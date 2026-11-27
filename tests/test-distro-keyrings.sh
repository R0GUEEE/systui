#!/usr/bin/env bash
# Archive keyrings for configured distributions.
#
# Keys used to be a flat list of eleven distros with no relation to the sources
# on the machine: selecting Debian did not tell you Debian was actually needed,
# and an entry written without its keyring failed apt-get update with NO_PUBKEY.
# These checks cover the requirement logic and the signed-by repair pass.
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

preamble() {
    cat <<'EOF'
LOGFILE=<TMP>/run.log; WARNFILE=<TMP>/run.warn; SYSTUI_TMP=<TMP>
PM=${PM:-apt}
log()  { printf '[log] %s\n' "$*" >> "$LOGFILE"; }
warn() { printf '[warn] %s\n' "$*" >> "$WARNFILE"; }
show_warnings() { :; }
run_cmd() { printf 'RUN: %s\n' "$*"; return 0; }
tui_msg() { printf 'MSG: %s\n' "$1"; }
tui_yesno() { return 0; }
tui_text() { :; }
tui_wait() { :; }
tui_input() { printf '%s\n' "${INPUT_ANSWER:-}"; }
tui_radio() { printf '%s\n' "${RADIO_ANSWER:-}"; }
tui_menu()  { printf '%s\n' "${MENU_ANSWER:-back}"; }
tui_check() { printf '%s\n' "${CHECK_ANSWER:-}"; }
distro_repo_label() { printf '%s\n' "$1"; }
EOF
}

extract() {
    local fn name
    for fn in "$@"; do
        case "$fn" in
            var:*) name=${fn#var:}; sed -n "/^${name}=/{p;q;}" "$SYSCONFIG" ;;
            *)
                awk -v re="^${fn}\\(\\) \\{" '
                    $0 ~ re { print; if ($0 ~ /}[[:space:]]*$/) exit; inn = 1; next }
                    inn { print; if ($0 ~ /^}/) exit }
                ' "$SYSCONFIG" ;;
        esac
        printf '\n'
    done
}

harness="$tmpdir/harness.sh"
{
    printf '#!/usr/bin/env bash\n'
    preamble | sed "s#<TMP>#$tmpdir#g"
    extract repo_sources_dir repo_keyring_dir repo_keyring_file_for \
        repo_distro_for_apt_url repo_referenced_distros repo_repair_signed_by \
        repo_ensure_distro_keyring
} > "$harness"
bash -n "$harness" || { echo 'harness does not parse'; exit 1; }

# --- static wiring ----------------------------------------------------------
check "keys menu installs distro keyrings"        contains "$SYSCONFIG" 'repo_ensure_distro_keyring "$distro"'
check "distro writer refuses unsigned entries"    contains "$SYSCONFIG" 'refusing to write an unverifiable entry'
check "required keyrings are listed first"        contains "$SYSCONFIG" 'REQUIRED, a configured repository cannot be verified'
check "repair pass adds signed-by"                contains "$SYSCONFIG" 'repo_repair_signed_by() {'
check "keys submenu has a required-keyring view"  contains "$PROJECT_DIR/src/features/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-sysconfig-audit-polish.sh" 'Show keyrings required by the configured sources'

# --- fixtures ---------------------------------------------------------------
apt="$tmpdir/apt"
keys="$tmpdir/keyrings"
mkdir -p "$apt/sources.list.d" "$keys"
export SYSTUI_APT_SOURCES_DIR="$apt"
export SYSTUI_KEYRING_DIR="$keys"

cat > "$apt/sources.list" <<'EOF_LIST'
deb http://deb.debian.org/debian bookworm main
# deb http://archive.ubuntu.com/ubuntu noble main
EOF_LIST
cat > "$apt/sources.list.d/systui-distro-debian-bookworm.list" <<'EOF_DEB'
# Added by systui Distro Repos — Debian bookworm
deb http://deb.debian.org/debian bookworm main
deb http://security.debian.org/debian-security bookworm-security main
EOF_DEB
cat > "$apt/sources.list.d/systui-distro-ubuntu-noble.list" <<'EOF_UBU'
deb [arch=amd64] http://archive.ubuntu.com/ubuntu noble main
EOF_UBU
cat > "$apt/sources.list.d/other-thirdparty.list" <<'EOF_OTHER'
deb http://deb.debian.org/debian bookworm main
EOF_OTHER

# --- requirement detection ---------------------------------------------------
refs=$(bash -c '. "$1"; repo_referenced_distros' _ "$harness")
check "referenced distro is detected (debian)"  bash -c 'printf %s "$1" | grep -qx debian' _ "$refs"
check "referenced distro is detected (ubuntu)"  bash -c 'printf %s "$1" | grep -qx ubuntu' _ "$refs"
check "commented entries are ignored"           bash -c 'printf %s "$1" | grep -qv devuan' _ "$refs"
check "each distro is reported once"            bash -c '[ "$(printf "%s\n" "$1" | grep -c debian)" -eq 1 ]' _ "$refs"

check "debian keyring is missing"               bash -c '. "$1"; ! repo_keyring_file_for debian' _ "$harness"
printf 'PGP\n' > "$keys/debian-archive-keyring.gpg"   # -s: a keyring must not be empty
check "installed debian keyring is found"       bash -c '. "$1"; repo_keyring_file_for debian' _ "$harness"
check "ubuntu keyring still missing"            bash -c '. "$1"; ! repo_keyring_file_for ubuntu' _ "$harness"

# --- signed-by repair --------------------------------------------------------
bash -c '. "$1"; repo_repair_signed_by' _ "$harness" >/dev/null 2>&1
check "debian entry gains signed-by"            contains "$apt/sources.list.d/systui-distro-debian-bookworm.list" '[signed-by='
check "security entry gains signed-by"          bash -c '[ "$(grep -c "signed-by" "$1/sources.list.d/systui-distro-debian-bookworm.list")" -eq 2 ]' _ "$apt"
check "ubuntu entry is left alone without its key" not_contains "$apt/sources.list.d/systui-distro-ubuntu-noble.list" 'signed-by'
check "existing arch option is preserved"       bash -c '[ "$(grep -c "^deb \[arch=amd64\]" "$1/sources.list.d/systui-distro-ubuntu-noble.list")" -eq 1 ]' _ "$apt"
check "hand-written sources are untouched"      not_contains "$apt/sources.list" 'signed-by'
check "third-party files are untouched"         not_contains "$apt/sources.list.d/other-thirdparty.list" 'signed-by'

printf 'PGP\n' > "$keys/ubuntu-archive-keyring.gpg"
bash -c '. "$1"; repo_repair_signed_by ubuntu' _ "$harness" >/dev/null 2>&1
check "ubuntu entry gains signed-by once keyed" contains "$apt/sources.list.d/systui-distro-ubuntu-noble.list" 'signed-by='
check "arch option and signed-by share one group" \
    bash -c 'grep -qE "^deb \[arch=amd64 signed-by=[^]]+\] http" "$1/sources.list.d/systui-distro-ubuntu-noble.list"' _ "$apt"

first=$(cat "$apt/sources.list.d/systui-distro-debian-bookworm.list")
bash -c '. "$1"; repo_repair_signed_by' _ "$harness" >/dev/null 2>&1
check "repair is idempotent"                    bash -c '[ "$1" = "$2" ]' _ "$first" "$(cat "$apt/sources.list.d/systui-distro-debian-bookworm.list")"

check "ensure succeeds when the keyring exists" \
    bash -c '. "$1"; repo_ensure_distro_keyring debian quiet' _ "$harness"

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
