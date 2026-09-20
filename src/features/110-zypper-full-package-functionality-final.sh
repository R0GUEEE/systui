# shellcheck shell=bash
###############################################################################
# PHASE 110 — full Zypper package-manager functionality
#
# Provides an openSUSE/SUSE-native control surface without replacing the
# generic package APIs or Bedrock-aware wrappers loaded earlier.
###############################################################################

systui_zypper_available() {
    command -v zypper >/dev/null 2>&1
}

systui_zypper_require() {
    systui_zypper_available && return 0
    tui_msg "Zypper unavailable" "The zypper executable is not available in the current runtime."
    return 127
}

systui_zypper_show() { # <title> <command...>
    local title="$1" out rc=0
    shift
    out="${SYSTUI_TMP:-${TMPDIR:-/tmp}}/systui-zypper-$$.txt"
    "$@" >"$out" 2>&1 || rc=$?
    [ -s "$out" ] || printf '(no output)\n' >"$out"
    tui_text "$title" "$out" || true
    rm -f -- "$out"
    return "$rc"
}

systui_zypper_refresh() {
    systui_zypper_require || return $?
    run_cmd "Zypper refresh" zypper --non-interactive --gpg-auto-import-keys refresh
}

systui_zypper_update() {
    systui_zypper_require || return $?
    run_cmd "Zypper update" zypper --non-interactive update
}

systui_zypper_dist_upgrade() {
    systui_zypper_require || return $?
    tui_yesno "Distribution upgrade"         "Run 'zypper dup'?\n\nThis performs a distribution upgrade and may change package vendors or repositories." || return 0
    run_cmd "Zypper distribution upgrade" zypper --non-interactive dup
}

systui_zypper_install() {
    local input
    local -a pkgs=()
    systui_zypper_require || return $?
    input=$(tui_input "Zypper install" "Package name(s), space separated:" "") || return 0
    [ -n "${input//[[:space:]]/}" ] || return 0
    if declare -F parse_package_input >/dev/null 2>&1; then
        parse_package_input "$input" pkgs || return 1
    else
        read -r -a pkgs <<< "$input"
    fi
    run_cmd "Zypper install ${pkgs[*]}" zypper --non-interactive install -- "${pkgs[@]}"
}

systui_zypper_remove() {
    local input
    local -a pkgs=()
    systui_zypper_require || return $?
    input=$(tui_input "Zypper remove" "Package name(s), space separated:" "") || return 0
    [ -n "${input//[[:space:]]/}" ] || return 0
    if declare -F parse_package_input >/dev/null 2>&1; then
        parse_package_input "$input" pkgs || return 1
    else
        read -r -a pkgs <<< "$input"
    fi
    tui_yesno "Remove packages" "Remove with Zypper?\n\n${pkgs[*]}" || return 0
    run_cmd "Zypper remove ${pkgs[*]}" zypper --non-interactive remove -- "${pkgs[@]}"
}

systui_zypper_reinstall() {
    local input
    local -a pkgs=()
    systui_zypper_require || return $?
    input=$(tui_input "Zypper reinstall" "Installed package name(s), space separated:" "") || return 0
    [ -n "${input//[[:space:]]/}" ] || return 0
    read -r -a pkgs <<< "$input"
    run_cmd "Zypper reinstall ${pkgs[*]}" zypper --non-interactive install --force -- "${pkgs[@]}"
}

systui_zypper_search() {
    local term
    systui_zypper_require || return $?
    term=$(tui_input "Zypper search" "Package, capability, or pattern:" "") || return 0
    [ -n "$term" ] || return 0
    systui_zypper_show "Zypper search: $term" zypper --non-interactive search -s -- "$term"
}

systui_zypper_info() {
    local pkg
    systui_zypper_require || return $?
    pkg=$(tui_input "Zypper package info" "Package name:" "") || return 0
    [ -n "$pkg" ] || return 0
    systui_zypper_show "Package info: $pkg" zypper --non-interactive info -- "$pkg"
}

systui_zypper_list_installed() {
    systui_zypper_require || return $?
    systui_zypper_show "Installed packages" zypper --non-interactive search --installed-only -s
}

systui_zypper_list_updates() {
    systui_zypper_require || return $?
    systui_zypper_show "Available updates" zypper --non-interactive list-updates
}

systui_zypper_verify() {
    systui_zypper_require || return $?
    run_cmd "Zypper verify dependencies" zypper --non-interactive verify
}

systui_zypper_clean() {
    systui_zypper_require || return $?
    run_cmd "Zypper clean caches" zypper --non-interactive clean --all
}

systui_zypper_patches() {
    systui_zypper_require || return $?
    systui_zypper_show "Available patches" zypper --non-interactive list-patches
}

systui_zypper_patch_install() {
    systui_zypper_require || return $?
    run_cmd "Install Zypper patches" zypper --non-interactive patch
}

systui_zypper_patterns() {
    systui_zypper_require || return $?
    systui_zypper_show "Zypper patterns" zypper --non-interactive patterns
}

systui_zypper_locks_menu() {
    local c item
    systui_zypper_require || return $?
    while true; do
        tui_capture_menu c tui_menu_no_tags "Zypper locks"             "Protect packages from installation, removal, or upgrade:"             list "List active locks"             add "Add a package lock"             remove "Remove a package lock"             clean "Remove all locks"             back "Back" || return $?
        case "$c" in
            list) systui_zypper_show "Zypper locks" zypper --non-interactive locks ;;
            add)
                item=$(tui_input "Add lock" "Package or capability:" "") || continue
                [ -n "$item" ] && run_cmd "Add Zypper lock: $item" zypper --non-interactive addlock -- "$item"
                ;;
            remove)
                item=$(tui_input "Remove lock" "Package or capability:" "") || continue
                [ -n "$item" ] && run_cmd "Remove Zypper lock: $item" zypper --non-interactive removelock -- "$item"
                ;;
            clean)
                tui_yesno "Remove all locks" "Delete every Zypper package lock?"                     && run_cmd "Remove all Zypper locks" zypper --non-interactive cleanlocks
                ;;
            back|'') return 0 ;;
        esac
    done
}

systui_zypper_repositories_menu() {
    local c alias url
    systui_zypper_require || return $?
    while true; do
        tui_capture_menu c tui_menu_no_tags "Zypper repositories"             "Manage openSUSE/SUSE software repositories:"             list "List repositories with priorities and URLs"             refresh "Refresh all repositories"             add "Add and auto-refresh a repository"             remove "Remove a repository by alias"             enable "Enable a repository by alias"             disable "Disable a repository by alias"             back "Back" || return $?
        case "$c" in
            list) systui_zypper_show "Zypper repositories" zypper --non-interactive repos -d -u ;;
            refresh) systui_zypper_refresh ;;
            add)
                alias=$(tui_input "Add repository" "Repository alias:" "systui-custom") || continue
                if declare -F sysconfig_valid_repo_name >/dev/null 2>&1; then
                    sysconfig_valid_repo_name "$alias" || { tui_msg "Invalid alias" "Use letters, digits, dots, underscores and dashes only."; continue; }
                fi
                url=$(tui_input "Add repository" "Repository URL:" "") || continue
                if declare -F sysconfig_valid_url >/dev/null 2>&1; then
                    sysconfig_valid_url "$url" || { tui_msg "Invalid URL" "Use an http:// or https:// URL."; continue; }
                fi
                [ -n "$alias" ] && [ -n "$url" ] || continue
                run_cmd "Add Zypper repository: $alias" zypper --non-interactive addrepo --refresh "$url" "$alias"
                ;;
            remove|enable|disable)
                alias=$(tui_input "Repository $c" "Repository alias:" "") || continue
                [ -n "$alias" ] || continue
                case "$c" in
                    remove)
                        tui_yesno "Remove repository" "Remove repository '$alias'?"                             && run_cmd "Remove Zypper repository: $alias" zypper --non-interactive removerepo "$alias"
                        ;;
                    enable) run_cmd "Enable Zypper repository: $alias" zypper --non-interactive modifyrepo --enable "$alias" ;;
                    disable) run_cmd "Disable Zypper repository: $alias" zypper --non-interactive modifyrepo --disable "$alias" ;;
                esac
                ;;
            back|'') return 0 ;;
        esac
    done
}

menu_zypper_manager() {
    local c
    systui_zypper_require || return $?
    while true; do
        tui_capture_menu c tui_menu_no_tags "Zypper package manager"             "Full package management for openSUSE/SUSE:"             install "Install packages"             remove "Remove packages"             reinstall "Reinstall packages"             search "Search packages/capabilities"             info "Show package information"             installed "List installed packages"             updates "List available updates"             refresh "Refresh repositories and import trusted keys"             update "Install normal package updates"             dup "Distribution upgrade (zypper dup)"             patches "List available patches"             patch "Install applicable patches"             patterns "List software patterns"             locks "Package locks"             repos "Repository management"             verify "Verify dependency consistency"             clean "Clean metadata/package caches"             config "Edit /etc/zypp/zypper.conf"             back "Back" || return $?
        case "$c" in
            install) systui_zypper_install ;;
            remove) systui_zypper_remove ;;
            reinstall) systui_zypper_reinstall ;;
            search) systui_zypper_search ;;
            info) systui_zypper_info ;;
            installed) systui_zypper_list_installed ;;
            updates) systui_zypper_list_updates ;;
            refresh) systui_zypper_refresh ;;
            update) systui_zypper_update ;;
            dup) systui_zypper_dist_upgrade ;;
            patches) systui_zypper_patches ;;
            patch) systui_zypper_patch_install ;;
            patterns) systui_zypper_patterns ;;
            locks) systui_zypper_locks_menu ;;
            repos) systui_zypper_repositories_menu ;;
            verify) systui_zypper_verify ;;
            clean) systui_zypper_clean ;;
            config)
                if [ -f /etc/zypp/zypper.conf ]; then safe_edit /etc/zypp/zypper.conf
                else tui_msg "Zypper config" "/etc/zypp/zypper.conf does not exist."; fi
                ;;
            back|'') return 0 ;;
        esac
    done
}

# Add Zypper's native administration hub to the final package-manager menu while
# preserving all generic, language-manager, and Bedrock entries.
if declare -F menu_package_managers >/dev/null 2>&1     && ! declare -F _systui_package_managers_before_zypper_full >/dev/null 2>&1; then
    _systui_saved_fn=$(declare -f menu_package_managers)
    _systui_saved_fn=${_systui_saved_fn/#menu_package_managers /_systui_package_managers_before_zypper_full }
    eval "$_systui_saved_fn"
    unset _systui_saved_fn
fi

menu_package_managers() {
    local c
    if ! systui_zypper_available && [ "${PM:-}" != zypper ]; then
        _systui_package_managers_before_zypper_full "$@"
        return $?
    fi
    while true; do
        tui_capture_menu c tui_menu_no_tags "Package Managers"             "Configure package-manager ecosystems and native Zypper administration:"             zypper "Zypper — full openSUSE/SUSE package management"             existing "Other native/language package managers"             back "Back" || return $?
        case "$c" in
            zypper) menu_zypper_manager ;;
            existing) _systui_package_managers_before_zypper_full ;;
            back|'') return 0 ;;
        esac
    done
}


# These functions are used by the menus in this shell only. Feature files are
# sourced into one Bash process, and modern core/rootfs/sysconfig modules must
# not export functions (iSH ARG_MAX limits and the loader export scrubber).

return 0 2>/dev/null || true
