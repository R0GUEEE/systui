#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

base="$ROOT/src/features/70-sysconfig-systemd-manager.sh"
route="$ROOT/src/features/72-sysconfig-final-init-routing.sh"
final="$ROOT/src/features/75-sysconfig-root-systemd-online.sh"

bash -n "$base"
bash -n "$route"
bash -n "$final"

grep -q 'menu_systemd_manager()' "$base"
grep -q 'enable|disable|mask|unmask|preset' "$base"
grep -q 'Daemon reload (online only)' "$base"
grep -q 'Boot analysis (online only)' "$base"

grep -q 'Systemd Manager \[\$state\]' "$route"
grep -q 'menu_systemd_manager' "$route"

grep -q 'Systemd Manager — root system' "$final"
grep -q 'SYSTEMD_OFFLINE=1 systemctl' "$final"
grep -q 'Bring manager online / recheck' "$final"

printf 'ok - systemd manager is routed by phase 72 and finalized by phase 75\n'
