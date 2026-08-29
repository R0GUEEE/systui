# shellcheck shell=bash
###############################################################################
# ROOTFS WORKBENCH — management actions
# Consolidates the useful actions from the former Rootfs > Manage menu into
# each selected rootfs's Workbench menu.
###############################################################################

rootfs_wb_inspect() { # <target>
    local t="$1" report
    report="$(rootfs_report_file)"
    {
        echo "ROOTFS INSPECTION"
        echo
        echo "Path        : $t"
        echo "Name        : $(basename "$t")"
        echo "Size        : $(du -sh "$t" 2>/dev/null | awk '{print $1}')"
        echo "Architecture: $(rootfs_target_arch "$t" 2>/dev/null || echo unknown)"
        echo "Engine      : $(rootfs_wb_engine_get "$t" 2>/dev/null || echo unknown)"
        echo "Live mounts : $(rootfs_wb_mount_count "$t" 2>/dev/null || echo 0)"
        echo
        echo "--- Distribution ---"
        if [ -r "$t/etc/os-release" ]; then
            sed -n 's/^PRETTY_NAME=//p; s/^ID=//p; s/^VERSION_ID=//p; s/^VERSION_CODENAME=//p' "$t/etc/os-release" | tr -d '"'
        else
            echo "No /etc/os-release found."
        fi
        echo
        echo "--- Build state ---"
        if [ -r "$(rootfs_state_file "$t")" ]; then
            cat "$(rootfs_state_file "$t")"
        elif [ -r "$t/etc/systui-build.conf" ]; then
            cat "$t/etc/systui-build.conf"
        else
            echo "No systui build state found."
        fi
        echo
        echo "--- Directory sizes ---"
        rootfs_du_summary "$t" 2>/dev/null || true
    } > "$report" 2>&1
    tui_text "Inspect: $(basename "$t")" "$report"
}

rootfs_wb_ish_boot_analyze() { # <target>
    local t="$1" report arch engine init_desc="unknown" distro="unknown"
    local pass=0 warnc=0 fail=0 mount_count=0
    local has_systemd=0 has_ish_systemd=0 has_runit=0 has_openrc=0 has_sysv=0
    report="$(rootfs_report_file)"

    rootfs_wb_ish_emit() { # <level> <check> <detail>
        local level="$1" check="$2" detail="$3"
        printf '[%-4s] %-30s %s\n' "$level" "$check" "$detail"
        case "$level" in
            PASS) pass=$((pass + 1)) ;;
            WARN) warnc=$((warnc + 1)) ;;
            FAIL) fail=$((fail + 1)) ;;
        esac
    }

    {
        echo "iSH-AOK ROOTFS BOOT READINESS"
        echo "================================"
        echo
        echo "Target : $t"
        arch=$(rootfs_target_arch "$t" 2>/dev/null || echo unknown)
        engine=$(rootfs_wb_engine_get "$t" 2>/dev/null || echo unknown)
        mount_count=$(rootfs_wb_mount_count "$t" 2>/dev/null || echo 0)
        if [ -r "$t/etc/os-release" ]; then
            distro=$(sed -n 's/^PRETTY_NAME=//p' "$t/etc/os-release" | head -n1 | tr -d '"')
            [ -n "$distro" ] || distro=$(sed -n 's/^ID=//p' "$t/etc/os-release" | head -n1 | tr -d '"')
        fi
        echo "Distro : $distro"
        echo "Arch   : $arch"
        echo "Engine : $engine"
        echo
        echo "--- Core filesystem ---"

        [ -d "$t" ] && rootfs_wb_ish_emit PASS "Rootfs directory" "present" || rootfs_wb_ish_emit FAIL "Rootfs directory" "missing"
        [ -x "$t/bin/sh" ] && rootfs_wb_ish_emit PASS "/bin/sh" "executable" || rootfs_wb_ish_emit FAIL "/bin/sh" "missing or not executable"
        if [ -x "$t/bin/bash" ]; then
            rootfs_wb_ish_emit PASS "/bin/bash" "available for Workbench sessions"
        else
            rootfs_wb_ish_emit WARN "/bin/bash" "missing; Workbench will fall back to /bin/sh"
        fi
        [ -r "$t/etc/passwd" ] && grep -q '^root:' "$t/etc/passwd" 2>/dev/null && \
            rootfs_wb_ish_emit PASS "root account" "present in /etc/passwd" || \
            rootfs_wb_ish_emit FAIL "root account" "missing from /etc/passwd"
        [ -r "$t/etc/group" ] && rootfs_wb_ish_emit PASS "/etc/group" "present" || rootfs_wb_ish_emit WARN "/etc/group" "missing"
        [ -r "$t/etc/os-release" ] && rootfs_wb_ish_emit PASS "/etc/os-release" "present" || rootfs_wb_ish_emit WARN "/etc/os-release" "missing"
        [ -d "$t/proc" ] && rootfs_wb_ish_emit PASS "/proc mountpoint" "directory exists" || rootfs_wb_ish_emit FAIL "/proc mountpoint" "directory missing"
        [ -d "$t/sys" ] && rootfs_wb_ish_emit PASS "/sys mountpoint" "directory exists" || rootfs_wb_ish_emit WARN "/sys mountpoint" "directory missing"
        [ -d "$t/dev" ] && rootfs_wb_ish_emit PASS "/dev mountpoint" "directory exists" || rootfs_wb_ish_emit FAIL "/dev mountpoint" "directory missing"
        [ -d "$t/dev/pts" ] && rootfs_wb_ish_emit PASS "/dev/pts mountpoint" "directory exists" || rootfs_wb_ish_emit WARN "/dev/pts mountpoint" "directory missing"
        [ -d "$t/run" ] && rootfs_wb_ish_emit PASS "/run" "directory exists" || rootfs_wb_ish_emit WARN "/run" "directory missing"
        [ -d "$t/tmp" ] && rootfs_wb_ish_emit PASS "/tmp" "directory exists" || rootfs_wb_ish_emit FAIL "/tmp" "directory missing"

        echo
        echo "--- Architecture and execution ---"
        case "$arch" in
            arm64|aarch64) rootfs_wb_ish_emit PASS "Architecture" "$arch is native for iSH-AOK ARM64" ;;
            unknown) rootfs_wb_ish_emit WARN "Architecture" "could not determine target architecture" ;;
            *) rootfs_wb_ish_emit FAIL "Architecture" "$arch requires emulation; iSH-AOK boot path expects ARM64" ;;
        esac
        if declare -F rootfs_wb_is_ish_kernel >/dev/null 2>&1 && rootfs_wb_is_ish_kernel; then
            rootfs_wb_ish_emit PASS "Host kernel" "iSH-AOK detected"
        else
            rootfs_wb_ish_emit WARN "Host kernel" "current host does not appear to be iSH-AOK; report is predictive"
        fi
        case "$engine" in
            chroot) rootfs_wb_ish_emit PASS "Workbench engine" "chroot is the supported iSH-AOK engine" ;;
            proot|nspawn|unshare) rootfs_wb_ish_emit FAIL "Workbench engine" "$engine relies on kernel features incomplete on iSH-AOK; select chroot" ;;
            *) rootfs_wb_ish_emit WARN "Workbench engine" "$engine is not the preferred iSH-AOK engine" ;;
        esac
        [ "$mount_count" -gt 0 ] && rootfs_wb_ish_emit PASS "Virtual mounts" "$mount_count currently attached" || rootfs_wb_ish_emit WARN "Virtual mounts" "none attached; /proc, /dev and /dev/pts must be available when entering/booting"

        echo
        echo "--- Init system ---"
        [ -x "$t/lib/systemd/systemd" ] || [ -x "$t/usr/lib/systemd/systemd" ] && has_systemd=1
        [ -x "$t/usr/sbin/runit" ] && has_runit=1
        [ -x "$t/sbin/openrc-init" ] || [ -x "$t/bin/openrc-init" ] && has_openrc=1
        [ -x "$t/sbin/init" ] && grep -q 'systui-ish-init\|REAL_SYSTEMD=' "$t/sbin/init" 2>/dev/null && has_ish_systemd=1
        [ -x "$t/sbin/init" ] && { [ -x "$t/sbin/init" ] && strings "$t/sbin/init" 2>/dev/null | grep -qi 'sysvinit' ; } && has_sysv=1

        if [ -x "$t/sbin/init" ]; then
            if [ -L "$t/sbin/init" ]; then
                init_desc="symlink -> $(readlink "$t/sbin/init" 2>/dev/null || echo unknown)"
            else
                init_desc="direct executable"
            fi
            rootfs_wb_ish_emit PASS "/sbin/init" "$init_desc"
        else
            rootfs_wb_ish_emit FAIL "/sbin/init" "missing or not executable"
        fi

        if [ "$has_systemd" -eq 1 ]; then
            rootfs_wb_ish_emit PASS "systemd binary" "installed"
            if [ "$has_ish_systemd" -eq 1 ] || [ -r "$t/etc/systui/ish-systemd-compat.conf" ]; then
                rootfs_wb_ish_emit PASS "iSH systemd compatibility" "installed"
            else
                rootfs_wb_ish_emit FAIL "iSH systemd compatibility" "missing; install the Workbench iSH-AOK systemd compatibility layer"
            fi
            [ -L "$t/etc/sysctl.d/50-pid-max.conf" ] && [ "$(readlink "$t/etc/sysctl.d/50-pid-max.conf" 2>/dev/null)" = /dev/null ] && \
                rootfs_wb_ish_emit PASS "kernel.pid_max mask" "vendor sysctl disabled for iSH-AOK" || \
                rootfs_wb_ish_emit WARN "kernel.pid_max mask" "missing; systemd-sysctl may print Operation not permitted"
            if [ -L "$t/etc/tmpfiles.d/20-systemd-osc-context.conf" ] && [ "$(readlink "$t/etc/tmpfiles.d/20-systemd-osc-context.conf" 2>/dev/null)" = /dev/null ]; then
                rootfs_wb_ish_emit PASS "systemd OSC profile mask" "missing procfs UUID probes disabled"
            else
                rootfs_wb_ish_emit WARN "systemd OSC profile mask" "missing; shell startup may probe unavailable random UUID procfs nodes"
            fi
            [ -x "$t/usr/local/bin/cat" ] && grep -q 'Systui iSH-AOK procfs compatibility wrapper' "$t/usr/local/bin/cat" 2>/dev/null && \
                rootfs_wb_ish_emit PASS "procfs UUID compatibility" "cat wrapper installed" || \
                rootfs_wb_ish_emit WARN "procfs UUID compatibility" "wrapper not installed"
        elif [ "$has_runit" -eq 1 ]; then
            rootfs_wb_ish_emit PASS "runit" "installed"
        elif [ "$has_openrc" -eq 1 ]; then
            rootfs_wb_ish_emit PASS "OpenRC" "installed"
        elif [ "$has_sysv" -eq 1 ]; then
            rootfs_wb_ish_emit PASS "SysVinit" "detected"
        else
            rootfs_wb_ish_emit WARN "Init identification" "could not identify a supported init implementation"
        fi

        echo
        echo "--- Package/build completion ---"
        if [ -r "$(rootfs_state_file "$t")" ]; then
            rootfs_wb_ish_emit PASS "Systui build state" "present"
            sed 's/^/       /' "$(rootfs_state_file "$t")" 2>/dev/null || true
        elif [ -r "$t/etc/systui-build.conf" ]; then
            rootfs_wb_ish_emit PASS "Systui build manifest" "present"
        else
            rootfs_wb_ish_emit WARN "Systui build state" "not found; imported/manual rootfs assumed"
        fi

        if [ -e "$t/var/lib/dpkg/status" ]; then
            rootfs_wb_ish_emit PASS "dpkg database" "present"
            if grep -q '^Status: .*half-configured\|^Status: .*unpacked' "$t/var/lib/dpkg/status" 2>/dev/null; then
                rootfs_wb_ish_emit WARN "dpkg completion" "packages may still need dpkg --configure -a / apt-get -f install"
            else
                rootfs_wb_ish_emit PASS "dpkg completion" "no obvious half-configured/unpacked package state detected"
            fi
        elif [ -e "$t/lib/apk/db/installed" ]; then
            rootfs_wb_ish_emit PASS "apk database" "present"
        elif [ -e "$t/var/lib/pacman/local" ]; then
            rootfs_wb_ish_emit PASS "pacman database" "present"
        elif [ -e "$t/var/lib/rpm" ]; then
            rootfs_wb_ish_emit PASS "RPM database" "present"
        else
            rootfs_wb_ish_emit WARN "Package database" "not recognized"
        fi

        echo
        echo "--- Basic runtime configuration ---"
        [ -r "$t/etc/resolv.conf" ] && rootfs_wb_ish_emit PASS "DNS configuration" "/etc/resolv.conf present" || rootfs_wb_ish_emit WARN "DNS configuration" "/etc/resolv.conf missing"
        [ -r "$t/etc/hosts" ] && rootfs_wb_ish_emit PASS "Hosts file" "/etc/hosts present" || rootfs_wb_ish_emit WARN "Hosts file" "/etc/hosts missing"
        [ -r "$t/etc/hostname" ] && rootfs_wb_ish_emit PASS "Hostname" "/etc/hostname present" || rootfs_wb_ish_emit WARN "Hostname" "/etc/hostname missing"
        if [ -e "$t/etc/machine-id" ]; then
            rootfs_wb_ish_emit PASS "Machine ID" "/etc/machine-id exists"
        else
            rootfs_wb_ish_emit WARN "Machine ID" "missing; systemd-compatible roots should create /etc/machine-id"
        fi

        echo
        echo "--- iSH-AOK kernel constraints ---"
        if grep -RqsE '^[[:space:]]*(kernel\.pid_max|kernel\.threads-max|kernel\.core_pattern|kernel\.unprivileged_userns_clone|fs\.|vm\.|net\.)[[:space:]]*=' \
            "$t/etc/sysctl.conf" "$t/etc/sysctl.d" "$t/usr/lib/sysctl.d" "$t/lib/sysctl.d" 2>/dev/null; then
            rootfs_wb_ish_emit WARN "Kernel sysctl policy" "rootfs contains host-kernel sysctls; unsupported writes may be ignored or report EPERM on iSH-AOK"
        else
            rootfs_wb_ish_emit PASS "Kernel sysctl policy" "no obvious host-only sysctl settings detected"
        fi
        if [ -e "$t/etc/fstab" ] && grep -Eq '[[:space:]](fuse|cgroup2?|overlay|bpf)[[:space:]]' "$t/etc/fstab" 2>/dev/null; then
            rootfs_wb_ish_emit WARN "Filesystem requirements" "/etc/fstab requests kernel filesystems commonly unavailable in iSH-AOK"
        else
            rootfs_wb_ish_emit PASS "Filesystem requirements" "no obvious unsupported fstab entries detected"
        fi

        echo
        echo "================================"
        echo "SUMMARY: PASS=$pass  WARN=$warnc  FAIL=$fail"
        if [ "$fail" -gt 0 ]; then
            echo "BOOT READINESS: INCOMPLETE"
            echo "Resolve FAIL items before treating this rootfs as bootable on iSH-AOK."
        elif [ "$warnc" -gt 0 ]; then
            echo "BOOT READINESS: LIKELY BOOTABLE WITH WARNINGS"
            echo "No hard blocker was detected, but review WARN items for iSH-AOK compatibility."
        else
            echo "BOOT READINESS: READY"
            echo "No known Systui/iSH-AOK boot requirement is missing."
        fi
        echo
        echo "Recommended next actions:"
        [ "$has_systemd" -eq 1 ] && [ "$has_ish_systemd" -eq 0 ] && echo "  - Workbench > Install iSH-AOK systemd compatibility layer"
        [ "$engine" != chroot ] && echo "  - Workbench > Execution engine > chroot"
        [ "$mount_count" -eq 0 ] && echo "  - Workbench > Mount virtual filesystems and binds"
        [ "$fail" -gt 0 ] && echo "  - Workbench > Continue/recover interrupted rootfs generation"
        echo "  - Re-run this analyzer after repairs"
    } > "$report" 2>&1

    unset -f rootfs_wb_ish_emit 2>/dev/null || true
    tui_text "iSH-AOK boot readiness: $(basename "$t")" "$report"
}

rootfs_wb_install_ish_systemd_compat() { # <target>
    local t="$1" real_systemd=""

    [ -d "$t" ] || {
        tui_msg "iSH systemd compatibility" "Rootfs directory does not exist:\n$t"
        return 1
    }

    for real_systemd in /lib/systemd/systemd /usr/lib/systemd/systemd; do
        [ -x "$t$real_systemd" ] && break
    done
    if [ ! -x "$t$real_systemd" ]; then
        tui_msg "iSH systemd compatibility" \
"No systemd executable was found in this rootfs.

Expected one of:
/lib/systemd/systemd
/usr/lib/systemd/systemd

Install systemd in the rootfs first, then run this utility again."
        return 1
    fi

    if ! declare -F rootfs_install_ish_systemd_compat >/dev/null 2>&1; then
        tui_msg "iSH systemd compatibility" "The Systui iSH-AOK systemd compatibility installer is not loaded."
        return 1
    fi

    # This Workbench utility is intentionally host-side. Do not run apt/dpkg
    # migrations while installing the layer: partially configured Ubuntu
    # Resolute roots may still contain Rust/uutils coreutils that abort on iSH.
    if SYSTUI_ISH_COMPAT_SKIP_COREUTILS_MIGRATION=1 \
        rootfs_install_ish_systemd_compat "$t"; then
        tui_msg "iSH systemd compatibility installed" \
"Installed/refreshed the iSH-AOK systemd compatibility layer in:
$t

/sbin/init now routes through the Systui compatibility launcher on iSH-AOK.
On a normal Linux kernel the launcher hands control to the real systemd binary:
$real_systemd

This is a compatibility PID 1 for iSH-AOK; kernel features that iSH does not implement still cannot be emulated."
        return 0
    fi

    tui_msg "iSH systemd compatibility" "Could not install the compatibility layer into:\n$t"
    return 1
}

rootfs_wb_delete() { # <target>
    local t="$1"
    rootfs_wb_detach_all "$t" >/dev/null 2>&1 || true
    if [ "$(rootfs_wb_mount_count "$t" 2>/dev/null || echo 0)" != 0 ]; then
        tui_msg "Delete rootfs" "Could not detach every mount under:\n$t\n\nThe rootfs was not deleted."
        return 1
    fi
    if rootfs_rm_tree "$t"; then
        tui_msg "Rootfs deleted" "Deleted:\n$t"
        return 0
    fi
    tui_msg "Delete failed" "Could not delete:\n$t"
    return 1
}

rootfs_wb_menu_for() { # <target>
    local t="$1" c engine mounts
    [ -x "$t/bin/sh" ] || tui_msg "Warning" \
"$t has no executable /bin/sh.

You can still inspect, mount, pack, or delete it, but entering it will fail."
    while true; do
        engine=$(rootfs_wb_engine_get "$t")
        mounts=$(rootfs_wb_mount_count "$t")
        c=$(tui_menu "Workbench: $(basename "$t")" \
            "Engine: $engine   Live mounts: $mounts   Arch: $(rootfs_target_arch "$t")" \
            enter    "Enter an interactive session" \
            analyze  "Analyze iSH-AOK boot readiness and completion requirements" \
            run      "Run a single command" \
            continue "Continue/recover interrupted rootfs generation" \
            inspect  "Inspect rootfs information and disk usage" \
            ishinit  "Install iSH-AOK systemd compatibility layer" \
            engine   "Execution engine (chroot, proot, nspawn, unshare)" \
            mount    "Mount virtual filesystems and binds (persistent)" \
            detach   "Detach every mount under this rootfs" \
            binds    "Configure bind mounts" \
            status   "Mount and engine status report" \
            pack     "Pack/compress into a tarball" \
            pkg      "Package management inside the rootfs" \
            config   "In-rootfs configuration" \
            delete   "Delete this rootfs" \
            other    "Work on a different rootfs" \
            back     "Back") || return 0
        case "$c" in
            enter)    rootfs_wb_enter "$t" || true ;;
            analyze)  rootfs_wb_ish_boot_analyze "$t" ;;
            run)      rootfs_wb_run_once "$t" ;;
            continue) rootfs_continue_generation "$t" ;;
            inspect)  rootfs_wb_inspect "$t" ;;
            ishinit)  rootfs_wb_install_ish_systemd_compat "$t" || true ;;
            engine)   rootfs_wb_engine_menu "$t" ;;
            mount)
                if [ "$mounts" -gt 0 ]; then
                    tui_msg "Already mounted" "$mounts filesystem(s) are already mounted under this rootfs."
                else
                    rootfs_wb_mount_persistent "$t"
                fi ;;
            detach)
                if [ "$mounts" = 0 ]; then
                    tui_msg "Nothing mounted" "No filesystems are mounted under this rootfs."
                elif rootfs_wb_detach_all "$t"; then
                    tui_msg "Detached" "All mounts under $(basename "$t") were detached."
                else
                    tui_msg "Partly detached" "Some mounts could not be detached. See $LOGFILE."
                fi ;;
            binds)   rootfs_wb_binds_menu "$t" ;;
            status)  rootfs_wb_mount_report "$t" ;;
            pack)    rootfs_wb_pack "$t" ;;
            pkg)     rootfs_pkg_menu "$t" ;;
            config)  rootfs_cfg_menu "$t" ;;
            delete)
                if rootfs_wb_delete "$t"; then
                    return 2
                fi ;;
            other)   return 2 ;;
            back|"") return 0 ;;
        esac
    done
}

export -f rootfs_wb_inspect rootfs_wb_ish_boot_analyze rootfs_wb_install_ish_systemd_compat rootfs_wb_delete rootfs_wb_menu_for
