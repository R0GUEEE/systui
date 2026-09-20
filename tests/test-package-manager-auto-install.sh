#!/usr/bin/env bash
# Unattended package-manager installation: every catalogue manager must have an
# automatic installer, and the installation tool must never open a follow-up
# prompt after the user picks managers.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MULTI="$ROOT/src/features/zzzzzzzzzzzzz-package-manager-multiselect.sh"
AUTO="$ROOT/src/features/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-package-manager-auto-install.sh"
LOAD="$ROOT/src/features/.load-order"

pass=0
fail=0
check() {
    local desc="$1"; shift
    if "$@"; then printf 'ok: %s\n' "$desc"; pass=$((pass + 1)); else printf 'not ok: %s\n' "$desc" >&2; fail=$((fail + 1)); fi
}
contains() { grep -Fq -- "$2" "$1"; }

# --- wiring ------------------------------------------------------------------
check "auto-install layer is present exactly once" bash -c '[ "$(grep -Fxc "$2" "$1")" = 1 ]' _ "$LOAD" "$(basename "$AUTO")"
check "auto-install layer loads after the package manager multiselect" bash -c '
    a=$(grep -nFx "zzzzzzzzzzzzz-package-manager-multiselect.sh" "$1" | cut -d: -f1)
    b=$(grep -nFx "$2" "$1" | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$LOAD" "$(basename "$AUTO")"
check "auto-install layer loads after the universal install options layer" bash -c '
    a=$(grep -nFx "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-package-install-options-final.sh" "$1" | cut -d: -f1)
    b=$(grep -nFx "$2" "$1" | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$LOAD" "$(basename "$AUTO")"
check "final ARG_MAX cleanup still loads last" bash -c '
    z=$(grep -vE "^[[:space:]]*(#|$)" "$1" | tail -n1)
    case "$z" in *rootfs-ish-argmax-cleanup.sh) exit 0 ;; *) exit 1 ;; esac' _ "$LOAD"

check "every catalogue manager has an automatic installer" bash -c '
    missing=""
    for tag in $(sed -n "s/^[[:space:]]*\([a-z]*\)|[a-z0-9-]*|.*/\1/p" "$1" | sort -u); do
        grep -q "^sysconfig_pm_auto_${tag}() {" "$2" || missing="$missing $tag"
    done
    [ -z "$missing" ] || { echo "no auto installer:$missing"; exit 1; }' _ "$MULTI" "$AUTO"

check "auto layer redirects the special installer hook" contains "$AUTO" 'sysconfig_pm_multi_special_installer() {'
check "auto layer keeps a menu-mode escape hatch" contains "$AUTO" 'SYSTUI_PM_INSTALL_MODE:-auto}" = menu'
check "auto layer forces non-interactive native installs" bash -c '
    grep -q "SYSTUI_PM_OPTION_PROMPT=0 SYSTUI_PM_OPTIONS_BYPASS=1 \\\\" "$1"' _ "$AUTO"
check "auto layer supports per-manager command overrides" contains "$AUTO" 'SYSTUI_PM_AUTO_${name}'
check "remote installers run with stdin closed" contains "$AUTO" '< /dev/null'
check "layer passes bash syntax" bash -n "$AUTO"
check "multiselect layer still passes bash syntax" bash -n "$MULTI"

# --- behaviour ---------------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/probe.sh" <<PROBE
set -e
SYSTUI_TMP='$tmp'
record='$tmp/calls'
: > "\$record"
menu_package_managers() { :; }
tui_menu() { printf 'tui_menu\n' >> "\$record"; return 1; }
tui_menu_no_tags() { printf 'tui_menu_no_tags\n' >> "\$record"; return 1; }
tui_check() { printf 'tui_check\n' >> "\$record"; return 1; }
tui_radio() { printf 'tui_radio\n' >> "\$record"; return 1; }
tui_yesno() { printf 'tui_yesno\n' >> "\$record"; return 1; }
tui_input() { printf 'tui_input\n' >> "\$record"; return 1; }
tui_msg() { printf 'tui_msg\n' >> "\$record"; return 0; }
log() { printf 'log %s\n' "\$*" >> "\$record"; }
warn() { :; }
run_cmd() { local d="\$1"; shift; printf 'run %s :: %s\n' "\$d" "\$*" >> "\$record"; return 0; }
pm_install() { printf 'pm_install %s\n' "\$*" >> "\$record"; return 0; }
pm_remove() { printf 'pm_remove %s\n' "\$*" >> "\$record"; return 0; }
PM=apt
. "$MULTI"
. "$AUTO"
PROBE

check "special installer hook returns the automatic installer" bash -c '
    . "$1"
    [ "$(sysconfig_pm_multi_special_installer yay)" = sysconfig_pm_auto_yay ] &&
    [ "$(sysconfig_pm_multi_special_installer brew)" = sysconfig_pm_auto_brew ]' _ "$tmp/probe.sh"

check "menu mode restores the original method menus" bash -c '
    . "$1"
    SYSTUI_PM_INSTALL_MODE=menu
    out=$(sysconfig_pm_multi_special_installer yay)
    [ "$out" = menu_yay_install ]' _ "$tmp/probe.sh"

check "unknown tags fall back to the original hook" bash -c '
    . "$1"
    out=$(sysconfig_pm_multi_special_installer nosuchmanager 2>/dev/null || true)
    [ -z "$out" ] || [ "$out" = "" ] || true' _ "$tmp/probe.sh"

check "installing a manager never opens a TUI prompt" bash -c '
    . "$1"
    : > "$SYSTUI_TMP/calls"
    sysconfig_pm_auto_install pip >/dev/null 2>&1 || true
    ! grep -qE "^tui_(menu|check|radio|yesno|input|msg)" "$SYSTUI_TMP/calls"' _ "$tmp/probe.sh"

check "auto install routes through the native package manager" bash -c '
    . "$1"
    : > "$SYSTUI_TMP/calls"
    sysconfig_pm_auto_present() { return 1; }
    sysconfig_pm_auto_install npm >/dev/null 2>&1 || true
    grep -q "^pm_install " "$SYSTUI_TMP/calls"' _ "$tmp/probe.sh"

check "absent managers get an unattended installer for every tag" bash -c '
    . "$1"
    for tag in aptfast nala aptitude flatpak snap pip pipx npm pnpm yarn cargo gem composer go yay paru nix brew; do
        fn="sysconfig_pm_auto_${tag}"
        declare -F "$fn" >/dev/null 2>&1 || { echo "missing $fn"; exit 1; }
    done' _ "$tmp/probe.sh"

check "auto install is a no-op for managers already present" bash -c '
    . "$1"
    : > "$SYSTUI_TMP/calls"
    sysconfig_pm_auto_present() { return 0; }
    sysconfig_pm_auto_install nix >/dev/null 2>&1
    [ ! -s "$SYSTUI_TMP/calls" ]' _ "$tmp/probe.sh"

check "custom per-manager command override wins" bash -c '
    . "$1"
    : > "$SYSTUI_TMP/calls"
    SYSTUI_PM_AUTO_NOSUCHTOOL="printf custom-ran"
    sysconfig_pm_auto_install nosuchtool >/dev/null 2>&1 || true
    grep -q "custom-ran" "$SYSTUI_TMP/calls"' _ "$tmp/probe.sh"

check "selecting a manager in the tool installs it without a method menu" bash -c '
    . "$1"
    : > "$SYSTUI_TMP/calls"
    menu_yay_install() { printf "menu_yay_install\n" >> "$SYSTUI_TMP/calls"; return 0; }
    tui_check() { printf "yay\n"; }
    sysconfig_pm_multi_install >/dev/null 2>&1 || true
    ! grep -q "^menu_yay_install$" "$SYSTUI_TMP/calls"
    ! grep -qE "^tui_(menu|radio|yesno|input)" "$SYSTUI_TMP/calls"' _ "$tmp/probe.sh"

check "the tool reports status through the log, not a dialog" bash -c '
    . "$1"
    : > "$SYSTUI_TMP/calls"
    tui_check() { printf "yay\n"; }
    sysconfig_pm_multi_install >/dev/null 2>&1 || true
    grep -q "^log systui: package managers available:" "$SYSTUI_TMP/calls"
    ! grep -qE "^tui_(msg|menu|radio|yesno|input)" "$SYSTUI_TMP/calls"' _ "$tmp/probe.sh"

check "install-all skips installed managers and reports" bash -c '
    . "$1"
    : > "$SYSTUI_TMP/calls"
    sysconfig_pm_install_all_automatically >/dev/null 2>&1 || true
    grep -q "^log systui: installing " "$SYSTUI_TMP/calls"' _ "$tmp/probe.sh"

printf '\nUnattended package manager installs: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
