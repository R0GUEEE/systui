#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# Services/init redraws must reuse startup detection unless state is dirty or an
# explicit diagnostic requests a live refresh.
refresh_calls=0
sysconfig_refresh_init_state() { refresh_calls=$((refresh_calls + 1)); }
SYSTUI_SERVICE_RUNTIME=systemd
SYSTUI_INIT_PROVIDER=systemd
INIT=systemd
tui_menu_no_tags() { return 1; }
tui_menu() { return 1; }
tui_text() { :; }
tui_msg() { :; }
run_cmd() { :; }
# shellcheck source=/dev/null
. "$ROOT/src/features/108-services-init-full-configuration-final.sh"

[ "$(systui_init_current)" = systemd ]
[ "$(systui_init_current)" = systemd ]
[ "$refresh_calls" -eq 0 ]
systui_init_mark_dirty
systui_init_refresh
[ "$refresh_calls" -eq 1 ]
systui_init_refresh force
[ "$refresh_calls" -eq 2 ]

# A catalogue category render should query installed packages once, not once per
# row. tui_check returns Cancel immediately after the first rendered checklist.
snapshot_calls="$tmp/snapshot-calls"
: > "$snapshot_calls"
log() { :; }
catalogue_find_line() { :; }
cat_title() { printf '%s\n' "$1"; }
app_native_name() { printf '%s\n' "$1"; }
app_status() { echo "per-row status probe should not run" >&2; return 99; }
systui_catalogue_installed_snapshot() {
    printf 'x\n' >> "$snapshot_calls"
    printf 'alpha\ngamma\n'
}
tui_check() { return 1; }
tui_yesno() { return 1; }
pm_install() { :; }
pm_remove() { :; }
declare -A CAT_APPS=()
CAT_ORDER=""
FEATURED_APPS=""
# shellcheck source=/dev/null
. "$ROOT/src/features/95-software-catalogue-registry-final.sh"
systui_catalogue_category_data() {
    printf '%s\n' 'alpha|Alpha|A' 'beta|Beta|B' 'gamma|Gamma|C'
}
browse_category test
[ "$(wc -l < "$snapshot_calls")" -eq 1 ]

# Hot menu implementations must not restore known expensive redraw patterns.
! grep -Fq '< <(tui_geometry' "$ROOT/src/core/tui-widgets.sh"
! grep -A20 '^menu_shell_hierarchy()' "$ROOT/src/features/103-tmux-shells-menu-integration-final.sh" \
    | grep -Fq 'detect_init 2>/dev/null || true'

printf 'ok - menu load paths reuse cached state and batch status probes\n'
