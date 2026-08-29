#!/bin/bash
###############################################################################
# systui Installation Script
# Installs dependencies and sets up systui as an executable
###############################################################################

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTUI_VERSION=$(head -n1 "$PROJECT_DIR/src/VERSION" 2>/dev/null | tr -d '[:space:]')
[ -n "$SYSTUI_VERSION" ] || SYSTUI_VERSION=dev
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
BIN_DIR="$INSTALL_PREFIX/bin"
LIB_DIR="$INSTALL_PREFIX/lib/systui"

###############################################################################
# Colors
###############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

###############################################################################
# Helper Functions
###############################################################################

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root. Try: sudo $0"
    fi
}

detect_pm() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v zypper >/dev/null 2>&1; then
        echo "zypper"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    elif command -v xbps-install >/dev/null 2>&1; then
        echo "xbps"
    elif command -v emerge >/dev/null 2>&1; then
        echo "emerge"
    else
        echo ""
    fi
}

package_is_installed() { # <package-manager> <native-package>
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

refresh_package_metadata() { # <package-manager>
    local pm="$1"
    [ "$PACKAGE_METADATA_REFRESHED" = 0 ] || return 0
    case "$pm" in
        apt) apt-get update ;;
        apk) apk update ;;
        pacman) pacman -Syu --noconfirm ;;   # -Sy alone desynchronises the system
        dnf) dnf makecache -y ;;
        yum) yum makecache -y ;;
        zypper) zypper --non-interactive refresh ;;
        xbps) xbps-install -S ;;
        emerge) return 0 ;;
    esac
    PACKAGE_METADATA_REFRESHED=1
}

install_native_packages() { # <package-manager> <packages...>
    local pm="$1" pkg
    shift
    local missing=() failed=()

    for pkg in "$@"; do
        package_is_installed "$pm" "$pkg" || missing+=("$pkg")
    done
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

    if [ ${#failed[@]} -gt 0 ]; then
        error "Required dependencies could not be installed: ${failed[*]}"
    fi
}

install_dependencies() {
    if [ "${SYSTUI_SKIP_DEPS:-0}" = "1" ]; then
        info "Skipping dependency installation (SYSTUI_SKIP_DEPS=1)"
        return 0
    fi

    info "Checking the minimal systui runtime dependencies..."

    local pm pkg_bash pkg_dialog pkg_coreutils pkg_grep pkg_sed pkg_awk
    local pkg_find pkg_curl pkg_ca cmd core_missing=0
    local required=()
    pm=$(detect_pm)
    [ -z "$pm" ] && error "Could not detect package manager. Please install manually."

    # Package names are shared by the supported binary distributions. Gentoo
    # uses category-qualified atoms.
    case "$pm" in
        apt|apk|pacman|dnf|yum|zypper|xbps)
            pkg_bash="bash"; pkg_dialog="dialog"; pkg_coreutils="coreutils"
            pkg_grep="grep"; pkg_sed="sed"; pkg_awk="gawk"; pkg_find="findutils"
            pkg_curl="curl"; pkg_ca="ca-certificates"
            ;;
        emerge)
            pkg_bash=app-shells/bash; pkg_dialog=dev-util/dialog
            pkg_coreutils=sys-apps/coreutils; pkg_grep=sys-apps/grep
            pkg_sed=sys-apps/sed; pkg_awk=sys-apps/gawk
            pkg_find=sys-apps/findutils; pkg_curl=net-misc/curl
            pkg_ca=app-misc/ca-certificates
            ;;
    esac

    info "Detected package manager: $pm"

    # Test capabilities, not package names. This avoids installing gawk when a
    # working awk is already present, or curl when wget already handles HTTPS.
    command -v bash >/dev/null 2>&1 || required+=("$pkg_bash")
    command -v dialog >/dev/null 2>&1 || required+=("$pkg_dialog")
    command -v grep >/dev/null 2>&1 || required+=("$pkg_grep")
    command -v sed >/dev/null 2>&1 || required+=("$pkg_sed")
    command -v awk >/dev/null 2>&1 || required+=("$pkg_awk")
    command -v find >/dev/null 2>&1 || required+=("$pkg_find")

    for cmd in id mktemp head tr cut sort tee chmod rm date; do
        command -v "$cmd" >/dev/null 2>&1 || core_missing=1
    done
    [ "$core_missing" = 0 ] || required+=("$pkg_coreutils")

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        required+=("$pkg_curl")
    fi
    package_is_installed "$pm" "$pkg_ca" || required+=("$pkg_ca")

    install_native_packages "$pm" "${required[@]}"

    success "Dependency check complete"
}

check_command() {
    command -v "$1" >/dev/null 2>&1 && return 0 || return 1
}

verify_dependencies() {
    info "Verifying dependencies..."
    
    local missing_commands=""
    for cmd in bash dialog sed awk grep cut tr head sort find; do
        if ! check_command "$cmd"; then
            missing_commands+="$cmd "
        fi
    done
    if ! check_command curl && ! check_command wget; then
        missing_commands+="curl-or-wget "
    fi
    
    if [ -n "$missing_commands" ]; then
        error "Missing required commands: $missing_commands"
    fi
    
    success "All dependencies present"
}

install_project() {
    info "Installing systui to $LIB_DIR..."

    # Refuse to run when the checkout *is* the install target: the managed
    # content is deleted before it is copied, which would destroy the source.
    if [ "$PROJECT_DIR" = "$LIB_DIR" ]; then
        error "Refusing to install: the source directory and \$LIB_DIR are the same path ($LIB_DIR).
Run install.sh from a separate checkout, or set INSTALL_PREFIX to another prefix."
    fi

    mkdir -p "$LIB_DIR"
    mkdir -p "$BIN_DIR"
    
    # Remove managed content first so files deleted in the new release cannot
    # linger from an older installation. User configuration lives elsewhere.
    rm -rf -- "$LIB_DIR/src" "$LIB_DIR/share" "$LIB_DIR/docs"

    # Copy the latest project files.
    cp -r "$PROJECT_DIR/src" "$LIB_DIR/"
    if [ -d "$PROJECT_DIR/share" ]; then
        cp -r "$PROJECT_DIR/share" "$LIB_DIR/"
    fi
    if [ -d "$PROJECT_DIR/docs" ]; then
        cp -r "$PROJECT_DIR/docs" "$LIB_DIR/"
    fi
    [ -f "$LIB_DIR/share/homebrew/install-homebrew-root.sh" ] && chmod 0755 "$LIB_DIR/share/homebrew/install-homebrew-root.sh"
    if [ -f "$PROJECT_DIR/update.sh" ]; then
        install -m 0755 "$PROJECT_DIR/update.sh" "$LIB_DIR/update.sh"
        ln -sfn "$LIB_DIR/update.sh" "$BIN_DIR/systui-update"
    fi
    # Record the source checkout so systui-update works from the installed copy.
    local state_dir="${SYSTUI_STATE_DIR:-/etc/systui}"
    local source_url="" source_branch=""
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

    # Build beside the destination, then replace /usr/local/bin/systui in one
    # operation. This intentionally supersedes any older managed executable.
    rm -f -- "$wrapper_tmp"
    cat > "$wrapper_tmp" << 'WRAPPER'
#!/bin/bash
# systui — Linux System TUI
# Auto-generated by install.sh

LIBDIR="__SYSTUI_LIBDIR__"

# Source core modules
. "$LIBDIR/src/core/config.sh" || exit 1
. "$LIBDIR/src/core/tui-widgets.sh" || exit 1
. "$LIBDIR/src/core/common.sh" || exit 1

# Source feature modules (if they exist). The explicit `continue` keeps an
# unmatched glob or a module whose last statement returns non-zero from
# becoming the loop's exit status.
manifest="$LIBDIR/src/features/.load-order"
[ -r "$manifest" ] || { echo "systui: missing feature load manifest: $manifest" >&2; exit 1; }
while IFS= read -r rel || [ -n "$rel" ]; do
    case "$rel" in ''|'#'*) continue ;; esac
    feature="$LIBDIR/src/features/$rel"
    [ -f "$feature" ] || { echo "systui: feature manifest references missing file: $rel" >&2; exit 1; }
    . "$feature" || { echo "systui: failed to load $feature" >&2; exit 1; }
done < "$manifest"

# Initialize system detection
detect_pm
detect_init
detect_distro

# systui needs root for rootfs builds and system configuration. require_root
# calls die(), which exits -- so it must not be wrapped in a `||` fallback and
# its message must not be redirected to /dev/null, or a non-root invocation
# terminates silently with no output at all.
require_root

# Main menu
main_menu() {
    while true; do
        local choice
        choice=$(tui_menu "Main Menu" "systui — choose a section:" \
            provision "Ultimate Provision (quick system setup)" \
            rootfs    "Rootfs Builder (create minimal systems)" \
            config    "System Configuration" \
            awesome   "Awesome Linux (software catalogue)" \
            health    "System Health (scans and repairs)" \
            quit      "Quit") || return 0
        
        case "$choice" in
            provision)
                menu_ultimate_provision
                ;;
            rootfs)
                menu_rootfs
                ;;
            config)
                menu_sysconfig
                ;;
            awesome)
                menu_awesome_linux
                ;;
            health)
                menu_health
                ;;
            quit)
                return
                ;;
        esac
    done
}

# Run main menu
main_menu
WRAPPER
    # Escape sed replacement metacharacters so a prefix containing | & or \
    # cannot corrupt (or inject into) the generated wrapper.
    local lib_dir_escaped
    lib_dir_escaped=$(printf '%s' "$LIB_DIR" | sed -e 's/[\\&|]/\\&/g')
    sed -i "s|__SYSTUI_LIBDIR__|$lib_dir_escaped|g" "$wrapper_tmp"
    install -m 0755 "$wrapper_tmp" "$BIN_DIR/systui"
    rm -f -- "$wrapper_tmp"
    success "Executable installed/replaced at $BIN_DIR/systui"
}

create_manpage() {
    info "Creating man page..."
    
    mkdir -p "$INSTALL_PREFIX/share/man/man1"
    
    cat > "$INSTALL_PREFIX/share/man/man1/systui.1" << 'MANPAGE'
.TH SYSTUI 1 "2026-08-29" "systui __SYSTUI_VERSION__" "User Commands"
.SH NAME
systui \- Linux System Administration Terminal UI
.SH SYNOPSIS
.B systui
.SH DESCRIPTION
systui is a terminal-based user interface for Linux system configuration,
provisioning, and management.
.SH FEATURES
.IP "•" 2
Ultimate Provision: Install, configure, run, update, and remove quick setup
.IP "•" 2
System Configuration: Shells, repositories, packages, services, and users
.IP "•" 2
Dialog-based TUI: Easy navigation and configuration
.SH REQUIREMENTS
.IP "•" 2
Root access (for most operations)
.IP "•" 2
dialog command
.IP "•" 2
Standard Unix tools
.SH USAGE
.B sudo systui
.PP
Navigate using arrow keys and Enter. Press Tab to switch focus.
.SH SEE ALSO
dialog(1), bash(1)
.SH AUTHOR
systui Development Team
MANPAGE
    sed -i "s/__SYSTUI_VERSION__/$SYSTUI_VERSION/g" "$INSTALL_PREFIX/share/man/man1/systui.1"
    
    success "Man page created at $INSTALL_PREFIX/share/man/man1/systui.1"
}

cleanup() {
    info "Final checks..."
    
    # Verify installation
    if [ ! -x "$BIN_DIR/systui" ]; then
        error "Failed to create systui executable"
    fi
    
    if ! command -v systui >/dev/null 2>&1; then
        warn "systui not in PATH. Add $BIN_DIR to your PATH:"
        warn "  export PATH=\"$BIN_DIR:\$PATH\""
    fi
    
    success "Installation complete!"
}

###############################################################################
# Main Installation Flow
###############################################################################

main() {
    echo ""
    echo "========== systui Installation =========="
    echo "Version: $SYSTUI_VERSION"
    echo "Install prefix: $INSTALL_PREFIX"
    echo "Library directory: $LIB_DIR"
    echo ""
    
    require_root
    
    info "Step 1: Installing system dependencies..."
    install_dependencies
    
    info "Step 2: Verifying dependencies..."
    verify_dependencies
    
    info "Step 3: Installing project files..."
    install_project
    
    info "Step 4: Creating executable..."
    create_executable
    
    info "Step 5: Creating documentation..."
    create_manpage
    
    cleanup
    
    echo ""
    echo "========== Installation Complete =========="
    echo ""
    echo "To use systui, run:"
    echo "  sudo $BIN_DIR/systui"
    echo ""
    echo "For help, see:"
    echo "  man systui"
    echo ""
}

main "$@"
