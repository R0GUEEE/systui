#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Phase 73 must preserve the failed apt status in the else branch, not read $?
# after the if compound command has completed.
F="$ROOT/src/features/73-rootfs-deb-install-final.sh"
bash -n "$F"
grep -Fq 'else' "$F"
grep -Fq 'rc=$?' "$F"
if grep -Pzo 'fi\s*\n\s*rc=\$\?' "$F" >/dev/null 2>&1; then
    echo 'not ok - apt status is captured after the if compound command' >&2
    exit 1
fi
printf 'ok - Debian installer preserves the original apt failure status\n'

# Phase 74 must route legacy in_chroot calls through the guarded API.
called=''
systui_rootfs_exec_guarded() {
    called="$*"
    printf '%s\n' "$called" > "$TMPDIR/guard-call"
    return 0
}
TMPDIR=$(mktemp -d); export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT
LOGFILE="$TMPDIR/log"; export LOGFILE
# shellcheck source=../src/features/74-rootfs-guarded-chroot-final.sh
. "$ROOT/src/features/74-rootfs-guarded-chroot-final.sh"
in_chroot /opt/rootfs/test /bin/echo hello
[ "$(cat "$TMPDIR/guard-call")" = '1800 /opt/rootfs/test /bin/echo hello' ]
printf 'ok - legacy in_chroot uses guarded execution with a bounded timeout\n'

SYSTUI_ROOTFS_CHROOT_TIMEOUT=42
in_chroot /opt/rootfs/test /bin/true
[ "$(cat "$TMPDIR/guard-call")" = '42 /opt/rootfs/test /bin/true' ]
printf 'ok - rootfs chroot timeout is configurable\n'
