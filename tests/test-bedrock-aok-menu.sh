#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

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

# Minimal widget stubs: the feature saves these definitions and wraps them.
tui_menu() { printf '%s\n' "${SYSTUI_TEST_MENU_RESULT:-back}"; }
tui_check() { printf '%s\n' "${SYSTUI_TEST_CHECK_RESULT:-}"; }

# shellcheck source=../src/features/zzz-bedrock-aok.sh
source "$PROJECT_DIR/src/features/zzz-bedrock-aok.sh"

check "dedicated Bedrock-AOK menu is exposed" declare -F menu_bedrock_aok
check "install workflow is exposed" declare -F bedrock_aok_install
check "strata workflow is exposed" declare -F bedrock_aok_strata_menu
check "feature checklist workflow is exposed" declare -F bedrock_aok_features_menu
check "rollback workflow is exposed" declare -F bedrock_aok_rollback_menu

# Rootfs Builder distro picker must silently remove its old Bedrock entry while
# preserving every other distro triplet.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
_systui_bedrock_orig_tui_check() {
    printf '%s\n' "$@" > "$tmp/check-args"
    printf 'debian\n'
}
result=$(tui_check "Rootfs Builder 1/13" "Select distros" \
    debian "Debian" on \
    bedrock "Bedrock Linux" off \
    alpine "Alpine" off)
check "Rootfs picker still returns a normal selection" test "$result" = debian
check "Rootfs picker removes Bedrock tag" bash -c "! grep -qx bedrock '$tmp/check-args'"
check "Rootfs picker keeps Debian" grep -qx debian "$tmp/check-args"
check "Rootfs picker keeps Alpine" grep -qx alpine "$tmp/check-args"

# The top-level menu wrapper inserts Bedrock before Quit, consumes that choice
# locally, opens menu_bedrock_aok, then returns the next ordinary main choice.
: > "$tmp/main-count"
_systui_bedrock_orig_tui_menu() {
    printf '%s\n' "$@" > "$tmp/main-args"
    if [ ! -s "$tmp/main-count" ]; then
        printf x > "$tmp/main-count"
        printf 'bedrock\n'
    else
        printf 'quit\n'
    fi
}
menu_bedrock_aok() { printf opened > "$tmp/bedrock-opened"; }
main_result=$(tui_menu "Main Menu" "systui — choose a section:" rootfs "Rootfs Builder" quit "Quit")
check "main-menu wrapper returns non-Bedrock choice" test "$main_result" = quit
check "main-menu wrapper inserts Bedrock entry" grep -qx bedrock "$tmp/main-args"
check "Bedrock choice opens dedicated menu" test -f "$tmp/bedrock-opened"

# Static guards for the requested SPACE-to-select workflows and upstream source.
feature="$PROJECT_DIR/src/features/zzz-bedrock-aok.sh"
check "uses requested Bedrock-AOK template repository" grep -Fq 'vjnzbcsbgf-maker/Bedrock-AOK' "$feature"
check "install extras use a checklist" grep -Fq 'Bedrock-AOK additional features' "$feature"
check "feature maintenance uses a checklist" grep -Fq 'Bedrock-AOK features' "$feature"
check "strata fetching uses a checklist" grep -Fq 'Fetch Bedrock-AOK strata' "$feature"
check "supports reversible edition" grep -Fq 'reversible "Reversible' "$feature"
check "supports permanent edition" grep -Fq 'permanent  "Permanent' "$feature"

if [ "$failures" -ne 0 ]; then
    printf '%d/%d checks failed\n' "$failures" "$checks" >&2
    exit 1
fi
printf 'All %d Bedrock-AOK menu checks passed.\n' "$checks"
