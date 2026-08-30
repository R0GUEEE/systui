#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

tui_msg(){ :; }
run_cmd(){ shift; "$@"; }
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

url=$(bedrock_aok_resolve_lxc_direct nixos)
case "$url" in
    https://images.linuxcontainers.org/images/nixos/unstable/arm64/default/20260829_01:03/rootfs.tar.xz) ;;
    *) printf 'unexpected URL: %s\n' "$url" >&2; exit 1 ;;
esac

bedrock_aok_refresh_one_url nixos
grep -q '^nixos https://images.linuxcontainers.org/images/nixos/unstable/arm64/default/20260829_01:03/rootfs.tar.xz$' "$TMPDIR/cache"

printf 'ok - direct NixOS LXC resolver selects newest arm64 rootfs\n'
