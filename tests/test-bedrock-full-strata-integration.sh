#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
F="$ROOT/src/features/85-bedrock-full-strata-integration.sh"
L="$ROOT/src/features/.load-order"

bash -n "$F"
grep -Fxq '85-bedrock-full-strata-integration.sh' "$L"
grep -Fq 'bedrock_systui_scan_capabilities()' "$F"
grep -Fq 'bedrock_systui_manager_rows_for()' "$F"
grep -Fq 'for pm in apt nala apk pacman dnf yum zypper xbps emerge opkg nix flatpak pip3 pip npm yarn pnpm cargo gem composer' "$F"
grep -Fq "nix) printf '/etc/nix/nix.conf" "$F"
grep -Fq 'bedrock_systui_integrated_packages_menu()' "$F"
grep -Fq 'menu_packages()' "$F"
grep -Fq 'if bedrock_systui_is_installed; then' "$F"
grep -Fq 'bedrock_aok_compat_finalize()' "$F"
printf 'ok - Bedrock strata capabilities integrate into package/config menus\n'
