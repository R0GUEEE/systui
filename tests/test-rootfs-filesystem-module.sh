#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
SYSTUI_TMP="$tmp/work"
mkdir -p "$SYSTUI_TMP" "$tmp/root/a" "$tmp/root/b"

# shellcheck source=../src/rootfs/filesystem.sh
. "$ROOT/src/rootfs/filesystem.sh"

[ "$(rootfs_report_file)" = "$SYSTUI_TMP/rootfs-report" ]

printf x > "$tmp/root/a/file"
printf y > "$tmp/root/b/file"
rootfs_du_summary "$tmp/root" >/dev/null

mkdir -p "$tmp/delete/me"
printf z > "$tmp/delete/me/file"
rootfs_rm_tree "$tmp/delete"
[ ! -e "$tmp/delete" ]

if rootfs_rm_tree / >/dev/null 2>&1; then
    echo 'rootfs_rm_tree accepted /' >&2
    exit 1
fi

rootfs_tar_create gz "$tmp/root" "$tmp/root.tar.gz"
tar -tzf "$tmp/root.tar.gz" | grep -q './a/file'

if rootfs_tar_create bogus "$tmp/root" "$tmp/bogus.tar" >/dev/null 2>&1; then
    echo 'unsupported archive format accepted' >&2
    exit 1
fi

if rootfs_fetch_file file:///etc/passwd "$tmp/passwd" >/dev/null 2>&1; then
    echo 'non-http URL accepted' >&2
    exit 1
fi

printf 'rootfs filesystem module checks passed\n'
