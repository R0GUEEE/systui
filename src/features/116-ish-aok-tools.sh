# shellcheck shell=bash
# Dynamic guest tools; never source discovered files.
systui_aok_tool_executable() {
    local mode
    mode=$(stat -c %a -- "$1" 2>/dev/null) || return 1
    [[ $mode =~ ^[0-7]+$ ]] && (( (8#$mode & 0111) != 0 )) && [ -x "$1" ]
}

systui_aok_tool_eligible() {
    local path=$1 name=${1##*/} first=
    [ ! -L "$path" ] && [ -f "$path" ] && [ -r "$path" ] || return 1
    case ${name,,} in *provision*) return 1 ;; esac
    systui_aok_tool_executable "$path" && return 0
    IFS= read -r first < "$path" || :
    [[ $first == '#!'* ]]
}

systui_aok_tool_run() {
    local path=$1 arg rc=0 first='' spec interp rest item display=''
    local -a args=() command=()
    systui_aok_tool_eligible "$path" || { tui_msg 'Tool unavailable' "No longer available: $path"; return 0; }
    while tui_yesno 'Tool arguments' 'Add one literal argument? Spaces are preserved.'; do
        arg=$(tui_input 'Tool argument' 'Enter one literal argument:' '') || return 0
        args+=("$arg")
    done
    if systui_aok_tool_executable "$path"; then
        command=("$path")
    else
        IFS= read -r first < "$path" || :
        spec=${first#\#!}
        spec=${spec#"${spec%%[!$' \t']*}"}
        interp=${spec%%[ $'\t']*}; rest=${spec#"$interp"}
        rest=${rest#"${rest%%[!$' \t']*}"}
        [ -n "$interp" ] || { tui_msg 'Invalid shebang' "Cannot run: $path"; return 0; }
        command=("$interp")
        [ -z "$rest" ] || command+=("$rest")
        command+=("$path")
    fi
    for item in "${command[@]}" "${args[@]}"; do printf -v item '%q' "$item"; display+="${display:+ }$item"; done
    tui_yesno 'Run iSH-AOK tool?' "Run interactively with your current privileges:\n\n$display" || return 0
    # Retain terminal streams instead of piping through run_cmd/tee.
    printf '\n>>> %s\n' "$display"
    "${command[@]}" "${args[@]}" || rc=$?
    printf '\nTool exited with status %s.\n' "$rc"
    if [ -t 0 ]; then read -r -p 'Press Enter to return to the menu... ' _ || :; fi
    return 0
}

# SYSTUI_AOK_TOOLS_DIR overrides /AOK/tools, e.g. for tests.
menu_ish_aok_tools() {
    local dir=${SYSTUI_AOK_TOOLS_DIR:-/AOK/tools} path choice tag message
    local -a entries paths
    while :; do
        entries=(provision 'Ultimate Provision'); paths=()
        for path in "$dir"/*; do
            systui_aok_tool_eligible "$path" || continue
            tag="tool_${#paths[@]}"; paths+=("$path")
            entries+=("$tag" "${path##*/}")
        done
        entries+=(back 'Back')
        if [ ! -d "$dir" ] || [ ! -r "$dir" ]; then
            message="Tool directory unavailable: $dir. Ultimate Provision remains available."
        elif [ "${#paths[@]}" -eq 0 ]; then
            message="No runnable tools found in $dir. Provision scripts are excluded."
        else
            message="Tools in $dir (refreshed on each draw). Select a tool to review and run."
        fi
        tui_capture_menu choice tui_menu_no_tags 'iSH-AOK Tools' \
            "$message" "${entries[@]}" || return $?
        case $choice in
            provision) if declare -F menu_ultimate_provision >/dev/null; then menu_ultimate_provision; else tui_msg 'Unavailable' 'Ultimate Provision menu is not loaded.'; fi ;;
            back|'') return 0 ;;
            tool_*)
                tag=${choice#tool_}
                [[ $tag =~ ^(0|[1-9][0-9]*)$ ]] || continue
                (( ${#tag} < 9 && tag < ${#paths[@]} )) || continue
                systui_aok_tool_run "${paths[tag]}" ;;
        esac
    done
}
