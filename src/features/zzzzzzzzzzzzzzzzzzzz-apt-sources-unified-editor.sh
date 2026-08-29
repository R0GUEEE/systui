# shellcheck shell=bash
# Rebuild the APT repository manager around one unified editor for
# /etc/apt/sources.list and repository files in /etc/apt/sources.list.d.

_systui_apt_source_files() {
    local dir=/etc/apt/sources.list.d f

    printf '%s\n' /etc/apt/sources.list
    [ -d "$dir" ] || return 0

    while IFS= read -r f; do
        [ -n "$f" ] && printf '%s\n' "$f"
    done < <(find "$dir" -maxdepth 1 -type f \
        \( -name '*.list' -o -name '*.sources' -o -name '*.list.disabled' -o -name '*.sources.disabled' \) \
        -print 2>/dev/null | sort)
}

_systui_apt_pick_source_file() { # [title] [include-main]
    local title="${1:-Select source list}" include_main="${2:-1}"
    local -a files=() args=()
    local f tag sel i=0

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ "$include_main" != 1 ] && [ "$f" = /etc/apt/sources.list ]; then
            continue
        fi
        files+=("$f")
        tag="f$i"
        args+=("$tag" "$f")
        i=$((i + 1))
    done < <(_systui_apt_source_files)

    [ "${#files[@]}" -gt 0 ] || {
        tui_msg "APT Sources" "No source-list files were found."
        return 1
    }

    sel=$(tui_menu "$title" "Choose a source-list file:" "${args[@]}" back "Back") || return 1
    [ "$sel" != back ] && [ -n "$sel" ] || return 1
    case "$sel" in f[0-9]*) ;; *) return 1 ;; esac

    i=${sel#f}
    [ "$i" -lt "${#files[@]}" ] 2>/dev/null || return 1
    printf '%s\n' "${files[$i]}"
}

_systui_apt_edit_source_file() {
    local file backup
    file=$(_systui_apt_pick_source_file "Edit source lists" 1) || return 0

    mkdir -p /etc/apt/sources.list.d
    [ -e "$file" ] || touch "$file"
    backup="$file.bak.$(date +%s)"
    cp -a -- "$file" "$backup" 2>/dev/null || true
    safe_edit "$file" || true
}

_systui_apt_add_source_file() {
    local name type file
    mkdir -p /etc/apt/sources.list.d

    name=$(tui_input "New repository file" "File name (without extension):" "custom") || return 0
    [ -n "$name" ] || return 0
    case "$name" in
        *[!A-Za-z0-9._-]*|.*|*/*) tui_msg "Invalid name" "Use letters, numbers, dots, underscores, and dashes only."; return 0 ;;
    esac

    type=$(tui_radio "Repository format" "Choose source-list format:" \
        list    ".list — traditional deb/deb-src lines" on \
        sources ".sources — deb822 format" off) || return 0
    [ -n "$type" ] || return 0

    file="/etc/apt/sources.list.d/$name.$type"
    if [ -e "$file" ]; then
        tui_msg "Already exists" "$file already exists."
        return 0
    fi

    : > "$file"
    safe_edit "$file" || true
}

_systui_apt_disable_source_file() {
    local file
    file=$(_systui_apt_pick_source_file "Disable repository file" 0) || return 0
    case "$file" in
        *.disabled) tui_msg "Already disabled" "$file is already disabled." ;;
        *) mv -- "$file" "$file.disabled" ;;
    esac
}

_systui_apt_enable_source_file() {
    local dir=/etc/apt/sources.list.d f sel i=0
    local -a files=() args=()

    [ -d "$dir" ] || { tui_msg "APT Sources" "No disabled source-list files were found."; return 0; }
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        files+=("$f")
        args+=("f$i" "$f")
        i=$((i + 1))
    done < <(find "$dir" -maxdepth 1 -type f \
        \( -name '*.list.disabled' -o -name '*.sources.disabled' \) -print 2>/dev/null | sort)

    [ "${#files[@]}" -gt 0 ] || { tui_msg "APT Sources" "No disabled source-list files were found."; return 0; }
    sel=$(tui_menu "Enable repository file" "Choose a disabled source list:" "${args[@]}" back "Back") || return 0
    [ "$sel" != back ] && [ -n "$sel" ] || return 0
    i=${sel#f}
    f=${files[$i]}
    mv -- "$f" "${f%.disabled}"
}

_systui_apt_delete_source_file() {
    local file
    file=$(_systui_apt_pick_source_file "Delete repository file" 0) || return 0
    tui_yesno "Delete repository file" "Delete:\n$file\n\nThis cannot be undone." || return 0
    rm -f -- "$file"
}

repo_sources_listd() {
    [ "$PM" = apt ] || {
        tui_msg "N/A" "APT source-list management is only available when APT is the active package manager."
        return 0
    }

    mkdir -p /etc/apt/sources.list.d
    touch /etc/apt/sources.list

    while true; do
        local c
        c=$(tui_menu "APT Sources" \
            "Manage /etc/apt/sources.list and /etc/apt/sources.list.d from one place:" \
            edit    "Edit source lists (unified editor)" \
            add     "Create a new source-list file" \
            disable "Disable a sources.list.d repository file" \
            enable  "Enable a disabled repository file" \
            delete  "Delete a sources.list.d repository file" \
            update  "Refresh APT repository indexes" \
            back    "Back") || return 0

        case "$c" in
            edit)    _systui_apt_edit_source_file ;;
            add)     _systui_apt_add_source_file ;;
            disable) _systui_apt_disable_source_file ;;
            enable)  _systui_apt_enable_source_file ;;
            delete)  _systui_apt_delete_source_file ;;
            update)  run_cmd "apt update" apt-get update ;;
            back|"") return 0 ;;
        esac
    done
}

# Keep the original generic repository manager intact for non-APT systems.
# Only the menu dispatch is redirected to the unified APT source manager when
# APT is active.
_systui_repo_manage_unified() {
    if [ "$PM" = apt ]; then
        repo_sources_listd
    else
        repo_manage "$@"
    fi
}

# The original Repositories and keys menu exposed both "Manage sources" and a
# separate sources.list.d submenu. Collapse those into the existing Manage
# entry, remove listd, and dispatch Manage through the unified route above.
if declare -F menu_repos >/dev/null 2>&1; then
    eval "$(declare -f menu_repos | awk '
        /listd[[:space:]]+\"/ { next }
        /listd\)[[:space:]]+repo_sources_listd/ { next }
        /manage[[:space:]]+\"Manage sources/ {
            sub(/Manage sources[^\"]*/, "Manage repository sources")
        }
        /manage\)[[:space:]]+repo_manage/ {
            sub(/repo_manage/, "_systui_repo_manage_unified")
        }
        { print }
    ')"
fi
