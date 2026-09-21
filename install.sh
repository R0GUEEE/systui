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

usage() {
    cat <<USAGE
Usage: $0 [options]

Options:
  --deps-only   Install and verify dependencies, then exit
  --dry-run     Print the dependency plan without changing the system
  --minimal     Accepted for compatibility; the core tier is installed anyway
  --no-deps     Skip dependency installation
  -h, --help    Show this help.

All packages systui needs to run are declared in share/systui-deps.tsv and
installed up front. Optional tooling and toolchains are installed on demand
from the menus. Anything a distribution cannot provide is skipped, not fatal.

Environment:
  SYSTUI_SKIP_DEPS=1       skip dependency installation entirely
  SYSTUI_MINIMAL_DEPS=1    accepted for compatibility (core is the default)
  SYSTUI_DEPS_TIERS=core   explicit tier selection
  SYSTUI_DEPS_DRY_RUN=1    print what would be installed, change nothing
  SYSTUI_DEPS_STRICT=1     fail instead of skipping unavailable packages
  SYSTUI_PM_OVERRIDE=<pm>  force apt|apk|pacman|dnf|zypper|xbps|emerge
USAGE
}

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
    # A failed index refresh must never abort the install: the locate step and
    # the per-package retry still run, and any package that cannot be found is
    # reported and skipped.
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
    esac || warn "Package index refresh did not complete for $pm; continuing"
    PACKAGE_METADATA_REFRESHED=1
    return 0
}

# Locate a package in the configured repositories without installing it.
#   0 = located, 1 = not found, 2 = cannot tell (no usable query for this PM)
deps_package_available() { # <pm> <package>
    local pm="$1" pkg="$2"
    case "$pm" in
        apt)
            apt-cache show -- "$pkg" >/dev/null 2>&1 && return 0
            apt-cache policy -- "$pkg" 2>/dev/null | grep -q 'Candidate: [0-9]' && return 0
            return 1 ;;
        apk)
            apk info -e "$pkg" >/dev/null 2>&1 && return 0
            apk search -x -- "$pkg" 2>/dev/null | grep -q . && return 0
            return 1 ;;
        pacman) pacman -Si -- "$pkg" >/dev/null 2>&1 && return 0; return 1 ;;
        dnf) dnf -q list --available "$pkg" >/dev/null 2>&1 && return 0; return 1 ;;
        yum) yum -q list available "$pkg" >/dev/null 2>&1 && return 0; return 1 ;;
        zypper) zypper --non-interactive --no-refresh search -x "$pkg" >/dev/null 2>&1 && return 0; return 1 ;;
        xbps) xbps-query -Rs "$pkg" >/dev/null 2>&1 && return 0; return 1 ;;
        emerge) emerge --search "$pkg" >/dev/null 2>&1 && return 0; return 1 ;;
        *) return 2 ;;
    esac
}

deps_run_install_batch() { # <pm> <packages...>
    local pm="$1"
    shift
    case "$pm" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
        apk) apk add --no-progress "$@" ;;
        pacman) pacman -S --noconfirm --needed "$@" ;;
        dnf) dnf install -y --setopt=install_weak_deps=False "$@" ;;
        yum) yum install -y "$@" ;;
        zypper) zypper --non-interactive install --no-recommends "$@" ;;
        xbps) xbps-install -y "$@" ;;
        emerge) emerge --noreplace "$@" ;;
        *) return 1 ;;
    esac
}

deps_run_install_one() { # <pm> <package>
    deps_run_install_batch "$1" "$2"
}

# Track packages that were unavailable so they are reported once, at the end.
deps_note_skipped() { # <packages...>
    local pkg
    for pkg in "$@"; do
        [ -n "$pkg" ] || continue
        case " ${SYSTUI_DEPS_SKIPPED:-} " in
            *" $pkg "*) ;;
            *) SYSTUI_DEPS_SKIPPED="${SYSTUI_DEPS_SKIPPED:+$SYSTUI_DEPS_SKIPPED }$pkg" ;;
        esac
    done
    return 0
}

deps_report_skipped() {
    [ -n "${SYSTUI_DEPS_SKIPPED:-}" ] || return 0
    warn "Skipped (not available for this distribution): $SYSTUI_DEPS_SKIPPED"
    warn "Related features will report their tool as unavailable; everything else works normally."
    return 0
}

# Install native packages. Packages a distribution cannot provide are located
# first and skipped with a report instead of failing the install: no missing
# package aborts the run. SYSTUI_DEPS_STRICT=1 turns skipped packages back into
# a hard error.
install_native_packages() {
    local pm="$1" pkg
    shift
    [ "$#" -gt 0 ] || return 0
    local -a missing=() available=() unlocatable=() failed=()
    for pkg in "$@"; do package_is_installed "$pm" "$pkg" || missing+=("$pkg"); done
    [ ${#missing[@]} -gt 0 ] || return 0
    info "Installing ${#missing[@]} missing package(s): ${missing[*]}"
    refresh_package_metadata "$pm"

    for pkg in "${missing[@]}"; do
        if deps_package_available "$pm" "$pkg"; then
            available+=("$pkg")
        else
            case $? in
                1) unlocatable+=("$pkg") ;;
                *) available+=("$pkg") ;;
            esac
        fi
    done
    if [ ${#unlocatable[@]} -gt 0 ]; then
        warn "Not found in any configured repository (skipped): ${unlocatable[*]}"
        deps_note_skipped "${unlocatable[@]}"
    fi

    if [ ${#available[@]} -gt 0 ]; then
        if deps_run_install_batch "$pm" "${available[@]}"; then
            for pkg in "${available[@]}"; do
                package_is_installed "$pm" "$pkg" || failed+=("$pkg")
            done
        else
            warn "The package batch did not complete; retrying one package at a time."
            for pkg in "${available[@]}"; do
                package_is_installed "$pm" "$pkg" && continue
                if deps_run_install_one "$pm" "$pkg" >/dev/null 2>&1; then
                    package_is_installed "$pm" "$pkg" || failed+=("$pkg")
                else
                    failed+=("$pkg")
                fi
            done
        fi
    fi

    if [ ${#failed[@]} -gt 0 ]; then
        warn "Could not install (skipped): ${failed[*]}"
        deps_note_skipped "${failed[@]}"
    fi

    if [ "${SYSTUI_DEPS_STRICT:-0}" = "1" ] && [ -n "${SYSTUI_DEPS_SKIPPED:-}" ]; then
        error "Dependencies could not be installed: $SYSTUI_DEPS_SKIPPED"
    fi
    return 0
}

###############################################################################
# Dependency installation (manifest driven)
#
# share/systui-deps.tsv is the single source of truth for systui's runtime
# dependencies: the core packages needed to start and operate the TUI. The
# former extra and build tiers were removed; anything else systui can use is
# installed on demand from the menus.
#
# Environment:
#   SYSTUI_SKIP_DEPS=1       skip dependency installation entirely
#   SYSTUI_MINIMAL_DEPS=1    accepted for compatibility (core is the default)
#   SYSTUI_DEPS_TIERS=core   explicit tier selection
#   SYSTUI_DEPS_DRY_RUN=1    print what would be installed, change nothing
#   SYSTUI_DEPS_STRICT=1     fail (instead of skipping) when a package or
#                            command is unavailable; the default skips
#   SYSTUI_PM_OVERRIDE=<pm>  force a package-manager backend
###############################################################################

deps_manifest_path() {
    if [ -r "$PROJECT_DIR/share/systui-deps.tsv" ]; then printf '%s\n' "$PROJECT_DIR/share/systui-deps.tsv"
    elif [ -n "${LIB_DIR:-}" ] && [ -r "$LIB_DIR/share/systui-deps.tsv" ]; then printf '%s\n' "$LIB_DIR/share/systui-deps.tsv"
    else return 1
    fi
}

deps_family_column() {
    case "$1" in
        apt) printf '2\n' ;; apk) printf '3\n' ;; pacman) printf '4\n' ;;
        dnf|yum|zypper) printf '5\n' ;; xbps) printf '6\n' ;; emerge) printf '7\n' ;;
        *) return 1 ;;
    esac
}

# Only the core tier is installed. The extra and build tiers were removed, so
# tooling, compilers and language managers are installed on demand from the
# menus instead of up front. SYSTUI_DEPS_TIERS can still narrow or extend the
# selection for a custom manifest.
deps_tiers() {
    if [ -n "${SYSTUI_DEPS_TIERS:-}" ]; then printf '%s\n' "$SYSTUI_DEPS_TIERS"; return 0; fi
    printf 'core\n'
}

# Emit "tier<TAB>package" rows for the requested tiers on this package manager.
deps_rows() { # <column> <tiers-csv>
    local col="$1" tiers="$2" manifest canonical apt apk pacman dnf xbps emerge tier cmds pkg
    manifest=$(deps_manifest_path) || return 1
    while IFS=$'\t' read -r canonical apt apk pacman dnf xbps emerge tier cmds || [ -n "${canonical:-}" ]; do
        case "${canonical:-}" in ''|'#'*) continue ;; esac
        case ",${tiers}," in *",${tier:-},"*) ;; *) continue ;; esac
        case "$col" in
            2) pkg="$apt" ;; 3) pkg="$apk" ;; 4) pkg="$pacman" ;;
            5) pkg="$dnf" ;; 6) pkg="$xbps" ;; 7) pkg="$emerge" ;;
            *) return 1 ;;
        esac
        [ -n "${pkg:-}" ] || continue
        [ "$pkg" = "-" ] || printf '%s\t%s\n' "$tier" "$pkg"
    done < "$manifest"
}

# Missing commands declared by the manifest, one "tier:command" per line.
# The manifest may split a "commands" field on "|": entries before the bar are
# mandatory, entries after it are advisory and reported as "soft:tier:command".
deps_missing_commands() { # <tiers-csv>
    local tiers="$1" manifest canonical apt apk pacman dnf xbps emerge tier cmds
    manifest=$(deps_manifest_path) || return 1
    while IFS=$'\t' read -r canonical apt apk pacman dnf xbps emerge tier cmds || [ -n "${canonical:-}" ]; do
        case "${canonical:-}" in ''|'#'*) continue ;; esac
        case ",${tiers}," in *",${tier:-},"*) ;; *) continue ;; esac
        [ -n "${cmds:-}" ] || continue
        [ "$cmds" = "-" ] && continue
        deps_missing_commands_group "$tier" '' "${cmds%%|*}"
        case "$cmds" in
            *'|'*) deps_missing_commands_group "$tier" 'soft:' "${cmds#*|}" ;;
        esac
    done < "$manifest"
}

deps_missing_commands_group() { # <tier> <prefix> <comma-list>
    local tier="$1" prefix="$2" list="$3" cmd
    while [ -n "$list" ]; do
        case "$list" in
            *,*) cmd=${list%%,*}; list=${list#*,} ;;
            *)   cmd=$list; list='' ;;
        esac
        [ -n "$cmd" ] || continue
        command -v "$cmd" >/dev/null 2>&1 || printf '%s%s:%s\n' "$prefix" "$tier" "$cmd"
    done
}

# Non-core packages are best-effort: a name a distribution does not ship must
# not abort the whole install. Unavailable packages are reported and skipped.
# Kept for compatibility with earlier callers: every tier now behaves this way
# (unavailable packages are skipped and reported), so this is a thin alias.
install_native_packages_tolerant() { # <pm> <label> <packages...>
    local pm="$1" label="$2"
    shift 2
    [ "$#" -gt 0 ] || return 0
    info "Installing $label package(s)"
    install_native_packages "$pm" "$@" || true
    return 0
}

deps_install_tier() { # <pm> <tier> <packages...>
    local pm="$1" tier="$2"
    shift 2
    [ "$#" -gt 0 ] || return 0
    if [ "${SYSTUI_DEPS_DRY_RUN:-0}" = "1" ]; then
        printf '[dry-run] %s (%s): %s\n' "$tier" "$pm" "$*"
        return 0
    fi
    case "$tier" in
        core) install_native_packages "$pm" "$@" ;;
        *)    install_native_packages_tolerant "$pm" "$tier" "$@" ;;
    esac
}

install_dependencies() {
    if [ "${SYSTUI_SKIP_DEPS:-0}" = "1" ]; then
        info "Skipping dependency installation (SYSTUI_SKIP_DEPS=1)"
        return 0
    fi
    local pm col tiers manifest row_file tier pkg
    pm="${SYSTUI_PM_OVERRIDE:-$(detect_pm)}"
    [ -n "$pm" ] || error "Could not detect a package manager. Install dependencies manually or set SYSTUI_PM_OVERRIDE=<apt|apk|pacman|dnf|zypper|xbps|emerge>."
    col=$(deps_family_column "$pm") || error "Unsupported package manager: $pm"
    tiers=$(deps_tiers)

    if ! manifest=$(deps_manifest_path); then
        warn "Dependency manifest is missing (share/systui-deps.tsv); installing the built-in core list."
        install_native_packages "$pm" bash dialog coreutils grep sed gawk findutils tar gzip xz-utils unzip ca-certificates curl
        return 0
    fi

    info "Detected package manager: $pm"
    info "Dependency tiers: $tiers"

    row_file=$(mktemp) || error "Could not create a temporary file for the dependency manifest."
    deps_rows "$col" "$tiers" > "$row_file" || true
    if [ ! -s "$row_file" ]; then
        rm -f "$row_file"
        error "The dependency manifest produced no packages for $pm (tiers: $tiers)."
    fi

    local -a core_pkgs=() toolkit_pkgs=()
    while IFS=$'\t' read -r tier pkg; do
        [ -n "$pkg" ] || continue
        case "$tier" in
            core) core_pkgs+=("$pkg") ;;
            *)    toolkit_pkgs+=("$pkg") ;;
        esac
    done < "$row_file"
    rm -f "$row_file"

    deps_install_tier "$pm" core "${core_pkgs[@]}"
    [ "${#toolkit_pkgs[@]}" -eq 0 ] || deps_install_tier "$pm" toolkit "${toolkit_pkgs[@]}"
    success "Dependency installation complete"
}

check_command() { command -v "$1" >/dev/null 2>&1; }

verify_dependencies() {
    info "Verifying dependencies..."
    local tiers manifest entry tier cmd missing_commands="" cmd_list
    tiers=$(deps_tiers)
    if manifest=$(deps_manifest_path); then
        cmd_list=$(mktemp) || cmd_list=""
        if [ -n "$cmd_list" ]; then
            deps_missing_commands "$tiers" > "$cmd_list" 2>/dev/null || true
            while IFS= read -r entry; do
                [ -n "$entry" ] || continue
                case "$entry" in
                    soft:*)
                        entry=${entry#soft:}
                        warn "Optional ${entry%%:*} command not available: ${entry#*:}"
                        ;;
                    core:*) missing_commands+="${entry#core:} " ;;
                    *) warn "Optional ${entry%%:*} command not available: ${entry#*:}" ;;
                esac
            done < "$cmd_list"
            rm -f "$cmd_list"
        fi
    else
        for cmd in bash dialog sed awk grep cut tr head sort find; do check_command "$cmd" || missing_commands+="$cmd "; done
    fi
    if ! check_command curl && ! check_command wget; then
        warn "Neither curl nor wget is available; network features will be unavailable."
    fi
    if [ -n "$missing_commands" ]; then
        warn "Commands still missing after the dependency step: $missing_commands"
        warn "Menus that need them report their tool as unavailable; the rest of systui works normally."
        if [ "${SYSTUI_DEPS_STRICT:-0}" = "1" ]; then
            error "Missing required commands: $missing_commands"
        fi
    fi
    deps_report_skipped
    success "Dependency check finished"
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
BACKTITLE="${SYSTUI_ENVIRONMENT:-linux} · systui v${SYSTUI_VERSION:-dev}"
export BACKTITLE
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
tui_refresh_terminal_size >/dev/null
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
            health) tui_call_menu menu_health "System Health" ;;
            provision) tui_call_menu menu_ultimate_provision "Ultimate Provision" ;;
            rootfs) tui_call_menu menu_rootfs "Root Filesystems" ;;
            config) tui_call_menu menu_sysconfig "System Configuration" ;;
            performance) tui_call_menu menu_performance "Performance tuning" ;;
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
    local deps_only=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --deps-only) deps_only=1 ;;
            --dry-run) SYSTUI_DEPS_DRY_RUN=1 ;;
            --minimal) SYSTUI_MINIMAL_DEPS=1 ;;
            --no-deps) SYSTUI_SKIP_DEPS=1 ;;
            -h|--help) usage; return 0 ;;
            *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; return 2 ;;
        esac
        shift
    done
    echo "========== systui Installation =========="
    echo "Version: $SYSTUI_VERSION"
    require_root
    install_dependencies
    if [ "${SYSTUI_DEPS_DRY_RUN:-0}" != "1" ]; then
        verify_dependencies
    fi
    if [ "$deps_only" -eq 1 ]; then
        success "Dependency setup complete (--deps-only)"
        return 0
    fi
    install_project
    create_executable
    create_manpage
    cleanup
}

main "$@"