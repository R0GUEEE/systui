#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Core/UI modules must not export Bash function bodies into child environments.
if grep -R -nE '^[[:space:]]*export[[:space:]]+-f([[:space:]]|$)' "$ROOT/src/core" "$ROOT/src/rootfs"; then
    echo "core/rootfs modules must not export functions" >&2
    exit 1
fi

# Responsive geometry must fit a narrow iSH-like terminal.
DIALOG=dialog
BACKTITLE=test
log() { :; }
LOGFILE=/dev/null
# shellcheck source=../src/core/tui-widgets.sh
. "$ROOT/src/core/tui-widgets.sh"

tput() {
    case "$1" in lines) printf '22\n';; cols) printf '53\n';; *) return 1;; esac
}
export -f tput
read -r h w list < <(tui_geometry menu)
[ "$h" -le 22 ]
[ "$w" -le 53 ]
[ "$w" -ge 38 ]
[ "$list" -ge 4 ]
export -n -f tput

# Data-backed package mapping must preserve the historical column contract:
# Alpine, Arch, Fedora, Void.
declare -A PKG_MAP=([build-essential]='old old old old')
SYSTUI_LIBDIR="$ROOT"
warn() { :; }
# shellcheck source=../src/core/package-map-data.sh
. "$ROOT/src/core/package-map-data.sh"
[ "${PKG_MAP[build-essential]}" = 'build-base base-devel gcc base-devel' ]
[ "${PKG_MAP[fish]}" = 'fish fish fish fish-shell' ]

# Stable rootfs execution API must preserve argv exactly.
# shellcheck source=../src/rootfs/api.sh
. "$ROOT/src/rootfs/api.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/root/etc" "$tmp/root/bin"
rootfs_exec_raw() { printf '%s|%s|%s|%s\n' "$#" "$1" "$2" "${3:-}"; }
out=$(systui_rootfs_exec "$tmp/root" /bin/sh hello)
[ "$out" = "3|$tmp/root|/bin/sh|hello" ]

# Rootfs metadata must be atomic, replace keys rather than duplicate them, and
# preserve unrelated keys.
# shellcheck source=../src/rootfs/metadata.sh
. "$ROOT/src/rootfs/metadata.sh"
systui_rootfs_metadata_init "$tmp/root" debian forky arm64 mmdebstrap systemd ish-systemd-compat
[ "$(systui_rootfs_metadata_get "$tmp/root" distro)" = debian ]
[ "$(systui_rootfs_metadata_get "$tmp/root" init)" = systemd ]
systui_rootfs_metadata_set "$tmp/root" init runit
[ "$(systui_rootfs_metadata_get "$tmp/root" init)" = runit ]
[ "$(grep -c '^init=' "$tmp/root/etc/systui/rootfs.conf")" -eq 1 ]
[ "$(systui_rootfs_metadata_get "$tmp/root" schema)" = 1 ]

printf 'core polish checks passed\n'
