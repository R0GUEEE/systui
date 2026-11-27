#!/usr/bin/env bash
# The installer and the updater must run natively under sh, dash, ash (BusyBox),
# bash, zsh, ksh and mksh — no Bash, no re-exec trampoline.
#
# Nothing here installs packages or touches the system: --help, --dry-run and
# (when the test runs as root) a real install into a throw-away prefix.
set -euo pipefail
repo=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
cd "$repo"

# Resolve every shell to an absolute path *before* the fake-bash directory is
# prepended to PATH, so the matrix keeps using the real binaries.
shells=(sh bash)
declare -A SHELL_PATH
SHELL_PATH[sh]=$(command -v sh)
SHELL_PATH[bash]=$(command -v bash)
for s in dash zsh ash ksh mksh yash busybox; do
    if command -v "$s" >/dev/null 2>&1; then
        shells+=("$s")
        SHELL_PATH[$s]=$(command -v "$s")
    fi
done

run_with() { # <shell> <script> <args...>
    local sh=$1 script=$2
    shift 2
    local bin=${SHELL_PATH[$sh]:-$sh}
    if [ "$sh" = busybox ]; then
        "$bin" ash "$script" "$@"
    else
        "$bin" "$script" "$@"
    fi
}

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# ---------------------------------------------------------------------------
# 1. Help works everywhere and never shells out to bash.
#
#    A fake `bash` that exits 99 is placed first on PATH: if either script
#    re-exec'd itself, the run would fail with that status instead of printing
#    usage.
# ---------------------------------------------------------------------------
mkdir -p "$tmp/fakebin"
cat > "$tmp/fakebin/bash" <<'EOF'
#!/bin/sh
echo "bash was executed by $0" >&2
exit 99
EOF
chmod +x "$tmp/fakebin/bash"

for sh in "${shells[@]}"; do
    for script in install.sh update.sh; do
        out=$(PATH="$tmp/fakebin:$PATH" run_with "$sh" "$script" --help) || {
            printf 'FAIL %s %s --help (rc=%s)\n' "$sh" "$script" "$?" >&2
            exit 1
        }
        case "$out" in
            *--dry-run*) ;;
            *) printf 'FAIL %s %s --help output\n' "$sh" "$script" >&2; exit 1 ;;
        esac
        printf 'PASS %s %s --help\n' "$sh" "$script"
    done
done

# ---------------------------------------------------------------------------
# 2. The dependency plan is identical under every shell. This is the part that
#    depends on word splitting and a tab IFS, which is exactly where zsh and
#    dash differ from bash.
# ---------------------------------------------------------------------------
reference=''
for sh in "${shells[@]}"; do
    out=$(run_with "$sh" install.sh --dry-run 2>&1) || {
        printf 'FAIL %s install.sh --dry-run\n' "$sh" >&2
        printf '%s\n' "$out" >&2
        exit 1
    }
    case "$out" in
        *'[dry-run] core'*) ;;
        *) printf 'FAIL %s dry run produced no dependency plan\n' "$sh" >&2; exit 1 ;;
    esac
    if [ -z "$reference" ]; then
        reference=$out
    elif [ "$out" != "$reference" ]; then
        printf 'FAIL %s dry-run output differs from the first shell\n' "$sh" >&2
        diff <(printf '%s\n' "$reference") <(printf '%s\n' "$out") >&2 || true
        exit 1
    fi
    printf 'PASS %s install.sh --dry-run\n' "$sh"
done

# ---------------------------------------------------------------------------
# 3. update.sh plans the same reinstall under every shell.
# ---------------------------------------------------------------------------
for sh in "${shells[@]}"; do
    out=$(run_with "$sh" update.sh --dry-run 2>&1) || {
        printf 'FAIL %s update.sh --dry-run\n' "$sh" >&2
        printf '%s\n' "$out" >&2
        exit 1
    }
    case "$out" in
        *'Dry run complete'*) ;;
        *) printf 'FAIL %s update.sh --dry-run output\n' "$sh" >&2; exit 1 ;;
    esac
    printf 'PASS %s update.sh --dry-run\n' "$sh"
done

# ---------------------------------------------------------------------------
# 4. Bad options are rejected with the documented status, not a shell error.
# ---------------------------------------------------------------------------
for sh in sh dash zsh bash; do
    command -v "$sh" >/dev/null 2>&1 || continue
    set +e
    out=$("$sh" install.sh --not-an-option 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || { printf 'FAIL %s unknown option rc=%s\n' "$sh" "$rc" >&2; exit 1; }
    case "$out" in
        *'Unknown option'*) ;;
        *) printf 'FAIL %s unknown option message: %s\n' "$sh" "$out" >&2; exit 1 ;;
    esac
    printf 'PASS %s rejects unknown options (rc 2)\n' "$sh"
done

# ---------------------------------------------------------------------------
# 5. A real install into a throw-away prefix, under a non-Bash shell. Skipped
#    for unprivileged runs, because the installer requires root by design.
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    for sh in dash zsh; do
        command -v "$sh" >/dev/null 2>&1 || continue
        prefix="$tmp/prefix-$sh"
        INSTALL_PREFIX="$prefix" SYSTUI_STATE_DIR="$tmp/state-$sh" \
            run_with "$sh" install.sh --no-deps >/dev/null 2>&1 || {
                printf 'FAIL %s real install\n' "$sh" >&2; exit 1; }
        [ -x "$prefix/bin/systui" ] || { printf 'FAIL %s launcher missing\n' "$sh" >&2; exit 1; }
        [ -f "$prefix/share/man/man1/systui.1" ] || { printf 'FAIL %s man page missing\n' "$sh" >&2; exit 1; }
        # The wrapper must be installed with its library path substituted and
        # its main menu intact — proof the heredoc survived the POSIX shell.
        grep -qF "LIBDIR=\"$prefix/lib/systui\"" "$prefix/bin/systui" ||
            { printf 'FAIL %s launcher library path\n' "$sh" >&2; exit 1; }
        grep -qF 'main_menu' "$prefix/bin/systui" ||
            { printf 'FAIL %s launcher main menu\n' "$sh" >&2; exit 1; }
        printf 'PASS %s real install into a temporary prefix\n' "$sh"
    done
else
    printf 'SKIP real install (test is not running as root)\n'
fi

printf 'PASS all shell entrypoints\n'
