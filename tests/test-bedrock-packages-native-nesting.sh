#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
F="$ROOT/src/features/86-bedrock-packages-native-nesting.sh"
ORDER="$ROOT/src/features/.load-order"

bash -n "$F"

grep -Fq 'bedrock_systui_package_managers_menu()' "$F"
grep -Fq 'tui_menu_no_tags "Package Configuration' "$F"
grep -Fq 'bedrock "Bedrock strata package managers"' "$F"
grep -Fq 'managers   "Package managers (native, Flatpak, Snap, language)"' "$F"

# Native package sections must remain at the Package Configuration front door.
for tag in packages catalogue repos managers advanced; do
    grep -Eq "^[[:space:]]*$tag[[:space:]]" "$F"
done

# The old Bedrock-centric front-door title must not be reintroduced here.
if grep -Fq 'Packages — host + Bedrock' "$F"; then
    echo "phase 86 must not use the Bedrock-centric package front door" >&2
    exit 1
fi

# Phase 86 must override phase 85 before install guards/final exec layers.
p85=$(grep -n '^85-bedrock-full-strata-integration.sh$' "$ORDER" | cut -d: -f1)
p86=$(grep -n '^86-bedrock-packages-native-nesting.sh$' "$ORDER" | cut -d: -f1)
p90=$(grep -n '^90-install-guard-final.sh$' "$ORDER" | cut -d: -f1)
[ "$p85" -lt "$p86" ]
[ "$p86" -lt "$p90" ]

echo "ok: Bedrock managers are nested under native Package Configuration"
