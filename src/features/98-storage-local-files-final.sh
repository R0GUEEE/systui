# shellcheck shell=bash
# PHASE 98 — restore iSH/iOS Local Files mounts to the final Storage menu.
# Keep the existing final storage implementation available as a single submenu
# and expose iCloud/iPhone mounts directly from Config > Storage.

if declare -F menu_storage >/dev/null 2>&1 \
    && ! declare -F _systui_storage_before_local_files_final >/dev/null 2>&1; then
    _systui_saved_fn=$(declare -f menu_storage)
    _systui_saved_fn=${_systui_saved_fn/#menu_storage /_systui_storage_before_local_files_final }
    eval "$_systui_saved_fn"
    unset _systui_saved_fn
fi

systui_storage_refresh_mount_status() {
    local _dev _mp _rest
    SYSTUI_STORAGE_ICLOUD_STATUS=""
    SYSTUI_STORAGE_IPHONE_STATUS=""
    [ -r /proc/mounts ] || return 0
    while IFS=' ' read -r _dev _mp _rest; do
        case "$_mp" in
            /mnt/iCloud) SYSTUI_STORAGE_ICLOUD_STATUS=' [mounted]' ;;
            /mnt/iPhone) SYSTUI_STORAGE_IPHONE_STATUS=' [mounted]' ;;
        esac
    done < /proc/mounts
}

menu_storage() {
    local c
    while true; do
        systui_storage_refresh_mount_status
        c=$(tui_menu_no_tags "Storage" \
            "Storage, filesystems and iOS Local Files:" \
            manage "Storage management — mounts, filesystems, SMART and disks" \
            icloud "Mount iCloud at /mnt/iCloud${SYSTUI_STORAGE_ICLOUD_STATUS}" \
            iphone "Mount iPhone at /mnt/iPhone${SYSTUI_STORAGE_IPHONE_STATUS}" \
            back "Back") || return 0
        case "$c" in
            manage)
                if declare -F _systui_storage_before_local_files_final >/dev/null 2>&1; then
                    _systui_storage_before_local_files_final
                else
                    tui_msg "Storage" "The general storage-management menu was not loaded."
                fi
                ;;
            icloud)
                if declare -F systui_local_files_mount >/dev/null 2>&1; then
                    systui_local_files_mount icloud || true
                else
                    tui_msg "iCloud" "The iOS Local Files mount helper was not loaded."
                fi
                ;;
            iphone)
                if declare -F systui_local_files_mount >/dev/null 2>&1; then
                    systui_local_files_mount iphone || true
                else
                    tui_msg "iPhone" "The iOS Local Files mount helper was not loaded."
                fi
                ;;
            back|'') return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
