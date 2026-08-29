# shellcheck shell=bash
###############################################################################
# DISTRO MANAGER MULTI-INSTALL UI
#
# Loaded after zz-rootfs-distro-managers.sh. Adds a SPACE-to-select workflow
# for installing several distro manager tools in one pass while preserving each
# manager's existing package/upstream installation logic.
###############################################################################

rootfs_dm_install_multiple_managers() {
    local tag bin label selected
    local -a args=()

    while IFS='|' read -r tag bin label; do
        [ -n "$tag" ] || continue
        if rootfs_dm_available "$tag"; then
            args+=("$tag" "$label — installed" off)
        else
            args+=("$tag" "$label — not installed" off)
        fi
    done <<< "$(rootfs_dm_managers)"

    [ ${#args[@]} -gt 0 ] || {
        tui_msg "Distro managers" "No distro managers are available in the catalogue."
        return 0
    }

    selected=$(tui_check "Install distro managers" \
        "SPACE selects one or more manager tools; ENTER installs every selected missing manager." \
        "${args[@]}") || return 0
    selected=${selected//\"/}
    [ -n "${selected//[[:space:]]/}" ] || return 0

    for tag in $selected; do
        if rootfs_dm_available "$tag"; then
            continue
        fi
        rootfs_dm_install "$tag" || true
    done
}

# Replace the original one-manager-at-a-time front door with a menu that also
# exposes a bulk installer. Individual manager menus remain unchanged, and the
# distro/image catalogue inside supported managers keeps its own multi-select
# install workflow.
menu_rootfs_distro_managers() {
    local c tag bin label status
    while true; do
        local -a args=(
            multi-install "Install multiple managers (SPACE to select)"
        )

        while IFS='|' read -r tag bin label; do
            [ -n "$tag" ] || continue
            if rootfs_dm_available "$tag"; then
                status="installed"
            else
                status="not installed"
            fi
            args+=("$tag" "$label — $status")
        done <<< "$(rootfs_dm_managers)"

        args+=(back "Back")
        c=$(tui_menu_no_tags "Distro Managers" \
            "Select a manager, or install several manager tools with SPACE:" \
            "${args[@]}") || return 0

        case "$c" in
            multi-install) rootfs_dm_install_multiple_managers ;;
            back|"") return 0 ;;
            *) rootfs_dm_menu_one "$c" ;;
        esac
    done
}

return 0 2>/dev/null || true
