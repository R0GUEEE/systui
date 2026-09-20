#!/bin/bash
###############################################################################
# systui — TUI Widget Framework (dialog-based)
###############################################################################

###############################################################################
# RESPONSIVE TERMINAL GEOMETRY
###############################################################################

# Bash keeps LINES/COLUMNS current after foreground commands when checkwinsize
# is enabled. Prefer those shell variables so ordinary menu redraws require no
# helper processes at all.
shopt -s checkwinsize 2>/dev/null || true

TUI_ROWS_CACHE="${TUI_ROWS_CACHE:-}"
TUI_COLS_CACHE="${TUI_COLS_CACHE:-}"
TUI_ROWS=24
TUI_COLS=80
TUI_H=20
TUI_W=76
TUI_LIST=12

tui_refresh_terminal_size() {
    local rows="${LINES:-}" cols="${COLUMNS:-}" probe
    local root="${SYSTUI_TMP:-${TMPDIR:-/tmp}}"

    if [[ ! "$rows" =~ ^[0-9]+$ ]] && [[ "${TUI_ROWS_CACHE:-}" =~ ^[0-9]+$ ]]; then
        rows="$TUI_ROWS_CACHE"
    fi
    if [[ ! "$cols" =~ ^[0-9]+$ ]] && [[ "${TUI_COLS_CACHE:-}" =~ ^[0-9]+$ ]]; then
        cols="$TUI_COLS_CACHE"
    fi

    # Only probe the terminal when neither Bash nor the cache has dimensions.
    # stty returns both values in one process; tput is a final fallback.
    if [[ ! "$rows" =~ ^[0-9]+$ || ! "$cols" =~ ^[0-9]+$ ]]; then
        probe="$root/.systui-tty-size.$$"
        if command -v stty >/dev/null 2>&1 && stty size > "$probe" 2>/dev/null; then
            read -r rows cols < "$probe" || true
        fi
        if [[ ! "$rows" =~ ^[0-9]+$ ]] && command -v tput >/dev/null 2>&1; then
            if tput lines > "$probe" 2>/dev/null; then read -r rows < "$probe" || true; fi
        fi
        if [[ ! "$cols" =~ ^[0-9]+$ ]] && command -v tput >/dev/null 2>&1; then
            if tput cols > "$probe" 2>/dev/null; then read -r cols < "$probe" || true; fi
        fi
    fi

    [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    [ "$rows" -ge 12 ] || rows=12
    [ "$cols" -ge 40 ] || cols=40

    TUI_ROWS="$rows"
    TUI_COLS="$cols"
    TUI_ROWS_CACHE="$rows"
    TUI_COLS_CACHE="$cols"
}

tui_rows() {
    tui_refresh_terminal_size
    printf '%s\n' "$TUI_ROWS"
}

tui_cols() {
    tui_refresh_terminal_size
    printf '%s\n' "$TUI_COLS"
}

tui_geometry() { # <kind> -> "height width list-height" and TUI_H/TUI_W/TUI_LIST
    local kind="${1:-menu}" h w list
    tui_refresh_terminal_size
    h=$((TUI_ROWS - 2)); [ "$h" -gt 22 ] && h=22; [ "$h" -lt 10 ] && h=10
    w=$((TUI_COLS - 4)); [ "$w" -gt 90 ] && w=90; [ "$w" -lt 38 ] && w=38
    list=$((h - 8)); [ "$list" -gt 14 ] && list=14; [ "$list" -lt 4 ] && list=4
    case "$kind" in
        msg|input|password|yesno|progress)
            [ "$h" -gt 12 ] && h=12
            [ "$w" -gt 70 ] && w=70
            list=0
            ;;
        text)
            h=$((TUI_ROWS - 2)); [ "$h" -gt 24 ] && h=24; [ "$h" -lt 10 ] && h=10
            w=$((TUI_COLS - 2)); [ "$w" -gt 100 ] && w=100; [ "$w" -lt 38 ] && w=38
            list=0
            ;;
    esac
    TUI_H="$h"
    TUI_W="$w"
    TUI_LIST="$list"
    printf '%s %s %s\n' "$h" "$w" "$list"
}

###############################################################################
# DIALOG WRAPPERS
###############################################################################

tui_report_dialog_error() { # <widget> <title> <rc>
    local widget="${1:-dialog}" title="${2:-unknown}" rc="${3:-1}"
    local msg="systui: $widget failed while opening '$title' (dialog exit $rc)"
    printf '%s\n' "$msg" >&2
    if declare -F log >/dev/null 2>&1; then
        log "$msg" 2>/dev/null || true
    fi
}

tui_dialog_status() { # <widget> <title> <rc>
    local widget="$1" title="$2" rc="$3"
    case "$rc" in
        0|1|255) return "$rc" ;;
        *) tui_report_dialog_error "$widget" "$title" "$rc"; return "$rc" ;;
    esac
}

# Run a menu capture from the parent shell. This primes terminal geometry before
# the command-substitution child is created, so the size cache survives menu
# redraws. Cancel/ESC becomes an empty selection; actual dialog failures remain
# non-zero and have already been reported by the widget wrapper.
tui_capture_menu() { # <destination-var> <tui_menu|tui_menu_no_tags> <args...>
    local dest="$1" widget="$2" out='' rc=0
    shift 2
    case "$widget" in tui_menu|tui_menu_no_tags) ;; *) return 2 ;; esac
    tui_refresh_terminal_size
    if out=$("$widget" "$@"); then rc=0; else rc=$?; fi
    case "$rc" in
        0) printf -v "$dest" '%s' "$out"; return 0 ;;
        1|255) printf -v "$dest" '%s' ''; return 0 ;;
        *) printf -v "$dest" '%s' "$out"; return "$rc" ;;
    esac
}

tui_call_menu() { # <function> <label> [args...]
    local fn="$1" label="${2:-$1}"
    shift 2 || true
    if declare -F "$fn" >/dev/null 2>&1; then
        "$fn" "$@"
        return $?
    fi
    local msg="Menu unavailable: $label (missing function: $fn)"
    if declare -F log >/dev/null 2>&1; then log "$msg" 2>/dev/null || true; fi
    if declare -F tui_msg >/dev/null 2>&1 && command -v "${DIALOG:-dialog}" >/dev/null 2>&1; then
        tui_msg "Menu unavailable" "$label could not be loaded.\n\nMissing function: $fn" || true
    else
        printf 'systui: %s\n' "$msg" >&2
    fi
    return 0
}

tui_msg() {
    local h w _; tui_geometry msg >/dev/null; h=$TUI_H; w=$TUI_W
    local rc=0
    "$DIALOG" --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" "$h" "$w" || rc=$?
    tui_dialog_status "msgbox" "$1" "$rc"
}

tui_yesno() {
    local h w _; tui_geometry yesno >/dev/null; h=$TUI_H; w=$TUI_W
    local rc=0
    "$DIALOG" --backtitle "$BACKTITLE" --title "$1" --yesno "$2" "$h" "$w" || rc=$?
    tui_dialog_status "yesno" "$1" "$rc"
}

tui_input() {
    local h w _; tui_geometry input >/dev/null; h=$TUI_H; w=$TUI_W
    local rc=0
    "$DIALOG" --backtitle "$BACKTITLE" --title "$1" --inputbox "$2" "$h" "$w" "${3:-}" 3>&1 1>&2 2>&3 || rc=$?
    tui_dialog_status "inputbox" "$1" "$rc"
}

tui_password() {
    local h w _; tui_geometry password >/dev/null; h=$TUI_H; w=$TUI_W
    local rc=0
    "$DIALOG" --backtitle "$BACKTITLE" --title "$1" --passwordbox "$2" "$h" "$w" 3>&1 1>&2 2>&3 || rc=$?
    tui_dialog_status "passwordbox" "$1" "$rc"
}

tui_menu() {
    local title="$1" text="$2" h w list; shift 2
    tui_geometry menu >/dev/null; h=$TUI_H; w=$TUI_W; list=$TUI_LIST
    local rc=0
    "$DIALOG" --backtitle "$BACKTITLE" --title "$title" --menu "$text" "$h" "$w" "$list" "$@" 3>&1 1>&2 2>&3 || rc=$?
    tui_dialog_status "menu" "$title" "$rc"
}

tui_menu_no_tags() {
    local title="$1" text="$2" h w list; shift 2
    tui_geometry menu >/dev/null; h=$TUI_H; w=$TUI_W; list=$TUI_LIST
    local rc=0
    "$DIALOG" --backtitle "$BACKTITLE" --title "$title" --no-tags --menu "$text" "$h" "$w" "$list" "$@" 3>&1 1>&2 2>&3 || rc=$?
    tui_dialog_status "menu" "$title" "$rc"
}

tui_radio() {
    local title="$1" text="$2" h w list; shift 2
    tui_geometry menu >/dev/null; h=$TUI_H; w=$TUI_W; list=$TUI_LIST
    local rc=0
    "$DIALOG" --backtitle "$BACKTITLE" --title "$title" --radiolist "$text" "$h" "$w" "$list" "$@" 3>&1 1>&2 2>&3 || rc=$?
    tui_dialog_status "radiolist" "$1" "$rc"
}

tui_check() {
    local title="$1" text="$2" h w list; shift 2
    tui_geometry menu >/dev/null; h=$TUI_H; w=$TUI_W; list=$TUI_LIST
    local rc=0
    "$DIALOG" --backtitle "$BACKTITLE" --title "$title" --checklist "$text" "$h" "$w" "$list" "$@" 3>&1 1>&2 2>&3 || rc=$?
    tui_dialog_status "checklist" "$1" "$rc"
}

tui_text() {
    local h w _; tui_geometry text >/dev/null; h=$TUI_H; w=$TUI_W
    local rc=0
    "$DIALOG" --backtitle "$BACKTITLE" --title "$1" --textbox "$2" "$h" "$w" || rc=$?
    tui_dialog_status "textbox" "$1" "$rc"
}

tui_progress() {
    local h w _; tui_geometry progress >/dev/null; h=$TUI_H; w=$TUI_W
    local rc=0
    "$DIALOG" --backtitle "$BACKTITLE" --title "$1" --gauge "$2" "$h" "$w" "${3:-0}" || rc=$?
    tui_dialog_status "gauge" "$1" "$rc"
}

###############################################################################
# COMMAND EXECUTION WITH OUTPUT
###############################################################################

run_cmd() {
    local desc="$1"; shift
    local rc=0 had_errexit=0
    case $- in *e*) had_errexit=1 ;; esac

    log "RUN: $desc :: $*"
    # Do not require TERM/terminfo when commands are run from CI, pipes, or
    # noninteractive provisioning. Clearing is cosmetic and only useful on a TTY.
    if [ -t 1 ] && [ -n "${TERM:-}" ] && command -v clear >/dev/null 2>&1; then
        clear 2>/dev/null || true
    fi
    echo ">>> $desc"
    echo ">>> $*"
    echo "================================================================="

    set +e
    "$@" 2>&1 | tee -a "$LOGFILE"
    rc=${PIPESTATUS[0]}
    if [ "$had_errexit" -eq 1 ]; then set -e; else set +e; fi

    if [ "$rc" -eq 0 ]; then
        echo "================================================================="
        echo "Done: $desc"
        return 0
    fi
    echo "================================================================="
    log "FAILED ($rc): $desc"
    if [ -t 0 ]; then
        read -rp "FAILED ($rc): $desc — see $LOGFILE  (press Enter)" _ || true
    else
        echo "FAILED ($rc): $desc — see $LOGFILE" >&2
    fi
    return "$rc"
}

###############################################################################
# CONFIRMATION DIALOGS
###############################################################################

tui_confirm() { tui_yesno "$1" "$2"; }

tui_wait() {
    local msg="${1:-Press Enter to continue...}"
    read -rp "$msg" _ 2>/dev/null || true
}

# These functions are intentionally NOT exported. Feature files are sourced in
# the same Bash process, so child processes do not need serialized BASH_FUNC_*
# copies. Avoiding export at the source prevents ARG_MAX failures on iSH-AOK.
