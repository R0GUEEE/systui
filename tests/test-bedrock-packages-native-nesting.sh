#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ORDER="$ROOT/src/features/.load-order"
CONSOLIDATED="$ROOT/src/features/96-menu-consolidation-final.sh"
RUNTIME="$ROOT/src/features/92-runtime-menu-cleanup.sh"
ZYPFINAL="$ROOT/src/features/110-zypper-full-package-functionality-final.sh"

bash -n "$CONSOLIDATED"
bash -n "$RUNTIME"
bash -n "$ZYPFINAL"

# The old phase-86 wrapper is obsolete: final menu consolidation owns the
# Package Configuration front door, while runtime cleanup owns Bedrock package
# manager details.
! grep -Fqx '86-bedrock-packages-native-nesting.sh' "$ORDER"

grep -Fq 'menu_packages()' "$CONSOLIDATED"
grep -Fq 'menu_package_managers()' "$CONSOLIDATED"
grep -Fq 'bedrock "Bedrock strata package managers"' "$CONSOLIDATED"
grep -Fq 'bedrock_systui_package_managers_menu()' "$RUNTIME"
grep -Fq '_systui_package_managers_before_zypper_full' "$ZYPFINAL"
! grep -Fq 'if ! systui_zypper_available && [ "${PM:-}" != zypper ]; then' "$ZYPFINAL"

grep -Fq 'packages  "Install, remove, search and update packages"' "$CONSOLIDATED"
grep -Fq 'catalogue "Software catalogue"' "$CONSOLIDATED"
grep -Fq 'repos      "Repositories and signing keys"' "$CONSOLIDATED"
grep -Fq 'advanced   "Advanced package maintenance"' "$CONSOLIDATED"

grep -Fq 'bedrock_systui_package_managers_menu()' "$RUNTIME"

packages_body=$(awk '/^menu_packages\(\)/,/^}/' "$CONSOLIDATED")
if grep -Fq 'Packages — host + Bedrock' <<<"$packages_body"; then
    echo "Package front door must not be Bedrock-centric" >&2
    exit 1
fi
if grep -Fq 'bedrock_systui_package_managers_menu' <<<"$packages_body"; then
    echo "Bedrock managers should be nested below Package Managers" >&2
    exit 1
fi

line92=$(grep -n '^92-runtime-menu-cleanup.sh$' "$ORDER" | cut -d: -f1)
line96=$(grep -n '^96-menu-consolidation-final.sh$' "$ORDER" | cut -d: -f1)
[ -n "$line92" ] && [ -n "$line96" ] && [ "$line92" -lt "$line96" ]

echo "ok: Bedrock managers are nested under final Package Configuration"
