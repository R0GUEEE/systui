#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

f="$ROOT/src/features/70-sysconfig-systemd-manager.sh"
grep -q 'menu_systemd_manager()' "$f"
grep -q 'Systemd Manager (online or offline)' "$f"
grep -q 'SYSTEMD_OFFLINE=1 systemctl' "$f"
grep -q 'enable|disable|mask|unmask|preset' "$f"
grep -q 'Daemon reload (online only)' "$f"
grep -q 'Boot analysis (online only)' "$f"
grep -q 'init "Init Manager"' "$f"

printf 'ok - offline-capable systemd manager is exposed under Init Manager\n'
