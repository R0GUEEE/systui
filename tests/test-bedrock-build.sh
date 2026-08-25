#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Load the same way systui does: rootfs.sh first, then the late Bedrock override.
# shellcheck source=../src/features/rootfs.sh
source "$PROJECT_DIR/src/features/rootfs.sh"
# shellcheck source=../src/features/zz-rootfs-bedrock-fix.sh
source "$PROJECT_DIR/src/features/zz-rootfs-bedrock-fix.sh"

failures=0
checks=0
check() {
    local desc="$1"; shift
    checks=$((checks + 1))
    if "$@"; then
        printf 'ok %d - %s\n' "$checks" "$desc"
    else
        printf 'not ok %d - %s\n' "$checks" "$desc"
        failures=$((failures + 1))
    fi
}

fn_has() { declare -f "$1" | grep -Fq -- "$2"; }
fn_lacks() { ! fn_has "$1" "$2"; }

check "Bedrock override exposes full preflight" declare -F rootfs_bedrock_preflight
check "preflight checks WSL" fn_has rootfs_bedrock_preflight microsoft
check "preflight checks FUSE registration" fn_has rootfs_bedrock_preflight /proc/filesystems
check "preflight checks /dev/fuse character device" fn_has rootfs_bedrock_preflight '[ -c /dev/fuse ]'
check "preflight verifies bind-mount capability" fn_has rootfs_bedrock_preflight 'mount --bind'
check "preflight probes extended attributes" fn_has rootfs_bedrock_preflight user.systui.bedrock
check "preflight probes file capabilities" fn_has rootfs_bedrock_preflight cap_sys_chroot

# The regression this override fixes: build_bedrock must not call the generic
# rootfs_chroot_exec after it has already mounted the target, because that
# helper mounts again and replaces ROOTFS_ACTIVE_MOUNTS bookkeeping.
check "Bedrock hijack avoids nested rootfs_chroot_exec" fn_lacks build_bedrock 'rootfs_chroot_exec "$target" "Bedrock hijack'
check "Bedrock hijack runs directly in the mounted chroot" fn_has build_bedrock 'rootfs_exec_raw "$target"'
check "Bedrock preserves the mount list for cleanup" fn_has build_bedrock 'mounts="${ROOTFS_ACTIVE_MOUNTS:-}"'
check "Bedrock unmount uses preserved mount list" fn_has build_bedrock 'rootfs_unmount_chroot_fs "$target" "$mounts"'
check "Bedrock fails early when /sbin/init is absent" fn_has build_bedrock 'bedrock-init-missing'
check "Bedrock records incompatible-host stage" fn_has build_bedrock 'bedrock-host-incompatible'

# Verify the filename really loads after rootfs.sh under the feature glob used
# by config.sh/run_strict and the generated launcher.
load_order_ok() {
    local root_idx fix_idx idx=0 f
    for f in "$PROJECT_DIR"/src/features/*.sh; do
        idx=$((idx + 1))
        [ "$(basename "$f")" = rootfs.sh ] && root_idx=$idx
        [ "$(basename "$f")" = zz-rootfs-bedrock-fix.sh ] && fix_idx=$idx
    done
    [ -n "${root_idx:-}" ] && [ -n "${fix_idx:-}" ] && [ "$fix_idx" -gt "$root_idx" ]
}
check "Bedrock override loads after rootfs.sh" load_order_ok

printf '%s checks, %s failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
