#!/usr/bin/env bash
# Every user-facing entrypoint must survive being started by a non-Bash shell.
# No installation, network access or system change: --help and a stub launcher.
set -euo pipefail
repo=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
cd "$repo"

shells=(sh bash)
for s in dash zsh ash ksh mksh yash busybox; do
    command -v "$s" >/dev/null 2>&1 && shells+=("$s")
done

run_with() { # <shell> <script> <args...>
    local sh=$1 script=$2
    shift 2
    if [ "$sh" = busybox ]; then
        busybox ash "$script" "$@"
    else
        "$sh" "$script" "$@"
    fi
}

for sh in "${shells[@]}"; do
    out=$(run_with "$sh" install.sh --help)
    [[ $out == *'--dry-run'* && $out == *'--deps-only'* ]] || {
        printf 'FAIL %s install.sh --help\n' "$sh" >&2; exit 1; }
    printf 'PASS %s install.sh --help\n' "$sh"

    out=$(run_with "$sh" update.sh --help)
    [[ $out == *'--dry-run'* ]] || {
        printf 'FAIL %s update.sh --help\n' "$sh" >&2; exit 1; }
    printf 'PASS %s update.sh --help\n' "$sh"
done

# The generated systui launcher uses the same trampoline. Extract it from the
# heredoc and prove that a non-Bash start reaches Bash with the original argv.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
awk '/^cat > "\$wrapper_tmp" << .WRAPPER./{grab=1;next} /^WRAPPER$/{if(grab){exit}} grab' install.sh |
    sed '/^LIBDIR=/,$d' > "$tmp/launcher"
printf '%s\n' 'printf "reached-bash:%s\n" "${BASH_VERSION%%.*}"' >> "$tmp/launcher"
chmod +x "$tmp/launcher"
grep -q 'BASH_VERSION' "$tmp/launcher" || { echo 'FAIL launcher trampoline missing' >&2; exit 1; }
for sh in "${shells[@]}"; do
    out=$(run_with "$sh" "$tmp/launcher")
    [[ $out == reached-bash:* ]] || {
        printf 'FAIL launcher under %s: %s\n' "$sh" "$out" >&2; exit 1; }
    printf 'PASS launcher under %s (%s)\n' "$sh" "$out"
done

# Without Bash on PATH the entrypoints must diagnose the problem, not emit a
# syntax error. The scripts are copied out so nothing real is executed.
mkdir "$tmp/bin"
ln -s "$(command -v sh)" "$tmp/bin/sh"
for script in install.sh update.sh; do
    cp "$script" "$tmp/$script"
    set +e
    out=$(PATH="$tmp/bin" "$tmp/bin/sh" "$tmp/$script" --help 2>&1)
    rc=$?
    set -e
    [[ $rc -eq 127 && $out == *'requires Bash'* ]] || {
        printf 'FAIL %s missing-bash diagnostic: rc=%s %s\n' "$script" "$rc" "$out" >&2; exit 1; }
    printf 'PASS %s missing-bash diagnostic (127)\n' "$script"
done

printf 'PASS all shell entrypoints\n'
