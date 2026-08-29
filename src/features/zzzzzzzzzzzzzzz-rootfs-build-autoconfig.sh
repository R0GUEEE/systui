# shellcheck shell=bash
###############################################################################
# ROOTFS BUILD AUTO-CONFIGURATION
#
# Keep builder defaults automatic without rewriting rootfs_builder_impl.  The
# previous declare/awk/eval transform could produce a malformed function body
# and leave wizard commands at top level, causing systui to open directly into
# the target-directory prompt while features were being sourced.
###############################################################################

ROOTFS_BASE=/opt/rootfs

rootfs_backend_auto_select() { # <distro> <arch> <release>
    local distro="$1" arch="$2" release="$3" backend _desc first=""
    while IFS='|' read -r backend _desc; do
        [ -n "$backend" ] || continue
        rootfs_backend_release_supported "$distro" "$backend" "$release" "$arch" || continue
        [ -n "$first" ] || first="$backend"
        if rootfs_backend_available "$backend"; then
            printf '%s\n' "$backend"
            return 0
        fi
    done <<< "$(rootfs_backend_catalog "$distro" "$arch" "$release" 2>/dev/null)"
    [ -n "$first" ] && { printf '%s\n' "$first"; return 0; }
    return 1
}

rootfs_target_collision_resolve() { # <distro> <release> <arch> <initial-target>
    local distro="$1" release="$2" arch="$3" target="$4" action name
    while [ -e "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; do
        action=$(tui_menu_no_tags "Rootfs already exists" \
            "A rootfs already exists at:\n$target\n\nChoose how to continue:" \
            overwrite "Overwrite the existing rootfs" \
            rename "Use a different rootfs name" \
            back "Cancel build") || return 1
        case "$action" in
            overwrite)
                rootfs_rm_tree "$target" || { tui_msg "Overwrite failed" "Could not remove the existing rootfs:\n$target"; return 1; }
                break ;;
            rename)
                name=$(tui_input "Rootfs name" "Name under $ROOTFS_BASE:" "${distro}-${release}-${arch}-2") || return 1
                [ -n "$name" ] || continue
                valid_safe_name "$name" || { tui_msg "Invalid name" "Use letters, numbers, dots, underscores and hyphens only."; continue; }
                target="$ROOTFS_BASE/$name" ;;
            *) return 1 ;;
        esac
    done
    printf '%s\n' "$target"
}

# Capture the original builder once, changing only its function name.  No body
# transformation is performed, so sourcing this feature cannot expose or run
# wizard statements at top level.
if declare -F rootfs_builder_impl >/dev/null 2>&1 && ! declare -F _systui_base_rootfs_builder_impl >/dev/null 2>&1; then
    eval "$(declare -f rootfs_builder_impl | sed '1s/^rootfs_builder_impl[[:space:]]*()/_systui_base_rootfs_builder_impl ()/')"
fi

# Save the small UI helpers used by the builder so the wrapper can auto-answer
# deterministic steps only while a rootfs build is actually running.
for _systui_ui_fn in tui_input tui_password tui_yesno tui_check tui_radio; do
    if declare -F "$_systui_ui_fn" >/dev/null 2>&1 && ! declare -F "_systui_base_${_systui_ui_fn}" >/dev/null 2>&1; then
        eval "$(declare -f "$_systui_ui_fn" | sed "1s/^${_systui_ui_fn}[[:space:]]*()/_systui_base_${_systui_ui_fn} ()/")"
    fi
done
unset _systui_ui_fn

# These wrappers delegate normally unless rootfs_builder_impl set the private
# build flag. Bash dynamic scoping lets the wrappers see the builder's local
# distro/def_mirror variables without exporting or persisting them.
tui_input() {
    if [ "${SYSTUI_ROOTFS_AUTOMATIC_BUILD:-0}" = 1 ]; then
        case "${1:-}" in
            "Rootfs Builder 7/13") printf '%s\n' "${def_mirror:-${3:-}}"; return 0 ;;
            "Rootfs Builder 9/13") printf '%s-iSH\n' "${distro^}"; return 0 ;;
            User) printf 'ish\n'; return 0 ;;
            Timezone) printf 'UTC\n'; return 0 ;;
        esac
    fi
    _systui_base_tui_input "$@"
}

tui_password() {
    if [ "${SYSTUI_ROOTFS_AUTOMATIC_BUILD:-0}" = 1 ]; then
        case "${1:-}" in Root\ password|User) printf '\n'; return 0 ;; esac
    fi
    _systui_base_tui_password "$@"
}

tui_yesno() {
    if [ "${SYSTUI_ROOTFS_AUTOMATIC_BUILD:-0}" = 1 ]; then
        case "${1:-}" in
            "Rootfs Builder 10/13") return 0 ;; # always create regular user ish
            sudo) return 1 ;;                    # no sudo grant by default
        esac
    fi
    _systui_base_tui_yesno "$@"
}

tui_check() {
    if [ "${SYSTUI_ROOTFS_AUTOMATIC_BUILD:-0}" = 1 ] && [ "${1:-}" = "Rootfs Builder 11/13" ]; then
        printf '"dns" "hosts" "tz" "mounts" "cleanup" "manifest"\n'
        return 0
    fi
    _systui_base_tui_check "$@"
}

tui_radio() {
    if [ "${SYSTUI_ROOTFS_AUTOMATIC_BUILD:-0}" = 1 ] && [ "${1:-}" = "Rootfs Builder 12/13" ]; then
        printf 'gz\n'
        return 0
    fi
    _systui_base_tui_radio "$@"
}

# The backend and package catalogue are derived automatically only during the
# guided build. Save their originals for all other callers.
if declare -F rootfs_backend_menu >/dev/null 2>&1 && ! declare -F _systui_base_rootfs_backend_menu >/dev/null 2>&1; then
    eval "$(declare -f rootfs_backend_menu | sed '1s/^rootfs_backend_menu[[:space:]]*()/_systui_base_rootfs_backend_menu ()/')"
fi
if declare -F rootfs_package_catalog >/dev/null 2>&1 && ! declare -F _systui_base_rootfs_package_catalog >/dev/null 2>&1; then
    eval "$(declare -f rootfs_package_catalog | sed '1s/^rootfs_package_catalog[[:space:]]*()/_systui_base_rootfs_package_catalog ()/')"
fi

rootfs_backend_menu() {
    if [ "${SYSTUI_ROOTFS_AUTOMATIC_BUILD:-0}" = 1 ]; then
        rootfs_backend_auto_select "$1" "$2" "$3"
    else
        _systui_base_rootfs_backend_menu "$@"
    fi
}

rootfs_package_catalog() {
    if [ "${SYSTUI_ROOTFS_AUTOMATIC_BUILD:-0}" = 1 ]; then
        printf '%s\n' "${2:-} git curl wget"
    else
        _systui_base_rootfs_package_catalog "$@"
    fi
}

rootfs_builder_impl() {
    local SYSTUI_ROOTFS_AUTOMATIC_BUILD=1
    _systui_base_rootfs_builder_impl "$@"
}

return 0 2>/dev/null || true
