#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FEATURE="$ROOT/src/features/zz-rootfs-distro-manager-multiselect.sh"
LOAD_ORDER="$ROOT/src/features/.load-order"

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

check "multi-install helper exists" grep -Fq 'rootfs_dm_install_multiple_managers()' "$FEATURE"
check "manager menu exposes SPACE multi-select" grep -Fq 'Install multiple managers (SPACE to select)' "$FEATURE"
check "bulk installer uses tui_check" grep -Fq 'tui_check "Install distro managers"' "$FEATURE"
check "bulk installer skips already installed managers" grep -Fq 'if rootfs_dm_available "$tag"; then' "$FEATURE"
check "bulk installer reuses manager-specific install logic" grep -Fq 'rootfs_dm_install "$tag"' "$FEATURE"
check "override is in explicit feature load order" grep -Fxq 'zz-rootfs-distro-manager-multiselect.sh' "$LOAD_ORDER"

[ "$fail" -eq 0 ]
