#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FILE="$ROOT/src/features/zzzzzzzzzzzzz-package-manager-multiselect.sh"
LOAD="$ROOT/src/features/.load-order"

fail=0
check() {
    local name="$1"; shift
    if "$@"; then
        printf 'ok - %s\n' "$name"
    else
        printf 'not ok - %s\n' "$name" >&2
        fail=$((fail + 1))
    fi
}

check "feature is loaded last" bash -c '[ "$(tail -n 1 "$1")" = zzzzzzzzzzzzz-package-manager-multiselect.sh ]' _ "$LOAD"
check "package manager menu exposes multi install" grep -Fq 'Install multiple managers (SPACE to select)' "$FILE"
check "multi install uses checklist" grep -Fq 'tui_check "Install package managers"' "$FILE"
check "selected native packages install in one batch" grep -Fq 'pm_install "${dedup[@]}"' "$FILE"
check "pnpm and yarn share one npm command" grep -Fq 'npm install -g "${npm_globals[@]}"' "$FILE"
check "already installed managers are skipped" grep -Fq 'command -v "$cmd" >/dev/null 2>&1 && continue 2' "$FILE"
check "existing individual manager UI is preserved" grep -Fq '_systui_single_menu_package_managers' "$FILE"
check "package recovery layer remains before manager multiselect" bash -c 'a=$(grep -nFx zzzzzzzzzzzz-package-install-recovery.sh "$1" | cut -d: -f1); b=$(grep -nFx zzzzzzzzzzzzz-package-manager-multiselect.sh "$1" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$LOAD"

bash -n "$FILE"
check "feature passes bash syntax" true

[ "$fail" -eq 0 ]
