#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Minimal functions required to source the late override.
bedrock_sysconfig_active() { return 0; }
bedrock_aok_brl() { printf '/tmp/fake-brl\n'; }
bedrock_sysconfig_stratum_pm() { printf 'apt\n'; }
bedrock_sysconfig_strata() { printf 'debian\nubuntu\nkali\n'; }
bedrock_sysconfig_sh_quote() { printf "'%s'" "$1"; }
run_cmd() { :; }

source "$PROJECT_DIR/src/features/zzzzzzzzz-bedrock-sysconfig-latest.sh"

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

best_version_wins() {
    bedrock_sysconfig_package_candidates() {
        printf '1.9.9\tdebian\tapt\n'
        printf '1.10.0\tubuntu\tapt\n'
        printf '1.10.0-2\tkali\tapt\n'
    }
    [ "$(bedrock_sysconfig_best_source demo)" = 'kali|apt|1.10.0-2' ]
}
check "newest version is selected across all strata" best_version_wins

no_interactive_source_prompt() {
    local body
    body=$(declare -f bedrock_sysconfig_install_fallback)
    ! grep -qE 'tui_(radio|yesno|check)' <<< "$body" &&
    grep -q 'bedrock_sysconfig_best_source' <<< "$body"
}
check "install fallback does not prompt for a stratum" no_interactive_source_prompt

install_uses_selected_stratum() {
    local log
    log=$(mktemp)
    trap 'rm -f "${log:-}"' RETURN
    bedrock_sysconfig_best_source() { printf 'ubuntu|apt|3.4.5\n'; }
    bedrock_aok_brl() { printf '/tmp/brl\n'; }
    run_cmd() { printf '%s\n' "$*" >> "$log"; return 0; }
    # Avoid executing the fake brl for enable; the command is allowed to fail.
    bedrock_sysconfig_install_fallback demo >/dev/null 2>&1 || return 1
    grep -q 'Install demo 3.4.5 from Bedrock stratum ubuntu \[apt\].*/tmp/brl install ubuntu demo' "$log"
}
check "installation targets the automatically selected stratum" install_uses_selected_stratum

printf '%d checks, %d failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
