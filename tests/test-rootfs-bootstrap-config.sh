#!/usr/bin/env bash
# Rootfs bootstrap tool configuration and build-mode selection.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FEATURE="$ROOT/src/features/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-rootfs-bootstrap-config.sh"
LOAD="$ROOT/src/features/.load-order"
MULTI="$ROOT/src/features/zzzzzzzzzzzzzz-multi-install-optimizer.sh"

pass=0
fail=0
check() {
    local desc="$1"; shift
    if "$@"; then printf 'ok: %s\n' "$desc"; pass=$((pass + 1)); else printf 'not ok: %s\n' "$desc" >&2; fail=$((fail + 1)); fi
}
contains() { grep -Fq -- "$2" "$1"; }

check "bootstrap configuration layer is registered once" bash -c '[ "$(grep -Fxc "$2" "$1")" = 1 ]' _ "$LOAD" "$(basename "$FEATURE")"
check "layer loads after the automatic-build feature" bash -c '
    a=$(grep -nFx "zzzzzzzzzzzzzzz-rootfs-build-autoconfig.sh" "$1" | cut -d: -f1)
    b=$(grep -nFx "$2" "$1" | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$LOAD" "$(basename "$FEATURE")"
check "layer passes bash syntax" bash -n "$FEATURE"
check "no process substitution in the layer" bash -c '! grep -q "< <(" "$1"' _ "$FEATURE"

# --- menu surface ------------------------------------------------------------
check "bootstrap tools menu offers tool configuration" contains "$FEATURE" 'defaults "Build defaults'
check "bootstrap tools menu offers the build mode switch" contains "$FEATURE" 'mode "Build mode'
check "bootstrap tools menu keeps multi-install and single-tool entries" bash -c '
    grep -q "multi \"Install multiple tools" "$1" && grep -q "single \"Manage individual bootstrap tools" "$1"' _ "$FEATURE"
check "per-tool configuration replaces the static help text" bash -c '
    body=$(awk "/^_bs_config\(\)/,/^}/" "$1")
    grep -q "systui_bsc_tool_config_menu" <<<"$body"' _ "$FEATURE"
check "per-tool configuration edits real files" contains "$FEATURE" 'Edit configuration files'
check "per-tool configuration exposes build defaults" contains "$FEATURE" 'Systui build defaults for'
check "per-tool configuration reports version and requirements" contains "$FEATURE" 'rootfs_backend_requirements'
check "per-tool configuration can set the preferred tool" contains "$FEATURE" 'Use $tag for new builds'

# --- build-mode fix ----------------------------------------------------------
check "automatic builds are opt-in, not forced" bash -c '
    body=$(awk "/^rootfs_builder_impl\(\)/,/^}/" "$1")
    grep -q "systui_bsc_automatic" <<<"$body" &&
    grep -q "_systui_base_rootfs_builder_impl" <<<"$body"' _ "$FEATURE"
check "automatic mode asks for confirmation once" contains "$FEATURE" 'Automatic build'
check "interactive builds bypass the automatic wrapper" bash -c '
    grep -q "Interactive builds must not go through the automatic-mode wrapper" "$1"' _ "$FEATURE"
check "the old unconditional override is superseded" bash -c '
    a=$(grep -n "local SYSTUI_ROOTFS_AUTOMATIC_BUILD=1" "$1" | head -n1 | cut -d: -f1)
    b=$(grep -n "systui_bsc_automatic" "$1" | head -n1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$b" -lt "$a" ]' _ "$FEATURE"
check "preferred tool drives the Automatic backend choice" contains "$FEATURE" 'rootfs_resolve_backend() { # <distro> <selected> [arch] [release]'
check "stored mirror pre-fills the mirror prompt" contains "$FEATURE" 'Rootfs Builder 7/13'
check "stored defaults win over computed ones" bash -c '
    body=$(awk "/^systui_bsc_apply_defaults\(\)/,/^}/" "$1")
    grep -q "ROOTFS_BACKEND_VARIANT" <<<"$body" && grep -q "ROOTFS_MMDEBSTRAP_MODE" <<<"$body"' _ "$FEATURE"

# --- archive packer dependency -------------------------------------------------
check "the packer for the chosen archive is required" bash -c '
    body=$(awk "/^rootfs_backend_missing_cmds\(\)/,/^}/" "$1")
    grep -q "zstd (tar.zst archives)" <<<"$body" &&
    grep -q "xz-utils (tar.xz archives)" <<<"$body"' _ "$ROOT/src/features/rootfs.sh"
check "the packer is verified after the format is chosen" bash -c '
    grep -q "rootfs_check_host_deps \"\$distro\" \"\$backend\" \"\$arch\" \"\$comp\"" "$1"' _ "$ROOT/src/features/rootfs.sh"

# --- behaviour ---------------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/probe.sh" <<PROBE
set -e
SYSTUI_TMP='$tmp'
SYSTUI_STATE_DIR='$tmp/state'
tui_menu() { return 1; }
tui_menu_no_tags() { return 1; }
tui_yesno() { return 1; }
tui_msg() { :; }
tui_text() { :; }
tui_input() { printf '%s\n' "\${3:-}"; }
log() { :; }
rootfs_backend_requirements() { printf 'debootstrap\n'; }
rootfs_backend_command() { printf 'mmdebstrap\n'; }
rootfs_backend_supported() { return 0; }
rootfs_backend_available() { return 0; }
rootfs_backend_config_defaults() { ROOTFS_BACKEND_VARIANT=minbase; ROOTFS_BACKEND_INCLUDE=""; ROOTFS_MMDEBSTRAP_MODE=root; }
rootfs_backend_auto_optimize() { ROOTFS_BACKEND_VARIANT=standard; }
rootfs_resolve_backend() { printf 'debootstrap\n'; }
rootfs_builder_impl() { return 0; }
menu_rootfs_bootstrap_tools() { return 0; }
. "$FEATURE"
PROBE

check "defaults are stored and read back" bash -c '
    . "$1"
    systui_bsc_set variant standard
    systui_bsc_set mmdebstrap_mode unshare
    [ "$(systui_bsc_get variant)" = standard ] &&
    [ "$(systui_bsc_get mmdebstrap_mode)" = unshare ] &&
    [ "$(systui_bsc_get missing_key fallback)" = fallback ]' _ "$tmp/probe.sh"

check "stored file is plain key=value" bash -c '
    . "$1"
    grep -q "^variant=standard$" "$SYSTUI_STATE_DIR/rootfs-bootstrap.conf"' _ "$tmp/probe.sh"

check "build mode defaults to interactive" bash -c '
    . "$1"
    ! systui_bsc_automatic' _ "$tmp/probe.sh"

check "stored automatic mode is honoured" bash -c '
    . "$1"
    systui_bsc_set automatic 1
    systui_bsc_automatic' _ "$tmp/probe.sh"

check "environment overrides the stored build mode" bash -c '
    . "$1"
    SYSTUI_ROOTFS_AUTOMATIC_BUILD=0
    ! systui_bsc_automatic' _ "$tmp/probe.sh"

check "stored defaults are applied over computed ones" bash -c '
    . "$1"
    systui_bsc_set automatic 0
    systui_bsc_set variant custom-variant
    rootfs_backend_auto_optimize debian mmdebstrap
    [ "$ROOTFS_BACKEND_VARIANT" = custom-variant ]' _ "$tmp/probe.sh"

check "preferred tool is used for the Automatic backend" bash -c '
    . "$1"
    systui_bsc_set default_tool mmdebstrap
    [ "$(rootfs_resolve_backend debian auto arm64 bookworm)" = mmdebstrap ]' _ "$tmp/probe.sh"

check "per-tool file list resolves real paths" bash -c '
    . "$1"
    systui_bsc_tool_files mmdebstrap | grep -q "new:/etc/mmdebstrap.conf" &&
    systui_bsc_tool_files schroot | grep -q "/etc/schroot/schroot.conf"' _ "$tmp/probe.sh"

check "every catalogue tool has a configuration entry point" bash -c '
    . "$1"
    missing=""
    for t in debootstrap mmdebstrap cdebootstrap multistrap qemu-user-static binfmt-support \
             arch-install-scripts schroot systemd-container rinse proot fakechroot fakeroot \
             xbps-tools dnf zypper zstd xz-utils; do
        systui_bsc_tool_files "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    [ -z "$missing" ] || { echo "no config entry point:$missing"; exit 1; }' _ "$tmp/probe.sh"

printf '\nRootfs bootstrap configuration: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
