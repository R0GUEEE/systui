# shellcheck shell=bash
# Unified APT source editor for /etc/apt/sources.list and
# /etc/apt/sources.list.d. This file is loaded late, so menu_repos is defined
# explicitly below instead of rewriting an existing function with eval.

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

_systui_repo_manage_unified() {
    if [ "$PM" = apt ]; then
        repo_sources_listd
    else
        repo_manage "$@"
    fi
}

# Explicit late-loaded menu override. Avoid declare/awk/eval function rewriting:
# that can interfere with dialog output capture and leave System Configuration
# apparently stuck when a selection is made.
menu_repos() {
    while true; do
        local c
        c=$(tui_menu "Repositories  [manager: $PM]" "Repository management:" \
            view    "View configured repositories" \
            manage  "Manage repository sources" \
            distro  "Distro Repos (official distro repositories)" \
            popular "Add popular repositories (space-select)" \
            ppa     "Add/manage Ubuntu PPA repositories" \
            refresh "Refresh package indexes" \
            addrepo "Add a custom repository" \
            keys    "Signing keys and missing archive keyrings" \
            remove  "Delete a systui-added repository" \
            back    "Back") || return 0
        case "$c" in
            view)
                case "$PM" in
                    apt)    { grep -rHv '^\s*#' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -v '^\s*$'; } ;;
                    apk)    cat /etc/apk/repositories ;;
                    pacman) grep -A2 '^\[' /etc/pacman.conf | grep -v '^--' ;;
                    dnf)    dnf repolist --all ;;
                esac > "${SYSTUI_TMP}/repo" 2>&1
                tui_text "Repositories" "${SYSTUI_TMP}/repo" ;;
            manage)  _systui_repo_manage_unified ;;
            distro)  menu_distro_repos ;;
            popular) repo_popular ;;
            ppa)     menu_ppa_repos ;;
            refresh)
                case "$PM" in
                    apt)    run_cmd "apt-get update" apt-get update ;;
                    apk)    run_cmd "apk update" apk update ;;
                    pacman) run_cmd "pacman -Syy" pacman -Syy ;;
                    dnf)    run_cmd "dnf makecache" dnf makecache ;;
                esac ;;
            addrepo)
                case "$PM" in
                    apt)
                        local line name
                        line=$(tui_input "Add apt repo" "Full deb line, e.g.:\ndeb [signed-by=/etc/apt/keyrings/foo.gpg] https://repo.example.com stable main" "deb ") || continue
                        [ "$line" = "deb " ] && continue
                        name=$(tui_input "Add apt repo" "Short name for the .list file:" "custom") || continue
                        echo "$line" > "/etc/apt/sources.list.d/systui-$name.list"
                        tui_msg "Added" "Wrote /etc/apt/sources.list.d/systui-$name.list\nRemember to import its signing key, then refresh." ;;
                    apk)
                        local url
                        url=$(tui_input "Add apk repo" "Repository URL:" "") || continue
                        [ -z "$url" ] && continue
                        grep -qxF "$url" /etc/apk/repositories || echo "$url" >> /etc/apk/repositories
                        tui_msg "Added" "Appended to /etc/apk/repositories. Run refresh." ;;
                    pacman)
                        local name srv
                        name=$(tui_input "Add pacman repo" "Repo name (section header):" "") || continue
                        srv=$(tui_input "Add pacman repo" "Server URL (\$repo/\$arch vars allowed):" "") || continue
                        [ -z "$name" ] || [ -z "$srv" ] && continue
                        printf '\n[%s]\nServer = %s\n' "$name" "$srv" >> /etc/pacman.conf
                        tui_msg "Added" "Appended [$name] to /etc/pacman.conf.\nImport/trust its key, then refresh (-Syy)." ;;
                    dnf)
                        local url
                        url=$(tui_input "Add dnf repo" ".repo file URL or baseurl:" "") || continue
                        [ -z "$url" ] && continue
                        case "$url" in
                            *.repo) run_cmd "Adding repo file" bash -c "curl -fsSL '$url' -o /etc/yum.repos.d/systui-\$(basename '$url')" ;;
                            *)      run_cmd "dnf config-manager --add-repo" dnf config-manager --add-repo "$url" ;;
                        esac ;;
                esac ;;
            keys)
                case "$PM" in
                    apt)
                        local ka
                        ka=$(tui_menu "APT Keys" "Signing-key tools:" missing "Download distro keyrings from official repositories (SPACE-to-select)" import "Import key from URL" list "List installed keyrings" back "Back") || continue
                        case "$ka" in missing) apt_missing_keyrings_menu; continue;; list) find /etc/apt/keyrings /usr/share/keyrings -maxdepth 1 -type f 2>/dev/null | sort > "${SYSTUI_TMP}/keys"; tui_text "APT keyrings" "${SYSTUI_TMP}/keys"; continue;; back|"") continue;; esac
                        local url name
                        url=$(tui_input "apt key" "Key URL (.gpg or .asc):" "") || continue
                        [ -z "$url" ] && continue
                        name=$(tui_input "apt key" "Keyring filename (no extension):" "custom") || continue
                        mkdir -p /etc/apt/keyrings
                        run_cmd "Importing key -> /etc/apt/keyrings/$name.gpg" bash -c \
                          "curl -fsSL '$url' | gpg --dearmor --yes -o /etc/apt/keyrings/$name.gpg"
                        tui_msg "Key" "Reference it in the repo line with:\n  [signed-by=/etc/apt/keyrings/$name.gpg]" ;;
                    pacman)
                        local kid; kid=$(tui_input "pacman key" "Key ID or fingerprint:" "") || continue
                        [ -z "$kid" ] && continue
                        run_cmd "Importing pacman key $kid" bash -c \
                          "pacman-key --recv-keys '$kid' && pacman-key --lsign-key '$kid'" ;;
                    *)  tui_msg "N/A" "Key import helper covers apt and pacman.\napk uses /etc/apk/keys/; dnf imports keys per-repo (gpgkey=)." ;;
                esac ;;
            remove)
                local files f tags=()
                case "$PM" in
                    apt)  files=$(ls /etc/apt/sources.list.d/systui-*.list /etc/apt/sources.list.d/systui-*.list.disabled 2>/dev/null) ;;
                    dnf)  files=$(ls /etc/yum.repos.d/systui-*.repo 2>/dev/null) ;;
                    *)    tui_msg "Manual" "Use Manage to disable entries; deleting lines is manual\nfor $PM (single shared config file)."; continue ;;
                esac
                [ -z "$files" ] && { tui_msg "None" "No systui-added repos found."; continue; }
                for f in $files; do tags+=("$f" "$(basename "$f")" off); done
                local sel
                sel=$(tui_check "Delete repos" "SPACE selects files to DELETE, ENTER confirms:" "${tags[@]}") || continue
                sel=${sel//\"/}
                [ -z "${sel// }" ] && continue
                tui_yesno "Confirm" "Delete these repo files?\n\n$sel" || continue
                rm -f $sel
                [ "$PM" = apt ] && run_cmd "apt-get update" apt-get update ;;
            back|"") return 0 ;;
        esac
    done
}
