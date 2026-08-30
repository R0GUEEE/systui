#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
F="$ROOT/src/features/76-sysconfig-multi-init-services.sh"
LOAD="$ROOT/src/features/.load-order"

[ -r "$F" ]
bash -n "$F"

grep -Fq 'rootfs_install_ish_systemd_compat "$t"' "$F"
grep -Fq '[ "$init" = systemd ]' "$F"
! grep -Fq '[ "$init" = systemd ] && declare -F rootfs_install_ish_systemd_compat >/dev/null 2>&1 && systui_is_ish' "$F"
grep -Fq 'runtime=ish-systemd-compat' "$F"
grep -Fq 'SYSTUI_SYSTEMD_COMPAT_MODE=ish-aok-auto' "$F"

for provider in systemd openrc runit sysvinit; do
    grep -Fq "$provider \"" "$F"
    grep -Fq "menu_services_provider $provider" "$F"
done

grep -Fq 'sysconfig_service_action_for()' "$F"
grep -Fq 'sysconfig_service_config_path_for()' "$F"
grep -Fq 'sysconfig_service_list_for()' "$F"
grep -Fq 'rc-service "$bare" "$action"' "$F"
grep -Fq 'sv restart "$bare"' "$F"
grep -Fq 'service "$bare" "$action"' "$F"
grep -Fq 'sysconfig_systemd_unit_file_action "$action" "$s"' "$F"

# Final phase ordering.
a=$(grep -nFx '75-sysconfig-root-systemd-online.sh' "$LOAD" | cut -d: -f1)
b=$(grep -nFx '76-sysconfig-multi-init-services.sh' "$LOAD" | cut -d: -f1)
c=$(grep -nFx '90-install-guard-final.sh' "$LOAD" | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ]
[ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]

# Functional rootfs wiring: systemd must invoke compatibility installer even on
# a host that is explicitly not iSH.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/root/sbin"
cat > "$tmp/test.sh" <<EOF
set -e
called=0
rootfs_install_ish_systemd_compat() { called=1; [ "\$1" = "$tmp/root" ]; }
systui_is_ish() { return 1; }
rootfs_wb_init_link_target() { return 99; }
. "$F"
rootfs_wb_init_wire "$tmp/root" systemd
[ "\$called" -eq 1 ]
EOF
bash "$tmp/test.sh"

printf 'ok - systemd compatibility and multi-init service management are final\n'
