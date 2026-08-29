# shellcheck shell=bash
###############################################################################
# ROOTFS — iSH-safe Debian package configuration
#
# Debian package postinst scripts for systemd/dbus/openssh expect procfs and
# related virtual filesystems to exist, and often attempt to start services.
# iSH-AOK cannot run those service starts normally. Wrap the normal Debian
# package installer so package configuration happens with the rootfs virtual
# filesystems prepared and service starts suppressed. If the install itself
# returns non-zero after unpacking, repair the runtime scaffolding and retry
# pending dpkg configuration before declaring the package stage failed.
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

_rootfs_ish_pkg_policy_force() { # <target>
    local p="$1/usr/sbin/policy-rc.d"
    mkdir -p "$1/usr/sbin" || return 1
    cat >"$p" <<'EOF'
#!/bin/sh
exit 101
EOF
    chmod 0755 "$p"
}

_rootfs_ish_pkg_policy_cleanup() { # <target> <created>
    [ "${2:-0}" = 1 ] || return 0
    rm -f -- "$1/usr/sbin/policy-rc.d" 2>/dev/null || true
}

_rootfs_ish_pkg_runtime_prepare() { # <target>
    local t="$1" mid
    mkdir -p "$t/run" "$t/run/dbus" "$t/run/systemd" "$t/run/sshd" \
             "$t/var/lib/dbus" "$t/etc" "$t/tmp" || return 1

    # systemd/dbus maintainer scripts expect a stable machine-id. Do not invoke
    # systemd-machine-id-setup here: on iSH it may probe kernel facilities that
    # are incomplete. Generate a valid 32-hex identifier if one is absent.
    if [ ! -s "$t/etc/machine-id" ]; then
        if command -v od >/dev/null 2>&1 && [ -r /dev/urandom ]; then
            mid=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
        else
            mid=$(printf '%032x' "$$" 2>/dev/null || true)
        fi
        case "$mid" in
           ????????????????????????????????) printf '%s\n' "$mid" >"$t/etc/machine-id" ;;
            *) printf '00000000000000000000000000000001\n' >"$t/etc/machine-id" ;;
        esac
        chmod 0444 "$t/etc/machine-id" 2>/dev/null || true
    fi

    if [ ! -e "$t/var/lib/dbus/machine-id" ]; then
        ln -s /etc/machine-id "$t/var/lib/dbus/machine-id" 2>/dev/null || \
            cp -f "$t/etc/machine-id" "$t/var/lib/dbus/machine-id" 2>/dev/null || true
    fi

    # Debian treats /var/run as /run. Minimal bootstrap trees can lack it.
    if [ ! -e "$t/var/run" ]; then
        ln -s /run "$t/var/run" 2>/dev/null || mkdir -p "$t/var/run"
    fi
    return 0
}

_rootfs_ish_pkg_repair() { # <target>
    local t="$1"

    # The base installer creates and then unconditionally removes policy-rc.d.
    # Recreate it before *every* recovery pass so postinst scripts cannot start
    # systemd, dbus, sshd, cron, or other daemons inside iSH/chroot.
    _rootfs_ish_pkg_policy_force "$t" || return 1
    _rootfs_ish_pkg_runtime_prepare "$t" || return 1

    if declare -F rootfs_chroot_exec >/dev/null 2>&1; then
        rootfs_chroot_exec "$t" "Repair iSH package configuration" \
            "export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true SYSTEMD_OFFLINE=1 SYSTEMD_IN_CHROOT=1 SYSTEMD_IGNORE_CHROOT=1; mkdir -p /run/dbus /run/systemd /run/sshd /var/lib/dbus; dpkg --configure -a; rc=\$?; [ \$rc -eq 0 ] || true; apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confold -f install -y; apt_rc=\$?; dpkg --configure -a; final_rc=\$?; [ \$final_rc -eq 0 ] && [ \$apt_rc -eq 0 ]"
        return $?
    fi

    command -v chroot >/dev/null 2>&1 || return 1
    chroot "$t" /bin/sh -c \
        'export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true SYSTEMD_OFFLINE=1 SYSTEMD_IN_CHROOT=1 SYSTEMD_IGNORE_CHROOT=1; mkdir -p /run/dbus /run/systemd /run/sshd /var/lib/dbus; dpkg --configure -a || true; apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confold -f install -y || exit $?; dpkg --configure -a'
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

    _rootfs_ish_pkg_runtime_prepare "$t" || warn "rootfs: could not fully prepare package runtime directories"
    policy_created=$(_rootfs_ish_pkg_policy_prepare "$t" 2>/dev/null || echo 0)

    # The underlying installer performs the requested apt install normally.
    if SYSTEMD_OFFLINE=1 SYSTEMD_IN_CHROOT=1 SYSTEMD_IGNORE_CHROOT=1 \
       DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
        _systui_base_rootfs_install_deb_packages_ishpkg "$t" "$pkgs"; then
        rc=0
    else
        rc=$?
        warn "rootfs: package install returned $rc; repairing pending systemd/dbus/sshd package configuration"

        # The base installer removes policy-rc.d on return, so recreate the
        # service guard here before retrying any maintainer scripts.
        if _rootfs_ish_pkg_repair "$t"; then
            rc=0
        fi
    fi

    _rootfs_ish_pkg_policy_cleanup "$t" "$policy_created"

    if [ "$owned_mounts" = 1 ] && declare -F rootfs_unmount_chroot_fs >/dev/null 2>&1; then
        rootfs_unmount_chroot_fs "$t" "${ROOTFS_ACTIVE_MOUNTS:-}" >/dev/null 2>&1 || true
    fi

    return "$rc"
}

export -f _rootfs_ish_host _rootfs_ish_pkg_policy_prepare _rootfs_ish_pkg_policy_force \
    _rootfs_ish_pkg_policy_cleanup _rootfs_ish_pkg_runtime_prepare _rootfs_ish_pkg_repair \
    rootfs_install_deb_packages
