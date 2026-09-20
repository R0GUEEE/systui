#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

export SYSTUI_TMP_ROOT="$tmp"
export SYSTUI_LOGFILE="$tmp/systui.log"
export SYSTUI_LIBDIR="$ROOT"

. "$ROOT/src/core/config.sh"
. "$ROOT/src/core/tui-widgets.sh"
. "$ROOT/src/core/common.sh"
. "$ROOT/src/core/loader.sh"

systui_load_features "$ROOT/src/features/.load-order"

# Validate the effective functions after the entire override stack is loaded,
# not intermediate phase implementations.
required=(
    menu_health menu_ultimate_provision menu_rootfs menu_sysconfig menu_performance
    menu_sysconfig_basics menu_packages menu_shells menu_editors menu_file_managers
    menu_network menu_services menu_users menu_storage
    menu_package_operations pkg_catalogue menu_repos menu_package_managers menu_pkg_advanced
    menu_scan_system menu_shell_hierarchy menu_tmux_manager menu_init_manager
    systui_init_provider_admin_menu
    rootfs_builder rootfs_download menu_rootfs_workbench
    menu_rootfs_bootstrap_tools menu_rootfs_distro_managers
)
for fn in "${required[@]}"; do
    declare -F "$fn" >/dev/null 2>&1 || {
        printf 'final menu graph missing function: %s\n' "$fn" >&2
        exit 1
    }
done

# Final authoritative front doors must use guarded routing and error-aware
# capture rather than direct calls that turn a partial install into "command not found".
declare -f menu_sysconfig | grep -Fq 'tui_capture_menu'
declare -f menu_sysconfig | grep -Fq 'tui_call_menu menu_editors'
declare -f menu_sysconfig | grep -Fq 'tui_call_menu menu_services'
declare -f menu_services | grep -Fq 'tui_capture_menu'
declare -f menu_init_manager | grep -Fq 'tui_capture_menu'

# Stateful init detection must not be hidden in command substitution. Refresh
# mutations such as clearing SYSTUI_INIT_STATE_DIRTY need to survive in parent.
services_file="$ROOT/src/features/108-services-init-full-configuration-final.sh"
! grep -Fq 'current=$(systui_init_current)' "$services_file"

# Real dialog errors are not Cancel. An unexpected exit must be reported and
# propagated by modern menu capture.
cat > "$tmp/dialog-fail" <<'EOF'
#!/bin/sh
exit 3
EOF
chmod +x "$tmp/dialog-fail"
DIALOG="$tmp/dialog-fail"
BACKTITLE=test
LINES=24
COLUMNS=80
choice=''
if tui_capture_menu choice tui_menu "Synthetic menu" "Testing failure propagation" ok "OK" 2>"$tmp/dialog.err"; then
    echo 'unexpected dialog failure was treated as success/cancel' >&2
    exit 1
else
    rc=$?
fi
[ "$rc" -eq 3 ]
grep -Fq "menu failed while opening 'Synthetic menu' (dialog exit 3)" "$tmp/dialog.err"

# Cancel and ESC remain normal navigation outcomes.
cat > "$tmp/dialog-cancel" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$tmp/dialog-cancel"
DIALOG="$tmp/dialog-cancel"
choice=stale
tui_capture_menu choice tui_menu "Synthetic menu" "Testing cancel" ok "OK"
[ -z "$choice" ]

printf 'ok - final assembled menu graph and dialog error routing\n'
