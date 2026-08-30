#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

warn() { :; }
tui_msg() { :; }
tui_yesno() { return 0; }
systui_is_ish() { return 1; }
SYSTUI_LIBDIR="$ROOT"

# shellcheck source=../src/rootfs/metadata.sh
. "$ROOT/src/rootfs/metadata.sh"
# shellcheck source=../src/features/40-rootfs-init-manager.sh
. "$ROOT/src/features/40-rootfs-init-manager.sh"

r="$tmp/root"
mkdir -p "$r/sbin" "$r/usr/sbin" "$r/lib/systemd" "$r/etc/systui"
: > "$r/usr/sbin/runit"; chmod +x "$r/usr/sbin/runit"
: > "$r/lib/systemd/systemd"; chmod +x "$r/lib/systemd/systemd"
ln -s ../lib/systemd/systemd "$r/sbin/init"

backup=$(rootfs_wb_init_backup "$r")
[ "$backup" != none ]
[ -L "$backup" ]

rootfs_wb_init_wire "$r" runit
[ "$(readlink "$r/sbin/init")" = '../usr/sbin/runit' ]

rootfs_wb_init_restore "$r" "$backup"
[ "$(readlink "$r/sbin/init")" = '../lib/systemd/systemd' ]

rootfs_wb_init_wire "$r" runit
rootfs_wb_init_commit_metadata "$r" runit systemd
[ "$(systui_rootfs_metadata_get "$r" init)" = runit ]
[ "$(systui_rootfs_metadata_get "$r" runtime)" = runit ]
grep -q '^previous=systemd$' "$r/etc/systui/init-selection.conf"

# Failed validation must not remove or replace the current init.
rm -f "$r/usr/sbin/runit"
ln -sfn ../lib/systemd/systemd "$r/sbin/init"
set +e
rootfs_wb_init_wire "$r" runit >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ]
[ "$(readlink "$r/sbin/init")" = '../lib/systemd/systemd' ]

printf 'rootfs init transaction checks passed\n'
