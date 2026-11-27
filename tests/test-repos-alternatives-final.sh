#!/usr/bin/env bash
# Repository tooling: Distro Repos, the popular catalogue and the PPA manager.
#
# The Distro Repos checklist used to lose its line continuations for Debian and
# Ubuntu, so dialog was handed a single item and the shell tried to execute
# "updates trixie-updates off" as a command. These checks run the real
# functions (extracted from sysconfig.sh) against stubs, so a missing backslash
# fails here instead of in the TUI.
set -uo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SYSCONFIG="$PROJECT_DIR/src/features/sysconfig.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf -- "$tmpdir"' EXIT

checks=0
failures=0
check() {
    local name="$1"; shift
    checks=$((checks + 1))
    if "$@"; then printf 'ok %d - %s\n' "$checks" "$name"
    else printf 'not ok %d - %s\n' "$checks" "$name"; failures=$((failures + 1)); fi
}
contains()     { grep -Fq -- "$2" "$1"; }
not_contains() { ! grep -Fq -- "$2" "$1"; }
count_of()     { grep -c -- "$2" "$1"; }

# --- shared preamble for the extracted-function harnesses --------------------
preamble() {
    cat <<'EOF'
LOGFILE=<TMP>/run.log; WARNFILE=<TMP>/run.warn; SYSTUI_TMP=<TMP>; PM=apt
log()  { printf '[log] %s\n' "$*" >> "$LOGFILE"; }
warn() { printf '[warn] %s\n' "$*" >> "$WARNFILE"; log "WARN: $*"; }
show_warnings() { :; }
run_cmd() { printf 'RUN: %s\n' "$*"; return 0; }
tui_msg() { printf 'MSG: %s\n' "$1"; }
tui_yesno() { return 0; }
tui_text() { :; }
tui_wait() { :; }
tui_input() { printf '%s\n' "${INPUT_ANSWER:-}"; }
tui_radio() { printf '%s\n' "${RADIO_ANSWER:-}"; }
tui_menu()  { printf '%s\n' "${MENU_ANSWER:-back}"; }
tui_check() { printf '%s|%s\n' "$#" "$*" >> "${CHECK_LOG:-/dev/null}"; printf '"%s"\n' "${CHECK_ANSWER:-}"; }
EOF
}

# Extract one function (or a set) verbatim from sysconfig.sh. Names prefixed
# with var: extract a quoted multi-line assignment instead (APT_POPULAR, ...).
extract() { # <function-name|var:NAME> ...
    local fn name
    for fn in "$@"; do
        case "$fn" in
            var:*)
                name=${fn#var:}
                sed -n "/^${name}=/,/\"$/p" "$SYSCONFIG"
                ;;
            *)
                sed -n "/^${fn}() {/,/^}/p" "$SYSCONFIG"
                ;;
        esac
        printf '\n'
    done
}

build_harness() { # <outfile> <function...>
    local out="$1"; shift
    {
        printf '#!/usr/bin/env bash\n'
        preamble | sed "s#<TMP>#$tmpdir#g"
        extract "$@"
    } > "$out"
    bash -n "$out"
}

# --- static wiring ----------------------------------------------------------
check "distro repos menu exists"        contains "$SYSCONFIG" 'menu_distro_repos() {'
check "popular repos menu exists"       contains "$SYSCONFIG" 'repo_popular() {'
check "PPA menu exists"                 contains "$SYSCONFIG" 'menu_ppa_repos() {'
check "repositories menu routes distro" contains "$SYSCONFIG" 'distro)  menu_distro_repos'
check "repositories menu routes ppa"    contains "$SYSCONFIG" 'ppa)     menu_ppa_repos'
check "popular menu is category driven" contains "$SYSCONFIG" 'SPACE marks categories'
check "PPA menu offers the popular list" contains "$SYSCONFIG" 'ppa_menu_catalogue() {'
check "PPA menu offers Launchpad search" contains "$SYSCONFIG" 'ppa_menu_search() {'

# --- the bug: checklist continuations --------------------------------------
pockets="$tmpdir/pockets.sh"
build_harness "$pockets" distro_repo_pockets
check "distro pockets harness builds" test -x "$pockets" -o -f "$pockets"

pockets_args() { # <distro> <release> -> "call-count|arg-count|args"
    : > "$tmpdir/check.log"
    CHECK_LOG="$tmpdir/check.log" CHECK_ANSWER=base bash -c '
        . "$1"
        distro_repo_pockets "$2" "$3" >/dev/null 2>"'"$tmpdir"'/pockets.err"
    ' _ "$pockets" "$1" "$2"
    wc -l < "$tmpdir/check.log" | tr -d " "
    head -1 "$tmpdir/check.log"
}
out=$(pockets_args debian trixie); calls=$(printf '%s\n' "$out" | head -1); args=$(printf '%s\n' "$out" | tail -1)
check "debian pockets: one checklist call"   test "$calls" = 1
check "debian pockets: twelve argument pairs" bash -c 'case "$1" in "14|"*) exit 0;; *) exit 1;; esac' _ "$args"
check "debian pockets: no command-not-found" bash -c '! grep -q "command not found" "$1"' _ "$tmpdir/pockets.err"
check "debian pockets lists backports"       bash -c 'case "$1" in *"trixie-backports"*) exit 0;; *) exit 1;; esac' _ "$args"

out=$(pockets_args ubuntu noble); args=$(printf '%s\n' "$out" | tail -1)
check "ubuntu pockets: fifteen argument pairs" bash -c 'case "$1" in "17|"*) exit 0;; *) exit 1;; esac' _ "$args"
check "ubuntu pockets lists proposed"        bash -c 'case "$1" in *"noble-proposed"*) exit 0;; *) exit 1;; esac' _ "$args"
check "ubuntu pockets: no command-not-found" bash -c '! grep -q "command not found" "$1"' _ "$tmpdir/pockets.err"

out=$(pockets_args devuan daedalus); args=$(printf '%s\n' "$out" | tail -1)
check "devuan pockets still parse"            bash -c 'case "$1" in "11|"*) exit 0;; *) exit 1;; esac' _ "$args"

# --- distro repo writer -----------------------------------------------------
writer="$tmpdir/writer.sh"
{
    printf '#!/usr/bin/env bash\n'
    preamble | sed "s#<TMP>#$tmpdir#g"
    extract distro_repo_label distro_repo_key_option distro_repo_write_apt | sed "s#/etc/apt/sources.list.d#$tmpdir/apt#g"
} > "$writer"
bash -n "$writer"
mkdir -p "$tmpdir/apt"

bash -c '. "$1"; distro_repo_write_apt debian trixie "main contrib" "base updates security backports" "deb" >/dev/null' _ "$writer"
deb_file="$tmpdir/apt/systui-distro-debian-trixie.list"
check "debian repo file is written"        test -f "$deb_file"
check "debian repo has four suites"        test "$(count_of "$deb_file" '^deb ')" = 4
check "debian updates suite is correct"    contains "$deb_file" 'trixie-updates main contrib'
check "debian security uses security host" contains "$deb_file" 'security.debian.org/debian-security trixie-security'
check "debian backports suite is correct"  contains "$deb_file" 'trixie-backports main contrib'

bash -c '. "$1"; distro_repo_write_apt ubuntu noble "main universe" "base updates security" "deb" >/dev/null' _ "$writer"
ub_file="$tmpdir/apt/systui-distro-ubuntu-noble.list"
check "ubuntu repo has three pockets"      test "$(count_of "$ub_file" '^deb ')" = 3
check "ubuntu base line is complete"       contains "$ub_file" 'noble main universe'

bash -c '. "$1"; distro_repo_write_apt kali kali-rolling "main" "base" "deb deb-src" >/dev/null' _ "$writer"
kali_file="$tmpdir/apt/systui-distro-kali-kali-rolling.list"
check "kali writes binary and source"      test "$(count_of "$kali_file" '^deb')" = 2

# --- popular catalogue integrity -------------------------------------------
pop="$tmpdir/popular.sh"
build_harness "$pop" var:APT_POPULAR repo_host_vars repo_popular_entry repo_popular_tags_in repo_popular_categories repo_popular_category_label

fields=$(bash -c '. "$1"; printf "%s\n" "$APT_POPULAR"' _ "$pop" |
         awk -F'|' 'NF && NF != 6 { bad++ } END { print bad+0 }')
check "every catalogue entry has six fields" test "$fields" = 0

duptags=$(bash -c '. "$1"; printf "%s\n" "$APT_POPULAR"' _ "$pop" |
          awk -F'|' 'NF { print $1 }' | sort | uniq -d | wc -l)
check "catalogue tags are unique"            test "$duptags" = 0

badcat=$(bash -c '. "$1"; printf "%s\n" "$APT_POPULAR"' _ "$pop" |
         awk -F'|' 'NF { print $6 }' | sort -u | while read -r c; do
             case "$c" in dev|infra|data|browsers|desktop|media|cloud) ;; *) echo "$c";; esac
         done | wc -l)
check "every catalogue row has a known category" test "$badcat" = 0

labels=$(bash -c '. "$1"; repo_popular_categories' _ "$pop" | wc -l)
check "every category has a label"           test "$labels" -ge 7

badline=$(bash -c '. "$1"; printf "%s\n" "$APT_POPULAR"' _ "$pop" |
          awk -F'|' 'NF==6 && $5 !~ /^deb / { print $1 }' | wc -l)
check "every repo line starts with deb"      test "$badline" = 0

badkey=$(bash -c '. "$1"; printf "%s\n" "$APT_POPULAR"' _ "$pop" |
         awk -F'|' 'NF==6 && $3 !~ /^https:\/\// { print $1 }' | wc -l)
check "every key URL is https"               test "$badkey" = 0

badvar=$(bash -c '. "$1"; printf "%s\n" "$APT_POPULAR"' _ "$pop" |
         sed -e 's/\$ID//g' -e 's/\$CODENAME//g' -e 's/\$ARCH//g' \
             -e 's/\$COMPONENT//g' -e 's/\$K//g' |
         awk '/\$/ { n++ } END { print n + 0 }')
check "repo templates use only known variables" test "$badvar" = 0

entries=$(bash -c '. "$1"; printf "%s\n" "$APT_POPULAR" | grep -c .' _ "$pop")
check "catalogue was expanded beyond the old 18" test "$entries" -ge 30

check "known entry resolves by tag"          bash -c '. "$1"; repo_popular_entry docker | grep -q "Docker CE"' _ "$pop"
check "unknown tag is rejected"              bash -c '. "$1"; ! repo_popular_entry not-a-repo' _ "$pop"
check "host vars fall back without dpkg"     bash -c '. "$1"; repo_host_vars; [ -n "$REPO_ARCH" ] && [ -n "$REPO_ID" ]' _ "$pop"
check "codename survives when empty"         bash -c '. "$1"; repo_host_vars; : "${REPO_CODENAME-}"' _ "$pop"

# --- PPA catalogue and parsing ---------------------------------------------
ppa="$tmpdir/ppa.sh"
build_harness "$ppa" var:PPA_CATALOGUE ppa_normalize ppa_owner_archive ppa_is_configured ppa_parse_listing ppa_category_label

badppa=$(bash -c '. "$1"; printf "%s\n" "$PPA_CATALOGUE"' _ "$ppa" |
         awk -F'|' 'NF != 3 { bad++ } END { print bad+0 }')
check "every PPA entry has three fields"     test "$badppa" = 0

badshape=$(bash -c '. "$1"; printf "%s\n" "$PPA_CATALOGUE"' _ "$ppa" |
           awk -F'|' 'NF==3 && $1 !~ /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/ { print $1 }' | wc -l)
check "PPA specs are owner/archive"          test "$badshape" = 0

ppacount=$(bash -c '. "$1"; printf "%s\n" "$PPA_CATALOGUE" | grep -c .' _ "$ppa")
check "PPA list is populated"                test "$ppacount" -ge 20

check "ppa: prefix normalizes"               bash -c '. "$1"; [ "$(ppa_normalize "ppa:deadsnakes/ppa")" = "ppa:deadsnakes/ppa" ]' _ "$ppa"
check "normalize keeps owner/archive"        test "$(bash -c '. "$1"; ppa_normalize "ppa:deadsnakes/ppa"' _ "$ppa")" = "ppa:deadsnakes/ppa"
check "launchpad URL normalizes"             test "$(bash -c '. "$1"; ppa_normalize "https://launchpad.net/~ondrej/+archive/ubuntu/php"' _ "$ppa")" = "ppa:ondrej/php"
check "owner/archive extraction"             test "$(bash -c '. "$1"; ppa_owner_archive "ppa:ondrej/php"' _ "$ppa")" = "ondrej/php"

mkdir -p "$tmpdir/apt/sources.list.d"
printf 'deb [signed-by=/etc/apt/keyrings/x.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu noble main\n' \
    > "$tmpdir/apt/sources.list.d/systui-ppa-ondrej-php.list"
check "configured PPA is detected"           bash -c 'SYSTUI_APT_SOURCES_DIR="$2/apt"; . "$1"; ppa_is_configured ondrej/php' _ "$ppa" "$tmpdir"
check "absent PPA is not reported"           bash -c 'SYSTUI_APT_SOURCES_DIR="$2/apt"; . "$1"; ! ppa_is_configured deadsnakes/ppa' _ "$ppa" "$tmpdir"
check "prefix of a name does not match"      bash -c 'SYSTUI_APT_SOURCES_DIR="$2/apt"; . "$1"; ! ppa_is_configured ondrej/php5' _ "$ppa" "$tmpdir"

# Fixture: the shape Launchpad actually returns (two rows, multi-line desc).
cat > "$tmpdir/listing.html" <<'HTML'
<table class="listing sortable"><tbody>
          <tr class="ppa_batch_row">
  <td><a href="/~neovim-ppa/+archive/ubuntu/stable">Neovim Stable</a></td>
  <td>Neovim releases backported from Debian.

Homepage: https://neo...</td>
  <td>31</td>
  <td>98</td>
</tr>

          <tr class="ppa_batch_row">
  <td><a href="/~deki/+archive/ubuntu/firejail">Firejail</a></td>
  <td>Firejail sandbox builds</td>
  <td>4</td>
  <td>4</td>
</tr>
</tbody></table>
HTML
parsed=$(bash -c '. "$1"; ppa_parse_listing < "$2"' _ "$ppa" "$tmpdir/listing.html")
check "parser finds both rows"               test "$(printf '%s\n' "$parsed" | wc -l)" = 2
check "parser extracts owner/archive"        bash -c 'printf %s "$1" | head -1 | grep -q "^neovim-ppa/stable"' _ "$parsed"
check "parser keeps the display name"        bash -c 'printf %s "$1" | head -1 | grep -q "Neovim Stable"' _ "$parsed"
check "parser joins a multi-line description" bash -c 'printf %s "$1" | head -1 | grep -q "Homepage"' _ "$parsed"
check "parser records the package count"     bash -c 'printf %s "$1" | head -1 | awk -F"\t" "{exit !(\$4==98)}"' _ "$parsed"
check "parser leaves no HTML behind"         bash -c '! printf %s "$1" | grep -q "</td>"' _ "$parsed"

# --- add flow ---------------------------------------------------------------
addfns="$tmpdir/add.sh"
build_harness "$addfns" ppa_add_selected ppa_add_one ppa_signing_fingerprint repo_host_vars
check "add flow exists"                      contains "$SYSCONFIG" 'ppa_add_selected "${todo[@]}"'
check "add flow refreshes indexes once"      contains "$SYSCONFIG" 'apt-get update'
check "direct writer names the keyring"      contains "$SYSCONFIG" 'systui-ppa-${o}-${a}.gpg'
check "direct writer uses launchpadcontent"  contains "$SYSCONFIG" 'ppa.launchpadcontent.net'
check "key is validated before writing"      contains "$SYSCONFIG" 'BEGIN PGP PUBLIC KEY BLOCK'
check "popular add validates keys too"       contains "$SYSCONFIG" 'did not yield an OpenPGP key'
check "search results are cached"            contains "$SYSCONFIG" 'ppa-search-'

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
