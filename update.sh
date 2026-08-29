#!/usr/bin/env bash
###############################################################################
# systui Update Script
# Fetches a clean committed revision into a root-owned cache and reinstalls it.
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
STATE_DIR="${SYSTUI_STATE_DIR:-/etc/systui}"
REMOTE_FILE="$STATE_DIR/source-url"
BRANCH_FILE="$STATE_DIR/source-branch"
CACHE_DIR="${SYSTUI_UPDATE_CACHE:-/var/lib/systui/source}"
FORCE=0
NO_DEPS=0

usage() {
    cat <<USAGE
Usage: $0 [options]

Options:
  --force       Recreate the root-owned update cache before updating.
  --no-deps     Skip dependency installation during reinstall.
  -h, --help    Show this help.

Environment overrides:
  SYSTUI_REPO_URL      Git repository URL.
  SYSTUI_BRANCH        Branch to update (default: recorded branch or main).
  SYSTUI_UPDATE_CACHE  Root-owned clean checkout (default: /var/lib/systui/source).
  INSTALL_PREFIX       Installation prefix (default: /usr/local).
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --force) FORCE=1 ;;
        --no-deps) NO_DEPS=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

info() { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is required to update systui."

if [ "$(id -u)" -ne 0 ]; then
    args=("$0")
    [ "$FORCE" -eq 1 ] && args+=(--force)
    [ "$NO_DEPS" -eq 1 ] && args+=(--no-deps)
    command -v sudo >/dev/null 2>&1 || die "Run this script as root."
    exec sudo --preserve-env=SYSTUI_REPO_URL,SYSTUI_BRANCH,SYSTUI_UPDATE_CACHE,INSTALL_PREFIX,SYSTUI_STATE_DIR "${args[@]}"
fi

mkdir -p "$STATE_DIR" "$(dirname "$CACHE_DIR")"
chmod 0755 "$STATE_DIR" "$(dirname "$CACHE_DIR")" 2>/dev/null || true

REPO_URL="${SYSTUI_REPO_URL:-}"
if [ -z "$REPO_URL" ] && [ -r "$REMOTE_FILE" ]; then
    REPO_URL=$(cat "$REMOTE_FILE")
fi
# Development checkout fallback. We only read its origin; installation never
# executes files from this potentially user-owned tree.
if [ -z "$REPO_URL" ] && git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    REPO_URL=$(git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)
fi
[ -n "$REPO_URL" ] || die "No repository URL is recorded. Set SYSTUI_REPO_URL or reinstall from a Git checkout."

BRANCH="${SYSTUI_BRANCH:-}"
if [ -z "$BRANCH" ] && [ -r "$BRANCH_FILE" ]; then
    BRANCH=$(cat "$BRANCH_FILE")
fi
[ -n "$BRANCH" ] || BRANCH=main
case "$BRANCH" in
    -*|*..*|*~*|*^*|*:*|*\?*|*\**|*\[*|*\\*|*' '*) die "Unsafe branch name: $BRANCH" ;;
esac

# The cache is the trust boundary: it is owned by root, contains only Git
# tracked files, and is reset/cleaned before every install.
if [ "$FORCE" -eq 1 ] && [ -e "$CACHE_DIR" ]; then
    info "Recreating update cache: $CACHE_DIR"
    rm -rf -- "$CACHE_DIR"
fi

if [ -e "$CACHE_DIR" ] && [ ! -d "$CACHE_DIR/.git" ]; then
    die "$CACHE_DIR exists but is not a Git checkout. Use --force or set SYSTUI_UPDATE_CACHE."
fi

if [ ! -d "$CACHE_DIR/.git" ]; then
    info "Creating root-owned update cache..."
    git clone --no-checkout -- "$REPO_URL" "$CACHE_DIR"
fi
chown -R root:root "$CACHE_DIR"
chmod go-w "$CACHE_DIR"

git_cache() { git -C "$CACHE_DIR" "$@"; }

info "Remote: $REPO_URL"
info "Branch: $BRANCH"
info "Cache:  $CACHE_DIR"

git_cache remote set-url origin "$REPO_URL"
git_cache fetch --prune --tags origin "$BRANCH"
git_cache checkout -B "$BRANCH" "origin/$BRANCH"
git_cache reset --hard "origin/$BRANCH"
git_cache clean -fdx

# Verify the install entry point is tracked by the exact commit we fetched.
git_cache ls-files --error-unmatch install.sh >/dev/null 2>&1 || die "Fetched revision does not track install.sh."
[ -f "$CACHE_DIR/install.sh" ] || die "Fetched revision does not contain install.sh."

TARGET_SHA=$(git_cache rev-parse --verify HEAD)
info "Installing commit: $TARGET_SHA"
chmod 0755 "$CACHE_DIR/install.sh"

if [ "$NO_DEPS" -eq 1 ]; then
    SYSTUI_SKIP_DEPS=1 INSTALL_PREFIX="$INSTALL_PREFIX" "$CACHE_DIR/install.sh"
else
    INSTALL_PREFIX="$INSTALL_PREFIX" "$CACHE_DIR/install.sh"
fi

printf '%s\n' "$CACHE_DIR" > "$STATE_DIR/source-dir"
printf '%s\n' "$REPO_URL" > "$REMOTE_FILE"
printf '%s\n' "$BRANCH" > "$BRANCH_FILE"
printf '%s\n' "$TARGET_SHA" > "$STATE_DIR/installed-commit"
chmod 0644 "$STATE_DIR/source-dir" "$REMOTE_FILE" "$BRANCH_FILE" "$STATE_DIR/installed-commit"

ok "systui updated and reinstalled successfully ($TARGET_SHA)."
