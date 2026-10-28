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

# Known guest tools: category, concise display name, purpose.
systui_aok_tool_info() {
    case "$1" in
        setup-wayland.sh) printf '%s\n' 'desktop|Install Wayland Desktop|Install labwc, sway and display components' ;;
        setup-wayland-extras.sh) printf '%s\n' 'desktop|Install Desktop Extras|Install optional games, tools or X11 packages' ;;
        setup-wayfire.sh) printf '%s\n' 'desktop|Install Wayfire|Install the GPU-composited Wayfire desktop' ;;
        setup-xfce.sh) printf '%s\n' 'desktop|Install Xfce|Install the Xfce desktop on labwc' ;;
        select-desktop.sh) printf '%s\n' 'desktop|Choose Desktop|Show or change the desktop and panel' ;;
        start-wayland.sh) printf '%s\n' 'desktop|Start Display Session|Run the app Display session supervisor' ;;
        fix-neatvnc) printf '%s\n' 'desktop|Fix Desktop Resizing|Build and install an updated neatvnc' ;;
        setup-gpu.sh) printf '%s\n' 'graphics|Configure GPU Acceleration|Install or check Vulkan and OpenGL support' ;;
        setup-games.sh) printf '%s\n' 'graphics|Install Desktop Games|Install supported games and launcher setup' ;;
        aok-sdl-game) printf '%s\n' 'graphics|SDL Game Launcher|Launch games through installed game aliases' ;;
        manage-roots.sh) printf '%s\n' 'roots|Manage Root Filesystems|List, install or select root filesystems' ;;
        mount-root.sh) printf '%s\n' 'roots|Enter or Mount a Root|Mount resources or enter an installed root' ;;
        native-links.sh) printf '%s\n' 'links|Link Native Commands|Manage links to native commands and applets' ;;
        persist-links.sh) printf '%s\n' 'links|Link Persistent Commands|Manage links to persistent commands' ;;
        setup-locale.sh) printf '%s\n' 'system|Language and Locale|Configure or inspect language and locale' ;;
        suspend.sh) printf '%s\n' 'system|Save Session|Save or inspect the session; saving may stop it' ;;
        *)
            local display=${1%.sh}
            display=${display//[-_]/ }
            printf 'other|%s|Unrecognized tool; review before running\n' "$display" ;;

    esac
}
systui_aok_category_label() {
    case "$1" in
        desktop) printf '%s\n' 'Wayland and Desktop' ;;
        graphics) printf '%s\n' 'Graphics and Games' ;;
        roots) printf '%s\n' 'Root Filesystems' ;;
        links) printf '%s\n' 'Native and Persistent Commands' ;;
        system) printf '%s\n' 'System and Session' ;;
        other) printf '%s\n' 'Other Tools' ;;
    esac
}

systui_aok_category_menu() {
    local dir=$1 category=$2 path info group name description choice tag title
    local -a entries paths
    while :; do
        entries=(); paths=()
        for path in "$dir"/*; do
            systui_aok_tool_eligible "$path" || continue
            info=$(systui_aok_tool_info "${path##*/}")
            IFS='|' read -r group name description <<< "$info"
            [ "$group" = "$category" ] || continue
            tag="tool_${#paths[@]}"; paths+=("$path")
            entries+=("$tag" "$name — $description")
        done
        if [ "${#paths[@]}" -eq 0 ]; then
            tui_msg 'iSH-AOK Tools' 'No tools remain in this category.'
            return 0
        fi
        entries+=(back 'Back')
        title=$(systui_aok_category_label "$category")
        tui_capture_menu choice tui_menu_no_tags "$title" \
            'Select a tool to review its command and run it.' "${entries[@]}" || return $?
        case $choice in
            back|'') return 0 ;;
            tool_*)
                tag=${choice#tool_}
                [[ $tag =~ ^(0|[1-9][0-9]*)$ ]] || continue
                (( ${#tag} < 9 && tag < ${#paths[@]} )) || continue
                systui_aok_tool_run "${paths[tag]}" ;;
        esac
    done
}
# SYSTUI_AOK_TOOLS_DIR overrides /AOK/tools, e.g. for tests.
menu_ish_aok_tools() {
    local dir=${SYSTUI_AOK_TOOLS_DIR:-/AOK/tools} path info group name description choice category message
    local -a entries
    local -A available
    while :; do
        entries=(provision 'Ultimate Provision'); available=()
        for path in "$dir"/*; do
            systui_aok_tool_eligible "$path" || continue
            info=$(systui_aok_tool_info "${path##*/}")
            IFS='|' read -r group name description <<< "$info"
            available[$group]=1
        done
        for category in desktop graphics roots links system other; do
            [ "${available[$category]:-}" = 1 ] || continue
            entries+=("$category" "$(systui_aok_category_label "$category")")
        done
        entries+=(back 'Back')
        if [ ! -d "$dir" ] || [ ! -r "$dir" ]; then
            message="Tool directory unavailable: $dir. Ultimate Provision remains available."
        elif [ "${#available[@]}" -eq 0 ]; then
            message="No runnable tools found in $dir. Provision scripts are excluded."
        else
            message="Browse tools in $dir by category; lists refresh on each draw."
        fi
        tui_capture_menu choice tui_menu_no_tags 'iSH-AOK Tools' "$message" "${entries[@]}" || return $?
        case $choice in
            provision) if declare -F menu_ultimate_provision >/dev/null; then menu_ultimate_provision; else tui_msg 'Unavailable' 'Ultimate Provision menu is not loaded.'; fi ;;
            desktop|graphics|roots|links|system|other) systui_aok_category_menu "$dir" "$choice" ;;
            back|'') return 0 ;;
        esac
    done
}
