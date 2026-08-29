#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FEATURE="$ROOT/src/features/zzzzzzzzzzzzzzz-rootfs-build-autoconfig.sh"
LOAD="$ROOT/src/features/.load-order"

fail=0
check() {
    local name="$1"; shift
    if "$@"; then printf 'ok - %s\n' "$name"; else printf 'not ok - %s\n' "$name" >&2; fail=$((fail + 1)); fi
}

check "autoconfig is loaded last" bash -c '[ "$(tail -n1 "$1")" = zzzzzzzzzzzzzzz-rootfs-build-autoconfig.sh ]' _ "$LOAD"
check "rootfs base defaults to /opt/rootfs" grep -Fq 'ROOTFS_BASE=/opt/rootfs' "$FEATURE"
check "backend is selected automatically" grep -Fq 'rootfs_backend_auto_select' "$FEATURE"
check "backend tuning is automatic" grep -Fq 'rootfs_backend_auto_optimize' "$FEATURE"
check "host bootstrap dependencies are checked automatically" grep -Fq 'rootfs_check_host_deps' "$FEATURE"
check "package catalogue call is replaced" grep -Fq 'pkgs="$pkgs git curl wget"' "$FEATURE"
check "default name remains distro-release-arch" grep -Fq '"$ROOTFS_BASE/${distro}-${release}-${arch}"' "$FEATURE"
check "existing rootfs offers overwrite" grep -Fq 'overwrite "Overwrite the existing rootfs"' "$FEATURE"
check "existing rootfs offers rename" grep -Fq 'rename "Use a different rootfs name"' "$FEATURE"
check "overwrite removes existing tree" grep -Fq 'rootfs_rm_tree "$target"' "$FEATURE"
check "renamed rootfs stays under rootfs base" grep -Fq 'target="$ROOTFS_BASE/$name"' "$FEATURE"

bash -n "$FEATURE"
check "feature passes bash syntax" true

[ "$fail" -eq 0 ]
