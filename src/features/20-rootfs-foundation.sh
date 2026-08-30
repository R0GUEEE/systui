# shellcheck shell=bash
# PHASE 20 — authoritative rootfs filesystem/archive primitives.

_systui_rootfs_module="$SYSTUI_LIBDIR/src/rootfs/filesystem.sh"
[ -r "$_systui_rootfs_module" ] || {
    echo "systui: missing rootfs module: $_systui_rootfs_module" >&2
    return 1
}
# shellcheck disable=SC1090
. "$_systui_rootfs_module"
unset _systui_rootfs_module
