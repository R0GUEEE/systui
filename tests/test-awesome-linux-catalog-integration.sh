#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONSOLIDATED="$ROOT/src/features/96-menu-consolidation-final.sh"
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

check "old Awesome integration wrapper is not loaded" bash -c '! grep -Fqx "zzzzzzzzzzzzzzzz-awesome-linux-catalog-integration.sh" "$1"' _ "$LOAD"
check "consolidated catalogue exposes Awesome Linux" contains "$CONSOLIDATED" 'awesome     "Awesome Linux catalogue"'
check "Awesome Linux entry calls existing catalogue implementation" contains "$CONSOLIDATED" 'menu_awesome_linux'
check "consolidated catalogue keeps compact front door" contains "$CONSOLIDATED" 'categories  "Browse all categories"'
check "consolidated catalogue avoids external declare-f pipelines" bash -c '! grep -Eq "declare -f .*\|.*(sed|awk)" "$1"' _ "$CONSOLIDATED"
check "generated main menu has no standalone awesome tag" bash -c '! grep -Eq "^[[:space:]]*awesome[[:space:]]+\"Software catalogue\"" "$1"' _ "$INSTALL"
check "generated main menu has no direct menu_awesome_linux dispatch" bash -c '! grep -Eq "awesome\)[[:space:]]*menu_awesome_linux" "$1"' _ "$INSTALL"
check "consolidated feature passes bash syntax" bash -n "$CONSOLIDATED"

printf '\nAwesome Linux catalogue integration: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
