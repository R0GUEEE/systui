# shellcheck shell=bash
# iOS LinuxKit manager v2: discovery, automatic configuration and AOT setup.
# Loaded after the base manager and intentionally overrides only menu functions.

systui_ioskit_auto_conf_file() {
    printf '%s\n' "${SYSTUI_IOSKIT_AUTO_CONF:-${SYSTUI_STATE_DIR:-/etc/systui}/ios-linuxkit-auto.conf}"
}

systui_ioskit_auto_get() { # key
    local f line
    f=$(systui_ioskit_auto_conf_file)
    [ -r "$f" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "$1="*) printf '%s\n' "${line#*=}"; return 0 ;; esac
    done < "$f"
    return 1
}

systui_ioskit_auto_set() { # key value
    local key="$1" val="$2" f tmp line
    case "$key" in
        IOSKIT_AOT_ROOT|IOSKIT_AOT_GADGET_DIR|IOSKIT_AOT_RECORDER_DIR|IOSKIT_AOT_EVIDENCE_DIR|IOSKIT_AOT_DIR|IOSKIT_AOT_SEED_DIR|IOSKIT_AOT_RECORDINGS_DIR|IOSKIT_AOT_OUTPUT_DIR|IOSKIT_AOT_BUN|IOSKIT_AOT_ENABLED|IOSKIT_PROFILE|IOSKIT_CC|IOSKIT_MESON|IOSKIT_NINJA|IOSKIT_REPO_URL|IOSKIT_BRANCH|IOSKIT_SRC_DIR|IOSKIT_IMAGES_DIR|IOSKIT_DOWNLOAD_DIR|IOSKIT_AUTO_DEPS|IOSKIT_SETUP_PROFILE|IOSKIT_SETUP_STEPS) ;;
        *) return 2 ;;
    esac
    case "$val" in *$'\n'*) return 2 ;; esac
    f=$(systui_ioskit_auto_conf_file); mkdir -p "${f%/*}" 2>/dev/null || true
    tmp="$f.$$"
    [ -r "$f" ] && while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "$key="*) continue ;; esac
        printf '%s\n' "$line" >> "$tmp"
    done < "$f"
    printf '%s=%s\n' "$key" "$val" >> "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$f"
}

systui_ioskit_first_dir() {
    local p
    for p in "$@"; do [ -d "$p" ] && { printf '%s\n' "$p"; return 0; }; done
    return 1
}

systui_ioskit_find_checkout() {
    local p
    [ -d "${IOSKIT_SRC_DIR:-}/.git" ] && { printf '%s\n' "$IOSKIT_SRC_DIR"; return 0; }
    for p in         "$PWD" "$HOME/ios-linuxkit" "$HOME/src/ios-linuxkit" "$HOME/Projects/ios-linuxkit"         "/opt/ios-linuxkit/src" "/opt/ios-linuxkit" "/workspace/ios-linuxkit"         "/root/ios-linuxkit" "/usr/local/src/ios-linuxkit"; do
        [ -f "$p/meson.build" ] && [ -f "$p/app/GuestARM64.xcconfig" ] && {
            printf '%s\n' "$p"; return 0;
        }
    done
    if command -v find >/dev/null 2>&1; then
        find "$HOME" /opt /workspace -maxdepth 4 -type f -name GuestARM64.xcconfig 2>/dev/null |
            while IFS= read -r p; do
                p=${p%/app/GuestARM64.xcconfig}
                [ -f "$p/meson.build" ] && { printf '%s\n' "$p"; break; }
            done
    fi
}

systui_ioskit_discover_paths() {
    local src root images downloads aot bun cc meson ninja
    src=$(systui_ioskit_find_checkout 2>/dev/null | head -n1)
    [ -n "$src" ] || src="${IOSKIT_SRC_DIR:-/opt/ios-linuxkit/src}"
    root=${src%/src}; [ "$root" = "$src" ] && root=${src%/ios-linuxkit}
    [ -n "$root" ] || root=/opt/ios-linuxkit
    images=$(systui_ioskit_first_dir "${IOSKIT_IMAGES_DIR:-}" "$root/images" "$src/images" "$HOME/ios-linuxkit-images" 2>/dev/null || true)
    [ -n "$images" ] || images="$root/images"
    downloads=$(systui_ioskit_first_dir "${IOSKIT_DOWNLOAD_DIR:-}" "$root/downloads" "$src/downloads" 2>/dev/null || true)
    [ -n "$downloads" ] || downloads="$root/downloads"
    aot=$(systui_ioskit_auto_get IOSKIT_AOT_DIR 2>/dev/null || true); [ -n "$aot" ] || aot="$root/aot"
    bun=$(command -v bun 2>/dev/null || true)
    cc=$(command -v clang 2>/dev/null || command -v cc 2>/dev/null || true)
    meson=$(command -v meson 2>/dev/null || true)
    ninja=$(command -v ninja 2>/dev/null || command -v ninja-build 2>/dev/null || true)
    printf 'SRC=%s\nIMAGES=%s\nDOWNLOADS=%s\nAOT=%s\nBUN=%s\nCC=%s\nMESON=%s\nNINJA=%s\n'         "$src" "$images" "$downloads" "$aot" "$bun" "$cc" "$meson" "$ninja"
}

systui_ioskit_discovery_text() {
    printf 'iOS LinuxKit automatic discovery\n===============================\n\n'
    systui_ioskit_discover_paths
    printf '\nHost\n  architecture=%s\n  package-manager=%s\n' "$(systui_ioskit_host_arch)" "${PM:-unknown}"
    printf '\nBuild outputs\n'
    local src d
    src=$(systui_ioskit_find_checkout 2>/dev/null | head -n1)
    [ -n "$src" ] || src="${IOSKIT_SRC_DIR:-}"
    for d in build-arm64-linux build-arm64-linux-debug build-arm64-native build-arm64-native-release; do
        [ -d "$src/$d" ] && printf '  %-32s present\n' "$src/$d"
    done
}

systui_ioskit_apply_discovery() {
    local data src images downloads aot bun cc meson ninja
    data=$(systui_ioskit_discover_paths)
    src=$(printf '%s\n' "$data" | sed -n 's/^SRC=//p')
    images=$(printf '%s\n' "$data" | sed -n 's/^IMAGES=//p')
    downloads=$(printf '%s\n' "$data" | sed -n 's/^DOWNLOADS=//p')
    aot=$(printf '%s\n' "$data" | sed -n 's/^AOT=//p')
    bun=$(printf '%s\n' "$data" | sed -n 's/^BUN=//p')
    cc=$(printf '%s\n' "$data" | sed -n 's/^CC=//p')
    meson=$(printf '%s\n' "$data" | sed -n 's/^MESON=//p')
    ninja=$(printf '%s\n' "$data" | sed -n 's/^NINJA=//p')
    systui_ioskit_conf_set IOSKIT_SRC_DIR "$src" || return 1
    systui_ioskit_conf_set IOSKIT_IMAGES_DIR "$images" || return 1
    systui_ioskit_conf_set IOSKIT_DOWNLOAD_DIR "$downloads" || return 1
    systui_ioskit_auto_set IOSKIT_AOT_DIR "$aot"
    systui_ioskit_auto_set IOSKIT_AOT_SEED_DIR "$aot/seeds"
    systui_ioskit_auto_set IOSKIT_AOT_RECORDINGS_DIR "$aot/recordings"
    systui_ioskit_auto_set IOSKIT_AOT_OUTPUT_DIR "$aot/output"
    systui_ioskit_auto_set IOSKIT_AOT_BUN "$bun"
    systui_ioskit_auto_set IOSKIT_CC "$cc"
    systui_ioskit_auto_set IOSKIT_MESON "$meson"
    systui_ioskit_auto_set IOSKIT_NINJA "$ninja"
    systui_ioskit_auto_set IOSKIT_PROFILE auto
    mkdir -p "$images" "$downloads" "$aot/seeds" "$aot/recordings" "$aot/output" 2>/dev/null || true
    systui_ioskit_cache_invalidate
}

systui_ioskit_autoconfigure() {
    systui_ioskit_show_text "Automatic discovery" systui_ioskit_discovery_text
    tui_yesno "Auto configure" "Use the detected paths and create missing working directories?\n\nExisting source and images are never deleted." || return 0
    systui_ioskit_apply_discovery || { tui_msg "Auto configure" "Could not persist the discovered configuration."; return 1; }
    tui_msg "Auto configure" "Configuration populated.\n\nSource: $IOSKIT_SRC_DIR\nImages: $IOSKIT_IMAGES_DIR\nDownloads: $IOSKIT_DOWNLOAD_DIR\nAOT: $(systui_ioskit_auto_get IOSKIT_AOT_DIR)"
}

# One guided profile for both tools.
#
# "Quick setup" asked a single yes/no and then ran package installation, a
# clone, a build and (for AOT) nothing at all: the AOT flags were scattered
# across Advanced → Source/Build/AOT. The profile records what the operator
# actually wants, is shown on both setup screens, and drives the same steps in
# the same order for each tool.
#
#   runtime  - clone/update, dependencies, release build  (ios-linuxkit)
#   aot      - runtime + AOT workspace, recorder build     (Rootfs → AOT JIT)
#   full     - runtime + aot + guest image import          (both)
#
# Values live in the shared auto config under IOSKIT_SETUP_PROFILE / _STEPS so
# a later run, and both menus, read the same intent.
systui_ioskit_profile() {
    systui_ioskit_auto_get IOSKIT_SETUP_PROFILE 2>/dev/null || printf 'runtime\n'
}

systui_ioskit_profile_steps() { # [profile]
    case "${1:-$(systui_ioskit_profile)}" in
        runtime) printf 'source deps build\n' ;;
        aot)     printf 'source deps build aot\n' ;;
        full)    printf 'source deps build aot guest\n' ;;
        *)       printf 'source deps build\n' ;;
    esac
}

systui_ioskit_profile_label() {
    case "${1:-$(systui_ioskit_profile)}" in
        runtime) printf 'Runtime only — checkout, dependencies, release build\n' ;;
        aot)     printf 'Runtime + AOT — also configures the AOT workspace and recorder\n' ;;
        full)    printf 'Full — runtime, AOT and a guest rootfs\n' ;;
        *)       printf 'Runtime only\n' ;;
    esac
}

systui_ioskit_profile_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Setup profile" \
            "Current: $(systui_ioskit_profile_label)" \
            runtime "Runtime only — checkout, dependencies, release build" \
            aot     "Runtime + AOT — adds the AOT workspace and recorder build" \
            full    "Full — adds a guest rootfs import as well" \
            back    "Back" || return $?
        case "$c" in
            runtime|aot|full)
                systui_ioskit_auto_set IOSKIT_SETUP_PROFILE "$c" || {
                    tui_msg "Setup profile" "Could not save the profile."; continue; }
                systui_ioskit_auto_set IOSKIT_SETUP_STEPS "$(systui_ioskit_profile_steps "$c")" 2>/dev/null || true
                tui_msg "Setup profile" "Saved: $(systui_ioskit_profile_label "$c")" ;;
            back|'') return 0 ;;
        esac
    done
}

# Run one guided setup under the saved profile. Every step is reported before
# it starts so a long run is never a black box, and a step that is skipped is
# named with its reason.
# shellcheck disable=SC2120
systui_ioskit_run_profile() { # [--dry-run] [profile]
    local dry=0 profile step arch
    [ "${1:-}" = --dry-run ] && { dry=1; shift; }
    profile="${1:-$(systui_ioskit_profile)}"
    arch=$(systui_ioskit_host_arch)
    tui_msg "Guided setup" "Profile: $(systui_ioskit_profile_label "$profile")

Steps: $(systui_ioskit_profile_steps "$profile")

Source: $IOSKIT_SRC_DIR
AOT workspace: $(systui_ioskit_aot_root)" || return 0
    if [ "$dry" = 1 ]; then
        printf 'Dry run — no changes.\nProfile: %s\nSteps: %s\n' \
            "$(systui_ioskit_profile_label "$profile")" "$(systui_ioskit_profile_steps "$profile")"
        return 0
    fi
    systui_ioskit_apply_discovery || return 1
    for step in $(systui_ioskit_profile_steps "$profile"); do
        case "$step" in
            source)
                if [ ! -d "$IOSKIT_SRC_DIR/.git" ]; then
                    systui_ioskit_source_clone "$IOSKIT_REPO_URL" "$IOSKIT_BRANCH" "$IOSKIT_SRC_DIR" || return 1
                elif ! systui_ioskit_source_update; then
                    # A checkout that is not a usable git repository (a copied
                    # tree, a broken .git) is a normal situation here, not a
                    # fatal one: say so and continue with the build.
                    printf 'Could not update the checkout at %s; continuing with it as it is.\n' "$IOSKIT_SRC_DIR"
                fi
                if [ -d "$IOSKIT_SRC_DIR/.git" ]; then
                    run_cmd "Initialise ios-linuxkit submodules" git -C "$IOSKIT_SRC_DIR" submodule update --init --recursive || \
                        printf 'Submodule initialisation failed; the build may report missing sources.\n'
                fi
                ;;
            deps)
                if [ "${IOSKIT_AUTO_DEPS:-1}" = 1 ]; then
                    systui_ioskit_install_dependencies || return 1
                else
                    printf 'Skipped dependencies: IOSKIT_AUTO_DEPS=0\n'
                fi
                ;;
            build)
                if [ "$arch" = aarch64 ]; then
                    systui_ioskit_run_build "$(systui_ioskit_build_target_for release)" || return 1
                else
                    printf 'Skipped the runtime build: this host is %s, the build needs AArch64.\n' "$arch"
                fi
                ;;
            aot)
                if [ "$arch" = aarch64 ]; then
                    ios_aot_defaults 2>/dev/null || true
                    ios_aot_save_paths "$IOSKIT_AOT_DIR" "$IOSKIT_AOT_ROOT" "$IOSKIT_AOT_RECORDINGS_DIR" \
                        "$IOSKIT_AOT_OUTPUT_DIR" "$IOSKIT_AOT_GADGET_DIR" "$IOSKIT_AOT_RECORDER_DIR" \
                        "$IOSKIT_AOT_EVIDENCE_DIR" || return 1
                    ios_aot_build recorder || return 1
                else
                    printf 'Skipped the AOT recorder: it needs an AArch64 Linux host (this is %s).\nThe workspace is configured and can be built elsewhere.\n' "$arch"
                fi
                ;;
            guest)
                if [ "$dry" = 1 ]; then
                    printf 'guest: would import the pinned rootfs if none is present\n'
                elif [ "$(systui_ioskit_image_count)" -gt 0 ]; then
                    printf 'Guest images already present (%s); nothing to import.\n' "$(systui_ioskit_image_count)"
                else
                    systui_ioskit_download_pinned || return 1
                fi
                ;;
        esac
    done
    systui_ioskit_cache_invalidate
    tui_msg "Guided setup" "Profile \"$profile\" finished.

Source: $IOSKIT_SRC_DIR
Images: $IOSKIT_IMAGES_DIR ($(systui_ioskit_image_count))
AOT workspace: $(systui_ioskit_aot_root)"
}

systui_ioskit_complete_setup() {
    local arch
    systui_ioskit_apply_discovery || return 1
    arch=$(systui_ioskit_host_arch)
    if [ ! -d "$IOSKIT_SRC_DIR/.git" ]; then
        systui_ioskit_source_clone "$IOSKIT_REPO_URL" "$IOSKIT_BRANCH" "$IOSKIT_SRC_DIR" || return 1
    else
        # Quick setup is idempotent: an existing checkout is refreshed before
        # rebuilding instead of silently compiling stale source.
        systui_ioskit_source_update || return 1
    fi
    run_cmd "Initialise ios-linuxkit submodules" git -C "$IOSKIT_SRC_DIR" submodule update --init --recursive || return 1
    if [ "${IOSKIT_AUTO_DEPS:-1}" = 1 ]; then
        systui_ioskit_install_dependencies || return 1
    fi
    if [ "$arch" = aarch64 ]; then
        systui_ioskit_run_build "$(systui_ioskit_build_target_for release)" || return 1
    else
        tui_msg "Complete setup" "Source and configuration are ready.\n\nLinux runtime compilation was skipped because this host is $arch; the host build requires AArch64."
    fi
    systui_ioskit_cache_invalidate
}

systui_ioskit_aot_root() {
    local v; v=$(systui_ioskit_auto_get IOSKIT_AOT_DIR 2>/dev/null || true)
    printf '%s\n' "${v:-${IOSKIT_SRC_DIR%/src}/aot}"
}
systui_ioskit_aot_bun() {
    local v; v=$(systui_ioskit_auto_get IOSKIT_AOT_BUN 2>/dev/null || true)
    [ -x "$v" ] && { printf '%s\n' "$v"; return; }
    command -v bun 2>/dev/null || true
}
systui_ioskit_aot_status_text() {
    local root bun
    root=$(systui_ioskit_aot_root); bun=$(systui_ioskit_aot_bun)
    printf 'Native / AOT setup status\n=========================\n\n'
    printf 'checkout       : %s\n' "$IOSKIT_SRC_DIR"
    printf 'host arch      : %s\n' "$(systui_ioskit_host_arch)"
    printf 'AOT workspace  : %s\n' "$root"
    printf 'Bun            : %s\n' "${bun:-missing}"
    printf 'kit            : %s\n' "$([ -f "$IOSKIT_SRC_DIR/tools/jit_aot/kit.ts" ] && printf present || printf missing)"
    printf 'native build   : %s\n' "$([ -x "$IOSKIT_SRC_DIR/build-arm64-native/ish" ] && printf present || printf absent)"
    printf 'seed dir       : %s\n' "$(systui_ioskit_auto_get IOSKIT_AOT_SEED_DIR 2>/dev/null || printf "$root/seeds")"
    printf 'recordings dir : %s\n' "$(systui_ioskit_auto_get IOSKIT_AOT_RECORDINGS_DIR 2>/dev/null || printf "$root/recordings")"
    printf 'output dir     : %s\n' "$(systui_ioskit_auto_get IOSKIT_AOT_OUTPUT_DIR 2>/dev/null || printf "$root/output")"
    printf '\nRequired source targets\n'
    for t in build-arm64-native test-aot-generator test-aot-kit test-arm64-native-emitter test-arm64-linked-aot; do
        if systui_ioskit_gate_available "$t"; then printf '  %-30s available\n' "$t"; else printf '  %-30s absent\n' "$t"; fi
    done
}

systui_ioskit_aot_setup() {
    local root bun
    systui_ioskit_apply_discovery || return 1
    root=$(systui_ioskit_aot_root)
    mkdir -p "$root/seeds" "$root/recordings" "$root/output" || return 1
    bun=$(systui_ioskit_aot_bun)
    if [ -z "$bun" ]; then
        tui_msg "AOT setup" "Bun is required by tools/jit_aot/kit.ts but was not detected.\n\nInstall Bun, then run AOT setup again."
        return 1
    fi
    systui_ioskit_auto_set IOSKIT_AOT_BUN "$bun"
    systui_ioskit_auto_set IOSKIT_AOT_ENABLED 1
    systui_ioskit_auto_set IOSKIT_AOT_DIR "$root"
    systui_ioskit_auto_set IOSKIT_AOT_SEED_DIR "$root/seeds"
    systui_ioskit_auto_set IOSKIT_AOT_RECORDINGS_DIR "$root/recordings"
    systui_ioskit_auto_set IOSKIT_AOT_OUTPUT_DIR "$root/output"
    systui_ioskit_repo_present || { tui_msg "AOT setup" "Source checkout is required first."; return 1; }
    run_cmd "Initialise AOT source dependencies" git -C "$IOSKIT_SRC_DIR" submodule update --init --recursive || return 1
    tui_msg "AOT setup" "AOT workspace configured.\n\nBun: $bun\nWorkspace: $root\n\nUse Build recorder next on an AArch64 Linux host."
}

systui_ioskit_aot_build_recorder() {
    [ "$(systui_ioskit_host_arch)" = aarch64 ] || { tui_msg "AOT recorder" "The recorder build requires an AArch64 Linux host."; return 1; }
    systui_ioskit_repo_present || { tui_msg "AOT recorder" "No source checkout."; return 1; }
    if systui_ioskit_gate_available build-arm64-native; then
        run_cmd "Build native/AOT recorder" make -C "$IOSKIT_SRC_DIR" build-arm64-native CC=clang
    else
        run_cmd "Build native/AOT recorder" env CC=clang meson setup "$IOSKIT_SRC_DIR/build-arm64-native" "$IOSKIT_SRC_DIR" -Dguest_arch=arm64 -Djit=true --buildtype=release &&
        run_cmd "Compile native/AOT recorder" ninja -C "$IOSKIT_SRC_DIR/build-arm64-native"
    fi
}

systui_ioskit_aot_verify() {
    local bun
    bun=$(systui_ioskit_aot_bun)
    [ -n "$bun" ] || { tui_msg "AOT verify" "Bun is not configured."; return 1; }
    [ -f "$IOSKIT_SRC_DIR/tools/jit_aot/kit.ts" ] || { tui_msg "AOT verify" "tools/jit_aot/kit.ts is missing from this checkout."; return 1; }
    systui_ioskit_run_single_gate test-aot-generator || return 1
    systui_ioskit_run_single_gate test-aot-kit || return 1
    systui_ioskit_gate_available test-arm64-native-emitter && systui_ioskit_run_single_gate test-arm64-native-emitter
}

systui_ioskit_aot_paths_prompt() {
    local root v
    root=$(systui_ioskit_aot_root)
    v=$(tui_input "AOT workspace" "AOT workspace directory:" "$root") || return 0
    [ -n "$v" ] || return 0
    systui_ioskit_auto_set IOSKIT_AOT_DIR "$v"
    systui_ioskit_auto_set IOSKIT_AOT_SEED_DIR "$v/seeds"
    systui_ioskit_auto_set IOSKIT_AOT_RECORDINGS_DIR "$v/recordings"
    systui_ioskit_auto_set IOSKIT_AOT_OUTPUT_DIR "$v/output"
    mkdir -p "$v/seeds" "$v/recordings" "$v/output" 2>/dev/null || true
}

systui_ioskit_aot_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Native / AOT setup"             "Workspace: $(systui_ioskit_aot_root)   Bun: $(systui_ioskit_aot_bun | xargs basename 2>/dev/null || printf missing)"             status   "Status — detected toolchain, paths and source targets"             setup    "Set up AOT — auto configure workspace, Bun and submodules"             recorder "Build recorder — native/AOT Linux build (-Djit=true)"             verify   "Verify AOT — generator, kit and emitter gates"             freeze   "Freeze/export a guest for recording"             paths    "Configure AOT workspace paths"             about    "Pipeline guide and current limitations"             back     "Back" || return $?
        case "$c" in
            status)   systui_ioskit_show_text "AOT status" systui_ioskit_aot_status_text ;;
            setup)    systui_ioskit_aot_setup ;;
            recorder) systui_ioskit_aot_build_recorder ;;
            verify)   systui_ioskit_aot_verify ;;
            freeze)   systui_ioskit_freeze_guest ;;
            paths)    systui_ioskit_aot_paths_prompt ;;
            about)    systui_ioskit_show_text "Native / AOT" systui_ioskit_aot_text ;;
            back|'')  return 0 ;;
        esac
    done
}

systui_ioskit_setup_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "iOS-linuxkit setup" \
            "Configure and install iOS-linuxkit for iSH-AOK.

Checkout: $(systui_ioskit_version)
Profile : $(systui_ioskit_profile_label)" \
            auto     "Quick setup (recommended) — run the saved profile" \
            profile  "Change the setup profile — runtime, runtime + AOT, or full" \
            detect   "Auto-detect configuration — populate paths and tools only" \
            advanced "Advanced setup — source, build, AOT and maintenance" \
            back     "Back" || return $?
        case "$c" in
            auto)     systui_ioskit_run_profile ;;
            profile)  systui_ioskit_profile_menu ;;
            detect)   systui_ioskit_autoconfigure ;;
            advanced) systui_ioskit_advanced_setup_menu ;;
            back|'')  return 0 ;;
        esac
    done
}

systui_ioskit_advanced_setup_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Advanced iOS-linuxkit setup" \
            "Manual iOS-linuxkit controls. Quick setup is recommended for normal iSH-AOK installs." \
            source "Source checkout, update and submodules" \
            build  "Dependencies and build targets" \
            aot    "Native / AOT workspace and validation" \
            maint  "Update, rebuild, prune or remove" \
            back   "Back" || return $?
        case "$c" in
            source) systui_ioskit_source_menu ;;
            build)  systui_ioskit_build_menu ;;
            aot)    systui_ioskit_aot_menu ;;
            maint)  systui_ioskit_maintenance_menu ;;
            back|'') return 0 ;;
        esac
    done
}

systui_ioskit_settings_config_menu() {
    local c v
    while true; do
        tui_capture_menu c tui_menu_no_tags "Source and directories"             "Auto profile: $(systui_ioskit_auto_get IOSKIT_PROFILE 2>/dev/null || printf manual)"             detect    "Auto-detect and populate all paths"             url       "Repository URL ($IOSKIT_REPO_URL)"             branch    "Branch ($IOSKIT_BRANCH)"             srcdir    "Source directory ($IOSKIT_SRC_DIR)"             imagesdir "Images directory ($IOSKIT_IMAGES_DIR)"             downloads "Downloads directory ($IOSKIT_DOWNLOAD_DIR)"             aot       "AOT workspace ($(systui_ioskit_aot_root))"             back      "Back" || return $?
        case "$c" in
            detect) systui_ioskit_autoconfigure ;;
            url) v=$(tui_input "Repository URL" "Git URL:" "$IOSKIT_REPO_URL") || continue; [ -n "$v" ] && systui_ioskit_conf_set IOSKIT_REPO_URL "$v" ;;
            branch) v=$(tui_input "Branch" "Branch/tag/commit:" "$IOSKIT_BRANCH") || continue; [ -n "$v" ] && systui_ioskit_conf_set IOSKIT_BRANCH "$v" ;;
            srcdir) v=$(tui_input "Source directory" "Checkout path:" "$IOSKIT_SRC_DIR") || continue; [ -n "$v" ] && systui_ioskit_conf_set IOSKIT_SRC_DIR "$v"; systui_ioskit_cache_invalidate ;;
            imagesdir) v=$(tui_input "Images directory" "Guest image path:" "$IOSKIT_IMAGES_DIR") || continue; [ -n "$v" ] && systui_ioskit_conf_set IOSKIT_IMAGES_DIR "$v"; systui_ioskit_cache_invalidate ;;
            downloads) v=$(tui_input "Downloads directory" "Archive path:" "$IOSKIT_DOWNLOAD_DIR") || continue; [ -n "$v" ] && systui_ioskit_conf_set IOSKIT_DOWNLOAD_DIR "$v" ;;
            aot) systui_ioskit_aot_paths_prompt ;;
            back|'') return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
