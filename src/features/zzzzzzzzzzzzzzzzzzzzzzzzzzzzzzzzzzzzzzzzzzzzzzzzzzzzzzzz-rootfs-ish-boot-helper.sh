# shellcheck shell=bash
###############################################################################
# iSH-AOK boot helper hardening
#
# systemd cannot be launched as a system manager unless it is PID 1, and a
# systemd user manager requires XDG_RUNTIME_DIR plus the usual kernel/runtime
# facilities. iSH-AOK rootfs sessions generally provide neither. Make
# systui-boot route iSH sessions through the compatibility supervisor instead
# of forwarding systemd's --system/--user modes to the real systemd binary.
###############################################################################

sysconfig_write_ish_safe_boot_helper() {
    local helper="${SYSCONFIG_BOOT_HELPER:-/usr/local/sbin/systui-boot}"
    mkdir -p "$(dirname "$helper")" /etc/systui || return 1

    cat > "$helper" <<'EOF'
#!/bin/sh
cfg=/etc/systui/boot-command
cmd='/sbin/init'
[ -r "$cfg" ] && IFS= read -r cmd < "$cfg"
[ -n "$cmd" ] || cmd='/sbin/init'

is_ish_aok() {
    v=''
    r=''
    a=''
    [ -r /proc/version ] && IFS= read -r v < /proc/version 2>/dev/null || true
    case "$v" in *-ish*|*ish_aok*|*iSH-AOK*|*iSH*) return 0 ;; esac
    [ -e /proc/ish ] && return 0
    if command -v uname >/dev/null 2>&1; then
        r=$(uname -r 2>/dev/null || true)
        a=$(uname -a 2>/dev/null || true)
        case "$r $a" in *-ish*|*ish_aok*|*iSH-AOK*|*iSH*) return 0 ;; esac
    fi
    case "${container:-} ${SYSTUI_ISH_AOK:-}" in *ish-aok*|*iSH-AOK*|*yes*) return 0 ;; esac
    return 1
}

# iSH-AOK cannot run the real systemd system manager from an ordinary shell
# and its user manager is not useful as a boot replacement. Always route boot
# through Systui's compatibility PID1 supervisor when available.
if is_ish_aok; then
    export container=ish-aok SYSTUI_ISH_AOK=yes SYSTEMD_IN_CHROOT=1 SYSTEMD_IGNORE_CHROOT=1
    export SYSTEMD_LOG_TARGET=console SYSTEMD_LOG_LEVEL=warning
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    # --system/--user are systemd execution-mode switches. They do not apply to
    # the iSH compatibility supervisor, so consume them instead of passing them
    # to a real systemd binary and triggering misleading errors.
    case "${1:-}" in
        --system|--user) shift ;;
    esac

    if [ -x /usr/local/sbin/systui-ish-init ]; then
        exec /usr/local/sbin/systui-ish-init "$@"
    fi

    # Newer rootfs images install the compatibility launcher directly at
    # /sbin/init. Detect it by its marker before trusting the configured boot
    # command; this avoids accidentally executing a real systemd binary.
    if [ -x /sbin/init ] && grep -q '^REAL_SYSTEMD=' /sbin/init 2>/dev/null; then
        exec /sbin/init "$@"
    fi

    # Last-resort compatibility supervisor for older images that have systemd
    # installed but have not yet received systui-ish-init. This intentionally
    # does NOT attempt to execute real systemd on iSH-AOK.
    mkdir -p /run /run/lock /tmp /proc /sys /dev /dev/pts 2>/dev/null || true
    chmod 1777 /tmp 2>/dev/null || true
    [ -e /etc/machine-id ] || : > /etc/machine-id

    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q /proc 2>/dev/null || mount -t proc proc /proc 2>/dev/null || true
        mountpoint -q /sys 2>/dev/null || mount -t sysfs sysfs /sys 2>/dev/null || true
        mountpoint -q /dev/pts 2>/dev/null || mount -t devpts devpts /dev/pts 2>/dev/null || true
    fi

    for script in /etc/init.d/rcS /etc/rc.local; do
        [ -x "$script" ] && "$script" >/dev/console 2>&1 &
    done
    for svc in dbus cron crond rsyslog ssh sshd networking network-manager; do
        [ -x "/etc/init.d/$svc" ] && "/etc/init.d/$svc" start >/dev/console 2>&1 &
    done

    printf '%s\n' 'systui-boot: iSH-AOK compatibility supervisor active.' >&2
    trap 'exit 0' TERM INT HUP
    while :; do
        wait 2>/dev/null || true
        sleep 1
    done
fi

# Normal Linux keeps the configured boot semantics unchanged.
if [ "$cmd" = /sbin/init ] && [ -x /sbin/init ]; then
    exec /sbin/init "$@"
fi
exec /bin/sh -c "exec $cmd \"\$@\"" sh "$@"
EOF
    chmod 0755 "$helper"
}

# Preserve the existing helper installer but replace only systui-boot after it
# has written the generic helpers.
if declare -F sysconfig_runtime_install_helpers >/dev/null 2>&1 && ! declare -F _systui_base_runtime_install_helpers_ishboot >/dev/null 2>&1; then
    eval "$(declare -f sysconfig_runtime_install_helpers | sed '1s/^sysconfig_runtime_install_helpers[[:space:]]*()/_systui_base_runtime_install_helpers_ishboot ()/')"
fi
sysconfig_runtime_install_helpers() {
    local rc=0
    _systui_base_runtime_install_helpers_ishboot "$@" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    sysconfig_write_ish_safe_boot_helper
}

# Repair the currently installed helper immediately when this feature is
# sourced so existing rootfs images are fixed simply by updating/running Systui.
sysconfig_write_ish_safe_boot_helper 2>/dev/null || true
