#!/usr/bin/env bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
F="$ROOT/src/features/98-storage-local-files-final.sh"

bash -n "$F"

tui_menu_no_tags() { printf 'back\n'; }
tui_msg() { :; }
menu_storage() { printf 'legacy-storage\n'; }
systui_local_files_mount() { printf 'mount:%s\n' "$1"; }

. "$F"

declare -F _systui_storage_before_local_files_final >/dev/null
declare -F menu_storage >/dev/null

grep -Fq 'icloud "Mount iCloud at /mnt/iCloud' "$F"
grep -Fq 'iphone "Mount iPhone at /mnt/iPhone' "$F"
grep -Fq 'systui_local_files_mount icloud' "$F"
grep -Fq 'systui_local_files_mount iphone' "$F"
grep -Fq '98-storage-local-files-final.sh' "$ROOT/src/features/.load-order"

echo 'ok - restored iCloud/iPhone storage actions'
