#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
F="$ROOT/src/features/84-bedrock-nixos-direct-source.sh"
LOAD="$ROOT/src/features/.load-order"

bash -n "$F"
grep -Fqx '84-bedrock-nixos-direct-source.sh' "$LOAD"
grep -Fq "printf 'nixos|NixOS — official Hydra container rootfs" "$F"
grep -Fq 'nixos.containerTarball.%s/latest/download-by-type/file/system-tarball' "$F"
grep -Fq 'nixos.proxmoxLXC.%s/latest/download-by-type/file/system-tarball' "$F"
grep -Fq 'aarch64-linux' "$F"
grep -Fq 'x86_64-linux' "$F"
grep -Fq 'bedrock_aok_nixos_fetch_direct' "$F"
grep -Fq 'if [ "$tag" = nixos ]' "$F"
printf 'ok - direct NixOS Bedrock source\n'
