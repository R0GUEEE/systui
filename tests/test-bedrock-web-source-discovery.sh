#!/bin/bash
set -euo pipefail

f=src/features/82-bedrock-web-source-discovery.sh
manifest=src/features/.load-order

bash -n "$f"
grep -qx '82-bedrock-web-source-discovery.sh' "$manifest"
grep -q 'dl-cdn.alpinelinux.org/alpine/latest-stable/releases' "$f"
grep -q 'cdimage.ubuntu.com/ubuntu-base/releases' "$f"
grep -q 'repo-default.voidlinux.org/live/current' "$f"
grep -q 'distfiles.gentoo.org/releases' "$f"
grep -q 'systui-discovered-sources.cache' "$f"
grep -q 'BEDROCK_AOK_DISCOVERY_TTL' "$f"
grep -q 'void-musl' "$f"
grep -q 'gentoo-systemd' "$f"
grep -q 'bedrock_aok_discovery_refresh' "$f"
grep -q 'bedrock_aok_discovery_rows' "$f"
grep -q 'Scan distro web indexes now' "$f"

echo 'ok - Bedrock discovers and caches alternate distro sources from official web indexes'
