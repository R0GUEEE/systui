#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
F="$ROOT/src/features/92-runtime-menu-cleanup.sh"
ORDER="$ROOT/src/features/.load-order"

[ -f "$F" ]
bash -n "$F"

grep -Fq 'unset -f bedrock_systui_integrated_packages_menu' "$F"
grep -Fq 'systui_bedrock_install_target_menu()' "$F"
grep -Fq 'bedrock_systui_package_managers_menu()' "$F"
grep -Fq 'systui_bedrock_stratum_multi_pm_install()' "$F"
grep -Fq 'continue' "$F"

p91=$(grep -n '^91-rootfs-exec-final.sh$' "$ORDER" | cut -d: -f1)
p92=$(grep -n '^92-runtime-menu-cleanup.sh$' "$ORDER" | cut -d: -f1)
[ -n "$p91" ] && [ -n "$p92" ] && [ "$p91" -lt "$p92" ]

# Unusable/unknown strata must not be offered as install targets.
bash -c '
set -e
systui_bedrock_install_active() { return 0; }
systui_bedrock_install_strata() { printf "%s\n" good bad; }
systui_bedrock_stratum_pm() { [ "$1" = good ] && echo apt; }
tui_radio() {
    printf "%s\n" "$@" | grep -q "stratum:good"
    if printf "%s\n" "$@" | grep -q "stratum:bad"; then return 7; fi
    echo host
}
source "$1"
[ "$(systui_bedrock_install_target_menu demo)" = host ]
' _ "$F"

echo "ok: final runtime menu cleanup"
