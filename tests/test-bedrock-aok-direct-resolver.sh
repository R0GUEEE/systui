#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

tui_msg(){ :; }
log(){ :; }
warn(){ :; }
bedrock_aok_require(){ return 0; }
bedrock_aok_brl(){ printf '/tmp/fake-brl\n'; }
bedrock_aok_cache_set_url(){ printf '%s %s\n' "$1" "$2" > "$TMPDIR/cache"; }
bedrock_aok_cached_url(){ awk -v t="$1" '$1==t{$1=""; sub(/^ /,""); print; exit}' "$TMPDIR/cache" 2>/dev/null; }
bedrock_aok_mirror_candidates(){ :; }
catalog_recipe(){ [ "$1" = nixos ] && printf 'lxc:nixos:unstable\n'; }
catalog_names(){ printf 'nixos\n'; }

TMPDIR=$(mktemp -d); export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

# shellcheck source=../src/features/67-bedrock-aok-direct-resolver.sh
. "$ROOT/src/features/67-bedrock-aok-direct-resolver.sh"

bedrock_aok_host_arch(){ printf 'arm64\n'; }
bedrock_aok_http_text(){
    case "$1" in
        */nixos/unstable/arm64/default/)
            printf '<a href="20260828_01:01/">old</a>\n<a href="20260829_01:03/">new</a>\n' ;;
        */nixos/unstable/arm64/default/20260829_01:03/)
            printf '<a href="rootfs.tar.xz">rootfs.tar.xz</a>\n' ;;
        *) return 1 ;;
    esac
}

expected='https://images.linuxcontainers.org/images/nixos/unstable/arm64/default/20260829_01:03/rootfs.tar.xz'
url=$(bedrock_aok_resolve_lxc_direct nixos)
[ "$url" = "$expected" ] || { printf 'unexpected URL: %s\n' "$url" >&2; exit 1; }

refreshed=$(bedrock_aok_refresh_one_url nixos)
[ "$refreshed" = "$expected" ]
grep -q "^nixos $expected$" "$TMPDIR/cache"
printf 'ok - direct NixOS LXC resolver selects newest arm64 rootfs\n'

# First normal `brl fetch` fails because its internal lookup_url resolver is
# broken. The Systui path must then invoke `brl fetch-url nixos <resolved-url>`
# directly rather than re-entering `brl fetch nixos`.
: > "$TMPDIR/calls"
run_cmd(){
    local desc="$1"; shift
    printf '%s | %s\n' "$desc" "$*" >> "$TMPDIR/calls"
    case "$*" in
        '/tmp/fake-brl fetch nixos') return 1 ;;
        "/tmp/fake-brl fetch-url nixos $expected") return 0 ;;
        *) return 1 ;;
    esac
}

bedrock_aok_fetch_stratum_resilient nixos
grep -Fq "/tmp/fake-brl fetch nixos" "$TMPDIR/calls"
grep -Fq "/tmp/fake-brl fetch-url nixos $expected" "$TMPDIR/calls"
[ "$(grep -Fc '/tmp/fake-brl fetch nixos' "$TMPDIR/calls")" -eq 1 ]
printf 'ok - failed Bedrock lookup is bypassed with fetch-url\n'
