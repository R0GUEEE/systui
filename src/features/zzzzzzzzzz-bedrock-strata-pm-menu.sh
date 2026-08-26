# shellcheck shell=bash
# Bedrock stratum-aware package manager utilities for System Configuration.
#
# The standard Package Configuration > Package Managers flow configures the
# host/universal/language managers.  When Bedrock-AOK is installed, each
# installed stratum carries its own package manager (apt/apk/pacman/dnf/...).
# This last layer surfaces those strata as first-class package-manager
# utilities so they can be driven concurrently with the host PM, all from the
# same System Configuration > Packages flow.
#
# Loaded last (zzzzzzzzzz-...) so it re-wraps the Package Configuration menu
# without touching the native package integration or the Bedrock sysconfig
# layers below it.

# Keep the native Package Configuration menu intact and just extend it.
if declare -F menu_packages >/dev/null 2>&1 && ! declare -F _systui_native_menu_packages >/dev/null 2>&1; then
    eval "$(declare -f menu_packages | sed \
        '1s/^menu_packages[[:space:]]*()/_systui_native_menu_packages ()/')"
fi

# Which Bedrock executable `brl` is available for stratum execution.
bedrock_stratum_pm_brl() { bedrock_aok_brl 2>/dev/null || return 1; }

# All installed strata, one per line (empty when inactive).
bedrock_stratum_pm_strata() {
    if declare -F bedrock_sysconfig_strata >/dev/null 2>&1; then
        bedrock_sysconfig_strata
    elif declare -F bedrock_aok_installed_strata >/dev/null 2>&1; then
        bedrock_aok_installed_strata
    fi
}

# Package manager name for a stratum (apt/apk/pacman/dnf/yum/zypper/xbps/emerge/opkg/unknown).
bedrock_stratum_pm_of() {
    local st="$1"
    if declare -F bedrock_sysconfig_stratum_pm >/dev/null 2>&1; then
        bedrock_sysconfig_stratum_pm "$st"
    else
        printf 'unknown\n'
    fi
}

# Run a read-only command inside a stratum and show it in a text viewer.
bedrock_stratum_pm_view() { # <title> <stratum> <shell-command...>
    local title="$1" st="$2" brl out rc=0
    shift 2
    brl=$(bedrock_stratum_pm_brl) || return 1
    out="${SYSTUI_TMP:?}/bedrock-stratum-pm.$$.txt"
    "$brl" strat -r "$st" /bin/sh -lc "$*" >"$out" 2>&1 || rc=$?
    sed -i 's/\x1b\[[0-9;]*[[:alpha:]]//g' "$out" 2>/dev/null || true
    [ -s "$out" ] || printf '(no output)\n' >"$out"
    tui_text "$title" "$out" || true
    rm -f "$out"
    return "$rc"
}

# Translate a generic package action into an in-stratum shell command for a
# given stratum's package manager.  Prints the command executed as root inside
# the stratum, or returns 1 when the manager has no mapping for the action.
bedrock_stratum_pm_command() { # <stratum> <pm> <action> [extra]
    local pm="$2" act="$3" extra="${4:-}"
    case "$pm" in
        apt)
            case "$act" in
                update) echo "apt-get update -qq && apt-get -y -q upgrade" ;;
                install) echo "apt-get install -y $extra" ;;
                remove) echo "apt-get remove -y $extra" ;;
                clean) echo "apt-get clean && apt-get autoclean" ;;
                audit) echo "dpkg --audit" ;;
                autoremove) echo "apt-get autoremove -y" ;;
                *) return 1 ;;
            esac
            ;;
        apk)
            case "$act" in
                update) echo "apk update && apk upgrade" ;;
                install) echo "apk add $extra" ;;
                remove) echo "apk del $extra" ;;
                clean) echo "apk cache clean" ;;
                audit) echo "apk audit" ;;
                autoremove) echo "apk cache clean" ;;
                *) return 1 ;;
            esac
            ;;
        pacman)
            case "$act" in
                update) echo "pacman -Syu --noconfirm" ;;
                install) echo "pacman -S --noconfirm --needed $extra" ;;
                remove) echo "pacman -R --noconfirm $extra" ;;
                clean) echo "pacman -Sc --noconfirm" ;;
                audit) echo "pacman -Qk" ;;
                autoremove) echo "pacman -Rns --noconfirm \$(pacman -Qtdq) 2>/dev/null || true" ;;
                *) return 1 ;;
            esac
            ;;
        dnf)
            case "$act" in
                update) echo "dnf -y upgrade" ;;
                install) echo "dnf -y install $extra" ;;
                remove) echo "dnf -y remove $extra" ;;
                clean) echo "dnf clean all" ;;
                audit) echo "rpm -Va | head -50" ;;
                autoremove) echo "dnf -y autoremove" ;;
                *) return 1 ;;
            esac
            ;;
        yum)
            case "$act" in
                update) echo "yum -y update" ;;
                install) echo "yum -y install $extra" ;;
                remove) echo "yum -y remove $extra" ;;
                clean) echo "yum clean all" ;;
                audit) echo "rpm -Va | head -50" ;;
                autoremove) echo "yum -y autoremove" ;;
                *) return 1 ;;
            esac
            ;;
        zypper)
            case "$act" in
                update) echo "zypper --non-interactive --no-gpg-checks dup -y" ;;
                install) echo "zypper --non-interactive install -y $extra" ;;
                remove) echo "zypper --non-interactive remove -y $extra" ;;
                clean) echo "zypper clean --all" ;;
                audit) echo "rpm -Va | head -50" ;;
                autoremove) echo "zypper --non-interactive rm -y --clean-deps $extra" ;;
                *) return 1 ;;
            esac
            ;;
        xbps)
            case "$act" in
                update) echo "xbps-install -Syu" ;;
                install) echo "xbps-install -y $extra" ;;
                remove) echo "xbps-remove -y $extra" ;;
                clean) echo "xbps-remove -yO" ;;
                audit) echo "xbps-pkgdb -a | head -50" ;;
                autoremove) echo "xbps-remove -oo" ;;
                *) return 1 ;;
            esac
            ;;
        emerge)
            case "$act" in
                update) echo "emerge --sync && emerge -uDN @world" ;;
                install) echo "emerge --ask=n $extra" ;;
                remove) echo "emerge --unmerge $extra" ;;
                clean) echo "emerge --depclean" ;;
                audit) echo "equery check '*' 2>/dev/null || true" ;;
                autoremove) echo "emerge --depclean" ;;
                *) return 1 ;;
            esac
            ;;
        opkg)
            case "$act" in
                update) echo "opkg update" ;;
                install) echo "opkg install $extra" ;;
                remove) echo "opkg remove $extra" ;;
                clean) echo "opkg clean" ;;
                audit) echo "opkg list-installed | head -50" ;;
                autoremove) echo "opkg clean" ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

# Validate a package-name list strictly (letters, digits, + . _ : @ / -).
# Empty or whitespace-only lists are rejected; every space-separated token must
# be a well-formed package name.
bedrock_stratum_pm_valid_pkgs() { # <space-separated packages>
    local p bad=0
    [ -n "${1//[[:space:]]/}" ] || return 1
    for p in $1; do
        case "$p" in *[!A-Za-z0-9+._:@/-]*|'') bad=1 ;; esac
    done
    [ "$bad" = 0 ]
}

# Edit the stratum's primary package-manager configuration file via TUI:
# stage it out, edit, then copy it back into the stratum.
bedrock_stratum_pm_edit_config() { # <stratum> <pm>
    local st="$1" pm="$2" f brl src
    case "$pm" in
        apt)    f=/etc/apt/apt.conf ;;
        apk)    f=/etc/apk/repositories ;;
        pacman) f=/etc/pacman.conf ;;
        dnf)    f=/etc/dnf/dnf.conf ;;
        yum)    f=/etc/yum.conf ;;
        zypper) f=/etc/zypp/zypper.conf ;;
        xbps)   f=/etc/xbps.d/00-repository-main.conf ;;
        emerge) f=/etc/portage/make.conf ;;
        opkg)   f=/etc/opkg/opkg.conf ;;
        *) tui_msg "Config" "No known config path for $pm in $st."; return 1 ;;
    esac
    tui_yesno "Edit config for $st" "Open '$f' inside the '$st' stratum for editing?" || return 0
    brl=$(bedrock_stratum_pm_brl) || return 1
    src="${SYSTUI_TMP:?}/bedrock-stratum-${st}-pmconf"
    : >"$src"
    "$brl" strat -r "$st" /bin/sh -lc "cat '$f' 2>/dev/null" >"$src" 2>/dev/null || true
    safe_edit "$src" || { rm -f "$src"; return 0; }
    "$brl" strat -r "$st" /bin/sh -lc "cat > '$f' 2>/dev/null" <"$src" >>"${SYSTUI_TMP:?}/pkg" 2>&1 || true
    rm -f "$src"
}

# Interactive per-stratum package manager utility menu.
bedrock_stratum_pm_menu() { # <stratum>
    local st="$1" pm brl
    brl=$(bedrock_stratum_pm_brl) || return 1
    pm=$(bedrock_stratum_pm_of "$st")
    if [ "$pm" = unknown ]; then
        tui_msg "Stratum $st" "No recognizable package manager detected in stratum $st."
        return 1
    fi
    if ! "$brl" strat -r "$st" /bin/sh -lc "command -v $pm" >/dev/null 2>&1; then
        tui_msg "Stratum $st" "The $pm manager is not currently usable inside stratum $st."
    fi
    while true; do
        local c
        c=$(tui_menu "Stratum PM: $st [$pm]" \
            "Package manager utilities for the Bedrock '$st' stratum ($pm):" \
            update "Update and upgrade all packages" \
            search "Search for a package" \
            info "Show package information" \
            list "List installed packages" \
            install "Install packages" \
            remove "Remove packages" \
            autoremove "Autoremove orphaned packages" \
            clean "Clean package caches" \
            audit "Verify package database" \
            config "Edit stratum package configuration" \
            back "Back") || return 0
        local p t q
        case "$c" in
            back|"") return 0 ;;
            update)
                run_cmd "Update $st [$pm]" "$brl" strat -r "$st" /bin/sh -lc "$(bedrock_stratum_pm_command "$st" "$pm" update)" || true
                ;;
            search)
                t=$(tui_input "Search in $st" "Term:" "") || continue
                [ -n "$t" ] || continue
                q=$(bedrock_sysconfig_sh_quote "$t")
                case "$pm" in
                    apt)    bedrock_stratum_pm_view "Search $st [$pm]: $t" "$st" "apt-cache search -- $q | head -30" ;;
                    apk)    bedrock_stratum_pm_view "Search $st [$pm]: $t" "$st" "apk search -v -- $q | head -30" ;;
                    pacman) bedrock_stratum_pm_view "Search $st [$pm]: $t" "$st" "pacman -Ss -- $q | head -30" ;;
                    dnf)    bedrock_stratum_pm_view "Search $st [$pm]: $t" "$st" "dnf -q search $q | head -30" ;;
                    yum)    bedrock_stratum_pm_view "Search $st [$pm]: $t" "$st" "yum -q search $q | head -30" ;;
                    zypper) bedrock_stratum_pm_view "Search $st [$pm]: $t" "$st" "zypper --non-interactive --no-refresh search $q | head -30" ;;
                    xbps)   bedrock_stratum_pm_view "Search $st [$pm]: $t" "$st" "xbps-query -Rs $q | head -30" ;;
                    emerge) bedrock_stratum_pm_view "Search $st [$pm]: $t" "$st" "emerge --search $q | head -30" ;;
                    opkg)   bedrock_stratum_pm_view "Search $st [$pm]: $t" "$st" "opkg list | grep -i -- $q | head -30" ;;
                esac
                ;;
            info)
                p=$(tui_input "Info in $st" "Package:" "") || continue
                [ -n "$p" ] || continue
                q=$(bedrock_sysconfig_sh_quote "$p")
                case "$pm" in
                    apt)    bedrock_stratum_pm_view "Info $st [$pm]: $p" "$st" "apt-cache show $q | head -80" ;;
                    apk)    bedrock_stratum_pm_view "Info $st [$pm]: $p" "$st" "apk info -a $q | head -80" ;;
                    pacman) bedrock_stratum_pm_view "Info $st [$pm]: $p" "$st" "pacman -Si $q | head -80" ;;
                    dnf)    bedrock_stratum_pm_view "Info $st [$pm]: $p" "$st" "dnf -q info $q | head -80" ;;
                    yum)    bedrock_stratum_pm_view "Info $st [$pm]: $p" "$st" "yum -q info $q | head -80" ;;
                    zypper) bedrock_stratum_pm_view "Info $st [$pm]: $p" "$st" "zypper --non-interactive --no-refresh info $q | head -80" ;;
                    xbps)   bedrock_stratum_pm_view "Info $st [$pm]: $p" "$st" "xbps-query -RS $q | head -80" ;;
                    emerge) bedrock_stratum_pm_view "Info $st [$pm]: $p" "$st" "emerge --search $q | head -80" ;;
                    opkg)   bedrock_stratum_pm_view "Info $st [$pm]: $p" "$st" "opkg info $q | head -80" ;;
                esac
                ;;
            list)
                case "$pm" in
                    apt)    bedrock_stratum_pm_view "Installed in $st [$pm]" "$st" "dpkg-query -W | head -200" ;;
                    apk)    bedrock_stratum_pm_view "Installed in $st [$pm]" "$st" "apk info -v | head -200" ;;
                    pacman) bedrock_stratum_pm_view "Installed in $st [$pm]" "$st" "pacman -Q | head -200" ;;
                    dnf|yum) bedrock_stratum_pm_view "Installed in $st [$pm]" "$st" "rpm -qa | head -200" ;;
                    zypper) bedrock_stratum_pm_view "Installed in $st [$pm]" "$st" "rpm -qa | head -200" ;;
                    xbps)   bedrock_stratum_pm_view "Installed in $st [$pm]" "$st" "xbps-query -l | head -200" ;;
                    emerge) bedrock_stratum_pm_view "Installed in $st [$pm]" "$st" "qlist -Iv 2>/dev/null | head -200" ;;
                    opkg)   bedrock_stratum_pm_view "Installed in $st [$pm]" "$st" "opkg list-installed | head -200" ;;
                esac
                ;;
            install)
                p=$(tui_input "Install into $st" "Package names (space-separated):" "") || continue
                [ -n "${p//[[:space:]]/}" ] || continue
                bedrock_stratum_pm_valid_pkgs "$p" || { tui_msg "Invalid package name" "Use letters, numbers, + . _ : @ / and - only."; continue; }
                tui_yesno "Install into $st" "Install '$p' into the '$st' stratum [${pm}]?" || continue
                run_cmd "Install into $st [$pm]: $p" "$brl" strat -r "$st" /bin/sh -lc "$(bedrock_stratum_pm_command "$st" "$pm" install "$p")" || true
                ;;
            remove)
                p=$(tui_input "Remove from $st" "Package names (space-separated):" "") || continue
                [ -n "${p//[[:space:]]/}" ] || continue
                bedrock_stratum_pm_valid_pkgs "$p" || { tui_msg "Invalid package name" "Use letters, numbers, + . _ : @ / and - only."; continue; }
                tui_yesno "Remove from $st" "Remove '$p' from the '$st' stratum [${pm}]?" || continue
                run_cmd "Remove from $st [$pm]: $p" "$brl" strat -r "$st" /bin/sh -lc "$(bedrock_stratum_pm_command "$st" "$pm" remove "$p")" || true
                ;;
            autoremove)
                local acmd
                acmd=$(bedrock_stratum_pm_command "$st" "$pm" autoremove) || { tui_msg "N/A" "No autoremove defined for $pm in $st."; continue; }
                tui_yesno "Autoremove in $st" "Remove orphaned/unneeded packages from the '$st' stratum [${pm}]?" || continue
                run_cmd "Autoremove in $st [$pm]" "$brl" strat -r "$st" /bin/sh -lc "$acmd" || true
                ;;
            clean)
                run_cmd "Clean caches in $st [$pm]" "$brl" strat -r "$st" /bin/sh -lc "$(bedrock_stratum_pm_command "$st" "$pm" clean)" || true
                ;;
            audit)
                bedrock_stratum_pm_view "Audit $st [$pm]" "$st" "$(bedrock_stratum_pm_command "$st" "$pm" audit)" || true
                ;;
            config)
                bedrock_stratum_pm_edit_config "$st" "$pm" || true
                ;;
        esac
    done
}

# Bedrock strata section: pick one installed stratum and open its package
# manager utility menu.
bedrock_stratum_pm_menu_section() {
    local st opts=()
    if ! bedrock_sysconfig_active 2>/dev/null; then
        tui_msg "Bedrock not active" "No installed Bedrock strata were found."
        return 0
    fi
    while IFS= read -r st; do
        [ -n "$st" ] || continue
        opts+=("$st" "Stratum $st ($(bedrock_stratum_pm_of "$st"))" off)
    done < <(bedrock_stratum_pm_strata)
    if [ ${#opts[@]} -eq 0 ]; then
        tui_msg "Bedrock strata" "No Bedrock strata are currently installed."
        return 0
    fi
    local picked
    picked=$(tui_radio "Bedrock strata package managers" \
        "Choose a stratum to operate its package manager (SPACE selects):" \
        "${opts[@]}") || return 0
    [ -n "$picked" ] || return 0
    bedrock_stratum_pm_menu "$picked"
}

# Extend the Package Configuration menu with a "strata" section when Bedrock is
# present, so each installed stratum's package manager is manageable from here.
menu_packages() {
    local st pm active
    active=$(bedrock_sysconfig_active 2>/dev/null && echo 1 || echo 0)
    if [ "$active" = 0 ]; then
        _systui_native_menu_packages
        return
    fi
    local -a tags=(
        packages "Install, remove, search and update packages"
        catalogue "Browse the application catalogue"
        repos "Repositories and keys"
        managers "Package managers (native, Flatpak, Snap, language)"
        strata "Bedrock strata package manager utilities"
        advanced "Advanced package management"
        back "Back"
    )
    while true; do
        local c
        c=$(tui_menu_no_tags "Package Configuration [${PM:-unknown}]" \
            "Select a section (Bedrock strata add their own package managers):" \
            "${tags[@]}") || return 0
        case "$c" in
            packages) menu_package_operations || true ;;
            catalogue) pkg_catalogue || true ;;
            repos) menu_repos || true ;;
            managers) menu_package_managers || true ;;
            strata) bedrock_stratum_pm_menu_section || true ;;
            advanced) menu_pkg_advanced || true ;;
            back|"") return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
