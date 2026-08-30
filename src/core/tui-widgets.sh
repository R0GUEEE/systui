#!/bin/bash
###############################################################################
# systui — TUI Widget Framework (dialog-based)
###############################################################################

###############################################################################
# RESPONSIVE TERMINAL GEOMETRY
###############################################################################

tui_rows() {
    local rows=""
    if command -v tput >/dev/null 2>&1; then rows=$(tput lines 2>/dev/null || true); fi
    if [[ ! "$rows" =~ ^[0-9]+$ ]] && command -v stty >/dev/null 2>&1; then
        rows=$(stty size 2>/dev/null | { read -r r _; printf '%s' "$r"; } || true)
    fi
    [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
    [ "$rows" -ge 12 ] || rows=12
    printf '%s\n' "$rows"
}

tui_cols() {
    local cols=""
    if command -v tput >/dev/null 2>&1; then cols=$(tput cols 2>/dev/null || true); fi
    if [[ ! "$cols" =~ ^[0-9]+$ ]] && command -v stty >/dev/null 2>&1; then
        cols=$(stty size 2>/dev/null | { read -r _ c; printf '%s' "$c"; } || true)
    fi
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    [ "$cols" -ge 40 ] || cols=40
    printf '%s\n' "$cols"
}

tui_geometry() { # <kind> -> "height width list-height"
    local kind="${1:-menu}" rows cols h w list
    rows=$(tui_rows); cols=$(tui_cols)
    h=$((rows - 2)); [ "$h" -gt 22 ] && h=22; [ "$h" -lt 10 ] && h=10
    w=$((cols - 4)); [ "$w" -gt 90 ] && w=90; [ "$w" -lt 38 ] && w=38
    list=$((h - 8)); [ "$list" -gt 14 ] && list=14; [ "$list" -lt 4 ] && list=4
    case "$kind" in
        msg|input|password|yesno|progress)
            [ "$h" -gt 12 ] && h=12
            [ "$w" -gt 70 ] && w=70
            list=0
            ;;
        text)
            h=$((rows - 2)); [ "$h" -gt 24 ] && h=24; [ "$h" -lt 10 ] && h=10
            w=$((cols - 2)); [ "$w" -gt 100 ] && w=100; [ "$w" -lt 38 ] && w=38
            list=0
            ;;
    esac
    printf '%s %s %s\n' "$h" "$w" "$list"
}

###############################################################################
# DIALOG WRAPPERS
###############################################################################

tui_msg() {
    local h w _; read -r h w _ < <(tui_geometry msg)
    "$DIALOG" --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" "$h" "$w"
}

tui_yesno() {
    local h w _; read -r h w _ < <(tui_geometry yesno)
    "$DIALOG" --backtitle "$BACKTITLE" --title "$1" --yesno "$2" "$h" "$w"
}

tui_input() {
    local h w _; read -r h w _ < <(tui_geometry input)
    "$DIALOG" --backtitle "$BACKTITLE" --title "$1" --inputbox "$2" "$h" "$w" "${3:-}" 3>&1 1>&2 2>&3
}

tui_password() {
    local h w _; read -r h w _ < <(tui_geometry password)
    "$DIALOG" --backtitle "$BACKTITLE" --title "$1" --passwordbox "$2" "$h" "$w" 3>&1 1>&2 2>&3
}

tui_menu() {
    local title="$1" text="$2" h w list; shift 2
    read -r h w list < <(tui_geometry menu)
    "$DIALOG" --backtitle "$BACKTITLE" --title "$title" --menu "$text" "$h" "$w" "$list" "$@" 3>&1 1>&2 2>&3
}

tui_menu_no_tags() {
    local title="$1" text="$2" h w list; shift 2
    read -r h w list < <(tui_geometry menu)
    "$DIALOG" --backtitle "$BACKTITLE" --title "$title" --no-tags --menu "$text" "$h" "$w" "$list" "$@" 3>&1 1>&2 2>&3
}

tui_radio() {
    local title="$1" text="$2" h w list; shift 2
    read -r h w list < <(tui_geometry menu)
    "$DIALOG" --backtitle "$BACKTITLE" --title "$title" --radiolist "$text" "$h" "$w" "$list" "$@" 3>&1 1>&2 2>&3
}

tui_check() {
    local title="$1" text="$2" h w list; shift 2
    read -r h w list < <(tui_geometry menu)
    "$DIALOG" --backtitle "$BACKTITLE" --title "$title" --checklist "$text" "$h" "$w" "$list" "$@" 3>&1 1>&2 2>&3
}

tui_text() {
    local h w _; read -r h w _ < <(tui_geometry text)
    "$DIALOG" --backtitle "$BACKTITLE" --title "$1" --textbox "$2" "$h" "$w"
}

tui_progress() {
    local h w _; read -r h w _ < <(tui_geometry progress)
    "$DIALOG" --backtitle "$BACKTITLE" --title "$1" --gauge "$2" "$h" "$w" "${3:-0}"
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
