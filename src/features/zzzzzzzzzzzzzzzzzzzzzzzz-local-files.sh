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

    mkdir -p "$mountpoint" || {
        tui_msg "Local Files" "Could not create $mountpoint."
        return 1
    }

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

# Explicit Storage menu. Keep the useful mount operations and Advanced menu,
# remove the redundant/unsafe top-level entries requested by the user:
# usage, SMART, reserve, format, tmpfs, swap, label, and fstab.
menu_storage() {
    while true; do
        local c
        c=$(tui_menu "Storage" "Storage & mounts:" \
            list       "List block devices & mounts" \
            mount      "Mount a device" \
            umount     "Unmount a device/path" \
            bind       "Create a bind mount" \
            localfiles "Local Files (iCloud and iPhone mounts)" \
            advanced   "Advanced storage operations" \
            back       "Back") || return 0

        case "$c" in
            list)
                {
                    echo "=== Block devices ==="
                    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS 2>/dev/null || lsblk 2>/dev/null || true
                    echo
                    echo "=== Mounted filesystems ==="
                    df -hT 2>/dev/null || mount
                } > "${SYSTUI_TMP}/storage" 2>&1
                tui_text "Storage" "${SYSTUI_TMP}/storage"
                ;;
            mount)
                local dev dst opts
                dev=$(tui_input "Mount device" "Device or source to mount:" "/dev/") || continue
                [ -n "$dev" ] || continue
                dst=$(tui_input "Mount device" "Mount point:" "/mnt/") || continue
                [ -n "$dst" ] || continue
                opts=$(tui_input "Mount device" "Mount options (blank = defaults):" "") || continue
                mkdir -p "$dst" || { tui_msg "Mount failed" "Could not create $dst."; continue; }
                if [ -n "$opts" ]; then
                    run_cmd "Mounting $dev at $dst" mount -o "$opts" "$dev" "$dst"
                else
                    run_cmd "Mounting $dev at $dst" mount "$dev" "$dst"
                fi
                ;;
            umount)
                local target
                target=$(tui_input "Unmount" "Device or mount point to unmount:" "/mnt/") || continue
                [ -n "$target" ] || continue
                run_cmd "Unmounting $target" umount "$target"
                ;;
            bind)
                local src dst
                src=$(tui_input "Bind mount" "Source directory:" "/") || continue
                [ -d "$src" ] || { tui_msg "Bind mount" "$src is not a directory."; continue; }
                dst=$(tui_input "Bind mount" "Destination mount point:" "/mnt/") || continue
                [ -n "$dst" ] || continue
                mkdir -p "$dst" || { tui_msg "Bind mount" "Could not create $dst."; continue; }
                run_cmd "Bind mounting $src at $dst" mount --bind "$src" "$dst"
                ;;
            localfiles)
                menu_local_files
                ;;
            advanced)
                menu_storage_advanced
                ;;
            back|"") return 0 ;;
        esac
    done
}

export -f systui_local_files_mount menu_local_files menu_storage
