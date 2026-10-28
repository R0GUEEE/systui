#!/usr/bin/env bash
# Regression test for phase 115: package search covers every installed manager.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FEATURE="$ROOT/src/features/115-unified-package-search.sh"
LOAD_ORDER="$ROOT/src/features/.load-order"

fail=0
check() {
    local name="$1"; shift
    if "$@"; then
        printf 'ok - %s\n' "$name"
    else
        printf 'not ok - %s\n' "$name" >&2
        fail=$((fail + 1))
    fi
}

check "feature exists" test -f "$FEATURE"
check "override is in explicit feature load order" grep -Fxq '115-unified-package-search.sh' "$LOAD_ORDER"

# The load order decides which definition wins; this feature must load after
# the unified installer it wraps (101) and after the Bedrock package menus.
line_of() { grep -nFx "$1" "$LOAD_ORDER" | cut -d: -f1; }
check "loads after the unified installer" test "$(line_of 115-unified-package-search.sh)" -gt "$(line_of 101-unified-package-installation-final.sh)"
check "loads after the Bedrock strata package menu" test "$(line_of 115-unified-package-search.sh)" -gt "$(line_of zzzzzzzzzz-bedrock-strata-pm-menu.sh)"
check "loads after the catalogue search it replaces" test "$(line_of 115-unified-package-search.sh)" -gt "$(line_of 96-menu-consolidation-final.sh)"

# Behavioural checks run the feature against stubbed managers.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

run_feature() { # <body>: run one check's shell code against stubbed managers
    local APK_STUB NPM_STUB CARGO_STUB GO_STUB   # function text, not values
    # shellcheck disable=SC2016
    APK_STUB='apk() { case "$1" in
        search) shift; [ "$1" = -x ] && shift; [ "$1" = -e ] && shift
                printf "vim-9.1-r0\nvimdiff-9.1-r0\n" ;;
        info)   [ "$2" = -e ] && case "$3" in vim|bash) return 0 ;; esac; return 1 ;;
    esac; }'
    NPM_STUB='npm() { [ "$1" = search ] && printf "stubnpm-helper\t1.0.0\tnpm stub\n" || echo 5.0.0; }'
    CARGO_STUB='cargo() { printf "stubcrate = \"1.0.0\"   # crate stub\n"; }'
    GO_STUB='go() { [ "$1" = list ] && printf "example.com/tool v1.0.0 v1.2.0\n"; }'
    cat > "$work/check.sh" <<'CHECK'
# Run against stubbed managers only: the machine running the test must not
# contribute its own npm/cargo/apk results. Every helper below is a shell
# function (never a #!file), so its "exit 1" would take this script down and
# be sourced into PATH for nothing; it is a PATH entry that is a regular file,
# which is never executed and keeps the stubs' "is it installed?" answer simple.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
trap - EXIT   # an inherited trap would delete our own temp dir
SYSTUI_TMP=/tmp/systui-test-pkgsearch-$$
mkdir -p "$SYSTUI_TMP"
trap 'rm -rf "$SYSTUI_TMP"' EXIT
log() { :; }; run_cmd() { "$@"; }; warn() { :; }; DIALOG=dialog
# Plain non-executable files in an empty PATH entry: nothing can run them and
# command -v skips them, so they only make "is it installed?" say no.
mkdir -p "$SYSTUI_TMP/empty"
for m in apk apt-get apt pip pip3 npm pnpm cargo gem go composer nix \
         flatpak snap pacman dnf zypper xbps-install emerge brew; do
    : > "$SYSTUI_TMP/$m"
done
PATH="$SYSTUI_TMP/empty:/usr/bin:/bin"
eval "$APK_STUB"; eval "$NPM_STUB"; eval "$CARGO_STUB"; eval "$GO_STUB"
# Force the stub native manager: the feature prefers systui_native_manager.
systui_pkg_native_search_pm() { printf "apk\n"; }
systui_native_manager() { printf "apk\n"; }
systui_package_manager_command() { command -v "$1" || printf "%s\n" "$1"; }
systui_package_install_with() { printf "INSTALL[%s]:%s\n" "$1" "${*:2}"; }
pm_search() { printf "RAW %s\n" "$1"; }
# The real installer asks dpkg whether a failed package is already present; in
# a subshell that has lost its function table the lookup falls through to the
# web-install fallback, which needs helpers this test does not stub.
dpkg() { return 1; }
pkg_web_fallback() { return 1; }
. "$FEATURE"
eval "$BODY"
CHECK
    FEATURE="$FEATURE" APK_STUB="$APK_STUB" NPM_STUB="$NPM_STUB" \
        CARGO_STUB="$CARGO_STUB" GO_STUB="$GO_STUB" BODY="$1" bash "$work/check.sh"
}

out=$(run_feature 'systui_pkg_search_with npm stub') || true
check "npm search returns package names" grep -qx 'stubnpm-helper' <<< "$out"
out=$(run_feature 'systui_pkg_search_with cargo stub') || true
check "cargo search returns crate names" grep -qx 'stubcrate' <<< "$out"
out=$(run_feature 'systui_pkg_search_native vim') || true
check "native search returns the exact package" grep -qx 'vim' <<< "$out"
check "exact native match is ranked first" test "$(head -1 <<< "$out")" = vim
out=$(run_feature 'systui_pkg_search_managers_available') || true
check "manager list includes the native manager" grep -qx 'native' <<< "$out"
check "manager list includes installed ecosystems" grep -qx 'npm' <<< "$out"
# Composer is shadowed by a non-executable file, so it cannot be "installed";
# gem is deliberately not asserted on because GitHub runners ship Ruby.
check "manager list skips managers that are not installed" test -z "$(grep -x composer <<< "$out" || true)"
out=$(run_feature 'systui_pkg_find_managers vim') || true
check "ownership probe reports the native manager" grep -q '^native' <<< "$out"
out=$(run_feature 'systui_pkg_find_managers golang.org/x/tools' ) || true
check "Go module paths are offered to the Go manager" grep -q '^go' <<< "$out"
out=$(run_feature 'systui_pkg_install_choice go example.com/tool example.com/tool') || true
check "Go modules are installed with @latest" grep -qx 'INSTALL\[go\]:example.com/tool@latest' <<< "$out"
out=$(run_feature 'systui_pkg_install_choice npm stub npm') || true
check "named managers install through the shared installer" grep -qx 'INSTALL\[npm\]:stub' <<< "$out"

# The menu hooks must wrap, not replace, what earlier phases installed.
check "install menu is wrapped" grep -Fq 'systui_unified_install_menu()' "$FEATURE"
check "catalogue search is wrapped" grep -Fq 'catalogue_search()' "$FEATURE"
check "previous implementation is kept callable" grep -Fq '_systui_pkg_install_menu_before_search' "$FEATURE"

[ "$fail" -eq 0 ]
