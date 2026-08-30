#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
file="$repo_root/src/features/96-menu-consolidation-final.sh"
manifest="$repo_root/src/features/.load-order"

[ -f "$file" ]
bash -n "$file"

grep -q '^menu_sysconfig_basics()' "$file"
grep -q '^menu_sysconfig()' "$file"
grep -q '^menu_packages()' "$file"
grep -q '^menu_package_managers()' "$file"
grep -q '^systui_catalogue_categories_menu()' "$file"
grep -q '^systui_catalogue_manage_menu()' "$file"
grep -q '^pkg_catalogue()' "$file"

# Common Tasks should no longer be an authoritative System Configuration entry.
menu_body=$(awk '/^menu_sysconfig\(\)/,/^}/' "$file")
if grep -q 'menu_sysconfig_common' <<<"$menu_body"; then
    echo 'menu_sysconfig still exposes the redundant Common Tasks front door' >&2
    exit 1
fi
grep -q 'system       "System basics' <<<"$menu_body"

# Bedrock manager access is nested under Package Managers, not Packages.
packages_body=$(awk '/^menu_packages\(\)/,/^}/' "$file")
if grep -q 'bedrock_systui_package_managers_menu' <<<"$packages_body"; then
    echo 'Packages still exposes Bedrock managers directly' >&2
    exit 1
fi
pm_body=$(awk '/^menu_package_managers\(\)/,/^}/' "$file")
grep -q 'Bedrock strata package managers' <<<"$pm_body"

# Catalogue front door should be compact and delegate categories/maintenance.
catalogue_body=$(awk '/^pkg_catalogue\(\)/,/^}/' "$file")
grep -q 'categories  "Browse all categories"' <<<"$catalogue_body"
grep -q 'manage      "Search, updates, installed apps and maintenance"' <<<"$catalogue_body"
if grep -q 'for cat in.*CAT_ORDER' <<<"$catalogue_body"; then
    echo 'catalogue front door still expands every category inline' >&2
    exit 1
fi

line95=$(grep -n '^95-software-catalogue-registry-final.sh$' "$manifest" | cut -d: -f1)
line96=$(grep -n '^96-menu-consolidation-final.sh$' "$manifest" | cut -d: -f1)
[ -n "$line95" ] && [ -n "$line96" ] && [ "$line95" -lt "$line96" ]

printf 'PASS: redundant menu entry points are consolidated\n'
