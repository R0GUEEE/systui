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

rootfs_ish_make_safe_shell() { # <target>
    local t="$1"
    mkdir -p "$t/usr/local/sbin"
    cat > "$t/usr/local/sbin/systui-ish-safe-shell" <<'EOF'
#!/bin/sh
# Ubuntu Resolute may provide essential coreutils through uutils/rust-coreutils.
# On iSH-AOK those binaries can panic while rustix reads the auxiliary vector.
# Enter bash without profile/rc processing so no external coreutils are invoked
# before the user reaches a prompt.
if [ -x /bin/bash ]; then
    exec /bin/bash --noprofile --norc
fi
exec /bin/sh
EOF
    chmod 0755 "$t/usr/local/sbin/systui-ish-safe-shell"
}

# Preserve the workbench enter implementation, then add an iSH-only safety pass.
if declare -F rootfs_wb_enter >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_wb_enter >/dev/null 2>&1; then
    eval "$(declare -f rootfs_wb_enter | sed '1s/^rootfs_wb_enter[[:space:]]*()/_systui_base_rootfs_wb_enter ()/')"
fi

rootfs_wb_enter() { # <target>
    local t="$1" old_shell="" safe_shell=0 rc=0

    if declare -F rootfs_wb_is_ish_kernel >/dev/null 2>&1 && rootfs_wb_is_ish_kernel; then
        # Apply the safe shell BEFORE running any in-rootfs repair command.
        # apt/dpkg maintainer scripts can invoke Rust coreutils too, so trying
        # to repair first can panic before Workbench ever reaches the shell.
        if rootfs_ish_target_needs_safe_shell "$t"; then
            old_shell=$(rootfs_chroot_option_get "$t" SHELL /bin/bash)
            rootfs_ish_make_safe_shell "$t"
            rootfs_chroot_option_set "$t" SHELL /usr/local/sbin/systui-ish-safe-shell >/dev/null 2>&1 || true
            safe_shell=1
        fi

        # Install/update the systemd compatibility files using host-side file
        # operations only. Skip the package-provider migration here; that is a
        # build-time concern and can itself execute the broken coreutils.
        if [ -x "$t/lib/systemd/systemd" ] || [ -x "$t/usr/lib/systemd/systemd" ] || \
           [ -e "$t/etc/systui/ish-systemd-compat.conf" ]; then
            SYSTUI_ISH_COMPAT_SKIP_COREUTILS_MIGRATION=1 rootfs_install_ish_systemd_compat "$t" || true
        fi
    fi

    _systui_base_rootfs_wb_enter "$t" || rc=$?

    if [ "$safe_shell" = 1 ]; then
        rootfs_chroot_option_set "$t" SHELL "$old_shell" >/dev/null 2>&1 || true
    fi
    return "$rc"
}

export -f rootfs_ish_target_release rootfs_ish_target_needs_safe_shell rootfs_ish_make_safe_shell rootfs_wb_enter
