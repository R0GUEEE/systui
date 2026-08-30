#!/bin/bash
###############################################################################
# systui — Installation Script
###############################################################################
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTUI_VERSION=$(head -n1 "$PROJECT_DIR/src/VERSION" 2>/dev/null | tr -d '[:space:]')
[ -n "$SYSTUI_VERSION" ] || SYSTUI_VERSION=dev
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr}"
BIN_DIR="$INSTALL_PREFIX/bin"
LIB_DIR="$INSTALL_PREFIX/lib/systui"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || error "This script must be run as root. Try: sudo $0"; }

detect_pm() {
    if command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v apk >/dev/null 2>&1; then echo apk
    elif command -v pacman >/dev/null 2>&1; then echo pacman
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v zypper >/dev/null 2>&1; then echo zypper
    elif command -v yum >/dev/null 2>&1; then echo yum
    elif command -v xbps-install >/dev/null 2>&1; then echo xbps
    elif command -v emerge >/dev/null 2>&1; then echo emerge
    else echo ""; fi
}

package_is_installed() {
    local pm="$1" pkg="$2"
    case "$pm" in
        apt) dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' ;;
        apk) apk info -e "$pkg" >/dev/null 2>&1 ;;
        pacman) pacman -Q "$pkg" >/dev/null 2>&1 ;;
        dnf|yum|zypper) rpm -q "$pkg" >/dev/null 2>&1 ;;
        xbps) xbps-query -p pkgver "$pkg" >/dev/null 2>&1 ;;
        emerge) [ -n "$(portageq match / "$pkg" 2>/dev/null)" ] ;;
        *) return 1 ;;
    esac
}

PACKAGE_METADATA_REFRESHED=0
refresh_package_metadata() {
    local pm="$1"
    [ "$PACKAGE_METADATA_REFRESHED" = 0 ] || return 0
    case "$pm" in
        apt) apt-get update ;;
        apk) apk update ;;
        pacman)
            warn "Arch requires a full synchronized upgrade before dependency installation."
            pacman -Syu --noconfirm ;;
        dnf) dnf makecache -y ;;
        yum) yum makecache -y ;;
        zypper) zypper --non-interactive refresh ;;
        xbps) xbps-install -S ;;
        emerge) return 0 ;;
    esac
    PACKAGE_METADATA_REFRESHED=1
}

install_native_packages() {
    local pm="$1" pkg; shift
    local missing=() failed=()
    for pkg in "$@"; do package_is_installed "$pm" "$pkg" || missing+=("$pkg"); done
    [ ${#missing[@]} -gt 0 ] || return 0
    info "Installing ${#missing[@]} missing package(s): ${missing[*]}"
    refresh_package_metadata "$pm"
    case "$pm" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" ;;
        apk) apk add --no-progress "${missing[@]}" ;;
        pacman) pacman -S --noconfirm --needed "${missing[@]}" ;;
        dnf) dnf install -y --setopt=install_weak_deps=False "${missing[@]}" ;;
        yum) yum install -y "${missing[@]}" ;;
        zypper) zypper --non-interactive install --no-recommends "${missing[@]}" ;;
        xbps) xbps-install -y "${missing[@]}" ;;
        emerge) emerge --noreplace "${missing[@]}" ;;
    esac && return 0
    warn "The package batch was not fully available; retrying one package at a time."
    for pkg in "${missing[@]}"; do
        package_is_installed "$pm" "$pkg" && continue
        case "$pm" in
            apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg" ;;
            apk) apk add --no-progress "$pkg" ;;
            pacman) pacman -S --noconfirm --needed "$pkg" ;;
            dnf) dnf install -y --setopt=install_weak_deps=False "$pkg" ;;
            yum) yum install -y "$pkg" ;;
            zypper) zypper --non-interactive install --no-recommends "$pkg" ;;
            xbps) xbps-install -y "$pkg" ;;
            emerge) emerge --noreplace "$pkg" ;;
        esac >/dev/null 2>&1 || failed+=("$pkg")
    done
    [ ${#failed[@]} -eq 0 ] || error "Required dependencies could not be installed: ${failed[*]}"
}

install_dependencies() {
    if [ "${SYSTUI_SKIP_DEPS:-0}" = "1" ]; then info "Skipping dependency installation (SYSTUI_SKIP_DEPS=1)"; return 0; fi
    info "Checking the minimal systui runtime dependencies..."
    local pm pkg_bash pkg_dialog pkg_coreutils pkg_grep pkg_sed pkg_awk pkg_find pkg_curl pkg_ca cmd core_missing=0
    local required=()
    pm=$(detect_pm); [ -z "$pm" ] && error "Could not detect package manager. Please install manually."
    case "$pm" in
        apt|apk|pacman|dnf|yum|zypper|xbps)
            pkg_bash='bash'; pkg_dialog='dialog'; pkg_coreutils='coreutils'; pkg_grep='grep'; pkg_sed='sed'; pkg_awk='gawk'; pkg_find='findutils'; pkg_curl='curl'; pkg_ca='ca-certificates' ;;
        emerge)
            pkg_bash='app-shells/bash'; pkg_dialog='dev-util/dialog'; pkg_coreutils='sys-apps/coreutils'; pkg_grep='sys-apps/grep'; pkg_sed='sys-apps/sed'; pkg_awk='sys-apps/gawk'; pkg_find='sys-apps/findutils'; pkg_curl='net-misc/curl'; pkg_ca='app-misc/ca-certificates' ;;
    esac
    info "Detected package manager: $pm"
    command -v bash >/dev/null 2>&1 || required+=("$pkg_bash")
    command -v dialog >/dev/null 2>&1 || required+=("$pkg_dialog")
    command -v grep >/dev/null 2>&1 || required+=("$pkg_grep")
    command -v sed >/dev/null 2>&1 || required+=("$pkg_sed")
    command -v awk >/dev/null 2>&1 || required+=("$pkg_awk")
    command -v find >/dev/null 2>&1 || required+=("$pkg_find")
    for cmd in id mktemp head tr cut sort tee chmod rm date; do command -v "$cmd" >/dev/null 2>&1 || core_missing=1; done
    [ "$core_missing" = 0 ] || required+=("$pkg_coreutils")
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then required+=("$pkg_curl"); fi
    package_is_installed "$pm" "$pkg_ca" || required+=("$pkg_ca")
    install_native_packages "$pm" "${required[@]}"
    success "Dependency check complete"
}

check_command() { command -v "$1" >/dev/null 2>&1; }
verify_dependencies() {
    info "Verifying dependencies..."
    local missing_commands="" cmd
    for cmd in bash dialog sed awk grep cut tr head sort find; do check_command "$cmd" || missing_commands+="$cmd "; done
    if ! check_command curl && ! check_command wget; then missing_commands+="curl-or-wget "; fi
    [ -z "$missing_commands" ] || error "Missing required commands: $missing_commands"
    success "All dependencies present"
}

install_project() {
    info "Installing systui to $LIB_DIR..."
    if [ "$PROJECT_DIR" = "$LIB_DIR" ]; then error "Refusing to install: the source directory and \$LIB_DIR are the same path ($LIB_DIR). Run install.sh from a separate checkout, or set INSTALL_PREFIX to another prefix."; fi
    mkdir -p "$LIB_DIR" "$BIN_DIR"
    rm -rf -- "$LIB_DIR/src" "$LIB_DIR/share" "$LIB_DIR/docs"
    cp -r "$PROJECT_DIR/src" "$LIB_DIR/"
    [ ! -d "$PROJECT_DIR/share" ] || cp -r "$PROJECT_DIR/share" "$LIB_DIR/"
    [ ! -d "$PROJECT_DIR/docs" ] || cp -r "$PROJECT_DIR/docs" "$LIB_DIR/"
    [ -f "$LIB_DIR/share/homebrew/install-homebrew-root.sh" ] && chmod 0755 "$LIB_DIR/share/homebrew/install-homebrew-root.sh"
    if [ -f "$PROJECT_DIR/update.sh" ]; then install -m 0755 "$PROJECT_DIR/update.sh" "$LIB_DIR/update.sh"; ln -sfn "$LIB_DIR/update.sh" "$BIN_DIR/systui-update"; fi
    local state_dir="${SYSTUI_STATE_DIR:-/etc/systui}" source_url="" source_branch=""
    mkdir -p "$state_dir"
    if command -v git >/dev/null 2>&1 && git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        source_url=$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)
        source_branch=$(git -C "$PROJECT_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
        printf '%s\n' "$(git -C "$PROJECT_DIR" rev-parse --show-toplevel)" > "$state_dir/source-dir"
        [ -n "$source_url" ] && printf '%s\n' "$source_url" > "$state_dir/source-url"
        [ -n "$source_branch" ] && printf '%s\n' "$source_branch" > "$state_dir/source-branch"
        chmod 0644 "$state_dir"/source-* 2>/dev/null || true
    fi
    success "Project files installed to $LIB_DIR"
}

create_executable() {
    local wrapper_tmp="$BIN_DIR/.systui.$$"
    info "Creating the latest executable wrapper..."
    rm -f -- "$wrapper_tmp"
    cat > "$wrapper_tmp" << 'WRAPPER'
#!/bin/bash
LIBDIR="__SYSTUI_LIBDIR__"
SYSTUI_LIBDIR="$LIBDIR"
export SYSTUI_LIBDIR

startup_die() {
    printf 'systui: startup failed: %s\n' "$*" >&2
    exit 1
}
startup_stage() {
    [ "${SYSTUI_DEBUG_STARTUP:-0}" = 1 ] && printf 'systui: startup: %s\n' "$*" >&2 || true
}

startup_stage "loading config"
. "$LIBDIR/src/core/config.sh" || startup_die "could not load core/config.sh"
startup_stage "loading TUI widgets"
. "$LIBDIR/src/core/tui-widgets.sh" || startup_die "could not load core/tui-widgets.sh"
startup_stage "loading common helpers"
. "$LIBDIR/src/core/common.sh" || startup_die "could not load core/common.sh"
startup_stage "loading feature loader"
. "$LIBDIR/src/core/loader.sh" || startup_die "could not load core/loader.sh"
startup_stage "loading features"
systui_load_features || startup_die "feature loading failed"
startup_stage "detecting platform"
detect_pm || startup_die "package manager detection failed"
detect_init || startup_die "init detection failed"
detect_distro || startup_die "distribution detection failed"
require_root || startup_die "root privileges are required"

systui_startup_check() {
    command -v "$DIALOG" >/dev/null 2>&1 || startup_die "dialog executable not found: $DIALOG"
    [ -t 0 ] || startup_die "stdin is not a terminal"
    [ -t 1 ] || startup_die "stdout is not a terminal"
    [ -t 2 ] || startup_die "stderr is not a terminal"
    [ -n "${TERM:-}" ] || startup_die "TERM is not set"
    if command -v tput >/dev/null 2>&1 && ! tput cols >/dev/null 2>&1; then
        startup_die "terminal type '$TERM' has no usable terminfo entry"
    fi
}

systui_diagnose() {
    printf 'systui diagnostics\n'
    printf '  library: %s\n' "$LIBDIR"
    printf '  version: %s\n' "${SYSTUI_VERSION:-unknown}"
    printf '  uid: %s\n' "$(id -u 2>/dev/null || echo unknown)"
    printf '  TERM: %s\n' "${TERM:-unset}"
    printf '  tty stdin/stdout/stderr: %s/%s/%s\n' "$([ -t 0 ] && echo yes || echo no)" "$([ -t 1 ] && echo yes || echo no)" "$([ -t 2 ] && echo yes || echo no)"
    printf '  dialog: %s\n' "$(command -v "$DIALOG" 2>/dev/null || echo missing)"
    printf '  runtime: %s\n' "${SYSTUI_ENVIRONMENT:-unknown}"
    printf '  init: %s\n' "${INIT:-unknown}"
    printf '  init provider: %s\n' "${SYSTUI_INIT_PROVIDER:-unknown}"
    printf '  package manager: %s\n' "${PM:-unknown}"
    printf '  distro: %s\n' "${DISTRO:-unknown}"
    printf '  logfile: %s\n' "${LOGFILE:-unknown}"
}

case "${1:-}" in
    --diagnose|--doctor) systui_diagnose; exit 0 ;;
esac

systui_startup_check
startup_stage "opening main menu"
main_menu() {
    while true; do
        local choice runtime rc
        runtime="${SYSTUI_ENVIRONMENT:-unknown}"
        choice=$(tui_menu "Main Menu" "Runtime: $runtime  ·  Init: ${INIT:-unknown}  ·  Packages: ${PM:-unknown}\n\nsystui — choose a section:" \
            health "System Health & diagnostics" \
            provision "Ultimate Provision — quick system setup" \
            rootfs "Root Filesystems — build, enter and manage" \
            config "System Configuration" \
            performance "Performance tuning" \
            quit "Quit")
        rc=$?
        case "$rc" in
            0) ;;
            1|255) return 0 ;;
            *)
                printf 'systui: dialog failed to open the main menu (exit %s)\n' "$rc" >&2
                [ -n "$choice" ] && printf '%s\n' "$choice" >&2
                return "$rc"
                ;;
        esac
        case "$choice" in
            health) menu_health ;;
            provision) menu_ultimate_provision ;;
            rootfs) menu_rootfs ;;
            config) menu_sysconfig ;;
            performance) menu_performance ;;
            quit) return ;;
            *) printf 'systui: unexpected main-menu selection: %s\n' "$choice" >&2; return 1 ;;
        esac
    done
}
main_menu
WRAPPER
    local lib_dir_escaped
    lib_dir_escaped=$(printf '%s' "$LIB_DIR" | sed -e 's/[\\&|]/\\&/g')
    sed -i "s|__SYSTUI_LIBDIR__|$lib_dir_escaped|g" "$wrapper_tmp"
    install -m 0755 "$wrapper_tmp" "$BIN_DIR/systui"
    rm -f -- "$wrapper_tmp"
    success "Executable installed/replaced at $BIN_DIR/systui"
}

create_manpage() {
    mkdir -p "$INSTALL_PREFIX/share/man/man1"
    cat > "$INSTALL_PREFIX/share/man/man1/systui.1" << 'MANPAGE'
.TH SYSTUI 1 "2026-08-30" "systui __SYSTUI_VERSION__" "User Commands"
.SH NAME
systui \- Linux System Administration Terminal UI
.SH SYNOPSIS
.B systui
.SH DESCRIPTION
systui is a terminal-based user interface for Linux system configuration, provisioning, and management.
.SH REQUIREMENTS
Root access, Bash, dialog, and standard Unix tools.
MANPAGE
    sed -i "s/__SYSTUI_VERSION__/$SYSTUI_VERSION/g" "$INSTALL_PREFIX/share/man/man1/systui.1"
}

cleanup() {
    [ -x "$BIN_DIR/systui" ] || error "Failed to create systui executable"
    if ! command -v systui >/dev/null 2>&1; then warn "systui not in PATH. Add $BIN_DIR to PATH."; fi
    success "Installation complete!"
}

main() {
    echo "========== systui Installation =========="
    echo "Version: $SYSTUI_VERSION"
    require_root
    install_dependencies
    verify_dependencies
    install_project
    create_executable
    create_manpage
    cleanup
}

main "$@"
