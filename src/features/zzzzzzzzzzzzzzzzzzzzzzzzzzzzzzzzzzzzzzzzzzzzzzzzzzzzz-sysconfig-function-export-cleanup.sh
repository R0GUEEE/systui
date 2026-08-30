# shellcheck shell=bash
###############################################################################
# SYSTEM CONFIGURATION — function export cleanup
#
# Feature files are sourced into the main Systui Bash process. These shell/menu
# functions do not need to be inherited by subprocesses. Keeping them exported
# serializes their full definitions into every child environment and can exceed
# ARG_MAX on constrained Linux/iSH/chroot environments.
###############################################################################

_sysconfig_unexport_function() {
    declare -F "$1" >/dev/null 2>&1 || return 0
    export -n -f "$1" 2>/dev/null || true
}

for _sysconfig_fn in \
    sysconfig_shell_path_valid \
    sysconfig_shell_for_user \
    sysconfig_shell_list \
    sysconfig_shell_choose \
    sysconfig_shell_set_user \
    sysconfig_shell_set_new_user_default \
    sysconfig_shells_file_menu \
    sysconfig_shell_show_accounts \
    sysconfig_sh_provider \
    sysconfig_init_summary \
    menu_shell_init_login \
    menu_shells \
    menu_shell_hierarchy \
    sysconfig_runtime_one_line \
    sysconfig_runtime_first_word \
    sysconfig_runtime_cmd_valid \
    sysconfig_runtime_read \
    sysconfig_runtime_write \
    sysconfig_runtime_install_helpers \
    sysconfig_launch_cmd_current \
    sysconfig_boot_cmd_current \
    sysconfig_launch_cmd_set \
    sysconfig_launch_cmd_test \
    sysconfig_boot_candidates \
    sysconfig_boot_cmd_set \
    sysconfig_boot_apply_init \
    sysconfig_boot_restore_init \
    sysconfig_runtime_summary \
    menu_shell_runtime_commands
 do
    _sysconfig_unexport_function "$_sysconfig_fn"
done
unset _sysconfig_fn
