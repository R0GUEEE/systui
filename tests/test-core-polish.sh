#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# New core/rootfs modules must never export Bash function bodies. config.sh and
# common.sh remain legacy-compatible during migration; the central loader
# scrubs their exports on constrained iSH runtimes.
modern=(
    "$ROOT/src/core/tui-widgets.sh"
    "$ROOT/src/core/platform.sh"
    "$ROOT/src/core/loader.sh"
    "$ROOT/src/core/strict-exec.sh"
    "$ROOT/src/core/package-map-data.sh"
    "$ROOT/src/rootfs/api.sh"
    "$ROOT/src/rootfs/metadata.sh"
)
if grep -nE '^[[:space:]]*export[[:space:]]+-f([[:space:]]|$)' "${modern[@]}"; then
    echo "modern core/rootfs modules must not export functions" >&2
    exit 1
fi

# Responsive geometry must fit a narrow iSH-like terminal.
DIALOG=dialog
BACKTITLE=test
log() { :; }
LOGFILE=/dev/null
# shellcheck source=../src/core/tui-widgets.sh
. "$ROOT/src/core/tui-widgets.sh"

# Ordinary redraws use Bash-maintained dimensions without any probe.
LINES=22
COLUMNS=53
tui_geometry menu >/dev/null
[ "$TUI_H" -le 22 ]
[ "$TUI_W" -le 53 ]
[ "$TUI_W" -ge 38 ]
[ "$TUI_LIST" -ge 4 ]

# When shell dimensions are unavailable, one stty probe seeds the cache and
# later redraws reuse it.
unset LINES COLUMNS
TUI_ROWS_CACHE=""
TUI_COLS_CACHE=""
stty_calls=0
stty() { stty_calls=$((stty_calls + 1)); printf '22 53\n'; }
tput() { return 99; }
tui_geometry menu >/dev/null
[ "$stty_calls" -eq 1 ]
tui_geometry menu >/dev/null
[ "$stty_calls" -eq 1 ]
[ "$TUI_H" -le 22 ]
[ "$TUI_W" -le 53 ]

! grep -Fq '< <(tui_geometry' "$ROOT/src/core/tui-widgets.sh"

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
