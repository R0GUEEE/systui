# shellcheck shell=bash
###############################################################################
# iSH-AOK pre-runtime ARG_MAX cleanup
#
# Some earlier features historically export large Bash function bodies. On
# iSH-AOK those BASH_FUNC_* environment entries can exhaust execve ARG_MAX
# before the final cleanup feature is reached. Strip every function export here
# using Bash builtins only, immediately before shell-runtime features that may
# invoke external utilities.
###############################################################################

_systui_pre_runtime_unexport_all() {
    local _decl _name
    while IFS= read -r _decl; do
        _name=${_decl##* }
        [ -n "$_name" ] || continue
        # shellcheck disable=SC2163
        export -n -f "$_name" 2>/dev/null || true
    done < <(declare -F)
}

_systui_pre_runtime_unexport_all
export -n -f _systui_pre_runtime_unexport_all 2>/dev/null || true
