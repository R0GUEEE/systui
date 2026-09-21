#!/bin/bash
set -eu

# Ultimate Provision must never look (or be) stuck:
#   * it must not execute /sbin/init to detect the init system (on iSH-AOK that
#     starts a real PID-1 supervisor and the probe blocks forever -- the
#     original "provisioning freezes before its first status line" report);
#   * every package-manager / service-manager call must go through the bounded
#     runner, which detaches stdin, enforces a wall-clock limit even without
#     coreutils `timeout`, and prints a heartbeat;
#   * the per-package fallback must report progress and stop early when the
#     package manager is wedged instead of grinding through the whole list.
#
# The static checks use bash builtins only (no grep/awk/sed): on the emulated
# hosts this tool targets, forking is slow and can occasionally deadlock, and a
# test that freezes while checking for freezes is useless. The runner itself is
# then exercised for real, against commands that hang on purpose.
#
# Set SYSTUI_PROVISION_TEST_ALLOW_SYSTEM=1 to also run the whole provision tool
# against a hanging fake package manager -- that writes system configuration, so
# it is opt-in.

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$PROJECT_DIR/src/provision/provision-ultimate.sh"
TMPDIR_TEST="${TMPDIR:-/tmp}/systui-provision-nonblocking.$$"
mkdir -p "$TMPDIR_TEST"
trap 'rm -rf -- "$TMPDIR_TEST"' EXIT
trap 'echo "not ok - test-provision-nonblocking.sh failed at line $LINENO" >&2' ERR

[ -r "$SCRIPT" ]
script_text="$(<"$SCRIPT")"

fail() { echo "$*" >&2; exit 1; }
has() { [[ $script_text == *"$1"* ]] || fail "expected to find: $1"; }
# matches <label> <ERE>: prints the first matching line and succeeds if the
# script contains a line matching the extended regex.
matches() {
    local line
    while IFS= read -r line; do
        if [[ $line =~ $2 ]]; then printf '%s\n' "$line"; return 0; fi
    done <<< "$script_text"
    return 1
}
# matches_code <label> <ERE>: like matches(), but ignores comment lines, so a
# comment that quotes the old code cannot trip a check.
matches_code() {
    local line
    while IFS= read -r line; do
        [[ $line =~ ^[[:space:]]*# ]] && continue
        if [[ $line =~ $2 ]]; then printf '%s\n' "$line"; return 0; fi
    done <<< "$script_text"
    return 1
}

# --- 1. the init probe that used to freeze the run is gone ------------------
# No execution of an init binary anywhere: only inspection of paths and links
# (so an init path may appear as the argument of readlink / [ -x ], never as the
# first word of a command).
if matches_code init_exec '(^|[;&|(])[[:space:]]*(/sbin/init|/lib/sysvinit/init|/usr/lib/sysvinit/init)([[:space:]]|$)'; then
    fail "/sbin/init is executed by the provision tool"
fi
# ...and the transforms systui applies at install time must still find anchors.
has 'SYSTUI_NONBLOCKING_INIT_DETECT=1'
has 'detect_init_system() {'
has 'detect_package_manager() {'
has 'export DEBIAN_FRONTEND=noninteractive'
matches apt_one '^[[:space:]]*apt\)[[:space:]]+_rto 300 apt-get -o Dpkg::Options::=' >/dev/null || fail "the APT per-package anchor moved"
matches apt_bulk '^[[:space:]]*apt\)[[:space:]]+_rto 1800 apt-get -o Dpkg::Options::=' >/dev/null || fail "the APT bulk-install anchor moved"

# --- 2. no unbounded package-manager / service-manager invocation ----------
# A line that *starts* with a manager command bypasses _rto, and with it the
# stdin detach, the wall-clock limit and the heartbeat.
if matches_code pm_bare '^[[:space:]]*(apt-get|apk|pacman|dnf|yum|zypper|xbps-install|emerge|systemctl|rc-service|rc-update|sv|service)[[:space:]]'; then
    fail "unbounded package/service manager call found"
fi
has '_rto() {'
has 'PROVISION_HEARTBEAT'
has 'PROVISION_TIMEOUT_MAX'
has 'PROVISION_NO_TIMEOUT'

# --- 3. progress + early abort in the per-package fallback -----------------
has 'note "[$_pkg_idx/$_pkg_total] $p"'
has 'note "skipped: $p (unavailable or timed out)"'
has 'the package manager looks wedged'
has 'PROVISION_MAX_CONSECUTIVE_TIMEOUTS'
# the sshd restart used to call an undefined helper, so hardening never applied
if matches_code svc_restart 'service_restart'; then
    fail "undefined service_restart helper is still called"
fi
has '_svc_activate "$_ssh_svc"'

# --- 4. exercise the shipped runner for real -------------------------------
# Extract the knob block + _rto() out of the shipped file, so the test runs the
# code that actually ships rather than a copy of it.
runner_file="$TMPDIR_TEST/runner.sh"
: > "$runner_file"
in_runner=0
in_fn=0
while IFS= read -r line; do
    [[ $line == '_STEP_T0=0'* ]] && in_runner=1
    [ "$in_runner" = 1 ] || continue
    printf '%s\n' "$line" >> "$runner_file"
    [[ $line == '_rto() {'* ]] && in_fn=1
    if [ "$in_fn" = 1 ] && [ "$line" = '}' ]; then break; fi
done <<< "$script_text"
[ "$(wc -l < "$runner_file" | tr -d ' ')" -gt 10 ] || fail "could not extract the runner"

# Snippet preamble: the runner block calls note/warn while it initialises.
snippet() {  # <name> <body>
    {
        printf 'note() { printf "    %%s\\n" "$*"; }\n'
        printf 'warn() { printf "WARN %%s\\n" "$*" >&2; }\n'
        printf '. "$RUNNER"\n'
        printf '%s\n' "$2"
    } > "$TMPDIR_TEST/$1.sh"
}
run_snippet() {  # <name> [env assignments...]
    _name="$1"; shift
    # env(1) rather than leading VAR=val words: an assignment that arrives
    # through "$@" is not re-parsed as an assignment by bash.
    env RUNNER="$runner_file" "$@" sh "$TMPDIR_TEST/$_name.sh" 2>&1
}

echo "  case 4a: a hanging command is killed at the limit" >&2
snippet 4a '_rto 2 sleep 600
echo "rc=$?"'
start=$(date +%s)
out=$(run_snippet 4a PROVISION_HEARTBEAT=0) || true
elapsed=$(( $(date +%s) - start ))
[[ $out == *'rc=124'* ]] || fail "a hanging command was not stopped: $out"
# generous: the watchdog wakes about once a second and a fork on an emulated
# host can cost that much, so a 2s limit is not enforced within 2s wall clock.
[ "$elapsed" -lt 90 ] || fail "the limit fired far too late (${elapsed}s)"

echo "  case 4b: a slow step stays audible" >&2
snippet 4b '_rto 3 sleep 600'
out=$(run_snippet 4b PROVISION_HEARTBEAT=1) || true
[[ $out == *'still running'* ]] || fail "no heartbeat: $out"
[[ $out == *'limit reached'* ]] || fail "no limit notice: $out"

echo "  case 4c: PROVISION_TIMEOUT_MAX caps every limit" >&2
snippet 4c '_rto 600 sleep 600
echo "rc=$?"'
start=$(date +%s)
out=$(run_snippet 4c PROVISION_TIMEOUT_MAX=2 PROVISION_HEARTBEAT=0) || true
elapsed=$(( $(date +%s) - start ))
[[ $out == *'rc=124'* ]] || fail "PROVISION_TIMEOUT_MAX did not cap the step: $out"
[ "$elapsed" -lt 90 ] || fail "the capped limit fired far too late (${elapsed}s)"

echo "  case 4d: stdin is detached" >&2
snippet 4d '_rto 20 sh -c "read line || exit 1; echo read:$line"
echo "rc=$?"'
start=$(date +%s)
out=$(run_snippet 4d PROVISION_HEARTBEAT=0) || true
elapsed=$(( $(date +%s) - start ))
[[ $out == *'rc=1'* ]] || fail "a command reading stdin did not get EOF: $out"
[[ $out != *'read:'* ]] || fail "stdin was not detached: $out"
[ "$elapsed" -lt 40 ] || fail "reading stdin blocked the run (${elapsed}s)"

echo "  case 4e: exit status passthrough" >&2
snippet 4e '_rto 20 sh -c "exit 7"
echo "rc=$?"'
out=$(run_snippet 4e PROVISION_HEARTBEAT=0) || true
[[ $out == *'rc=7'* ]] || fail "status was not passed through: $out"

echo "  case 4f: PROVISION_NO_TIMEOUT=1 opt-out" >&2
snippet 4f '_rto 1 sh -c "sleep 2; exit 3"
echo "rc=$?"'
out=$(run_snippet 4f PROVISION_NO_TIMEOUT=1) || true
[[ $out == *'rc=3'* ]] || fail "PROVISION_NO_TIMEOUT=1 did not run the command: $out"

# --- 5. opt-in end-to-end run against a hanging package manager ------------
if [ "${SYSTUI_PROVISION_TEST_ALLOW_SYSTEM:-0}" = 1 ]; then
    echo "  case 5: end-to-end run with a hanging package manager" >&2
    fakebin="$TMPDIR_TEST/bin"
    mkdir -p "$fakebin"
    for pm in apk apt-get pacman dnf yum zypper xbps-install emerge; do
        printf '#!/bin/sh\nsleep 900\n' > "$fakebin/$pm"
        chmod 0755 "$fakebin/$pm"
    done
    start=$(date +%s)
    out=$(PATH="$fakebin:$PATH" \
        PROVISION_TIMEOUT_MAX=2 PROVISION_HEARTBEAT=1 \
        PROVISION_MAX_CONSECUTIVE_TIMEOUTS=1 SKIP_SERVICES=1 \
        TZ_NAME=UTC TARGET_USER=root NEW_HOSTNAME=test-node \
        sh "$SCRIPT" 2>&1) || true
    elapsed=$(( $(date +%s) - start ))
    [[ $out == *'the package manager looks wedged'* ]] || fail "the wedged package manager was not detected: $out"
    [[ $out == *'provisioning finished'* ]] || fail "the run did not reach the end: $out"
    [ "$elapsed" -lt 300 ] || fail "the run still took too long (${elapsed}s)"
fi

echo "ok - test-provision-nonblocking.sh"
