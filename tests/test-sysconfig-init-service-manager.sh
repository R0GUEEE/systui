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
bash -n "$F"
printf 'ok - init manager and service config navigation restored\n'
