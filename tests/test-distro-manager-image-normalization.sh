#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FILE="$ROOT/src/features/60-rootfs-docker-image-normalization.sh"
LOAD="$ROOT/src/features/.load-order"

. "$FILE"

[ "$(rootfs_dm_normalize_image_ref aarch64/debian)" = debian ]
[ "$(rootfs_dm_normalize_image_ref arm64v8/debian:trixie)" = debian:trixie ]
[ "$(rootfs_dm_normalize_image_ref arm64/ubuntu:24.04)" = ubuntu:24.04 ]
[ "$(rootfs_dm_normalize_image_ref aarch64/some-third-party)" = aarch64/some-third-party ]
[ "$(rootfs_dm_normalize_image_ref example/debian)" = example/debian ]

a=$(grep -nFx "$(basename "$FILE")" "$LOAD" | cut -d: -f1)
b=$(grep -n -- '-rootfs-ish-argmax-cleanup.sh$' "$LOAD" | tail -n1 | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]

bash -n "$FILE"
printf 'distro-manager image normalization checks passed\n'
