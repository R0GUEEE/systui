#!/usr/bin/env bash
# Ultimate Provision: package-set tuning, service pass switch, and an accurate
# install status once compatibility patches have been applied.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FEATURE="$ROOT/src/features/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-provision-config.sh"
SCRIPT="$ROOT/src/provision/provision-ultimate.sh"
MENU="$ROOT/src/features/ultimate-provision.sh"
LOAD="$ROOT/src/features/.load-order"

pass=0
fail=0
check() {
    local desc="$1"; shift
    if "$@"; then printf 'ok: %s\n' "$desc"; pass=$((pass + 1)); else printf 'not ok: %s\n' "$desc" >&2; fail=$((fail + 1)); fi
}
contains() { grep -Fq -- "$2" "$1"; }

check "provision configuration layer is registered once" bash -c '[ "$(grep -Fxc "$2" "$1")" = 1 ]' _ "$LOAD" "$(basename "$FEATURE")"
check "layer loads after the rootfs bootstrap configuration layer" bash -c '
    a=$(grep -nFx "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-rootfs-bootstrap-config.sh" "$1" | cut -d: -f1)
    b=$(grep -nFx "$2" "$1" | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$LOAD" "$(basename "$FEATURE")"
check "layer passes bash syntax" bash -n "$FEATURE"
check "no process substitution in the layer" bash -c '! grep -q "< <(" "$1"' _ "$FEATURE"

# --- status accuracy ---------------------------------------------------------
check "status compares against the patched payload" bash -c '
    grep -q "script_provision_expected_file" "$1"' _ "$FEATURE"
check "the expected payload applies every compat patch" bash -c '
    body=$(awk "/^script_provision_expected_file\(\)/,/^}/" "$1")
    grep -q "script_provision_patch_init_detection" <<<"$body" &&
    grep -q "script_provision_patch_apt_nonblocking" <<<"$body" &&
    grep -q "script_provision_patch_apt_batches" <<<"$body"' _ "$FEATURE"

# --- package set and services -------------------------------------------------
check "the menu exposes the package-set configuration" bash -c '
    grep -q "packages \"Package set" "$1"' _ "$FEATURE"
check "extra and excluded packages are configurable" bash -c '
    grep -q "SCRIPT_PROV_EXTRA_PKGS" "$1" && grep -q "SCRIPT_PROV_SKIP_PKGS" "$1"' _ "$FEATURE"
check "the service pass can be disabled" bash -c '
    grep -q "SCRIPT_PROV_SKIP_SERVICES" "$1"' _ "$FEATURE"
check "settings are persisted with the other provision options" bash -c '
    body=$(awk "/^script_provision_save\(\)/,/^}/" "$1")
    grep -q "SCRIPT_PROV_EXTRA_PKGS" <<<"$body"' _ "$FEATURE"
check "the run passes the tuning through the environment" bash -c '
    grep -q "EXTRA_PKGS=\"\${SCRIPT_PROV_EXTRA_PKGS:-}\"" "$1" &&
    grep -q "SKIP_SERVICES=\"\${SCRIPT_PROV_SKIP_SERVICES:-0}\"" "$1"' _ "$ROOT/src/features/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-ultimate-provision-install-rescue.sh"
check "the provision script honours the tuned package set" bash -c '
    grep -q "EXTRA_PKGS" "$1" && grep -q "SKIP_PKGS" "$1" && grep -q "SKIP_SERVICES" "$1" && grep -q "PROVISION_DRY_RUN" "$1"' _ "$SCRIPT"
check "the source path no longer depends on LIBDIR alone" bash -c '
    body=$(awk "/^script_provision_source_path\(\)/,/^}/" "$1")
    grep -q "SYSTUI_LIBDIR" <<<"$body" && grep -q "BASH_SOURCE" <<<"$body"' _ "$MENU"

# --- behaviour ---------------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/probe.sh" <<PROBE
set -e
SYSTUI_TMP='$tmp'
SYSTUI_STATE_DIR='$tmp/state'
SYSTUI_PROVISION_TOOL='$tmp/provision-ultimate'
SYSTUI_PROVISION_CONFIG='$tmp/provision.conf'
DIALOG=true
BACKTITLE=x
PM=apk
INIT=unknown
tui_menu() { return 1; }
tui_input() { printf '%s\n' "\${3:-}"; }
tui_yesno() { return 1; }
tui_msg() { :; }
tui_text() { :; }
warn() { :; }
log() { :; }
LIBDIR='$ROOT'
. "$ROOT/src/core/config.sh" >/dev/null 2>&1
. "$ROOT/src/core/common.sh" >/dev/null 2>&1
. "$ROOT/src/features/ultimate-provision.sh" >/dev/null 2>&1
. "$ROOT/src/features/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-ultimate-provision-install-rescue.sh" >/dev/null 2>&1
# Stand in for the real compatibility patches: whatever they do on this host, the
# status logic must compare against the patched result, not the pristine payload.
script_provision_patch_init_detection() { printf '# stub-patch\\n' >> "\$1"; }
. "$FEATURE"
PROBE

check "source path resolves without LIBDIR" bash -c '
    . "$1"
    LIBDIR=""
    [ -r "$(script_provision_source_path)" ]' _ "$tmp/probe.sh"

check "a freshly installed tool reports as current" bash -c '
    . "$1"
    script_provision_install_tool >/dev/null 2>&1
    [ "$(script_provision_tool_status)" = "installed (current)" ]' _ "$tmp/probe.sh"

check "the installed tool really is patched (differs from the payload)" bash -c '
    . "$1"
    ! cmp -s "$(script_provision_source_path)" "$SYSTUI_PROVISION_TOOL"' _ "$tmp/probe.sh"

check "an out-of-date tool is still detected" bash -c '
    . "$1"
    printf "# locally modified\n" >> "$SYSTUI_PROVISION_TOOL"
    case "$(script_provision_tool_status)" in
        "installed (update available"*) exit 0 ;;
        *) exit 1 ;;
    esac' _ "$tmp/probe.sh"

check "package and service settings survive a save/load round trip" bash -c '
    . "$1"
    SCRIPT_PROV_EXTRA_PKGS="btop neofetch"
    SCRIPT_PROV_SKIP_PKGS="openssh-server rsyslog"
    SCRIPT_PROV_SKIP_SERVICES=1
    script_provision_save
    SCRIPT_PROV_EXTRA_PKGS=""; SCRIPT_PROV_SKIP_PKGS=""; SCRIPT_PROV_SKIP_SERVICES=0
    script_provision_load
    [ "$SCRIPT_PROV_EXTRA_PKGS" = "btop neofetch" ] &&
    [ "$SCRIPT_PROV_SKIP_PKGS" = "openssh-server rsyslog" ] &&
    [ "$SCRIPT_PROV_SKIP_SERVICES" = 1 ]' _ "$tmp/probe.sh"

check "the settings file keeps the original keys" bash -c '
    . "$1"
    grep -q "^SCRIPT_PROV_TZ=" "$SYSTUI_PROVISION_CONFIG" &&
    grep -q "^SCRIPT_PROV_EXTRA_PKGS=" "$SYSTUI_PROVISION_CONFIG"' _ "$tmp/probe.sh"

check "dry run prints the tuned set and changes nothing" bash -c '
    out=$(PROVISION_DRY_RUN=1 EXTRA_PKGS=dryrun-marker SKIP_PKGS=figlet \
          TZ_NAME=UTC TARGET_USER=nobody NEW_HOSTNAME=box sh "$1" 2>&1)
    list=$(printf "%s\n" "$out" | sed -n "/^    packages (/,/services:/p")
    grep -q "dryrun-marker" <<<"$list" &&
    ! grep -qw "figlet" <<<"$list" &&
    grep -q "Dry run" <<<"$out"' _ "$SCRIPT"

check "dry run reports the service pass state" bash -c '
    out=$(PROVISION_DRY_RUN=1 SKIP_SERVICES=1 TZ_NAME=UTC sh "$1" 2>&1)
    grep -q "services: skipped" <<<"$out"' _ "$SCRIPT"

printf '\nUltimate Provision configuration: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
