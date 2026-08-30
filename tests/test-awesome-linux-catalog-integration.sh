#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FEATURE_NAME="zzzzzzzzzzzzzzzz-awesome-linux-catalog-integration.sh"
FEATURE="$ROOT/src/features/$FEATURE_NAME"
LOAD="$ROOT/src/features/.load-order"
INSTALL="$ROOT/install.sh"

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

check "integration is present exactly once in load order" bash -c '[ "$(grep -Fxc "$2" "$1")" = 1 ]' _ "$LOAD" "$FEATURE_NAME"
check "integration loads after base sysconfig catalogue" bash -c '
    integration=$(grep -nFx "$2" "$1" | cut -d: -f1)
    base=$(grep -nFx "sysconfig.sh" "$1" | cut -d: -f1)
    [ "$integration" -gt "$base" ]
' _ "$LOAD" "$FEATURE_NAME"
check "final ARG_MAX guard still loads after integration" bash -c '
    integration=$(grep -nFx "$2" "$1" | cut -d: -f1)
    cleanup=$(grep -n -- "-rootfs-ish-argmax-cleanup.sh$" "$1" | tail -n1 | cut -d: -f1)
    [ -n "$cleanup" ] && [ "$cleanup" -gt "$integration" ]
' _ "$LOAD" "$FEATURE_NAME"
check "original application catalogue is preserved" contains "$FEATURE" '_systui_base_pkg_catalogue'
check "application catalogue exposes Awesome Linux" contains "$FEATURE" 'awesome "Awesome Linux software catalogue"'
check "Awesome Linux entry calls existing catalogue implementation" contains "$FEATURE" 'menu_awesome_linux'
check "integration no longer wraps global tui_menu" bash -c '! grep -Eq "^tui_menu\(\)" "$1"' _ "$FEATURE"
check "integration avoids external declare-f pipelines" bash -c '! grep -Eq "declare -f .*\|.*(sed|awk)" "$1"' _ "$FEATURE"
check "generated main menu has no standalone awesome tag" bash -c '! grep -Eq "^[[:space:]]*awesome[[:space:]]+\"Software catalogue\"" "$1"' _ "$INSTALL"
check "generated main menu has no direct menu_awesome_linux dispatch" bash -c '! grep -Eq "awesome\)[[:space:]]*menu_awesome_linux" "$1"' _ "$INSTALL"
check "feature passes bash syntax" bash -n "$FEATURE"

printf '\nAwesome Linux catalogue integration: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
