# shellcheck shell=bash
###############################################################################
# SYSTEM CONFIGURATION — integrate login/init into Shells > Managers
###############################################################################

# The previous late module wrapped menu_shells with a second top-level choice.
# Restore the complete original Shells menu; its existing "Managers" entry
# dispatches to menu_shell_hierarchy, which we extend below.
if declare -F _systui_base_menu_shells_initlogin >/dev/null 2>&1; then
    menu_shells() {
        _systui_base_menu_shells_initlogin "$@"
    }
fi

# Preserve the existing shell manager hierarchy, then expose account/login/init
# controls in the same Manage/Managers flow instead of beside it.
if declare -F menu_shell_hierarchy >/dev/null 2>&1 && ! declare -F _systui_base_menu_shell_hierarchy_logininit >/dev/null 2>&1; then
    eval "$(declare -f menu_shell_hierarchy | sed '1s/^menu_shell_hierarchy[[:space:]]*()/_systui_base_menu_shell_hierarchy_logininit ()/')"
fi

menu_shell_hierarchy() {
    local c
    while true; do
        detect_init 2>/dev/null || true
        c=$(tui_menu "Shell Managers" "Install/configure shells and manage login/init defaults. Current init: ${INIT:-unknown}" \
            shells "Install, remove & configure shell managers/frameworks" \
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
                else
                    tui_msg "Shell Managers" "The original shell manager hierarchy is unavailable."
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
            back|"") return 0 ;;
        esac
    done
}

export -f menu_shells menu_shell_hierarchy
