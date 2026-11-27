#!/usr/bin/env bash
# install.sh must work under any POSIX shell — including a PATH with no bash at
# all, which is the situation the old re-exec trampoline could not handle.
#
# No install operations here: --help and a restricted-PATH fixture only.
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

# ---------------------------------------------------------------------------
# Minimal PATH fixture: only the POSIX tools the entrypoint itself needs.
# bash is deliberately absent, and a bash that fails loudly is placed inside
# the directory to prove the installer never looks for it.
# ---------------------------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
cp install.sh "$tmp/install.sh"
mkdir "$tmp/bin"
for tool in sh dirname head tr cat; do
    ln -s "$(command -v "$tool")" "$tmp/bin/$tool" 2>/dev/null || true
done
cat > "$tmp/bin/bash" <<'EOF'
#!/bin/sh
echo "install.sh tried to re-exec bash" >&2
exit 99
EOF
chmod +x "$tmp/bin/bash"

set +e
output=$(PATH="$tmp/bin" "$tmp/bin/sh" "$tmp/install.sh" --help 2>&1)
rc=$?
set -e
[[ $rc -eq 0 ]] || { printf 'FAIL restricted-PATH run: rc=%s output=%s\n' "$rc" "$output" >&2; exit 1; }
[[ $output == *'--dry-run'* ]] || { printf 'FAIL restricted-PATH output: %s\n' "$output" >&2; exit 1; }
case "$output" in
    *'requires Bash'*) printf 'FAIL installer still demands bash\n' >&2; exit 1 ;;
    *'re-exec bash'*) printf 'FAIL installer still re-execs bash\n' >&2; exit 1 ;;
esac
printf 'PASS install.sh runs with no bash on PATH\n'

# The script must not carry a bash-only construct that a POSIX shell only
# parses when it reaches it. `dash -n` and `zsh -n` are the cheapest proof.
for shell in dash zsh; do
    command -v "$shell" >/dev/null 2>&1 || continue
    "$shell" -n install.sh || { printf 'FAIL %s cannot parse install.sh\n' "$shell" >&2; exit 1; }
    printf 'PASS %s parses install.sh\n' "$shell"
done
