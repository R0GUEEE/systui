#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
F="$ROOT/src/features/69-sysconfig-init-service-manager.sh"

grep -Fq 'initmgr "Init Manager"' "$F"
grep -Fq 'config "Configure service"' "$F"
grep -Fq 'menu_service_config' "$F"
grep -Fq 'menu_services_manage' "$F"
grep -Fq 'menu_init_manager' "$F"
grep -Fq 'systemctl daemon-reload' "$F"
grep -Fq '/etc/conf.d/$s' "$F"
grep -Fq '/etc/sv/$s/run' "$F"
grep -Fq '/etc/init.d/$s' "$F"

grep -Fq 'sysconfig_systemd_mask_offline' "$F"
grep -Fq 'ln -sfn /dev/null "$path"' "$F"
grep -Fq 'target=$(readlink "$path"' "$F"
grep -Fq 'Refusing to remove non-mask symlink' "$F"
grep -Fq 'offline supported' "$F"
! grep -Fq 'Masking requires a running systemd manager.' "$F"

bash -n "$F"
printf 'ok - init manager, service config, and offline systemd masking are wired\n'
