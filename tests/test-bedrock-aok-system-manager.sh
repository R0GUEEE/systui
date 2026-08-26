#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

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
source "$PROJECT_DIR/src/features/zzzzzz-bedrock-aok-system-manager.sh"

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

has_system_manager_entry() {
    declare -f menu_bedrock_aok | grep -q 'Unified system manager (all/multiple strata)'
}
check "Bedrock menu exposes unified system manager" has_system_manager_entry

has_config_entry() {
    local body
    body=$(declare -f menu_bedrock_aok)
    grep -q 'Manage Bedrock-AOK configuration' <<<"$body" &&
    grep -q 'config)' <<<"$body" &&
    grep -q 'bedrock_aok_config_menu' <<<"$body"
}
check "Bedrock menu exposes config management entry" has_config_entry

has_bulk_update() {
    local body
    body=$(declare -f bedrock_aok_bulk_update)
    grep -q 'Update all Bedrock-AOK strata' <<<"$body" &&
    grep -q 'Choose strata to update' <<<"$body"
}
check "bulk update supports all and selected strata" has_bulk_update

has_bulk_packages() {
    local body
    body=$(declare -f bedrock_aok_bulk_install_packages)
    grep -q 'Choose target strata' <<<"$body" &&
    grep -q 'Install into \$st' <<<"$body"
}
check "bulk package install targets multiple strata" has_bulk_packages

has_system_maintenance() {
    local body
    body=$(declare -f bedrock_aok_bulk_health_fix)
    grep -q 'Health-check all strata' <<<"$body" &&
    grep -q 'Fix \$st' <<<"$body" &&
    grep -q 'Unmount all strata' <<<"$body"
}
check "system maintenance covers health fix and unmount" has_system_maintenance

has_cross_access_bulk() {
    local body
    body=$(declare -f bedrock_aok_cross_access_menu)
    grep -q 'Enable cross-command access for all strata' <<<"$body" &&
    grep -q 'Disable cross-command access for all strata' <<<"$body" &&
    grep -q 'Reload unified wrappers' <<<"$body"
}
check "unified cross-command access can manage all strata" has_cross_access_bulk

has_multi_remove() {
    local body
    body=$(declare -f bedrock_aok_bulk_remove)
    grep -q 'Select strata to remove' <<<"$body" &&
    grep -q 'Remove \$st' <<<"$body"
}
check "bulk removal uses multi-select" has_multi_remove

has_overview() {
    local body
    body=$(declare -f bedrock_aok_system_overview)
    grep -q 'Per-stratum summary' <<<"$body" &&
    grep -q 'Health' <<<"$body"
}
check "system overview combines strata and health" has_overview

printf '%d checks, %d failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
