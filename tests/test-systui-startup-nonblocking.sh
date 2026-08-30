#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLATFORM="$ROOT/src/core/platform.sh"
ISH="$ROOT/src/features/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-ish-systemd-offline-manager.sh"

bash -n "$PLATFORM"
bash -n "$ISH"

# iSH init detection must not contact systemctl/D-Bus before the first menu.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
cat > "$tmp/check.sh" <<EOF
set -e
SYSTUI_TMP="$tmp"
SYSTUI_ISH_AOK=1
systemctl() { echo called > "$tmp/systemctl-called"; return 99; }
. "$PLATFORM"
systui_pid1_name() { printf 'systemd\n'; }
systui_detect_init
[ "\$SYSTUI_INIT_PROVIDER" = systemd ]
[ "\$INIT" = ish-systemd-compat ]
[ ! -e "$tmp/systemctl-called" ]
EOF
bash "$tmp/check.sh"

grep -Fq 'Startup detection must never contact the systemd manager' "$ISH"
! grep -A8 '^sysconfig_ish_systemd_offline()' "$ISH" | grep -q 'systemctl is-system-running'

printf 'ok - iSH startup init detection is nonblocking\n'
