# shellcheck shell=bash
###############################################################################
# ROOTFS RECOVERY — distinguish incomplete bootstrap from package repair
###############################################################################

rootfs_deb_base_incomplete() { # <target>
    local t="$1"
    [ -x "$t/bin/sh" ] || return 0
    [ -x "$t/usr/bin/dpkg" ] || [ -x "$t/bin/dpkg" ] || return 0
    [ -x "$t/usr/bin/apt-get" ] || [ -x "$t/bin/apt-get" ] || return 0
    if [ -r "$t/var/lib/dpkg/status" ]; then
        awk 'BEGIN{RS=""; ok=0}
             $0 ~ /(^|\n)Package: libc6(:[^\n]+)?(\n|$)/ && $0 ~ /(^|\n)Status: install ok installed(\n|$)/ {ok=1}
             END{exit ok?0:1}' "$t/var/lib/dpkg/status" 2>/dev/null || return 0
    else
        return 0
    fi
    return 1
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

    [ -n "$distro" ] && [ -n "$release" ] && [ -n "$mirror" ] && [ -n "$backend" ] || {
        tui_msg "Bootstrap recovery unavailable" \
"The rootfs is missing essential base packages (APT and/or libc6), but its build metadata is incomplete.

Expected build state: distro, release, mirror and backend.
Do not run dpkg --configure -a yet; restore the base system first."
        return 1
    }

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

    build_debfamily "$distro" "$release" "$arch" "$mirror" "$t" "$pkgs" "$use_qemu" "$backend" || {
        rootfs_set_build_stage "$t" bootstrap-recovery-failed
        tui_msg "Bootstrap recovery failed" "The $backend base-system recovery failed. See $LOGFILE."
        return 1
    }

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

if declare -F rootfs_continue_generation >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_continue_generation_bootstrap >/dev/null 2>&1; then
    eval "$(declare -f rootfs_continue_generation | sed '1s/^rootfs_continue_generation[[:space:]]*()/_systui_base_rootfs_continue_generation_bootstrap ()/')"
fi

rootfs_continue_generation() { # <target>
    local t="$1" distro release arch mirror pkgs use_qemu backend stage action base_incomplete=0
    distro=$(rootfs_state_get "$t" DISTRO || true)
    release=$(rootfs_state_get "$t" RELEASE || true)
    arch=$(rootfs_state_get "$t" ARCH || true)
    mirror=$(rootfs_state_get "$t" MIRROR || true)
    pkgs=$(rootfs_state_get "$t" PACKAGES || true)
    use_qemu=$(rootfs_state_get "$t" USE_QEMU || true)
    backend=$(rootfs_state_get "$t" BACKEND || true)
    stage=$(rootfs_state_get "$t" STAGE || true)

    [ -n "$distro" ] || distro=$(sed -n 's/^ID=//p' "$t/etc/os-release" 2>/dev/null | tr -d '"' | head -n1)
    [ -n "$release" ] || release=$(sed -n 's/^VERSION_CODENAME=//p' "$t/etc/os-release" 2>/dev/null | tr -d '"' | head -n1)
    [ -n "$arch" ] || arch=$(host_debarch)
    [ -n "$use_qemu" ] || { needs_qemu "$arch" && use_qemu=1 || use_qemu=0; }
    backend=$(rootfs_resolve_backend "$distro" "${backend:-auto}" "$arch" "$release" 2>/dev/null || true)

    case "$distro" in debian|devuan|ubuntu|kali)
        rootfs_deb_base_incomplete "$t" && base_incomplete=1
        ;;
    esac

    if [ "$base_incomplete" -eq 1 ]; then
        action=$(tui_check "Continue generation" \
            "Detected: ${distro:-unknown} ${release:-unknown} ($arch), backend: ${backend:-unknown}, stage: ${stage:-unknown}\n\nEssential base system is incomplete. APT repair is disabled until apt-get and libc6 are restored.\nSPACE selects recovery steps:" \
            bootstrap "Restore/complete bootstrap base (apt-get + libc6)" on \
            packages "Install remaining packages after base recovery" on \
            config "Open in-rootfs configuration after recovery" on) || return 0
    else
        action=$(tui_check "Continue generation" \
            "Detected: ${distro:-unknown} ${release:-unknown} ($arch), backend: ${backend:-unknown}, stage: ${stage:-unknown}\nSPACE selects recovery steps:" \
            second "Complete interrupted debootstrap second stage" on \
            repair "Repair dpkg/APT package configuration" on \
            packages "Install remaining packages from build state" on \
            config "Open in-rootfs configuration after recovery" on) || return 0
    fi
    action=${action//\"/}

    case " $action " in *" bootstrap "*)
        rootfs_recover_deb_base "$t" "$distro" "$release" "$arch" "$mirror" "$pkgs" "$use_qemu" "$backend" || return 0
        ;;
    esac

    # If the user selected second-stage explicitly on an otherwise complete
    # rootfs, retain the original behavior.
    case " $action " in *" second "*)
        if [ -x "$t/debootstrap/debootstrap" ]; then
            if run_cmd "Complete debootstrap second stage" rootfs_run_second_stage "$t" "$arch" "$use_qemu"; then
                rootfs_set_build_stage "$t" bootstrap-complete
            else
                rootfs_set_build_stage "$t" bootstrap-second-stage-failed
                return 0
            fi
        fi ;;
    esac

    # Never enter dpkg repair if the essential base is still incomplete.
    if rootfs_deb_base_incomplete "$t"; then
        tui_msg "Package repair deferred" "apt-get and/or libc6 are still missing. Restore the bootstrap base before running dpkg/APT repair."
        return 0
    fi

    case " $action " in *" repair "*)
        if [ "$(rootfs_detect_pm "$t")" = apt ]; then
            rootfs_chroot_exec "$t" "Repair package configuration" \
                "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -f install -y && dpkg --configure -a && apt-get -f install -y" || true
        fi ;;
    esac
    case " $action " in *" packages "*)
        if [ -n "${pkgs//[[:space:]]/}" ] && [ "$(rootfs_detect_pm "$t")" = apt ]; then
            rootfs_install_deb_packages "$t" "$pkgs" || true
        fi ;;
    esac
    rootfs_set_build_stage "$t" recovered
    case " $action " in *" config "*) rootfs_cfg_menu "$t" ;; esac
    tui_msg "Recovery complete" "Generation recovery finished for:\n$t\n\nReview the log for any package-specific warnings: $LOGFILE"
}

export -f rootfs_deb_base_incomplete rootfs_recover_deb_base rootfs_continue_generation
