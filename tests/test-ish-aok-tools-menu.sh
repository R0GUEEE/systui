#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export SYSTUI_AOK_TOOLS_DIR="$tmp/tools" OUT="$tmp/out"
mkdir "$SYSTUI_AOK_TOOLS_DIR"
source "$root/src/features/116-ish-aok-tools.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
tui_msg() { :; }
menu_ultimate_provision() { : > "$tmp/provision-called"; }
# Snapshot category and submenu draws, including refresh while browsing.
draw=0
tui_capture_menu() {
    local dest=$1; shift 4
    draw=$((draw+1)); printf '%s\n' "$@" > "$tmp/draw$draw"
    case $draw in
        1) printf -v "$dest" '%s' provision ;;
        2) printf -v "$dest" '%s' desktop ;;
        3) printf '#!/bin/sh\nexit 0\n' > "$SYSTUI_AOK_TOOLS_DIR/setup-xfce.sh"; printf -v "$dest" '%s' tool_0 ;;
        4) printf -v "$dest" '%s' back ;;
        5) printf -v "$dest" '%s' other ;;
        6) printf -v "$dest" '%s' back ;;
        *) printf -v "$dest" '%s' back ;;
    esac
}
# Verify selected tag resolves to the actual file without executing it.
systui_aok_tool_run_original=$(declare -f systui_aok_tool_run)
eval "${systui_aok_tool_run_original/systui_aok_tool_run ()/systui_aok_tool_run_saved ()}"
systui_aok_tool_run() { printf '%s\n' "$1" > "$tmp/selected"; }
printf '#!/bin/sh\nexit 0\n' > "$SYSTUI_AOK_TOOLS_DIR/setup-wayland.sh"
printf '#!/bin/sh\nexit 0\n' > "$SYSTUI_AOK_TOOLS_DIR/first tool"
printf '#!/bin/sh\nexit 0\n' > "$SYSTUI_AOK_TOOLS_DIR/Ultimate-Provision.sh"
printf 'data\n' > "$SYSTUI_AOK_TOOLS_DIR/notes.txt"
ln -s "$SYSTUI_AOK_TOOLS_DIR/first tool" "$SYSTUI_AOK_TOOLS_DIR/linked-tool"
[ "$(systui_aok_tool_info setup-wayland.sh)" = 'desktop|Install Wayland Desktop|Install labwc, sway and display components' ] || fail 'wayland classification'
[ "$(systui_aok_tool_info manage-roots.sh)" = 'roots|Manage Root Filesystems|List, install or select root filesystems' ] || fail 'roots classification'
[ "$(systui_aok_tool_info future-new_tool.sh)" = 'other|future new tool|Unrecognized tool; review before running' ] || fail 'unknown classification'
menu_ish_aok_tools
[ -e "$tmp/provision-called" ] || fail 'provision menu'
grep -q -F 'Wayland and Desktop' "$tmp/draw1" || fail 'desktop category missing'
grep -q -F 'Other Tools' "$tmp/draw1" || fail 'other category missing'
grep -q -F 'Install Wayland Desktop' "$tmp/draw3" || fail 'friendly title missing'
grep -q -F 'Install the Xfce desktop' "$tmp/draw4" || fail 'dynamic refresh'
[ "$(cat "$tmp/selected")" = "$SYSTUI_AOK_TOOLS_DIR/setup-wayland.sh" ] || fail 'wrong tool selected'
grep -q -F 'first tool' "$tmp/draw6" || fail 'unknown tool missing'
! grep -Eqi 'Ultimate-Provision.sh|notes.txt|linked-tool' "$tmp/draw6" || fail 'excluded files'
SYSTUI_AOK_TOOLS_DIR="$tmp/missing"; draw=6; menu_ish_aok_tools
grep -q -F 'Ultimate Provision' "$tmp/draw7" || fail 'missing directory'
SYSTUI_AOK_TOOLS_DIR="$tmp/tools"
eval "$(declare -f systui_aok_tool_run_saved | sed '1s/systui_aok_tool_run_saved/systui_aok_tool_run/')"
# Record literal argument bytes and prove shell metacharacters are not evaluated.
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$OUT"\n' > "$tmp/tools/safe tool"
chmod 644 "$tmp/tools/safe tool"
mode=cancel
tui_yesno() {
    case "$1:$mode" in
        'Tool arguments:arg') mode=finish; return 0 ;;
        'Tool arguments:'*) return 1 ;;
        'Run iSH-AOK tool?:cancel') return 1 ;;
        'Run iSH-AOK tool?:'*) return 0 ;;
    esac
}
tui_input() { printf '%s' 'literal space; $(touch /tmp/systui-tool-injection)'; }
systui_aok_tool_run "$tmp/tools/safe tool"
[ ! -e "$OUT" ] || fail 'cancel executed tool'
mode=arg; systui_aok_tool_run "$tmp/tools/safe tool"
[ "$(cat "$OUT")" = 'literal space; $(touch /tmp/systui-tool-injection)' ] || fail 'argument preservation'
[ ! -e /tmp/systui-tool-injection ] || fail 'argument evaluated'
# Exercise executable shebang and nonexecutable env -S shebang.
printf '#!/usr/bin/env bash\nprintf "env shebang\\n" > "$OUT"\n' > "$tmp/tools/env script"
chmod 644 "$tmp/tools/env script"
mode=finish; systui_aok_tool_run "$tmp/tools/env script"
[ "$(cat "$OUT")" = 'env shebang' ] || fail 'env interpreter'
chmod +x "$tmp/tools/env script"
systui_aok_tool_run "$tmp/tools/env script"
[ "$(cat "$OUT")" = 'env shebang' ] || fail 'executable shebang'
printf 'PASS: discovery, refresh, exclusions, missing directory, provision, cancellation, literal argv, shebangs\n'
