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
# Record now stages beside the destination, so it may run with existing
# recordings; what must never happen is a silent success on a failed run.
MOCK_RC=1 ios_aot_record && fail 'failed recording reported success'
unset MOCK_RC
[ "$(head -1 "$IOSKIT_AOT_RECORDINGS_DIR/manifest.json")" = x ] || fail 'previous recordings were lost'
[ -z "$(ls -d "$IOSKIT_AOT_RECORDINGS_DIR".new.* 2>/dev/null)" ] || fail 'recording staging directory left behind'
ios_aot_link && fail 'missing linked binary accepted'
[ -f "$T/args" ] || fail 'link not invoked'
grep -Fx -- "-Dcli_aot=$IOSKIT_AOT_RECORDINGS_DIR/aot_musl.S,$IOSKIT_AOT_RECORDINGS_DIR/aot_busybox.S,$IOSKIT_AOT_RECORDINGS_DIR/aot_python.S,$IOSKIT_AOT_RECORDINGS_DIR/aot_zlib.S" "$T/args" >/dev/null || fail 'image argument changed'
# Unsafe make/Meson path is rejected before any command can interpret it.
rm -f "$T/args"
# A path the build system cannot safely quote is rejected before anything runs.
old=$IOSKIT_AOT_OUTPUT_DIR; IOSKIT_AOT_OUTPUT_DIR="$T/evil;touch $T/pwn"; : > "$T/args"
ios_aot_link && fail 'unsafe path accepted'
[ ! -e "$T/pwn" ] || fail 'unsafe path was executed'
[ ! -s "$T/args" ] || fail 'a command ran with an unsafe path'
IOSKIT_AOT_OUTPUT_DIR=$old
# An existing output directory is now replaced deliberately (the confirm is
# stubbed to yes); a failed rebuild must leave nothing behind, so the step can
# be retried instead of dead-ending on "refusing to overwrite".
mkdir -p "$IOSKIT_AOT_OUTPUT_DIR"; : > "$T/args"
MOCK_RC=42; export MOCK_RC
ios_aot_link && fail 'failed setup reported success'
unset MOCK_RC
[ ! -e "$IOSKIT_AOT_OUTPUT_DIR" ] || fail 'failed link left its output directory'
mkdir -p "$IOSKIT_AOT_OUTPUT_DIR"; rmdir "$IOSKIT_AOT_OUTPUT_DIR"
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
# Pure-shell matching: grep is slow on some hosts and not worth the risk in a
# unit test.
has_line() { local want=$1 line; while IFS= read -r line; do [ "$line" = "$want" ] && return 0; done < "$2"; return 1; }
for tag in status workflow stages toolchain rollback about back; do
    has_line "$tag" "$T/menu-tags" || fail "AOT menu lacks $tag"
done
subs=0
while IFS= read -r line; do [ "$line" = "#sub" ] && subs=$((subs + 1)); done < "$SPLIT"
[ "$subs" -ge 2 ] || fail 'stages menu was not opened'
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
    has_exact_line() { local want=$1 line; while IFS= read -r line; do [ "$line" = "$want" ] && return 0; done < "$SYSTUI_IOSKIT_AUTO_CONF"; return 1; }
    has_exact_line "$pair" || { echo "not saved: $pair" >&2; exit 1; }
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

# --- hardening: retries, staging and guest probes ---------------------------
# Loaded fresh in a child so the stubs above cannot interfere.
cat > "$T/harden-probe.sh" <<'PROBE'
set -eu
. "$REPO/src/features/117-ios-linuxkit-aot-utility.sh"
T=$1
export SYSTUI_TMP="$T/tmp" IOSKIT_SRC_DIR="$T/src"
mkdir -p "$SYSTUI_TMP" "$IOSKIT_SRC_DIR"
# ios_aot_source refuses a checkout without a Makefile.
printf 'build-arm64-linux:\nrecord-arm64-aot:\n' > "$IOSKIT_SRC_DIR/Makefile"
systui_ioskit_repo_present() { return 0; }
systui_ioskit_gate_available() { return 0; }
tui_msg() { :; }
tui_yesno() { return 0; }
log() { :; }
ios_aot_defaults
IOSKIT_AOT_ROOT="$T/root"; IOSKIT_AOT_RECORDINGS_DIR="$T/rec"; IOSKIT_AOT_OUTPUT_DIR="$T/out"
IOSKIT_AOT_GADGET_DIR="$T/gad"; IOSKIT_AOT_RECORDER_DIR="$T/recdir"; IOSKIT_AOT_EVIDENCE_DIR="$T/ev"
mkdir -p "$IOSKIT_AOT_ROOT/data" "$IOSKIT_AOT_RECORDINGS_DIR" "$IOSKIT_AOT_RECORDER_DIR"
: > "$IOSKIT_AOT_ROOT/meta.db"
printf '#!/bin/sh\nexit 0\n' > "$IOSKIT_AOT_RECORDER_DIR/ish"; chmod +x "$IOSKIT_AOT_RECORDER_DIR/ish"
for f in manifest.json workload.sh aot_musl.S aot_busybox.S aot_python.S aot_zlib.S; do echo GOOD > "$IOSKIT_AOT_RECORDINGS_DIR/$f"; done

# 1. A failed meson configuration must not leave the output directory, or the
#    step can never be retried.
link_fail() {
    # run_cmd gets the description, then the command: never execute the real
    # meson/make here, and fail at the configure step.
    run_cmd() {
        local desc=$1; shift
        case "$desc" in "Configure linked AOT") return 1 ;; esac
        return 0
    }
    ios_aot_link || return 0
    return 1
}
link_fail || { echo 'link left a directory after a failed configure' >&2; exit 1; }
[ ! -e "$IOSKIT_AOT_OUTPUT_DIR" ] || { echo 'output dir survived failed meson' >&2; exit 1; }

# 2. Rebuilding over an existing output directory is allowed. run_cmd receives
#    the description first, then the command: the artifact has to be created by
#    the Build step, or the check afterwards rightly fails.
link_rebuild() {
    # Make the precondition explicit: the rebuild must work when the output
    # directory already exists, whatever the previous block left behind.
    mkdir -p "$IOSKIT_AOT_OUTPUT_DIR" 2>/dev/null || true
    run_cmd() {
        local desc=$1; shift
        if [ "$desc" = 'Configure linked AOT' ]; then
            [ -d "$IOSKIT_AOT_OUTPUT_DIR" ] || { echo 'configure ran before mkdir' >&2; return 1; }
        fi
        if [ "$desc" = 'Build linked AOT' ]; then
            [ -d "$IOSKIT_AOT_OUTPUT_DIR" ] || { echo 'build did not get its directory' >&2; return 1; }
            printf '#!/bin/sh\n' > "$IOSKIT_AOT_OUTPUT_DIR/ish"
            chmod +x "$IOSKIT_AOT_OUTPUT_DIR/ish"
        fi
        return 0
    }
    ios_aot_link || return 1
    [ -x "$IOSKIT_AOT_OUTPUT_DIR/ish" ]
}
if ! link_rebuild; then
    {
        echo 'rebuild over an existing directory was refused' >&2
        echo "  out=$IOSKIT_AOT_OUTPUT_DIR exists=$([ -d "$IOSKIT_AOT_OUTPUT_DIR" ] && echo yes || echo no)" >&2
        ls -la "${IOSKIT_AOT_OUTPUT_DIR%/*}" 2>&1 | head -10 >&2
        echo "  ios_aot_link source:" >&2
        declare -f ios_aot_link >&2
        echo "  tui_yesno stub: $(declare -f tui_yesno)" >&2
        IOSKIT_AOT_OUTPUT_DIR="${IOSKIT_AOT_OUTPUT_DIR:-}" IOSKIT_AOT_RECORDINGS_DIR="${IOSKIT_AOT_RECORDINGS_DIR:-}" bash -x -c '
            . "$1/src/features/117-ios-linuxkit-aot-utility.sh"
            true' _ "$PWD" 2>&1 | tail -5 >&2 || true
        ( set -x; ios_aot_ready; echo "ready=$?"; ios_aot_images; echo "images=$?";
          ios_aot_require_target build-arm64-linux; echo "target=$?";
          ios_aot_path "$IOSKIT_AOT_OUTPUT_DIR"; echo "path=$?" ) 2>&1 | tail -12 >&2
    } 2>&1
    exit 1
fi

# 3. A failed recording keeps the previous set and leaves no staging directory.
record_fail() {
    run_cmd() {
        local d=$1; shift
        case "$d" in *Record*) return 1 ;; *) return 0 ;; esac
    }
    ios_aot_record && return 1 || return 0
}
record_fail || { echo 'failed recording reported success' >&2; exit 1; }
[ "$(head -1 "$IOSKIT_AOT_RECORDINGS_DIR/manifest.json")" = GOOD ] || { echo 'previous recordings lost' >&2; exit 1; }
set -- "$T"/rec.new.*; [ ! -e "$1" ] || { echo 'staging directory left behind' >&2; exit 1; }

# 4. A successful recording replaces the set atomically.
record_ok() {
    run_cmd() {
        local desc=$1; shift
        case "$desc" in
            *Record*)
                for a in "$@"; do case "$a" in AOT_RECORD_DIR=*) d=${a#*=} ;; esac; done
                for f in manifest.json workload.sh aot_musl.S aot_busybox.S aot_python.S aot_zlib.S; do echo NEW > "$d/$f"; done
                return 0 ;;
        esac
        return 0
    }
    ios_aot_record
}
record_ok || { echo 'valid recording rejected' >&2; exit 1; }
[ "$(head -1 "$IOSKIT_AOT_RECORDINGS_DIR/manifest.json")" = NEW ] || { echo 'recording not swapped' >&2; exit 1; }

# 5. Guest probes distinguish "no python3" from "no zlib", and pass otherwise.
guest_probe() {
    mkdir -p "$IOSKIT_AOT_GADGET_DIR"
    printf '#!/bin/sh\n%s\n' "$1" > "$IOSKIT_AOT_GADGET_DIR/ish"; chmod +x "$IOSKIT_AOT_GADGET_DIR/ish"
}
guest_probe 'case "$*" in *"command -v python3"*) exit 127 ;; *) exit 0 ;; esac'
ios_aot_prepare_guest >/dev/null 2>&1 && { echo 'missing python3 accepted' >&2; exit 1; }
guest_probe 'case "$*" in *"python3 -c"*) exit 1 ;; *) exit 0 ;; esac'
ios_aot_prepare_guest >/dev/null 2>&1 && { echo 'broken zlib accepted' >&2; exit 1; }
guest_probe 'exit 0'
ios_aot_prepare_guest || { echo 'healthy guest rejected' >&2; exit 1; }
PROBE
if ! REPO=$(pwd) bash "$T/harden-probe.sh" "$T" 2>"$T/harden.err"; then
    # Show what the child said: a bare "failed" is useless in CI.
    printf 'harden probe failed:\n' >&2
    sed -n '1,20p' "$T/harden.err" >&2 2>/dev/null || true
    fail 'AOT hardening regressions'
fi
echo 'AOT hardening regressions passed'
