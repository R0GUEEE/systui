#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. src/features/117-ios-linuxkit-aot-utility.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
IOSKIT_SRC_DIR=$T/source; IOSKIT_AOT_DIR=$T/work
mkdir -p "$IOSKIT_SRC_DIR" "$IOSKIT_AOT_DIR"
: > "$IOSKIT_SRC_DIR/Makefile"
ios_aot_defaults
uname() { case "$1" in -s) echo Linux;; -m) echo aarch64;; esac; }
tui_msg() { :; }
tui_yesno() { return 0; }
systui_ioskit_repo_present() { return 0; }
systui_ioskit_gate_available() { return 0; }
systui_ioskit_image_valid() { [ -d "$1" ]; }
mkdir -p "$IOSKIT_AOT_ROOT/data" "$IOSKIT_AOT_RECORDER_DIR" "$IOSKIT_AOT_RECORDINGS_DIR"
: > "$IOSKIT_AOT_ROOT/meta.db"
: > "$IOSKIT_AOT_RECORDER_DIR/ish"; chmod +x "$IOSKIT_AOT_RECORDER_DIR/ish"
for f in manifest.json workload.sh aot_musl.S aot_busybox.S aot_python.S aot_zlib.S; do echo x > "$IOSKIT_AOT_RECORDINGS_DIR/$f"; done
run_cmd() { printf '%s\n' "$@" >> "$T/args"; return "${MOCK_RC:-0}"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ios_aot_record && fail 'existing recordings accepted'
[ ! -f "$T/args" ] || fail 'record command ran on existing output'
ios_aot_link && fail 'missing linked binary accepted'
[ -f "$T/args" ] || fail 'link not invoked'
grep -Fx -- "-Dcli_aot=$IOSKIT_AOT_RECORDINGS_DIR/aot_musl.S,$IOSKIT_AOT_RECORDINGS_DIR/aot_busybox.S,$IOSKIT_AOT_RECORDINGS_DIR/aot_python.S,$IOSKIT_AOT_RECORDINGS_DIR/aot_zlib.S" "$T/args" >/dev/null || fail 'image argument changed'
# Unsafe make/Meson path is rejected before any command can interpret it.
rm -f "$T/args"
old=$IOSKIT_AOT_OUTPUT_DIR; IOSKIT_AOT_OUTPUT_DIR="$T/evil;touch $T/pwn"
ios_aot_link && fail 'unsafe path accepted'
[ ! -e "$T/pwn" ] && [ ! -e "$T/args" ] || fail 'unsafe command executed'
IOSKIT_AOT_OUTPUT_DIR=$old
mkdir -p "$IOSKIT_AOT_OUTPUT_DIR"
ios_aot_link && fail 'existing output accepted'
[ ! -e "$T/args" ] || fail 'command ran on existing output'
rmdir "$IOSKIT_AOT_OUTPUT_DIR"
MOCK_RC=42; export MOCK_RC
ios_aot_link && fail 'failed setup reported success'
unset MOCK_RC
rm -f "$T/args" "$IOSKIT_AOT_RECORDINGS_DIR/aot_zlib.S"
ios_aot_link && fail 'missing image accepted'
[ ! -e "$T/args" ] || fail 'command ran with missing image'
echo 'AOT utility tests passed'
