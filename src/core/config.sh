#!/bin/bash
###############################################################################
# systui — Core Configuration & System Detection
###############################################################################

# Strict mode is deliberately NOT enabled here.
#
# config.sh is sourced by the interactive TUI, and `dialog` returns 1 on Cancel
# and 255 on ESC as ordinary control flow. Under a shell-wide `set -e` plus an
# ERR trap, any call site that forgets `|| ...` turns a user pressing Escape
# into a fatal error and a full exit. Provisioning routines -- which do want
# fail-fast semantics -- opt in explicitly via run_strict() below.

# Root of the installed tree, so run_strict can re-source it in a child shell.
SYSTUI_LIBDIR="${SYSTUI_LIBDIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export SYSTUI_LIBDIR

# Project info
if [ -r "$SYSTUI_LIBDIR/src/VERSION" ]; then
    SYSTUI_VERSION=$(head -n1 "$SYSTUI_LIBDIR/src/VERSION" | tr -d '[:space:]')
else
    SYSTUI_VERSION="dev"
fi
SYSTUI_TITLE="systui — Linux System TUI"
BACKTITLE="iSH-AOK · systui v${SYSTUI_VERSION}"
export SYSTUI_TITLE BACKTITLE

# Logging. Never trust a caller-provided SYSTUI_TMP as an owned directory: the
# application runs as root and removes its workspace on exit. Callers may
# choose the parent directory through SYSTUI_TMP_ROOT or TMPDIR instead.
SYSTUI_TMP_ROOT="${SYSTUI_TMP_ROOT:-${TMPDIR:-/tmp}}"
[ -d "$SYSTUI_TMP_ROOT" ] || { echo "Temporary directory does not exist: $SYSTUI_TMP_ROOT" >&2; exit 1; }
SYSTUI_TMP_ROOT=$(cd -- "$SYSTUI_TMP_ROOT" && pwd -P)
# A run_strict child re-sources this file. It must reuse the workspace that the
# parent created and own neither its creation nor its removal -- otherwise each
# strict routine would leak a directory, and the child's EXIT would delete a
# workspace the parent is still using. Note this is keyed off an internal flag,
# not off SYSTUI_TMP itself: a caller-provided SYSTUI_TMP is still never
# adopted (see tests/test-regressions.sh).
if [ "${SYSTUI_STRICT_CHILD:-0}" = 1 ] && [ -n "${SYSTUI_TMP:-}" ] && [ -f "${SYSTUI_TMP}/.systui-owned" ]; then
    SYSTUI_TMP_INHERITED=1
else
    SYSTUI_TMP_INHERITED=0
    SYSTUI_TMP=$(mktemp -d "$SYSTUI_TMP_ROOT/systui.XXXXXX") || exit 1
    chmod 700 "$SYSTUI_TMP"
    : > "$SYSTUI_TMP/.systui-owned"
fi
export SYSTUI_TMP
# The log must outlive the workspace: the EXIT trap removes $SYSTUI_TMP, and
# run_cmd tells the user to go read $LOGFILE after a failure. Prefer a durable
# location, fall back to the workspace only if that is not writable.
systui_pick_logfile() {
    local candidate
    for candidate in "${SYSTUI_LOGFILE:-}" /var/log/systui.log "$HOME/.local/state/systui.log"; do
        [ -n "$candidate" ] || continue
        mkdir -p "$(dirname "$candidate")" 2>/dev/null || continue
        if { : >> "$candidate"; } 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    printf '%s\n' "$SYSTUI_TMP/systui.log"
}
LOGFILE=$(systui_pick_logfile)
WARNFILE="$SYSTUI_TMP/systui.warnings"
chmod 0640 "$LOGFILE" 2>/dev/null || true
log_rotate_if_large() {
    local max=$((5 * 1024 * 1024)) size
    size=$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)
    [ "${size:-0}" -gt "$max" ] && mv -f "$LOGFILE" "$LOGFILE.1" 2>/dev/null && : > "$LOGFILE"
    return 0
}
log_rotate_if_large
: > "$WARNFILE"
cleanup_systui_tmp() {
    [ "${SYSTUI_TMP_INHERITED:-0}" = 1 ] && return 0
    case "${SYSTUI_TMP:-}" in
        "$SYSTUI_TMP_ROOT"/systui.*)
            [ -f "$SYSTUI_TMP/.systui-owned" ] && rm -rf -- "$SYSTUI_TMP"
            ;;
    esac
}
trap cleanup_systui_tmp EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Dialog
export DIALOG="${DIALOG:-dialog}"

# Colors (for manual terminal output)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
export RED GREEN YELLOW BLUE CYAN NC

###############################################################################
# LOGGING & ERROR HANDLING
###############################################################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"
}

warn() {
    echo "$*" >> "$WARNFILE"
    log "WARN: $*"
}

die() {
    log "FATAL: $*"
    echo -e "${RED}Fatal: $*${NC}" >&2
    exit 1
}

###############################################################################
# STRICT EXECUTION (legacy bootstrap; replaced by src/core/strict-exec.sh)
###############################################################################

run_strict() {
    local desc="$1" fn="$2"; shift 2
    if ! declare -F "$fn" >/dev/null; then
        warn "run_strict: no such function: $fn"
        return 127
    fi
    SYSTUI_STRICT_CHILD=1 \
    SYSTUI_TMP="$SYSTUI_TMP" \
    SYSTUI_LIBDIR="$SYSTUI_LIBDIR" \
    SYSTUI_LOGFILE="$LOGFILE" \
    SYSTUI_STRICT_DESC="$desc" \
    bash -c '
        set -eE
        . "$SYSTUI_LIBDIR/src/core/config.sh"
        . "$SYSTUI_LIBDIR/src/core/tui-widgets.sh"
        . "$SYSTUI_LIBDIR/src/core/common.sh"
        _manifest="$SYSTUI_LIBDIR/src/features/.load-order"
        [ -r "$_manifest" ] || { echo "systui: missing feature load manifest" >&2; exit 1; }
        while IFS= read -r _rel || [ -n "$_rel" ]; do
            case "$_rel" in ""|\#*) continue ;; esac
            _f="$SYSTUI_LIBDIR/src/features/$_rel"
            [ -f "$_f" ] || { echo "systui: manifest references missing feature: $_rel" >&2; exit 1; }
            . "$_f" || exit 1
        done < "$_manifest"
        detect_pm; detect_init; detect_distro
        trap '"'"'warn "$SYSTUI_STRICT_DESC: unexpected error on line $LINENO"; exit 1'"'"' ERR
        "$@"
    ' _ "$fn" "$@"
}

###############################################################################
# SYSTEM DETECTION
###############################################################################

detect_pm() {
    if command -v apt-get >/dev/null 2>&1; then PM="apt"
    elif command -v apk >/dev/null 2>&1; then PM="apk"
    elif command -v pacman >/dev/null 2>&1; then PM="pacman"
    elif command -v dnf >/dev/null 2>&1; then PM="dnf"
    elif command -v zypper >/dev/null 2>&1; then PM="zypper"
    elif command -v yum >/dev/null 2>&1; then PM="yum"
    elif command -v xbps-install >/dev/null 2>&1; then PM="xbps"
    elif command -v emerge >/dev/null 2>&1; then PM="emerge"
    else PM=""; fi
    export PM
    log "Detected package manager: $PM"
}

detect_init() {
    if [ -d /run/systemd/system ]; then INIT="systemd"
    elif command -v rc-service >/dev/null 2>&1; then INIT="openrc"
    elif command -v service >/dev/null 2>&1 && [ -d /etc/init.d ]; then INIT="sysvinit"
    elif command -v sv >/dev/null 2>&1 && { [ -d /etc/sv ] || [ -d /var/service ] || [ -d /service ]; }; then INIT="runit"
    else INIT=""; fi
    export INIT
    log "Detected init system: $INIT"
}

detect_distro() {
    local os_release="" id="" id_like="" version_id="" pretty_name=""

    if [ -r /etc/os-release ]; then os_release=/etc/os-release
    elif [ -r /usr/lib/os-release ]; then os_release=/usr/lib/os-release
    fi

    if [ -n "$os_release" ]; then
        id=$(sed -n 's/^ID=//p' "$os_release" | head -n1 | tr -d '"' | tr '[:upper:]' '[:lower:]')
        id_like=$(sed -n 's/^ID_LIKE=//p' "$os_release" | head -n1 | tr -d '"' | tr '[:upper:]' '[:lower:]')
        version_id=$(sed -n 's/^VERSION_ID=//p' "$os_release" | head -n1 | tr -d '"')
        pretty_name=$(sed -n 's/^PRETTY_NAME=//p' "$os_release" | head -n1 | sed 's/^"//;s/"$//')
    fi

    if [ -z "$id" ]; then
        if [ -r /etc/devuan_version ]; then id=devuan
        elif [ -r /etc/debian_version ]; then id=debian
        elif [ -r /etc/alpine-release ]; then id=alpine
        elif [ -r /etc/arch-release ]; then id=archlinux
        elif [ -r /etc/fedora-release ]; then id=fedora
        elif [ -r /etc/gentoo-release ]; then id=gentoo
        elif command -v xbps-install >/dev/null 2>&1; then id=void
        else id=unknown
        fi
    fi

    DISTRO="$id"
    DISTRO_ID_LIKE="$id_like"
    DISTRO_VERSION="${version_id:-unknown}"
    DISTRO_PRETTY_NAME="${pretty_name:-$id}"
    export DISTRO DISTRO_ID_LIKE DISTRO_VERSION DISTRO_PRETTY_NAME
    log "Detected distro: $DISTRO ($DISTRO_PRETTY_NAME), version=$DISTRO_VERSION, like=$DISTRO_ID_LIKE"
}

###############################################################################
# CONFIG STORAGE
###############################################################################

systui_config_dir() {
    if [ "$(id -u)" -eq 0 ]; then printf '/etc/systui\n'; else printf '%s/.config/systui\n' "$HOME"; fi
}

systui_config_file() { printf '%s/config\n' "$(systui_config_dir)"; }

get_config() {
    local key="$1" default="${2:-}" file line
    file=$(systui_config_file)
    [ -r "$file" ] || { printf '%s\n' "$default"; return; }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "$key="*) printf '%s\n' "${line#*=}"; return;; esac
    done < "$file"
    printf '%s\n' "$default"
}

set_config() {
    local key="$1" value="$2" dir file tmp
    case "$key" in ''|*[!A-Za-z0-9_.-]*) return 2;; esac
    [ "$value" != *$'\n'* ] && [ "$value" != *$'\r'* ] || return 2
    dir=$(systui_config_dir); file="$dir/config"
    mkdir -p "$dir" || return 1
    [ -f "$file" ] || : > "$file"
    tmp=$(mktemp "$dir/.config.XXXXXX") || return 1
    SYSTUI_CFG_KEY="$key" SYSTUI_CFG_VAL="$value" awk '
        BEGIN { key = ENVIRON["SYSTUI_CFG_KEY"]; val = ENVIRON["SYSTUI_CFG_VAL"]; done = 0 }
        index($0, key "=") == 1 { if (!done) { print key "=" val; done = 1 } ; next }
        { print }
        END { if (!done) print key "=" val }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file"
}

# Core functions are sourced where needed. Do not export Bash function bodies:
# serialized BASH_FUNC_* entries are a major ARG_MAX failure source on iSH-AOK.
