#!/usr/bin/env bash
set -euo pipefail

F=src/features/81-bedrock-additional-distro-sources.sh
[ -f "$F" ]
bash -n "$F"

grep -q 'BEDROCK_AOK_EXTRA_SOURCES' "$F"
grep -q 'alpine-minirootfs' "$F"
grep -q 'ubuntu-base-26.04-base' "$F"
grep -q 'repo-default.voidlinux.org/live/current' "$F"
grep -q 'current-stage3-' "$F"
grep -q 'ArchLinuxARM-aarch64-latest.tar.gz' "$F"
grep -q 'bedrock_aok_extra_source_urls' "$F"
grep -q 'bedrock_aok_fetch_stratum_resilient' "$F"
grep -q 'bedrock_aok_available_strata' "$F"
grep -q 'systui-distro-sources.conf' "$F"

line=$(grep -n '^81-bedrock-additional-distro-sources.sh$' src/features/.load-order | cut -d: -f1)
line80=$(grep -n '^80-busybox-rootfs-init-final.sh$' src/features/.load-order | cut -d: -f1)
line90=$(grep -n '^90-install-guard-final.sh$' src/features/.load-order | cut -d: -f1)
[ "$line80" -lt "$line" ]
[ "$line" -lt "$line90" ]

# Custom-only distro must be merged into the picker even when upstream emits none.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/test.sh" <<EOF
set -e
SYSTUI_TMP='$tmp'
BEDROCK_AOK_EXTRA_SOURCES='$tmp/sources.conf'
bedrock_aok_available_strata() { return 1; }
bedrock_aok_fetch_stratum_resilient() { return 1; }
bedrock_aok_host_arch() { printf 'arm64\n'; }
bedrock_aok_http_text() { return 1; }
bedrock_aok_brl() { printf '/bin/false\n'; }
bedrock_aok_cache_set_url() { :; }
run_cmd() { return 1; }
log() { :; }
tui_msg() { :; }
tui_menu() { return 1; }
tui_text() { :; }
safe_edit() { :; }
bedrock_aok_refresh_urls_resilient() { :; }
bedrock_aok_fetch_menu() { :; }
bedrock_aok_strata_menu() { :; }
printf 'customos|Custom OS|https://example.invalid/custom-{arch}.tar.xz\n' > '$tmp/sources.conf'
source '$F'
bedrock_aok_available_strata | grep -q '^customos|Custom OS'
bedrock_aok_extra_source_urls customos | grep -q 'custom-arm64.tar.xz'
EOF
bash "$tmp/test.sh"

echo 'PASS: Bedrock alternate distro sources'
