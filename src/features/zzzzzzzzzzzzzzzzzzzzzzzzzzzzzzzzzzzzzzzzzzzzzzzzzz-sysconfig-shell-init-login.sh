# shellcheck shell=bash
###############################################################################
# SYSTEM CONFIGURATION — Shell login + init management
###############################################################################

sysconfig_shell_path_valid() {
    case "${1:-}" in
        /*) [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]] ;;
        *) return 1 ;;
    esac
}

sysconfig_shell_for_user() { getent passwd "$1" 2>/dev/null | awk -F: 'NR==1{print $7}'; }

sysconfig_shell_list() {
    local p
    {
        [ -r /etc/shells ] && cat /etc/shells
        for p in /bin/bash /usr/bin/bash /bin/sh /usr/bin/sh /bin/zsh /usr/bin/zsh /usr/bin/fish /bin/fish /usr/bin/nu /usr/local/bin/nu /usr/bin/dash /bin/dash /bin/ksh /usr/bin/ksh /bin/mksh /usr/bin/mksh /bin/tcsh /usr/bin/tcsh /usr/bin/elvish /usr/local/bin/elvish /usr/bin/pwsh /usr/local/bin/pwsh; do
            [ -x "$p" ] && printf '%s\n' "$p"
        done
    } 2>/dev/null | awk 'NF && $1 !~ /^#/ && !seen[$1]++'
}

sysconfig_shell_choose() {
    local title="$1" current="${2:-}" p state
    local -a args=()
    while IFS= read -r p; do
        [ -x "$p" ] || continue
        [ "$p" = "$current" ] && state=on || state=off
        args+=("$p" "$(basename "$p")${p:+ — $p}" "$state")
    done < <(sysconfig_shell_list)
    [ "${#args[@]}" -gt 0 ] || { tui_msg "Shells" "No executable login shells were found."; return 1; }
    tui_radio "$title" "Current: ${current:-unknown}\n\nSPACE selects, ENTER applies:" "${args[@]}"
}

sysconfig_shell_set_user() {
    local u current chosen
    u=$(tui_input "Login shell" "Change the login shell for which user?" "${SUDO_USER:-root}") || return 0
    if declare -F sysconfig_require_existing_user >/dev/null 2>&1; then
        sysconfig_require_existing_user "$u" || { tui_msg "Login shell" "User '$u' was not found."; return 0; }
    else
        id "$u" >/dev/null 2>&1 || { tui_msg "Login shell" "User '$u' was not found."; return 0; }
    fi
    current=$(sysconfig_shell_for_user "$u")
    chosen=$(sysconfig_shell_choose "Login shell — $u" "$current") || return 0
    [ -n "$chosen" ] && [ "$chosen" != "$current" ] || return 0
    sysconfig_shell_path_valid "$chosen" && [ -x "$chosen" ] || { tui_msg "Login shell" "Selected shell is not executable."; return 1; }
    if [ -w /etc/shells ] && ! grep -qxF "$chosen" /etc/shells 2>/dev/null; then printf '%s\n' "$chosen" >> /etc/shells; fi
    if command -v usermod >/dev/null 2>&1; then run_cmd "Set $u login shell to $chosen" usermod -s "$chosen" -- "$u" || return 1
    elif command -v chsh >/dev/null 2>&1; then run_cmd "Set $u login shell to $chosen" chsh -s "$chosen" "$u" || return 1
    else tui_msg "Login shell" "Neither usermod nor chsh is available."; return 1; fi
    tui_msg "Login shell" "$u now uses $chosen.\nThe change takes effect at the next login."
}

sysconfig_shell_set_new_user_default() {
    local current chosen
    command -v useradd >/dev/null 2>&1 || { tui_msg "New-user shell" "useradd defaults are unavailable on this system."; return 0; }
    current=$(useradd -D 2>/dev/null | awk -F= '$1=="SHELL"{print $2}')
    chosen=$(sysconfig_shell_choose "Default shell for new users" "$current") || return 0
    [ -n "$chosen" ] && [ "$chosen" != "$current" ] || return 0
    run_cmd "Set new-user login shell to $chosen" useradd -D -s "$chosen" || return 1
    tui_msg "New-user shell" "New accounts created with useradd will default to $chosen.\nExisting users were not changed."
}

sysconfig_shells_file_menu() {
    local c p
    while true; do
        c=$(tui_menu "/etc/shells" "Valid login shells used by chsh and other account tools:" view "View registered login shells" add "Register an executable shell" remove "Remove a shell entry" back "Back") || return 0
        case "$c" in
            view) { cat /etc/shells 2>/dev/null || echo '(no /etc/shells file)'; } > "$SYSTUI_TMP/shells-file"; tui_text "/etc/shells" "$SYSTUI_TMP/shells-file" ;;
            add) p=$(tui_input "Register shell" "Absolute path to executable shell:" "/usr/bin/") || continue; sysconfig_shell_path_valid "$p" && [ -x "$p" ] || { tui_msg "Invalid shell" "$p is not an executable absolute path."; continue; }; touch /etc/shells || continue; grep -qxF "$p" /etc/shells 2>/dev/null || printf '%s\n' "$p" >> /etc/shells ;;
            remove)
                local -a options=()
                while IFS= read -r p; do [ -n "$p" ] && options+=("$p" "$p"); done < /etc/shells 2>/dev/null
                [ "${#options[@]}" -gt 0 ] || continue
                p=$(tui_menu "Remove shell entry" "This does not uninstall the shell:" "${options[@]}" back "Back") || continue
                [ "$p" = back ] && continue
                case "$p" in /bin/sh|/bin/bash|/usr/bin/bash) tui_yesno "Core shell" "Remove $p from /etc/shells?\nThis can affect chsh/login tools." || continue;; esac
                awk -v p="$p" '$0 != p' /etc/shells > "$SYSTUI_TMP/shells.new" && cat "$SYSTUI_TMP/shells.new" > /etc/shells ;;
            back|"") return 0 ;;
        esac
    done
}

sysconfig_shell_show_accounts() { awk -F: '{printf "%-20s %-7s %s\n", $1, $3, $7}' /etc/passwd > "$SYSTUI_TMP/login-shells"; tui_text "Account login shells" "$SYSTUI_TMP/login-shells"; }

sysconfig_sh_provider() {
    local current chosen p state
    current=$(readlink -f /bin/sh 2>/dev/null || printf '/bin/sh')
    local -a args=()
    for p in /bin/dash /usr/bin/dash /bin/bash /usr/bin/bash /bin/ash /usr/bin/ash /bin/busybox /usr/bin/busybox; do
        [ -x "$p" ] || continue
        [ "$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")" = "$current" ] && state=on || state=off
        args+=("$p" "$(basename "$p") — $p" "$state")
    done
    [ "${#args[@]}" -gt 0 ] || { tui_msg "/bin/sh" "No compatible POSIX shell providers were found."; return 0; }
    chosen=$(tui_radio "/bin/sh provider" "Current target: $current\n\nChanging /bin/sh can affect system scripts. SPACE selects:" "${args[@]}") || return 0
    [ -n "$chosen" ] || return 0
    tui_yesno "Change /bin/sh" "Point /bin/sh to $chosen?\n\nThis changes the system POSIX shell and may affect package/system scripts." || return 0
    if command -v update-alternatives >/dev/null 2>&1 && update-alternatives --query sh >/dev/null 2>&1; then run_cmd "Set /bin/sh provider" update-alternatives --set sh "$chosen" || return 1
    else [ -L /bin/sh ] || cp -p /bin/sh "/bin/sh.systui-backup.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true; ln -sfn "$chosen" /bin/sh || return 1; fi
    tui_msg "/bin/sh" "/bin/sh now resolves to $(readlink -f /bin/sh 2>/dev/null || echo "$chosen")."
}

sysconfig_init_summary() {
    detect_init 2>/dev/null || true
    {
        echo "Detected init : ${INIT:-unknown}"
        echo "PID 1         : $(cat /proc/1/comm 2>/dev/null || echo unknown)"
        echo "/sbin/init    : $(readlink -f /sbin/init 2>/dev/null || echo unavailable)"
        echo "Environment   : $(if declare -F sysconfig_is_ish >/dev/null 2>&1 && sysconfig_is_ish; then echo iSH-AOK; elif [ -f /.dockerenv ]; then echo container; else echo normal/unknown; fi)"
        echo
        command -v systemctl >/dev/null 2>&1 && systemctl is-system-running 2>/dev/null || true
        command -v rc-status >/dev/null 2>&1 && rc-status 2>/dev/null | head -30 || true
    } > "$SYSTUI_TMP/init-summary"
    tui_text "Init system" "$SYSTUI_TMP/init-summary"
}

menu_shell_init_login() {
    local c
    while true; do
        detect_init 2>/dev/null || true
        c=$(tui_menu "Shell login & init" "Login-shell defaults and init management. Current init: ${INIT:-unknown}" user "Change a user's default login shell" newuser "Set the default login shell for NEW users" accounts "List users and their login shells" shellsfile "Manage /etc/shells" shprovider "Manage the system /bin/sh provider" initstatus "Show detected init system / PID 1" initswap "Change the system init (systemd/OpenRC/runit/SysVinit)" services "Open service/init manager" back "Back") || return 0
        case "$c" in
            user) sysconfig_shell_set_user ;;
            newuser) sysconfig_shell_set_new_user_default ;;
            accounts) sysconfig_shell_show_accounts ;;
            shellsfile) sysconfig_shells_file_menu ;;
            shprovider) sysconfig_sh_provider ;;
            initstatus) sysconfig_init_summary ;;
            initswap) declare -F initswap_current >/dev/null 2>&1 && initswap_current || tui_msg "Init system" "Init switching is unavailable in this build." ;;
            services) declare -F menu_services >/dev/null 2>&1 && menu_services || tui_msg "Services" "Service management is unavailable in this build." ;;
            back|"") return 0 ;;
        esac
    done
}

if declare -F menu_shells >/dev/null 2>&1 && ! declare -F _systui_base_menu_shells_initlogin >/dev/null 2>&1; then
    eval "$(declare -f menu_shells | sed '1s/^menu_shells[[:space:]]*()/_systui_base_menu_shells_initlogin ()/')"
fi

menu_shells() {
    local c
    while true; do
        c=$(tui_menu "Shells" "Shell frameworks, plugins, login defaults and init integration:" manage "Shells, frameworks, prompts & plugins" logininit "Login shell & init system management" back "Back") || return 0
        case "$c" in manage) _systui_base_menu_shells_initlogin ;; logininit) menu_shell_init_login ;; back|"") return 0 ;; esac
    done
}

export -f sysconfig_shell_path_valid sysconfig_shell_for_user sysconfig_shell_list sysconfig_shell_choose sysconfig_shell_set_user sysconfig_shell_set_new_user_default sysconfig_shells_file_menu sysconfig_shell_show_accounts sysconfig_sh_provider sysconfig_init_summary menu_shell_init_login menu_shells
