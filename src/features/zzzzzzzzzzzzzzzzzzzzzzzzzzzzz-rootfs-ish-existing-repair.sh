# shellcheck shell=bash
###############################################################################
# ROOTFS WORKBENCH — repair existing iSH systemd roots before entering
###############################################################################

rootfs_ish_target_release() { # <target> -> ID|VERSION_CODENAME|VERSION_ID
    local t="$1" key value id="" codename="" version=""
    [ -r "$t/etc/os-release" ] || return 1
    while IFS='=' read -r key value; do
        value=${value#\"}; value=${value%\"}
        case "$key" in
            ID) id="$value" ;;
            VERSION_CODENAME) codename="$value" ;;
            VERSION_ID) version="$value" ;;
        esac
    done < "$t/etc/os-release"
    printf '%s|%s|%s\n' "$id" "$codename" "$version"
}

rootfs_ish_target_needs_safe_shell() { # <target>
    local t="$1" release
    release=$(rootfs_ish_target_release "$t" 2>/dev/null || true)
    case "$release" in
        ubuntu\|resolute\|*|ubuntu\|\|26.04*) return 0 ;;
    esac
    [ -r "$t/var/lib/dpkg/status" ] || return 1
    grep -qE '^Package: (rust-coreutils|coreutils-from-uutils)$' "$t/var/lib/dpkg/status" 2>/dev/null
}

# Ubuntu's gnu-coreutils package installs GNU implementations under gnu-prefixed
# names (gnucat, gnuid, gnuuname, ...). The uutils provider depends on that
# package, so a broken Resolute root normally already has the safe binaries.
# Switch the public command names to them entirely from the HOST; this does not
# execute a single binary from the damaged chroot and lets dpkg maintainer
# scripts run again on iSH-AOK.
rootfs_ish_activate_gnu_coreutils() { # <target>
    local t="$1" src name dest count=0
    [ -x "$t/usr/bin/gnucat" ] || return 1

    for src in "$t"/usr/bin/gnu*; do
        [ -e "$src" ] || continue
        name=${src##*/}
        name=${name#gnu}
        [ -n "$name" ] || continue
        dest="$t/usr/bin/$name"
        rm -f -- "$dest" 2>/dev/null || continue
        ln -s "gnu$name" "$dest" 2>/dev/null || continue
        count=$((count + 1))
    done

    if [ -x "$t/usr/sbin/gnuchroot" ]; then
        rm -f -- "$t/usr/sbin/chroot" 2>/dev/null || true
        ln -s gnuchroot "$t/usr/sbin/chroot" 2>/dev/null || true
    fi

    [ "$count" -gt 0 ] || return 1
    mkdir -p "$t/etc/systui"
    printf 'provider=gnu-coreutils\nreason=ish-aok-rust-coreutils-auxv\n' > "$t/etc/systui/coreutils-compat.conf"
    log "rootfs: activated $count GNU coreutils command links in $t for iSH-AOK"
    return 0
}

# Preserve the workbench enter implementation, then add an iSH-only safety pass.
if declare -F rootfs_wb_enter >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_wb_enter >/dev/null 2>&1; then
    eval "$(declare -f rootfs_wb_enter | sed '1s/^rootfs_wb_enter[[:space:]]*()/_systui_base_rootfs_wb_enter ()/')"
fi

rootfs_wb_enter() { # <target>
    local t="$1" rc=0

    # Workbench interactive sessions always use Bash. The iSH-AOK Resolute
    # repair below fixes the problematic Rust coreutils command links before
    # Bash is launched, so a wrapper shell is no longer exposed to the user.
    if [ -x "$t/bin/bash" ]; then
        rootfs_chroot_option_set "$t" SHELL /bin/bash >/dev/null 2>&1 || true
    fi

    if declare -F rootfs_wb_is_ish_kernel >/dev/null 2>&1 && rootfs_wb_is_ish_kernel; then
        if rootfs_ish_target_needs_safe_shell "$t"; then
            # Repair command links entirely from the host before entering the
            # rootfs so Bash startup cannot hit the incompatible Rust tools.
            rootfs_ish_activate_gnu_coreutils "$t" >/dev/null 2>&1 || true
        fi

        if [ -x "$t/lib/systemd/systemd" ] || [ -x "$t/usr/lib/systemd/systemd" ] || \
           [ -e "$t/etc/systui/ish-systemd-compat.conf" ]; then
            SYSTUI_ISH_COMPAT_SKIP_COREUTILS_MIGRATION=1 rootfs_install_ish_systemd_compat "$t" || true
        fi
    fi

    _systui_base_rootfs_wb_enter "$t" || rc=$?
    return "$rc"
}

export -f rootfs_ish_target_release rootfs_ish_target_needs_safe_shell rootfs_ish_activate_gnu_coreutils rootfs_wb_enter
