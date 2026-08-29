# shellcheck shell=bash
###############################################################################
# MULTI-INSTALL OPTIMIZER
#
# Prefer the fastest native installation path for checklist installers:
# resolve every selected tool to a distro package, install the whole set in one
# package-manager invocation, then use upstream/special installers only for
# selections still missing afterward.
###############################################################################

systui_multi_dedupe_packages() {
    local p seen=' '
    for p in "$@"; do
        [ -n "$p" ] || continue
        case "$seen" in
            *" $p "*) ;;
            *) printf '%s\n' "$p"; seen+="$p " ;;
        esac
    done
}

systui_multi_native_install() { # <packages...>
    local -a pkgs=() unique=()
    local p
    pkgs=("$@")
    [ "${#pkgs[@]}" -gt 0 ] || return 0
    while IFS= read -r p; do
        [ -n "$p" ] && unique+=("$p")
    done < <(systui_multi_dedupe_packages "${pkgs[@]}")
    [ "${#unique[@]}" -gt 0 ] || return 0
    pm_install "${unique[@]}"
}

# ---------------------------------------------------------------------------
# Rootfs -> Distro Managers
# ---------------------------------------------------------------------------
rootfs_dm_install_multiple_managers() {
    local tag bin label selected pkg
    local -a opts=() packages=() fallback=()

    while IFS='|' read -r tag bin label; do
        [ -n "$tag" ] || continue
        if rootfs_dm_available "$tag"; then
            opts+=("$tag" "$label — installed" off)
        else
            pkg=$(rootfs_dm_package "$tag" 2>/dev/null || true)
            if [ -n "$pkg" ]; then
                opts+=("$tag" "$label — native package: $pkg" off)
            else
                opts+=("$tag" "$label — upstream/special install" off)
            fi
        fi
    done <<< "$(rootfs_dm_managers)"

    selected=$(tui_check "Install distro managers" \
        "SPACE selects managers; ENTER batches all native packages into one install command, then handles only remaining upstream installs." \
        "${opts[@]}") || return 0
    selected=${selected//\"/}
    [ -n "${selected//[[:space:]]/}" ] || return 0

    for tag in $selected; do
        rootfs_dm_available "$tag" && continue
        pkg=$(rootfs_dm_package "$tag" 2>/dev/null || true)
        if [ -n "$pkg" ]; then
            packages+=("$pkg")
        else
            fallback+=("$tag")
        fi
    done

    [ "${#packages[@]}" -eq 0 ] || systui_multi_native_install "${packages[@]}" || true

    # Re-check every selected manager. A failed/missing native package now goes
    # through the existing upstream installer rather than being retried one by
    # one through the native PM.
    for tag in $selected; do
        rootfs_dm_available "$tag" && continue
        case "$tag" in
            proot-distro|chroot-distro|distrobox|udocker)
                rootfs_dm_install_upstream "$tag" || true ;;
            *)
                # No portable upstream installer exists. The batched pm_install
                # already performed refresh/repository recovery, so skip here.
                fallback+=("$tag") ;;
        esac
    done

    if [ "${#fallback[@]}" -gt 0 ]; then
        tui_msg "Multi-install complete" \
            "Native packages were installed in one batch. Any remaining tools without a portable upstream installer were skipped: ${fallback[*]}"
    fi
}

# ---------------------------------------------------------------------------
# Rootfs -> Bootstrap Tools
# ---------------------------------------------------------------------------
systui_bootstrap_catalogue() {
    printf '%s\n' \
        'debootstrap|debootstrap' \
        'mmdebstrap|mmdebstrap' \
        'cdebootstrap|cdebootstrap' \
        'multistrap|multistrap' \
        'qemu-user-static|qemu-user-static' \
        'binfmt-support|binfmt-support' \
        'arch-install-scripts|pacstrap / arch-install-scripts' \
        'schroot|schroot' \
        'chroot-distro|chroot-distro' \
        'systemd-container|systemd-nspawn / systemd-container' \
        'rinse|rinse' \
        'proot|proot' \
        'fakechroot|fakechroot' \
        'fakeroot|fakeroot' \
        'xbps-tools|xbps-install / xbps-tools' \
        'dnf|dnf' \
        'zypper|zypper' \
        'zstd|zstd' \
        'xz-utils|xz / xz-utils'
}

systui_bootstrap_package() { # <tag>
    case "$1" in
        arch-install-scripts) printf 'arch-install-scripts\n' ;;
        systemd-container) printf 'systemd-container\n' ;;
        xbps-tools) printf 'xbps-tools\n' ;;
        xz-utils)
            case "${PM:-}" in apk) printf 'xz\n' ;; *) printf 'xz-utils\n' ;; esac ;;
        chroot-distro) return 1 ;;
        *) printf '%s\n' "$1" ;;
    esac
}

systui_bootstrap_multi_install() {
    local tag label selected state pkg
    local -a opts=() packages=() specials=()

    while IFS='|' read -r tag label; do
        [ -n "$tag" ] || continue
        if rootfs_bs_installed "$tag"; then
            state='installed'
        elif pkg=$(systui_bootstrap_package "$tag" 2>/dev/null); then
            state="native package: $pkg"
        else
            state='upstream/special install'
        fi
        opts+=("$tag" "$label — $state" off)
    done <<< "$(systui_bootstrap_catalogue)"

    selected=$(tui_check "Install bootstrap tools" \
        "SPACE selects tools; ENTER installs all native packages together using the active package manager." \
        "${opts[@]}") || return 0
    selected=${selected//\"/}
    [ -n "${selected//[[:space:]]/}" ] || return 0

    for tag in $selected; do
        rootfs_bs_installed "$tag" && continue
        pkg=$(systui_bootstrap_package "$tag" 2>/dev/null || true)
        if [ -n "$pkg" ]; then packages+=("$pkg"); else specials+=("$tag"); fi
    done

    [ "${#packages[@]}" -eq 0 ] || systui_multi_native_install "${packages[@]}" || true

    # Only genuinely non-native tools use upstream installation after the fast
    # batch. chroot-distro is the current Python upstream project.
    for tag in "${specials[@]}"; do
        rootfs_bs_installed "$tag" && continue
        case "$tag" in
            chroot-distro)
                if declare -F rootfs_dm_install_upstream >/dev/null 2>&1; then
                    rootfs_dm_install_upstream chroot-distro || true
                fi ;;
        esac
    done
}

# Keep the existing comprehensive bootstrap configuration menu available, but
# make the multi-installer a dedicated fast path so its behavior is predictable.
if declare -F menu_rootfs_bootstrap_tools >/dev/null 2>&1 \
    && ! declare -F _systui_single_menu_rootfs_bootstrap_tools >/dev/null 2>&1; then
    eval "$(declare -f menu_rootfs_bootstrap_tools | sed '1s/^menu_rootfs_bootstrap_tools[[:space:]]*()/_systui_single_menu_rootfs_bootstrap_tools ()/')"
fi

menu_rootfs_bootstrap_tools() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Rootfs Bootstrap Tools" \
            "Install several bootstrap tools in one native package-manager command, or open the existing individual tool menu:" \
            multi "Install multiple tools (SPACE to select)" \
            single "Manage individual bootstrap tools" \
            back "Back") || return 0
        case "$c" in
            multi) systui_bootstrap_multi_install ;;
            single) _systui_single_menu_rootfs_bootstrap_tools ;;
            back|"") return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
