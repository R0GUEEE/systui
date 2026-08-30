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
    printf '%s|%s|%s\n' "$#" "${1:-}" "${2:-}"
}

out=$(systui_guard_exec 5 sample_guard_function hello world)
[ "$out" = '2|hello|world' ]

# Model the rootfs path shape that regressed: argv[1] must be the target, never
# the function name itself.
rootfs_exec_raw() {
    printf '%s|%s|%s\n' "$1" "$2" "$3"
}
out=$(systui_guard_exec 5 rootfs_exec_raw /opt/rootfs/debian-forky-arm64 /tmp/install.sh git)
[ "$out" = '/opt/rootfs/debian-forky-arm64|/tmp/install.sh|git' ]

# External executable argv must also remain exact after the guard metadata is
# removed.
out=$(systui_guard_exec 5 printf '%s|%s\n' hello world)
[ "$out" = 'hello|world' ]

export -n -f sample_guard_function rootfs_exec_raw 2>/dev/null || true
! env | grep -Eq '^BASH_FUNC_(sample_guard_function|rootfs_exec_raw)%%='

slow_guard_function() {
    sleep 5
}

set +e
systui_guard_exec 1 slow_guard_function >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 124 ]

printf 'install guard function checks passed\n'
