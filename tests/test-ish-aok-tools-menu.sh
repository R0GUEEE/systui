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
# Snapshot each draw without relying on subshell state.
draw=0
 tui_capture_menu() {
    local dest=$1; shift 4
    draw=$((draw+1)); printf '%s\n' "$@" > "$tmp/draw$draw"
    case $draw in
        1) printf -v "$dest" '%s' provision ;;
        2) printf '#!/bin/sh\nexit 0\n' > "$SYSTUI_AOK_TOOLS_DIR/new tool"; printf -v "$dest" '%s' provision ;;
        *) printf -v "$dest" '%s' back ;;
    esac
}
printf '#!/bin/sh\nexit 0\n' > "$SYSTUI_AOK_TOOLS_DIR/first tool"
printf '#!/bin/sh\nexit 0\n' > "$SYSTUI_AOK_TOOLS_DIR/Ultimate-Provision.sh"
printf 'data\n' > "$SYSTUI_AOK_TOOLS_DIR/notes.txt"; chmod 644 "$SYSTUI_AOK_TOOLS_DIR/notes.txt"
ln -s "$SYSTUI_AOK_TOOLS_DIR/first tool" "$SYSTUI_AOK_TOOLS_DIR/linked-tool"
menu_ish_aok_tools
[ -e "$tmp/provision-called" ] || fail 'provision menu'
grep -q -F 'first tool' "$tmp/draw1" || fail 'tool with spaces missing'
! grep -q -F 'new tool' "$tmp/draw2" || fail 'tool discovered before creation'
grep -q -F 'new tool' "$tmp/draw3" || fail 'dynamic refresh'
! grep -Eqi 'Ultimate-Provision.sh|notes.txt|linked-tool' "$tmp/draw3" || fail 'excluded files'
SYSTUI_AOK_TOOLS_DIR="$tmp/missing"; draw=2; menu_ish_aok_tools
grep -q -F 'Ultimate Provision' "$tmp/draw3" || fail 'missing directory'
SYSTUI_AOK_TOOLS_DIR="$tmp/tools"
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
