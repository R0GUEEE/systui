# shellcheck shell=bash
###############################################################################
# ROOTFS RECOVERY — distinguish incomplete bootstrap from package repair
###############################################################################

# Is this tree a Debian-family (dpkg/APT) rootfs? The essential-base predicate
# below is meaningless for Alpine/Arch/Fedora/Void trees: those legitimately
# have no dpkg, apt-get or glibc, and reporting them as an "incomplete Debian
# bootstrap" made the readiness scan offer a repair that cannot apply.
# Unknown trees stay Debian-family: a partially built Debian rootfs may not
# contain dpkg yet, and that is exactly the case this recovery exists for.
rootfs_tree_is_deb_family() { # <target>
    local t="$1" id="" like="" f b

    [ -d "$t" ] || return 1

    # dpkg tooling or a dpkg database is authoritative, whatever the vendor
    # strings say.
    if [ -x "$t/usr/bin/dpkg" ] || [ -x "$t/bin/dpkg" ] || [ -r "$t/var/lib/dpkg/status" ]; then
        return 0
    fi

    id=$(sed -n 's/^ID=//p' "$t/etc/os-release" 2>/dev/null | tr -d '"' | head -n1)
    like=$(sed -n 's/^ID_LIKE=//p' "$t/etc/os-release" 2>/dev/null | tr -d '"' | head -n1)
    case " $id $like " in
        *debian*|*ubuntu*|*devuan*|*kali*) return 0 ;;
    esac
    case "$id" in
        alpine|arch|archarm|fedora|centos|rhel|rocky|almalinux|opensuse*|suse|sles|gentoo|void|nixos|solus|clear-linux-os|amzn|manjaro|endeavouros|garuda)
            return 1 ;;
    esac

    # Any distribution marker file other than the Debian ones is decisive.
    for f in "$t"/etc/*-release; do
        [ -e "$f" ] || continue
        b=$(basename "$f")
        case "$b" in
            os-release|lsb-release|debian_version|*-upstream-release) continue ;;
        esac
        return 1
    done

    return 0
}

# Which essential base components are physically missing, as a printable list.
rootfs_deb_base_gaps() { # <target>
    local t="$1" gaps=""
    if [ ! -x "$t/bin/sh" ] && [ ! -x "$t/usr/bin/sh" ]; then gaps="$gaps /bin/sh"; fi
    if [ ! -x "$t/usr/bin/dpkg" ] && [ ! -x "$t/bin/dpkg" ]; then gaps="$gaps dpkg"; fi
    if [ ! -x "$t/usr/bin/apt-get" ] && [ ! -x "$t/bin/apt-get" ]; then gaps="$gaps apt-get"; fi
    rootfs_deb_libc_present "$t" || gaps="$gaps libc6"
    printf '%s\n' "${gaps# }"
}

rootfs_deb_libc_present() { # <target>
    local t="$1" p
    # Readiness is about whether the bootstrap runtime physically exists, not
    # whether dpkg has finished configuring libc6. A half-configured/unpacked
    # libc6 is exactly the state that dpkg --configure -a is meant to repair.
    for p in \
        "$t"/lib/*-linux-gnu/libc.so.6 \
        "$t"/usr/lib/*-linux-gnu/libc.so.6 \
        "$t"/lib/libc.so.6 \
        "$t"/usr/lib/libc.so.6; do
        [ -e "$p" ] || [ -L "$p" ] || continue
        return 0
    done
    return 1
}

rootfs_deb_base_incomplete() { # <target>
    local t="$1"
    # Another distribution (Alpine, Arch, Fedora, ...) never has a Debian-family
    # bootstrap base to restore; do not report it as incomplete.
    rootfs_tree_is_deb_family "$t" || return 1
    # A healthy tree can hold "/bin/sh -> /usr/bin/dash", which the host's
    # [ -x ] resolves against the HOST root and reports as missing. Ask the
    # in-tree resolver first so a good rootfs is never sent to base recovery.
    if declare -F rootfs_tree_shell_usable >/dev/null 2>&1; then
        rootfs_tree_shell_usable "$t" || return 0
    else
        [ -x "$t/bin/sh" ] || [ -x "$t/usr/bin/sh" ] || return 0
    fi
    [ -x "$t/usr/bin/dpkg" ] || [ -x "$t/bin/dpkg" ] || return 0
    [ -x "$t/usr/bin/apt-get" ] || [ -x "$t/bin/apt-get" ] || return 0
    rootfs_deb_libc_present "$t" || return 0
    return 1
}

# mmdebstrap recovery on iSH-AOK must not inherit stale virtual filesystems or
# device nodes from a previous failed attempt.  In particular, mmdebstrap's
# setup hook creates /dev/console itself and aborts if an old node already
# exists.  It also probes mount namespaces unless Systui explicitly tells the
# wrapper that unshare is unavailable.
rootfs_recover_mmdebstrap_prepare() { # <target>
    local t="$1" p

    if declare -F rootfs_wb_detach_all >/dev/null 2>&1; then
        rootfs_wb_detach_all "$t" >/dev/null 2>&1 || true
    fi

    # Do not remove the /dev directory itself; only clear runtime/device
    # contents so mmdebstrap can recreate exactly what its setup stage needs.
    if [ -d "$t/dev" ]; then
        for p in "$t/dev"/* "$t/dev"/.[!.]* "$t/dev"/..?*; do
            [ -e "$p" ] || [ -L "$p" ] || continue
            rootfs_rm_tree "$p" 2>/dev/null || rm -rf -- "$p" 2>/dev/null || true
        done
    fi
    mkdir -p "$t/dev" "$t/proc" "$t/sys" "$t/run" "$t/tmp" || return 1

    # These files are safe for mmdebstrap to replace/retain, but stale device
    # nodes are not.  Explicitly remove the common fatal collision as a final
    # guard for BusyBox glob edge cases.
    rm -f -- "$t/dev/console" "$t/dev/null" "$t/dev/zero" "$t/dev/full" \
        "$t/dev/random" "$t/dev/urandom" "$t/dev/tty" 2>/dev/null || true

    return 0
}

rootfs_recover_deb_base() { # <target> <distro> <release> <arch> <mirror> <packages> <use_qemu> <backend>
    local t="$1" distro="$2" release="$3" arch="$4" mirror="$5" pkgs="$6" use_qemu="$7" backend="$8"

    # A classic debootstrap tree may already contain everything needed to finish
    # the interrupted second stage. Prefer that because it does not discard the
    # partial rootfs and restores apt/libc from the package cache it already has.
    if [ -x "$t/debootstrap/debootstrap" ]; then
        if run_cmd "Complete interrupted debootstrap base system" \
            rootfs_run_second_stage "$t" "$arch" "$use_qemu"; then
            rootfs_set_build_stage "$t" bootstrap-complete
        else
            rootfs_set_build_stage "$t" bootstrap-second-stage-failed
        fi
    fi

    rootfs_deb_base_incomplete "$t" || return 0

    local missing=""
    [ -n "$distro" ]  || missing="$missing DISTRO"
    [ -n "$release" ] || missing="$missing RELEASE"
    [ -n "$mirror" ]  || missing="$missing MIRROR"
    [ -n "$backend" ] || missing="$missing BACKEND"
    if [ -n "$missing" ]; then
        tui_msg "Bootstrap recovery unavailable" \
"The rootfs is missing essential base packages ($(rootfs_deb_base_gaps "$t")), but the build metadata needed to restore them is incomplete.

Missing:$missing

Those values come from the rootfs build state. Rebuild the rootfs, or restore its state file, and run this recovery again.
Do not run dpkg --configure -a against this tree yet."
        return 1
    fi

    case "$distro" in
        debian|devuan|ubuntu|kali) ;;
        *) tui_msg "Unsupported bootstrap recovery" "Automatic essential-base recovery currently supports Debian-family rootfs trees."; return 1 ;;
    esac

    tui_yesno "Restore incomplete base system" \
"This rootfs has dpkg but is missing essential bootstrap components:

  apt-get: $([ -x "$t/usr/bin/apt-get" ] || [ -x "$t/bin/apt-get" ] && echo present || echo MISSING)
  libc6:   $(awk 'BEGIN{RS=""; ok=0} $0 ~ /(^|\n)Package: libc6(:[^\n]+)?(\n|$)/ && $0 ~ /(^|\n)Status: install ok installed(\n|$)/ {ok=1} END{print ok?"installed":"MISSING/not configured"}' "$t/var/lib/dpkg/status" 2>/dev/null)

Systui must resume/re-run the $backend bootstrap before package repair.
Continue?" || return 1

    case "$backend" in
        mmdebstrap|bdebstrap)
            rootfs_recover_mmdebstrap_prepare "$t" || {
                rootfs_set_build_stage "$t" bootstrap-recovery-prepare-failed
                tui_msg "Bootstrap recovery failed" "Could not clear stale mounts/device nodes from the partial rootfs."
                return 1
            }
            # Force the mmdebstrap/usr-merge compatibility wrapper into its
            # no-unshare path for this recovery attempt. SYSTUI_UNSHARE_SUPPORTED
            # is readonly (set once by the host capability probe), so a prefix
            # assignment to it only printed "readonly variable"; the writable
            # companion below is what the wrapper actually honours.
            SYSTUI_RECOVERY_NO_UNSHARE=1 \
                build_debfamily "$distro" "$release" "$arch" "$mirror" "$t" "$pkgs" "$use_qemu" "$backend" || {
                    rootfs_set_build_stage "$t" bootstrap-recovery-failed
                    tui_msg "Bootstrap recovery failed" "The $backend base-system recovery failed. See $LOGFILE."
                    return 1
                }
            ;;
        *)
            build_debfamily "$distro" "$release" "$arch" "$mirror" "$t" "$pkgs" "$use_qemu" "$backend" || {
                rootfs_set_build_stage "$t" bootstrap-recovery-failed
                tui_msg "Bootstrap recovery failed" "The $backend base-system recovery failed. See $LOGFILE."
                return 1
            }
            ;;
    esac

    if rootfs_deb_base_incomplete "$t"; then
        rootfs_set_build_stage "$t" bootstrap-essential-missing
        tui_msg "Base system still incomplete" \
"Bootstrap returned, but apt-get and/or an installed libc6 are still missing.

Systui will not run dpkg package repair against this rootfs yet."
        return 1
    fi

    rootfs_set_build_stage "$t" bootstrap-complete
    return 0
}

# The Continue/recover workflow is reimplemented in the final hardening module
# (zzzzzzzzzzzzzzzzzzzzzzzzzzzz-rootfs-repair-hardening.sh), which adds the
# essential-base diagnosis, the empty-selection re-ask and the watchdog-safe
# restore. Keeping a second copy here only let a stale, unreachable message
# reach users again.

export -f rootfs_deb_libc_present rootfs_deb_base_incomplete rootfs_recover_mmdebstrap_prepare rootfs_recover_deb_base
