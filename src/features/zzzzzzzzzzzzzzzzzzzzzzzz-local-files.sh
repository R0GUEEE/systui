# shellcheck shell=bash
###############################################################################
# SYSTEM CONFIGURATION > STORAGE > LOCAL FILES
# iSH/iOS host filesystem mount helpers.
###############################################################################

systui_local_files_mount() { # <icloud|iphone>
    local kind="$1" fstype mountpoint label
    case "$kind" in
        icloud)
            fstype="iOS"
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

    mkdir -p "$mountpoint" || {
        tui_msg "Local Files" "Could not create $mountpoint."
        return 1
    }

    # Avoid stacking another mount on an already-mounted target.
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

menu_local_files() {
    while true; do
        local c
        c=$(tui_menu "Local Files" "Mount iOS device folders into the system:" \
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

# Preserve the existing Storage implementation, then insert Local Files as a
# first-class option without modifying its individual storage operations.
if declare -F menu_storage >/dev/null 2>&1; then
    eval "$(declare -f menu_storage | sed \
        -e '/list    \"List block devices & mounts\"/a\            localfiles \"Local Files (iCloud and iPhone mounts)\" \\' \
        -e '/case \"\$c\" in/a\            localfiles) menu_local_files ;;')"
fi

export -f systui_local_files_mount menu_local_files menu_storage
