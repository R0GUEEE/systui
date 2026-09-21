#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NAME="zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-package-install-options-final.sh"
FILE="$ROOT/src/features/$NAME"
LOAD="$ROOT/src/features/.load-order"

pass=0
fail=0
check() {
    local desc="$1"; shift
    if "$@"; then printf 'ok: %s\n' "$desc"; pass=$((pass + 1)); else printf 'not ok: %s\n' "$desc" >&2; fail=$((fail + 1)); fi
}
contains() { grep -Fq -- "$2" "$1"; }

check "universal install options layer is present exactly once" bash -c '[ "$(grep -Fxc "$2" "$1")" = 1 ]' _ "$LOAD" "$NAME"
check "universal install options load after package recovery" bash -c '
    a=$(grep -nFx "zzzzzzzzzzzz-package-install-recovery.sh" "$1" | cut -d: -f1)
    b=$(grep -nFx "$2" "$1" | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
' _ "$LOAD" "$NAME"
check "feature has manager discovery" contains "$FILE" 'systui_installed_install_managers()'
check "feature offers Homebrew" contains "$FILE" 'brew install'
check "feature offers Python pip" contains "$FILE" 'python3 -m pip'
check "feature offers npm" contains "$FILE" 'npm install -g'
check "feature offers Nix" contains "$FILE" 'nix profile install'
check "feature offers Snap" contains "$FILE" 'snap install'
check "feature offers yay" contains "$FILE" 'yay -S'
check "feature offers paru" contains "$FILE" 'paru -S'
check "feature offers Cargo" contains "$FILE" 'cargo install'
check "feature offers Custom command" contains "$FILE" 'Custom install command'
check "feature preserves previous pm_install" contains "$FILE" '_systui_pm_install_before_universal_options'
check "feature passes bash syntax" bash -n "$FILE"

# Source just this final layer over a stub native pm_install.  Bypass mode must
# preserve non-interactive callers/tests, while explicit manager selection must
# route to installed secondary managers.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/brew" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "$SYSTUI_TMP/brew.args"
SH
chmod +x "$tmp/brew"
check "bypass mode calls preserved native installer" bash -c '
    validate_packages(){ return 0; }
    run_cmd(){ shift; "$@"; }
    tui_menu(){ return 1; }
    pm_install(){ printf "%s\n" "$*" > "$SYSTUI_TMP/native.args"; }
    export SYSTUI_TMP="$1"
    source "$2"
    SYSTUI_PM_OPTIONS_BYPASS=1 pm_install alpha beta
    grep -Fxq "alpha beta" "$1/native.args"
' _ "$tmp" "$FILE"
check "explicit brew manager routes install" bash -c '
    validate_packages(){ return 0; }
    run_cmd(){ shift; "$@"; }
    tui_menu(){ return 1; }
    pm_install(){ return 99; }
    export SYSTUI_TMP="$1" PATH="$3:$PATH" SYSTUI_INSTALL_MANAGER=brew SYSTUI_PM_OPTION_PROMPT=1
    source "$2"
    pm_install jq
    grep -Fxq "install --formula -- jq" "$1/brew.args"
' _ "$tmp" "$FILE" "$tmp"
check "fallback mode tries native before alternate manager" bash -c '
    validate_packages(){ return 0; }
    run_cmd(){ shift; "$@"; }
    tui_menu(){ return 1; }
    pm_install(){ printf "%s\n" "$*" > "$SYSTUI_TMP/native-fallback.args"; return 42; }
    export SYSTUI_TMP="$1" PATH="$3:$PATH" SYSTUI_PM_FALLBACK_MANAGERS=1 SYSTUI_INSTALL_MANAGER=brew
    source "$2"
    pm_install missing-tool
    grep -Fxq "missing-tool" "$1/native-fallback.args"
    grep -Fxq "install --formula -- missing-tool" "$1/brew.args"
' _ "$tmp" "$FILE" "$tmp"

# --- distribution manager is the default, the chooser is opt-in ---------------
check "native manager is offered even when PM was blanked" bash -c '
    validate_packages(){ return 0; }
    run_cmd(){ return 0; }
    tui_menu(){ return 1; }
    pm_install(){ return 0; }
    export SYSTUI_TMP="$1"
    source "$2"
    PM=""
    systui_installed_install_managers | grep -q "^native|"' _ "$tmp" "$FILE"

check "the native entry names the detected manager" bash -c '
    validate_packages(){ return 0; }
    run_cmd(){ return 0; }
    tui_menu(){ return 1; }
    pm_install(){ return 0; }
    export SYSTUI_TMP="$1"
    source "$2"
    PM=""
    systui_native_manager | grep -qE "^(apt|apk|pacman|dnf|yum|zypper|xbps|emerge)$"' _ "$tmp" "$FILE"

check "plain installs use the distribution manager without prompting" bash -c '
    validate_packages(){ return 0; }
    run_cmd(){ return 0; }
    tui_menu(){ printf "prompted\n" >> "$SYSTUI_TMP/prompts"; return 1; }
    pm_install(){ return 0; }
    export SYSTUI_TMP="$1"
    : > "$SYSTUI_TMP/prompts"
    source "$2"
    _systui_pm_install_before_universal_options(){ printf "native:%s\n" "$*" >> "$SYSTUI_TMP/native"; return 0; }
    pm_install alpha beta
    grep -q "^native:alpha beta$" "$SYSTUI_TMP/native"
    [ ! -s "$SYSTUI_TMP/prompts" ]' _ "$tmp" "$FILE"

check "explicit prompt mode still offers the choice" bash -c '
    validate_packages(){ return 0; }
    run_cmd(){ return 0; }
    tui_menu(){ printf "prompted\n" >> "$SYSTUI_TMP/prompts"; return 1; }
    pm_install(){ return 0; }
    export SYSTUI_TMP="$1"
    : > "$SYSTUI_TMP/prompts"
    source "$2"
    SYSTUI_PM_OPTION_PROMPT=1 pm_install alpha >/dev/null 2>&1 || true
    [ -s "$SYSTUI_TMP/prompts" ]' _ "$tmp" "$FILE"

check "bootstrap fallback offers alternatives only after the native failure" bash -c '
    validate_packages(){ return 0; }
    run_cmd(){ return 0; }
    tui_menu(){ printf "prompted\n" >> "$SYSTUI_TMP/prompts"; return 1; }
    pm_install(){ return 0; }
    export SYSTUI_TMP="$1"
    source "$2"
    : > "$SYSTUI_TMP/prompts"
    _systui_pm_install_before_universal_options(){ return 0; }
    SYSTUI_PM_FALLBACK_MANAGERS=1 pm_install alpha >/dev/null 2>&1 || true
    [ ! -s "$SYSTUI_TMP/prompts" ]' _ "$tmp" "$FILE"

check "bootstrap fallback prompts when the native route fails" bash -c '
    validate_packages(){ return 0; }
    run_cmd(){ return 0; }
    tui_menu(){ printf "prompted\n" >> "$SYSTUI_TMP/prompts"; return 1; }
    pm_install(){ return 0; }
    export SYSTUI_TMP="$1"
    source "$2"
    : > "$SYSTUI_TMP/prompts"
    _systui_pm_install_before_universal_options(){ return 1; }
    SYSTUI_PM_FALLBACK_MANAGERS=1 pm_install alpha >/dev/null 2>&1 || true
    [ -s "$SYSTUI_TMP/prompts" ]' _ "$tmp" "$FILE"

check "documented default is the distribution manager" bash -c '
    grep -q "distribution.s own package manager" "$1"' _ "$FILE"

UNIFIED="$ROOT/src/features/101-unified-package-installation-final.sh"
check "the unified picker resolves the native manager through the shared helper" bash -c '
    body=$(awk "/^systui_package_manager_command\(\)/,/^}/" "$1")
    grep -q "systui_native_manager" <<<"$body"' _ "$UNIFIED"
check "the unified picker hides an unknown native entry" bash -c '
    body=$(awk "/^systui_package_manager_available\(\)/,/^}/" "$1")
    grep -q "native" <<<"$body" && grep -q "unknown" <<<"$body"' _ "$UNIFIED"

printf '\nUniversal install options: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
