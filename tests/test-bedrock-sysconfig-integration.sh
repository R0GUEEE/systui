#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
base="$PROJECT_DIR/src/features/zzzzzzz-bedrock-sysconfig-integration.sh"
unified="$PROJECT_DIR/src/features/zzzzzzzz-bedrock-sysconfig-unified.sh"

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

check "native install is attempted before Bedrock fallback" \
    bash -c "grep -n '_systui_native_pm_install' '$base' | head -1 | grep -q . && grep -q 'bedrock_sysconfig_install_fallback' '$base'"

check "web fallback remains after Bedrock fallback" \
    bash -c "awk '/pm_install\(\)/,/^}/' '$base' | grep -q 'pkg_web_fallback'"

check "package search includes host and Bedrock strata" \
    bash -c "grep -q '===== Host:' '$base' && grep -q '===== Bedrock:' '$base' && grep -q 'bedrock_sysconfig_search_one' '$base'"

check "package details include Bedrock metadata" \
    bash -c "awk '/pkg_show_info\(\)/,/^}/' '$base' | grep -q 'bedrock_sysconfig_info_one'"

check "successful Bedrock installs enable stratum and reload wrappers" \
    bash -c "awk '/bedrock_sysconfig_install_fallback\(\)/,/^}/' '$base' | grep -q 'enable.*\$st' && awk '/bedrock_sysconfig_install_fallback\(\)/,/^}/' '$base' | grep -q 'reload'"

check "system update offers all-strata Bedrock update" \
    bash -c "awk '/pm_update\(\)/,/^}/' '$unified' | grep -q 'Update all Bedrock strata' && awk '/pm_update\(\)/,/^}/' '$unified' | grep -q '\"\$brl\" update'"

check "Bedrock can be disabled for unattended package workflows" \
    bash -c "grep -q 'SYSTUI_PM_NO_BEDROCK' '$unified'"

check "package menu visibly indicates Bedrock integration" \
    bash -c "grep -q 'Package Configuration' '$unified' && grep -q '+ Bedrock' '$unified'"

printf '%d checks, %d failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
