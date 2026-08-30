#!/usr/bin/env bash
set -euo pipefail

repo=${1:-.}
phase="$repo/src/features/89-bedrock-pm-install-routing.sh"
order="$repo/src/features/.load-order"

[ -f "$phase" ]
bash -n "$phase"

grep -q '^pm_install()' "$phase"
grep -q 'SYSTUI_INSTALL_TARGET' "$phase"
grep -q 'systui_bedrock_pm_install_raw' "$phase"
grep -q 'systui_bedrock_rebind_install_wrappers' "$phase"

p88=$(grep -n '^88-bedrock-global-install-targets\.sh$' "$order" | cut -d: -f1)
p89=$(grep -n '^89-bedrock-pm-install-routing\.sh$' "$order" | cut -d: -f1)
p90=$(grep -n '^90-install-guard-final\.sh$' "$order" | cut -d: -f1)
[ -n "$p88" ] && [ -n "$p89" ] && [ -n "$p90" ]
[ "$p88" -lt "$p89" ] && [ "$p89" -lt "$p90" ]

# Direct pm_install callers must gain a Bedrock target even when their menu is
# not named menu_*_install.
bash -c '
set -e
pm_install() { echo "HOST:$*"; }
systui_bedrock_install_active() { return 0; }
systui_bedrock_install_target_menu() { echo stratum:test; }
systui_bedrock_stratum_pm() { echo apk; }
systui_bedrock_exec_stratum() { echo "EXEC:$1:$2"; }
run_cmd() { shift; "$@"; }
tui_msg() { :; }
source "$1"
out=$(pm_install demo)
case "$out" in *"EXEC:test:apk add -- demo"*) ;; *) echo "unexpected: $out" >&2; exit 1;; esac
out=$(SYSTUI_INSTALL_TARGET=host pm_install demo)
[ "$out" = "HOST:demo" ]
' _ "$phase"

echo "ok: Bedrock pm_install routing"
