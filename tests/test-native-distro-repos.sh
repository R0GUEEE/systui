#!/usr/bin/env bash
# Distro Repos on non-APT hosts.
#
# The menu used to answer "APT required" on Alpine, Arch, Fedora, openSUSE,
# Void and Gentoo, so the feature was dead on the hosts systui ships on. These
# checks run the real writer functions against sandbox files: the block is
# rewritten in place, never stacked, and a pacman section is enabled or
# commented instead of being duplicated (pacman rejects duplicate sections).
set -uo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SYSCONFIG="$PROJECT_DIR/src/features/sysconfig.sh"
MENU_FIXES="$PROJECT_DIR/src/features/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-sysconfig-audit-fixes.sh"

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

preamble() {
    cat <<'EOF'
LOGFILE=<TMP>/run.log; WARNFILE=<TMP>/run.warn; SYSTUI_TMP=<TMP>
PM=${PM:-apk}
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
tui_check() { printf '%s\n' "${CHECK_ANSWER:-}"; }
repo_host_vars() { REPO_ID=alpine; REPO_CODENAME=; REPO_ARCH=x86_64; REPO_COMPONENT=main; }
EOF
}

extract() {
    local fn name
    for fn in "$@"; do
        case "$fn" in
            var:*)
                # sed only tests the end pattern on lines after the start
                # match, so a one-line assignment needs an explicit stop.
                name=${fn#var:}
                sed -n "/^${name}=/{p;q;}" "$SYSCONFIG" ;;
            *)
                # Function signatures may carry a trailing comment, and a
                # one-line definition ("fn() { body; }") must not swallow the
                # closing brace of the next function.
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
    extract var:REPO_BLOCK_BEGIN var:REPO_BLOCK_END \
        repo_native_file repo_write_block repo_native_refresh \
        repo_apk_file repo_apk_mirror repo_apk_release repo_apk_has repo_apk_write \
        repo_pacman_conf repo_pacman_active repo_pacman_set \
        repo_xbps_file repo_xbps_libc repo_xbps_base repo_xbps_has repo_xbps_write \
        repo_portage_conf repo_portage_write
} > "$harness"
bash -n "$harness" || { echo 'harness does not parse'; exit 1; }

# --- static wiring ----------------------------------------------------------
check "sysconfig defines the native dispatcher"  contains "$SYSCONFIG" 'menu_distro_repos_native() {'
check "dispatcher routes apk"                    contains "$SYSCONFIG" 'apk)     menu_distro_repos_apk ;;'
check "dispatcher keeps the apt flow"            contains "$SYSCONFIG" 'apt) menu_distro_repos_apt ;;'
check "apk writer targets /etc/apk/repositories" contains "$SYSCONFIG" 'SYSTUI_APK_REPOS_FILE /etc/apk/repositories'
check "pacman edits the section in place"        contains "$SYSCONFIG" 'repo_pacman_set "$s" off'
check "dnf toggles through config-manager"       contains "$SYSCONFIG" 'config-manager --set-enabled'
check "zypper toggles through modifyrepo"        contains "$SYSCONFIG" 'modifyrepo --enable'
check "xbps writes a drop-in conf"               contains "$SYSCONFIG" '00-systui-distro.conf'
check "portage writes repos.conf"                contains "$SYSCONFIG" 'SYSTUI_PORTAGE_REPOS_DIR /etc/portage/repos.conf'
check "menu no longer gates on APT"              not_contains "$MENU_FIXES" 'Distro Repos currently writes APT repository definitions'

# --- Alpine -----------------------------------------------------------------
apkfile="$tmpdir/apk-repositories"
# A foreign (hand-written) entry on a different branch: it must survive the
# rewrite and must not be counted as part of the managed block.
printf 'https://mirror.example.net/alpine/v3.20/main\n# keep me\n' > "$apkfile"
export SYSTUI_APK_REPOS_FILE="$apkfile"
export SYSTUI_ALPINE_RELEASE_FILE="$tmpdir/alpine-release"
printf '3.21.3\n' > "$tmpdir/alpine-release"

check "apk release is derived from /etc/alpine-release" \
    bash -c '. "$1"; [ "$(repo_apk_release)" = v3.21 ]' _ "$harness"
check "apk mirror is reused from the existing entry" \
    bash -c '. "$1"; [ "$(repo_apk_mirror)" = https://mirror.example.net/alpine ]' _ "$harness"

bash -c '. "$1"; repo_apk_write v3.21 main community' _ "$harness" >/dev/null
check "apk block lists main"        contains "$apkfile" 'https://mirror.example.net/alpine/v3.21/main'
check "apk block lists community"   contains "$apkfile" 'https://mirror.example.net/alpine/v3.21/community'
check "apk file keeps foreign lines" contains "$apkfile" '# keep me'
check "apk block is marked"         contains "$apkfile" '# >>> systui distro repos >>>'
check "apk main appears once"       bash -c '[ "$(grep -c "/v3.21/main" "$1")" -eq 1 ]' _ "$apkfile"

bash -c '. "$1"; repo_apk_write v3.21 main' _ "$harness" >/dev/null
check "apk rewrite drops the deselected component" not_contains "$apkfile" '/v3.21/community'
check "apk rewrite keeps one block"   bash -c '[ "$(grep -c ">>> systui distro repos >>>" "$1")" -eq 1 ]' _ "$apkfile"
first=$(cat "$apkfile")
bash -c '. "$1"; repo_apk_write v3.21 main' _ "$harness" >/dev/null
check "apk rewrite is idempotent"     bash -c '[ "$1" = "$2" ]' _ "$first" "$(cat "$apkfile")"
check "apk_has finds a written component" \
    bash -c '. "$1"; repo_apk_has v3.21/main' _ "$harness"
check "apk_has ignores a missing component" \
    bash -c '. "$1"; ! repo_apk_has v3.21/community' _ "$harness"

# --- Arch -------------------------------------------------------------------
conf="$tmpdir/pacman.conf"
cat > "$conf" <<'EOF_CONF'
[options]
HoldPkg = pacman glibc

[core]
Include = /etc/pacman.d/mirrorlist

#[multilib]
#Include = /etc/pacman.d/mirrorlist
EOF_CONF
export SYSTUI_PACMAN_CONF="$conf"

check "pacman reports an active section"  bash -c '. "$1"; repo_pacman_active core' _ "$harness"
check "pacman reports a commented section as off" bash -c '. "$1"; ! repo_pacman_active multilib' _ "$harness"

bash -c '. "$1"; repo_pacman_set multilib on' _ "$harness" >/dev/null
check "pacman enables a commented section" bash -c '[ "$(grep -c "^\[multilib\]" "$1")" -eq 1 ]' _ "$conf"
check "pacman uncomments its Include"      bash -c '[ "$(grep -c "^Include = /etc/pacman.d/mirrorlist" "$1")" -eq 2 ]' _ "$conf"
check "pacman keeps unrelated options"     contains "$conf" 'HoldPkg = pacman glibc'

bash -c '. "$1"; repo_pacman_set core off' _ "$harness" >/dev/null
check "pacman comments a disabled section" bash -c '[ "$(grep -c "^#\[core\]" "$1")" -eq 1 ]' _ "$conf"
check "pacman disables its Include too"    bash -c '[ "$(grep -c "^#Include = /etc/pacman.d/mirrorlist" "$1")" -eq 1 ]' _ "$conf"
check "pacman does not duplicate sections" bash -c '[ "$(grep -cE "^#?\[(core|multilib)\]" "$1")" -eq 2 ]' _ "$conf"

# --- Void -------------------------------------------------------------------
xdir="$tmpdir/xbps.d"
mkdir -p "$xdir"
export SYSTUI_XBPS_CONF_DIR="$xdir"
bash -c '. "$1"; repo_xbps_write glibc base nonfree' _ "$harness" >/dev/null
check "xbps writes a drop-in conf"   contains "$xdir/00-systui-distro.conf" 'repository=https://repo-default.voidlinux.org/current'
check "xbps lists nonfree"           contains "$xdir/00-systui-distro.conf" 'repository=https://repo-default.voidlinux.org/current/nonfree'
check "xbps detects base"            bash -c '. "$1"; repo_xbps_has current/nonfree' _ "$harness"
bash -c '. "$1"; repo_xbps_write musl base' _ "$harness" >/dev/null
check "xbps musl repo path"          contains "$xdir/00-systui-distro.conf" 'current/musl'
check "xbps drops nonfree on rewrite" not_contains "$xdir/00-systui-distro.conf" 'nonfree'

# --- Gentoo -----------------------------------------------------------------
pdir="$tmpdir/portage/repos.conf"
export SYSTUI_PORTAGE_REPOS_DIR="$pdir"
bash -c '. "$1"; repo_portage_write git' _ "$harness" >/dev/null
check "portage writes [gentoo]"      contains "$pdir/systui-gentoo.conf" '[gentoo]'
check "portage honours git sync"     contains "$pdir/systui-gentoo.conf" 'sync-type = git'
check "portage points at the mirror" contains "$pdir/systui-gentoo.conf" 'gentoo-mirror/gentoo.git'
bash -c '. "$1"; repo_portage_write rsync' _ "$harness" >/dev/null
check "portage switches to rsync"    contains "$pdir/systui-gentoo.conf" 'sync-type = rsync'

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
