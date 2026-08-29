#!/bin/bash
###############################################################################
# systui — TUI Widget Framework (dialog-based)
###############################################################################

###############################################################################
# DIALOG WRAPPERS
###############################################################################

tui_msg() {
    # Simple message dialog: tui_msg <title> <message>
    $DIALOG --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" 10 60
}

tui_yesno() {
    # Yes/No dialog: tui_yesno <title> <question>
    # Returns: 0 (yes) or 1 (no)
    $DIALOG --backtitle "$BACKTITLE" --title "$1" --yesno "$2" 8 60
}

tui_input() {
    # Input dialog: tui_input <title> <prompt> [default]
    # Returns: input text or empty
    $DIALOG --backtitle "$BACKTITLE" --title "$1" --inputbox "$2" 10 60 "${3:-}" 3>&1 1>&2 2>&3
}

tui_password() {
    # Password input (masked): tui_password <title> <prompt>
    $DIALOG --backtitle "$BACKTITLE" --title "$1" --passwordbox "$2" 10 60 3>&1 1>&2 2>&3
}

tui_menu() {
    # Menu selection: tui_menu <title> <text> <tag1> <desc1> [...]
    # Returns: selected tag
    local title="$1" text="$2"; shift 2
    $DIALOG --backtitle "$BACKTITLE" --title "$title" \
        --menu "$text" 22 74 14 "$@" 3>&1 1>&2 2>&3
}

# Menu that hides internal selection tags and displays only descriptions.
# Useful when tags are generated IDs that should not appear in the UI.
tui_menu_no_tags() {
    local title="$1" text="$2"; shift 2
    $DIALOG --backtitle "$BACKTITLE" --title "$title" --no-tags \
        --menu "$text" 22 90 14 "$@" 3>&1 1>&2 2>&3
}

tui_radio() {
    # Radio list (single choice): tui_radio <title> <text> <tag1> <desc1> <on|off> [...]
    # Returns: selected tag
    local title="$1" text="$2"; shift 2
    $DIALOG --backtitle "$BACKTITLE" --title "$title" \
        --radiolist "$text" 22 74 14 "$@" 3>&1 1>&2 2>&3
}

tui_check() {
    # Checkbox list (multiple choice): tui_check <title> <text> <tag1> <desc1> <on|off> [...]
    # Returns: space-separated selected tags
    local title="$1" text="$2"; shift 2
    $DIALOG --backtitle "$BACKTITLE" --title "$title" \
        --checklist "$text" 22 74 14 "$@" 3>&1 1>&2 2>&3
}

tui_text() {
    # Text viewer (scrollable): tui_text <title> <file>
    $DIALOG --backtitle "$BACKTITLE" --title "$1" --textbox "$2" 22 76
}

tui_progress() {
    # Progress gauge: tui_progress <title> <text> [percent]
    $DIALOG --backtitle "$BACKTITLE" --title "$1" --gauge "$2" 10 60 "${3:-0}"
}

###############################################################################
# COMMAND EXECUTION WITH OUTPUT
###############################################################################

run_cmd() {
    # run_cmd <description> <cmd...>
    # Executes command with visual output, logs it, reports success/failure.
    # Preserve the caller's errexit state: the interactive TUI deliberately
    # runs without `set -e`, while run_strict children deliberately enable it.
    local desc="$1"; shift
    local rc=0 had_errexit=0
    case $- in *e*) had_errexit=1 ;; esac

    log "RUN: $desc :: $*"
    clear
    echo ">>> $desc"
    echo ">>> $*"
    echo "================================================================="

    # Keep the pipeline out of errexit handling and capture the command's
    # status rather than tee's. Restore exactly the shell state we inherited.
    set +e
    "$@" 2>&1 | tee -a "$LOGFILE"
    rc=${PIPESTATUS[0]}
    if [ "$had_errexit" -eq 1 ]; then
        set -e
    else
        set +e
    fi

    if [ "$rc" -eq 0 ]; then
        echo "================================================================="
        echo "Done: $desc"
        return 0
    fi
    echo "================================================================="
    log "FAILED ($rc): $desc"
    read -rp "FAILED ($rc): $desc — see $LOGFILE  (press Enter)" _ || true
    return "$rc"
}

###############################################################################
# CONFIRMATION DIALOGS
###############################################################################

tui_confirm() {
    # Confirm with description: tui_confirm <title> <message>
    # Returns: 0 (confirmed) or 1 (cancelled)
    if tui_yesno "$1" "$2"; then
        return 0
    else
        return 1
    fi
}

tui_wait() {
    # Show a wait message and wait for user to press Enter
    local msg="${1:-Press Enter to continue...}"
    read -rp "$msg" _ 2>/dev/null || true
}

export -f tui_msg tui_yesno tui_input tui_password tui_menu tui_menu_no_tags tui_radio tui_check tui_text tui_progress run_cmd tui_confirm tui_wait
