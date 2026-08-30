# shellcheck shell=bash
# PHASE 77 — host-native installation policy.
#
# Every general install path should prefer the package manager of the current
# host. Specialized GitHub/source/vendor installers remain fallbacks when the
# native package is unavailable or the native install fails.

systui_host_pm() {
    if declare -F systui_detect_pm >/dev/null 2>&1; then
        systui_detect_pm >/dev/null 2>&1 || true
    elif declare -F detect_pm >/dev/null 2>&1; then
        detect_pm >/dev/null 2>&1 || true
    fi
    printf '%s\n' "${PM:-}"
}

systui_native_pkg_name() { # <canonical-tool>
    local canonical="$1" pm mapped='' fields=''
    pm=$(systui_host_pm)

    # Explicit distro-family mappings for names that differ from the canonical
    # Systui tool name. SKIP means there is no dependable native package and the
    # specialized installer should be used instead.
    case "$pm:$canonical" in
        apt:go) mapped=golang-go ;;
        apt:rust) mapped=rustc ;;
        apt:node) mapped=nodejs ;;
        apt:pip) mapped=python3-pip ;;
        apt:gem) mapped=ruby ;;
        apt:docker) mapped=docker.io ;;
        apt:snap) mapped=snapd ;;
        apk:node) mapped=nodejs ;;
        apk:pip) mapped=py3-pip ;;
        apk:gem) mapped=ruby ;;
        apk:docker) mapped=docker ;;
        apk:snap) mapped=SKIP ;;
        pacman:node) mapped=nodejs ;;
        pacman:pip) mapped=python-pip ;;
        pacman:gem) mapped=ruby ;;
        pacman:docker) mapped=docker ;;
        pacman:snap) mapped=snapd ;;
        dnf:go|yum:go) mapped=golang ;;
        dnf:node|yum:node) mapped=nodejs ;;
        dnf:pip|yum:pip) mapped=python3-pip ;;
        dnf:gem|yum:gem) mapped=ruby ;;
        dnf:docker|yum:docker) mapped=moby-engine ;;
        dnf:snap|yum:snap) mapped=snapd ;;
        zypper:node) mapped=nodejs ;;
        zypper:pip) mapped=python3-pip ;;
        zypper:gem) mapped=ruby ;;
        zypper:docker) mapped=docker ;;
        xbps:node) mapped=nodejs ;;
        xbps:pip) mapped=python3-pip ;;
        xbps:gem) mapped=ruby ;;
        xbps:docker) mapped=docker ;;
        emerge:node) mapped=net-libs/nodejs ;;
        emerge:pip) mapped=dev-python/pip ;;
        emerge:gem) mapped=dev-lang/ruby ;;
        emerge:docker) mapped=app-containers/docker ;;
        *:brew|*:yay|*:paru) mapped=SKIP ;;
    esac

    if [ -z "$mapped" ] && declare -p PKG_MAP >/dev/null 2>&1 && [ -n "${PKG_MAP[$canonical]:-}" ]; then
        fields=${PKG_MAP[$canonical]}
        case "$pm" in
            apk) set -- $fields; mapped=${1:-SKIP} ;;
            pacman) set -- $fields; mapped=${2:-SKIP} ;;
            dnf|yum) set -- $fields; mapped=${3:-SKIP} ;;
            xbps) set -- $fields; mapped=${4:-SKIP} ;;
        esac
    fi

    [ -n "$mapped" ] || mapped=$canonical
    [ "$mapped" != SKIP ] || return 1
    printf '%s\n' "$mapped"
}

systui_native_package_available() { # <native-package>
    local pkg="$1" pm
    pm=$(systui_host_pm)
    case "$pm" in
        apt)
            dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' && return 0
            apt-cache show "$pkg" >/dev/null 2>&1
            ;;
        apk)
            apk info -e "$pkg" >/dev/null 2>&1 && return 0
            apk search -x "$pkg" 2>/dev/null | grep -q .
            ;;
        pacman)
            pacman -Q "$pkg" >/dev/null 2>&1 || pacman -Si "$pkg" >/dev/null 2>&1
            ;;
        dnf)
            rpm -q "$pkg" >/dev/null 2>&1 || dnf -q list --available "$pkg" >/dev/null 2>&1
            ;;
        yum)
            rpm -q "$pkg" >/dev/null 2>&1 || yum -q list available "$pkg" >/dev/null 2>&1
            ;;
        xbps)
            xbps-query -p pkgver "$pkg" >/dev/null 2>&1 || xbps-query -Rs "^${pkg}-[0-9]" 2>/dev/null | grep -q .
            ;;
        # zypper and Portage searches do not have a consistently useful exit
        # status across supported releases. Let the native installer attempt the
        # package directly, then fall back if it fails.
        zypper|emerge) return 0 ;;
        *) return 1 ;;
    esac
}

systui_native_install() { # <canonical-tool>
    local canonical="$1" pkg pm
    pm=$(systui_host_pm)
    [ -n "$pm" ] || return 1
    pkg=$(systui_native_pkg_name "$canonical") || return 1
    systui_native_package_available "$pkg" || return 1

    if declare -F is_pkg_installed >/dev/null 2>&1 && is_pkg_installed "$pkg"; then
        return 0
    fi
    declare -F pm_install >/dev/null 2>&1 || return 1
    pm_install "$pkg"
}

systui_install_native_first() { # <canonical-tool> <fallback-function> [args...]
    local canonical="$1" fallback="$2" pm pkg
    shift 2
    pm=$(systui_host_pm)
    pkg=$(systui_native_pkg_name "$canonical" 2>/dev/null || true)

    if [ -n "$pkg" ]; then
        log "install policy: prefer host-native $pm package '$pkg' for '$canonical'"
        if systui_native_install "$canonical"; then
            return 0
        fi
        log "install policy: native $pm install unavailable/failed for '$canonical'; using specialized fallback"
    else
        log "install policy: no dependable native $pm package for '$canonical'; using specialized fallback"
    fi

    declare -F "$fallback" >/dev/null 2>&1 || return 127
    "$fallback" "$@"
}

systui_wrap_native_installer() { # <function> <canonical-tool>
    local fn="$1" canonical="$2" saved def
    declare -F "$fn" >/dev/null 2>&1 || return 0
    saved="_systui_native_fallback_${fn}"
    declare -F "$saved" >/dev/null 2>&1 && return 0

    def=$(declare -f "$fn") || return 1
    def=${def/#$fn ()/$saved ()}
    def=${def/#$fn()/$saved()}
    eval "$def"
    eval "$fn() { systui_install_native_first '$canonical' '$saved' \"\$@\"; }"
}

# Specialized installers that historically prompted for GitHub/vendor/source
# methods before trying the host package manager. Native package management is
# now the default for each when the host repository provides the tool.
systui_wrap_native_installer menu_nix_install nix
systui_wrap_native_installer menu_cargo_install cargo
systui_wrap_native_installer menu_npm_install npm
systui_wrap_native_installer menu_pnpm_install pnpm
systui_wrap_native_installer menu_yarn_install yarn
systui_wrap_native_installer menu_gem_install gem
systui_wrap_native_installer menu_composer_install composer
systui_wrap_native_installer menu_go_install go
systui_wrap_native_installer menu_pipx_install pipx
systui_wrap_native_installer menu_pip_install pip
systui_wrap_native_installer menu_flatpak_install flatpak
systui_wrap_native_installer menu_snap_install snap
systui_wrap_native_installer menu_starship_install starship
systui_wrap_native_installer menu_zsh_install zsh
systui_wrap_native_installer menu_fish_install fish
systui_wrap_native_installer menu_neovim_install neovim
systui_wrap_native_installer menu_micro_install micro
systui_wrap_native_installer menu_fzf_install fzf
systui_wrap_native_installer menu_docker_install docker
systui_wrap_native_installer menu_node_install node
systui_wrap_native_installer menu_ripgrep_install ripgrep
systui_wrap_native_installer menu_nushell_install nushell

export -n -f systui_host_pm systui_native_pkg_name systui_native_package_available \
    systui_native_install systui_install_native_first systui_wrap_native_installer 2>/dev/null || true
return 0 2>/dev/null || true
