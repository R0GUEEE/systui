#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FILE="$ROOT/src/features/zzzzzzzzzzzz-package-install-recovery.sh"
LOAD="$ROOT/src/features/.load-order"

pass=0
fail=0
check() {
    local desc="$1"; shift
    if "$@"; then
        printf 'ok: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'not ok: %s\n' "$desc" >&2
        fail=$((fail + 1))
    fi
}
contains() { grep -Fq -- "$2" "$1"; }

check "package recovery layer is loaded last" bash -c '[ "$(tail -n 1 "$1")" = zzzzzzzzzzzz-package-install-recovery.sh ]' _ "$LOAD"
check "installer has a batch command helper" contains "$FILE" 'systui_pm_install_batch()'
check "initial install passes the full requested array in one command" contains "$FILE" 'systui_pm_install_batch "${requested[@]}"'
check "failed installs refresh package indexes" contains "$FILE" 'systui_pm_refresh_indexes || true'
check "retry batches all still-missing packages" contains "$FILE" 'systui_pm_install_batch "${missing[@]}"'
check "repository retry batches all unresolved packages" contains "$FILE" 'systui_pm_install_batch "${after_repo[@]}"'
check "repository recovery analyzes package availability" contains "$FILE" 'systui_pkg_availability_report'
check "repository recovery offers an add-repository prompt" contains "$FILE" 'Add repository?'
check "Ubuntu repository recovery offers Universe" contains "$FILE" 'Enable Ubuntu Universe'
check "Debian repository recovery offers non-free firmware" contains "$FILE" 'non-free + non-free-firmware'
check "Alpine repository recovery offers community" contains "$FILE" 'Enable $release/community'
check "Fedora repository recovery offers RPM Fusion" contains "$FILE" 'Enable RPM Fusion Free'
check "multi installs skip unresolved packages" contains "$FILE" 'Packages skipped'
check "single installs return to the previous menu on failure" contains "$FILE" 'Returning to the previous menu.'
check "Pacman refresh does not install packages during metadata refresh" contains "$FILE" 'pacman -Syy --noconfirm'

bash -n "$FILE"
check "package recovery layer passes bash syntax" true

printf '\nPackage install recovery: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
