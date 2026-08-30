# shellcheck shell=bash
# PHASE 98 — restore iSH/iOS Local Files mounts to the final Storage menu.
# Keep the existing final storage implementation available as a single submenu
# and expose iCloud/iPhone mounts directly from Config > Storage.

if declare -F menu_storage >/dev/null 2>&1 \
    && ! declare -F _systui_storage_before_local_files_final >/dev/null 2>&1; then
    eval "$(declare -f menu_storage | sed '1s/^menu_storage[[:space:]]*()/_systui_storage_before_local_files_final ()/')"
fi

systui_storage_mount_status() { # <mountpoint>
    local mp="$1"
    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$mp" 2>/dev/null; then
        printf ' [mounted]'
    elif grep -qs " $mp " /proc/mounts 2>/dev/null; then
        printf ' [mounted]'
    fi
}

menu_storage() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Storage" \
            "Storage, filesystems and iOS Local Files:" \
            manage "Storage management — mounts, filesystems, SMART and disks" \
            icloud "Mount iCloud at /mnt/iCloud$(systui_storage_mount_status /mnt/iCloud)" \
            iphone "Mount iPhone at /mnt/iPhone$(systui_storage_mount_status /mnt/iPhone)" \
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
