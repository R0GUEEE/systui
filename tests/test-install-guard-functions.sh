#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="$ROOT/src/features/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-sysconfig-install-execution-guard.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
LOGFILE="$tmp/log"

log() { :; }
clear() { :; }
run_cmd() { "$@"; }
. "$GUARD"

sample_guard_function() {
    printf 'function-ok:%s\n' "$1"
}

out=$(systui_guard_exec 5 sample_guard_function hello)
[ "$out" = 'function-ok:hello' ]

# Function bodies must remain local; the ARG_MAX fix depends on avoiding
# BASH_FUNC_* propagation into external children.
export -n -f sample_guard_function 2>/dev/null || true
! env | grep -q '^BASH_FUNC_sample_guard_function%%='

slow_guard_function() {
    sleep 5
}

set +e
systui_guard_exec 1 slow_guard_function >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 124 ]

printf 'install guard function checks passed\n'
