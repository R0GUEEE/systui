#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../src/rootfs/backends.sh
. "$ROOT/src/rootfs/backends.sh"

[ "$(systui_rootfs_backend_requirements qemu-debootstrap)" = 'qemu-debootstrap (qemu-user-static) and debootstrap' ]
[ "$(systui_rootfs_backend_requirements apk-static)" = 'tar, gzip, and curl or wget' ]

systui_rootfs_alpine_release_supports_arch v3.21 riscv64
systui_rootfs_alpine_release_supports_arch edge riscv64
! systui_rootfs_alpine_release_supports_arch v3.20 riscv64
systui_rootfs_alpine_release_supports_arch v3.20 arm64

systui_rootfs_devuan_release_supports_arch ceres riscv64
! systui_rootfs_devuan_release_supports_arch excalibur riscv64
systui_rootfs_devuan_release_supports_arch excalibur arm64

# Unsupported backend tags are rejected rather than silently considered usable.
! systui_rootfs_backend_available definitely-not-a-backend

printf 'rootfs backend module checks passed\n'
