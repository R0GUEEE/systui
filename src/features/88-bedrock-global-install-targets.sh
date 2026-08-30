# shellcheck shell=bash
# PHASE 88 — global Bedrock-aware installation targets.
#
# Keep existing installation menus intact on non-Bedrock systems.  When
# Bedrock is installed, software installer entry-points gain a host/stratum
# target picker.  Stratum installs use that stratum's native package manager;
# host-only vendor/source fallbacks are never run against a selected stratum.

systui_bedrock_install_active() {
    [ -d /bedrock/strata ] || return 1
    if declare -F bedrock_systui_is_installed >/dev/null 2>&1; then
        bedrock_systui_is_installed
    elif declare -F bedrock_aok_brl >/dev/null 2>&1; then
        bedrock_aok_brl >/dev/null 2>&1
    else
        command -v brl >/dev/null 2>&1 || [ -x /bedrock/bin/brl ]
    fi
}

systui_bedrock_install_strata() {
    local st p
    if declare -F bedrock_systui_strata >/dev/null 2>&1; then
        bedrock_systui_strata
        return
    fi
    [ -d /bedrock/strata ] || return 0
    for p in /bedrock/strata/*; do
        [ -d "$p" ] || continue
        st=${p##*/}
        case "$st" in ''|.*|bedrock) continue ;; esac
        printf '%s\n' "$st"
    done | LC_ALL=C sort -u
}

systui_bedrock_stratum_has_cmd() { # <stratum> <command>
    local st="$1" cmd="$2" root p
    root="/bedrock/strata/$st"
    for p in bin sbin usr/bin usr/sbin usr/local/bin usr/local/sbin nix/var/nix/profiles/default/bin; do
        [ -x "$root/$p/$cmd" ] && return 0
    done
    return 1
}

systui_bedrock_stratum_pm() { # <stratum>
    local st="$1" rst rpm class cfg pm
    # Prefer the capability scanner's system-manager classification.
    if declare -F bedrock_systui_capability_rows >/dev/null 2>&1; then
        while IFS='|' read -r rst rpm class cfg; do
            [ "$rst" = "$st" ] || continue
            [ "$class" = system ] || continue
            case "$rpm" in apt|apk|pacman|dnf|yum|zypper|xbps|emerge|opkg|nix)
                printf '%s\n' "$rpm"; return 0 ;;
            esac
        done <<< "$(bedrock_systui_capability_rows)"
    fi
    for pm in apt apk pacman dnf yum zypper xbps-install emerge opkg nix; do
        systui_bedrock_stratum_has_cmd "$st" "$pm" || continue
        [ "$pm" = xbps-install ] && pm=xbps
        printf '%s\n' "$pm"
        return 0
    done
    return 1
}

systui_bedrock_install_target_menu() { # [thing]
    local thing="${1:-software}" st pm picked
    local -a opts=(host "Host system [${PM:-native}]" on)
    systui_bedrock_install_active || { printf 'host\n'; return 0; }
    while IFS= read -r st; do
        [ -n "$st" ] || continue
        pm=$(systui_bedrock_stratum_pm "$st" 2>/dev/null || printf 'unknown')
        opts+=("stratum:$st" "Bedrock stratum: $st [$pm]" off)
    done <<< "$(systui_bedrock_install_strata)"
    [ "${#opts[@]}" -gt 3 ] || { printf 'host\n'; return 0; }
    picked=$(tui_radio "Install target — $thing" \
        "Choose where this installation should be performed (SPACE selects):" \
        "${opts[@]}") || return 1
    printf '%s\n' "$picked"
}

systui_bedrock_pkg_name() { # <pm> <canonical>
    local pm="$1" canonical="$2"
    canonical=${canonical//_/-}
    case "$pm:$canonical" in
        apt:go) printf 'golang-go\n' ;;
        apt:node) printf 'nodejs\n' ;;
        apt:pip|apt:pip3) printf 'python3-pip\n' ;;
        apt:gem) printf 'ruby\n' ;;
        apt:docker) printf 'docker.io\n' ;;
        apt:snap) printf 'snapd\n' ;;
        apk:node) printf 'nodejs\n' ;;
        apk:pip|apk:pip3) printf 'py3-pip\n' ;;
        apk:gem) printf 'ruby\n' ;;
        apk:docker) printf 'docker\n' ;;
        pacman:node) printf 'nodejs\n' ;;
        pacman:pip|pacman:pip3) printf 'python-pip\n' ;;
        pacman:gem) printf 'ruby\n' ;;
        dnf:go|yum:go|zypper:go) printf 'golang\n' ;;
        dnf:node|yum:node|zypper:node) printf 'nodejs\n' ;;
        dnf:pip|dnf:pip3|yum:pip|yum:pip3|zypper:pip|zypper:pip3) printf 'python3-pip\n' ;;
        dnf:gem|yum:gem|zypper:gem) printf 'ruby\n' ;;
        dnf:docker|yum:docker) printf 'moby-engine\n' ;;
        xbps:node) printf 'nodejs\n' ;;
        xbps:pip|xbps:pip3) printf 'python3-pip\n' ;;
        xbps:gem) printf 'ruby\n' ;;
        emerge:node) printf 'net-libs/nodejs\n' ;;
        emerge:pip|emerge:pip3) printf 'dev-python/pip\n' ;;
        emerge:gem) printf 'dev-lang/ruby\n' ;;
        emerge:docker) printf 'app-containers/docker\n' ;;
        nix:*) printf 'nixpkgs#%s\n' "$canonical" ;;
        *:aptfast) printf 'apt-fast\n' ;;
        *:python) printf 'python3\n' ;;
        *:neovim) printf 'neovim\n' ;;
        *:ripgrep) printf 'ripgrep\n' ;;
        *:starship) printf 'starship\n' ;;
        *:nushell) printf 'nushell\n' ;;
        *:micro) printf 'micro\n' ;;
        *:fzf) printf 'fzf\n' ;;
        *:cargo) printf 'cargo\n' ;;
        *:rust) printf 'rust\n' ;;
        *:flatpak) printf 'flatpak\n' ;;
        *:zsh) printf 'zsh\n' ;;
        *:fish) printf 'fish\n' ;;
        *:git) printf 'git\n' ;;
        *:curl) printf 'curl\n' ;;
        *:wget) printf 'wget\n' ;;
        *:tmux) printf 'tmux\n' ;;
        *:nano) printf 'nano\n' ;;
        *:vim) printf 'vim\n' ;;
        *:openssh|*:ssh) printf 'openssh\n' ;;
        *:npm) printf 'npm\n' ;;
        *:pnpm) printf 'pnpm\n' ;;
        *:yarn) printf 'yarn\n' ;;
        *:composer) printf 'composer\n' ;;
        *:pipx) printf 'pipx\n' ;;
        *:nala) printf 'nala\n' ;;
        *:aptitude) printf 'aptitude\n' ;;
        *:*) printf '%s\n' "$canonical" ;;
    esac
}

systui_bedrock_pm_install_cmd() { # <pm> <package>
    local pm="$1" pkg="$2"
    case "$pm" in
        apt) printf 'DEBIAN_FRONTEND=noninteractive apt-get install -y -- %q' "$pkg" ;;
        apk) printf 'apk add -- %q' "$pkg" ;;
        pacman) printf 'pacman -S --noconfirm --needed -- %q' "$pkg" ;;
        dnf) printf 'dnf install -y -- %q' "$pkg" ;;
        yum) printf 'yum install -y -- %q' "$pkg" ;;
        zypper) printf 'zypper --non-interactive install -- %q' "$pkg" ;;
        xbps) printf 'xbps-install -Sy -- %q' "$pkg" ;;
        emerge) printf 'emerge --ask=n %q' "$pkg" ;;
        opkg) printf 'opkg install %q' "$pkg" ;;
        nix) printf 'nix profile install %q' "$pkg" ;;
        *) return 1 ;;
    esac
}

systui_bedrock_exec_stratum() { # <stratum> <command>
    local st="$1" cmd="$2" brl
    if declare -F bedrock_systui_exec >/dev/null 2>&1; then
        bedrock_systui_exec "$st" "$cmd"
        return
    fi
    if declare -F bedrock_aok_brl >/dev/null 2>&1; then brl=$(bedrock_aok_brl) || return 1
    else brl=$(command -v brl 2>/dev/null || true); fi
    [ -n "$brl" ] || return 1
    "$brl" strat -r "$st" /bin/sh -lc "$cmd"
}

systui_bedrock_install_canonical() { # <stratum> <canonical>
    local st="$1" canonical="$2" pm pkg cmd
    pm=$(systui_bedrock_stratum_pm "$st" 2>/dev/null || true)
    [ -n "$pm" ] || {
        tui_msg "Install unavailable" "No supported system package manager was detected in Bedrock stratum '$st'."
        return 1
    }
    pkg=$(systui_bedrock_pkg_name "$pm" "$canonical") || return 1
    cmd=$(systui_bedrock_pm_install_cmd "$pm" "$pkg") || {
        tui_msg "Install unavailable" "Systui has no safe installation mapping for '$canonical' through $pm in '$st'."
        return 1
    }
    tui_yesno "Install in $st" "Install '$canonical' in Bedrock stratum '$st' using $pm?\n\nResolved package: $pkg" || return 0
    if run_cmd "Install $canonical in Bedrock stratum $st [$pm]" systui_bedrock_exec_stratum "$st" "$cmd"; then
        declare -F bedrock_systui_scan_capabilities >/dev/null 2>&1 && bedrock_systui_scan_capabilities >/dev/null 2>&1 || true
        return 0
    fi
    return 1
}

systui_bedrock_wrap_install_menu() { # <function>
    local fn="$1" saved def canonical
    case "$fn" in _*|systui_*|bedrock_*|rootfs_*|menu_bedrock_*|menu_rootfs_*) return 0 ;; esac
    declare -F "$fn" >/dev/null 2>&1 || return 0
    saved="_systui_bedrock_target_original_${fn}"
    declare -F "$saved" >/dev/null 2>&1 && return 0
    canonical=${fn#menu_}; canonical=${canonical%_install}
    [ -n "$canonical" ] || return 0
    def=$(declare -f "$fn") || return 1
    def=${def/#$fn ()/$saved ()}
    def=${def/#$fn()/$saved()}
    eval "$def"
    eval "$fn() { local _target; if ! systui_bedrock_install_active; then $saved \"\$@\"; return; fi; _target=\$(systui_bedrock_install_target_menu '$canonical') || return 0; case \"\$_target\" in host|'') $saved \"\$@\" ;; stratum:*) systui_bedrock_install_canonical \"\${_target#stratum:}\" '$canonical' ;; esac; }"
}

# Wrap every loaded software menu_<thing>_install entry point.  This catches
# current and future shell/editor/tool/package-manager installers without a
# manually-maintained list. Rootfs and Bedrock installation workflows are
# explicitly excluded because their target is structural, not a package root.
while read -r _ _flag _systui_install_fn; do
    case "$_systui_install_fn" in menu_*_install) systui_bedrock_wrap_install_menu "$_systui_install_fn" ;; esac
done < <(declare -F)
unset _flag _systui_install_fn

# The multi-package-manager installer is not named menu_*_install. Give it the
# same host/stratum target behavior while retaining its native host workflow.
if declare -F sysconfig_pm_multi_install >/dev/null 2>&1 \
    && ! declare -F _systui_bedrock_target_original_sysconfig_pm_multi_install >/dev/null 2>&1; then
    eval "$(declare -f sysconfig_pm_multi_install | sed '1s/^sysconfig_pm_multi_install[[:space:]]*()/_systui_bedrock_target_original_sysconfig_pm_multi_install ()/')"
    systui_bedrock_stratum_multi_pm_install() { # <stratum>
        local st="$1" selected tag cmd label
        local -a opts=()
        while IFS='|' read -r tag cmd label; do
            [ -n "$tag" ] || continue
            opts+=("$tag" "$label" off)
        done <<< "$(sysconfig_pm_multi_catalogue)"
        selected=$(tui_check "Install package managers in $st" \
            "SPACE selects managers; ENTER installs them in Bedrock stratum '$st'." \
            "${opts[@]}") || return 0
        selected=${selected//\"/}
        for tag in $selected; do systui_bedrock_install_canonical "$st" "$tag" || true; done
    }
    sysconfig_pm_multi_install() {
        local target
        if ! systui_bedrock_install_active; then
            _systui_bedrock_target_original_sysconfig_pm_multi_install "$@"
            return
        fi
        target=$(systui_bedrock_install_target_menu "package managers") || return 0
        case "$target" in
            host|'') _systui_bedrock_target_original_sysconfig_pm_multi_install "$@" ;;
            stratum:*) systui_bedrock_stratum_multi_pm_install "${target#stratum:}" ;;
        esac
    }
fi

return 0 2>/dev/null || true
