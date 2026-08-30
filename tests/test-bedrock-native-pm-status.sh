#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PHASE="$ROOT/src/features/87-bedrock-native-pm-status.sh"
LOAD="$ROOT/src/features/.load-order"

bash -n "$PHASE"
grep -q '^87-bedrock-native-pm-status.sh$' "$LOAD"

sysconfig_pm_multi_catalogue() { printf '%s\n' 'nix|nix|Nix' 'pip|pip3|pip'; }
sysconfig_pm_multi_package() { [ "$1" = pip ] && printf 'python3-pip\n'; }
sysconfig_pm_multi_special_installer() { [ "$1" = nix ] && printf 'menu_nix_install\n'; }
bedrock_systui_is_installed() { return 0; }
bedrock_systui_strata() { printf '%s\n' nixos debian; }
bedrock_systui_has_cmd() {
    case "$1:$2" in nixos:nix|debian:pip3) return 0 ;; *) return 1 ;; esac
}
source "$PHASE"

s=$(sysconfig_pm_native_status nix nix)
[[ "$s" == *'host:'* ]]
[[ "$s" == *'strata: nixos'* ]]

s=$(sysconfig_pm_native_status pip pip3)
[[ "$s" == *'strata: debian'* ]]

# Strata presence must not be treated as a native installation check.
grep -q 'Only a host command suppresses native installation' "$PHASE"

echo 'ok: Bedrock-aware native package-manager status'
