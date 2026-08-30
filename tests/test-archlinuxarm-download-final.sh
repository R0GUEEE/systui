#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
F="$ROOT/src/features/100-archlinuxarm-download-final.sh"
LOAD="$ROOT/src/features/.load-order"

bash -n "$F"
grep -Fqx '100-archlinuxarm-download-final.sh' "$LOAD"
grep -Fq 'http://os.archlinuxarm.org' "$F"
grep -Fq 'https://ca.us.mirror.archlinuxarm.org' "$F"
! grep -Fq -- '--insecure' "$F"
! grep -Fq -- ' -k ' "$F"

source "$F"
out=$(systui_archlinuxarm_url_candidates 'https://mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz')
grep -qx 'http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz' <<<"$out"
grep -qx 'https://ca.us.mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz' <<<"$out"

printf 'ok - Arch Linux ARM download endpoint repair\n'
