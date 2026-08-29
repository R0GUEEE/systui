# shellcheck shell=bash
# Bedrock-AOK integration for System Configuration package management.
# Loaded after sysconfig.sh and the Bedrock feature modules so the normal
# package tools transparently gain access to installed Bedrock strata.

# Preserve the native implementations before replacing them.  pm_install is
# the central install entrypoint used by System Configuration and the software
# catalogue, so integrating here automatically covers those workflows too.
if declare -F pm_install >/dev/null 2>&1 && ! declare -F _systui_native_pm_install >/dev/null 2>&1; then
    eval "$(declare -f pm_install | sed '1s/^pm_install[[:space:]]*()/_systui_native_pm_install ()/')"
fi
if declare -F pm_search >/dev/null 2>&1 && ! declare -F _systui_native_pm_search >/dev/null 2>&1; then
    eval "$(declare -f pm_search | sed '1s/^pm_search[[:space:]]*()/_systui_native_pm_search ()/')"
fi
if declare -F pkg_show_info >/dev/null 2>&1 && ! declare -F _systui_native_pkg_show_info >/dev/null 2>&1; then
    eval "$(declare -f pkg_show_info | sed '1s/^pkg_show_info[[:space:]]*()/_systui_native_pkg_show_info ()/')"
fi

bedrock_sysconfig_active() {
    declare -F bedrock_aok_installed >/dev/null 2>&1 && bedrock_aok_installed
}

bedrock_sysconfig_strata() {
    if declare -F bedrock_aok_installed_strata >/dev/null 2>&1; then
        bedrock_aok_installed_strata
    elif [ -d /bedrock/strata ]; then
        find /bedrock/strata -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null \
            | sed 's#.*/##' | LC_ALL=C sort
    fi
}

# Determine the package manager from the stratum filesystem without entering it.
# This is fast, deterministic and works even when a stratum currently has no
# pseudo-filesystems mounted.
bedrock_sysconfig_stratum_pm() { # <stratum>
    local r="/bedrock/strata/$1"
    if [ -x "$r/usr/bin/apt" ] || [ -x "$r/usr/bin/apt-get" ]; then echo apt
    elif [ -x "$r/sbin/apk" ] || [ -x "$r/usr/bin/apk" ]; then echo apk
    elif [ -x "$r/usr/bin/pacman" ]; then echo pacman
    elif [ -x "$r/usr/bin/dnf" ]; then echo dnf
    elif [ -x "$r/usr/bin/yum" ]; then echo yum
    elif [ -x "$r/usr/bin/zypper" ]; then echo zypper
    elif [ -x "$r/usr/bin/xbps-query" ]; then echo xbps
    elif [ -x "$r/usr/bin/emerge" ]; then echo emerge
    elif [ -x "$r/bin/opkg" ] || [ -x "$r/usr/bin/opkg" ]; then echo opkg
    else echo unknown
    fi
}

bedrock_sysconfig_sh_quote() {
    # POSIX single-quote escaping for commands passed to `brl strat ... sh -lc`.
    local s="$1"
    s=${s//\'/\'"\'"\'}
    printf "'%s'" "$s"
}

bedrock_sysconfig_exec_quiet() { # <stratum> <shell-command>
    local brl="$1" st="$2" cmd="$3"
    "$brl" strat -r "$st" /bin/sh -lc "$cmd" >/dev/null 2>&1
}

bedrock_sysconfig_pkg_available() { # <stratum> <package>
    local st="$1" pkg="$2" pm brl q cmd
    bedrock_sysconfig_active || return 1
    brl=$(bedrock_aok_brl) || return 1
    pm=$(bedrock_sysconfig_stratum_pm "$st")
    q=$(bedrock_sysconfig_sh_quote "$pkg")
    case "$pm" in
        apt)     cmd="apt-cache show $q >/dev/null 2>&1" ;;
        apk)     cmd="apk search -x $q 2>/dev/null | grep -q ." ;;
        pacman)  cmd="pacman -Si $q >/dev/null 2>&1" ;;
        dnf)     cmd="dnf -q info $q >/dev/null 2>&1" ;;
        yum)     cmd="yum -q info $q >/dev/null 2>&1" ;;
        zypper)  cmd="zypper --non-interactive --no-refresh search -x $q 2>/dev/null | grep -Fq $q" ;;
        xbps)    cmd="xbps-query -Rs $q 2>/dev/null | grep -q ." ;;
        emerge)  cmd="emerge --search $q 2>/dev/null | grep -q ." ;;
        opkg)    cmd="opkg list $q 2>/dev/null | grep -q ." ;;
        *) return 1 ;;
    esac
    bedrock_sysconfig_exec_quiet "$brl" "$st" "$cmd"
}

# Print matching strata as "name|package-manager".
bedrock_sysconfig_package_sources() { # <package>
    local pkg="$1" st pm
    while IFS= read -r st; do
        [ -n "$st" ] || continue
        if bedrock_sysconfig_pkg_available "$st" "$pkg"; then
            pm=$(bedrock_sysconfig_stratum_pm "$st")
            printf '%s|%s\n' "$st" "$pm"
        fi
    done <<< "$(bedrock_sysconfig_strata)"
}

bedrock_sysconfig_install_fallback() { # <package>
    local pkg="$1" brl sources st pm picked
    local -a opts=()
    bedrock_sysconfig_active || return 1
    brl=$(bedrock_aok_brl) || return 1

    sources=$(bedrock_sysconfig_package_sources "$pkg")
    [ -n "$sources" ] || return 1

    while IFS='|' read -r st pm; do
        [ -n "$st" ] || continue
        opts+=("$st" "$st — $pm" off)
    done <<< "$sources"
    [ ${#opts[@]} -gt 0 ] || return 1

    if [ ${#opts[@]} -eq 3 ]; then
        st=${opts[0]}
        tui_yesno "Install from Bedrock" \
"'$pkg' is unavailable from the host package manager ($PM), but is available in Bedrock stratum '$st' (${opts[1]#*— }).\n\nInstall it there and expose its commands through Bedrock's unified PATH?" || return 1
    else
        st=$(tui_radio "Install from Bedrock" \
"'$pkg' is unavailable on the host. Choose a Bedrock stratum (SPACE selects):" \
            "${opts[@]}") || return 1
    fi

    run_cmd "Install $pkg from Bedrock stratum $st" "$brl" install "$st" "$pkg" || return 1
    # Ensure the stratum participates in cross-command resolution and rebuild
    # wrappers so newly installed executables are immediately visible system-wide.
    "$brl" enable "$st" >/dev/null 2>&1 || true
    run_cmd "Refresh Bedrock unified command PATH" "$brl" reload || true
    return 0
}

# Host first, Bedrock second, existing web/cross-distro fallback last.
pm_install() {
    validate_packages "$@" || return 1
    local native_rc=0 pkg unresolved=0

    # Suppress sysconfig.sh's web fallback for this first attempt; Bedrock is a
    # safer and more cohesive fallback because packages stay inside a managed
    # stratum instead of force-installing foreign packages into the host root.
    SYSTUI_PM_NO_WEB_FALLBACK=1 _systui_native_pm_install "$@" || native_rc=$?
    [ "$native_rc" -eq 0 ] && return 0

    for pkg in "$@"; do
        # If the failed batch partially installed this package, do not duplicate it.
        command -v "$pkg" >/dev/null 2>&1 && continue
        if command -v dpkg >/dev/null 2>&1 && dpkg -s "$pkg" >/dev/null 2>&1; then continue; fi

        if bedrock_sysconfig_install_fallback "$pkg"; then
            continue
        fi

        unresolved=1
        if [ "${SYSTUI_PM_NO_WEB_FALLBACK:-0}" != "1" ] && declare -F pkg_web_fallback >/dev/null 2>&1; then
            pkg_web_fallback "$pkg" || true
        fi
    done

    [ "$unresolved" -eq 0 ] && return 0
    return "$native_rc"
}

bedrock_sysconfig_search_one() { # <stratum> <term>
    local st="$1" term="$2" pm brl q cmd
    brl=$(bedrock_aok_brl) || return 1
    pm=$(bedrock_sysconfig_stratum_pm "$st")
    q=$(bedrock_sysconfig_sh_quote "$term")
    case "$pm" in
        apt)     cmd="apt-cache search -- $q 2>/dev/null | head -30" ;;
        apk)     cmd="apk search -v -- $q 2>/dev/null | head -30" ;;
        pacman)  cmd="pacman -Ss -- $q 2>/dev/null | head -30" ;;
        dnf)     cmd="dnf -q search $q 2>/dev/null | head -30" ;;
        yum)     cmd="yum -q search $q 2>/dev/null | head -30" ;;
        zypper)  cmd="zypper --non-interactive --no-refresh search $q 2>/dev/null | head -30" ;;
        xbps)    cmd="xbps-query -Rs $q 2>/dev/null | head -30" ;;
        emerge)  cmd="emerge --search $q 2>/dev/null | head -30" ;;
        opkg)    cmd="opkg list | grep -i -- $q 2>/dev/null | head -30" ;;
        *) return 1 ;;
    esac
    printf '\n===== Bedrock: %s [%s] =====\n' "$st" "$pm"
    "$brl" strat -r "$st" /bin/sh -lc "$cmd" 2>/dev/null || true
}

# Repository searches now behave like a unified package index: host results
# first, followed by each installed Bedrock stratum.
pm_search() {
    local term="$1" st
    printf '===== Host: %s =====\n' "$PM"
    _systui_native_pm_search "$term" 2>&1 || true
    bedrock_sysconfig_active || return 0
    while IFS= read -r st; do
        [ -n "$st" ] || continue
        bedrock_sysconfig_search_one "$st" "$term"
    done <<< "$(bedrock_sysconfig_strata)"
}

bedrock_sysconfig_info_one() { # <stratum> <package>
    local st="$1" pkg="$2" pm brl q cmd
    brl=$(bedrock_aok_brl) || return 1
    pm=$(bedrock_sysconfig_stratum_pm "$st")
    q=$(bedrock_sysconfig_sh_quote "$pkg")
    case "$pm" in
        apt)     cmd="apt-cache show $q 2>/dev/null | head -80" ;;
        apk)     cmd="apk info -a $q 2>/dev/null | head -80" ;;
        pacman)  cmd="pacman -Si $q 2>/dev/null | head -80" ;;
        dnf)     cmd="dnf -q info $q 2>/dev/null | head -80" ;;
        yum)     cmd="yum -q info $q 2>/dev/null | head -80" ;;
        zypper)  cmd="zypper --non-interactive --no-refresh info $q 2>/dev/null | head -80" ;;
        xbps)    cmd="xbps-query -RS $q 2>/dev/null | head -80" ;;
        emerge)  cmd="emerge --search $q 2>/dev/null | head -80" ;;
        opkg)    cmd="opkg info $q 2>/dev/null | head -80" ;;
        *) return 1 ;;
    esac
    printf '\n===== Bedrock: %s [%s] =====\n' "$st" "$pm"
    "$brl" strat -r "$st" /bin/sh -lc "$cmd" 2>/dev/null || true
}

pkg_show_info() {
    local pkg="$1" st
    printf '===== Host: %s =====\n' "$PM"
    _systui_native_pkg_show_info "$pkg" 2>&1 || true
    bedrock_sysconfig_active || return 0
    while IFS= read -r st; do
        [ -n "$st" ] || continue
        bedrock_sysconfig_pkg_available "$st" "$pkg" || continue
        bedrock_sysconfig_info_one "$st" "$pkg"
    done <<< "$(bedrock_sysconfig_strata)"
}

return 0 2>/dev/null || true
