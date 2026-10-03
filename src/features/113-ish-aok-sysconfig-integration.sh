# shellcheck shell=bash
# Rootfs integration for iSH-AOK / iOS LinuxKit.
# Loaded after 112-ish-aok-optimization.sh so iOS-linuxkit has one authoritative
# home under Rootfs and does not compete with System Configuration.

systui_aok_environment_text() {
    printf 'iSH-AOK / iOS LinuxKit environment\n=================================\n\n'
    printf 'iSH-AOK runtime : %s\n' "$([ -e /proc/ish ] && printf detected || printf not-detected)"
    printf 'host arch       : %s\n' "$(uname -m 2>/dev/null || printf unknown)"
    printf 'iOSKit source   : %s\n' "${IOSKIT_SRC_DIR:-unset}"
    printf 'image directory : %s\n' "${IOSKIT_IMAGES_DIR:-unset}"
    printf 'default image   : %s\n' "${IOSKIT_DEFAULT_IMAGE:-none}"
    printf 'images          : %s\n' "$(systui_ioskit_image_count 2>/dev/null || printf 0)"
    printf 'AOT workspace   : %s\n' "$(systui_ioskit_aot_root 2>/dev/null || printf unavailable)"
    printf 'Bun             : %s\n' "$(systui_ioskit_aot_bun 2>/dev/null || printf missing)"
    printf '\nRuntime interfaces\n'
    [ -d /proc/ish ] && find /proc/ish -maxdepth 1 -type f -o -type d 2>/dev/null | sed 's/^/  /' || printf '  /proc/ish unavailable on this host\n'
}

systui_aok_profile_reset() {
    local i="$1" f
    f=$(systui_aok_file "$i")
    [ -e "$f" ] || { tui_msg "Reset profile" "No saved profile exists for $i."; return 0; }
    tui_yesno "Reset profile" "Delete the saved SystUI iSH-AOK profile for $i?\n\nThe guest image itself will not be deleted." || return 0
    rm -f -- "$f"
    tui_msg "Reset profile" "Saved profile reset. Image files were left intact."
}

systui_aok_profile_export() {
    local i="$1" f out
    f=$(systui_aok_file "$i")
    [ -r "$f" ] || { tui_msg "Export profile" "No saved profile exists for $i."; return 1; }
    out=$(tui_input "Export profile" "Destination file:" "${HOME:-/tmp}/systui-ish-aok-$i.conf") || return 0
    [ -n "$out" ] || return 0
    mkdir -p "$(dirname "$out")" 2>/dev/null || true
    cp -- "$f" "$out" && tui_msg "Export profile" "Exported to:\n$out"
}

systui_aok_profile_import() {
    local i="$1" src line k v
    src=$(tui_input "Import profile" "Profile file to import:" "") || return 0
    [ -r "$src" ] || { tui_msg "Import profile" "File is not readable."; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; *=*) k=${line%%=*}; v=${line#*=}; systui_aok_set "$i" "$k" "$v" 2>/dev/null || true ;; esac
    done < "$src"
    tui_msg "Import profile" "Imported supported settings for $i."
}

systui_aok_profiles_menu() {
    local i c
    i=$(systui_ioskit_choose_image) || return 0
    [ -n "$i" ] || return 0
    while true; do
        tui_capture_menu c tui_menu_no_tags "iSH-AOK profile management — $i" \
            "Manage SystUI's saved per-image tuning profile:" \
            edit   "Open the full optimizer for this image" \
            export "Export profile" \
            import "Import supported profile values" \
            reset  "Reset saved profile (does not delete image)" \
            back   "Back" || return $?
        case "$c" in
            edit) systui_aok_image_menu "$i" ;;
            export) systui_aok_profile_export "$i" ;;
            import) systui_aok_profile_import "$i" ;;
            reset) systui_aok_profile_reset "$i" ;;
            back|'') return 0 ;;
        esac
    done
}

systui_aok_diagnostics_menu() {
    local c i
    while true; do
        tui_capture_menu c tui_menu_no_tags "iSH-AOK diagnostics" \
            "Inspect runtime capabilities and image-specific configuration:" \
            env    "Environment and detected runtime interfaces" \
            image  "Inspect an image profile" \
            ioskit "iOS LinuxKit diagnostics" \
            aot    "AOT/native recorder status" \
            back   "Back" || return $?
        case "$c" in
            env) systui_ioskit_show_text "iSH-AOK environment" systui_aok_environment_text ;;
            image) i=$(systui_ioskit_choose_image) || continue; [ -n "$i" ] && systui_ioskit_show_text "iSH-AOK profile" systui_aok_status "$i" ;;
            ioskit) systui_ioskit_diagnostics_menu ;;
            aot) systui_ioskit_show_text "AOT status" systui_ioskit_aot_status_text ;;
            back|'') return 0 ;;
        esac
    done
}

systui_aok_ioskit_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "iSH-AOK image tuning" \
            "Tune iOS-linuxkit guest images specifically for the iSH-AOK runtime:" \
            optimize "Image optimizer — presets, accelerators, JIT, memory and advanced features" \
            profiles "Profile management — edit, import, export and reset" \
            diag     "iSH-AOK diagnostics and capability detection" \
            back     "Back to iOS-linuxkit" || return $?
        case "$c" in
            optimize) systui_aok_menu ;;
            profiles) systui_aok_profiles_menu ;;
            diag) systui_aok_diagnostics_menu ;;
            back|'') return 0 ;;
        esac
    done
}

# Rootfs is the single authoritative location for iOS-linuxkit.  This late
# definition intentionally follows the rootfs download/workbench integrations
# so it extends the final Rootfs menu instead of creating another competing
# System Configuration override.
menu_rootfs() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Rootfs" \
            "Build, download, repair and run Linux root filesystems:" \
            ioskit    "iOS-linuxkit for iSH-AOK — install, images, runtime, AOT and tuning" \
            build     "Build a new rootfs (guided)" \
            download  "Download a prebuilt rootfs (always tar.gz)" \
            workbench "Chroot workbench (manage rootfs)" \
            bootstrap "Bootstrap tools" \
            distros   "Distro managers" \
            back      "Back" || return $?
        case "$c" in
            ioskit)    tui_call_menu menu_ios_linuxkit "iOS-linuxkit for iSH-AOK" ;;
            build)     rootfs_builder || true ;;
            download)  rootfs_download || true ;;
            workbench) menu_rootfs_workbench || true ;;
            bootstrap) menu_rootfs_bootstrap_tools || true ;;
            distros)   menu_rootfs_distro_managers || true ;;
            back|'') return 0 ;;
        esac
    done
}

# Extend the iOS-linuxkit front door with iSH-AOK-specific image tuning while
# keeping setup, diagnostics, guest filesystem, validation and settings in the
# same Rootfs-owned feature tree.
if declare -F menu_ios_linuxkit >/dev/null 2>&1 \
    && ! declare -F _systui_ioskit_base_menu >/dev/null 2>&1; then
    systui_alias_function menu_ios_linuxkit _systui_ioskit_base_menu
fi

menu_ios_linuxkit() {
    local c
    systui_ioskit_load
    systui_ioskit_cache_warm
    while true; do
        tui_capture_menu c tui_menu_no_tags "iOS-linuxkit for iSH-AOK" \
            "Install, configure and operate iOS-linuxkit guest root filesystems.\n\n$(systui_ioskit_state_summary)\n\n$(systui_ioskit_recommendation)" \
            setup    "Install / setup — guided quick setup or advanced controls" \
            guestfs  "Guest root filesystems — import, export, run and host access" \
            optimize "iSH-AOK image tuning — performance profiles and runtime features" \
            status   "Status and diagnostics — host, source, tools and limits" \
            verify   "Validate and release — gates, versions and AOT" \
            settings "Settings — paths, branch, pin and session switches" \
            about    "About iOS LinuxKit" \
            back     "Back to Rootfs" || return $?
        case "$c" in
            setup)    systui_ioskit_setup_menu; systui_ioskit_cache_warm ;;
            guestfs)  systui_ioskit_guestfs_menu; systui_ioskit_cache_warm ;;
            optimize) systui_aok_ioskit_menu ;;
            status)   systui_ioskit_status_menu ;;
            verify)   systui_ioskit_verify_menu ;;
            settings) systui_ioskit_settings_menu ;;
            about)    systui_ioskit_about ;;
            back|'')  return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
