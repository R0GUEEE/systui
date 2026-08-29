#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FILE="$ROOT/src/features/zzzzzzzzzzzzzz-multi-install-optimizer.sh"
LOAD="$ROOT/src/features/.load-order"

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

check "optimizer is loaded last" bash -c '[ "$(tail -n 1 "$1")" = zzzzzzzzzzzzzz-multi-install-optimizer.sh ]' _ "$LOAD"
check "shared native batch helper exists" contains "$FILE" 'systui_multi_native_install()'
check "shared helper sends full array to pm_install" contains "$FILE" 'pm_install "${unique[@]}"'
check "distro manager multi-install collects native packages" contains "$FILE" 'packages+=("$pkg")'
check "distro manager multi-install batches native packages" contains "$FILE" 'systui_multi_native_install "${packages[@]}"'
check "distro managers only use upstream after native batch" contains "$FILE" 'rootfs_dm_install_upstream "$tag"'
check "bootstrap multi-install uses checklist" contains "$FILE" 'tui_check "Install bootstrap tools"'
check "bootstrap multi-install batches native packages" contains "$FILE" 'systui_multi_native_install "${packages[@]}"'
check "bootstrap chroot-distro keeps upstream fallback" contains "$FILE" 'rootfs_dm_install_upstream chroot-distro'
check "bootstrap individual management remains accessible" contains "$FILE" '_systui_single_menu_rootfs_bootstrap_tools'
check "optimizer passes bash syntax" bash -n "$FILE"

printf '\nMulti-install optimizer: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
