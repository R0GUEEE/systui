# shellcheck shell=bash
###############################################################################
# ROOTFS WORKBENCH — repair existing iSH systemd roots before entering
###############################################################################

rootfs_ish_target_has_rust_coreutils() { # <target>
    local t="$1"
    [ -r "$t/var/lib/dpkg/status" ] || return 1
    grep -qE '^Package: (rust-coreutils|coreutils-from-uutils)$' "$t/var/lib/dpkg/status" 2>/dev/null
}

rootfs_ish_make_safe_shell() { # <target>
    local t="$1"
    mkdir -p "$t/usr/local/sbin"
    cat > "$t/usr/local/sbin/systui-ish-safe-shell" <<'EOF'
#!/bin/sh
# Ignore login-shell flags: Ubuntu Resolute's /etc/profile can invoke uutils
# commands such as id/uname before GNU coreutils is installed, which panics on
# iSH-AOK's incomplete auxv implementation.
if [ -x /bin/bash ]; then
    exec /bin/bash --noprofile --norc
fi
exec /bin/sh
EOF
    chmod 0755 "$t/usr/local/sbin/systui-ish-safe-shell"
}

# Preserve the workbench enter implementation, then add an iSH-only repair pass.
if declare -F rootfs_wb_enter >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_wb_enter >/dev/null 2>&1; then
    eval "$(declare -f rootfs_wb_enter | sed '1s/^rootfs_wb_enter[[:space:]]*()/_systui_base_rootfs_wb_enter ()/')"
fi

rootfs_wb_enter() { # <target>
    local t="$1" old_shell="" safe_shell=0 rc=0

    if declare -F rootfs_wb_is_ish_kernel >/dev/null 2>&1 && rootfs_wb_is_ish_kernel; then
        # Existing roots built before the compatibility fix are repaired in
        # place, including replacing Ubuntu's uutils provider with GNU coreutils
        # when the package is available.
        if [ -x "$t/lib/systemd/systemd" ] || [ -x "$t/usr/lib/systemd/systemd" ] || \
           [ -e "$t/etc/systui/ish-systemd-compat.conf" ]; then
            rootfs_install_ish_systemd_compat "$t" || true
        fi

        # If Rust/uutils coreutils remain, do not source /etc/profile yet: that
        # path commonly invokes id/uname and can panic before the prompt.
        if rootfs_ish_target_has_rust_coreutils "$t"; then
            old_shell=$(rootfs_chroot_option_get "$t" SHELL /bin/bash)
            rootfs_ish_make_safe_shell "$t"
            rootfs_chroot_option_set "$t" SHELL /usr/local/sbin/systui-ish-safe-shell >/dev/null 2>&1 || true
            safe_shell=1
        fi
    fi

    _systui_base_rootfs_wb_enter "$t" || rc=$?

    if [ "$safe_shell" = 1 ]; then
        rootfs_chroot_option_set "$t" SHELL "$old_shell" >/dev/null 2>&1 || true
    fi
    return "$rc"
}

export -f rootfs_ish_target_has_rust_coreutils rootfs_ish_make_safe_shell rootfs_wb_enter
