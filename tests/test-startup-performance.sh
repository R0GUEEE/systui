#!/usr/bin/env bash
# Guards the startup optimizations: fork-free function aliasing, batched export
# scrubbing, and Bedrock wrapper work deferred until Bedrock is actually used.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMMON="$ROOT/src/core/common.sh"
ALIAS="$ROOT/src/core/alias.sh"
LOADER="$ROOT/src/core/loader.sh"
PROFILE="$ROOT/tools/feature-profile.sh"

pass=0
fail=0
check() {
    local desc="$1"; shift
    if "$@"; then printf 'ok: %s\n' "$desc"; pass=$((pass + 1)); else printf 'not ok: %s\n' "$desc" >&2; fail=$((fail + 1)); fi
}

check "core provides the fork-free function alias helper" bash -c 'grep -q "^systui_alias_function()" "$1"' _ "$ALIAS"
check "core loads the alias helper module" bash -c 'grep -q "src/core/alias.sh" "$1"' _ "$COMMON"
check "features can source the alias helper on their own" bash -c '
    n=$(grep -l "systui_alias_function" "$1"/src/features/*.sh | wc -l)
    b=$(grep -l "src/core/alias.sh" "$1"/src/features/*.sh | wc -l)
    [ "$n" -gt 0 ] && [ "$b" -ge "$n" ]' _ "$ROOT"
check "alias helper captures with a reusable file, not a command substitution" bash -c '
    body=$(awk "/^systui_alias_function\(\)/,/^}/" "$1")
    ! grep -q "declare -f \"\$src\")\|declare -f \$src)" <<<"$body"
    grep -q "declare -f \"\$src\" > \"\$def\"" <<<"$body"
    grep -q "mapfile -t lines" <<<"$body"' _ "$ALIAS"
check "alias helper sets IFS on its own line before eval" bash -c '
    body=$(awk "/^systui_alias_function\(\)/,/^}/" "$1")
    grep -q "local IFS=\\$'"'"'\\\\n'"'"'" <<<"$body"' _ "$ALIAS"

check "loader batches the export scrub" bash -c 'grep -q "systui_scrub_interval" "$1"' _ "$LOADER"
check "loader default interval is 4" bash -c 'grep -q "SYSTUI_SCRUB_INTERVAL:-4" "$1"' _ "$LOADER"
# Only the multi-line awk filter in rootfs-delete-no-confirm.sh legitimately
# needs an external filter; every other rename uses systui_alias_function.
check "no feature forks sed/awk just to rename a function" bash -c '
    n=$(grep -hE "declare -f[^|]*\|[[:space:]]*(sed|awk)" "$1"/src/features/*.sh \
        | grep -v "^[[:space:]]*#" | wc -l)
    [ "$n" -le 1 ] || { echo "$n remaining pipelines"; exit 1; }' _ "$ROOT"
check "wrap loops skip work when Bedrock is absent" bash -c '
    grep -q "SYSTUI_BEDROCK_TARGET_WRAPPERS" "$1/src/features/88-bedrock-global-install-targets.sh" &&
    grep -q "\[ -d /bedrock \]" "$1/src/features/88-bedrock-global-install-targets.sh" &&
    grep -q "\[ ! -d /bedrock \]" "$1/src/features/89-bedrock-pm-install-routing.sh"' _ "$ROOT"
check "Bedrock wrappers can be forced for tests and reduced builds" bash -c '
    grep -q "SYSTUI_BEDROCK_WRAP_INSTALL_MENUS" "$1/src/features/88-bedrock-global-install-targets.sh"' _ "$ROOT"
check "opening the Bedrock menu creates missing wrappers" bash -c '
    grep -q "systui_bedrock_ensure_install_wrappers" "$1/src/features/zzzzzz-bedrock-aok-system-manager.sh"' _ "$ROOT"
check "the profiler stays available to measure regressions" test -x "$PROFILE"

printf '\nStartup performance guards: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
