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

printf '%d checks, %d failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
