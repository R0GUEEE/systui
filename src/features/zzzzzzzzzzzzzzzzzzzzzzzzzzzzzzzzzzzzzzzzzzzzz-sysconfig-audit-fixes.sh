# shellcheck shell=bash
###############################################################################
# SYSTEM CONFIGURATION — audit fixes
#
# Final runtime hardening for the current-system configuration UI.  This file
# deliberately overrides only public helpers/menus with concrete correctness,
# portability, or input-safety problems found in the full sysconfig audit.
###############################################################################

sysconfig_is_ish() {
    case "${SYSTUI_ISH_AOK:-}" in 1|yes|true) return 0 ;; esac
    case "${container:-}" in *ish*|*iSH*) return 0 ;; esac
    case "$(uname -r 2>/dev/null) $(uname -a 2>/dev/null)" in
        *-ish*|*ish_aok*|*iSH-AOK*|*iSH*) return 0 ;;
    esac
    return 1
}

sysconfig_systemd_usable() {
    [ "${INIT:-}" = systemd ] || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    local s
    s=$(systemctl is-system-running 2>/dev/null || true)
    case "$s" in running|degraded|starting|maintenance) return 0 ;; esac
    return 1
}

sysconfig_valid_token() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._@:+-]{0,127}$ ]]; }
sysconfig_valid_iface() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$ ]]; }
sysconfig_valid_group_list() { [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$ ]]; }
sysconfig_valid_abs_path() { [[ "${1:-}" == /* && "${1:-}" != *$'\n'* && "${1:-}" != *$'\r'* ]]; }
sysconfig_valid_size() { [[ "${1:-}" =~ ^[0-9]+([KMGTPE]i?[Bb]?)?$ ]]; }
sysconfig_valid_repo_name() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }
sysconfig_valid_url() { [[ "${1:-}" =~ ^https?://[^[:space:]]+$ ]]; }

sysconfig_require_existing_user() {
    local u="$1"
    [[ "$u" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,31}$ ]] && id "$u" >/dev/null 2>&1
}

sysconfig_call_menu() { # <function> <label>
    local fn="$1" label="$2"
    if declare -F "$fn" >/dev/null 2>&1; then
        "$fn"
    else
        tui_msg "System Configuration" "$label is unavailable because its menu function was not loaded.\n\nMissing function: $fn"
        warn "sysconfig: missing menu function $fn ($label)"
    fi
}

# zypper was incorrectly mapped through Fedora package names.  openSUSE is not
# represented by the four-column package map, so keep native names instead of
# silently substituting Fedora-only names.
local_pkg_map() {
    case "${PM:-}" in
        apk) map_packages alpine "$@" ;;
        pacman) map_packages arch "$@" ;;
        dnf|yum) map_packages fedora "$@" ;;
        xbps) map_packages void "$@" ;;
        zypper|apt|emerge|*) printf '%s\n' "$*" ;;
    esac
}

# Pick an editor that actually exists. The old fallback always selected nano,
# which fails on minimal installations where nano is exactly what the user is
# trying to install/configure.
safe_edit() {
    local file="$1" editor_spec="${EDITOR:-}"; shift || true
    local -a editor_argv=()
    if [ -n "$editor_spec" ]; then
        read -r -a editor_argv <<< "$editor_spec"
    fi
    if [ "${#editor_argv[@]}" -eq 0 ] || ! command -v "${editor_argv[0]}" >/dev/null 2>&1; then
        local e
        editor_argv=()
        for e in nano vim vi nvim micro ed; do
            if command -v "$e" >/dev/null 2>&1; then editor_argv=("$e"); break; fi
        done
    fi
    [ "${#editor_argv[@]}" -gt 0 ] || { tui_msg "Editor unavailable" "No usable text editor is installed."; return 127; }
    "${editor_argv[@]}" "$file" "$@"
}

_sysconfig_apt_policy_created=0
sysconfig_apt_guard_prepare() {
    _sysconfig_apt_policy_created=0
    sysconfig_is_ish || return 0
    if [ ! -e /usr/sbin/policy-rc.d ]; then
        mkdir -p /usr/sbin
        cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
        chmod 0755 /usr/sbin/policy-rc.d
        _sysconfig_apt_policy_created=1
    fi
}
sysconfig_apt_guard_cleanup() {
    [ "${_sysconfig_apt_policy_created:-0}" = 1 ] && rm -f /usr/sbin/policy-rc.d 2>/dev/null || true
    _sysconfig_apt_policy_created=0
}

# Native package installation with a deterministic iSH APT mode and correct
# return status after the optional cross-repository fallback. Previously a
# successful fallback still returned the original native PM failure.
pm_install() {
    validate_packages "$@" || return 1
    local rc=0 pkg fallback_failed=0
    case "${PM:-}" in
        apt)
            sysconfig_apt_guard_prepare
            if DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true SYSTEMD_OFFLINE=1 \
                run_cmd "apt install $*" apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confold install -y -- "$@"; then
                rc=0
            else
                rc=$?
                if sysconfig_is_ish; then
                    DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true SYSTEMD_OFFLINE=1 \
                        dpkg --configure -a >>"$LOGFILE" 2>&1 || true
                    DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true SYSTEMD_OFFLINE=1 \
                        apt-get -f install -y >>"$LOGFILE" 2>&1 || true
                    DEBIAN_FRONTEND=noninteractive dpkg --configure -a >>"$LOGFILE" 2>&1 || true
                    if dpkg-query -W -f='${db:Status-Abbrev}\n' "$@" 2>/dev/null | grep -vq '^ii'; then :; else rc=0; fi
                fi
            fi
            sysconfig_apt_guard_cleanup
            ;;
        apk)
            if run_cmd "apk add $*" apk add -- "$@"; then rc=0
            else run_cmd "apk update (retry after failed add)" apk update || true; run_cmd "apk add $* (retry)" apk add -- "$@"; rc=$?; fi ;;
        pacman) run_cmd "pacman -S $*" pacman -S --noconfirm --needed -- "$@"; rc=$? ;;
        dnf) run_cmd "dnf install $*" dnf install -y -- "$@"; rc=$? ;;
        yum) run_cmd "yum install $*" yum install -y -- "$@"; rc=$? ;;
        zypper) run_cmd "zypper install $*" zypper --non-interactive install -- "$@"; rc=$? ;;
        xbps) run_cmd "xbps-install $*" xbps-install -Sy -- "$@"; rc=$? ;;
        emerge) run_cmd "emerge $*" emerge --ask=n -- "$@"; rc=$? ;;
        *) tui_msg "Error" "No supported package manager found."; return 1 ;;
    esac

    if [ "$rc" -ne 0 ] && [ "${SYSTUI_PM_NO_WEB_FALLBACK:-0}" != 1 ] && declare -F pkg_web_fallback >/dev/null 2>&1; then
        for pkg in "$@"; do
            if pkg_web_fallback "$pkg"; then :; else fallback_failed=1; fi
        done
        [ "$fallback_failed" -eq 0 ] && rc=0
    fi
    return "$rc"
}

scan_pkg_count() {
    case "${PM:-}" in
        apt) dpkg-query -W 2>/dev/null | wc -l ;;
        apk) apk info 2>/dev/null | wc -l ;;
        pacman) pacman -Q 2>/dev/null | wc -l ;;
        dnf|yum|zypper) rpm -qa 2>/dev/null | wc -l ;;
        xbps) xbps-query -l 2>/dev/null | wc -l ;;
        emerge) if command -v qlist >/dev/null 2>&1; then qlist -IC 2>/dev/null | wc -l; else find /var/db/pkg -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l; fi ;;
        *) echo '?' ;;
    esac
}

sysconfig_set_hostname() {
    local h
    h=$(tui_input "Hostname" "New hostname:" "$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null)") || return 0
    [ -n "$h" ] || return 0
    [[ "$h" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}[A-Za-z0-9]$|^[A-Za-z0-9]$ ]] || {
        tui_msg "Invalid hostname" "Use letters, digits, dots and dashes; do not begin or end with punctuation."; return 0;
    }
    printf '%s\n' "$h" > /etc/hostname || return 1
    hostname "$h" 2>/dev/null || true
    if sysconfig_systemd_usable && command -v hostnamectl >/dev/null 2>&1; then hostnamectl set-hostname "$h" 2>>"$LOGFILE" || true; fi
    if ! grep -qE "^[[:space:]]*127\\.0\\.1\\.1[[:space:]].*([[:space:]]|^)$h([[:space:]]|$)" /etc/hosts 2>/dev/null; then
        printf '127.0.1.1\t%s\n' "$h" >> /etc/hosts
    fi
    tui_msg "Hostname" "Hostname set to $h."
}

sysconfig_set_timezone() {
    local tz
    tz=$(tui_input "Timezone" "IANA timezone (for example America/New_York or UTC):" \
        "$(cat /etc/timezone 2>/dev/null || readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || echo UTC)") || return 0
    [ -n "$tz" ] || return 0
    case "$tz" in *..*|/*|*\\*) tui_msg "Error" "Invalid timezone path."; return 0;; esac
    [ -f "/usr/share/zoneinfo/$tz" ] || { tui_msg "Error" "Unknown timezone: $tz"; return 0; }
    ln -sfn "/usr/share/zoneinfo/$tz" /etc/localtime
    printf '%s\n' "$tz" > /etc/timezone 2>/dev/null || true
    if sysconfig_systemd_usable && command -v timedatectl >/dev/null 2>&1; then timedatectl set-timezone "$tz" 2>>"$LOGFILE" || true; fi
    tui_msg "Done" "Timezone set to $tz."
}

# Do not offer a real init replacement where there is no real bootable init
# boundary (iSH/chroot/container). Package-swapping init there only breaks the
# userspace and cannot change the host kernel's PID 1 semantics.
if declare -F initswap_current >/dev/null 2>&1 && ! declare -F _systui_base_initswap_current_audit >/dev/null 2>&1; then
    eval "$(declare -f initswap_current | sed '1s/^initswap_current[[:space:]]*()/_systui_base_initswap_current_audit ()/')"
fi
initswap_current() {
    if sysconfig_is_ish || [ -f /.dockerenv ] || grep -qaE '(docker|lxc|container|chroot)' /proc/1/cgroup 2>/dev/null; then
        tui_msg "Init swap unavailable" "This environment does not control a normal boot PID 1. Replacing init packages here can leave the userspace unconfigurable without changing how the host boots."
        return 0
    fi
    _systui_base_initswap_current_audit "$@"
}

# Safer repository front-end: all supported PMs get useful view/refresh
# behavior, and user-controlled names can no longer escape config directories.
sysconfig_repo_view() {
    case "${PM:-}" in
        apt) { grep -rHEn '^[[:space:]]*(deb|deb-src)[[:space:]]' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; grep -rHEn '^[[:space:]]*(Types|URIs|Suites|Components):' /etc/apt/sources.list.d/*.sources 2>/dev/null; } ;;
        apk) cat /etc/apk/repositories 2>/dev/null ;;
        pacman) grep -E '^\[[^]]+\]|^[[:space:]]*Server[[:space:]]*=' /etc/pacman.conf 2>/dev/null ;;
        dnf|yum) "${PM}" repolist --all 2>/dev/null ;;
        zypper) zypper --non-interactive lr -u 2>/dev/null ;;
        xbps) { grep -rh '^[[:space:]]*repository=' /etc/xbps.d /usr/share/xbps.d 2>/dev/null || true; } ;;
        emerge) { grep -rhE '^[[:space:]]*(sync-uri|sync-type|location)[[:space:]]*=' /etc/portage/repos.conf /usr/share/portage/config/repos.conf 2>/dev/null || true; } ;;
        *) echo "No supported package manager detected." ;;
    esac
}

sysconfig_repo_refresh() {
    case "${PM:-}" in
        apt) run_cmd "apt-get update" apt-get update ;;
        apk) run_cmd "apk update" apk update ;;
        pacman) run_cmd "pacman -Syyu" pacman -Syu --noconfirm ;;
        dnf) run_cmd "dnf makecache" dnf makecache ;;
        yum) run_cmd "yum makecache" yum makecache ;;
        zypper) run_cmd "zypper refresh" zypper --non-interactive refresh ;;
        xbps) run_cmd "xbps refresh" xbps-install -S ;;
        emerge) run_cmd "Portage sync" emerge --sync ;;
        *) return 1 ;;
    esac
}

sysconfig_repo_add_custom() {
    local name url line tmp
    case "${PM:-}" in
        apt)
            line=$(tui_input "Add apt repo" "Full deb/deb-src line:" "deb ") || return 0
            case "$line" in deb\ *|deb-src\ *) ;; *) tui_msg "Invalid repository" "APT entries must begin with 'deb ' or 'deb-src '."; return 0;; esac
            [ "$line" != *$'\n'* ] && [ "$line" != *$'\r'* ] || { tui_msg "Invalid repository" "Repository entries must be one line."; return 0; }
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
            [ -n "$url" ] && [ "$url" != *$'\n'* ] && [ "$url" != *$'\r'* ] || return 0
            printf '\n[%s]\nServer = %s\n' "$name" "$url" >> /etc/pacman.conf
            ;;
        dnf|yum)
            url=$(tui_input "Add RPM repo" ".repo file URL:" "") || return 0
            sysconfig_valid_url "$url" || { tui_msg "Invalid URL" "Use an http:// or https:// .repo URL."; return 0; }
            case "$url" in *.repo) ;; *) tui_msg "Invalid URL" "Enter a URL ending in .repo."; return 0;; esac
            name=$(basename "${url%%\?*}")
            sysconfig_valid_repo_name "${name%.repo}" || name=custom.repo
            tmp=$(mktemp "${SYSTUI_TMP}/repo.XXXXXX") || return 1
            if _sys_fetch_text "$url" > "$tmp" && grep -q '^\[' "$tmp"; then
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
        emerge) tui_msg "Portage repositories" "Use /etc/portage/repos.conf for custom Portage repositories. The editor will open that directory's systui.conf file."; mkdir -p /etc/portage/repos.conf; safe_edit /etc/portage/repos.conf/systui.conf ;;
        *) tui_msg "N/A" "No supported package manager detected." ;;
    esac
}

menu_repos() {
    while true; do
        local c
        c=$(tui_menu "Repositories  [manager: ${PM:-unknown}]" "Repository management:" \
            view "View configured repositories" manage "Manage sources (enable/disable)" listd "Manage sources.list and sources.list.d" \
            distro "Distro Repos (official repositories)" popular "Add popular repositories" ppa "Ubuntu PPA repositories" \
            refresh "Refresh package indexes" addrepo "Add a custom repository" keys "Signing keys / archive keyrings" \
            remove "Delete a systui-added repository" back "Back") || return 0
        case "$c" in
            view) sysconfig_repo_view > "$SYSTUI_TMP/repo" 2>&1; [ -s "$SYSTUI_TMP/repo" ] || echo '(none)' > "$SYSTUI_TMP/repo"; tui_text "Repositories" "$SYSTUI_TMP/repo" ;;
            manage) sysconfig_call_menu repo_manage "Repository manager" ;;
            listd) [ "${PM:-}" = apt ] && sysconfig_call_menu repo_sources_listd "APT sources editor" || tui_msg "N/A" "sources.list.d management is APT-specific." ;;
            distro) [ "${PM:-}" = apt ] && sysconfig_call_menu menu_distro_repos "Distro repositories" || tui_msg "N/A" "Distro Repos currently writes APT repository definitions." ;;
            popular) sysconfig_call_menu repo_popular "Popular repositories" ;;
            ppa) sysconfig_call_menu menu_ppa_repos "PPA repositories" ;;
            refresh) sysconfig_repo_refresh || tui_msg "Refresh failed" "Repository refresh failed. See $LOGFILE." ;;
            addrepo) sysconfig_repo_add_custom ;;
            keys) [ "${PM:-}" = apt ] && sysconfig_call_menu apt_missing_keyrings_menu "APT keyrings" || tui_msg "Signing keys" "Use the native $PM key/repository tooling; the automatic keyring downloader is APT-specific." ;;
            remove) [ "${PM:-}" = apt ] && { local f sel; local -a opts=(); for f in /etc/apt/sources.list.d/systui-*.list /etc/apt/sources.list.d/systui-*.list.disabled; do [ -f "$f" ] && opts+=("$f" "$(basename "$f")" off); done; [ "${#opts[@]}" -gt 0 ] || { tui_msg "None" "No systui-added APT repositories found."; continue; }; sel=$(tui_check "Delete repos" "SPACE selects repository files:" "${opts[@]}") || continue; sel=${sel//\"/}; for f in $sel; do case "$f" in /etc/apt/sources.list.d/systui-*.list|/etc/apt/sources.list.d/systui-*.list.disabled) rm -f -- "$f";; esac; done; } || tui_msg "Repository removal" "Use the native $PM repository manager for non-APT repository removal." ;;
            back|"") return 0 ;;
        esac
    done
}

# Validate service names before they are used as paths or unit names.
if declare -F svc >/dev/null 2>&1 && ! declare -F _systui_base_svc_audit >/dev/null 2>&1; then
    eval "$(declare -f svc | sed '1s/^svc[[:space:]]*()/_systui_base_svc_audit ()/')"
fi
svc() {
    local action="${1:-}" s="${2:-}"
    case "$action" in enable|disable|start|stop|restart|status) ;; *) return 2;; esac
    sysconfig_valid_token "$s" || { echo "Invalid service name: $s" >&2; return 2; }
    _systui_base_svc_audit "$action" "$s"
}

# User operations are kept feature-complete but now validate all usernames and
# filesystem-derived sudoers names before changing accounts.
menu_users() {
    while true; do
        local c u p sh_ g home_dir key mx wn
        c=$(tui_menu "Users" "User management:" add "Add a user" del "Delete a user" passwd "Change password" aging "Password aging" \
            expire "Force password change" lock "Lock account" unlock "Unlock account" sudo "Grant sudo group" nopass "Passwordless sudo" \
            sudoers "Manage systui sudoers drop-ins" sshkey "Add SSH authorized key" groups "Add user to groups" whois "Show user details" \
            defaults "Defaults for new users" list "List human users" advanced "Advanced user settings" back "Back") || return 0
        case "$c" in
            add)
                u=$(tui_input "New user" "Username:" "") || continue
                [[ "$u" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,31}$ ]] || { tui_msg "Invalid user" "Unsafe or invalid username."; continue; }
                id "$u" >/dev/null 2>&1 && { tui_msg "Exists" "User $u already exists."; continue; }
                sh_=$(tui_radio "Shell" "Login shell:" /bin/bash Bash on /bin/sh sh off /bin/zsh Zsh off) || continue
                if command -v useradd >/dev/null 2>&1; then run_cmd "useradd $u" useradd -m -s "$sh_" -- "$u"; else run_cmd "adduser $u" adduser -D -s "$sh_" -- "$u"; fi || continue
                p=$(tui_password "Password" "Password for $u (blank leaves account locked):") || true
                [ -n "$p" ] && printf '%s:%s\n' "$u" "$p" | chpasswd
                ;;
            del) u=$(tui_input "Delete user" "Username:" "") || continue; sysconfig_require_existing_user "$u" || { tui_msg "Invalid user" "User not found or unsafe name."; continue; }; [ "$u" = root ] && { tui_msg "Refused" "Root cannot be deleted here."; continue; }; tui_yesno "Confirm" "Delete '$u' and their home directory?" && run_cmd "Deleting $u" userdel -r -- "$u" ;;
            passwd) u=$(tui_input "Password" "Username:" "${SUDO_USER:-root}") || continue; sysconfig_require_existing_user "$u" || { tui_msg "Invalid user" "User not found."; continue; }; p=$(tui_password "Password" "New password for $u:") || continue; [ -n "$p" ] && printf '%s:%s\n' "$u" "$p" | chpasswd ;;
            aging) command -v chage >/dev/null 2>&1 || { tui_msg "N/A" "chage is not installed."; continue; }; u=$(tui_input "Aging" "Username:" "") || continue; sysconfig_require_existing_user "$u" || continue; mx=$(tui_input "Aging" "Maximum age in days (-1 = never):" "-1") || continue; wn=$(tui_input "Aging" "Warning days:" "7") || continue; [[ "$mx" =~ ^-?[0-9]+$ && "$wn" =~ ^[0-9]+$ ]] || { tui_msg "Invalid" "Aging values must be integers."; continue; }; run_cmd "chage $u" chage -M "$mx" -W "$wn" -- "$u" ;;
            expire|lock|unlock) u=$(tui_input "User" "Username:" "") || continue; sysconfig_require_existing_user "$u" || { tui_msg "Invalid user" "User not found."; continue; }; case "$c" in expire) run_cmd "Expire $u" passwd -e -- "$u";; lock) run_cmd "Lock $u" usermod -L -- "$u";; unlock) run_cmd "Unlock $u" usermod -U -- "$u";; esac ;;
            sudo) u=$(tui_input "Sudo" "Username:" "") || continue; sysconfig_require_existing_user "$u" || continue; g=sudo; getent group sudo >/dev/null 2>&1 || g=wheel; run_cmd "Grant $g to $u" usermod -aG "$g" -- "$u" ;;
            nopass) u=$(tui_input "NOPASSWD" "Username:" "") || continue; sysconfig_require_existing_user "$u" || { tui_msg "Invalid user" "User not found."; continue; }; mkdir -p /etc/sudoers.d; printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$u" > "/etc/sudoers.d/90-systui-$u"; chmod 0440 "/etc/sudoers.d/90-systui-$u"; if command -v visudo >/dev/null 2>&1 && ! visudo -cf "/etc/sudoers.d/90-systui-$u" >/dev/null 2>&1; then rm -f "/etc/sudoers.d/90-systui-$u"; tui_msg "Error" "sudoers validation failed; reverted."; fi ;;
            sudoers) local f sel; local -a opts=(); for f in /etc/sudoers.d/90-systui-*; do [ -f "$f" ] && opts+=("$f" "$(basename "$f")"); done; [ "${#opts[@]}" -gt 0 ] || { tui_msg "None" "No systui sudoers drop-ins found."; continue; }; sel=$(tui_menu "sudoers drop-ins" "Select a drop-in to delete:" "${opts[@]}") || continue; case "$sel" in /etc/sudoers.d/90-systui-*) tui_yesno "Confirm" "Delete $sel?" && rm -f -- "$sel";; esac ;;
            sshkey) u=$(tui_input "SSH key" "Username:" "${SUDO_USER:-root}") || continue; sysconfig_require_existing_user "$u" || continue; home_dir=$(user_home "$u"); [ -n "$home_dir" ] || continue; key=$(tui_input "SSH key" "Paste one OpenSSH public-key line:" "") || continue; case "$key" in ssh-*\ *|ecdsa-*\ *|sk-*\ *) ;; *) tui_msg "Invalid key" "Expected an OpenSSH public key line."; continue;; esac; mkdir -p "$home_dir/.ssh"; printf '%s\n' "$key" >> "$home_dir/.ssh/authorized_keys"; chmod 700 "$home_dir/.ssh"; chmod 600 "$home_dir/.ssh/authorized_keys"; chown -R "$u":"$(id -gn "$u")" "$home_dir/.ssh" ;;
            groups) u=$(tui_input "Groups" "Username:" "") || continue; sysconfig_require_existing_user "$u" || continue; g=$(tui_input "Groups" "Comma-separated groups:" "") || continue; sysconfig_valid_group_list "$g" || { tui_msg "Invalid groups" "Use comma-separated group names only."; continue; }; run_cmd "Add $u to groups" usermod -aG "$g" -- "$u" ;;
            whois) u=$(tui_input "User details" "Username:" "${SUDO_USER:-root}") || continue; sysconfig_require_existing_user "$u" || continue; { id "$u"; getent passwd "$u"; command -v chage >/dev/null 2>&1 && chage -l "$u" 2>/dev/null; } > "$SYSTUI_TMP/usr" 2>&1; tui_text "Details: $u" "$SYSTUI_TMP/usr" ;;
            defaults) sysconfig_call_menu menu_user_advanced "Advanced/new-user settings" ;;
            list) awk -F: '$3>=1000 && $3<65534 {printf "%-16s uid=%-6s %s\n",$1,$3,$7}' /etc/passwd > "$SYSTUI_TMP/usr"; tui_text "Human users" "$SYSTUI_TMP/usr" ;;
            advanced) sysconfig_call_menu menu_user_advanced "Advanced user settings" ;;
            back|"") return 0 ;;
        esac
    done
}

# Storage: reject malformed paths/sizes and remove the shell interpolation from
# swapfile creation that allowed a crafted size string to execute commands.
if declare -F menu_storage >/dev/null 2>&1 && ! declare -F _systui_base_menu_storage_audit >/dev/null 2>&1; then
    eval "$(declare -f menu_storage | sed '1s/^menu_storage[[:space:]]*()/_systui_base_menu_storage_audit ()/')"
fi
sysconfig_create_swapfile() {
    local size="$1" file="${2:-/swapfile}"
    sysconfig_valid_size "$size" || { tui_msg "Invalid size" "Use a size such as 512M, 2G, or 4096M."; return 1; }
    sysconfig_valid_abs_path "$file" || return 1
    if command -v fallocate >/dev/null 2>&1 && fallocate -l "$size" "$file" 2>>"$LOGFILE"; then :
    elif command -v truncate >/dev/null 2>&1; then truncate -s "$size" "$file"
    else tui_msg "Swap" "Neither fallocate nor truncate is available."; return 1; fi
    chmod 0600 "$file" && mkswap "$file" && swapon "$file" || return 1
    grep -qF "$file none swap sw 0 0" /etc/fstab 2>/dev/null || printf '%s none swap sw 0 0\n' "$file" >> /etc/fstab
}

menu_storage() {
    while true; do
        local c dev mp src dst sz f fs opts uuid line lbl pct typed
        c=$(tui_menu "Storage" "Storage & mounts:" list "List block devices & mounts" mount "Mount a device" umount "Unmount a device/path" bind "Create a bind mount" \
            fstab "Add an fstab entry" label "Label a filesystem" swap "Create & enable a swapfile" tmpfs "Mount a tmpfs" format "Format a partition (DESTRUCTIVE)" \
            reserve "Reserved blocks % (ext filesystems)" smart "Disk health (SMART)" usage "Disk usage overview" advanced "Advanced storage" back "Back") || return 0
        case "$c" in
            list) { command -v lsblk >/dev/null 2>&1 && lsblk -o NAME,SIZE,FSTYPE,LABEL,TYPE,MOUNTPOINTS; echo; command -v findmnt >/dev/null 2>&1 && findmnt; } > "$SYSTUI_TMP/stor" 2>&1; tui_text "Block devices" "$SYSTUI_TMP/stor" ;;
            mount) dev=$(tui_input "Mount" "Device/source:" "") || continue; mp=$(tui_input "Mount" "Mountpoint:" "/mnt/data") || continue; [ -n "$dev" ] && sysconfig_valid_abs_path "$mp" || { tui_msg "Invalid mount" "Mountpoint must be an absolute single-line path."; continue; }; mkdir -p -- "$mp" && run_cmd "mount $dev -> $mp" mount -- "$dev" "$mp" ;;
            umount) mp=$(tui_input "Unmount" "Device or mountpoint:" "") || continue; [ -n "$mp" ] && run_cmd "umount $mp" umount -- "$mp" ;;
            bind) src=$(tui_input "Bind mount" "Source directory:" "") || continue; dst=$(tui_input "Bind mount" "Target directory:" "") || continue; sysconfig_valid_abs_path "$src" && sysconfig_valid_abs_path "$dst" && [ -d "$src" ] || { tui_msg "Invalid bind" "Source and target must be absolute paths and source must exist."; continue; }; mkdir -p -- "$dst" && run_cmd "bind $src -> $dst" mount --bind -- "$src" "$dst" ;;
            fstab) dev=$(tui_input "fstab" "Device/source:" "") || continue; mp=$(tui_input "fstab" "Absolute mountpoint:" "/mnt/data") || continue; fs=$(tui_input "fstab" "Filesystem type:" "ext4") || continue; opts=$(tui_input "fstab" "Mount options:" "defaults,nofail") || continue; sysconfig_valid_abs_path "$mp" && sysconfig_valid_token "$fs" && [[ "$opts" =~ ^[A-Za-z0-9_.,=:-]+$ ]] || { tui_msg "Invalid fstab entry" "Mountpoint, filesystem type, or options are malformed."; continue; }; uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || true); [ -n "$uuid" ] && line="UUID=$uuid $mp $fs $opts 0 2" || line="$dev $mp $fs $opts 0 2"; cp -p /etc/fstab "/etc/fstab.bak.$(date +%s)" 2>/dev/null || true; printf '%s\n' "$line" >> /etc/fstab; mkdir -p -- "$mp"; mount -a 2>>"$LOGFILE" || tui_msg "fstab warning" "mount -a reported an error. A backup was kept." ;;
            label) dev=$(tui_input "Label" "Device:" "") || continue; lbl=$(tui_input "Label" "New label:" "") || continue; [ -n "$dev" ] && [ -n "$lbl" ] && [ "$lbl" != *$'\n'* ] || continue; fs=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true); case "$fs" in ext2|ext3|ext4) run_cmd "e2label" e2label "$dev" "$lbl";; xfs) run_cmd "xfs_admin" xfs_admin -L "$lbl" "$dev";; vfat) run_cmd "fatlabel" fatlabel "$dev" "$lbl";; btrfs) run_cmd "btrfs label" btrfs filesystem label "$dev" "$lbl";; *) tui_msg "N/A" "Unsupported filesystem type: ${fs:-unknown}";; esac ;;
            swap) sz=$(tui_input "Swapfile" "Size (for example 2G):" "2G") || continue; sysconfig_create_swapfile "$sz" /swapfile && tui_msg "Swap" "Swapfile created, enabled and added to fstab." ;;
            tmpfs) mp=$(tui_input "tmpfs" "Mountpoint:" "/mnt/ramdisk") || continue; sz=$(tui_input "tmpfs" "Size:" "512M") || continue; sysconfig_valid_abs_path "$mp" && sysconfig_valid_size "$sz" || { tui_msg "Invalid tmpfs" "Use an absolute path and a size such as 512M."; continue; }; mkdir -p -- "$mp" && run_cmd "tmpfs $mp" mount -t tmpfs -o "size=$sz" tmpfs "$mp" ;;
            format) dev=$(tui_input "Format" "Partition/device to format:" "") || continue; [ -n "$dev" ] || continue; mount | grep -Fq "$dev " && { tui_msg "Refused" "$dev appears to be mounted."; continue; }; fs=$(tui_radio "Filesystem" "Filesystem:" ext4 ext4 on xfs XFS off btrfs Btrfs off vfat FAT32 off) || continue; tui_yesno "DESTRUCTIVE" "Erase ALL DATA on $dev and create $fs?" || continue; typed=$(tui_input "Confirm" "Type the exact device path:" "") || continue; [ "$typed" = "$dev" ] || continue; case "$fs" in ext4) run_cmd "mkfs.ext4 $dev" mkfs.ext4 -F -- "$dev";; xfs) run_cmd "mkfs.xfs $dev" mkfs.xfs -f -- "$dev";; btrfs) run_cmd "mkfs.btrfs $dev" mkfs.btrfs -f -- "$dev";; vfat) run_cmd "mkfs.vfat $dev" mkfs.vfat -- "$dev";; esac ;;
            reserve) dev=$(tui_input "Reserved blocks" "ext filesystem device:" "") || continue; pct=$(tui_input "Reserved blocks" "Reserved percentage (0-50):" "1") || continue; [[ "$pct" =~ ^[0-9]+$ ]] && [ "$pct" -le 50 ] || { tui_msg "Invalid" "Percentage must be 0-50."; continue; }; run_cmd "tune2fs -m $pct $dev" tune2fs -m "$pct" -- "$dev" ;;
            smart) command -v smartctl >/dev/null 2>&1 || pm_install smartmontools || continue; dev=$(tui_input "SMART" "Disk:" "/dev/sda") || continue; { smartctl -H "$dev"; echo; smartctl -A "$dev" | head -30; } > "$SYSTUI_TMP/stor" 2>&1; tui_text "SMART: $dev" "$SYSTUI_TMP/stor" ;;
            usage) { df -hT -x tmpfs -x devtmpfs 2>/dev/null || df -h; } > "$SYSTUI_TMP/stor"; tui_text "Disk usage" "$SYSTUI_TMP/stor" ;;
            advanced) sysconfig_call_menu menu_storage_advanced "Advanced storage" ;;
            back|"") return 0 ;;
        esac
    done
}

# Network-sensitive overrides: avoid command-existence checks for systemd and
# provide validated direct helpers used by the existing menu.
if declare -F menu_network >/dev/null 2>&1 && ! declare -F _systui_base_menu_network_audit >/dev/null 2>&1; then
    eval "$(declare -f menu_network | sed '1s/^menu_network[[:space:]]*()/_systui_base_menu_network_audit ()/')"
fi
menu_network() {
    # The base menu remains feature-rich. Refresh detection before entry so its
    # systemd/network branches reflect the current runtime, not startup state.
    detect_init 2>/dev/null || true
    _systui_base_menu_network_audit "$@"
}

# Final top-level menu: refresh runtime detection on every pass and guard every
# submenu call so stale/failed late modules cannot turn a selection into a hang.
menu_sysconfig() {
    while true; do
        detect_pm 2>/dev/null || true
        detect_init 2>/dev/null || true
        detect_distro 2>/dev/null || true
        local c
        c=$(tui_menu_no_tags "System Configuration" \
            "Detected: package manager = ${PM:-none}, init = ${INIT:-none}" \
            common "Common tasks — packages, hostname, timezone, users, SSH" packages "Packages (catalogue, repositories, package managers)" \
            shells "Shells & plugins" editors "Editors" filemanagers "File managers" network "Network" services "Services (${INIT:-unknown})" \
            users "Users" storage "Storage" back "Back to main menu") || return 0
        case "$c" in
            common) sysconfig_call_menu menu_sysconfig_common "Common tasks" ;;
            packages) sysconfig_call_menu menu_packages "Packages" ;;
            shells) sysconfig_call_menu menu_shells "Shells" ;;
            editors) sysconfig_call_menu menu_editors "Editors" ;;
            filemanagers) sysconfig_call_menu menu_file_managers "File managers" ;;
            network) sysconfig_call_menu menu_network "Network" ;;
            services) sysconfig_call_menu menu_services "Services" ;;
            users) sysconfig_call_menu menu_users "Users" ;;
            storage) sysconfig_call_menu menu_storage "Storage" ;;
            back|"") return 0 ;;
        esac
    done
}

export -f sysconfig_is_ish sysconfig_systemd_usable sysconfig_valid_token sysconfig_valid_iface \
    sysconfig_valid_group_list sysconfig_valid_abs_path sysconfig_valid_size sysconfig_valid_repo_name \
    sysconfig_valid_url sysconfig_require_existing_user sysconfig_call_menu local_pkg_map safe_edit pm_install \
    scan_pkg_count sysconfig_set_hostname sysconfig_set_timezone initswap_current sysconfig_repo_view \
    sysconfig_repo_refresh sysconfig_repo_add_custom menu_repos svc menu_users sysconfig_create_swapfile \
    menu_storage menu_network menu_sysconfig
