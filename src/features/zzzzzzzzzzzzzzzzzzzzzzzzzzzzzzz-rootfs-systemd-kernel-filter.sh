# shellcheck shell=bash
###############################################################################
# ROOTFS BUILDER — guarantee selected systemd + skip host-kernel packages
###############################################################################

rootfs_pkg_is_unsupported_kernel() { # <package>
    case "$1" in
        linux-image|linux-image-*|linux-headers|linux-headers-*|linux-modules|linux-modules-*|linux-generic|linux-generic-*|linux-virtual|linux-virtual-*|linux-lowlatency|linux-lowlatency-*|linux-oem-*|linux-raspi|linux-raspi-*|linux-kvm|linux-kvm-*|linux-aws|linux-aws-*|linux-azure|linux-azure-*|linux-gcp|linux-gcp-*|kernel|kernel-core|kernel-core-*|kernel-modules|kernel-modules-*|kernel-modules-core|kernel-modules-core-*|kernel-devel|kernel-devel-*|kernel-headers|kernel-headers-*|kernel-default|kernel-default-*|kernel-lts|kernel-lts-*|kernel-vanilla|kernel-vanilla-*|kernel-longterm|kernel-longterm-*)
            return 0 ;;
    esac
    return 1
}

rootfs_filter_unsupported_kernel_packages() { # <space-separated packages>
    local pkg out=""
    for pkg in $1; do
        if rootfs_pkg_is_unsupported_kernel "$pkg"; then
            log "rootfs: skipping unsupported kernel package: $pkg"
            continue
        fi
        out="${out:+$out }$pkg"
    done
    printf '%s\n' "$out"
}

rootfs_append_exclude_pkg() { # <current> <package>
    local current="$1" pkg="$2"
    case " $current " in
        *" $pkg "*) printf '%s\n' "$current" ;;
        *) printf '%s\n' "${current:+$current }$pkg" ;;
    esac
}

# Rootfs images use the host/iSH kernel. Do not let Debian-family bootstrap
# select common kernel meta packages that cannot be booted from inside a chroot.
if declare -F build_debfamily >/dev/null 2>&1 && \
   ! declare -F _systui_systemd_base_build_debfamily >/dev/null 2>&1; then
    eval "$(declare -f build_debfamily | sed '1s/^build_debfamily[[:space:]]*()/_systui_systemd_base_build_debfamily ()/')"
fi

build_debfamily() {
    local saved_exclude="${ROOTFS_BACKEND_EXCLUDE:-}" rc=0 pkg
    for pkg in \
        linux-image-generic linux-headers-generic linux-generic \
        linux-image-arm64 linux-headers-arm64 \
        linux-image-amd64 linux-headers-amd64 \
        linux-image-cloud-arm64 linux-image-cloud-amd64 \
        linux-virtual linux-image-virtual linux-headers-virtual; do
        ROOTFS_BACKEND_EXCLUDE=$(rootfs_append_exclude_pkg "${ROOTFS_BACKEND_EXCLUDE:-}" "$pkg")
    done
    _systui_systemd_base_build_debfamily "$@" || rc=$?
    ROOTFS_BACKEND_EXCLUDE="$saved_exclude"
    return "$rc"
}

rootfs_ensure_systemd_selected() { # <target> <distro>
    local target="$1" distro="$2"

    # Already installed: avoid unnecessary package-manager work.
    if [ -x "$target/lib/systemd/systemd" ] || [ -x "$target/usr/lib/systemd/systemd" ]; then
        return 0
    fi

    log "rootfs: systemd selected; installing systemd into $target"
    case "$distro" in
        debian|ubuntu|kali|bedrock)
            rootfs_install_deb_packages "$target" "systemd systemd-sysv" || return 1
            ;;
        arch)
            in_chroot "$target" pacman -S --needed --noconfirm systemd || return 1
            ;;
        fedora)
            in_chroot "$target" dnf -y install systemd || return 1
            ;;
        opensuse|tumbleweed)
            in_chroot "$target" zypper --non-interactive install systemd || return 1
            ;;
        *)
            # Distro-specific stage3/base images (for example Gentoo systemd)
            # may already provide systemd without a generic installer path.
            warn "systemd was selected for $distro, but Systui has no automatic package installer for that distro."
            return 1
            ;;
    esac

    [ -x "$target/lib/systemd/systemd" ] || [ -x "$target/usr/lib/systemd/systemd" ] || {
        warn "systemd package installation completed but no systemd executable exists in $target"
        return 1
    }
}

# Wrap the final postconfig layer. Filter user/preset kernel packages before the
# canonical postconfig sees them, then install systemd before the existing iSH
# compatibility wrapper creates and verifies the direct /sbin/init entrypoint.
if declare -F rootfs_postconfig >/dev/null 2>&1 && \
   ! declare -F _systui_systemd_base_rootfs_postconfig >/dev/null 2>&1; then
    eval "$(declare -f rootfs_postconfig | sed '1s/^rootfs_postconfig[[:space:]]*()/_systui_systemd_base_rootfs_postconfig ()/')"
fi

rootfs_postconfig() {
    local target="$1" distro="$2" init_choice="$5" filtered_pkgs rc=0
    local -a args=("$@")

    filtered_pkgs=$(rootfs_filter_unsupported_kernel_packages "${14:-}")
    args[13]="$filtered_pkgs"

    if [ "$init_choice" = systemd ]; then
        rootfs_ensure_systemd_selected "$target" "$distro" || {
            warn "Could not install the selected systemd init system into the new rootfs."
            return 1
        }
    fi

    _systui_systemd_base_rootfs_postconfig "${args[@]}" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    if [ "$init_choice" = systemd ]; then
        [ -x "$target/sbin/init" ] || {
            warn "systemd rootfs completed without executable /sbin/init"
            return 1
        }
    fi
    return 0
}

export -f rootfs_pkg_is_unsupported_kernel rootfs_filter_unsupported_kernel_packages \
    rootfs_append_exclude_pkg rootfs_ensure_systemd_selected build_debfamily rootfs_postconfig
