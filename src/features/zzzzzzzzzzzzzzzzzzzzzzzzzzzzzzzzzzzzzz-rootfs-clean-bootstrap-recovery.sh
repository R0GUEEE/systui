# shellcheck shell=bash
###############################################################################
# ROOTFS RECOVERY — clean rebuild for contaminated mmdebstrap roots
###############################################################################

rootfs_recover_deb_base_clean_stage() { # <target> <distro> <release> <arch> <mirror> <packages> <use_qemu> <backend>
    local t="$1" distro="$2" release="$3" arch="$4" mirror="$5" pkgs="$6" use_qemu="$7" backend="$8"
    local parent base stage backup f

    parent=$(dirname "$t")
    base=$(basename "$t")
    stage="$parent/.${base}.systui-recovery.$$"
    backup="$parent/.${base}.systui-broken.$$"

    if declare -F rootfs_wb_detach_all >/dev/null 2>&1; then
        rootfs_wb_detach_all "$t" >/dev/null 2>&1 || true
    fi
    if declare -F rootfs_wb_mount_count >/dev/null 2>&1 && \
       [ "$(rootfs_wb_mount_count "$t" 2>/dev/null || printf '0')" -gt 0 ]; then
        tui_msg "Bootstrap recovery blocked" "Live mounts still exist below:\n$t\n\nDetach them before rebuilding the contaminated base."
        return 1
    fi

    rm -rf -- "$stage" 2>/dev/null || true
    mkdir -p "$stage" || return 1

    # Preserve backend choices in the clean staging tree when the original
    # partial build contains Systui backend configuration/state files.
    for f in "$t"/.systui-*; do
        [ -f "$f" ] || continue
        cp -p -- "$f" "$stage/" 2>/dev/null || true
    done
    [ -f "$t/etc/systui-build.conf" ] && {
        mkdir -p "$stage/etc"
        cp -p -- "$t/etc/systui-build.conf" "$stage/etc/systui-build.conf" 2>/dev/null || true
    }

    log "rootfs: rebuilding contaminated $backend base in clean stage $stage"
    if ! SYSTUI_UNSHARE_SUPPORTED=0 \
        build_debfamily "$distro" "$release" "$arch" "$mirror" "$stage" "$pkgs" "$use_qemu" "$backend"; then
        rootfs_set_build_stage "$t" bootstrap-clean-recovery-failed
        rm -rf -- "$stage" 2>/dev/null || true
        tui_msg "Bootstrap recovery failed" \
"The clean $backend staging build failed.\n\nThe original partial rootfs was left untouched:\n$t\n\nSee $LOGFILE."
        return 1
    fi

    if rootfs_deb_base_incomplete "$stage"; then
        rootfs_set_build_stage "$t" bootstrap-clean-essential-missing
        rm -rf -- "$stage" 2>/dev/null || true
        tui_msg "Clean base still incomplete" \
"The staging bootstrap completed but apt-get and/or libc6 is still missing.\n\nThe original rootfs was not replaced."
        return 1
    fi

    # Only replace the broken tree after the clean staging root has passed the
    # essential-base test.  Same-parent renames are atomic on a normal fs.
    mv -- "$t" "$backup" || {
        rm -rf -- "$stage" 2>/dev/null || true
        return 1
    }
    if ! mv -- "$stage" "$t"; then
        mv -- "$backup" "$t" 2>/dev/null || true
        return 1
    fi

    # Carry the authoritative build state forward. The clean bootstrap may
    # have created its own transient stage markers; recovery must retain the
    # user's original build selections and then mark the base complete.
    [ -f "$backup/.systui-build-state" ] && cp -p -- "$backup/.systui-build-state" "$t/.systui-build-state" 2>/dev/null || true
    [ -f "$backup/etc/systui-build.conf" ] && {
        mkdir -p "$t/etc"
        cp -p -- "$backup/etc/systui-build.conf" "$t/etc/systui-build.conf" 2>/dev/null || true
    }
    rootfs_set_build_stage "$t" bootstrap-complete

    # The old partial tree is no longer useful once the replacement passed
    # validation. Remove it to avoid doubling storage consumption on iSH.
    rm -rf -- "$backup" 2>/dev/null || true
    log "rootfs: replaced contaminated partial root with verified clean base at $t"
    return 0
}

if declare -F rootfs_recover_deb_base >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_recover_deb_base_clean >/dev/null 2>&1; then
    eval "$(declare -f rootfs_recover_deb_base | sed '1s/^rootfs_recover_deb_base[[:space:]]*()/_systui_base_rootfs_recover_deb_base_clean ()/')"
fi

rootfs_recover_deb_base() { # <target> <distro> <release> <arch> <mirror> <packages> <use_qemu> <backend>
    local t="$1" distro="$2" release="$3" arch="$4" mirror="$5" pkgs="$6" use_qemu="$7" backend="$8"

    # If this is a classic debootstrap tree, let the established recovery path
    # attempt its second stage first. mmdebstrap/bdebstrap do not have that
    # recoverable second-stage layout and must not be rerun into a poisoned dpkg
    # database when libc6 is absent.
    case "$backend" in
        mmdebstrap|bdebstrap)
            rootfs_deb_base_incomplete "$t" || return 0
            tui_yesno "Rebuild incomplete base cleanly" \
"This partial $backend rootfs has an inconsistent essential package database (for example packages recorded as installed while libc6 is missing).\n\nRerunning $backend in place cannot repair that state. Systui will build a clean base beside it, verify apt-get + libc6, and only then replace the broken partial tree.\n\nContinue?" || return 1
            rootfs_recover_deb_base_clean_stage "$t" "$distro" "$release" "$arch" "$mirror" "$pkgs" "$use_qemu" "$backend"
            ;;
        *)
            _systui_base_rootfs_recover_deb_base_clean "$@"
            ;;
    esac
}

export -f rootfs_recover_deb_base_clean_stage rootfs_recover_deb_base
