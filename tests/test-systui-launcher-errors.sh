#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
F="$ROOT/install.sh"

bash -n "$F"
grep -Fq 'startup_die()' "$F"
grep -Fq 'systui_startup_check()' "$F"
grep -Fq -- '--diagnose|--doctor' "$F"
grep -Fq 'dialog failed to open the main menu' "$F"
grep -Fq 'stdin is not a terminal' "$F"
grep -Fq "terminal type '\$TERM' has no usable terminfo entry" "$F"
# A dialog execution failure must no longer be swallowed by `|| return 0`.
! grep -Fq 'choice=$(tui_menu' "$F" || ! grep -Fq ') || return 0' "$F"

printf 'ok - systui launcher reports startup/dialog failures instead of silently exiting\n'
