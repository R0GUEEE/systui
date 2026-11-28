#!/usr/bin/env bash
# Menu -> guided builder -> release -> backend, with the real manifest and strict child.
# No bootstrap, package install, network lookup, or target write is permitted.
set -euo pipefail
repo=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export SYSTUI_LIBDIR="$repo" SYSTUI_TMP_ROOT="$tmp" SYSTUI_LOGFILE="$tmp/log"
export SYSTUI_STATE_DIR="$tmp/state" SYSTUI_ROOTFS_AUTOMATIC_BUILD=0
export DIALOG="$tmp/dialog" FIXTURE_TRACE="$tmp/trace"
cat > "$DIALOG" <<'DIALOG_FIXTURE'
#!/usr/bin/env bash
case "$*" in
    *'--title Rootfs Builder 1/13 --'*) printf 'debian\n' >&2 ;;
    *'--title Rootfs Builder 2/13 --'*) printf 'amd64\n' >&2 ;;
    *'--title Rootfs Builder 3/13 --'*) printf 'trixie\n' >&2 ;;
    *'--title Rootfs Builder 4/13 --'*) printf 'mmdebstrap\n' >&2 ;;
    # Rootfs is an index: the first answer opens the acquire group, the second
    # picks the guided build inside it.
    *'--title Rootfs --'*)
        if [ -e "${FIXTURE_TRACE}.group" ]; then printf 'back\n' >&2
        else : > "${FIXTURE_TRACE}.group"; printf 'acquire\n' >&2; fi ;;
    *'--title Rootfs — build or acquire --'*)
        if [ -e "${FIXTURE_TRACE}.menu" ]; then printf 'back\n' >&2
        else : > "${FIXTURE_TRACE}.menu"; printf 'build\n' >&2; fi ;;
    *) printf 'Unexpected dialog: %s\n' "$*" >&2; exit 90 ;;
esac
printf '%s\n' "$*" >> "$FIXTURE_TRACE"
DIALOG_FIXTURE
chmod +x "$DIALOG"
# Load the production functions in manifest order (base, automatic, config,
# final Rootfs menu). The full manifest initializes unrelated platform modules.
# The fixture supplies only the backend availability and the stage-4 stop.
cat > "$tmp/probe.sh" <<'PROBE'
set -eE
. "$SYSTUI_LIBDIR/src/core/config.sh"
. "$SYSTUI_LIBDIR/src/core/tui-widgets.sh"
. "$SYSTUI_LIBDIR/src/core/common.sh"
. "$SYSTUI_LIBDIR/src/features/rootfs.sh"
. "$SYSTUI_LIBDIR/src/features/zzzzzzzzzzzzzzz-rootfs-build-autoconfig.sh"
. "$SYSTUI_LIBDIR/src/features/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-rootfs-bootstrap-config.sh"
. "$SYSTUI_LIBDIR/src/features/113-ish-aok-sysconfig-integration.sh"
# Exercise the same builder/menu functions in-process so only the selected
# fixture modules are loaded; run_strict's production child loads every feature
# and probes the host before reaching the wizard.
run_strict() { shift; "$@"; }
rootfs_backend_available() { [ "$1" = mmdebstrap ]; }
rootfs_backend_menu() {
    printf 'backend-entered:%s:%s:%s\n' "$1" "$2" "$3" >> "$FIXTURE_TRACE"
    _systui_base_rootfs_backend_menu "$@" || return 1
    return 1  # deliberate stop before host dependencies or target operations
}
# menu_rootfs is an index now: acquire -> build runs the guided wizard.
menu_rootfs_acquire() { rootfs_builder; }
menu_rootfs
PROBE
# A timeout protects against accidental loops if the wizard exits too early.
if ! timeout 45 bash "$tmp/probe.sh" > "$tmp/out" 2> "$tmp/err"; then
    printf 'Guided release fixture failed; stderr:\n' >&2
    cat "$tmp/err" >&2
    exit 1
fi
if ! grep -q '^backend-entered:debian:amd64:trixie$' "$FIXTURE_TRACE"; then
    printf 'Regression: selecting release did not continue to backend. Trace:\n' >&2
    cat "$FIXTURE_TRACE" >&2
    exit 1
fi
printf 'PASS rootfs release choice continues to backend with production loader\n'
