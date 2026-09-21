#!/usr/bin/env bash
###############################################################################
# systui Update Script
# Replaces the local systui installation with a fresh copy of GitHub main.
###############################################################################

set -Eeuo pipefail

INSTALL_PREFIX="${INSTALL_PREFIX:-/usr}"
STATE_DIR="${SYSTUI_STATE_DIR:-/etc/systui}"
# Security boundary: the update checkout is always owned/selected by systui.
# Do not accept a caller-controlled recursive-deletion path through environment.
CACHE_DIR="/var/lib/systui/source"
LIB_DIR="$INSTALL_PREFIX/lib/systui"
REPO_URL="https://github.com/R0GUEEE/systui.git"
BRANCH="main"
NO_DEPS=0
MINIMAL=0
DRY_RUN=0

usage() {
    cat <<USAGE
Usage: $0 [options]

Options:
  --force       Accepted for compatibility; updates are always full replacements.
  --minimal     Accepted for compatibility; the core tier is installed anyway.
  --dry-run     Show the dependency plan without changing the system.
  --no-deps     Skip dependency installation during reinstall.
  -h, --help    Show this help.

Every update is a clean replacement from:
  $REPO_URL
  branch: $BRANCH

Core dependencies are pre-installed from share/systui-deps.tsv; optional
tooling is installed on demand from the menus.
Update checkout:
  $CACHE_DIR (fixed, root-owned)
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --force) ;;
        --minimal) MINIMAL=1 ;;
        --dry-run) DRY_RUN=1 ;;
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

detect_pm() {
    if command -v apt-get >/dev/null 2>&1; then printf 'apt\n'
    elif command -v apk >/dev/null 2>&1; then printf 'apk\n'
    elif command -v pacman >/dev/null 2>&1; then printf 'pacman\n'
    elif command -v dnf >/dev/null 2>&1; then printf 'dnf\n'
    elif command -v zypper >/dev/null 2>&1; then printf 'zypper\n'
    elif command -v yum >/dev/null 2>&1; then printf 'yum\n'
    elif command -v xbps-install >/dev/null 2>&1; then printf 'xbps\n'
    elif command -v emerge >/dev/null 2>&1; then printf 'emerge\n'
    fi
}

update_pkg_installed() { # <pm> <package>
    case "$1" in
        apt) dpkg-query -W -f='${Status}' "$2" 2>/dev/null | grep -q 'install ok installed' ;;
        apk) apk info -e "$2" >/dev/null 2>&1 ;;
        pacman) pacman -Q "$2" >/dev/null 2>&1 ;;
        dnf|yum|zypper) rpm -q "$2" >/dev/null 2>&1 ;;
        xbps) xbps-query -p pkgver "$2" >/dev/null 2>&1 ;;
        emerge) [ -n "$(portageq match / "$2" 2>/dev/null)" ] ;;
        *) command -v "$2" >/dev/null 2>&1 ;;
    esac
}

update_install_one() { # <pm> <package>
    case "$1" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$2" ;;
        apk) apk add --no-progress "$2" ;;
        pacman) pacman -S --noconfirm --needed "$2" ;;
        dnf) dnf install -y --setopt=install_weak_deps=False "$2" ;;
        yum) yum install -y "$2" ;;
        zypper) zypper --non-interactive install --no-recommends "$2" ;;
        xbps) xbps-install -y "$2" ;;
        emerge) emerge --noreplace "$2" ;;
        *) return 1 ;;
    esac
}

update_refresh_metadata() { # <pm>
    case "$1" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq ;;
        apk) apk update ;;
        dnf) dnf makecache -y ;;
        yum) yum makecache -y ;;
        zypper) zypper --non-interactive refresh ;;
        xbps) xbps-install -S ;;
        pacman) return 0 ;;
    esac >/dev/null 2>&1 || true
}

# The updater itself needs git plus a download tool and a CA bundle before it can
# clone. Each prerequisite is installed on its own and anything a distribution
# cannot provide is skipped rather than aborting the update; git is the only
# hard requirement, because without it the update cannot run at all.
ensure_update_prerequisites() {
    local pm pkg skipped=''
    local -a pkgs=()
    command -v git >/dev/null 2>&1 || pkgs+=(git)
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then pkgs+=(curl); fi
    command -v tar >/dev/null 2>&1 || pkgs+=(tar)
    [ -e /etc/ssl/certs/ca-certificates.crt ] || pkgs+=(ca-certificates)

    if [ "${#pkgs[@]}" -eq 0 ]; then
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] update prerequisites would be installed: ${pkgs[*]}"
        return 0
    fi
    pm=$(detect_pm)
    if [ -z "$pm" ]; then
        warn "No package manager detected; install these before updating: ${pkgs[*]}"
        command -v git >/dev/null 2>&1 || die "git is required to update systui."
        return 0
    fi

    info "Update prerequisites ($pm): ${pkgs[*]}"
    update_refresh_metadata "$pm"
    for pkg in "${pkgs[@]}"; do
        update_pkg_installed "$pm" "$pkg" && continue
        if ! update_install_one "$pm" "$pkg" >/dev/null 2>&1 || ! update_pkg_installed "$pm" "$pkg"; then
            skipped="$skipped $pkg"
        fi
    done
    if [ -n "$skipped" ]; then
        warn "Skipped prerequisites not available for $pm:${skipped}"
        warn "Continuing without them; affected features will report the tool as unavailable."
    fi
    command -v git >/dev/null 2>&1 || die "git is required to update systui and could not be installed automatically."
    return 0
}

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
    [ "$p" = /var/lib/systui/source ] || die "Refusing unexpected update cache path: $p"
    [ ! -e "$p" ] && return 0
    [ -d "$p" ] || die "Refusing to replace non-directory update cache: $p"
    # An existing checkout must prove it is ours before recursive deletion.
    if [ -f "$p/.systui-update-cache" ]; then :
    elif git -C "$p" remote get-url origin 2>/dev/null | grep -qxF "$REPO_URL"; then :
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

if [ "$(id -u)" -ne 0 ]; then
    args=("$0")
    [ "$NO_DEPS" -eq 1 ] && args+=(--no-deps)
    [ "$MINIMAL" -eq 1 ] && args+=(--minimal)
    [ "$DRY_RUN" -eq 1 ] && args+=(--dry-run)
    command -v sudo >/dev/null 2>&1 || die "Run this script as root."
    exec sudo "${args[@]}"
fi

# Prerequisites are installed as root, before anything needs them.
if [ "$NO_DEPS" -eq 1 ]; then
    command -v git >/dev/null 2>&1 || die "git is required to update systui."
else
    ensure_update_prerequisites
fi

CACHE_DIR=$(canonical_parent_child "$CACHE_DIR") || die "Unsafe update cache path."
[ "$CACHE_DIR" = /var/lib/systui/source ] || die "Update cache escaped fixed path."
LIB_DIR=$(canonical_parent_child "$LIB_DIR") || die "Unsafe install prefix/library path."
STATE_DIR=$(canonical_parent_child "$STATE_DIR") || die "Unsafe state directory path."

mkdir -p -- "$STATE_DIR" "$(dirname -- "$CACHE_DIR")"
chown root:root "$(dirname -- "$CACHE_DIR")" "$STATE_DIR" 2>/dev/null || true
chmod 0755 "$STATE_DIR" "$(dirname -- "$CACHE_DIR")" 2>/dev/null || true

if [ "$DRY_RUN" -eq 1 ]; then
    plan_args=''
    [ "$MINIMAL" -eq 1 ] && plan_args="$plan_args --minimal"
    [ "$NO_DEPS" -eq 1 ] && plan_args="$plan_args --no-deps"
    info "[dry-run] would replace the update checkout: $CACHE_DIR"
    info "[dry-run] would clone $REPO_URL ($BRANCH)"
    info "[dry-run] would remove and reinstall: $LIB_DIR"
    info "[dry-run] would run: INSTALL_PREFIX=$INSTALL_PREFIX $CACHE_DIR/install.sh$plan_args"
    SYSTUI_PM_OVERRIDE="${SYSTUI_PM_OVERRIDE:-$(detect_pm)}" \
        bash "$(dirname "$0")/install.sh" --deps-only --dry-run || warn "Dependency plan could not be generated."
    ok "Dry run complete; nothing was changed."
    exit 0
fi

info "Replacing update checkout with a fresh GitHub main clone..."
safe_remove_cache "$CACHE_DIR"
git clone --depth 1 --single-branch --branch "$BRANCH" -- "$REPO_URL" "$CACHE_DIR"
printf '%s\n' 'managed-by=systui-update' > "$CACHE_DIR/.systui-update-cache"
chown -R root:root "$CACHE_DIR"
chmod go-w "$CACHE_DIR"

test -f "$CACHE_DIR/install.sh" || die "GitHub main does not contain install.sh."
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

install_args=()
[ "$MINIMAL" -eq 1 ] && install_args+=(--minimal)
[ "$DRY_RUN" -eq 1 ] && install_args+=(--dry-run)

if [ "$NO_DEPS" -eq 1 ]; then
    SYSTUI_SKIP_DEPS=1 INSTALL_PREFIX="$INSTALL_PREFIX" "$CACHE_DIR/install.sh" ${install_args[@]+"${install_args[@]}"}
else
    INSTALL_PREFIX="$INSTALL_PREFIX" "$CACHE_DIR/install.sh" ${install_args[@]+"${install_args[@]}"}
fi

printf '%s\n' "$CACHE_DIR" > "$STATE_DIR/source-dir"
printf '%s\n' "$REPO_URL" > "$STATE_DIR/source-url"
printf '%s\n' "$BRANCH" > "$STATE_DIR/source-branch"
printf '%s\n' "$TARGET_SHA" > "$STATE_DIR/installed-commit"
chmod 0644 "$STATE_DIR/source-dir" "$STATE_DIR/source-url" "$STATE_DIR/source-branch" "$STATE_DIR/installed-commit"

ok "systui completely replaced with GitHub main ($TARGET_SHA)."
