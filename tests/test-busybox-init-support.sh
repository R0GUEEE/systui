#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
phase="$root/src/features/79-busybox-init-support.sh"
rootfs="$root/src/features/80-busybox-rootfs-init-final.sh"
manifest="$root/src/features/.load-order"

bash -n "$phase"
bash -n "$rootfs"

grep -q 'SYSTUI_INIT_PROVIDER=busybox' "$phase"
grep -q 'SYSTUI_SERVICE_RUNTIME=busybox' "$phase"
grep -q 'busybox "BusyBox init / inittab services"' "$phase"
grep -q 'printf.*busybox' "$phase"
grep -q 'provider" = busybox' "$phase"
grep -q 'busybox "BusyBox init"' "$rootfs"
grep -q 'busybox-static' "$rootfs"
grep -q '/etc/inittab' "$rootfs"
grep -q '79-busybox-init-support.sh' "$manifest"
grep -q '80-busybox-rootfs-init-final.sh' "$manifest"

echo 'BusyBox init support regression checks passed.'
