#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

fail=0
check() {
    local name="$1"; shift
    if "$@"; then printf 'ok - %s\n' "$name"; else printf 'not ok - %s\n' "$name"; fail=1; fi
}

tui_msg() { :; }
run_cmd() { shift; "$@" >/dev/null 2>&1 || true; }
log() { :; }
warn() { :; }
export SYSTUI_TMP="$tmp/work"
mkdir -p "$SYSTUI_TMP"
BEDROCK_AOK_RAW=https://example.invalid

# shellcheck source=../src/features/65-bedrock-aok-safe-update.sh
. "$ROOT/src/features/65-bedrock-aok-safe-update.sh"

valid="$tmp/valid"
broken="$tmp/broken"
printf '#!/bin/sh\necho ok\n' > "$valid"
printf '#!/bin/sh\ncase x in x) echo bad ;; ;; esac\n' > "$broken"
chmod +x "$valid" "$broken"

rejects_broken() { ! bedrock_aok_validate_script "$broken"; }

check "validator accepts valid shell" bedrock_aok_validate_script "$valid"
check "validator rejects malformed shell" rejects_broken

installed="$tmp/brl"
printf '#!/bin/sh\ncase x in x) echo bad ;; ;; esac\n' > "$installed"
printf '#!/bin/sh\necho restored\n' > "$installed.bak"
chmod +x "$installed" "$installed.bak"
check "valid backup restores malformed installed brl" bedrock_aok_restore_backup "$installed"
check "restored command passes syntax validation" bedrock_aok_validate_script "$installed"
check "restored command is previous backup" grep -q restored "$installed"

# Simulate an installed valid command and a malformed upstream candidate. The
# updater must reject the candidate without replacing the installed file.
printf '#!/bin/sh\necho current\n' > "$installed"
chmod +x "$installed"
before=$(sha256sum "$installed" | awk '{print $1}')
bedrock_aok_require() { return 0; }
bedrock_aok_brl() { printf '%s\n' "$installed"; }
bedrock_aok_download() {
    printf '#!/bin/sh\ncase x in x) echo bad ;; ;; esac\n' > "$2"
}
set +e
bedrock_aok_self_update >/dev/null 2>&1
rc=$?
set -e
after=$(sha256sum "$installed" | awk '{print $1}')
check "malformed upstream candidate returns failure" test "$rc" -ne 0
check "malformed upstream candidate does not replace installed brl" test "$before" = "$after"

exit "$fail"
