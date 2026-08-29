# shellcheck shell=bash
###############################################################################
# ROOTFS WORKBENCH — iSH-AOK readiness repair workflow
#
# Extends the existing readiness analyzer with an actionable, SPACE-select
# repair pass. Repairs are derived from the target's current state; the scanner
# never hides non-repairable blockers such as an incompatible architecture.
###############################################################################

rootfs_wb_ish_repair_choices() { # <target> -> tag|description|on/off
    local t="$1" engine mounts state_file="" has_systemd=0

    engine=$(rootfs_wb_engine_get "$t" 2>/dev/null || true)
    mounts=$(rootfs_wb_mount_count "$t" 2>/dev/null || echo 0)
    [ -x "$t/lib/systemd/systemd" ] || [ -x "$t/usr/lib/systemd/systemd" ] && has_systemd=1

    [ -d "$t/proc" ] && [ -d "$t/sys" ] && [ -d "$t/dev" ] && [ -d "$t/dev/pts" ] && \
        [ -d "$t/run" ] && [ -d "$t/tmp" ] || \
        printf '%s\n' 'dirs|Create required /proc, /sys, /dev/pts, /run and /tmp mountpoints|on'

    [ "$engine" = chroot ] || \
        printf '%s\n' 'engine|Set Workbench execution engine to chroot (required on iSH-AOK)|on'

    [ "$mounts" -gt 0 ] || \
        printf '%s\n' 'mounts|Mount virtual filesystems and configured binds|on'

    if [ "$has_systemd" -eq 1 ]; then
        if [ ! -r "$t/etc/systui/ish-systemd-compat.conf" ] || \
           [ ! -x "$t/sbin/init" ] || [ -L "$t/sbin/init" ] || \
           [ ! -L "$t/etc/sysctl.d/50-pid-max.conf" ] || \
           [ "$(readlink "$t/etc/sysctl.d/50-pid-max.conf" 2>/dev/null)" != /dev/null ] || \
           [ ! -L "$t/etc/tmpfiles.d/20-systemd-osc-context.conf" ] || \
           [ "$(readlink "$t/etc/tmpfiles.d/20-systemd-osc-context.conf" 2>/dev/null)" != /dev/null ] || \
           [ ! -x "$t/usr/local/bin/cat" ]; then
            printf '%s\n' 'systemd|Install/refresh complete iSH-AOK systemd compatibility layer|on'
        fi
    elif [ ! -x "$t/sbin/init" ]; then
        if [ -x "$t/usr/sbin/runit" ]; then
            printf '%s\n' 'runit-init|Wire /sbin/init to installed runit PID 1|on'
        elif [ -x "$t/sbin/openrc-init" ]; then
            printf '%s\n' 'openrc-init|Wire /sbin/init to installed OpenRC init|on'
        else
            printf '%s\n' 'continue|Continue/recover rootfs generation to install a usable init|on'
        fi
    fi

    if [ -r "$t/var/lib/dpkg/status" ] && \
       grep -qE '^Status: .* (half-configured|unpacked|half-installed|triggers-awaited|triggers-pending)$' "$t/var/lib/dpkg/status" 2>/dev/null; then
        printf '%s\n' 'dpkg|Complete interrupted dpkg configuration and repair dependencies|on'
    fi

    [ -r "$t/etc/resolv.conf" ] || printf '%s\n' 'dns|Create /etc/resolv.conf from the current host|on'
    [ -r "$t/etc/hosts" ] || printf '%s\n' 'hosts|Create a minimal /etc/hosts|on'
    [ -r "$t/etc/hostname" ] || printf '%s\n' 'hostname|Create /etc/hostname from the rootfs name|on'
    [ -e "$t/etc/machine-id" ] || printf '%s\n' 'machine-id|Create /etc/machine-id for init/service compatibility|on'

    state_file=$(rootfs_state_file "$t" 2>/dev/null || true)
    if [ -n "$state_file" ] && [ -r "$state_file" ]; then
        if grep -qiE 'stage=(failed|incomplete|bootstrap|postconfig)|status=(failed|incomplete)' "$state_file" 2>/dev/null; then
            printf '%s\n' 'continue|Continue/recover interrupted Systui rootfs generation|on'
        fi
    fi
}

rootfs_wb_ish_fix_dirs() { # <target>
    local t="$1"
    mkdir -p "$t/proc" "$t/sys" "$t/dev" "$t/dev/pts" "$t/run" "$t/run/lock" "$t/tmp" || return 1
    chmod 1777 "$t/tmp" 2>/dev/null || true
}

rootfs_wb_ish_fix_runtime_files() { # <target> <kind>
    local t="$1" kind="$2" h
    mkdir -p "$t/etc" || return 1
    case "$kind" in
        dns)
            if [ -r /etc/resolv.conf ]; then
                rm -f "$t/etc/resolv.conf" 2>/dev/null || true
                cp -L /etc/resolv.conf "$t/etc/resolv.conf" || return 1
            else
                printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$t/etc/resolv.conf" || return 1
            fi
            ;;
        hosts)
            cat > "$t/etc/hosts" <<'EOF'
127.0.0.1 localhost
::1 localhost ip6-localhost ip6-loopback
EOF
            ;;
        hostname)
            h=$(basename "$t" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^-*//;s/-*$//')
            [ -n "$h" ] || h=ish-rootfs
            printf '%s\n' "$h" > "$t/etc/hostname"
            ;;
        machine-id)
            : > "$t/etc/machine-id"
            ;;
        *) return 2 ;;
    esac
}

rootfs_wb_ish_fix_dpkg() { # <target>
    local t="$1" mounted_before=0 rc=0
    [ "$(rootfs_wb_mount_count "$t" 2>/dev/null || echo 0)" -gt 0 ] && mounted_before=1
    if [ "$mounted_before" -eq 0 ]; then
        rootfs_wb_mount_persistent "$t" || return 1
    fi

    if declare -F rootfs_ish_activate_gnu_coreutils >/dev/null 2>&1; then
        rootfs_ish_activate_gnu_coreutils "$t" >/dev/null 2>&1 || true
    fi
    if declare -F rootfs_apt_force_ipv4 >/dev/null 2>&1; then
        rootfs_apt_force_ipv4 "$t" >/dev/null 2>&1 || true
    fi

    in_chroot "$t" sh -c 'export DEBIAN_FRONTEND=noninteractive; dpkg --configure -a && apt-get -f install -y' || rc=$?
    return "$rc"
}

rootfs_wb_ish_apply_repair() { # <target> <tag>
    local t="$1" tag="$2"
    case "$tag" in
        dirs) rootfs_wb_ish_fix_dirs "$t" ;;
        engine) rootfs_chroot_option_set "$t" ENGINE chroot ;;
        mounts)
            rootfs_wb_ish_fix_dirs "$t" || return 1
            [ "$(rootfs_wb_mount_count "$t" 2>/dev/null || echo 0)" -gt 0 ] || rootfs_wb_mount_persistent "$t"
            ;;
        systemd)
            SYSTUI_ISH_COMPAT_SKIP_COREUTILS_MIGRATION=1 rootfs_install_ish_systemd_compat "$t"
            ;;
        runit-init)
            mkdir -p "$t/sbin" || return 1
            if [ -e "$t/sbin/init" ] || [ -L "$t/sbin/init" ]; then
                [ -e "$t/sbin/init.systui-original" ] || [ -L "$t/sbin/init.systui-original" ] || \
                    mv "$t/sbin/init" "$t/sbin/init.systui-original" 2>/dev/null || true
                rm -f "$t/sbin/init"
            fi
            ln -s ../usr/sbin/runit "$t/sbin/init"
            ;;
        openrc-init)
            mkdir -p "$t/sbin" || return 1
            if [ -e "$t/sbin/init" ] || [ -L "$t/sbin/init" ]; then
                [ -e "$t/sbin/init.systui-original" ] || [ -L "$t/sbin/init.systui-original" ] || \
                    mv "$t/sbin/init" "$t/sbin/init.systui-original" 2>/dev/null || true
                rm -f "$t/sbin/init"
            fi
            ln -s openrc-init "$t/sbin/init"
            ;;
        dpkg) rootfs_wb_ish_fix_dpkg "$t" ;;
        dns|hosts|hostname|machine-id) rootfs_wb_ish_fix_runtime_files "$t" "$tag" ;;
        continue) rootfs_continue_generation "$t" ;;
        *) return 2 ;;
    esac
}

rootfs_wb_ish_repair_menu() { # <target>
    local t="$1" selected tag line desc state rc=0 fixed=0 failed=0
    local -a args=()

    while IFS='|' read -r tag desc state; do
        [ -n "$tag" ] || continue
        # Avoid duplicate repair tags when several scan conditions map to the
        # same recovery action (for example an incomplete build plus no init).
        case " ${args[*]} " in *" $tag "*) continue ;; esac
        args+=("$tag" "$desc" "${state:-on}")
    done <<< "$(rootfs_wb_ish_repair_choices "$t")"

    if [ ${#args[@]} -eq 0 ]; then
        tui_msg "iSH-AOK readiness" "No automatically repairable readiness issues were detected.\n\nReview any remaining warnings in the scan report manually."
        return 0
    fi

    selected=$(tui_check "Repair iSH-AOK readiness" \
        "SPACE selects repairs; ENTER applies them. Only issues detected by the readiness scan are offered." \
        "${args[@]}") || return 0
    selected=${selected//\"/}
    [ -n "${selected//[[:space:]]/}" ] || return 0

    for tag in $selected; do
        if rootfs_wb_ish_apply_repair "$t" "$tag"; then
            fixed=$((fixed + 1))
            log "rootfs: iSH-AOK readiness repair '$tag' completed for $t"
        else
            rc=$?
            failed=$((failed + 1))
            warn "iSH-AOK readiness repair '$tag' failed for $t (status $rc)"
        fi
    done

    tui_msg "Readiness repairs complete" \
"Completed: $fixed
Failed: $failed

Systui will now run the readiness scan again so you can verify the remaining requirements."
    return 0
}

# Preserve the detailed report already provided by Workbench, then add the
# repair selection immediately afterward as requested. Re-running the analyzer
# after repairs gives the user a fresh PASS/WARN/FAIL report.
if declare -F rootfs_wb_ish_boot_analyze >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_wb_ish_boot_analyze_repair >/dev/null 2>&1; then
    eval "$(declare -f rootfs_wb_ish_boot_analyze | sed '1s/^rootfs_wb_ish_boot_analyze[[:space:]]*()/_systui_base_rootfs_wb_ish_boot_analyze_repair ()/')"
fi

rootfs_wb_ish_boot_analyze() { # <target>
    local t="$1"
    _systui_base_rootfs_wb_ish_boot_analyze_repair "$t"

    if tui_yesno "iSH-AOK readiness repairs" \
        "Scan complete. Review the report above.\n\nOpen the repair selector for issues Systui can fix automatically?"; then
        rootfs_wb_ish_repair_menu "$t"
        _systui_base_rootfs_wb_ish_boot_analyze_repair "$t"
    fi
}

export -f rootfs_wb_ish_repair_choices rootfs_wb_ish_fix_dirs \
    rootfs_wb_ish_fix_runtime_files rootfs_wb_ish_fix_dpkg \
    rootfs_wb_ish_apply_repair rootfs_wb_ish_repair_menu rootfs_wb_ish_boot_analyze
