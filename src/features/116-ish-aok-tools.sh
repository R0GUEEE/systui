# shellcheck shell=bash
# Dynamic guest tools; never source discovered files.
systui_aok_tool_executable() {
    local mode
    [ -x "$1" ] || return 1  # Skip stat for non-executable scripts on each menu redraw.
    mode=$(stat -c %a -- "$1" 2>/dev/null) || return 1
    [[ $mode =~ ^[0-7]+$ ]] && (( (8#$mode & 0111) != 0 ))
}

systui_aok_tool_eligible() {
    local path=$1 name=${1##*/} first=
    [ ! -L "$path" ] && [ -f "$path" ] && [ -r "$path" ] || return 1
    case ${name,,} in *provision*|companion-root.sh|wayland-root.sh) return 1 ;; esac
    systui_aok_tool_executable "$path" && return 0
    IFS= read -r first < "$path" || :
    [[ $first == '#!'* ]]
}

# These are installed guest scripts, not the upstream host-side Docker builder.
# Keep the caller's cwd, terminal and privileges. The manager accepts only
# absolute archive paths and treats every other non-URL as a catalog ID.
# Permanent removal is gated explicitly here before passing upstream --yes.
systui_aok_root_usage() {
    case $1 in
        manage-roots.sh) printf '%s' 'First argument: list, available, status, cancel, install, default, rename or remove. Install takes a catalog ID, or an absolute archive path/HTTP(S) URL plus a name. default NAME; rename OLD NEW; remove NAME --yes destroys it. Options: --default, --exit-app, -q/--quiet, -h/--help. Writes require the app root-manager knob.' ;;
        mount-root.sh) printf '%s' 'Needs guest root. NAME opens a shell; all prepares every root; NAME/all -- CMD [ARG...] executes a command; --unmount NAME/all tears mounts down. Enter each token separately.' ;;
        setup-companion.sh) printf '%s' 'Needs root in the native-mode guest. No arguments sets up the default companion; optional --root NAME, repeated --user LOGIN, or --help.' ;;
        companion-run.sh) printf '%s' 'COMMAND [ARG...] runs in the configured companion. This is not a root-install or archive-build action.' ;;
    esac
}

systui_aok_roots_menu() {
    systui_aok_category_menu "${SYSTUI_AOK_TOOLS_DIR:-/AOK/tools}" roots
}

# Initialize the dynamically scoped args array; extra flags/argv may then be
# appended literally. Back cancels the entire launch. No shell parsing/eval.
systui_aok_root_preset() {
    local tool=$1 op value name prompt
    case $tool in
        manage-roots.sh)
            op=$(tui_menu_no_tags 'App root manager' 'Choose an operation (removal is destructive):' list 'List installed roots' available 'List catalog' status 'Show current job' catalog 'Install a catalog ID' archive 'Import a local archive' url 'Install from URL' default 'Choose next boot root' rename 'Rename an installed root' remove 'Remove root permanently (requires explicit confirmation)' cancel 'Cancel current installation' help 'Show upstream help' raw 'Enter custom arguments' back 'Back') || return 1
            case $op in
                list|available|status|cancel) args=("$op");;
                help) args=(--help);;
                catalog|archive|url)
                    case $op in catalog) prompt='Catalog ID (see List catalog):';; archive) prompt='Absolute archive path inside this guest:';; url) prompt='HTTP(S) archive URL:';; esac
                    value=$(tui_input 'Install app root' "$prompt" '') || return 1
                    case $op in
                        catalog) [[ $value =~ ^[A-Za-z0-9._-]+$ ]] || { tui_msg 'Invalid catalog ID' 'Use the ID shown by List catalog.'; return 1; } ;;
                        archive) [[ $value == /* && -f $value ]] || { tui_msg 'Archive unavailable' 'Enter an absolute path to a readable archive.'; return 1; } ;;
                        url) [[ $value == http://?* || $value == https://?* ]] || { tui_msg 'Invalid URL' 'Enter an HTTP(S) archive URL.'; return 1; } ;;
                    esac
                    args=(install "$value")
                    if [[ $op != catalog ]]; then name=$(tui_input 'Install app root' 'New root name:' '') && [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || { tui_msg 'Invalid root name' 'Use letters, digits, dots, underscores or hyphens.'; return 1; }; args+=("$name"); fi ;;
                default|rename|remove)
                    name=$(tui_input 'App root' 'Existing root name:' '') && [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || { tui_msg 'Invalid root name' 'Use letters, digits, dots, underscores or hyphens.'; return 1; }; args=("$op" "$name")
                    case $op in
                        rename) value=$(tui_input 'Rename root' 'New root name:' '') && [[ $value =~ ^[A-Za-z0-9._-]+$ ]] || { tui_msg 'Invalid root name' 'Use letters, digits, dots, underscores or hyphens.'; return 1; }; args+=("$value") ;;
                        remove) tui_yesno 'Confirm permanent removal' "Delete app root $name? The upstream manager requires --yes and will destroy its files." || return 1; args+=(--yes) ;;
                    esac ;;
                raw) ;; *) return 1;;
            esac ;;
        mount-root.sh)
            op=$(tui_menu_no_tags 'Mount app roots' 'Needs guest root. Select what the upstream script should do:' enter 'Enter a named root' all 'Prepare mounts for all roots' exec 'Run a command in a root (or all)' unmount 'Unmount a root (or all)' raw 'Enter custom arguments' back 'Back') || return 1
            case $op in all) args=(all);; enter|exec|unmount)
                name=$(tui_input 'App root' 'Root name:' '') && [[ $name =~ ^[A-Za-z0-9._-]+$ && $name != -* && $name != . && $name != .. ]] || { tui_msg 'Invalid root name' 'Use letters, digits, dots, underscores or hyphens.'; return 1; }
                case $op in enter) [[ $name != all ]] || return 1; args=("$name");; unmount) args=(--unmount "$name");; exec) value=$(tui_input 'Guest command' 'Command name or executable path:' '') && [[ -n $value ]] || return 1; args=("$name" -- "$value");; esac ;;
                raw) ;; *) return 1;; esac ;;
    esac
    return 0
}

systui_aok_tool_run() {
    local path=$1 arg rc=0 first='' spec interp rest item display=''
    local -a args=() command=()
    local usage
    systui_aok_tool_eligible "$path" || { tui_msg 'Tool unavailable' "No longer available: $path"; return 0; }
    usage=$(systui_aok_root_usage "${path##*/}")
    if [[ ${path##*/} == manage-roots.sh || ${path##*/} == mount-root.sh ]]; then systui_aok_root_preset "${path##*/}" || return 0; fi
    while [[ ${path##*/} != manage-roots.sh && ${path##*/} != mount-root.sh ]] && tui_yesno 'Tool arguments' "${usage:+$usage\n\n}Add one literal argument? Spaces are preserved."; do
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
        setup-native-wayland.sh) printf '%s\n' 'desktop|Install Native Wayland Desktop|Install the desktop in the Devuan companion, not the native root' ;;
        setup-companion.sh) printf '%s\n' 'roots|Set Up Native Companion|Prepare Devuan arm64 for native-mode packages' ;;
        ssh-stash.sh) printf '%s\n' 'system|SSH Account Stash|List, save or restore SSH files for a login across roots; may copy private keys' ;;
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
        companion-run.sh) printf '%s\n' 'roots|Run Companion Command|Run a command and its arguments in the configured companion' ;;
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
