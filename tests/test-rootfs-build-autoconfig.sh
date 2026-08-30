#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FEATURE="$ROOT/src/features/zzzzzzzzzzzzzzz-rootfs-build-autoconfig.sh"
BASE="$ROOT/src/features/rootfs.sh"
LOAD="$ROOT/src/features/.load-order"

fail=0
check() {
    local name="$1"; shift
    if "$@"; then printf 'ok - %s\n' "$name"; else printf 'not ok - %s\n' "$name" >&2; fail=$((fail + 1)); fi
}

check "autoconfig is loaded after the multi-install optimizer" bash -c '
    a=$(grep -nFx zzzzzzzzzzzzzz-multi-install-optimizer.sh "$1" | cut -d: -f1)
    b=$(grep -nFx zzzzzzzzzzzzzzz-rootfs-build-autoconfig.sh "$1" | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ]
' _ "$LOAD"
check "rootfs base defaults to /opt/rootfs" grep -Fq 'ROOTFS_BASE=/opt/rootfs' "$FEATURE"
check "backend is selected automatically" grep -Fq 'rootfs_backend_auto_select' "$FEATURE"
check "backend tuning is automatic" grep -Fq 'rootfs_backend_auto_optimize' "$FEATURE"
# Dependency enforcement belongs to the base builder; the autoconfig layer only
# supplies automatic choices and then delegates to it.
check "host bootstrap dependencies are checked automatically" grep -Fq 'rootfs_check_host_deps "$distro" "$backend" "$arch" "$comp"' "$BASE"
check "package catalogue adds core tools and the distro init" grep -Fq '"${2:-} git curl wget $init_pkg"' "$FEATURE"
check "default name remains distro-release-arch" grep -Fq '"$ROOTFS_BASE/${distro}-${release}-${arch}"' "$BASE"
check "existing rootfs offers overwrite" grep -Fq 'overwrite "Overwrite the existing rootfs"' "$FEATURE"
check "existing rootfs offers rename" grep -Fq 'rename "Use a different rootfs name"' "$FEATURE"
check "overwrite removes existing tree" grep -Fq 'rootfs_rm_tree "$target"' "$FEATURE"
check "renamed rootfs stays under rootfs base" grep -Fq 'target="$ROOTFS_BASE/$name"' "$FEATURE"

bash -n "$FEATURE"
check "feature passes bash syntax" true

[ "$fail" -eq 0 ]
