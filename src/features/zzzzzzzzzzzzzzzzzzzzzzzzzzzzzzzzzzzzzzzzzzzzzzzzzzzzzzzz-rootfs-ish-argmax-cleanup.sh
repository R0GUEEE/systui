# shellcheck shell=bash
###############################################################################
# iSH-AOK / constrained execve environment cleanup
###############################################################################

systui_unexport_all_functions() {
    local _decl _name _tmp
    _tmp="${SYSTUI_TMP:-/tmp}/systui-final-functions.$$"
    declare -Fx > "$_tmp" 2>/dev/null || return 0
    while IFS= read -r _decl; do
        _name=${_decl##* }
        [ -n "$_name" ] || continue
        # `export -n -f` accepts a function name as data. ShellCheck's SC2163
        # assumes the argument names a variable to export; here dynamic naming
        # is intentional and required to strip BASH_FUNC_* entries generically.
        # shellcheck disable=SC2163
        export -n -f "$_name" 2>/dev/null || true
    done < "$_tmp"
    : > "$_tmp" 2>/dev/null || true
}

systui_unexport_all_functions
export -n -f systui_unexport_all_functions 2>/dev/null || true
