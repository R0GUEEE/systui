#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
F="$ROOT/src/features/95-software-catalogue-registry-final.sh"
ORDER="$ROOT/src/features/.load-order"

bash -n "$F"

grep -q '^systui_catalogue_ensure_registry()' "$F"
grep -q '^systui_catalogue_seed_fallback()' "$F"
grep -q '^systui_catalogue_rebuild_order()' "$F"
grep -q '^_systui_base_pkg_catalogue()' "$F"

# Simulate the reported runtime failure: legacy catalogue globals are absent.
unset CAT_APPS CAT_ORDER FEATURED_APPS 2>/dev/null || true
# shellcheck source=/dev/null
source "$F"

systui_catalogue_ensure_registry
count=$(systui_catalogue_registry_count)
[ "$count" -ge 10 ]
[ -n "$CAT_ORDER" ]
[ -n "${CAT_APPS[internet]:-}" ]
[ -n "${CAT_APPS[development]:-}" ]
[ -n "${CAT_APPS[terminal]:-}" ]
[ -n "$FEATURED_APPS" ]

grep -q 'firefox|Firefox' <<< "${CAT_APPS[internet]}"
grep -q 'python3|Python 3' <<< "${CAT_APPS[development]}"

# Existing catalogue content must be preserved rather than replaced by fallback.
unset CAT_APPS CAT_ORDER FEATURED_APPS 2>/dev/null || true
declare -A CAT_APPS=([custom]=$'custom-pkg|Custom App|Custom entry')
systui_catalogue_ensure_registry
[ "${CAT_APPS[custom]}" = 'custom-pkg|Custom App|Custom entry' ]
[ "$CAT_ORDER" = custom ]

p94=$(grep -n '^94-universal-software-catalogue.sh$' "$ORDER" | cut -d: -f1)
p95=$(grep -n '^95-software-catalogue-registry-final.sh$' "$ORDER" | cut -d: -f1)
[ "$p94" -lt "$p95" ]

printf 'PASS: software catalogue registry self-heals from an empty runtime state\n'
