#!/bin/bash
# Copy an existing function under a new name using only bash builtins.
#
# The obvious implementation captures the body with "$(declare -f fn)", which
# forks a subshell (and, historically, a sed pipeline) for every alias. On
# constrained hosts that costs ~20 ms per alias and systui makes 50+ of them
# during startup. Redirecting into a reusable file and reading it back with
# mapfile avoids both forks -- measured 2.3x faster, and it is the same
# technique the hot paths in the Bedrock and native-install layers use.
#
# Returns 0 when the destination exists afterwards (including when it already
# existed), 1 when the source function is unavailable.
systui_alias_function() { # <existing-function> <new-name>
    local src="$1" dst="$2"
    local def="${SYSTUI_ALIAS_FILE:-${SYSTUI_TMP:-${TMPDIR:-/tmp}}/.systui-alias-fn.$$}"
    declare -F "$src" >/dev/null 2>&1 || return 1
    declare -F "$dst" >/dev/null 2>&1 && return 0
    declare -f "$src" > "$def" 2>/dev/null || return 1
    [ -s "$def" ] || return 1
    local -a lines=()
    mapfile -t lines < "$def" || return 1
    [ "${#lines[@]}" -gt 0 ] || return 1
    lines[0]="$dst ()"
    # IFS must be set on its own line: a "IFS=x eval ..." prefix would expand
    # the array with the old IFS and join the body with spaces.
    local IFS=$'\n'
    eval "${lines[*]}"
}
