# shellcheck shell=bash
###############################################################################
# SYSTEM CONFIGURATION > STORAGE > LOCAL FILES
# iSH/iOS host filesystem mount helpers.
###############################################################################

systui_local_files_mount() { # <icloud|iphone>
    local kind="$1" fstype mountpoint label
    case "$kind" in
        icloud)
            fstype="ios"
            mountpoint="/mnt/iCloud"
            label="iCloud"
            ;;
        iphone)
            fstype="ios-unsafe"
            mountpoint="/mnt/iPhone"
            label="iPhone"
            ;;
        *) return 1 ;;
    esac

    if ! mkdir -p "$mountpoint"; then
        tui_msg "Local Files" "Could not create $mountpoint."
        return 1
    fi

    if mountpoint -q "$mountpoint" 2>/dev/null || grep -qs " $mountpoint " /proc/mounts 2>/dev/null; then
        tui_msg "Local Files" "$label is already mounted at:\n$mountpoint"
        return 0
    fi

    if run_cmd "Mounting $label at $mountpoint" mount -t "$fstype" . "$mountpoint"; then
        tui_msg "Local Files" "$label mounted at:\n$mountpoint"
        return 0
    fi

    tui_msg "Local Files" "Could not mount $label at:\n$mountpoint\n\nCommand:\nmount -t $fstype . $mountpoint"
    return 1
}

# Storage exposes the two iOS Local Files mounts directly. Generic storage
# operations intentionally remain omitted from this menu.
menu_storage() {
    while true; do
        local c
        c=$(tui_menu "Storage" "Storage configuration:" \
            icloud "Mount iCloud at /mnt/iCloud" \
            iphone "Mount iPhone at /mnt/iPhone" \
            back   "Back") || return 0
        case "$c" in
            icloud) systui_local_files_mount icloud || true ;;
            iphone) systui_local_files_mount iphone || true ;;
            back|"") return 0 ;;
        esac
    done
}

export -f systui_local_files_mount menu_storage
