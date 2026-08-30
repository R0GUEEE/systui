#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
F="$ROOT/src/features/75-sysconfig-root-systemd-online.sh"
LOAD="$ROOT/src/features/.load-order"

[ -r "$F" ]
bash -n "$F"

grep -Fq 'sysconfig_root_systemd_ensure_online()' "$F"
grep -Fq 'systemctl daemon-reexec' "$F"
grep -Fq 'systemctl daemon-reload' "$F"
grep -Fq 'Bring manager online / recheck' "$F"
grep -Fq 'Systemd Manager — root system' "$F"
grep -Fq 'run_cmd "systemctl $action $unit" systemctl "$action" "$unit"' "$F"
grep -Fq 'env SYSTEMD_OFFLINE=1 systemctl "$action" "$unit"' "$F"

# Never spawn a second system manager from the TUI.
! grep -Eq '(^|[[:space:]])(systemd|/[^ ]*/systemd)[[:space:]]+--system' "$F"

# Phase 75 must be later than rootfs guard 74 and earlier than final execution guards.
a=$(grep -nFx '74-rootfs-guarded-chroot-final.sh' "$LOAD" | cut -d: -f1)
b=$(grep -nFx '75-sysconfig-root-systemd-online.sh' "$LOAD" | cut -d: -f1)
c=$(grep -nFx '90-install-guard-final.sh' "$LOAD" | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ]
[ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# Sourcing the phase must never call systemctl or sleep. This is a startup invariant.
cat > "$tmp/source-only.sh" <<EOF
set -e
systemctl() { echo invoked > "$tmp/invoked"; return 99; }
sleep() { echo slept > "$tmp/slept"; return 99; }
. "$F"
[ ! -e "$tmp/invoked" ]
[ ! -e "$tmp/slept" ]
EOF
bash "$tmp/source-only.sh"

# Already-online manager: no recovery commands are required.
cat > "$tmp/online.sh" <<EOF
set -e
sysconfig_systemd_provider_active() { return 0; }
systui_systemd_online() { return 0; }
. "$F"
systemctl() { echo unexpected >&2; return 99; }
sysconfig_root_systemd_pid1() { printf 'systemd\n'; }
sysconfig_root_systemd_ensure_online
EOF
bash "$tmp/online.sh"

# If PID 1 is not systemd, ensure-online must fail without invoking systemctl.
cat > "$tmp/nonpid1.sh" <<EOF
set -e
sysconfig_systemd_provider_active() { return 0; }
systui_systemd_online() { return 1; }
. "$F"
systemctl() { echo invoked > "$tmp/invoked2"; return 0; }
sysconfig_root_systemd_pid1() { printf 'bash\n'; }
if sysconfig_root_systemd_ensure_online; then exit 1; fi
[ ! -e "$tmp/invoked2" ]
EOF
bash "$tmp/nonpid1.sh"

printf 'ok - root systemd phase is startup-safe and never spawns a second manager\n'
