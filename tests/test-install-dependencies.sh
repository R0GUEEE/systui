#!/usr/bin/env bash
# Dependency pre-install pipeline: manifest integrity plus install.sh / update.sh
# wiring. No packages are installed by this test (dry-run only).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST="$ROOT/share/systui-deps.tsv"
INSTALL="$ROOT/install.sh"
UPDATE="$ROOT/update.sh"

pass=0
fail=0
check() {
    local desc="$1"; shift
    if "$@"; then printf 'ok: %s\n' "$desc"; pass=$((pass + 1)); else printf 'not ok: %s\n' "$desc" >&2; fail=$((fail + 1)); fi
}
contains() { grep -Fq -- "$2" "$1"; }

# --- manifest integrity ------------------------------------------------------
check "dependency manifest exists" test -r "$MANIFEST"
check "manifest declares the core, extra and build tiers" bash -c 'grep -q "	core	" "$1" && grep -q "	extra	" "$1" && grep -q "	build	" "$1"' _ "$MANIFEST"
check "every manifest row has 9 fields or is a comment" bash -c '
    awk -F"\t" "/^[[:space:]]*#/ {next} NF==0 {next} NF!=9 {print NR\": \"NF; bad=1} END{exit bad}" "$1"' _ "$MANIFEST"
check "manifest has no duplicate canonical names" bash -c '
    dup=$(awk -F"\t" "!/^[[:space:]]*#/ && NF {print \$1}" "$1" | sort | uniq -d)
    [ -z "$dup" ] || { echo "duplicates: $dup"; exit 1; }' _ "$MANIFEST"
check "core tier carries the TUI essentials" bash -c '
    for p in bash dialog coreutils grep sed gawk findutils tar gzip unzip ca-certificates curl; do
        grep -q "^$p	" "$1" || { echo "missing $p"; exit 1; }
    done' _ "$MANIFEST"
check "manifest records package names for every supported family" bash -c '
    awk -F"\t" "!/^[[:space:]]*#/ && NF==9 {for (i=2;i<=7;i++) if (\$i==\"\") {print \"row \"NR\" empty column \"i; bad=1}} END{exit bad}" "$1"' _ "$MANIFEST"

# --- install.sh wiring -------------------------------------------------------
check "install.sh ships the manifest-driven dependency engine" contains "$INSTALL" 'deps_manifest_path'
check "install.sh resolves a package column per manager family" contains "$INSTALL" 'deps_family_column'
check "install.sh defaults to every tier" contains "$INSTALL" "printf 'core,extra,build\\n'"
check "install.sh supports a minimal core-only install" contains "$INSTALL" 'SYSTUI_MINIMAL_DEPS'
check "install.sh keeps the core tier fatal and other tiers tolerant" bash -c '
    grep -q "core) install_native_packages \"\$pm\" \"\$@\"" "$1" &&
    grep -q "install_native_packages_tolerant" "$1"' _ "$INSTALL"
check "install.sh supports dry-run and deps-only modes" bash -c '
    grep -q -- "--deps-only" "$1" && grep -q -- "--dry-run" "$1"' _ "$INSTALL"
check "install.sh has a usage function" contains "$INSTALL" 'usage() {'

# --- update.sh wiring --------------------------------------------------------
check "update.sh installs prerequisites before cloning" bash -c '
    a=$(grep -nE "^[[:space:]]*ensure_update_prerequisites[[:space:]]*$" "$1" | head -n1 | cut -d: -f1)
    b=$(grep -n "^git clone" "$1" | head -n1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$UPDATE"
check "update.sh escalates privileges before installing prerequisites" bash -c '
    a=$(grep -n "exec sudo" "$1" | head -n1 | cut -d: -f1)
    b=$(grep -n "Prerequisites are installed as root" "$1" | head -n1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$UPDATE"
check "update.sh forwards dependency flags to install.sh" bash -c '
    grep -q -- "--minimal" "$1" && grep -q "install_args+=" "$1"' _ "$UPDATE"

# --- runtime behaviour (no installation happens) -----------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sed 's/^main "\$@"$//' "$INSTALL" > "$tmp/install_lib.sh"

check "sourced engine lists core packages for apt" bash -c '
    source "$1"
    PROJECT_DIR="$2"
    deps_rows 2 core | grep -qx "core	bash"' _ "$tmp/install_lib.sh" "$ROOT"
check "sourced engine lists core packages for apk" bash -c '
    source "$1"
    PROJECT_DIR="$2"
    deps_rows 3 core | grep -qx "core	dialog"' _ "$tmp/install_lib.sh" "$ROOT"
check "toolkit packages are listed for the build tier" bash -c '
    source "$1"
    PROJECT_DIR="$2"
    deps_rows 2 build | grep -qx "build	make"' _ "$tmp/install_lib.sh" "$ROOT"
check "minimal mode selects the core tier only" bash -c '
    source "$1"
    SYSTUI_MINIMAL_DEPS=1
    [ "$(deps_tiers)" = core ]' _ "$tmp/install_lib.sh"
check "default mode selects all tiers" bash -c '
    source "$1"
    [ "$(deps_tiers)" = "core,extra,build" ]' _ "$tmp/install_lib.sh"
check "unknown package managers are rejected" bash -c '
    source "$1"
    ! deps_family_column nosuchmanager 2>/dev/null' _ "$tmp/install_lib.sh"

if [ "$(id -u)" -eq 0 ]; then
    check "install.sh --deps-only --dry-run plans the full install" bash -c '
        SYSTUI_PM_OVERRIDE=apt bash "$1" --deps-only --dry-run 2>/dev/null | grep -q "\[dry-run\] core (apt):"' _ "$INSTALL"
    check "install.sh --deps-only --dry-run exits successfully" bash -c '
        SYSTUI_PM_OVERRIDE=apt bash "$1" --deps-only --dry-run >/dev/null 2>&1' _ "$INSTALL"
    check "minimal dry-run plans core packages only" bash -c '
        out=$(SYSTUI_PM_OVERRIDE=apk bash "$1" --deps-only --dry-run --minimal 2>/dev/null)
        printf "%s\n" "$out" | grep -q "\[dry-run\] core (apk):"
        ! printf "%s\n" "$out" | grep -q "toolkit"' _ "$INSTALL"
    check "update.sh --dry-run reports the install it would run" bash -c '
        bash "$1" --dry-run 2>/dev/null | grep -q "would run: INSTALL_PREFIX="' _ "$UPDATE"
    check "update.sh --dry-run is non-destructive" bash -c '
        before=no; [ -d /var/lib/systui/source ] && before=yes
        bash "$1" --dry-run >/dev/null 2>&1 || exit 1
        after=no; [ -d /var/lib/systui/source ] && after=yes
        [ "$before" = "$after" ]' _ "$UPDATE"
fi

# --- unavailable packages are skipped ---------------------------------------
fakebin="$tmp/fakebin"
mkdir -p "$fakebin"
cat > "$fakebin/dpkg-query" <<'FAKE'
#!/bin/sh
exit 1
FAKE
cat > "$fakebin/apt-cache" <<'FAKE'
#!/bin/sh
exit 1
FAKE
cat > "$fakebin/apt-get" <<'FAKE'
#!/bin/sh
exit 100
FAKE
chmod +x "$fakebin"/*

check "unlocatable packages are skipped instead of failing" bash -c '
    source "$1"
    refresh_package_metadata() { return 0; }
    PATH="$2:$PATH"
    install_native_packages apt definitely-not-a-real-package-xyz >"$3/out" 2>&1
    rc=$?
    [ "$rc" -eq 0 ] || { echo "exit $rc"; exit 1; }
    grep -q "Not found in any configured repository" "$3/out" &&
    grep -q "definitely-not-a-real-package-xyz" "$3/out"' _ "$tmp/install_lib.sh" "$fakebin" "$tmp"

check "skipped packages are reported in the summary" bash -c '
    source "$1"
    refresh_package_metadata() { return 0; }
    PATH="$2:$PATH"
    SYSTUI_DEPS_SKIPPED=""
    install_native_packages apt another-missing-package-xyz >/dev/null 2>&1
    deps_report_skipped >"$3/summary" 2>&1
    grep -q "Skipped (not available for this distribution)" "$3/summary" &&
    grep -q "another-missing-package-xyz" "$3/summary"' _ "$tmp/install_lib.sh" "$fakebin" "$tmp"

check "strict mode still fails on unavailable packages" bash -c '
    source "$1"
    refresh_package_metadata() { return 0; }
    PATH="$2:$PATH"
    SYSTUI_DEPS_STRICT=1
    # error() exits, so run the call in a subshell and inspect its status.
    if ( install_native_packages apt strict-mode-missing-package ) >/dev/null 2>&1; then exit 1; fi
    exit 0' _ "$tmp/install_lib.sh" "$fakebin"

check "missing commands are warnings by default" bash -c '
    source "$1"
    PROJECT_DIR="$3"
    deps_missing_commands() { printf "core:definitely-missing-command\n"; }
    deps_report_skipped() { return 0; }
    verify_dependencies >"$2/verify" 2>&1
    rc=$?
    [ "$rc" -eq 0 ] || { echo "exit $rc"; exit 1; }
    grep -q "Commands still missing" "$2/verify"' _ "$tmp/install_lib.sh" "$tmp" "$ROOT"

check "strict mode fails verification on missing commands" bash -c '
    source "$1"
    PROJECT_DIR="$2"
    deps_missing_commands() { printf "core:definitely-missing-command\n"; }
    deps_report_skipped() { return 0; }
    SYSTUI_DEPS_STRICT=1
    if ( verify_dependencies ) >/dev/null 2>&1; then exit 1; fi
    exit 0' _ "$tmp/install_lib.sh" "$ROOT"

check "install.sh documents skip-by-default behaviour" bash -c '
    grep -q "Skipped (not available for this distribution)" "$1" &&
    grep -q "Not found in any configured repository" "$1"' _ "$INSTALL"
check "update.sh installs prerequisites one by one and skips unavailable ones" bash -c '
    grep -q "update_install_one" "$1" &&
    grep -q "Skipped prerequisites not available" "$1" &&
    grep -q "git is required to update systui and could not be installed" "$1"' _ "$UPDATE"

printf '\nDependency pipeline: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
