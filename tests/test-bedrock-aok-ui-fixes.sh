#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Minimal TUI/runtime stubs.
tui_msg() { :; }
tui_yesno() { return 0; }
tui_input() { printf '%s\n' "${3:-}"; }
tui_menu() { return 1; }
tui_radio() { return 1; }
tui_check() { return 1; }
tui_text() { :; }
run_cmd() { shift; "$@"; }
log() { :; }
warn() { :; }
export SYSTUI_TMP="$(mktemp -d)"
trap 'rm -rf "$SYSTUI_TMP"' EXIT

source "$PROJECT_DIR/src/features/zzz-bedrock-aok.sh"
source "$PROJECT_DIR/src/features/zzzz-bedrock-aok-menu-fixes.sh"
source "$PROJECT_DIR/src/features/zzzzz-bedrock-aok-ui-fixes.sh"

failures=0
checks=0
check() {
    local desc="$1"; shift
    checks=$((checks + 1))
    if "$@"; then
        printf 'ok %d - %s\n' "$checks" "$desc"
    else
        printf 'not ok %d - %s\n' "$checks" "$desc"
        failures=$((failures + 1))
    fi
}

list_uses_text_viewer() {
    local body
    body=$(declare -f bedrock_aok_list_strata_menu)
    grep -q 'tui_text "Installed Bedrock-AOK strata"' <<<"$body" &&
    ! grep -q 'run_cmd .* list' <<<"$body"
}
check "strata list uses persistent dialog text viewer" list_uses_text_viewer

readonly_actions_use_viewer() {
    local body
    body=$(declare -f bedrock_aok_strata_menu)
    # declare -f normalizes spacing around `|` and redirections.
    grep -Eq 'status[[:space:]]*\|[[:space:]]*show\)' <<<"$body" &&
    grep -q 'bedrock_aok_view_command' <<<"$body"
}
check "status/show render in dialog viewers" readonly_actions_use_viewer

shell_attaches_tty() {
    # declare -f prints redirections with spaces: < /dev/tty > /dev/tty 2> /dev/tty
    declare -f bedrock_aok_strata_menu \
        | grep -qE '[[:space:]]<[[:space:]]*/dev/tty[[:space:]]*>[[:space:]]*/dev/tty[[:space:]]*2?>[[:space:]]*/dev/tty'
}
check "interactive stratum shell attaches directly to tty" shell_attaches_tty

main_bedrock_attaches_tty() {
    local body
    body=$(declare -f tui_menu)
    # declare -f prints: menu_bedrock_aok < /dev/tty > /dev/tty 2> /dev/tty
    grep -qE 'menu_bedrock_aok[[:space:]]+<[[:space:]]*/dev/tty[[:space:]]+>[[:space:]]*/dev/tty[[:space:]]+2>?[[:space:]]*/dev/tty' <<<"$body"
}
check "nested Bedrock main menu bypasses command-substitution capture" main_bedrock_attaches_tty

# --- Config management + info-menu crash fix (added in this layer) -------------
config_menu_functions_exist() {
    declare -F bedrock_aok_config_menu >/dev/null &&
    declare -F bedrock_aok_config_edit >/dev/null &&
    declare -F bedrock_aok_config_view >/dev/null
}
check "config management functions are defined" config_menu_functions_exist

config_menu_uses_runtime_actions() {
    local body
    body=$(declare -f bedrock_aok_config_menu)
    grep -q 'bedrock_aok_run "Reload Bedrock-AOK" reload' <<<"$body" &&
    grep -q 'bedrock_aok_rollback_menu' <<<"$body"
}
check "config menu exposes reload and rollback" config_menu_uses_runtime_actions

info_menu_uses_viewer_not_run_cmd() {
    local body
    body=$(declare -f bedrock_aok_info_menu)
    # All read-only reports must render through the persistent viewer, never the
    # terminal-dumping run_cmd (which crashes the Bedrock menu's subshell).
    [ "$(grep -c 'bedrock_aok_view_command' <<<"$body")" -ge 1 ] &&
    ! grep -q 'run_cmd' <<<"$body"
}
check "info menu renders reports via viewer (no run_cmd crash)" info_menu_uses_viewer_not_run_cmd

info_menu_selects_version_through_viewer() {
    # Drive the menu to "version": tui_menu must return "version" then "back".
    # Because tui_menu runs inside $(...) (a subshell), persist state in a file.
    local state="$SYSTUI_TMP/info-call"; : > "$state"
    local seen=0
    tui_menu() {
        if [ -s "$state" ]; then echo back; else printf x > "$state"; echo version; fi
    }
    local got=""
    bedrock_aok_view_command() { got="${got}${got:+ }$1[$2]"; }
    bedrock_aok_run() { got="${got}${got:+ }RUN:$1"; }
    bedrock_aok_rollback_menu() { got="${got}${got:+ }ROLLBACK"; }
    # bedrock_aok_view_command runs "$brl" "$@"; stub brl to a no-op script.
    local fake="$SYSTUI_TMP/brl"; : > "$fake"; chmod 0755 "$fake"
    bedrock_aok_brl() { printf '%s\n' "$fake"; }
    bedrock_aok_require() { return 0; }
    bedrock_aok_info_menu
    # Expect exactly the version viewer invocation (no run_cmd / no crash).
    [ "$got" = "Bedrock-AOK version[version]" ]
}
check "info menu 'version' renders through the viewer" info_menu_selects_version_through_viewer

config_edit_falls_back_to_available_conf() {
    # When the primary brl.conf is absent but another .conf exists, edit must
    # still find something to edit (no crash / empty path).
    local body
    body=$(declare -f bedrock_aok_config_edit)
    grep -q '\*.conf' <<<"$body" && grep -q 'No configuration file found' <<<"$body"
}
check "config edit falls back to any available .conf" config_edit_falls_back_to_available_conf

printf '%d checks, %d failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
