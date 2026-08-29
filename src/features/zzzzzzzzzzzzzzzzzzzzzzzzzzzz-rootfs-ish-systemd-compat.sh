# shellcheck shell=bash
###############################################################################
# ROOTFS BUILDER — iSH-AOK compatibility for systemd rootfs images
#
# systemd expects a number of Linux kernel facilities that iSH/iSH-AOK only
# partially implements. A systemd-selected rootfs should still keep genuine
# systemd for normal Linux, but when the image is booted under iSH-AOK its
# /sbin/init entry point needs a small compatibility supervisor instead of
# handing PID 1 directly to systemd.
###############################################################################

rootfs_install_ish_systemd_compat() { # <target>
    local t="$1" real_systemd init_path distro_id=""

    [ -d "$t" ] || return 1

    for real_systemd in /lib/systemd/systemd /usr/lib/systemd/systemd; do
        [ -x "$t$real_systemd" ] && break
    done
    [ -x "$t$real_systemd" ] || {
        warn "systemd was selected, but no systemd binary exists in $t"
        return 0
    }

    # Ubuntu Resolute can provide coreutils via uutils/rust-coreutils. Its
    # rustix auxv probe is incompatible with iSH-AOK. During a normal build we
    # may migrate to GNU coreutils. During Workbench entry this is explicitly
    # skipped because apt/dpkg maintainer scripts can invoke the broken tools
    # before the safe shell has started.
    if [ "${SYSTUI_ISH_COMPAT_SKIP_COREUTILS_MIGRATION:-0}" != 1 ]; then
        if [ -r "$t/etc/os-release" ]; then
            while IFS='=' read -r key value; do
                case "$key" in
                    ID) distro_id=${value#\"}; distro_id=${distro_id%\"}; break ;;
                esac
            done < "$t/etc/os-release"
        fi
        if [ "$distro_id" = ubuntu ] && [ -x "$t/usr/bin/apt-get" ]; then
            if grep -qE '^(Package: (rust-coreutils|coreutils-from-uutils)|Status: install ok installed)$' \
                "$t/var/lib/dpkg/status" 2>/dev/null || [ -x "$t/usr/bin/uutils" ]; then
                rootfs_apt_force_ipv4 "$t" 2>/dev/null || true
                in_chroot "$t" sh -c \
                    'export DEBIAN_FRONTEND=noninteractive; apt-get update >/dev/null 2>&1 && apt-get install -y coreutils-from-gnu >/dev/null 2>&1' \
                    || warn "Could not switch Ubuntu rootfs to coreutils-from-gnu; some Rust coreutils may still fail on iSH-AOK."
            fi
        fi
    fi

    mkdir -p "$t/usr/local/sbin" "$t/etc/systui" "$t/run" "$t/proc" "$t/sys" "$t/dev" "$t/dev/pts" "$t/tmp"

    cat > "$t/usr/local/sbin/systui-ish-init" <<EOF
#!/bin/sh
REAL_SYSTEMD='$real_systemd'

is_ish_kernel() {
    v=''
    [ -r /proc/version ] && IFS= read -r v < /proc/version 2>/dev/null || true
    case "\$v" in
        *-ish*|*ish_aok*|*iSH-AOK*|*iSH*) return 0 ;;
    esac
    [ -e /proc/ish ] && return 0
    return 1
}

if ! is_ish_kernel; then
    exec "\$REAL_SYSTEMD" "\$@"
fi

export container=ish-aok
export SYSTEMD_IN_CHROOT=1
export SYSTEMD_IGNORE_CHROOT=1
export SYSTEMD_LOG_TARGET=console
export SYSTEMD_LOG_LEVEL=warning
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

mkdir -p /run /run/lock /tmp /proc /sys /dev /dev/pts 2>/dev/null || true
chmod 1777 /tmp 2>/dev/null || true

if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q /proc 2>/dev/null || mount -t proc proc /proc 2>/dev/null || true
    mountpoint -q /sys  2>/dev/null || mount -t sysfs sysfs /sys 2>/dev/null || true
    mountpoint -q /dev/pts 2>/dev/null || mount -t devpts devpts /dev/pts 2>/dev/null || true
fi

[ -e /etc/machine-id ] || : > /etc/machine-id
[ -s /etc/machine-id ] || {
    if command -v systemd-machine-id-setup >/dev/null 2>&1; then
        systemd-machine-id-setup >/dev/null 2>&1 || true
    elif command -v dbus-uuidgen >/dev/null 2>&1; then
        dbus-uuidgen --ensure=/etc/machine-id >/dev/null 2>&1 || true
    fi
}

host_name=''
[ -r /etc/hostname ] && IFS= read -r host_name < /etc/hostname 2>/dev/null || true
[ -n "\$host_name" ] && hostname "\$host_name" 2>/dev/null || true

for script in /etc/init.d/rcS /etc/rc.local; do
    [ -x "\$script" ] && "\$script" >/dev/console 2>&1 || true
done

for svc in dbus cron crond rsyslog ssh sshd networking network-manager; do
    if [ -x "/etc/init.d/\$svc" ]; then
        "/etc/init.d/\$svc" start >/dev/console 2>&1 || true
    fi
done

while :; do
    if [ -x /bin/bash ]; then
        /bin/bash --noprofile --norc
    else
        /bin/sh
    fi
    rc=\$?
    echo "iSH compatibility shell exited with status \$rc; restarting." >/dev/console 2>/dev/null || true
    sleep 1
done
EOF
    chmod 0755 "$t/usr/local/sbin/systui-ish-init"

    if [ -L "$t/sbin/init" ]; then
        init_path=$(readlink "$t/sbin/init" 2>/dev/null || true)
        printf '%s\n' "$init_path" > "$t/etc/systui/original-init"
        rm -f "$t/sbin/init"
    elif [ -e "$t/sbin/init" ]; then
        mv "$t/sbin/init" "$t/sbin/init.systui-original" 2>/dev/null || true
        printf '%s\n' /sbin/init.systui-original > "$t/etc/systui/original-init"
    fi
    ln -sfn /usr/local/sbin/systui-ish-init "$t/sbin/init"

    cat > "$t/etc/systui/ish-systemd-compat.conf" <<EOF
ENABLED=yes
REAL_SYSTEMD=$real_systemd
MODE=auto
DESCRIPTION=Use real systemd on normal Linux and the systui iSH PID1 compatibility supervisor on iSH-AOK.
EOF

    mkdir -p "$t/etc/profile.d"
    cat > "$t/etc/profile.d/systui-ish-systemd-compat.sh" <<'EOF'
_systui_proc_version=''
[ -r /proc/version ] && IFS= read -r _systui_proc_version < /proc/version 2>/dev/null || true
case "$_systui_proc_version" in
    *-ish*|*ish_aok*|*iSH-AOK*|*iSH*)
        export container=ish-aok
        export SYSTEMD_IN_CHROOT=1
        ;;
esac
unset _systui_proc_version
EOF
    chmod 0644 "$t/etc/profile.d/systui-ish-systemd-compat.sh"

    log "rootfs: installed iSH-AOK systemd compatibility layer in $t"
    return 0
}

if declare -F rootfs_postconfig >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_postconfig >/dev/null 2>&1; then
    eval "$(declare -f rootfs_postconfig | sed '1s/^rootfs_postconfig[[:space:]]*()/_systui_base_rootfs_postconfig ()/')"
fi

rootfs_postconfig() {
    local target="$1" init_choice="$5" rc=0

    _systui_base_rootfs_postconfig "$@" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    if [ "$init_choice" = systemd ]; then
        rootfs_install_ish_systemd_compat "$target" || {
            warn "Could not install the iSH-AOK systemd compatibility layer."
            return 1
        }
    fi
    return 0
}

export -f rootfs_install_ish_systemd_compat rootfs_postconfig
