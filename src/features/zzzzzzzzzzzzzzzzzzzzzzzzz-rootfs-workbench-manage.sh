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

rootfs_wb_delete() { # <target>
    local t="$1"
    # The old Manage workflow intentionally deletes without an extra confirmation.
    # Never remove a tree while host filesystems are still mounted beneath it.
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

# Override the per-rootfs workbench menu so management is available in the
# same place as mounting, package management, configuration, and packing.
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
            run      "Run a single command" \
            continue "Continue/recover interrupted rootfs generation" \
            inspect  "Inspect rootfs information and disk usage" \
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
            run)      rootfs_wb_run_once "$t" ;;
            continue) rootfs_continue_generation "$t" ;;
            inspect)  rootfs_wb_inspect "$t" ;;
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

export -f rootfs_wb_inspect rootfs_wb_delete rootfs_wb_menu_for
