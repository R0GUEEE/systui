# shellcheck shell=bash
###############################################################################
# iSH-AOK / constrained execve environment cleanup
#
# Systui sources all feature modules into one Bash process. Exported functions
# are encoded by Bash as BASH_FUNC_* environment entries and can become very
# large. iSH-AOK has a comparatively small execve ARG_MAX, so enough exported
# function bodies can make even tiny child commands such as env, timeout, date,
# or tee fail with E2BIG / "Argument list too long".
#
# No Systui feature function needs to cross an exec boundary: child commands
# receive data through argv/files/environment explicitly. Therefore strip the
# export attribute from every currently defined function after all features
# have loaded. This uses only Bash builtins while cleaning up, so it still works
# when the current environment is already too large to exec external programs.
###############################################################################

systui_unexport_all_functions() {
    local _decl _name
    while IFS= read -r _decl; do
        # `declare -F` produces: "declare -f function_name"
        _name=${_decl##* }
        [ -n "$_name" ] || continue
        export -n -f "$_name" 2>/dev/null || true
    done < <(declare -F)
}

systui_unexport_all_functions
export -n -f systui_unexport_all_functions 2>/dev/null || true
