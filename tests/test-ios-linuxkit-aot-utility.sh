#!/usr/bin/env bash
# shellcheck shell=bash
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
# Guided front door exposes a single ordered wizard and stops after a failed stage.
tui_capture_menu() {
    local dest=$1; shift
    printf '%s\n' "$@" > "$T/menu"
    printf -v "$dest" '%s' back
}
systui_ioskit_load() { :; }
menu_ios_linuxkit_aot
# The top-level menu is now an index; the guided workflow is one entry among
# status/workflow/stages/advanced/rollback/about.
grep -qx -- 'workflow' "$T/menu" || fail 'guided workflow is absent from the AOT menu'
GUIDE_LOG=$T/guide
: > "$GUIDE_LOG"
tui_msg() { :; }
tui_yesno() { return 0; }
ios_aot_host() { return 0; }
ios_aot_setup() { echo setup >> "$GUIDE_LOG"; }
ios_aot_configure() { echo paths >> "$GUIDE_LOG"; }
ios_aot_build() { echo "build:$1" >> "$GUIDE_LOG"; if [ "${GUIDE_FAIL:-}" = "$1" ]; then return 1; fi; return 0; }
ios_aot_rootfs() { echo rootfs >> "$GUIDE_LOG"; }
ios_aot_prepare_guest() { echo guest >> "$GUIDE_LOG"; }
ios_aot_record() { echo record >> "$GUIDE_LOG"; }
ios_aot_link() { echo link >> "$GUIDE_LOG"; }
ios_aot_validate() { echo validate >> "$GUIDE_LOG"; }
GUIDE_FAIL=recorder
if ios_aot_guided_setup; then fail 'guided setup ignored recorder failure'; fi
[ "$(tail -1 "$GUIDE_LOG")" = build:recorder ] || fail 'guided setup continued after failure'
GUIDE_FAIL=
: > "$GUIDE_LOG"
ios_aot_guided_setup || fail 'guided workflow did not complete'
[ "$(tail -1 "$GUIDE_LOG")" = validate ] || fail 'guided workflow skipped validation'
echo 'Guided AOT setup tests passed'



# --- menu: one front door, an index, and stages one level down -------------
SPLIT=$T/menu-split.$$; : > "$SPLIT"
tui_capture_menu() {
    local dest=$1; shift
    printf '%s\n' "$@" > "$T/menu-tags"
    printf '#sub\n' >> "$SPLIT"
    case "$(wc -l < "$SPLIT")" in
        1) printf -v "$dest" '%s' stages ;;
        2) printf -v "$dest" '%s' back ;;
        *) printf -v "$dest" '%s' back ;;
    esac
    return 0
}
menu_ios_linuxkit_aot
for tag in status workflow stages toolchain rollback about back; do
    grep -qx -- "$tag" "$T/menu-tags" || fail "AOT menu lacks $tag"
done
grep -q '^#sub' "$SPLIT" && [ "$(grep -c '^#sub' "$SPLIT")" -ge 2 ] || fail 'stages menu was not opened'
echo 'AOT menu structure tests passed'

# --- guided workflow still runs every stage in order ------------------------
GUIDE_LOG=$T/guide2; : > "$GUIDE_LOG"
ios_aot_configure() { echo paths >> "$GUIDE_LOG"; }
ios_aot_build() { echo "build:$1" >> "$GUIDE_LOG"; }
ios_aot_rootfs() { echo rootfs >> "$GUIDE_LOG"; }
ios_aot_prepare_guest() { echo guest >> "$GUIDE_LOG"; }
ios_aot_record() { echo record >> "$GUIDE_LOG"; }
ios_aot_link() { echo link >> "$GUIDE_LOG"; }
ios_aot_validate() { echo validate >> "$GUIDE_LOG"; }
ios_aot_setup() { echo setup >> "$GUIDE_LOG"; }
ios_aot_guided_setup || fail 'guided workflow failed'
[ "$(tail -1 "$GUIDE_LOG")" = validate ] || fail 'guided workflow skipped validation'
echo 'AOT guided workflow regression passed'

# --- paths: each setting keeps the value typed for it -----------------------
# ios_aot_configure used to loop over the *values* and save "${!p}", so all
# seven settings ended up holding the last directory typed.
#
# Everything above replaces AOT functions with logging stubs, and a dispatch
# failure of a sourced function inside `set -e` tears down the whole shell, so
# this check runs in a child that loads the utility fresh.
cat > "$T/paths-probe.sh" <<'PROBE'
set -eu
. "$REPO/src/features/117-ios-linuxkit-aot-utility.sh"
. "$REPO/src/features/111-ios-linuxkit-autoconfig-aot.sh"
T=$1
printf '%s\n' "$T/ws" "$T/ws/root" "$T/ws/rec" "$T/ws/out" "$T/ws/gad" "$T/ws/recb" "$T/ws/ev" > "$T/questions"
tui_input() {
    local line total
    line=$(sed -n '1p' "$T/questions")
    total=$(wc -l < "$T/questions")
    if [ "$total" -gt 1 ]; then sed '1d' "$T/questions" > "$T/questions.next"; mv "$T/questions.next" "$T/questions"; else : > "$T/questions"; fi
    printf '%s\n' "$line"
}
tui_yesno() { return 0; }
tui_msg() { :; }
SYSTUI_IOSKIT_AUTO_CONF="$T/auto.conf"
export SYSTUI_IOSKIT_AUTO_CONF
ios_aot_configure || exit 1
for pair in "IOSKIT_AOT_DIR=$T/ws" "IOSKIT_AOT_ROOT=$T/ws/root" \
            "IOSKIT_AOT_RECORDINGS_DIR=$T/ws/rec" "IOSKIT_AOT_OUTPUT_DIR=$T/ws/out" \
            "IOSKIT_AOT_GADGET_DIR=$T/ws/gad" "IOSKIT_AOT_RECORDER_DIR=$T/ws/recb" \
            "IOSKIT_AOT_EVIDENCE_DIR=$T/ws/ev"; do
    grep -Fx -- "$pair" "$SYSTUI_IOSKIT_AUTO_CONF" >/dev/null || { echo "not saved: $pair" >&2; exit 1; }
done
[ "$IOSKIT_AOT_OUTPUT_DIR" = "$T/ws/out" ] || { echo 'live variable not updated' >&2; exit 1; }
PROBE
REPO=$(pwd) bash "$T/paths-probe.sh" "$T" || fail 'AOT paths are not saved individually'
echo 'AOT path persistence tests passed'

# --- artifact adoption: a target that ignores its output variable -----------
# Some upstream targets write to $SRC/<target> regardless of the variable the
# pipeline passes. The build must adopt that binary instead of reporting a
# missing artifact.
SRC=$T/adopt-src; WANT=$T/adopt-want; mkdir -p "$SRC/build-arm64-native" "$WANT"
: > "$SRC/build-arm64-native/ish"; chmod +x "$SRC/build-arm64-native/ish"
ios_aot_adopt_artifact "$WANT" "$SRC/build-arm64-native" || fail 'artifact was not adopted'
[ -x "$WANT/ish" ] || fail 'adopted artifact missing'
: > "$WANT/ish"; chmod +x "$WANT/ish"
ios_aot_adopt_artifact "$WANT" "$SRC/build-arm64-native" || fail 'existing artifact rejected'
[ "$(stat -c %i "$WANT/ish")" = "$(stat -c %i "$WANT/ish")" ] || fail 'existing artifact replaced'
rm -f "$SRC/build-arm64-native/ish"
ios_aot_adopt_artifact "$T/nowhere" "$SRC/build-arm64-native" && fail 'missing build accepted'
echo 'AOT artifact adoption tests passed'
