#!/usr/bin/env bash
# Regression for the reported "returned to the main menu after choosing the
# release" bug: an uninstalled backend must not abandon the wizard silently.
# Everything is stubbed; no bootstrap, package or target operation runs.
set -euo pipefail
repo=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export SYSTUI_TMP_ROOT="$tmp" SYSTUI_TMP="$tmp" LOGFILE="$tmp/log"

cat > "$tmp/probe.sh" <<'PROBE'
set -eE
. "$SYSTUI_LIBDIR/src/core/config.sh"
. "$SYSTUI_LIBDIR/src/core/tui-widgets.sh"
. "$SYSTUI_LIBDIR/src/core/common.sh"
. "$SYSTUI_LIBDIR/src/features/rootfs.sh"
trace=$FIXTURE_TRACE
rootfs_backend_catalog() { printf '%s\n' 'debootstrap|Debootstrap (classic Debian bootstrap)'; }
rootfs_backend_supported() { return 0; }
installed=0
rootfs_backend_available() { [ "$installed" = 1 ]; }
tui_msg() { printf 'msg:%s\n' "$1" >> "$trace"; }
tui_yesno() { printf 'yesno:%s\n' "${2%%$'\n'*}" >> "$trace"; [ "$1" = "Rootfs Builder 4/13 — no bootstrap tool" ]; }
menu_rootfs_bootstrap_tools() { printf 'bootstrap-menu\n' >> "$trace"; installed=1; }
tui_radio() { printf 'radio:%s\n' "$1" >> "$trace"; printf 'debootstrap\n'; }

# 1. Nothing installed: the wizard must offer the tools menu, then continue to
#    the backend list in the same invocation instead of returning to Rootfs.
out=$(rootfs_backend_menu debian amd64 trixie)
[ "$out" = debootstrap ] || { printf 'FAIL recovery selection: %s\n' "$out" >&2; exit 1; }
grep -q '^yesno:None of the bootstrap tools' "$trace" || { echo 'FAIL missing install offer' >&2; exit 1; }
grep -q '^bootstrap-menu$' "$trace" || { echo 'FAIL tools menu not opened' >&2; exit 1; }
grep -q '^radio:Rootfs Builder 4/13$' "$trace" || { echo 'FAIL backend list not shown after install' >&2; exit 1; }

# 2. Declining the install is an explicit leave (status 1), never a silent drop.
: > "$trace"
tui_yesno() { printf 'yesno:%s\n' "${2%%$'\n'*}" >> "$trace"; return 1; }
if rootfs_backend_menu debian amd64 trixie >/dev/null; then
    echo 'FAIL decline must return non-zero' >&2; exit 1
fi
grep -q '^bootstrap-menu$' "$trace" && { echo 'FAIL declined install opened menu' >&2; exit 1; }

# 3. A widget that loses the selection must re-ask, not abort the wizard.
: > "$trace"
installed=1
radio_calls_file=$FIXTURE_TRACE.calls
: > "$radio_calls_file"
tui_radio() {
    local n
    n=$(($(cat "$radio_calls_file") + 1))
    printf '%s\n' "$n" > "$radio_calls_file"
    printf 'radio:%s\n' "$1" >> "$trace"
    [ "$n" = 1 ] && { printf ''; return 255; }
    printf 'debootstrap\n'
}
tui_yesno() { printf 'yesno:%s\n' "${2%%$'\n'*}" >> "$trace"; return 1; }
out=$(rootfs_backend_menu debian amd64 trixie)
[ "$out" = debootstrap ] || { printf 'FAIL re-ask selection: %s\n' "$out" >&2; exit 1; }
[ "$(cat "$radio_calls_file")" = 2 ] || { printf 'FAIL expected re-ask, calls=%s\n' "$(cat "$radio_calls_file")" >&2; exit 1; }
printf 'PASS backend recovery: install offer, explicit decline, widget re-ask\n'
PROBE

SYSTUI_LIBDIR="$repo" FIXTURE_TRACE="$tmp/trace" timeout 60 bash "$tmp/probe.sh"
