# shellcheck shell=bash
###############################################################################
# SYSTEM CONFIGURATION — PACKAGE MANAGER MULTI-INSTALL / UNINSTALL
###############################################################################

if declare -F menu_package_managers >/dev/null 2>&1 \
    && ! declare -F _systui_single_menu_package_managers >/dev/null 2>&1; then
    eval "$(declare -f menu_package_managers | sed '1s/^menu_package_managers[[:space:]]*()/_systui_single_menu_package_managers ()/')"
fi

sysconfig_pm_multi_catalogue() {
    printf '%s\n' \
        'aptfast|apt-fast|apt-fast' 'nala|nala|Nala' 'aptitude|aptitude|aptitude' \
        'flatpak|flatpak|Flatpak' 'snap|snap|Snap' 'pip|pip3|pip' 'pipx|pipx|pipx' \
        'npm|npm|npm' 'pnpm|pnpm|pnpm' 'yarn|yarn|Yarn' 'cargo|cargo|Cargo' \
        'gem|gem|RubyGems' 'composer|composer|Composer' 'go|go|Go' \
        'yay|yay|yay' 'paru|paru|paru' 'nix|nix|Nix' 'brew|brew|Homebrew/Linuxbrew'
}

sysconfig_pm_multi_package() {
    case "$1" in
        aptfast) [ "${PM:-}" = apt ] && printf 'apt-fast\n' ;;
        nala) [ "${PM:-}" = apt ] && printf 'nala\n' ;;
        aptitude) [ "${PM:-}" = apt ] && printf 'aptitude\n' ;;
        flatpak) printf 'flatpak\n' ;; snap) printf 'snapd\n' ;;
        pip) case "${PM:-}" in apk) printf 'py3-pip\n';; pacman) printf 'python-pip\n';; *) printf 'python3-pip\n';; esac ;;
        pipx) case "${PM:-}" in pacman) printf 'python-pipx\n';; apk) printf 'py3-pipx\n';; *) printf 'pipx\n';; esac ;;
        npm) printf 'npm\n' ;; cargo) printf 'cargo\n' ;; gem) printf 'ruby\n' ;; composer) printf 'composer\n' ;;
        go) case "${PM:-}" in apt) printf 'golang-go\n';; dnf|yum|zypper) printf 'golang\n';; *) printf 'go\n';; esac ;;
        *) return 1 ;;
    esac
}

sysconfig_pm_multi_special_installer() {
    case "$1" in yay) printf 'menu_yay_install\n';; paru) printf 'menu_paru_install\n';; nix) printf 'menu_nix_install\n';; brew) printf 'menu_brew_install\n';; *) return 1;; esac
}

sysconfig_pm_multi_install() {
    local tag cmd label state selected pkg fn p
    local -a opts=() packages=() npm_globals=() specials=() dedup=()
    while IFS='|' read -r tag cmd label; do
        [ -n "$tag" ] || continue
        if command -v "$cmd" >/dev/null 2>&1; then state='installed'
        elif sysconfig_pm_multi_package "$tag" >/dev/null 2>&1; then state='not installed'
        elif sysconfig_pm_multi_special_installer "$tag" >/dev/null 2>&1; then state='not installed — upstream installer'
        elif [ "$tag" = pnpm ] || [ "$tag" = yarn ]; then state='not installed — npm global install'
        else state='not available for this distro'; fi
        opts+=("$tag" "$label — $state" off)
    done <<< "$(sysconfig_pm_multi_catalogue)"
    selected=$(tui_check "Install package managers" "SPACE selects managers; ENTER installs selected missing managers." "${opts[@]}") || return 0
    selected=${selected//\"/}; [ -n "${selected//[[:space:]]/}" ] || return 0
    for tag in $selected; do
        while IFS='|' read -r p cmd label; do [ "$p" = "$tag" ] || continue; command -v "$cmd" >/dev/null 2>&1 && continue 2; break; done <<< "$(sysconfig_pm_multi_catalogue)"
        case "$tag" in pnpm|yarn) npm_globals+=("$tag");; yay|paru|nix|brew) specials+=("$tag");; *) pkg=$(sysconfig_pm_multi_package "$tag" 2>/dev/null || true); [ -n "$pkg" ] && packages+=("$pkg");; esac
    done
    if [ "${#packages[@]}" -gt 0 ]; then
        for pkg in "${packages[@]}"; do case " ${dedup[*]} " in *" $pkg "*) ;; *) dedup+=("$pkg");; esac; done
        [ "${#dedup[@]}" -eq 0 ] || pm_install "${dedup[@]}" || true
    fi
    if [ "${#npm_globals[@]}" -gt 0 ]; then
        command -v npm >/dev/null 2>&1 || pm_install npm || true
        command -v npm >/dev/null 2>&1 && run_cmd "Install npm package managers: ${npm_globals[*]}" npm install -g "${npm_globals[@]}" || true
    fi
    for tag in "${specials[@]}"; do fn=$(sysconfig_pm_multi_special_installer "$tag" 2>/dev/null || true); [ -n "$fn" ] && declare -F "$fn" >/dev/null 2>&1 && "$fn" || true; done
}

sysconfig_pm_multi_uninstall() {
    local tag cmd label selected pkg p
    local -a opts=() packages=() npm_globals=() dedup=()
    while IFS='|' read -r tag cmd label; do
        [ -n "$tag" ] || continue
        command -v "$cmd" >/dev/null 2>&1 || continue
        opts+=("$tag" "$label — installed" off)
    done <<< "$(sysconfig_pm_multi_catalogue)"
    if [ "${#opts[@]}" -eq 0 ]; then tui_msg "Package Managers" "No removable package managers from the catalogue were detected."; return 0; fi
    selected=$(tui_check "Uninstall package managers" "SPACE selects installed managers; ENTER removes all selected managers." "${opts[@]}") || return 0
    selected=${selected//\"/}; [ -n "${selected//[[:space:]]/}" ] || return 0
    for tag in $selected; do
        case "$tag" in
            pnpm|yarn) npm_globals+=("$tag") ;;
            yay|paru)
                pkg=$(sysconfig_pm_multi_package "$tag" 2>/dev/null || true)
                [ -n "$pkg" ] && packages+=("$pkg") || { command -v "$tag" >/dev/null 2>&1 && run_cmd "Uninstall $tag" "$tag" -Rns --noconfirm "$tag" || true; }
                ;;
            nix)
                tui_msg "Nix" "Nix uses a standalone multi-user/single-user installation. Use its individual package-manager menu for a safe removal."
                ;;
            brew)
                tui_msg "Homebrew" "Homebrew uses a standalone installation. Use its individual package-manager menu for a safe removal."
                ;;
            *) pkg=$(sysconfig_pm_multi_package "$tag" 2>/dev/null || true); [ -n "$pkg" ] && packages+=("$pkg") ;;
        esac
    done
    if [ "${#npm_globals[@]}" -gt 0 ] && command -v npm >/dev/null 2>&1; then
        run_cmd "Uninstall npm package managers: ${npm_globals[*]}" npm uninstall -g "${npm_globals[@]}" || true
    fi
    if [ "${#packages[@]}" -gt 0 ]; then
        for pkg in "${packages[@]}"; do case " ${dedup[*]} " in *" $pkg "*) ;; *) dedup+=("$pkg");; esac; done
        [ "${#dedup[@]}" -eq 0 ] || pm_remove "${dedup[@]}" || true
    fi
}

menu_package_managers() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Package Managers" "Install, uninstall, or configure package managers:" \
            install "Install package managers (SPACE to select)" \
            uninstall "Uninstall package managers (SPACE to select)" \
            single "Configure individual package managers" back "Back") || return 0
        case "$c" in install) sysconfig_pm_multi_install;; uninstall) sysconfig_pm_multi_uninstall;; single) _systui_single_menu_package_managers;; back|"") return 0;; esac
    done
}

return 0 2>/dev/null || true
