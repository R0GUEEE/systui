# shellcheck shell=bash
# PHASE 21 — rootfs backend capability compatibility layer.

# shellcheck source=../rootfs/backends.sh
. "$SYSTUI_LIBDIR/src/rootfs/backends.sh"

rootfs_backend_available() { systui_rootfs_backend_available "$@"; }
rootfs_backend_status() { systui_rootfs_backend_status "$@"; }
rootfs_backend_requirements() { systui_rootfs_backend_requirements "$@"; }
rootfs_alpine_release_supports_arch() { systui_rootfs_alpine_release_supports_arch "$@"; }
rootfs_devuan_release_supports_arch() { systui_rootfs_devuan_release_supports_arch "$@"; }
rootfs_backend_release_supported() { systui_rootfs_backend_release_supported "$@"; }

export -n -f rootfs_backend_available rootfs_backend_status rootfs_backend_requirements \
    rootfs_alpine_release_supports_arch rootfs_devuan_release_supports_arch \
    rootfs_backend_release_supported 2>/dev/null || true
