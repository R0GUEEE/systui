#!/bin/bash
# Validated custom repository handling for supported package managers.

systui_sysconfig_repo_add_custom() {
    local name url line tmp
    case "${PM:-}" in
        apt)
            line=$(tui_input "Add apt repo" "Full deb/deb-src line:" "deb ") || return 0
            [[ "$line" != *$'\n'* && "$line" != *$'\r'* ]] || { tui_msg "Invalid repository" "Repository entries must be one line."; return 0; }
            case "$line" in deb\ *|deb-src\ *) ;; *) tui_msg "Invalid repository" "APT entries must begin with 'deb ' or 'deb-src '."; return 0;; esac
            name=$(tui_input "Add apt repo" "Short name for the .list file:" "custom") || return 0
            sysconfig_valid_repo_name "$name" || { tui_msg "Invalid name" "Use letters, digits, dots, underscores and dashes only."; return 0; }
            mkdir -p /etc/apt/sources.list.d
            printf '%s\n' "$line" > "/etc/apt/sources.list.d/systui-$name.list"
            ;;
        apk)
            url=$(tui_input "Add apk repo" "Repository URL:" "") || return 0
            sysconfig_valid_url "$url" || { tui_msg "Invalid URL" "Use a single-line http:// or https:// URL."; return 0; }
            grep -qxF "$url" /etc/apk/repositories 2>/dev/null || printf '%s\n' "$url" >> /etc/apk/repositories
            ;;
        pacman)
            name=$(tui_input "Add pacman repo" "Repository name:" "custom") || return 0
            sysconfig_valid_repo_name "$name" || { tui_msg "Invalid name" "Unsafe pacman repository name."; return 0; }
            url=$(tui_input "Add pacman repo" "Server URL (\$repo/\$arch allowed):" "") || return 0
            [[ -n "$url" && "$url" != *$'\n'* && "$url" != *$'\r'* ]] || return 0
            case "$url" in http://*|https://*) ;; *) tui_msg "Invalid URL" "Pacman Server must use http:// or https://."; return 0;; esac
            printf '\n[%s]\nServer = %s\n' "$name" "$url" >> /etc/pacman.conf
            ;;
        dnf|yum)
            url=$(tui_input "Add RPM repo" ".repo file URL:" "") || return 0
            sysconfig_valid_url "$url" || { tui_msg "Invalid URL" "Use an http:// or https:// .repo URL."; return 0; }
            case "${url%%\?*}" in *.repo) ;; *) tui_msg "Invalid URL" "Enter a URL ending in .repo."; return 0;; esac
            name=${url%%\?*}; name=${name##*/}
            sysconfig_valid_repo_name "${name%.repo}" || name=custom.repo
            tmp=$(mktemp "${SYSTUI_TMP}/repo.XXXXXX") || return 1
            if _sys_fetch_text "$url" > "$tmp" && grep -q '^\[' "$tmp"; then
                mkdir -p /etc/yum.repos.d
                install -m 0644 "$tmp" "/etc/yum.repos.d/systui-$name"
            else
                tui_msg "Repository failed" "The URL did not return a valid .repo file."
            fi
            rm -f "$tmp"
            ;;
        zypper)
            name=$(tui_input "Add zypper repo" "Repository alias:" "systui-custom") || return 0
            sysconfig_valid_repo_name "$name" || { tui_msg "Invalid name" "Unsafe repository alias."; return 0; }
            url=$(tui_input "Add zypper repo" "Repository URL:" "") || return 0
            sysconfig_valid_url "$url" || { tui_msg "Invalid URL" "Use an http:// or https:// URL."; return 0; }
            run_cmd "zypper addrepo $name" zypper --non-interactive addrepo -f "$url" "$name"
            ;;
        xbps)
            url=$(tui_input "Add XBPS repo" "Repository URL:" "") || return 0
            sysconfig_valid_url "$url" || { tui_msg "Invalid URL" "Use an http:// or https:// URL."; return 0; }
            mkdir -p /etc/xbps.d
            grep -qxF "repository=$url" /etc/xbps.d/20-systui-repositories.conf 2>/dev/null || printf 'repository=%s\n' "$url" >> /etc/xbps.d/20-systui-repositories.conf
            ;;
        emerge)
            tui_msg "Portage repositories" "Use /etc/portage/repos.conf for custom Portage repositories."
            mkdir -p /etc/portage/repos.conf
            safe_edit /etc/portage/repos.conf/systui.conf
            ;;
        *) tui_msg "N/A" "No supported package manager detected." ;;
    esac
}

# Modern modules are sourced; never export function bodies.
