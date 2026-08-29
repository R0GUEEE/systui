# shellcheck shell=bash
###############################################################################
# ROOTFS BUILDER — iSH-AOK compatibility for systemd rootfs images
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

    if [ "${SYSTUI_ISH_COMPAT_SKIP_COREUTILS_MIGRATION:-0}" != 1 ]; then
        if [ -r "$t/etc/os-release" ]; then
            while IFS='=' read -r key value; do
                case "$key" in
                    ID) distro_id=${value#\"}; distro_id=${distro_id%\"}; break ;;
                esac
            done < "$t/etc/os-release"
        fi
        if [ "$distro_id" = ubuntu ] && [ -x "$t/usr/bin/apt-get" ]; then
            if grep -qE '^Package: (rust-coreutils|coreutils-from-uutils)$' "$t/var/lib/dpkg/status" 2>/dev/null || [ -x "$t/usr/bin/uutils" ]; then
                rootfs_apt_force_ipv4 "$t" 2>/dev/null || true
                in_chroot "$t" sh -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update >/dev/null 2>&1 && apt-get install -y coreutils-from-gnu >/dev/null 2>&1' \
                    || warn "Could not switch Ubuntu rootfs to coreutils-from-gnu; some Rust coreutils may still fail on iSH-AOK."
            fi
        fi
    fi

    mkdir -p "$t/sbin" "$t/usr/local/sbin" "$t/etc/systui" "$t/etc/sysctl.d" "$t/run" "$t/proc" "$t/sys" "$t/dev" "$t/dev/pts" "$t/tmp"

    # systemd ships a vendor sysctl that raises kernel.pid_max. A chroot/rootfs
    # on iSH-AOK shares the host kernel and is not allowed to change that host
    # sysctl, so systemd-sysctl prints "Operation not permitted" on startup.
    # Mask the vendor drop-in through /etc, which is the supported override
    # mechanism and survives systemd package upgrades without modifying /usr.
    ln -sfn /dev/null "$t/etc/sysctl.d/50-pid-max.conf" || return 1

    cat > "$t/usr/local/sbin/systui-ish-init" <<EOF
#!/bin/sh
REAL_SYSTEMD='$real_systemd'

is_ish_kernel() {
    v=''
    [ -r /proc/version ] && IFS= read -r v < /proc/version 2>/dev/null || true
    case "\$v" in *-ish*|*ish_aok*|*iSH-AOK*|*iSH*) return 0 ;; esac
    [ -e /proc/ish ] && return 0
    return 1
}

case "\${1:-}" in
    shell|session-shell|--shell|--session-shell)
        shift
        if [ -x /bin/bash ]; then exec /bin/bash "\$@"; fi
        exec /bin/sh "\$@"
        ;;
esac

if ! is_ish_kernel; then
    exec "\$REAL_SYSTEMD" "\$@"
fi

export container=ish-aok SYSTEMD_IN_CHROOT=1 SYSTEMD_IGNORE_CHROOT=1
export SYSTEMD_LOG_TARGET=console SYSTEMD_LOG_LEVEL=warning
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

mkdir -p /run /run/lock /tmp /proc /sys /dev /dev/pts 2>/dev/null || true
chmod 1777 /tmp 2>/dev/null || true

if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q /proc 2>/dev/null || mount -t proc proc /proc 2>/dev/null || true
    mountpoint -q /sys 2>/dev/null || mount -t sysfs sysfs /sys 2>/dev/null || true
    mountpoint -q /dev/pts 2>/dev/null || mount -t devpts devpts /dev/pts 2>/dev/null || true
fi

[ -e /etc/machine-id ] || : > /etc/machine-id
[ -s /etc/machine-id ] || {
    command -v systemd-machine-id-setup >/dev/null 2>&1 && systemd-machine-id-setup >/dev/null 2>&1 || true
}

host_name=''
[ -r /etc/hostname ] && IFS= read -r host_name < /etc/hostname 2>/dev/null || true
[ -n "\$host_name" ] && hostname "\$host_name" 2>/dev/null || true

for script in /etc/init.d/rcS /etc/rc.local; do
    [ -x "\$script" ] && "\$script" >/dev/console 2>&1 &
done
for svc in dbus cron crond rsyslog ssh sshd networking network-manager; do
    [ -x "/etc/init.d/\$svc" ] && "/etc/init.d/\$svc" start >/dev/console 2>&1 &
done

trap 'exit 0' TERM INT HUP
while :; do
    wait 2>/dev/null || true
    sleep 1
done
EOF
    chmod 0755 "$t/usr/local/sbin/systui-ish-init"

    # Preserve the distro-provided init exactly once. New systemd rootfs builds
    # commonly have /sbin/init as a symlink to systemd; keep that target for
    # normal-Linux fallback, then replace /sbin/init with a real executable.
    if [ -L "$t/sbin/init" ]; then
        init_path=$(readlink "$t/sbin/init" 2>/dev/null || true)
        if [ "$init_path" != /usr/local/sbin/systui-ish-init ]; then
            [ -s "$t/etc/systui/original-init" ] || printf '%s\n' "$init_path" > "$t/etc/systui/original-init"
        fi
        rm -f "$t/sbin/init"
    elif [ -e "$t/sbin/init" ]; then
        if ! grep -q '^REAL_SYSTEMD=' "$t/sbin/init" 2>/dev/null; then
            if [ ! -e "$t/sbin/init.systui-original" ]; then
                mv "$t/sbin/init" "$t/sbin/init.systui-original" 2>/dev/null || true
            else
                rm -f "$t/sbin/init"
            fi
            [ -s "$t/etc/systui/original-init" ] || printf '%s\n' /sbin/init.systui-original > "$t/etc/systui/original-init"
        else
            rm -f "$t/sbin/init"
        fi
    fi

    # Install the compatibility launcher DIRECTLY at /sbin/init. This avoids
    # relying on symlink resolution during iSH-AOK rootfs startup and guarantees
    # every freshly built systemd image contains an executable init entrypoint.
    cp "$t/usr/local/sbin/systui-ish-init" "$t/sbin/init" || return 1
    chmod 0755 "$t/sbin/init" || return 1

    cat > "$t/etc/systui/ish-systemd-compat.conf" <<EOF
ENABLED=yes
REAL_SYSTEMD=$real_systemd
MODE=auto
SESSION_SHELL=/bin/bash
INIT_PATH=/sbin/init
INIT_TYPE=direct-executable
PID_MAX_SYSCTL_MASK=/etc/sysctl.d/50-pid-max.conf
DESCRIPTION=Use real systemd on normal Linux and a non-interactive PID1 compatibility supervisor on iSH-AOK.
EOF

    mkdir -p "$t/etc/profile.d"
    cat > "$t/etc/profile.d/systui-ish-systemd-compat.sh" <<'EOF'
_systui_proc_version=''
[ -r /proc/version ] && IFS= read -r _systui_proc_version < /proc/version 2>/dev/null || true
case "$_systui_proc_version" in
    *-ish*|*ish_aok*|*iSH-AOK*|*iSH*) export container=ish-aok SYSTEMD_IN_CHROOT=1 ;;
esac
unset _systui_proc_version
EOF
    chmod 0644 "$t/etc/profile.d/systui-ish-systemd-compat.sh"
    log "rootfs: installed direct iSH-AOK systemd compatibility /sbin/init in $t"
    log "rootfs: masked unsupported systemd kernel.pid_max sysctl in $t"
}

if declare -F rootfs_postconfig >/dev/null 2>&1 && ! declare -F _systui_base_rootfs_postconfig >/dev/null 2>&1; then
    eval "$(declare -f rootfs_postconfig | sed '1s/^rootfs_postconfig[[:space:]]*()/_systui_base_rootfs_postconfig ()/')"
fi
rootfs_postconfig() {
    local target="$1" init_choice="$5" rc=0
    _systui_base_rootfs_postconfig "$@" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    # Install /sbin/init during the build itself, before integrity validation
    # and before any archive is created. systemd builds must leave postconfig
    # with a usable direct init executable already present in the target tree.
    if [ "$init_choice" = systemd ]; then
        rootfs_install_ish_systemd_compat "$target" || {
            warn "Could not install /sbin/init for the iSH-AOK systemd compatibility layer."
            return 1
        }
        [ -x "$target/sbin/init" ] || {
            warn "Systemd rootfs postconfig completed without an executable /sbin/init."
            return 1
        }
        [ ! -L "$target/sbin/init" ] || {
            warn "Systemd rootfs /sbin/init is unexpectedly still a symlink."
            return 1
        }
    fi
}

# Final archive guard for recovered/interrupted or manually modified builds.
if declare -F rootfs_tar_create >/dev/null 2>&1 && ! declare -F _systui_base_rootfs_tar_create >/dev/null 2>&1; then
    eval "$(declare -f rootfs_tar_create | sed '1s/^rootfs_tar_create[[:space:]]*()/_systui_base_rootfs_tar_create ()/')"
fi
rootfs_tar_create() {
    local fmt="$1" src="$2" out="$3" pid rc=0 bytes=0
    shift 3
    local -a extra=("$@")

    if [ -x "$src/lib/systemd/systemd" ] || [ -x "$src/usr/lib/systemd/systemd" ]; then
        log "rootfs: verifying direct /sbin/init before packing $src"
        if [ ! -x "$src/sbin/init" ] || [ -L "$src/sbin/init" ] || ! grep -q '^REAL_SYSTEMD=' "$src/sbin/init" 2>/dev/null; then
            SYSTUI_ISH_COMPAT_SKIP_COREUTILS_MIGRATION=1 rootfs_install_ish_systemd_compat "$src" || return 1
        fi
        [ -x "$src/sbin/init" ] || return 1
        [ ! -L "$src/sbin/init" ] || return 1

        # Never archive live pseudo-filesystems. Build/chroot helpers may leave
        # proc, sysfs, devpts, /dev or /run mounted below the target on iSH-AOK;
        # traversing those trees can make tar block indefinitely or produce an
        # invalid rootfs archive. Keep the mountpoint directories themselves but
        # exclude their runtime contents.
        extra+=(
            '--exclude=./proc/*'
            '--exclude=./sys/*'
            '--exclude=./dev/*'
            '--exclude=./run/*'
            '--exclude=./tmp/*'
        )

        rm -f -- "$out" 2>/dev/null || true
        log "rootfs: packing systemd image with virtual filesystems excluded"

        # Run compression in the background only so the foreground can report
        # activity. This is especially important on iSH-AOK where gzip on a
        # complete Ubuntu ARM64 tree can be slow enough to look frozen.
        ( _systui_base_rootfs_tar_create "$fmt" "$src" "$out" "${extra[@]}" ) &
        pid=$!
        while kill -0 "$pid" 2>/dev/null; do
            if [ -f "$out" ]; then
                bytes=$(wc -c < "$out" 2>/dev/null || printf '0')
                printf '>>> Packing rootfs: %s bytes written\n' "$bytes"
            else
                printf '>>> Packing rootfs: preparing archive...\n'
            fi
            sleep 5
        done
        if wait "$pid"; then
            rc=0
        else
            rc=$?
        fi
        [ "$rc" -eq 0 ] || {
            warn "Rootfs archive creation failed with status $rc"
            return "$rc"
        }
        bytes=$(wc -c < "$out" 2>/dev/null || printf '0')
        printf '>>> Rootfs archive complete: %s bytes\n' "$bytes"
        return 0
    fi

    _systui_base_rootfs_tar_create "$fmt" "$src" "$out" "${extra[@]}"
}

export -f rootfs_install_ish_systemd_compat rootfs_postconfig rootfs_tar_create
