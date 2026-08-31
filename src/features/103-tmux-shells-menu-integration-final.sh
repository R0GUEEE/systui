# shellcheck shell=bash
###############################################################################
# PHASE 103 — integrate tmux into the existing Shells menu
#
# Phase 102 originally wrapped menu_shells() in a second screen containing
# "Shells, prompts and shell plugins" and "tmux manager". Restore the original
# Shells menu and place tmux inside its existing Shell Managers hierarchy.
###############################################################################

# Restore the Shells menu captured by phase 102 so System Configuration > Shells
# opens the real shell menu immediately instead of an extra wrapper menu.
if declare -F _systui_shells_before_tmux_overhaul >/dev/null 2>&1; then
    menu_shells() {
        _systui_shells_before_tmux_overhaul "$@"
    }
fi

# Preserve the final Shell Managers implementation and extend it with tmux.
if declare -F menu_shell_hierarchy >/dev/null 2>&1 \
    && ! declare -F _systui_shell_hierarchy_before_tmux_final >/dev/null 2>&1; then
    _systui_tmux_hierarchy_def=$(declare -f menu_shell_hierarchy)
    _systui_tmux_hierarchy_def=${_systui_tmux_hierarchy_def/#menu_shell_hierarchy ()/_systui_shell_hierarchy_before_tmux_final ()}
    _systui_tmux_hierarchy_def=${_systui_tmux_hierarchy_def/#menu_shell_hierarchy()/_systui_shell_hierarchy_before_tmux_final()}
    eval "$_systui_tmux_hierarchy_def"
    unset _systui_tmux_hierarchy_def
fi

menu_shell_hierarchy() {
    local c
    while true; do
        detect_init 2>/dev/null || true
        c=$(tui_menu "Shell Managers" \
            "Install/configure shells, terminal tools and login/init defaults. Current init: ${INIT:-unknown}" \
            shells "Install, remove & configure shell managers/frameworks" \
            tmux "tmux — install/update, plugins, config and sessions" \
            user "Change a user's default login shell" \
            newuser "Set default login shell for NEW users" \
            accounts "List users and their login shells" \
            shellsfile "Manage /etc/shells" \
            shprovider "Manage system /bin/sh provider" \
            initstatus "Show detected init system / PID 1" \
            initswap "Change init system (systemd/OpenRC/runit/SysVinit)" \
            services "Open service/init manager" \
            back "Back") || return 0
        case "$c" in
            shells)
                if declare -F _systui_base_menu_shell_hierarchy_logininit >/dev/null 2>&1; then
                    _systui_base_menu_shell_hierarchy_logininit
                elif declare -F _systui_shell_hierarchy_before_tmux_final >/dev/null 2>&1; then
                    # Compatibility fallback if the login/init integration alias
                    # is unavailable in a reduced build.
                    _systui_shell_hierarchy_before_tmux_final
                else
                    tui_msg "Shell Managers" "The shell manager hierarchy is unavailable."
                fi
                ;;
            tmux)
                if declare -F menu_tmux_manager >/dev/null 2>&1; then
                    menu_tmux_manager
                else
                    tui_msg "tmux" "tmux management is unavailable in this build."
                fi
                ;;
            user) sysconfig_shell_set_user ;;
            newuser) sysconfig_shell_set_new_user_default ;;
            accounts) sysconfig_shell_show_accounts ;;
            shellsfile) sysconfig_shells_file_menu ;;
            shprovider) sysconfig_sh_provider ;;
            initstatus) sysconfig_init_summary ;;
            initswap)
                if declare -F initswap_current >/dev/null 2>&1; then
                    initswap_current
                else
                    tui_msg "Init system" "Init switching is unavailable in this build."
                fi
                ;;
            services)
                if declare -F menu_services >/dev/null 2>&1; then
                    menu_services
                else
                    tui_msg "Services" "Service management is unavailable in this build."
                fi
                ;;
            back|'') return 0 ;;
        esac
    done
}

export -f menu_shells menu_shell_hierarchy 2>/dev/null || true

return 0 2>/dev/null || true
