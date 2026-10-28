#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export SYSTUI_TMP_ROOT="$tmp" SYSTUI_LOGFILE="$tmp/log" SYSTUI_LIBDIR="$ROOT"
. "$ROOT/src/core/config.sh"
. "$ROOT/src/core/tui-widgets.sh"
. "$ROOT/src/core/common.sh"
. "$ROOT/src/core/loader.sh"
systui_load_features "$ROOT/src/features/.load-order"
# Preserve the real capture and dispatch helpers, replacing only the widget.
tui_refresh_terminal_size() { :; }
tui_menu_no_tags() {
    printf '%s\n' "$@" > "$tmp/rootfs-args"
    if [ ! -e "$tmp/selected" ]; then touch "$tmp/selected"; echo bedrock; else echo back; fi
}
menu_bedrock_aok() { echo invoked > "$tmp/opened"; }
menu_rootfs
[ -f "$tmp/opened" ] || { echo 'Bedrock not dispatched' >&2; exit 1; }
for tag in bedrock aot build download manage workbench bootstrap distros back; do
    rg -qx "$tag" "$tmp/rootfs-args" || { echo "Missing rootfs entry: $tag" >&2; exit 1; }
done
# Dispatch is in the caller, not the command-substitution widget process.
rm "$tmp/selected" "$tmp/opened"
menu_bedrock_aok() { state=changed; }
state=original; menu_rootfs; [ "$state" = changed ]
# AOT has its own guarded dispatch and exact user-facing label.
rm "$tmp/selected"
tui_menu_no_tags() {
    printf '%s\n' "$@" > "$tmp/rootfs-args"
    if [ ! -e "$tmp/selected" ]; then touch "$tmp/selected"; echo aot; else echo back; fi
}
menu_ios_linuxkit_aot() { aot_state=opened; }
aot_state=closed; menu_rootfs; [ "$aot_state" = opened ]
rg -Fxq 'Ahead-of-time JIT — installation, setup and configuration' "$tmp/rootfs-args"
! rg -qx ioskit "$tmp/rootfs-args"
# Cancellation exits; real widget errors propagate unchanged.
tui_menu_no_tags() { return 1; }; menu_rootfs
tui_menu_no_tags() { return 3; }; rc=0; menu_rootfs || rc=$?; [ "$rc" = 3 ]
# Original widget should not contain the historical injection wrapper.
! declare -f tui_menu | rg -q 'menu_bedrock_aok|Bedrock-AOK'
printf 'Bedrock rootfs full-manifest routing checks passed.\n'
