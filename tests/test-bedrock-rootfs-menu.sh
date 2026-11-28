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
#
# Rootfs is an index of five groups; iSH-AOK features live one level down in
# menu_rootfs_ish_aok. The stub answers group -> child menu -> back, so the
# dispatch of both levels is exercised.
tui_refresh_terminal_size() { :; }
tui_menu_no_tags() {
    printf '%s\n' "$@" > "$tmp/rootfs-args"
    local depth
    depth=0; [ -e "$tmp/selected" ] && depth=$(wc -l < "$tmp/selected")
    case "$depth" in
        0) echo ish; printf 'x\n' >> "$tmp/selected" ;;
        1) echo aot; printf 'x\n' >> "$tmp/selected" ;;
        *) echo back; printf 'x\n' >> "$tmp/selected" ;;
    esac
}
menu_ios_linuxkit_aot() { echo invoked > "$tmp/opened"; }
menu_rootfs
[ -f "$tmp/opened" ] || { echo 'AOT not dispatched through the iSH-AOK group' >&2; exit 1; }
for tag in acquire manage distros containers ish back; do
    grep -qx "$tag" "$tmp/rootfs-args" || { echo "Missing rootfs group: $tag" >&2; exit 1; }
done
rm -f "$tmp/selected" "$tmp/opened"
tui_menu_no_tags() {
    local depth
    depth=0; [ -e "$tmp/selected" ] && depth=$(wc -l < "$tmp/selected")
    case "$depth" in
        0) echo ish; printf 'x\n' >> "$tmp/selected" ;;
        1) echo bedrock; printf 'x\n' >> "$tmp/selected" ;;
        *) echo back; printf 'x\n' >> "$tmp/selected" ;;
    esac
}
menu_bedrock_aok() { state=changed; }
state=original; menu_rootfs; [ "$state" = changed ]
rm -f "$tmp/selected"
tui_menu_no_tags() {
    local depth
    depth=0; [ -e "$tmp/selected" ] && depth=$(wc -l < "$tmp/selected")
    case "$depth" in
        0) echo ish; printf 'x\n' >> "$tmp/selected" ;;
        1) echo guestroots; printf 'x\n' >> "$tmp/selected" ;;
        *) echo back; printf 'x\n' >> "$tmp/selected" ;;
    esac
}
systui_aok_roots_menu() { guestroots_state=opened; }
guestroots_state=closed; menu_rootfs; [ "$guestroots_state" = opened ]
# The iSH-AOK group still offers the iOS-linuxkit front door.
printf 'x\n' > "$tmp/selected"
tui_menu_no_tags() { printf '%s\n' "$@" > "$tmp/ish-args"; echo back; return 0; }
menu_rootfs_ish_aok
for tag in aot bedrock guestroots ioskit back; do
    grep -qx "$tag" "$tmp/ish-args" || { echo "Missing iSH-AOK entry: $tag" >&2; exit 1; }
done
# The acquire group still offers the guided builder.
( tui_menu_no_tags() { printf '%s\n' "$@" > "$tmp/acq-args"; echo back; return 0; }; menu_rootfs_acquire )
for tag in build download bootstrap back; do
    grep -qx "$tag" "$tmp/acq-args" || { echo "Missing acquire entry: $tag" >&2; exit 1; }
done
# Cancellation exits; real widget errors propagate unchanged.
tui_menu_no_tags() { return 1; }; menu_rootfs
tui_menu_no_tags() { return 3; }; rc=0; menu_rootfs || rc=$?; [ "$rc" = 3 ]
# Original widget should not contain the historical injection wrapper.
! declare -f tui_menu | grep -Eq 'menu_bedrock_aok|Bedrock-AOK'
printf 'Rootfs grouping and full-manifest routing checks passed.\n'
