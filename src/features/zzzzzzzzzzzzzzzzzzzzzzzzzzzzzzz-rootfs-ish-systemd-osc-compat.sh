# shellcheck shell=bash
###############################################################################
# ROOTFS BUILDER — iSH-AOK systemd shell OSC compatibility
###############################################################################

rootfs_ish_patch_systemd_osc_profile() { # <target>
    local t="$1" profile tmp

    for profile in \
        "$t/usr/lib/profile.d/80-systemd-osc-context.sh" \
        "$t/etc/profile.d/80-systemd-osc-context.sh"
    do
        [ -f "$profile" ] || continue
        grep -q 'SYSTUI_ISH_OSC_PROCFS_GUARD' "$profile" 2>/dev/null && continue

        tmp="$profile.systui-tmp.$$"
        {
            cat <<'EOF'
# SYSTUI_ISH_OSC_PROCFS_GUARD
# systemd's OSC shell integration expects Linux procfs UUID interfaces that
# iSH-AOK does not implement. Disable only this optional prompt integration
# when those interfaces are absent; normal Linux kernels continue unchanged.
if [ ! -r /proc/sys/kernel/random/uuid ] || [ ! -r /proc/sys/kernel/random/boot_id ]; then
    return 0 2>/dev/null || exit 0
fi
EOF
            cat "$profile"
        } > "$tmp" || { rm -f "$tmp"; return 1; }
        cat "$tmp" > "$profile" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
        log "rootfs: guarded systemd OSC procfs probes for iSH-AOK in $profile"
    done
}

# Add the procfs compatibility guard whenever the systemd compatibility layer
# is installed or refreshed, including fresh builds, Workbench repair and the
# final pre-pack archive verification path.
if declare -F rootfs_install_ish_systemd_compat >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_install_ish_systemd_compat_osc >/dev/null 2>&1; then
    eval "$(declare -f rootfs_install_ish_systemd_compat | sed '1s/^rootfs_install_ish_systemd_compat[[:space:]]*()/_systui_base_rootfs_install_ish_systemd_compat_osc ()/')"
fi

rootfs_install_ish_systemd_compat() {
    local t="$1" rc=0
    _systui_base_rootfs_install_ish_systemd_compat_osc "$@" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    rootfs_ish_patch_systemd_osc_profile "$t" || {
        warn "Could not install the iSH-AOK systemd OSC procfs compatibility guard."
        return 1
    }
}

export -f rootfs_ish_patch_systemd_osc_profile rootfs_install_ish_systemd_compat
