# shellcheck shell=bash
# AArch64 Linux AOT workflow. No iOS-app JIT entitlement is implied.

ios_aot_error() { tui_msg 'Linux AOT' "$1"; return 1; }
ios_aot_host() {
    [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ] ||
        { ios_aot_error 'AArch64 Linux is required; iOS app JIT is not provided.'; return 1; }
}
ios_aot_defaults() {
    local key val
    if [ "${IOS_AOT_CONFIG_LOADED:-0}" != 1 ] && declare -F systui_ioskit_auto_get >/dev/null; then
        for key in IOSKIT_AOT_DIR IOSKIT_AOT_ROOT IOSKIT_AOT_RECORDINGS_DIR IOSKIT_AOT_OUTPUT_DIR IOSKIT_AOT_GADGET_DIR IOSKIT_AOT_RECORDER_DIR IOSKIT_AOT_EVIDENCE_DIR; do
            val=$(systui_ioskit_auto_get "$key" 2>/dev/null) || continue
            [ -n "$val" ] && printf -v "$key" '%s' "$val"
        done
        IOS_AOT_CONFIG_LOADED=1
    fi
    : "${IOSKIT_AOT_DIR:=${HOME}/ios-linuxkit-aot}"
    : "${IOSKIT_AOT_ROOT:=$IOSKIT_AOT_DIR/training-fakefs}"
    : "${IOSKIT_AOT_RECORDINGS_DIR:=$IOSKIT_AOT_DIR/recordings}"
    : "${IOSKIT_AOT_OUTPUT_DIR:=$IOSKIT_AOT_DIR/build-aot}"
    : "${IOSKIT_AOT_GADGET_DIR:=$IOSKIT_AOT_DIR/build-gadget}"
    : "${IOSKIT_AOT_RECORDER_DIR:=$IOSKIT_AOT_DIR/build-recorder}"
    : "${IOSKIT_AOT_EVIDENCE_DIR:=$IOSKIT_AOT_DIR/evidence}"
}
ios_aot_path() {
    case "$1" in /*) ;; *) ios_aot_error 'Paths must be absolute.'; return 1;; esac
    case "$1" in *[!a-zA-Z0-9_./+-]*) ios_aot_error 'Paths may contain only letters, digits, underscore, dot, slash, plus and hyphen (upstream make/cli_aot limitation).'; return 1;; esac
    case "/$1/" in */../*|*/./*) ios_aot_error 'Dot path components are not allowed.'; return 1;; esac
}
ios_aot_new() {
    ios_aot_path "$1" || return 1
    [ ! -e "$1" ] && [ ! -L "$1" ] || { ios_aot_error "Refusing to overwrite: $1"; return 1; }
}
ios_aot_source() {
    ios_aot_host && ios_aot_path "${IOSKIT_SRC_DIR:-}" && systui_ioskit_repo_present || return 1
    [ -f "$IOSKIT_SRC_DIR/Makefile" ] || ios_aot_error 'Checkout has no Makefile.'
}
ios_aot_require_target() {
    systui_ioskit_gate_available "$1" || { ios_aot_error "Checkout does not provide make target: $1. Use a compatible source revision."; return 1; }
}
ios_aot_configure() {
    local w r rec out g n e p
    ios_aot_defaults
    w=$(tui_input 'Linux AOT' 'Workspace (absolute):' "$IOSKIT_AOT_DIR") || return 1
    ios_aot_path "$w" || return 1
    r=$(tui_input 'Linux AOT' 'Training fakefs:' "$w/training-fakefs") || return 1
    rec=$(tui_input 'Linux AOT' 'New recordings directory:' "$w/recordings") || return 1
    out=$(tui_input 'Linux AOT' 'New linked build directory:' "$w/build-aot") || return 1
    g=$(tui_input 'Linux AOT' 'New gadget build directory:' "$w/build-gadget") || return 1
    n=$(tui_input 'Linux AOT' 'New recorder build directory:' "$w/build-recorder") || return 1
    e=$(tui_input 'Linux AOT' 'New validation evidence directory:' "$w/evidence") || return 1
    for p in "$r" "$rec" "$out" "$g" "$n" "$e"; do ios_aot_path "$p" || return 1; done
    tui_yesno 'Linux AOT' 'Save these paths to the AOT configuration?' || return 1
    # One save per setting, with the value typed for that setting. The
    # previous loop iterated the *values* and looked each one up by name, so
    # every key ended up holding whichever directory was last in the list.
    ios_aot_save_paths "$w" "$r" "$rec" "$out" "$g" "$n" "$e"
}

# Persist the seven AOT paths. Takes the values as arguments and sets the live
# variables together with the stored configuration, so a failed save leaves
# nothing half-applied in memory.
ios_aot_save_paths() { # <workspace> <root> <recordings> <output> <gadget> <recorder> <evidence>
    local w="$1" r="$2" rec="$3" out="$4" g="$5" n="$6" e="$7"
    if ! declare -F systui_ioskit_auto_set >/dev/null; then
        ios_aot_error 'Configuration storage unavailable.'; return 1
    fi
    systui_ioskit_auto_set IOSKIT_AOT_DIR "$w" || { ios_aot_error 'Failed to save IOSKIT_AOT_DIR.'; return 1; }
    systui_ioskit_auto_set IOSKIT_AOT_ROOT "$r" || { ios_aot_error 'Failed to save IOSKIT_AOT_ROOT.'; return 1; }
    systui_ioskit_auto_set IOSKIT_AOT_RECORDINGS_DIR "$rec" || { ios_aot_error 'Failed to save IOSKIT_AOT_RECORDINGS_DIR.'; return 1; }
    systui_ioskit_auto_set IOSKIT_AOT_OUTPUT_DIR "$out" || { ios_aot_error 'Failed to save IOSKIT_AOT_OUTPUT_DIR.'; return 1; }
    systui_ioskit_auto_set IOSKIT_AOT_GADGET_DIR "$g" || { ios_aot_error 'Failed to save IOSKIT_AOT_GADGET_DIR.'; return 1; }
    systui_ioskit_auto_set IOSKIT_AOT_RECORDER_DIR "$n" || { ios_aot_error 'Failed to save IOSKIT_AOT_RECORDER_DIR.'; return 1; }
    systui_ioskit_auto_set IOSKIT_AOT_EVIDENCE_DIR "$e" || { ios_aot_error 'Failed to save IOSKIT_AOT_EVIDENCE_DIR.'; return 1; }
    IOSKIT_AOT_DIR=$w IOSKIT_AOT_ROOT=$r IOSKIT_AOT_RECORDINGS_DIR=$rec
    IOSKIT_AOT_OUTPUT_DIR=$out IOSKIT_AOT_GADGET_DIR=$g IOSKIT_AOT_RECORDER_DIR=$n IOSKIT_AOT_EVIDENCE_DIR=$e
    IOS_AOT_CONFIG_LOADED=1
}
# Change just the training rootfs. The guided workflow uses this instead of
# re-asking for all seven paths.
ios_aot_paths_root_only() {
    local r
    ios_aot_defaults
    r=$(tui_input 'Linux AOT' 'Training fakefs (data/ + meta.db):' "$IOSKIT_AOT_ROOT") || return 1
    ios_aot_path "$r" || return 1
    ios_aot_save_paths "$(dirname "$r")" "$r" "$IOSKIT_AOT_RECORDINGS_DIR" "$IOSKIT_AOT_OUTPUT_DIR" \
        "$IOSKIT_AOT_GADGET_DIR" "$IOSKIT_AOT_RECORDER_DIR" "$IOSKIT_AOT_EVIDENCE_DIR" || return 1
    ios_aot_ready
}

ios_aot_setup() {
    ios_aot_host || return 1
    tui_msg 'Linux AOT setup' 'Source setup is separate from dependency installation. Existing checkouts are not updated automatically. Use a source revision whose AOT targets match the documented pipeline (v2.4.1).'
    systui_ioskit_source_menu || return 1
    systui_ioskit_repo_present || return 1
    tui_yesno 'Linux AOT dependencies' 'Open dependency and build setup? Package installations can modify the host.' || return 0
    systui_ioskit_build_menu
}
ios_aot_build() {
    local dir target var
    ios_aot_defaults; ios_aot_source || return 1
    case "$1" in
      gadget) dir=$IOSKIT_AOT_GADGET_DIR; target=build-arm64-linux; var=RELEASE_BUILD_DIR;;
      recorder) dir=$IOSKIT_AOT_RECORDER_DIR; target=build-arm64-native; var=NATIVE_BUILD_DIR;;
      *) return 1;;
    esac
    ios_aot_require_target "$target" || return 1
    # Ask first: a cancelled build must not leave directories behind.
    tui_yesno 'Linux AOT' "Build $1 into $dir?

The build uses $target with $var=$dir." || return 0
    ios_aot_new "$dir" || return 1
    mkdir -p "$dir" || return 1
    run_cmd "Build $1" env CC=clang make -C "$IOSKIT_SRC_DIR" "$target" "$var=$dir" || return 1
    ios_aot_adopt_artifact "$dir" "$IOSKIT_SRC_DIR/$target" ||
        ios_aot_error "Build reported success but no ish executable was found in $dir or $IOSKIT_SRC_DIR/$target."
}

# Some upstream targets ignore their output variable and build in the checkout.
# Rather than failing a build that succeeded, move the artifact where the rest
# of the pipeline looks for it — but never replace a binary that is there.
ios_aot_adopt_artifact() { # <wanted-dir> <built-dir>
    local want="$1" built="$2"
    [ -x "$want/ish" ] && return 0
    [ -x "$built/ish" ] || return 1
    [ -e "$want/ish" ] && return 1
    mkdir -p "$want" || return 1
    cp -p "$built/ish" "$want/ish" 2>/dev/null || ln "$built/ish" "$want/ish" 2>/dev/null || return 1
    [ -x "$want/ish" ] || { chmod 0755 "$want/ish" 2>/dev/null || true; }
    [ -x "$want/ish" ]
}
ios_aot_rootfs() {
    ios_aot_defaults; ios_aot_source || return 1
    tui_yesno 'Linux AOT guest' 'Open the guest manager to import or select a fakefs? Afterwards use Configure paths to set the training fakefs path.' || return 0
    systui_ioskit_guestfs_menu || return 1
}
ios_aot_prepare_guest() {
    ios_aot_ready || return 1
    ios_aot_path "$IOSKIT_AOT_GADGET_DIR" || return 1
    [ -x "$IOSKIT_AOT_GADGET_DIR/ish" ] || { ios_aot_error 'Build the gadget executable first.'; return 1; }
    # Answering Yes used to return 0 (aborting the whole step) and No fell
    # through and failed with a bare status 1.
    # The confirmation must gate the install: answering No skips the step
    # (success), answering Yes runs it. The previous form returned 0 on No and
    # ran on Yes only to fail with a bare status 1 on any error.
    tui_yesno 'Prepare training guest' 'Run apk update and install python3 and zlib inside the selected Alpine fakefs? This changes the guest and needs working network and DNS.' || return 0
    run_cmd 'Prepare AOT training guest' "$IOSKIT_AOT_GADGET_DIR/ish" -f "$IOSKIT_AOT_ROOT" /bin/sh -ec 'apk update && apk add python3 zlib && python3 -c "import zlib"' ||
        { ios_aot_error 'Guest preparation failed. Check that the guest has a working network and DNS, then retry.'; return 1; }
    # zlib is recorded as a workload, so a missing python3 there would only
    # surface much later during recording.
    "$IOSKIT_AOT_GADGET_DIR/ish" -f "$IOSKIT_AOT_ROOT" /bin/sh -c 'python3 -c "import zlib"' >/dev/null 2>&1 ||
        { ios_aot_error 'python3 cannot import zlib inside the training guest.'; return 1; }
    return 0
}
ios_aot_ready() {
    ios_aot_defaults; ios_aot_source || return 1
    ios_aot_path "$IOSKIT_AOT_ROOT" || return 1
    [ -d "$IOSKIT_AOT_ROOT/data" ] && [ -f "$IOSKIT_AOT_ROOT/meta.db" ] || { ios_aot_error 'Training fakefs must contain data/ and meta.db. Import with fakefsify first.'; return 1; }
}
ios_aot_record() {
    ios_aot_ready || return 1
    ios_aot_path "$IOSKIT_AOT_RECORDER_DIR" || return 1
    [ -x "$IOSKIT_AOT_RECORDER_DIR/ish" ] || { ios_aot_error 'Recorder executable is missing.'; return 1; }
    ios_aot_require_target record-arm64-aot || return 1
    tui_yesno 'Linux AOT' 'Run the upstream recording target? Training executes guest workloads.' || return 0
    ios_aot_new "$IOSKIT_AOT_RECORDINGS_DIR" || return 1
    mkdir -p "$IOSKIT_AOT_RECORDINGS_DIR" || return 1
    run_cmd 'Record AOT images' env CC=clang make -C "$IOSKIT_SRC_DIR" record-arm64-aot "NATIVE_BUILD_DIR=$IOSKIT_AOT_RECORDER_DIR" "ROOTFS_DIR=$IOSKIT_AOT_ROOT" "AOT_RECORD_DIR=$IOSKIT_AOT_RECORDINGS_DIR" || return 1
    ios_aot_images || return 1
}
ios_aot_images() {
    local f
    ios_aot_path "$IOSKIT_AOT_RECORDINGS_DIR" || return 1
    for f in manifest.json workload.sh aot_musl.S aot_busybox.S aot_python.S aot_zlib.S; do
        [ -s "$IOSKIT_AOT_RECORDINGS_DIR/$f" ] || { ios_aot_error "Missing or empty recording: $f"; return 1; }
    done
}
ios_aot_link() {
    local images d
    ios_aot_ready || return 1
    ios_aot_images || return 1
    ios_aot_require_target build-arm64-linux || return 1
    d=$IOSKIT_AOT_OUTPUT_DIR
    images=$IOSKIT_AOT_RECORDINGS_DIR/aot_musl.S,$IOSKIT_AOT_RECORDINGS_DIR/aot_busybox.S,$IOSKIT_AOT_RECORDINGS_DIR/aot_python.S,$IOSKIT_AOT_RECORDINGS_DIR/aot_zlib.S
    tui_yesno 'Linux AOT' "Link images into $d with jit=true and jit_emit=false?" || return 0
    ios_aot_new "$d" || return 1
    mkdir -p "$d" || return 1
    run_cmd 'Configure linked AOT' env CC=clang meson setup "$d" "$IOSKIT_SRC_DIR" --buildtype=release -Djit=true -Djit_emit=false "-Dcli_aot=$images" || return 1
    run_cmd 'Build linked AOT' env CC=clang make -C "$IOSKIT_SRC_DIR" build-arm64-linux "RELEASE_BUILD_DIR=$d" || return 1
    [ -x "$d/ish" ] || ios_aot_error 'Linked build reported success but ish is missing.'
}
ios_aot_validate() {
    ios_aot_ready || return 1
    ios_aot_images || return 1
    ios_aot_path "$IOSKIT_AOT_OUTPUT_DIR" || return 1
    [ -x "$IOSKIT_AOT_OUTPUT_DIR/ish" ] || { ios_aot_error 'Linked executable is missing.'; return 1; }
    ios_aot_require_target test-arm64-linked-aot || return 1
    tui_yesno 'Linux AOT' "Run upstream linked-AOT validation and write evidence to
$IOSKIT_AOT_EVIDENCE_DIR?" || return 0
    mkdir -p "$IOSKIT_AOT_EVIDENCE_DIR" || return 1
    # Only count evidence written by this run: the directory may already hold
    # the previous attempt.
    _stamp="$SYSTUI_TMP/ios-aot-stamp.$$"
    : > "$_stamp" 2>/dev/null || _stamp=""
    run_cmd 'Validate linked AOT' env CC=clang "EVIDENCE_DIR=$IOSKIT_AOT_EVIDENCE_DIR" make -C "$IOSKIT_SRC_DIR" test-arm64-linked-aot "RELEASE_BUILD_DIR=$IOSKIT_AOT_OUTPUT_DIR" "ROOTFS_DIR=$IOSKIT_AOT_ROOT" "AOT_RECORD_DIR=$IOSKIT_AOT_RECORDINGS_DIR" || { rm -f "$_stamp"; return 1; }
    if [ -n "$_stamp" ]; then
        if ! find "$IOSKIT_AOT_EVIDENCE_DIR" -newer "$_stamp" -type f 2>/dev/null | head -n1 | grep -q .; then
            rm -f "$_stamp"
            ios_aot_error 'Validation reported success but wrote no new evidence. Treat this build as unvalidated.'
            return 1
        fi
        rm -f "$_stamp"
    else
        [ -n "$(ls -A "$IOSKIT_AOT_EVIDENCE_DIR" 2>/dev/null)" ] || {
            ios_aot_error 'Validation reported success but the evidence directory is empty.'
            return 1
        }
    fi
    return 0
}
ios_aot_status() {
    ios_aot_defaults
    tui_msg 'Linux AOT status' "Host: $(uname -s) $(uname -m)
Source: ${IOSKIT_SRC_DIR:-unset}
Revision: $(git -C "${IOSKIT_SRC_DIR:-/nonexistent}" rev-parse --short HEAD 2>/dev/null || printf unavailable)
Training rootfs: $([ -d "$IOSKIT_AOT_ROOT/data" ] && [ -f "$IOSKIT_AOT_ROOT/meta.db" ] && printf ready || printf missing)
Gadget built: $([ -x "$IOSKIT_AOT_GADGET_DIR/ish" ] && printf yes || printf no)
Recorder built: $([ -x "$IOSKIT_AOT_RECORDER_DIR/ish" ] && printf yes || printf no)
Recordings: $([ -s "$IOSKIT_AOT_RECORDINGS_DIR/manifest.json" ] && printf present || printf none)
Linked executable: $([ -x "$IOSKIT_AOT_OUTPUT_DIR/ish" ] && printf yes || printf no)
Evidence: $([ -d "$IOSKIT_AOT_EVIDENCE_DIR" ] && printf present || printf none)
Workspace: $IOSKIT_AOT_DIR
Root: $IOSKIT_AOT_ROOT
Gadget: $IOSKIT_AOT_GADGET_DIR
Recorder: $IOSKIT_AOT_RECORDER_DIR
Recordings: $IOSKIT_AOT_RECORDINGS_DIR
Linked: $IOSKIT_AOT_OUTPUT_DIR
Evidence: $IOSKIT_AOT_EVIDENCE_DIR

Artifacts alone do not establish validation. Linux AOT does not enable iOS-app JIT."
}
ios_aot_rollback() {
    ios_aot_ready || return 1
    ios_aot_path "$IOSKIT_AOT_GADGET_DIR" || return 1
    [ -x "$IOSKIT_AOT_GADGET_DIR/ish" ] || { ios_aot_error 'Gadget executable is missing.'; return 1; }
    tui_yesno 'Linux AOT rollback' 'Run a gadget-only guest shell? No files or builds will be deleted.' || return 1
    env ISH_JIT=0 "$IOSKIT_AOT_GADGET_DIR/ish" -f "$IOSKIT_AOT_ROOT" /bin/sh
}
ios_aot_guided_setup() {
    ios_aot_host || return 1
    tui_msg 'Guided AOT setup' 'This guided workflow builds and validates an experimental AOT executable for AArch64 Linux. It is not iOS-app JIT. It may install host/guest packages, run guest training workloads, and create new build, recording, and evidence directories. Existing data is never overwritten.'
    tui_yesno 'Guided AOT setup' 'Start at source and dependency setup? You can cancel between every stage.' || return 0
    ios_aot_setup || { ios_aot_error 'Source/dependency setup did not complete. Fix the reported issue, then resume from the matching individual step.'; return 1; }
    ios_aot_configure || return 1
    ios_aot_build gadget || { ios_aot_error 'Gadget build did not complete; remaining steps were skipped.'; return 1; }
    ios_aot_build recorder || { ios_aot_error 'Recorder build did not complete; remaining steps were skipped.'; return 1; }
    ios_aot_rootfs || return 1
    # Only the training rootfs is re-checked here: re-running the full path
    # prompt made the user type seven answers a second time for one change.
    if ! ios_aot_ready 2>/dev/null; then
        ios_aot_paths_root_only || { ios_aot_error 'No usable training rootfs was configured; recording was skipped.'; return 1; }
    fi
    ios_aot_prepare_guest || { ios_aot_error 'Guest preparation did not complete; recording was skipped.'; return 1; }
    ios_aot_record || { ios_aot_error 'Recording did not complete; linking was skipped.'; return 1; }
    ios_aot_link || { ios_aot_error 'Linking did not complete; validation was skipped.'; return 1; }
    ios_aot_validate || { ios_aot_error 'Linked validation did not pass. Do not treat this build as validated.'; return 1; }
    tui_msg 'Guided AOT setup' 'The upstream linked-AOT validation target returned success. This validates the Linux-host artifact only; it does not enable JIT in the iOS app.'
}

# The Rootfs > Ahead-of-time JIT entry point: a compact index, with the
# workflow, the build targets and the toolchain gates one level down.
menu_ios_linuxkit_aot() {
    local c
    systui_ioskit_load || return 1
    ios_aot_defaults
    while :; do
        tui_capture_menu c tui_menu_no_tags 'AArch64 Linux AOT' \
"Workspace: $IOSKIT_AOT_DIR
iOS-app JIT is not provided; this builds and validates a Linux host artifact." \
          status   'Status — host, source, artifacts and evidence' \
          workflow 'Guided workflow — setup through linked validation' \
          stages   'Run one stage — setup, paths, builds, guest, record, link, validate' \
          toolchain 'Toolchain — Bun workspace, recorder build and gate checks' \
          rollback 'Run a gadget shell (no persistent changes)' \
          about    'How the AOT pipeline works' \
          back     'Back' || return $?
        case "$c" in
          status)   ios_aot_status ;;
          workflow) ios_aot_guided_setup ;;
          stages)   ios_aot_stages_menu ;;
          toolchain) systui_ioskit_aot_menu ;;
          rollback) ios_aot_rollback ;;
          about)    systui_ioskit_show_text 'AArch64 Linux AOT' systui_ioskit_aot_text ;;
          back|'')  return 0 ;;
        esac
    done
}

# One stage at a time, in pipeline order.
ios_aot_stages_menu() {
    local c
    while :; do
        tui_capture_menu c tui_menu_no_tags 'AOT stages' \
'Each stage is independent; the guided workflow runs them in this order.' \
          setup    'Setup — checkout and build dependencies' \
          paths    'Configure paths' \
          gadget   'Build gadget — runtime used to prepare the guest' \
          recorder 'Build recorder — native build with recording enabled' \
          rootfs   'Import or select the training rootfs' \
          guest    'Install training guest packages' \
          record   'Record images' \
          link     'Link the AOT executable' \
          validate 'Validate the linked target' \
          back     'Back' || return $?
        case "$c" in
          setup)    ios_aot_setup ;;
          paths)    ios_aot_configure ;;
          gadget|recorder) ios_aot_build "$c" ;;
          rootfs)   ios_aot_rootfs ;;
          guest)    ios_aot_prepare_guest ;;
          record)   ios_aot_record ;;
          link)     ios_aot_link ;;
          validate) ios_aot_validate ;;
          back|'')  return 0 ;;
        esac
    done
}
