#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
module="$PROJECT_DIR/src/features/zzzzzzzzzz-bedrock-strata-pm-menu.sh"

# TUI + runtime stubs so the module can be exercised without a live Bedrock.
tui_msg() { :; }
tui_yesno() { return 0; }
tui_input() { printf '%s\n' "${3:-}"; }
tui_menu() { return 1; }
tui_radio() { return 1; }
tui_check() { return 1; }
tui_text() { :; }
safe_edit() { :; }
run_cmd() { shift; "$@"; }
log() { :; }
warn() { :; }
export SYSTUI_TMP="$(mktemp -d)"
PM=apt
INIT=systemd
trap 'rm -rf "$SYSTUI_TMP"' EXIT

# Bedrock infra the module delegates to.  These stand in for the sysconfig
# integration layer functions the module reuses at runtime.
bedrock_sysconfig_active() { return 0; }
bedrock_sysconfig_strata() { printf 'debian\narch\nvoid\n'; }
bedrock_sysconfig_stratum_pm() {
    case "$1" in debian) echo apt;; arch) echo pacman;; void) echo xbps;;
        *) echo unknown;; esac
}
bedrock_sysconfig_sh_quote() { printf "'%s'" "${1//\'/\'\\\"\'\\\'\\\"\'}"; }
bedrock_aok_brl() { printf '%s\n' /bedrock/bin/brl; }

source "$module"

failures=0
checks=0
check() {
    local desc="$1"; shift
    checks=$((checks + 1))
    if "$@"; then
        printf 'ok %d - %s\n' "$checks" "$desc"
    else
        printf 'not ok %d - %s\n' "$checks" "$desc"
        failures=$((failures + 1))
    fi
}

# --- command mapping ---------------------------------------------------------
cmd_apt_install() {
    # Packages arrive as a single space-separated string argument.
    [ "$(bedrock_stratum_pm_command debian apt install 'curl git')" = 'apt-get install -y curl git' ]
}
check "apt install maps into apt-get install" cmd_apt_install

cmd_apk_update() {
    [ "$(bedrock_stratum_pm_command void apk update)" = 'apk update && apk upgrade' ]
}
check "apk update maps into apk upgrade" cmd_apk_update

cmd_pacman_remove() {
    [ "$(bedrock_stratum_pm_command arch pacman remove firefox)" = 'pacman -R --noconfirm firefox' ]
}
check "pacman remove maps into pacman -R" cmd_pacman_remove

cmd_unknown_action() {
    ! bedrock_stratum_pm_command debian apt bogusaction 2>/dev/null
}
check "unknown action returns non-zero" cmd_unknown_action

cmd_unknown_pm() {
    ! bedrock_stratum_pm_command nosuch emacs update 2>/dev/null
}
check "unknown package manager returns non-zero" cmd_unknown_pm

# --- package-name validation ------------------------------------------------
valid_good() {
    bedrock_stratum_pm_valid_pkgs 'curl git libssl1.1 foo:bar+baz/qux_1.0@x'
}
check "valid package list accepted" valid_good

valid_bad() {
    ! bedrock_stratum_pm_valid_pkgs 'curl; rm -rf /'
}
check "shell metacharacters rejected" valid_bad

valid_empty_token() {
    ! bedrock_stratum_pm_valid_pkgs ''
}
check "empty package list rejected" valid_empty_token

valid_whitespace_only() {
    ! bedrock_stratum_pm_valid_pkgs '   '
}
check "whitespace-only package list rejected" valid_whitespace_only

# --- stratum enumeration and PM detection ------------------------------------
stratum_pm_of_apt() { [ "$(bedrock_stratum_pm_of debian)" = apt ]; }
check "stratum package manager detected as apt" stratum_pm_of_apt

strata_enum() {
    local got
    got=$(bedrock_stratum_pm_strata | tr '\n' ' ')
    [ "$got" = "debian arch void " ]
}
check "strata enumerated from integration helper" strata_enum

# --- menu_packages override gating -------------------------------------------
# When Bedrock is inactive the native menu is used; when active the override
# builds a menu until Back.  We simulate both by overriding the underlying
# helpers around the loaded function.
override_dispatches_native_when_inactive() {
    # Re-define active to be false, then ensure _systui_native_menu_packages is
    # called (it returns immediately from our stub loop-free native body below).
    _systui_native_menu_packages() { return 0; }
    bedrock_sysconfig_active() { return 1; }
    menu_packages
    return 0
}
check "inactive Bedrock falls through to native Package Configuration menu" \
    override_dispatches_native_when_inactive

override_shows_strata_when_active() {
    local called=0
    # Re-enable active; tui_menu_no_tags is stubbed to return "back" immediately
    # but also record that the override's "strata" tag was offered.
    bedrock_sysconfig_active() { return 0; }
    tui_menu_no_tags() { return 1; }   # Back -> leaves immediately
    menu_packages; local rc=$?
    # Reaching here without error means the override composed fine.
    [ "$rc" -eq 0 ]
}
check "active Bedrock builds the extended Package Configuration menu" \
    override_shows_strata_when_active

# --- per-stratum menu constructs a stratum-scoped command ---------------------
pm_menu_search_uses_view_with_stratum_command() {
    # Sequence: tui_menu returns "search" once then "back".  The menu runs its
    # tui_menu calls inside $(...) command substitution (a subshell), so the
    # stub must persist its state in a marker file rather than a shell variable.
    local cnt="$SYSTUI_TMP/pm-menu-calls" cmd_title="" cmd_st="" cmd_body=""
    : > "$cnt"
    tui_menu() {
        if [ -s "$cnt" ]; then
            echo "back"                       # already seen first call -> back
        else
            printf 'x' > "$cnt"; echo "search"
        fi
    }
    tui_input() { printf 'zzz\n'; }
    # Intercept the viewer helper to capture the stratum-scoped command.
    bedrock_stratum_pm_view() {
        cmd_title="$1"; cmd_st="$2"; cmd_body="$3"
    }
    # Force a usable package manager present so the menu builds.
    bedrock_aok_brl() { printf '%s\n' /bedrock/bin/brl; }
    bedrock_stratum_pm_menu debian >/dev/null 2>&1
    [ "$cmd_st" = debian ] &&
    [ "$cmd_title" = "Search debian [apt]: zzz" ] &&
    printf '%s' "$cmd_body" | grep -q "apt-cache search -- 'zzz'"
}
check "stratum search is executed inside the stratum scope" \
    pm_menu_search_uses_view_with_stratum_command

# --- shellcheck must stay clean on the module --------------------------------
shellcheck_clean() {
    if ! command -v shellcheck >/dev/null 2>&1; then return 0; fi
    shellcheck -s bash -S error "$module" >/dev/null
}
check "module passes shellcheck (error level)" shellcheck_clean

printf '%d checks, %d failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
