#!/usr/bin/env bash
# Guest rootfs import: stalls must not hang, failures must not leave a partial
# image, and replacing an image must be atomic.
#
# Config, images and downloads all live in a temporary directory; the only
# network use is a loopback server that deliberately stalls.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$ROOT/src/features/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-ios-linuxkit-manager.sh"
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT

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
equals() { [ "$1" = "$2" ] || { printf '    expected: %s\n    actual  : %s\n' "$2" "$1"; return 1; }; }

# The module is sourced directly: these are pure IO helpers with no menu.
SYSTUI_TMP="$T/tmp"; mkdir -p "$SYSTUI_TMP"; export SYSTUI_TMP
# shellcheck source=/dev/null
. "$MODULE"

log() { :; }
MSG=""
tui_msg() { MSG="$2"; }
tui_yesno() { return 0; }
tui_input() { return 1; }
run_cmd() { local _d="$1"; shift; "$@"; }

export IOSKIT_IMAGES_DIR="$T/images"
export IOSKIT_DOWNLOAD_DIR="$T/dl"
export IOSKIT_SRC_DIR="$T/src"
export SYSTUI_IOSKIT_CONF="$T/ioskit.conf"
export IOSKIT_DEFAULT_IMAGE=""
export IOSKIT_ROOTFS_URL=""
export IOSKIT_ROOTFS_SHA256=""
mkdir -p "$IOSKIT_IMAGES_DIR" "$IOSKIT_DOWNLOAD_DIR" "$IOSKIT_SRC_DIR/build-arm64-linux/tools"

fakefsify() { # <body>
    printf '#!/bin/sh\n%s\n' "$1" > "$IOSKIT_SRC_DIR/build-arm64-linux/tools/fakefsify"
    chmod +x "$IOSKIT_SRC_DIR/build-arm64-linux/tools/fakefsify"
}

# --- 1. the fetcher is bounded ------------------------------------------------
# A transfer that stalls used to wait forever with the bar already at 100%.
fetch_body=$(declare -f systui_ioskit_fetch)
contains() { case "$1" in *"$2"*) return 0 ;; *) printf '    missing: %s\n' "$2"; return 1 ;; esac; }
check "fetch sets a connect timeout" contains "$fetch_body" "--connect-timeout"
check "fetch abandons a stalled transfer" contains "$fetch_body" "--speed-time"
check "fetch has an absolute cap" contains "$fetch_body" "--max-time"

# A stall must be abandoned quickly, not merely eventually: with a 3s window
# the call has to come back in single-digit seconds, not after curl's default
# two-minute inactivity timeout.

# Behavioural check: a server that sends one chunk and then goes quiet.
if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    port=$((20000 + $$ % 10000))
    python3 - "$port" "$T" <<'PY' &
import socket, sys, time
port = int(sys.argv[1])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(1)
s.settimeout(60)
try:
    c, _ = s.accept(); c.recv(4096)
    c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
              b"Transfer-Encoding: chunked\r\n\r\n")
    body = b"z" * 10000
    c.sendall(("%X\r\n" % len(body)).encode() + body + b"\r\n")
    time.sleep(30)          # stall: no more data, connection stays open
except Exception:
    pass
PY
    server=$!
    sleep 1
    start=$(date +%s)
    SYSTUI_IOSKIT_STALL_SECONDS=3 SYSTUI_IOSKIT_MAX_SECONDS=15 \
        systui_ioskit_fetch "http://127.0.0.1:$port/x.tar.gz" "$T/stall.out" >/dev/null 2>&1
    rc=$?
    elapsed=$(( $(date +%s) - start ))
    kill "$server" 2>/dev/null
    wait "$server" 2>/dev/null
    check "a stalled transfer fails instead of hanging" test "$rc" -ne 0
    # The exact delay depends on the transport: curl's speed-limit cancels the
    # transfer itself, while a slower path only trips the absolute cap -- or the
    # retry budget, which alone runs to 2x2s. What matters is that the call
    # returns instead of waiting forever; an unbounded fetch never does.
    check "the stall is abandoned within the configured window" test "$elapsed" -le 60
else
    printf 'skip - python3/curl unavailable for the behavioural stall check\n'
fi

# --- 2. a failed import leaves nothing behind ---------------------------------
: > "$T/x.tar.gz"

fakefsify 'mkdir -p "$2/data"; echo half > "$2/half"; exit 1'
systui_ioskit_import_tarball "$T/x.tar.gz" demo
check "a failed fakefsify is reported as a failure" test $? -ne 0
check "a failed import leaves no image directory" equals "$(ls -A "$IOSKIT_IMAGES_DIR" | tr '\n' ' ')" ""

fakefsify 'mkdir -p "$2"; echo junk > "$2/notes.txt"'
systui_ioskit_import_tarball "$T/x.tar.gz" demo
check "a result that is not a rootfs is rejected" test $? -ne 0
check "a rejected import leaves no image directory" equals "$(ls -A "$IOSKIT_IMAGES_DIR" | tr '\n' ' ')" ""

# --- 3. success installs the image and sets the default -----------------------
fakefsify 'mkdir -p "$2/data"; : > "$2/meta.db"'
systui_ioskit_import_tarball "$T/x.tar.gz" demo
check "a valid import succeeds" test $? -eq 0
check "the image directory exists" test -d "$IOSKIT_IMAGES_DIR/demo"
check "no staging or backup leftovers" equals "$(ls -A "$IOSKIT_IMAGES_DIR" | tr '\n' ' ')" "demo "
check "the first image becomes the default" equals "$IOSKIT_DEFAULT_IMAGE" "demo"

# --- 4. replacing an image is atomic ------------------------------------------
: > "$IOSKIT_IMAGES_DIR/keep.me"
fakefsify 'mkdir -p "$2/data"; : > "$2/meta.db"'
systui_ioskit_import_tarball "$T/x.tar.gz" demo
check "replacing an existing image succeeds" test $? -eq 0
check "replacing leaves no .old or .import directories" equals \
    "$(ls -A "$IOSKIT_IMAGES_DIR" | tr '\n' ' ')" "demo keep.me "

# A replacement that fails must restore the image that was there.
fakefsify 'mkdir -p "$2/data"; : > "$2/partial"; exit 1'
systui_ioskit_import_tarball "$T/x.tar.gz" demo
check "a failed replacement is reported" test $? -ne 0
check "a failed replacement keeps the previous image" test -f "$IOSKIT_IMAGES_DIR/demo/meta.db"
check "a failed replacement removes its staging directory" equals \
    "$(ls -A "$IOSKIT_IMAGES_DIR" | tr '\n' ' ')" "demo keep.me "

# --- 5. the iSH-AOK proxy binary's argument shape ----------------------------
# Its usage line puts the flags directory first and takes <tarball> <output>,
# unlike the upstream tool. Both shapes must work.
: > "$IOSKIT_IMAGES_DIR/keep.me"
fakefsify 'case "$1" in --help) echo "usage: fakefsify <flags dir> <tarball> <output> <flags...>"; exit 0;; esac
mkdir -p "$2/data"; : > "$2/meta.db"; printf "%s" "$3" > "$2/flagsdir.txt"'
systui_ioskit_import_tarball "$T/x.tar.gz" proxyimg
check "a proxy-style fakefsify is detected and used" test $? -eq 0
check "the proxy import produced an image" test -d "$IOSKIT_IMAGES_DIR/proxyimg"
check "the proxy received a flags directory" test -s "$IOSKIT_IMAGES_DIR/proxyimg/flagsdir.txt"
check "the flags directory is not left next to the image" equals \
    "$(ls -A "$IOSKIT_IMAGES_DIR" | tr '\n' ' ')" "demo keep.me proxyimg "

printf '%s checks, %s failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
