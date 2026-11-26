#!/usr/bin/env bash
# After the release is picked, a lost dialog capture must reopen the chooser
# rather than answer an exit prompt on the user's behalf. No build is run.
set -euo pipefail
repo=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
. "$repo/src/features/rootfs.sh"

calls_file=$(mktemp)
msgs_file=$(mktemp)
: > "$calls_file"; : > "$msgs_file"
calls() { cat "$calls_file"; }
tui_msg() { printf '%s\n' "$1" >> "$msgs_file"; }
tui_yesno() { printf 'FAIL unexpected exit prompt\n' >&2; return 0; }

# 1. Empty result with status 0 (capture hiccup) -> reopen, then accept.
tui_menu() {
    local n; n=$(($(calls) + 1)); printf '%s\n' "$n" > "$calls_file"
    if [ "$n" -eq 1 ]; then printf ''; return 0; fi
    printf 'trixie\n'
}
out=$(rootfs_release_menu debian amd64)
[ "$out" = trixie ] || { printf 'FAIL retry result: %s\n' "$out" >&2; exit 1; }
[ "$(calls)" = 2 ] || { printf 'FAIL expected one retry, got %s\n' "$(calls)" >&2; exit 1; }
case $(cat "$msgs_file") in *'Release menu needs another try'*) ;; *) printf 'FAIL retry notice not shown\n' >&2; exit 1 ;; esac

# 2. Unexpected status -> retried, not treated as cancel.
: > "$msgs_file"; : > "$calls_file"
tui_menu() { local n; n=$(($(calls) + 1)); printf '%s\n' "$n" > "$calls_file"; printf ''; return 3; }
if rootfs_release_menu debian amd64 >/dev/null 2>&1; then
    printf 'FAIL gave up with success\n' >&2; exit 1
fi
[ "$(calls)" = 3 ] || { printf 'FAIL expected bounded retries, got %s\n' "$(calls)" >&2; exit 1; }
case $(cat "$msgs_file") in *'Release selection failed'*) ;; *) printf 'FAIL failure notice not shown\n' >&2; exit 1 ;; esac

# 3. A real Cancel (status 1/255) exits immediately, without retrying.
: > "$calls_file"
tui_menu() { local n; n=$(($(calls) + 1)); printf '%s\n' "$n" > "$calls_file"; printf ''; return 1; }
if rootfs_release_menu debian amd64 >/dev/null 2>&1; then
    printf 'FAIL cancel returned success\n' >&2; exit 1
fi
[ "$(calls)" = 1 ] || { printf 'FAIL cancel retried: %s\n' "$(calls)" >&2; exit 1; }

rm -f -- "$calls_file" "$msgs_file"
printf 'PASS release capture hiccups retry, real cancel exits once\n'
