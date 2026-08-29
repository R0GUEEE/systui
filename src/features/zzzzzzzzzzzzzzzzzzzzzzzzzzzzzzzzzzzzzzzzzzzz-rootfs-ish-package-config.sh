# shellcheck shell=bash
###############################################################################
# ROOTFS — iSH-safe Debian package configuration
#
# Debian package postinst scripts for systemd/dbus/openssh expect procfs and
# related virtual filesystems to exist, and often attempt to start services.
# iSH-AOK cannot run those service starts normally. Wrap the normal Debian
# package installer so package configuration happens with the rootfs virtual
# filesystems prepared and service starts suppressed. If the install itself
# returns non-zero after unpacking, retry dpkg configuration once before
# declaring the package stage failed.
###############################################################################

_rootfs_ish_host() {
    case "${SYSTUI_ISH_AOK:-}" in 1|yes|true) return 0 ;; esac
    case "${container:-}" in *ish*|*iSH*) return 0 ;; esac
    command -v uname >/dev/null 2>&1 || return 1
    case "$(uname -r 2>/dev/null) $(uname -a 2>/dev/null)" in
        *-ish*|*ish_aok*|*iSH-AOK*|*iSH*) return 0 ;;
    esac
    return 1
}

_rootfs_ish_pkg_policy_prepare() { # <target> -> prints 1 if created
    local t="$1" p="$1/usr/sbin/policy-rc.d"
    mkdir -p "$t/usr/sbin" || return 1
    if [ -e "$p" ]; then
        printf '0\n'
        return 0
    fi
    cat >"$p" <<'EOF'
#!/bin/sh
# Systui/iSH package configuration: packages may register services but must not
# attempt to start them while the rootfs is being built.
exit 101
EOF
    chmod 0755 "$p" || return 1
    printf '1\n'
}

_rootfs_ish_pkg_policy_cleanup() { # <target> <created>
    [ "${2:-0}" = 1 ] || return 0
    rm -f -- "$1/usr/sbin/policy-rc.d" 2>/dev/null || true
}

if declare -F rootfs_install_deb_packages >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_install_deb_packages_ishpkg >/dev/null 2>&1; then
    eval "$(declare -f rootfs_install_deb_packages | sed '1s/^rootfs_install_deb_packages[[:space:]]*()/_systui_base_rootfs_install_deb_packages_ishpkg ()/')"
fi

rootfs_install_deb_packages() { # <target> <space-separated packages>
    local t="$1" pkgs="$2" initial_mounts=0 owned_mounts=0 policy_created=0 rc=0

    # Non-iSH hosts retain the original behavior exactly.
    if ! _rootfs_ish_host; then
        _systui_base_rootfs_install_deb_packages_ishpkg "$@"
        return $?
    fi

    # Package maintainer scripts need functional /proc, /sys and /dev. Reuse
    # Systui's rootfs mount helper, which already contains iSH-specific fallbacks.
    if declare -F rootfs_wb_mount_count >/dev/null 2>&1; then
        initial_mounts=$(rootfs_wb_mount_count "$t" 2>/dev/null || echo 0)
    fi
    if [ "${initial_mounts:-0}" -eq 0 ] && declare -F rootfs_mount_chroot_fs >/dev/null 2>&1; then
        if rootfs_mount_chroot_fs "$t"; then
            owned_mounts=1
        else
            warn "rootfs: could not fully prepare virtual filesystems before package configuration"
        fi
    fi

    policy_created=$(_rootfs_ish_pkg_policy_prepare "$t" 2>/dev/null || echo 0)

    # The underlying installer performs the requested apt install normally.
    # Service startup is blocked by policy-rc.d while package files and service
    # definitions are still installed as usual.
    if SYSTEMD_OFFLINE=1 DEBIAN_FRONTEND=noninteractive \
        _systui_base_rootfs_install_deb_packages_ishpkg "$t" "$pkgs"; then
        rc=0
    else
        rc=$?
        warn "rootfs: package install returned $rc; retrying pending dpkg configuration in iSH-safe mode"

        # Most failures at this point are postinst failures after packages were
        # already unpacked. Give dpkg one deterministic recovery pass while the
        # virtual filesystems and policy-rc.d guard are still active.
        if declare -F rootfs_chroot_exec >/dev/null 2>&1; then
            if rootfs_chroot_exec "$t" "Repair iSH package configuration" \
                "export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true SYSTEMD_OFFLINE=1; dpkg --configure -a && apt-get -f install -y"; then
                rc=0
            fi
        elif command -v chroot >/dev/null 2>&1; then
            chroot "$t" /bin/sh -c \
                'export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true SYSTEMD_OFFLINE=1; dpkg --configure -a && apt-get -f install -y' && rc=0
        fi
    fi

    _rootfs_ish_pkg_policy_cleanup "$t" "$policy_created"

    if [ "$owned_mounts" = 1 ] && declare -F rootfs_unmount_chroot_fs >/dev/null 2>&1; then
        rootfs_unmount_chroot_fs "$t" "${ROOTFS_ACTIVE_MOUNTS:-}" >/dev/null 2>&1 || true
    fi

    return "$rc"
}

export -f _rootfs_ish_host _rootfs_ish_pkg_policy_prepare _rootfs_ish_pkg_policy_cleanup rootfs_install_deb_packages
