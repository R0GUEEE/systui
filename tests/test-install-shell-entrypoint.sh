#!/usr/bin/env bash
# No install operations: --help and an isolated PATH missing-bash fixture only.
set -euo pipefail
repo=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
cd "$repo"
for shell in sh dash zsh bash; do
    if command -v "$shell" >/dev/null 2>&1; then
        output=$("$shell" install.sh --help)
        [[ $output == *'--dry-run'* && $output == *'--deps-only'* ]] || { echo "FAIL $shell --help" >&2; exit 1; }
        printf 'PASS %s install.sh --help\n' "$shell"
    fi
done
if command -v busybox >/dev/null 2>&1; then
    output=$(busybox ash install.sh --help)
    [[ $output == *'--dry-run'* ]] || exit 1
    printf 'PASS BusyBox ash install.sh --help\n'
fi
# Restrict PATH for a POSIX shell; bash isn't available through this PATH.
# The fixture is a copy outside the repo; no genuine installer runs.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
cp install.sh "$tmp/install.sh"
mkdir "$tmp/bin"
ln -s "$(command -v sh)" "$tmp/bin/sh"
set +e
output=$(PATH="$tmp/bin" "$tmp/bin/sh" "$tmp/install.sh" --help 2>&1)
rc=$?
set -e
[[ $rc -eq 127 && $output == *'requires Bash'* && $output == *'apk add bash'* ]] || {
    printf 'FAIL missing-bash diagnostic: rc=%s output=%s\n' "$rc" "$output" >&2; exit 1;
}
printf 'PASS missing-bash actionable diagnostic (127)\n'
