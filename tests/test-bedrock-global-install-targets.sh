#!/usr/bin/env bash
set -euo pipefail

repo=${1:-.}
phase="$repo/src/features/88-bedrock-global-install-targets.sh"
order="$repo/src/features/.load-order"

[ -f "$phase" ]
bash -n "$phase"

grep -q 'systui_bedrock_install_target_menu' "$phase"
grep -q 'systui_bedrock_install_canonical' "$phase"
grep -q 'menu_\*_install' "$phase"
grep -q 'sysconfig_pm_multi_install' "$phase"
grep -q 'menu_rootfs_\*' "$phase"
grep -q 'menu_bedrock_\*' "$phase"

p87=$(grep -n '^87-bedrock-native-pm-status\.sh$' "$order" | cut -d: -f1)
p88=$(grep -n '^88-bedrock-global-install-targets\.sh$' "$order" | cut -d: -f1)
p90=$(grep -n '^90-install-guard-final\.sh$' "$order" | cut -d: -f1)
[ -n "$p87" ] && [ -n "$p88" ] && [ -n "$p90" ]
[ "$p87" -lt "$p88" ] && [ "$p88" -lt "$p90" ]

# Functional wrapper test: ordinary menu_*_install functions gain a target
# picker, while structural rootfs installers remain untouched.
bash -c '
set -e
menu_demo_install() { echo HOST; }
menu_rootfs_demo_install() { echo ROOTFS; }
tui_radio() { echo stratum:test; }
tui_yesno() { return 0; }
tui_msg() { :; }
run_cmd() { shift; "$@"; }
source "$1"
systui_bedrock_install_active() { return 0; }
systui_bedrock_install_canonical() { echo "STRATUM:$1:$2"; }
out=$(menu_demo_install)
[ "$out" = "STRATUM:test:demo" ]
out=$(menu_rootfs_demo_install)
[ "$out" = ROOTFS ]
' _ "$phase"

# Package mappings must account for distro-family naming differences and Nix.
bash -c '
set -e
source "$1"
[ "$(systui_bedrock_pkg_name apt go)" = golang-go ]
[ "$(systui_bedrock_pkg_name apk pip)" = py3-pip ]
[ "$(systui_bedrock_pkg_name pacman node)" = nodejs ]
[ "$(systui_bedrock_pkg_name nix ripgrep)" = nixpkgs#ripgrep ]
' _ "$phase"

echo "ok: Bedrock global installation targets"
