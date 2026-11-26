#!/usr/bin/env bash
# A fail-fast wizard child must report its status instead of bouncing the user
# back to the Rootfs menu with no message. Nothing is built or installed.
set -euo pipefail
repo=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
. "$repo/src/features/rootfs.sh"

shown=''
LOGFILE=/var/log/systui.log
run_strict() { return 7; }
tui_msg() { shown+="$1"$'\n'"$2"$'\n'; }

rootfs_builder
case $shown in
    *'Rootfs builder stopped'*) ;;
    *) printf 'FAIL child failure was silent\n' >&2; exit 1 ;;
esac
case $shown in
    *'status 7'*) ;;
    *) printf 'FAIL child status not reported\n' >&2; exit 1 ;;
esac

# A normal finish and a user cancel stay quiet.
shown=''
run_strict() { return 0; }
rootfs_builder
[ -z "$shown" ] || { printf 'FAIL success path showed an error\n' >&2; exit 1; }
run_strict() { return 1; }
rootfs_builder
[ -z "$shown" ] || { printf 'FAIL cancel path showed an error\n' >&2; exit 1; }

printf 'PASS wizard child failure is reported, success and cancel stay quiet\n'
