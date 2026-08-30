#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf -- "$tmpdir"' EXIT
export SYSTUI_TMP_ROOT="$tmpdir"
export SYSTUI_LOGFILE="$tmpdir/systui.log"
export SYSTUI_LIBDIR="$PROJECT_DIR"

. "$PROJECT_DIR/src/core/config.sh"
. "$PROJECT_DIR/src/core/tui-widgets.sh"
. "$PROJECT_DIR/src/core/common.sh"

manifest="$PROJECT_DIR/src/features/.load-order"
[ -r "$manifest" ]

duplicates=$(grep -vE '^[[:space:]]*(#|$)' "$manifest" | sort | uniq -d)
[ -z "$duplicates" ] || { printf 'duplicate feature entries:\n%s\n' "$duplicates" >&2; exit 1; }
last=$(grep -vE '^[[:space:]]*(#|$)' "$manifest" | tail -n1)
[[ "$last" == *rootfs-ish-argmax-cleanup.sh ]]

while IFS= read -r rel || [ -n "$rel" ]; do
    case "$rel" in ''|'#'*) continue;; esac
    [ -f "$PROJECT_DIR/src/features/$rel" ] || { echo "missing manifest feature: $rel" >&2; exit 1; }
    . "$PROJECT_DIR/src/features/$rel"
done < "$manifest"

declare -F systui_detect_init >/dev/null
declare -F systui_rootfs_init_detect >/dev/null
declare -F detect_init >/dev/null
declare -F rootfs_wb_init_detect >/dev/null
declare -F svc >/dev/null
declare -f detect_init | grep -q 'systui_detect_init'
declare -f rootfs_wb_init_detect | grep -q 'systui_rootfs_init_detect'
declare -f svc | grep -q 'SYSTUI_SERVICE_RUNTIME'

# Unsafe service tokens must be rejected before any backend command runs.
svc start 'sshd;touch /tmp/pwned' >/dev/null 2>&1 && { echo 'unsafe service name accepted' >&2; exit 1; }
svc bogus sshd >/dev/null 2>&1 && { echo 'unsafe service action accepted' >&2; exit 1; }

# Automatic foreign-package recovery must be disabled by default.
[ "${SYSTUI_PM_NO_WEB_FALLBACK:-}" = 1 ]

# Rootfs detection must honor the wired PID1 even when systemd packages coexist.
r="$tmpdir/root"
mkdir -p "$r/sbin" "$r/usr/sbin" "$r/usr/lib/systemd"
: > "$r/usr/sbin/runit"; chmod +x "$r/usr/sbin/runit"
: > "$r/usr/lib/systemd/systemd"; chmod +x "$r/usr/lib/systemd/systemd"
ln -s ../usr/sbin/runit "$r/sbin/init"
[ "$(systui_rootfs_init_detect "$r")" = runit ]

# Provision configuration parsing must never execute shell syntax.
pwn="$tmpdir/pwned"
printf 'SAFE_VALUE=ok\nEVIL=$(touch %s)\nLOGFILE=/tmp/redirected\n' "$pwn" > "$tmpdir/provision.conf"
log() { :; }
. "$PROJECT_DIR/src/provision/runtime.sh"
LOGFILE="$tmpdir/original.log"
provision_load_config "$tmpdir/provision.conf"
[ "$SAFE_VALUE" = ok ]
[ ! -e "$pwn" ]
[ "$LOGFILE" = "$tmpdir/original.log" ]

# The updater must no longer preserve caller-controlled deletion paths through
# sudo, and arbitrary caches require a Systui ownership marker.
grep -q 'Refusing to recursively remove untrusted update cache' "$PROJECT_DIR/update.sh"
! grep -q 'preserve-env=SYSTUI_UPDATE_CACHE' "$PROJECT_DIR/update.sh"
grep -q '.systui-update-cache' "$PROJECT_DIR/update.sh"

# Final environment cleanup should remove exported Bash functions, protecting
# iSH's small ARG_MAX from BASH_FUNC_* growth.
if env | grep -q '^BASH_FUNC_'; then
    echo 'exported Bash function leaked after final cleanup' >&2
    exit 1
fi

printf 'project integration checks passed\n'
