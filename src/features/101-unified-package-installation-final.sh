# shellcheck shell=bash
###############################################################################
# PHASE 101 — unified package installation routing
###############################################################################

systui_package_manager_registry() {
    printf '%s\n' \
        'native|Native system package manager' \
        'apt|APT' 'apt-fast|apt-fast' 'nala|Nala' 'aptitude|Aptitude' \
        'apk|APK' 'pacman|Pacman' 'dnf|DNF' 'yum|YUM' 'zypper|Zypper' 'xbps|XBPS' 'emerge|Portage' \
        'flatpak|Flatpak' 'snap|Snap' \
        'pip|pip' 'pipx|pipx' 'npm|npm' 'pnpm|pnpm' 'yarn|Yarn' 'cargo|Cargo' 'gem|RubyGems' 'composer|Composer' 'go|Go' \
        'yay|yay' 'paru|paru' 'nix|Nix' 'brew|Homebrew/Linuxbrew'
}

systui_package_manager_command() {
    case "$1" in
        native) printf '%s\n' "${PM:-unknown}" ;;
        apt) printf 'apt-get\n' ;; apt-fast) printf 'apt-fast\n' ;; nala) printf 'nala\n' ;; aptitude) printf 'aptitude\n' ;;
        apk) printf 'apk\n' ;; pacman) printf 'pacman\n' ;; dnf) printf 'dnf\n' ;; yum) printf 'yum\n' ;; zypper) printf 'zypper\n' ;; xbps) printf 'xbps-install\n' ;; emerge) printf 'emerge\n' ;;
        flatpak) printf 'flatpak\n' ;; snap) printf 'snap\n' ;; pip) command -v pip3 >/dev/null 2>&1 && printf 'pip3\n' || printf 'pip\n' ;;
        pipx) printf 'pipx\n' ;; npm) printf 'npm\n' ;; pnpm) printf 'pnpm\n' ;; yarn) printf 'yarn\n' ;; cargo) printf 'cargo\n' ;; gem) printf 'gem\n' ;; composer) printf 'composer\n' ;; go) printf 'go\n' ;;
        yay) printf 'yay\n' ;; paru) printf 'paru\n' ;; nix) printf 'nix\n' ;; brew) printf 'brew\n' ;;
        *) return 1 ;;
    esac
}

systui_package_manager_available() {
    local tag="$1" cmd
    [ "$tag" = native ] && [ "${PM:-unknown}" != unknown ] && return 0
    cmd=$(systui_package_manager_command "$tag" 2>/dev/null || true)
    [ -n "$cmd" ] && command -v "$cmd" >/dev/null 2>&1
}

systui_package_install_with() { # <manager> <packages...>
    local manager="$1"; shift
    [ "$#" -gt 0 ] || return 0
    case "$manager" in
        native) pm_install "$@" ;;
        apt) run_cmd "APT install $*" apt-get install -y -- "$@" ;;
        apt-fast) run_cmd "apt-fast install $*" apt-fast install -y -- "$@" ;;
        nala) run_cmd "Nala install $*" nala install -y -- "$@" ;;
        aptitude) run_cmd "Aptitude install $*" aptitude install -y -- "$@" ;;
        apk) run_cmd "APK add $*" apk add -- "$@" ;;
        pacman) run_cmd "Pacman install $*" pacman -S --noconfirm --needed -- "$@" ;;
        dnf) run_cmd "DNF install $*" dnf install -y -- "$@" ;;
        yum) run_cmd "YUM install $*" yum install -y -- "$@" ;;
        zypper) run_cmd "Zypper install $*" zypper --non-interactive install -- "$@" ;;
        xbps) run_cmd "XBPS install $*" xbps-install -y -- "$@" ;;
        emerge) run_cmd "Portage install $*" emerge --ask=n -- "$@" ;;
        flatpak) run_cmd "Flatpak install $*" flatpak install -y --noninteractive flathub "$@" ;;
        snap) run_cmd "Snap install $*" snap install "$@" ;;
        pip) run_cmd "pip install $*" "$(systui_package_manager_command pip)" install "$@" ;;
        pipx) for _p in "$@"; do run_cmd "pipx install $_p" pipx install "$_p" || return 1; done ;;
        npm) run_cmd "npm install $*" npm install -g "$@" ;;
        pnpm) run_cmd "pnpm install $*" pnpm add -g "$@" ;;
        yarn) run_cmd "Yarn install $*" yarn global add "$@" ;;
        cargo) run_cmd "Cargo install $*" cargo install "$@" ;;
        gem) run_cmd "RubyGems install $*" gem install "$@" ;;
        composer) run_cmd "Composer global require $*" composer global require "$@" ;;
        go) for _p in "$@"; do run_cmd "Go install $_p" go install "$_p" || return 1; done ;;
        yay) run_cmd "yay install $*" yay -S --noconfirm --needed -- "$@" ;;
        paru) run_cmd "paru install $*" paru -S --noconfirm --needed -- "$@" ;;
        nix) run_cmd "Nix install $*" nix profile install "$@" ;;
        brew) run_cmd "Homebrew install $*" brew install "$@" ;;
        *) return 2 ;;
    esac
}

systui_package_remove_with() { # <manager> <packages...>
    local manager="$1"; shift
    [ "$#" -gt 0 ] || return 0
    case "$manager" in
        native) pm_remove "$@" ;;
        apt) run_cmd "APT remove $*" apt-get remove -y -- "$@" ;;
        apt-fast) run_cmd "apt-fast remove $*" apt-fast remove -y -- "$@" ;;
        nala) run_cmd "Nala remove $*" nala remove -y -- "$@" ;;
        aptitude) run_cmd "Aptitude remove $*" aptitude remove -y -- "$@" ;;
        apk) run_cmd "APK del $*" apk del -- "$@" ;;
        pacman|yay|paru) run_cmd "Remove $*" "$(systui_package_manager_command "$manager")" -Rns --noconfirm -- "$@" ;;
        dnf|yum) run_cmd "Remove $*" "$manager" remove -y -- "$@" ;;
        zypper) run_cmd "Zypper remove $*" zypper --non-interactive remove -- "$@" ;;
        xbps) run_cmd "XBPS remove $*" xbps-remove -Ry -- "$@" ;;
        emerge) run_cmd "Portage remove $*" emerge --ask=n --unmerge "$@" ;;
        flatpak) run_cmd "Flatpak uninstall $*" flatpak uninstall -y --noninteractive "$@" ;;
        snap) run_cmd "Snap remove $*" snap remove "$@" ;;
        pip) run_cmd "pip uninstall $*" "$(systui_package_manager_command pip)" uninstall -y "$@" ;;
        pipx) for _p in "$@"; do run_cmd "pipx uninstall $_p" pipx uninstall "$_p" || return 1; done ;;
        npm) run_cmd "npm uninstall $*" npm uninstall -g "$@" ;;
        pnpm) run_cmd "pnpm remove $*" pnpm remove -g "$@" ;;
        yarn) run_cmd "Yarn remove $*" yarn global remove "$@" ;;
        cargo) run_cmd "Cargo uninstall $*" cargo uninstall "$@" ;;
        gem) run_cmd "RubyGems uninstall $*" gem uninstall -aIx "$@" ;;
        brew) run_cmd "Homebrew uninstall $*" brew uninstall "$@" ;;
        *) return 2 ;;
    esac
}

systui_package_manager_picker() {
    local tag label cmd state
    local -a opts=()
    while IFS='|' read -r tag label; do
        [ -n "$tag" ] || continue
        if systui_package_manager_available "$tag"; then
            cmd=$(systui_package_manager_command "$tag" 2>/dev/null || true)
            state=${cmd:-available}
            opts+=("$tag" "$label [$state]")
        fi
    done <<< "$(systui_package_manager_registry)"
    [ "${#opts[@]}" -gt 0 ] || return 1
    tui_menu_no_tags "Package manager" "Choose the package manager/ecosystem to use:" "${opts[@]}" back "Back"
}

systui_unified_install_menu() {
    local manager input
    local -a pkgs=()
    manager=$(systui_package_manager_picker) || return 0
    [ "$manager" != back ] && [ -n "$manager" ] || return 0
    input=$(tui_input "Install with $manager" "Package/application name(s), space separated:" "") || return 0
    [ -n "${input//[[:space:]]/}" ] || return 0
    if declare -F parse_package_input >/dev/null 2>&1; then
        parse_package_input "$input" pkgs || return 1
    else
        read -r -a pkgs <<< "$input"
    fi
    systui_package_install_with "$manager" "${pkgs[@]}" || tui_msg "Package install" "Installation through $manager failed. Review the Systui log."
}

systui_unified_remove_menu() {
    local manager input
    local -a pkgs=()
    manager=$(systui_package_manager_picker) || return 0
    [ "$manager" != back ] && [ -n "$manager" ] || return 0
    input=$(tui_input "Remove with $manager" "Package/application name(s), space separated:" "") || return 0
    [ -n "${input//[[:space:]]/}" ] || return 0
    read -r -a pkgs <<< "$input"
    tui_yesno "Remove packages" "Remove with $manager?\n\n${pkgs[*]}" || return 0
    systui_package_remove_with "$manager" "${pkgs[@]}" || tui_msg "Package removal" "Removal through $manager failed. Review the Systui log."
}

if declare -F menu_package_operations >/dev/null 2>&1 \
    && ! declare -F _systui_package_operations_before_unified >/dev/null 2>&1; then
    _systui_pkgops_def=$(declare -f menu_package_operations)
    _systui_pkgops_def=${_systui_pkgops_def/#menu_package_operations ()/_systui_package_operations_before_unified ()}
    _systui_pkgops_def=${_systui_pkgops_def/#menu_package_operations()/_systui_package_operations_before_unified()}
    eval "$_systui_pkgops_def"
    unset _systui_pkgops_def
fi

menu_package_operations() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Package operations" \
            "Unified package installation across native, universal, language and user package managers:" \
            install "Install packages — choose package manager" \
            remove "Remove packages — choose package manager" \
            collections "Install curated software collections" \
            native "Native package operations — search, update, hold, clean, info" \
            managers "Install/configure package managers" \
            catalogue "Software catalogue" \
            back "Back") || return 0
        case "$c" in
            install) systui_unified_install_menu ;;
            remove) systui_unified_remove_menu ;;
            collections) catalogue_collections ;;
            native) [ -n "$(declare -F _systui_package_operations_before_unified 2>/dev/null)" ] && _systui_package_operations_before_unified ;;
            managers) menu_package_managers ;;
            catalogue) pkg_catalogue ;;
            back|'') return 0 ;;
        esac
    done
}

# Collections remain logical/native package sets so distro-specific app_native_name
# mapping and repository recovery are preserved, but expose the unified installer
# as the common collection backend entrypoint.
systui_install_collection_packages() {
    pm_install "$@"
}

return 0 2>/dev/null || true
