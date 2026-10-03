# shellcheck shell=bash
# Central System Configuration integration for iSH-AOK / iOS LinuxKit.
# Loaded after 112-ish-aok-optimization.sh so it can extend the final menu graph.

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

systui_aok_sysconfig_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "iSH-AOK / iOS LinuxKit Configuration" \
            "Configure guest images, iSH-AOK performance features, runtime integration and AOT:" \
            optimize "Image optimizer — presets, accelerators, JIT, memory and advanced features" \
            profiles "Profile management — edit, import, export and reset" \
            images   "Guest images — download, import, export, verify and defaults" \
            runtime  "Guest runtime — shell, commands and host filesystem" \
            host     "Host integration — bind mounts, offload and netlink" \
            aot      "Native/AOT — recorder, validation and workspace" \
            paths    "iOS LinuxKit paths and automatic discovery" \
            diag     "Diagnostics and capability detection" \
            back     "Back to System Configuration" || return $?
        case "$c" in
            optimize) systui_aok_menu ;;
            profiles) systui_aok_profiles_menu ;;
            images) systui_ioskit_images_menu ;;
            runtime) systui_ioskit_run_menu ;;
            host) systui_ioskit_host_menu ;;
            aot) systui_ioskit_aot_menu ;;
            paths) systui_ioskit_settings_config_menu ;;
            diag) systui_aok_diagnostics_menu ;;
            back|'') return 0 ;;
        esac
    done
}

# Final central Config menu. This intentionally loads after phase 96.
menu_sysconfig() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "System Configuration" \
            "Detected: package manager = ${PM:-unknown}, init = ${INIT:-unknown}" \
            system       "System basics — hostname, timezone and system scan" \
            aok          "iSH-AOK / iOS LinuxKit — image optimization, advanced features and AOT" \
            packages     "Packages, catalogue, repositories and managers" \
            shells       "Shells, prompts and plugins" \
            editors      "Editors" \
            filemanagers "File managers" \
            network      "Network, SSH, DNS, proxy and time" \
            services     "Services and init systems" \
            users        "Users, sudo, passwords and SSH keys" \
            storage      "Storage, mounts, filesystems and SMART" \
            back         "Back to main menu" || return $?
        case "$c" in
            system)       tui_call_menu menu_sysconfig_basics "System basics" ;;
            aok)          tui_call_menu systui_aok_sysconfig_menu "iSH-AOK / iOS LinuxKit" ;;
            packages)     tui_call_menu menu_packages "Packages" ;;
            shells)       tui_call_menu menu_shells "Shells" ;;
            editors)      tui_call_menu menu_editors "Editors" ;;
            filemanagers) tui_call_menu menu_file_managers "File managers" ;;
            network)      tui_call_menu menu_network "Network" ;;
            services)     tui_call_menu menu_services "Services" ;;
            users)        tui_call_menu menu_users "Users" ;;
            storage)      tui_call_menu menu_storage "Storage" ;;
            back|'') return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
