#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Minimal TUI/runtime stubs; the feature files only need the function names at
# source time. Tests below replace command execution with deterministic fakes.
tui_msg() { :; }
tui_yesno() { return 0; }
tui_input() { printf '%s\n' "${3:-}"; }
tui_menu() { return 1; }
tui_radio() { return 1; }
tui_check() { return 1; }
run_cmd() { shift; "$@"; }
log() { :; }
warn() { :; }
export SYSTUI_TMP="$(mktemp -d)"
trap 'rm -rf "$SYSTUI_TMP"' EXIT

# Load base integration then the late correctness overrides.
# shellcheck source=../src/features/zzz-bedrock-aok.sh
source "$PROJECT_DIR/src/features/zzz-bedrock-aok.sh"
# shellcheck source=../src/features/zzzz-bedrock-aok-menu-fixes.sh
source "$PROJECT_DIR/src/features/zzzz-bedrock-aok-menu-fixes.sh"

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

# Upstream formats fetch --list in four columns. Ensure every token is parsed,
# not just the first name on each row.
fake_brl="$SYSTUI_TMP/brl"
cat > "$fake_brl" <<'BRL'
#!/bin/sh
if [ "$1" = fetch ] && [ "$2" = --list ]; then
    printf '\033[1mStrata available to fetch:\033[0m\n'
    printf '  alpine       debian       ubuntu       kali\n'
    printf '  arch         void         gentoo       fedora\n'
    exit 0
fi
exit 0
BRL
chmod +x "$fake_brl"
bedrock_aok_brl() { printf '%s\n' "$fake_brl"; }

all_fetch_columns() {
    local got
    got=$(bedrock_aok_available_strata | cut -d'|' -f1 | tr '\n' ' ')
    [ "$got" = "alpine debian ubuntu kali arch void gentoo fedora " ]
}
check "fetch parser reads all four output columns" all_fetch_columns

# Self-update must inject the trusted upstream URL required by Bedrock-AOK.
self_update_url_is_set() {
    local out="$SYSTUI_TMP/self-update-env"
    : >"$out"
    # Capture the exact argv that run_cmd dispatches. The self-update action
    # runs `env BRL_SELF_URL=... "$brl" self-update`, so the URL must appear as
    # an environment assignment argument rather than being executed.
    run_cmd() {
        shift
        local arg
        for arg in "$@"; do
            printf '%s\n' "$arg" >>"$out"
        done
        return 0
    }
    bedrock_aok_require() { return 0; }
    bedrock_aok_brl() { printf '%s\n' /bedrock/bin/brl; }
    bedrock_aok_self_update >/dev/null 2>&1 || true
    grep -q '^BRL_SELF_URL=https://raw.githubusercontent.com/vjnzbcsbgf-maker/Bedrock-AOK/main/brl$' "$out"
}
check "self-update supplies BRL_SELF_URL" self_update_url_is_set

# Installed-stratum discovery should only return immediate directories.
installed_strata_are_directories() {
    # Function is hard-coded to /bedrock/strata; validate implementation shape
    # without mutating the host test runner's root filesystem.
    declare -f bedrock_aok_installed_strata | grep -q 'mindepth 1 -maxdepth 1 -type d'
}
check "installed strata selector enumerates directories only" installed_strata_are_directories

# Update menu must not advertise bedrockport --update as a program update;
# upstream maps that operation to brl_update (package updates).
update_menu_is_separated() {
    local body
    body=$(declare -f bedrock_aok_update_menu)
    grep -q 'Update Bedrock-AOK itself from upstream' <<<"$body" &&
    grep -q 'Update packages in all installed strata' <<<"$body" &&
    ! grep -q -- '--force-update' <<<"$body"
}
check "program and stratum updates are distinct" update_menu_is_separated

printf '%d checks, %d failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
