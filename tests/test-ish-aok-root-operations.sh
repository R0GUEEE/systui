#!/usr/bin/env bash
set -eu
repo=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
source "$repo/src/features/116-ish-aok-tools.sh"
tui_msg(){ :; }
tui_yesno(){ [[ ${CONFIRM:-no} == yes ]]; }
tui_menu_no_tags(){ printf '%s' "$MENU"; }
tui_input(){ case $1:$2 in 'App root:Existing root name:') printf '%s' NeverUsed;; 'App root:Root name:') printf '%s' "${SOURCE:-Test-Root}";; 'Install app root:New root name:') printf '%s' "${NEW_NAME:-TestRoot}";; 'Guest command:Command name or executable path:') printf '%s' "$VALUE";; 'Install app root:Absolute archive path inside this guest:'|'Install app root:HTTP(S) archive URL:'|'Install app root:Catalog ID (see List catalog):') printf '%s' "$SOURCE";; 'Rename root:New root name:') printf '%s' "$VALUE";; *) return 1;; esac; }
reset_inputs(){ :; }
MENU=catalog; reset_inputs; SOURCE=alpine3242aarch64; VALUE=
systui_aok_root_preset manage-roots.sh
test "${args[0]}" = install && test "${args[1]}" = "$SOURCE" && test ${#args[@]} -eq 2
MENU=catalog; reset_inputs; SOURCE='bad id'; VALUE=
if systui_aok_root_preset manage-roots.sh; then echo 'FAIL: invalid catalog ID accepted' >&2; exit 1; fi
MENU=archive; reset_inputs; SOURCE="$tmp/fake.archive"; VALUE=; touch "$SOURCE"
systui_aok_root_preset manage-roots.sh
test "${args[0]}" = install && test "${args[1]}" = "$SOURCE" && test "${args[2]}" = TestRoot
NEW_NAME='Bad/Name'
if systui_aok_root_preset manage-roots.sh; then echo 'FAIL: invalid archive root name accepted' >&2; exit 1; fi
unset NEW_NAME
MENU=url; SOURCE=https://example.org/rootfs.tar.gz
systui_aok_root_preset manage-roots.sh
test "${args[0]}" = install && test "${args[1]}" = "$SOURCE" && test "${args[2]}" = TestRoot
MENU=remove; reset_inputs; SOURCE=; VALUE=NeverUsed; CONFIRM=no
if systui_aok_root_preset manage-roots.sh; then echo 'FAIL: unconfirmed removal accepted' >&2; exit 1; fi
CONFIRM=yes; systui_aok_root_preset manage-roots.sh
test "${args[*]}" = 'remove NeverUsed --yes'
MENU=rename; reset_inputs; SOURCE=; VALUE=TestRoot
systui_aok_root_preset manage-roots.sh
test "${args[*]}" = 'rename NeverUsed TestRoot'
MENU=rename; reset_inputs; SOURCE=; VALUE=../escape
if systui_aok_root_preset manage-roots.sh; then echo 'FAIL: unsafe renamed root accepted' >&2; exit 1; fi
MENU=exec; reset_inputs; SOURCE=TestRoot; VALUE='/bin/echo hello; literal'
systui_aok_root_preset mount-root.sh
test "${args[0]}" = TestRoot && test "${args[1]}" = -- && test "${args[2]}" = "$VALUE"
MENU=unmount; reset_inputs; SOURCE=TestRoot; VALUE=foo
systui_aok_root_preset mount-root.sh
test "${args[*]}" = '--unmount TestRoot'
MENU=enter; reset_inputs; SOURCE=../elsewhere; VALUE=
if systui_aok_root_preset mount-root.sh; then echo 'FAIL: unsafe mounted root accepted' >&2; exit 1; fi
MENU=enter; reset_inputs; SOURCE=all; VALUE=
if systui_aok_root_preset mount-root.sh; then echo 'FAIL: enter all accepted' >&2; exit 1; fi
printf 'PASS AOK root operations: argv, source, removal confirmation, mount and unmount\n'
