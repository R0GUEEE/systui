#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FEATURE="$ROOT/src/features/zzzzzzzzzzzzzzzz-awesome-linux-catalog-integration.sh"
LOAD="$ROOT/src/features/.load-order"

pass=0
fail=0
check() {
    local desc="$1"; shift
    if "$@"; then
        printf 'ok: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'not ok: %s\n' "$desc" >&2
        fail=$((fail + 1))
    fi
}
contains() { grep -Fq -- "$2" "$1"; }

check "integration is loaded last" bash -c '[ "$(tail -n1 "$1")" = zzzzzzzzzzzzzzzz-awesome-linux-catalog-integration.sh ]' _ "$LOAD"
check "original application catalogue is preserved" contains "$FEATURE" '_systui_base_pkg_catalogue'
check "application catalogue exposes Awesome Linux" contains "$FEATURE" 'awesome "Awesome Linux software catalogue"'
check "Awesome Linux entry calls existing catalogue implementation" contains "$FEATURE" 'menu_awesome_linux'
check "main menu filter targets only legacy Awesome Linux entry" contains "$FEATURE" '[ "$tag" = awesome ] && [ "$label" = "Awesome Linux (software catalogue)" ]'
check "generic menu implementation is preserved" contains "$FEATURE" '_systui_base_tui_menu'
check "feature passes bash syntax" bash -n "$FEATURE"

printf '\nAwesome Linux catalogue integration: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
