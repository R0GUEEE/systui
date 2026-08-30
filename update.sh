#!/usr/bin/env bash
###############################################################################
# systui Update Script
# Replaces the local systui installation with a fresh copy of GitHub main.
###############################################################################

set -Eeuo pipefail

INSTALL_PREFIX="${INSTALL_PREFIX:-/usr}"
STATE_DIR="${SYSTUI_STATE_DIR:-/etc/systui}"
CACHE_DIR="${SYSTUI_UPDATE_CACHE:-/var/lib/systui/source}"
LIB_DIR="$INSTALL_PREFIX/lib/systui"
REPO_URL="https://github.com/R0GUEEE/systui.git"
BRANCH="main"
NO_DEPS=0

usage() {
    cat <<USAGE
Usage: $0 [options]

Options:
  --force       Accepted for compatibility; updates are always full replacements.
  --no-deps     Skip dependency installation during reinstall.
  -h, --help    Show this help.

Every update is a clean replacement from:
  $REPO_URL
  branch: $BRANCH
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --force) ;;
        --no-deps) NO_DEPS=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

info() { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[OK]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

canonical_parent_child() { # <path>
    local p="$1" parent base
    [ -n "$p" ] || return 1
    case "$p" in /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var) return 1;; esac
    parent=$(dirname -- "$p")
    base=$(basename -- "$p")
    mkdir -p -- "$parent" || return 1
    parent=$(cd -- "$parent" && pwd -P) || return 1
    printf '%s/%s\n' "$parent" "$base"
}

safe_remove_cache() {
    local p="$1"
    [ ! -e "$p" ] && return 0
    [ -d "$p" ] || die "Refusing to replace non-directory update cache: $p"
    # Never recursively remove an arbitrary caller-selected directory. An
    # existing cache must either carry our marker or be the default checkout
    # with the expected Git remote.
    if [ -f "$p/.systui-update-cache" ]; then :
    elif [ "$p" = /var/lib/systui/source ] && git -C "$p" remote get-url origin 2>/dev/null | grep -qxF "$REPO_URL"; then :
    else
        die "Refusing to recursively remove untrusted update cache: $p"
    fi
    rm -rf --one-file-system -- "$p"
}

safe_remove_library() {
    local p="$1"
    case "$p" in */lib/systui) ;; *) die "Unsafe systui library path: $p";; esac
    [ "$p" != /lib/systui ] || die "Refusing unsafe library deletion: $p"
    [ ! -e "$p" ] || rm -rf --one-file-system -- "$p"
}

command -v git >/dev/null 2>&1 || die "git is required to update systui."

if [ "$(id -u)" -ne 0 ]; then
    args=("$0")
    [ "$NO_DEPS" -eq 1 ] && args+=(--no-deps)
    command -v sudo >/dev/null 2>&1 || die "Run this script as root."
    # Deliberately do not preserve arbitrary update/deletion paths through sudo.
    exec sudo "${args[@]}"
fi

CACHE_DIR=$(canonical_parent_child "$CACHE_DIR") || die "Unsafe update cache path."
LIB_DIR=$(canonical_parent_child "$LIB_DIR") || die "Unsafe install prefix/library path."
STATE_DIR=$(canonical_parent_child "$STATE_DIR") || die "Unsafe state directory path."

mkdir -p -- "$STATE_DIR" "$(dirname -- "$CACHE_DIR")"
chmod 0755 "$STATE_DIR" "$(dirname -- "$CACHE_DIR")" 2>/dev/null || true

info "Replacing update checkout with a fresh GitHub main clone..."
safe_remove_cache "$CACHE_DIR"
git clone --depth 1 --single-branch --branch "$BRANCH" -- "$REPO_URL" "$CACHE_DIR"
printf '%s\n' 'managed-by=systui-update' > "$CACHE_DIR/.systui-update-cache"
chown -R root:root "$CACHE_DIR"
chmod go-w "$CACHE_DIR"

[ -f "$CACHE_DIR/install.sh" ] || die "GitHub main does not contain install.sh."
chmod 0755 "$CACHE_DIR/install.sh"
[ ! -f "$CACHE_DIR/update.sh" ] || chmod 0755 "$CACHE_DIR/update.sh"

TARGET_SHA=$(git -C "$CACHE_DIR" rev-parse --verify HEAD)
info "Remote: $REPO_URL"
info "Branch: $BRANCH"
info "Commit: $TARGET_SHA"

if [ -e "$LIB_DIR" ]; then
    info "Removing previous systui installation tree: $LIB_DIR"
    safe_remove_library "$LIB_DIR"
fi

if [ "$NO_DEPS" -eq 1 ]; then
    SYSTUI_SKIP_DEPS=1 INSTALL_PREFIX="$INSTALL_PREFIX" "$CACHE_DIR/install.sh"
else
    INSTALL_PREFIX="$INSTALL_PREFIX" "$CACHE_DIR/install.sh"
fi

printf '%s\n' "$CACHE_DIR" > "$STATE_DIR/source-dir"
printf '%s\n' "$REPO_URL" > "$STATE_DIR/source-url"
printf '%s\n' "$BRANCH" > "$STATE_DIR/source-branch"
printf '%s\n' "$TARGET_SHA" > "$STATE_DIR/installed-commit"
chmod 0644 "$STATE_DIR/source-dir" "$STATE_DIR/source-url" "$STATE_DIR/source-branch" "$STATE_DIR/installed-commit"

ok "systui completely replaced with GitHub main ($TARGET_SHA)."
