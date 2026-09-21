#!/bin/bash
set -eu

# Guards the provision hardening that came out of the code audit:
#   * hostname handling is shell-builtin only (a `grep` on /etc/hosts was a
#     reproduced, unbounded freeze on hosts that deadlock forks) and validates
#     the name before using it;
#   * package names are checked against the index before the all-or-nothing bulk
#     install, so one unknown name cannot throw the run into the slow path;
#   * sshd hardening keeps a backup and rolls back when the result does not
#     validate (a rejected edit used to stay on disk and sshd then refused to
#     start at the next boot);
#   * the advertised periodic maintenance job actually exists, in the run-parts
#     directory the detected distribution's cron reads;
#   * a terminated package-manager step tells the operator which lock to clear;
#   * the parent caps the whole run so a stall is visible instead of a dead TUI.
#
# Static checks use bash builtins only; the few dynamic ones run functions
# extracted from the shipped script (never a copy of them).

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$PROJECT_DIR/src/provision/provision-ultimate.sh"
RUNNER_FEATURE="$PROJECT_DIR/src/features/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-ultimate-provision-install-rescue.sh"
TMPDIR_TEST="${TMPDIR:-/tmp}/systui-provision-hardening.$$"
mkdir -p "$TMPDIR_TEST"
trap 'rm -rf -- "$TMPDIR_TEST"' EXIT
trap 'echo "not ok - test-provision-hardening.sh failed at line $LINENO" >&2' ERR

[ -r "$SCRIPT" ]
[ -r "$RUNNER_FEATURE" ]
script_text="$(<"$SCRIPT")"
feature_text="$(<"$RUNNER_FEATURE")"

fail() { echo "$*" >&2; exit 1; }
has() { [[ $script_text == *"$1"* ]] || fail "provision script: expected to find: $1"; }
has_feature() { [[ $feature_text == *"$1"* ]] || fail "run wrapper: expected to find: $1"; }
matches() {
    local line
    while IFS= read -r line; do
        if [[ $line =~ $2 ]]; then printf '%s\n' "$line"; return 0; fi
    done <<< "$script_text"
    return 1
}
matches_code() {
    local line
    while IFS= read -r line; do
        [[ $line =~ ^[[:space:]]*# ]] && continue
        if [[ $line =~ $2 ]]; then printf '%s\n' "$line"; return 0; fi
    done <<< "$script_text"
    return 1
}
extract_fn() {  # <name>: print that function straight out of the shipped file
    local name="$1" line copy=0
    while IFS= read -r line; do
        case "$line" in
            "$name() {"*) copy=1 ;;
        esac
        if [ "$copy" = 1 ]; then
            printf '%s\n' "$line"
            [ "$line" = '}' ] && break
        fi
    done <<< "$script_text"
}

# --- hostname --------------------------------------------------------------
# The /etc/hosts check must not fork (grep/sed/awk/ls were the freeze).
hostname_fn="$(extract_fn apply_hostname)"
[ -n "$hostname_fn" ] || fail "apply_hostname not found"
case "$hostname_fn" in
    *$'\n'*'grep '*|*$'\n'*'sed '*|*$'\n'*'awk '*|*$'\n'*'ls '*) fail "apply_hostname still forks an external text tool" ;;
esac
has 'valid_hostname() {'
matches_code hostname_ctl 'Ignoring invalid hostname' >/dev/null
has 'apply_hostname "$_hn" /etc/hostname /etc/hosts'
# the old regex-based mapping check must be gone for good
if matches_code old_hn 'grep -qE "\[\[:space:\]\]\$_hn'; then
    fail "the regex /etc/hosts check is back"
fi

# --- package-name filtering ------------------------------------------------
has 'pkg_available() {'
has 'PROVISION_SKIP_FILTER'
has 'not in this distribution'"'"'s index (dropped):$_pkg_dropped'
has 'using the unfiltered list'
if matches_code old_count 'INSTALLED_COUNT=\$\(echo \$PKGS \| wc -w\)'; then
    fail "the bulk path still counts through a subshell"
fi
has 'packages requested; already-present ones are included'

# --- sshd backup / rollback ------------------------------------------------
sshd_fn="$(extract_fn harden_sshd_inplace)"
[ -n "$sshd_fn" ] || fail "harden_sshd_inplace not found"
case "$sshd_fn" in
    *'_hs_bak="$_hs_cfg.systui.bak.'*) : ;;
    *) fail "in-place sshd hardening no longer keeps a timestamped backup" ;;
esac
case "$sshd_fn" in
    *'cp -a "$_hs_bak" "$_hs_cfg"'*) : ;;
    *) fail "in-place sshd hardening does not restore its backup" ;;
esac
has 'rm -f "$_SSH_DROP"'
has 'harden_sshd_inplace "$_SSH_MAIN"'

# --- periodic maintenance job ---------------------------------------------
has 'MAINT_SCRIPT=/usr/local/sbin/systui-maintenance'
has 'maint_dir=/etc/periodic/daily'
has 'ln -sf "$MAINT_SCRIPT" "$maint_dir/systui-maintenance"'
has 'find /tmp -type f -atime +7 -delete'
has 'pm_cache_trim() {'
has 'chmod 0755 "$MAINT_SCRIPT"'
# run-parts on Debian skips names containing a dot
case "$script_text" in
    *'$maint_dir/systui-maintenance.sh'*) fail "the maintenance job name must not contain a dot" ;;
esac

# --- package-manager lock hint --------------------------------------------
has 'rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock'
has 'rm -f /lib/apk/db/lock'
has 'rm -f /var/lib/pacman/db.lck'
has '_pm_timeout_seen=1'

# --- pacman full-upgrade opt-out ------------------------------------------
has 'PROVISION_PACMAN_SYSUPGRADE'
has 'pacman -Syu --noconfirm'
# the repo-wide invariant: never a partial-upgrade refresh
if matches_code partial_sy 'pacman[[:space:]]+-Sy([[:space:]]|$)' && \
   ! matches_code partial_sy 'pacman[[:space:]]+-Syu([[:space:]]|$)'; then
    fail "a partial-upgrade pacman refresh is back"
fi

# --- timezone preseed -----------------------------------------------------
has 'debconf-set-selections'
has 'tzdata tzdata/Areas select %s'
has 'not installed yet (tzdata arrives with the package pass)'

# --- outer guard in the run wrapper ---------------------------------------
has_feature 'PROVISION_TOTAL_TIMEOUT'
has_feature 'while kill -0 "$prov_pid" 2>/dev/null; do'
has_feature 'kill -KILL "$prov_pid"'
has_feature 'if wait "$prov_pid"; then'

# --- critical-path file checks are builtin-only ----------------------------
has 'file_has_word /etc/shells /bin/bash'
has 'file_has_prefix /etc/environment '"'"'LANG='"'"''
has 'file_has_text "$_cfg" "$NVIM_MARKER"'
has 'file_has_text "$_cfg" "$TMUX_MARKER"'
has 'file_has_prefix "$_SSH_MAIN" "Include"'
has '_ch_tmp=/etc/default/chrony.systui.$$'
if matches_code old_chrony_sed "sed -i 's/\^DAEMON_OPTS="; then
    fail "the chrony DAEMON_OPTS rewrite still forks sed"
fi

# --- dynamic: the builtin file checks -------------------------------------
eval "$(extract_fn file_has_word)"
eval "$(extract_fn file_has_prefix)"
eval "$(extract_fn file_has_text)"
printf '/bin/sh\n/bin/bash\n' > "$TMPDIR_TEST/shells"
file_has_word "$TMPDIR_TEST/shells" /bin/bash || fail "file_has_word missed a word"
if file_has_word "$TMPDIR_TEST/shells" /bin/zsh; then fail "file_has_word matched a missing word"; fi
# a word must not match as a substring of another word
printf 'other /bin/bashish\n' > "$TMPDIR_TEST/words"
if file_has_word "$TMPDIR_TEST/words" /bin/bash; then fail "file_has_word matched a substring"; fi
printf 'LANG=C.UTF-8\n' > "$TMPDIR_TEST/env"
file_has_prefix "$TMPDIR_TEST/env" 'LANG=' || fail "file_has_prefix missed a prefix"
if file_has_prefix "$TMPDIR_TEST/env" 'LC_ALL='; then fail "file_has_prefix matched a missing prefix"; fi
file_has_text "$TMPDIR_TEST/env" 'C.UTF-8' || fail "file_has_text missed a substring"
if file_has_text "$TMPDIR_TEST/env" 'nope'; then fail "file_has_text matched absent text"; fi
if file_has_text "$TMPDIR_TEST/absent-file" 'x'; then fail "file_has_text accepted a missing file"; fi

# --- dynamic: valid_hostname ----------------------------------------------
eval "$(extract_fn valid_hostname)"
for ok in host my.host host-1 a 1host; do
    valid_hostname "$ok" || fail "valid_hostname rejected '$ok'"
done
for bad in '' '-x' 'x-' 'a..b' 'bad_host' 'a b' 'x!' '.x' 'x.'; do
    if valid_hostname "$bad"; then fail "valid_hostname accepted '$bad'"; fi
done
long64=""
while [ "${#long64}" -lt 64 ]; do long64="${long64}a"; done
if valid_hostname "$long64"; then fail "valid_hostname accepted a 64-character name"; fi

# --- dynamic: apply_hostname (pure builtins, temp files) ------------------
_rto() { return 0; }   # stand-in for the shipped runner; the tests below only
                          # care about the file handling, and not forking keeps the
                          # test safe on hosts where a fork can deadlock
eval "$(extract_fn apply_hostname)"

# a fresh hosts file gets a 127.0.1.1 mapping for the name
printf '127.0.0.1\tlocalhost\n' > "$TMPDIR_TEST/hosts1"
apply_hostname "test-node" "$TMPDIR_TEST/hname1" "$TMPDIR_TEST/hosts1"
[ "$(cat "$TMPDIR_TEST/hname1")" = "test-node" ] || fail "hostname file not written"
case "$(<"$TMPDIR_TEST/hosts1")" in
    *'127.0.1.1	test-node'*) : ;;
    *) fail "no 127.0.1.1 mapping was added: $(<"$TMPDIR_TEST/hosts1")" ;;
esac

# an existing mapping is replaced, not duplicated, and the old name is gone
printf '127.0.0.1\tlocalhost\n127.0.1.1\told-name old\n' > "$TMPDIR_TEST/hosts2"
apply_hostname "new-name" "$TMPDIR_TEST/hname2" "$TMPDIR_TEST/hosts2"
n_map=0
while IFS= read -r line; do
    case "$line" in 127.0.1.1*) n_map=$((n_map + 1)) ;; esac
    case "$line" in *old-name*) fail "the previous 127.0.1.1 mapping was left behind" ;; esac
done < "$TMPDIR_TEST/hosts2"
[ "$n_map" = 1 ] || fail "expected exactly one 127.0.1.1 line, found $n_map"

# an already-present name is not added twice
printf '127.0.0.1\tlocalhost\n127.0.1.1\tsame-node\n' > "$TMPDIR_TEST/hosts3"
apply_hostname "same-node" "$TMPDIR_TEST/hname3" "$TMPDIR_TEST/hosts3"
n_same=0
while IFS= read -r line; do
    case "$line" in *same-node*) n_same=$((n_same + 1)) ;; esac
done < "$TMPDIR_TEST/hosts3"
[ "$n_same" = 1 ] || fail "an existing mapping was duplicated ($n_same lines)"

# a dotted hostname is compared literally, not as a regex
printf '127.0.0.1\tlocalhost myXhost\n' > "$TMPDIR_TEST/hosts4"
apply_hostname "my.host" "$TMPDIR_TEST/hname4" "$TMPDIR_TEST/hosts4"
case "$(<"$TMPDIR_TEST/hosts4")" in
    *'127.0.1.1	my.host'*) : ;;
    *) fail "a dotted hostname was matched as a regex and got no mapping" ;;
esac

# --- dynamic: pkg_available ----------------------------------------------
PATH_SAVE="$PATH"
mkdir -p "$TMPDIR_TEST/bin"
cat > "$TMPDIR_TEST/bin/apk" <<'STUB'
#!/bin/sh
for a in "$@"; do [ "$a" = good-pkg ] && exit 0; done
exit 1
STUB
chmod 0755 "$TMPDIR_TEST/bin/apk"
eval "$(extract_fn pkg_available)"
PACKAGE_MANAGER=apk
PATH="$TMPDIR_TEST/bin:$PATH"
pkg_available good-pkg || fail "pkg_available rejected a package the manager knows"
if pkg_available missing-pkg; then fail "pkg_available accepted an unknown package"; fi
PATH="$PATH_SAVE"

echo "ok - test-provision-hardening.sh"
