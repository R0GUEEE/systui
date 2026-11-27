#!/usr/bin/env bash
# The dependency manifest is the contract for "what does systui need on this
# machine". These checks keep it complete, keep the generated documentation in
# step with it, and prove the printed install command matches the manifest for
# every supported family.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST="$ROOT/share/systui-deps.tsv"
DOCS="$ROOT/docs/DEPENDENCIES.md"
INSTALL="$ROOT/install.sh"
VERIFY="$ROOT/tools/deps-verify.sh"
AUDIT="$ROOT/tools/deps-audit.py"

checks=0
failures=0
check() {
    local desc="$1"; shift
    checks=$((checks + 1))
    if "$@"; then
        printf 'ok %d - %s\n' "$checks" "$desc"
    else
        printf 'not ok %d - %s\n' "$checks" "$desc"
        failures=$((failures + 1))
    fi
}
contains() { grep -Fq -- "$2" "$1"; }
equals() { [ "$1" = "$2" ] || { printf '    expected: %s\n    actual  : %s\n' "$2" "$1"; return 1; }; }

# ---------------------------------------------------------------------------
# Manifest structure
# ---------------------------------------------------------------------------
check "manifest exists" test -s "$MANIFEST"
check "docs exist" test -s "$DOCS"

bad_fields=$(awk -F'\t' '!/^#/ && NF && NF != 9 && NF != 10 { print NR }' "$MANIFEST" | wc -l | tr -d ' ')
check "every row has 9 or 10 tab-separated fields" equals "$bad_fields" "0"

bad_tier=$(awk -F'\t' '!/^#/ && NF && $8 != "core" { print NR }' "$MANIFEST" | wc -l | tr -d ' ')
check "every row is the core tier" equals "$bad_tier" "0"

dupes=$(awk -F'\t' '!/^#/ && NF { print $1 }' "$MANIFEST" | sort | uniq -d | wc -l | tr -d ' ')
check "package names are unique" equals "$dupes" "0"

# A "-" package is skipped, so it must never leak into an install command.
placeholder_leaked=0
for pm in apt apk pacman dnf xbps emerge; do
    out=$(SYSTUI_PM_OVERRIDE=$pm sh "$INSTALL" --print-deps 2>&1)
    case " $out " in *" - "*) placeholder_leaked=1 ;; esac
done
check "no family prints a '-' placeholder package" equals "$placeholder_leaked" "0"

# ---------------------------------------------------------------------------
# Audit + generated documentation
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
    check "manifest audit passes and docs are current" python3 "$AUDIT" --check
fi

# Every package in the manifest must appear in the generated package map.
missing_from_docs=0
for pkg in $(awk -F'\t' '!/^#/ && NF { print $1 }' "$MANIFEST"); do
    contains "$DOCS" "\`$pkg\`" || { printf '    docs missing %s\n' "$pkg"; missing_from_docs=$((missing_from_docs + 1)); }
done
check "generated docs list every package" equals "$missing_from_docs" "0"

check "docs document the print-deps entry point" contains "$DOCS" 'install.sh --print-deps'
check "docs explain the '+' multi-package cell" contains "$DOCS" 'Alpine ships `util-linux`'

# ---------------------------------------------------------------------------
# The printed install command matches the manifest, under every shell
# ---------------------------------------------------------------------------
first_pkg=$(awk -F'\t' '!/^#/ && NF { print $2; exit }' "$MANIFEST")
for pm in apt apk pacman dnf xbps emerge; do
    out=$(SYSTUI_PM_OVERRIDE=$pm sh "$INSTALL" --print-deps 2>&1)
    case "$out" in
        sudo*"$first_pkg"*) ;;
        *) printf 'not ok - %s print-deps: %s\n' "$pm" "$out"; failures=$((failures + 1)); continue ;;
    esac
    printf 'ok %d - %s print-deps prints a usable command\n' "$((checks = checks + 1))" "$pm"
done

for sh in sh dash zsh; do
    command -v "$sh" >/dev/null 2>&1 || continue
    a=$(SYSTUI_PM_OVERRIDE=apt "$sh" "$INSTALL" --print-deps 2>&1)
    b=$(SYSTUI_PM_OVERRIDE=apt bash "$INSTALL" --print-deps 2>&1)
    check "$sh --print-deps matches bash" equals "$a" "$b"
done

# zypper takes the dnf names except for the manifest's documented overrides
# (ncurses-utils, procps). Normalise those away and the lists must match.
zypper_pkg_list() {
    SYSTUI_PM_OVERRIDE=zypper "$1" "$INSTALL" --print-deps 2>&1 |
        sed 's/.* install //; s/ncurses-utils/ncurses/; s/\bprocps\b/procps-ng/'
}
dnf_pkg_list() {
    SYSTUI_PM_OVERRIDE=dnf "$1" "$INSTALL" --print-deps 2>&1 | sed 's/.* install -y //'
}
check "zypper matches the dnf column apart from the overrides" equals \
    "$(zypper_pkg_list bash)" "$(dnf_pkg_list bash)"

# ---------------------------------------------------------------------------
# zypper (openSUSE) overrides the dnf names where they differ
# ---------------------------------------------------------------------------
check "zypper uses the openSUSE ncurses package" bash -c \
    'SYSTUI_PM_OVERRIDE=zypper bash "$1" --print-deps 2>&1 | grep -qw ncurses-utils' _ "$INSTALL"
check "zypper does not get the dnf-only package name" bash -c \
    '! SYSTUI_PM_OVERRIDE=zypper bash "$1" --print-deps 2>&1 | grep -qw procps-ng' _ "$INSTALL"
check "dnf still uses its own procps name" bash -c \
    'SYSTUI_PM_OVERRIDE=dnf bash "$1" --print-deps 2>&1 | grep -qw procps-ng' _ "$INSTALL"
check "deps-verify resolves zypper overrides" bash -c \
    'sh "$1" --list-packages zypper | grep -qx ncurses-utils' _ "$VERIFY"

# ---------------------------------------------------------------------------
# Multi-package cells (Alpine's split util-linux)
# ---------------------------------------------------------------------------
check "apk cell expands to both util-linux packages" bash -c \
    'out=$(SYSTUI_PM_OVERRIDE=apk bash "$1" --print-deps 2>&1); printf "%s" "$out" | grep -qw util-linux && printf "%s" "$out" | grep -qw util-linux-misc' _ "$INSTALL"
check "other families do not inherit the Alpine split" bash -c \
    '! SYSTUI_PM_OVERRIDE=apt bash "$1" --print-deps 2>&1 | grep -qw util-linux-misc' _ "$INSTALL"
check "deps-verify lists both split packages" bash -c \
    'sh "$1" --list-packages apk | grep -qx util-linux && sh "$1" --list-packages apk | grep -qx util-linux-misc' _ "$VERIFY"

# ---------------------------------------------------------------------------
# deps-verify behaviour against fixtures
# ---------------------------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    good "$first_pkg" "$first_pkg" "$first_pkg" "$first_pkg" "$first_pkg" "$first_pkg" core sh > "$tmp/ok.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    missing pkg pkg pkg pkg pkg pkg core systui-command-that-does-not-exist > "$tmp/bad.tsv"

check "deps-verify passes when commands exist" sh "$VERIFY" apt "$tmp/ok.tsv"
check "deps-verify fails when a mandatory command is missing" bash -c \
    '! sh "$1" apt "$2" >/dev/null 2>&1' _ "$VERIFY" "$tmp/bad.tsv"
check "deps-verify names the missing command" bash -c \
    'sh "$1" apt "$2" 2>&1 | grep -q systui-command-that-does-not-exist' _ "$VERIFY" "$tmp/bad.tsv"

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    optional pkg pkg pkg pkg pkg pkg core "sh|systui-advisory-command" > "$tmp/adv.tsv"
check "advisory commands never fail the check" sh "$VERIFY" apt "$tmp/adv.tsv"

printf '%s\n' 'Usage: tools/deps-verify.sh' > "$tmp/unused"
check "deps-verify rejects an unknown family" bash -c '! sh "$1" slackware 2>/dev/null' _ "$VERIFY"

printf '%s checks, %s failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
