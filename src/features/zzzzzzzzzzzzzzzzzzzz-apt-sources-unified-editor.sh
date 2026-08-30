# shellcheck shell=bash
# Unified APT source editor for /etc/apt/sources.list and sources.list.d.

_systui_apt_source_files() {
    local dir=/etc/apt/sources.list.d f
    printf '%s\n' /etc/apt/sources.list
    [ -d "$dir" ] || return 0
    while IFS= read -r f; do [ -n "$f" ] && printf '%s\n' "$f"; done < <(
        find "$dir" -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' -o -name '*.list.disabled' -o -name '*.sources.disabled' \) -print 2>/dev/null | sort
    )
}

_systui_apt_pick_source_file() {
    local title="${1:-Select source list}" include_main="${2:-1}" f tag sel i=0
    local -a files=() args=()
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ "$include_main" = 1 ] || [ "$f" != /etc/apt/sources.list ] || continue
        files+=("$f"); tag="f$i"; args+=("$tag" "$f"); i=$((i + 1))
    done < <(_systui_apt_source_files)
    [ "${#files[@]}" -gt 0 ] || { tui_msg "APT Sources" "No source-list files were found."; return 1; }
    sel=$(tui_menu "$title" "Choose a source-list file:" "${args[@]}" back "Back") || return 1
    case "$sel" in f[0-9]*) ;; *) return 1;; esac
    i=${sel#f}; [ "$i" -lt "${#files[@]}" ] 2>/dev/null || return 1
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
    case "$name" in ''|*[!A-Za-z0-9._-]*|.*|*/*) tui_msg "Invalid name" "Use letters, numbers, dots, underscores, and dashes only."; return 0;; esac
    type=$(tui_radio "Repository format" "Choose source-list format:" list ".list — traditional deb/deb-src lines" on sources ".sources — deb822 format" off) || return 0
    case "$type" in list|sources) ;; *) return 0;; esac
    file="/etc/apt/sources.list.d/$name.$type"
    [ ! -e "$file" ] || { tui_msg "Already exists" "$file already exists."; return 0; }
    : > "$file"; safe_edit "$file" || true
}

_systui_apt_disable_source_file() {
    local file
    file=$(_systui_apt_pick_source_file "Disable repository file" 0) || return 0
    case "$file" in *.disabled) tui_msg "Already disabled" "$file is already disabled." ;; *) mv -- "$file" "$file.disabled" ;; esac
}

_systui_apt_enable_source_file() {
    local dir=/etc/apt/sources.list.d f sel i=0
    local -a files=() args=()
    [ -d "$dir" ] || { tui_msg "APT Sources" "No disabled source-list files were found."; return 0; }
    while IFS= read -r f; do [ -n "$f" ] || continue; files+=("$f"); args+=("f$i" "$f"); i=$((i + 1)); done < <(
        find "$dir" -maxdepth 1 -type f \( -name '*.list.disabled' -o -name '*.sources.disabled' \) -print 2>/dev/null | sort
    )
    [ "${#files[@]}" -gt 0 ] || { tui_msg "APT Sources" "No disabled source-list files were found."; return 0; }
    sel=$(tui_menu "Enable repository file" "Choose a disabled source list:" "${args[@]}" back "Back") || return 0
    case "$sel" in f[0-9]*) ;; *) return 0;; esac
    i=${sel#f}; [ "$i" -lt "${#files[@]}" ] 2>/dev/null || return 0
    f=${files[$i]}; mv -- "$f" "${f%.disabled}"
}

_systui_apt_delete_source_file() {
    local file
    file=$(_systui_apt_pick_source_file "Delete repository file" 0) || return 0
    tui_yesno "Delete repository file" "Delete:\n$file\n\nThis cannot be undone." || return 0
    rm -f -- "$file"
}

repo_sources_listd() {
    [ "$PM" = apt ] || { tui_msg "N/A" "APT source-list management is only available when APT is active."; return 0; }
    mkdir -p /etc/apt/sources.list.d; touch /etc/apt/sources.list
    local c
    while true; do
        c=$(tui_menu "APT Sources" "Manage /etc/apt/sources.list and /etc/apt/sources.list.d:" edit "Edit source lists" add "Create a source-list file" disable "Disable a repository file" enable "Enable a disabled repository" delete "Delete a repository file" update "Refresh APT indexes" back "Back") || return 0
        case "$c" in
            edit) _systui_apt_edit_source_file ;;
            add) _systui_apt_add_source_file ;;
            disable) _systui_apt_disable_source_file ;;
            enable) _systui_apt_enable_source_file ;;
            delete) _systui_apt_delete_source_file ;;
            update) run_cmd "apt update" apt-get update ;;
            back|"") return 0 ;;
        esac
    done
}

_systui_repo_manage_unified() { [ "$PM" = apt ] && repo_sources_listd || repo_manage "$@"; }

_systui_repo_key_import_apt() {
    local url name tmp
    url=$(tui_input "apt key" "Key URL (.gpg or .asc):" "") || return 0
    declare -F sysconfig_valid_url >/dev/null 2>&1 && sysconfig_valid_url "$url" || { tui_msg "Invalid URL" "Use a single-line http:// or https:// key URL."; return 0; }
    name=$(tui_input "apt key" "Keyring filename (no extension):" "custom") || return 0
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { tui_msg "Invalid name" "Unsafe keyring filename."; return 0; }
    mkdir -p /etc/apt/keyrings
    tmp=$(mktemp "$SYSTUI_TMP/key.XXXXXX") || return 1
    if _sys_fetch_text "$url" > "$tmp" && gpg --dearmor --yes -o "/etc/apt/keyrings/$name.gpg" "$tmp"; then
        chmod 0644 "/etc/apt/keyrings/$name.gpg" 2>/dev/null || true
        tui_msg "Key" "Imported /etc/apt/keyrings/$name.gpg"
    else
        tui_msg "Key import failed" "Could not download or decode the key."
    fi
    rm -f -- "$tmp"
}

_systui_repo_key_import_pacman() {
    local kid
    kid=$(tui_input "pacman key" "Key ID or fingerprint:" "") || return 0
    [[ "$kid" =~ ^[A-Fa-f0-9]{8,64}$ ]] || { tui_msg "Invalid key" "Use a hexadecimal key ID or fingerprint."; return 0; }
    run_cmd "Importing pacman key $kid" pacman-key --recv-keys "$kid" || return 1
    run_cmd "Locally signing pacman key $kid" pacman-key --lsign-key "$kid"
}

_systui_remove_added_repos() {
    local f sel
    local -a files=() tags=() selected=()
    case "$PM" in
        apt)
            while IFS= read -r f; do files+=("$f"); done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name 'systui-*.list' -o -name 'systui-*.list.disabled' -o -name 'systui-*.sources' -o -name 'systui-*.sources.disabled' \) -print 2>/dev/null | sort) ;;
        dnf|yum)
            while IFS= read -r f; do files+=("$f"); done < <(find /etc/yum.repos.d -maxdepth 1 -type f -name 'systui-*.repo' -print 2>/dev/null | sort) ;;
        *) tui_msg "Manual" "Use the manager-specific repository editor for $PM."; return 0 ;;
    esac
    [ "${#files[@]}" -gt 0 ] || { tui_msg "None" "No systui-added repository files found."; return 0; }
    for f in "${files[@]}"; do tags+=("$f" "$(basename "$f")" off); done
    sel=$(tui_check "Delete repos" "SPACE selects files to DELETE, ENTER confirms:" "${tags[@]}") || return 0
    # dialog checklists return quoted tags. Parse only tags that exactly match
    # our prebuilt file list; never pass the raw response to rm.
    for f in "${files[@]}"; do [[ " $sel " == *"\"$f\""* || " $sel " == *" $f "* ]] && selected+=("$f"); done
    [ "${#selected[@]}" -gt 0 ] || return 0
    tui_yesno "Confirm" "Delete ${#selected[@]} selected repository file(s)?" || return 0
    rm -f -- "${selected[@]}"
    [ "$PM" = apt ] && run_cmd "apt-get update" apt-get update || true
}

menu_repos() {
    local c ka
    while true; do
        c=$(tui_menu "Repositories  [manager: $PM]" "Repository management:" view "View configured repositories" manage "Manage repository sources" distro "Official distro repositories" popular "Add popular repositories" ppa "Ubuntu PPA repositories" refresh "Refresh package indexes" addrepo "Add a validated custom repository" keys "Signing keys and archive keyrings" remove "Delete a systui-added repository" back "Back") || return 0
        case "$c" in
            view)
                case "$PM" in
                    apt) grep -rHv '^[[:space:]]*#' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -v '^[[:space:]]*$' ;;
                    apk) cat /etc/apk/repositories ;;
                    pacman) grep -A2 '^\[' /etc/pacman.conf | grep -v '^--' ;;
                    dnf) dnf repolist --all ;;
                    yum) yum repolist all ;;
                    zypper) zypper --non-interactive lr -u ;;
                    xbps) grep -rh '^[[:space:]]*repository=' /etc/xbps.d /usr/share/xbps.d 2>/dev/null || true ;;
                esac > "$SYSTUI_TMP/repo" 2>&1
                tui_text "Repositories" "$SYSTUI_TMP/repo" ;;
            manage) _systui_repo_manage_unified ;;
            distro) menu_distro_repos ;;
            popular) repo_popular ;;
            ppa) menu_ppa_repos ;;
            refresh) declare -F sysconfig_repo_refresh >/dev/null 2>&1 && sysconfig_repo_refresh || repo_refresh ;;
            addrepo) declare -F sysconfig_repo_add_custom >/dev/null 2>&1 && sysconfig_repo_add_custom || tui_msg "Repositories" "Validated custom-repository helper is unavailable." ;;
            keys)
                case "$PM" in
                    apt)
                        ka=$(tui_menu "APT Keys" "Signing-key tools:" missing "Download distro keyrings" import "Import key from URL" list "List installed keyrings" back "Back") || continue
                        case "$ka" in
                            missing) apt_missing_keyrings_menu ;;
                            import) _systui_repo_key_import_apt ;;
                            list) find /etc/apt/keyrings /usr/share/keyrings -maxdepth 1 -type f 2>/dev/null | sort > "$SYSTUI_TMP/keys"; tui_text "APT keyrings" "$SYSTUI_TMP/keys" ;;
                        esac ;;
                    pacman) _systui_repo_key_import_pacman ;;
                    *) tui_msg "N/A" "Use the package manager's native signing-key configuration." ;;
                esac ;;
            remove) _systui_remove_added_repos ;;
            back|"") return 0 ;;
        esac
    done
}
