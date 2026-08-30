#!/usr/bin/env bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
F="$ROOT/src/features/83-bedrock-oci-fallback-sources.sh"

bash -n "$F"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Stub prior final functions so phase 83 can wrap them without loading the full TUI.
bedrock_aok_available_strata() { printf 'upstream|upstream\n'; }
bedrock_aok_fetch_stratum_resilient() { return 1; }
bedrock_aok_brl() { printf '/bin/true\n'; }
log() { :; }
tui_msg() { :; }
pm_install() { :; }
export SYSTUI_TMP="$tmp"
# shellcheck source=/dev/null
. "$F"

rows=$(bedrock_aok_oci_builtin_rows)
printf '%s\n' "$rows" | grep -Fq 'nixos|NixOS/Nix — official NixOS Nix image fallback|docker.io/nixos/nix:latest'
printf '%s\n' "$rows" | grep -Fq 'manjaro|Manjaro — project base image fallback|docker.io/manjarolinux/base:latest'
printf '%s\n' "$rows" | grep -Fq 'opensuse|openSUSE Tumbleweed — project image fallback|docker.io/opensuse/tumbleweed:latest'
printf '%s\n' "$rows" | grep -Fq 'fedora|Fedora — Fedora registry fallback|registry.fedoraproject.org/fedora:latest'

catalog=$(bedrock_aok_available_strata)
printf '%s\n' "$catalog" | grep -Fq 'upstream|upstream'
printf '%s\n' "$catalog" | grep -Fq 'nixos|NixOS/Nix — official NixOS Nix image fallback'

# Custom OCI entries are additive and support multiple images for one tag.
cat > "$tmp/oci.conf" <<'EOF'
custom|Custom distro|registry.example/custom:latest
custom|Custom distro backup|registry.example/custom:stable
EOF
BEDROCK_AOK_OCI_SOURCES="$tmp/oci.conf"
imgs=$(bedrock_aok_oci_images_for custom)
[ "$(printf '%s\n' "$imgs" | wc -l | tr -d ' ')" -eq 2 ]
printf '%s\n' "$imgs" | grep -Fq 'registry.example/custom:latest'
printf '%s\n' "$imgs" | grep -Fq 'registry.example/custom:stable'

echo 'ok - Bedrock OCI fallback sources'
