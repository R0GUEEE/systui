#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

fail=0
check() {
    local name="$1"; shift
    if "$@"; then printf 'ok - %s\n' "$name"; else printf 'not ok - %s\n' "$name"; fail=1; fi
}

tui_msg() { :; }
log() { :; }
warn() { :; }
export SYSTUI_TMP="$tmp/work"
mkdir -p "$SYSTUI_TMP" "$tmp/bedrock/etc"

# shellcheck source=../src/features/66-bedrock-aok-strata-fallbacks.sh
. "$ROOT/src/features/66-bedrock-aok-strata-fallbacks.sh"

bedrock_aok_url_cache_file() { printf '%s\n' "$tmp/bedrock/etc/urls.cache"; }
bedrock_aok_require() { return 0; }
bedrock_aok_brl() { printf '%s\n' "$tmp/brl"; }
printf '#!/bin/sh\nexit 0\n' > "$tmp/brl"; chmod +x "$tmp/brl"

primary='https://images.linuxcontainers.org/images/debian/trixie/arm64/default/20260829_05:24/rootfs.tar.xz'
us='https://us.lxd.images.canonical.com/images/debian/trixie/arm64/default/20260829_05:24/rootfs.tar.xz'
uk='https://uk.lxd.images.canonical.com/images/debian/trixie/arm64/default/20260829_05:24/rootfs.tar.xz'
printf 'debian %s\n' "$primary" > "$tmp/bedrock/etc/urls.cache"

mirrors_are_generated() {
    local got
    got=$(bedrock_aok_mirror_candidates "$primary")
    grep -qxF "$us" <<<"$got" && grep -qxF "$uk" <<<"$got"
}
check "LinuxContainers URL yields US and UK mirrors" mirrors_are_generated

# Primary and refreshed primary fail; US fails; UK succeeds.
attempt=0
run_cmd() {
    local desc="$1"; shift
    case "$desc" in
        "Refreshing Bedrock-AOK stratum URLs") return 0 ;;
    esac
    attempt=$((attempt + 1))
    case "$attempt" in
        1|2|3) return 1 ;;
        4) return 0 ;;
        *) return 1 ;;
    esac
}
check "fetch succeeds on alternate mirror" bedrock_aok_fetch_stratum_resilient debian
check "working UK mirror remains cached" bash -c 'grep -qxF "debian $1" "$2"' _ "$uk" "$tmp/bedrock/etc/urls.cache"

# All attempts fail: the upstream-resolved URL must be restored, not the last
# failed mirror.
printf 'debian %s\n' "$primary" > "$tmp/bedrock/etc/urls.cache"
run_cmd() {
    local desc="$1"; shift
    case "$desc" in
        "Refreshing Bedrock-AOK stratum URLs") return 0 ;;
        *) return 1 ;;
    esac
}
set +e
bedrock_aok_fetch_stratum_resilient debian >/dev/null 2>&1
rc=$?
set -e
check "all-source failure is reported" test "$rc" -ne 0
check "failed mirrors restore upstream URL" bash -c 'grep -qxF "debian $1" "$2"' _ "$primary" "$tmp/bedrock/etc/urls.cache"

exit "$fail"
