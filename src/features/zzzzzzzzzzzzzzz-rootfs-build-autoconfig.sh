# shellcheck shell=bash
###############################################################################
# ROOTFS BUILD AUTO-CONFIGURATION
###############################################################################

ROOTFS_BASE=/opt/rootfs

rootfs_backend_auto_select() { # <distro> <arch> <release>
    local distro="$1" arch="$2" release="$3" backend _desc first=""
    while IFS='|' read -r backend _desc; do
        [ -n "$backend" ] || continue
        rootfs_backend_release_supported "$distro" "$backend" "$release" "$arch" || continue
        [ -n "$first" ] || first="$backend"
        if rootfs_backend_available "$backend"; then printf '%s\n' "$backend"; return 0; fi
    done <<< "$(rootfs_backend_catalog "$distro" "$arch" "$release" 2>/dev/null)"
    [ -n "$first" ] && { printf '%s\n' "$first"; return 0; }
    return 1
}

rootfs_target_collision_resolve() { # <distro> <release> <arch> <initial-target>
    local distro="$1" release="$2" arch="$3" target="$4" action name
    while [ -e "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; do
        action=$(tui_menu_no_tags "Rootfs already exists" "A rootfs already exists at:\n$target\n\nChoose how to continue:" overwrite "Overwrite the existing rootfs" rename "Use a different rootfs name" back "Cancel build") || return 1
        case "$action" in
            overwrite) rootfs_rm_tree "$target" || { tui_msg "Overwrite failed" "Could not remove the existing rootfs:\n$target"; return 1; }; break ;;
            rename)
                name=$(_systui_base_tui_input "Rootfs name" "Name under $ROOTFS_BASE:" "${distro}-${release}-${arch}-2") || return 1
                [ -n "$name" ] || continue
                valid_safe_name "$name" || { tui_msg "Invalid name" "Use letters, numbers, dots, underscores and hyphens only."; continue; }
                target="$ROOTFS_BASE/$name" ;;
            *) return 1 ;;
        esac
    done
    printf '%s\n' "$target"
}

# Every new rootfs gets a real init package by default. Pick the distro-native
# init rather than assuming systemd everywhere: Alpine uses OpenRC, Devuan uses
# SysV init, and the mainstream systemd distributions get systemd. This package
# is part of the bootstrap package set, so /sbin/init exists before post-config
# and before the rootfs is packed.
rootfs_default_init_packages() { # <distro>
    case "$1" in
        alpine) printf 'openrc\n' ;;
        devuan) printf 'sysvinit-core\n' ;;
        void) printf 'runit\n' ;;
        bedrock) printf 'sysvinit-core\n' ;;
        debian|ubuntu|kali|fedora|opensuse|tumbleweed|arch|archlinuxarm|archriscv) printf 'systemd\n' ;;
        gentoo) printf 'sys-apps/openrc\n' ;;
        *) printf 'systemd\n' ;;
    esac
}

if declare -F rootfs_builder_impl >/dev/null 2>&1 && ! declare -F _systui_base_rootfs_builder_impl >/dev/null 2>&1; then
    eval "$(declare -f rootfs_builder_impl | sed '1s/^rootfs_builder_impl[[:space:]]*()/_systui_base_rootfs_builder_impl ()/')"
fi

for _systui_ui_fn in tui_input tui_password tui_yesno tui_check tui_radio; do
    if declare -F "$_systui_ui_fn" >/dev/null 2>&1 && ! declare -F "_systui_base_${_systui_ui_fn}" >/dev/null 2>&1; then
        eval "$(declare -f "$_systui_ui_fn" | sed "1s/^${_systui_ui_fn}[[:space:]]*()/_systui_base_${_systui_ui_fn} ()/")"
    fi
done
unset _systui_ui_fn

tui_input() {
    if [ "${SYSTUI_ROOTFS_AUTOMATIC_BUILD:-0}" = 1 ]; then
        case "${1:-}" in
            "Rootfs Builder 7/13") printf '%s\n' "${def_mirror:-${3:-}}"; return 0 ;;
            "Rootfs Builder 8/13") rootfs_target_collision_resolve "${distro:-rootfs}" "${release:-current}" "${arch:-unknown}" "${3:-$ROOTFS_BASE/rootfs}"; return $? ;;
            "Rootfs Builder 9/13") printf '%s-iSH\n' "${distro^}"; return 0 ;;
            User) printf 'ish\n'; return 0 ;;
            Timezone) printf 'UTC\n'; return 0 ;;
        esac
    fi
    _systui_base_tui_input "$@"
}

tui_password() {
    if [ "${SYSTUI_ROOTFS_AUTOMATIC_BUILD:-0}" = 1 ]; then case "${1:-}" in Root\ password|User) printf '\n'; return 0 ;; esac; fi
    _systui_base_tui_password "$@"
}

tui_yesno() {
    if [ "${SYSTUI_ROOTFS_AUTOMATIC_BUILD:-0}" = 1 ]; then
        case "${1:-}" in "Rootfs Builder 10/13") return 0 ;; sudo) return 1 ;; esac
    fi
    _systui_base_tui_yesno "$@"
}

tui_check() {
    if [ "${SYSTUI_ROOTFS_AUTOMATIC_BUILD:-0}" = 1 ] && [ "${1:-}" = "Rootfs Builder 11/13" ]; then printf '"dns" "hosts" "tz" "mounts" "cleanup" "manifest"\n'; return 0; fi
    _systui_base_tui_check "$@"
}

tui_radio() {
    if [ "${SYSTUI_ROOTFS_AUTOMATIC_BUILD:-0}" = 1 ] && [ "${1:-}" = "Rootfs Builder 12/13" ]; then printf 'gz\n'; return 0; fi
    _systui_base_tui_radio "$@"
}

for _systui_rootfs_fn in rootfs_backend_menu rootfs_backend_config_menu rootfs_package_catalog; do
    if declare -F "$_systui_rootfs_fn" >/dev/null 2>&1 && ! declare -F "_systui_base_${_systui_rootfs_fn}" >/dev/null 2>&1; then
        eval "$(declare -f "$_systui_rootfs_fn" | sed "1s/^${_systui_rootfs_fn}[[:space:]]*()/_systui_base_${_systui_rootfs_fn} ()/")"
    fi
done
unset _systui_rootfs_fn

rootfs_backend_menu() {
    if [ "${SYSTUI_ROOTFS_AUTOMATIC_BUILD:-0}" = 1 ]; then rootfs_backend_auto_select "$1" "$2" "$3"; else _systui_base_rootfs_backend_menu "$@"; fi
}

rootfs_backend_config_menu() {
    if [ "${SYSTUI_ROOTFS_AUTOMATIC_BUILD:-0}" = 1 ]; then rootfs_backend_auto_optimize "$1" "$2"; return 0; fi
    _systui_base_rootfs_backend_config_menu "$@"
}

rootfs_package_catalog() {
    if [ "${SYSTUI_ROOTFS_AUTOMATIC_BUILD:-0}" = 1 ]; then
        local init_pkg
        init_pkg=$(rootfs_default_init_packages "${distro:-${1:-}}")
        printf '%s\n' "${2:-} git curl wget $init_pkg"
    else
        _systui_base_rootfs_package_catalog "$@"
    fi
}

rootfs_builder_impl() {
    local SYSTUI_ROOTFS_AUTOMATIC_BUILD=1
    _systui_base_rootfs_builder_impl "$@"
}

return 0 2>/dev/null || true
