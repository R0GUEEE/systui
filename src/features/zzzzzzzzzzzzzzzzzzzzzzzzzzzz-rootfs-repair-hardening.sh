# shellcheck shell=bash
###############################################################################
# ROOTFS REPAIR HARDENING — essential-base recovery that explains itself
#
# Reported symptom: running "Continue/recover interrupted rootfs generation" (or
# the readiness repair) on a rootfs whose base is incomplete ended with
#
#   Package repair deferred
#   apt-get and/or libc6 are still missing. Restore the bootstrap base before
#   running dpkg/APT repair.
#
# That message is circular (the user is already in the restore flow), it names
# nothing specific, and it is reached whenever the selection coming back from
# the checklist is empty — including the case where a dialog build returns
# success without capturing the selection, which is what makes the screen look
# like it simply "went back to the menu".
#
# This module:
#   * re-asks once instead of acting on an uncaptured checklist selection;
#   * reuses the bootstrap repair that the readiness menu already queued, so the
#     same restore is not offered (and rebuilt) twice in one pass;
#   * derives the mirror from the tree or from a distribution default instead of
#     refusing recovery when only MIRROR is missing from the build state;
#   * replaces the circular message with the exact missing components plus an
#     offer to restore them.
###############################################################################

# Write the recovery metadata for a tree, filling gaps that the build state may
# not carry (notably MIRROR for imported or older roots).
rootfs_deb_recovery_metadata() { # <target> -> distro|release|arch|mirror|packages|use_qemu|backend
    local t="$1" distro release arch mirror pkgs use_qemu backend

    distro=$(rootfs_state_get "$t" DISTRO 2>/dev/null || true)
    release=$(rootfs_state_get "$t" RELEASE 2>/dev/null || true)
    arch=$(rootfs_state_get "$t" ARCH 2>/dev/null || true)
    mirror=$(rootfs_state_get "$t" MIRROR 2>/dev/null || true)
    pkgs=$(rootfs_state_get "$t" PACKAGES 2>/dev/null || true)
    use_qemu=$(rootfs_state_get "$t" USE_QEMU 2>/dev/null || true)
    backend=$(rootfs_state_get "$t" BACKEND 2>/dev/null || true)

    [ -n "$distro" ] || distro=$(sed -n 's/^ID=//p' "$t/etc/os-release" 2>/dev/null | tr -d '"' | head -n1)
    [ -n "$release" ] || release=$(sed -n 's/^VERSION_CODENAME=//p' "$t/etc/os-release" 2>/dev/null | tr -d '"' | head -n1)
    [ -n "$arch" ] || arch=$(host_debarch)
    [ -n "$mirror" ] || mirror=$(rootfs_deb_mirror_from_tree "$t" 2>/dev/null || true)
    [ -n "$mirror" ] || mirror=$(rootfs_deb_default_mirror "$distro" 2>/dev/null || true)
    [ -n "$use_qemu" ] || { needs_qemu "$arch" && use_qemu=1 || use_qemu=0; }

    # A backend recorded by another machine can be unusable here (for example an
    # arm64 rootfs recorded on an x86_64 host, where the catalogue offers
    # qemu-debootstrap instead of mmdebstrap). Fall back to whatever this host
    # can actually use, and only keep the recorded name when nothing else
    # resolves, so the caller can still report it.
    local recorded="$backend" resolved=""
    resolved=$(rootfs_resolve_backend "$distro" "${recorded:-auto}" "$arch" "$release" 2>/dev/null || true)
    if [ -z "$resolved" ] && [ -n "$recorded" ]; then
        warn "rootfs: backend '$recorded' is not offered for $distro $release ($arch) here; resolving another"
        resolved=$(rootfs_resolve_backend "$distro" auto "$arch" "$release" 2>/dev/null || true)
    fi
    [ -n "$resolved" ] || resolved="$recorded"
    backend="$resolved"

    printf '%s|%s|%s|%s|%s|%s|%s\n' \
        "$distro" "$release" "$arch" "$mirror" "$pkgs" "$use_qemu" "$backend"
}

# Mirror recorded inside the rootfs itself, if any. APT lines are either
#   deb http://host/debian suite components
#   deb [arch=arm64 signed-by=...] http://host/debian suite components
#   URIs: http://host/debian            (deb822 sources)
# so scan the tokens and take the first one that carries a URL scheme. Pure
# Bash: this runs on the repair path, where an external text tool that wedges
# (measured on iSH) would leave the user with no recovery at all.
rootfs_deb_mirror_from_tree() { # <target>
    local t="$1" f line rest word
    for f in "$t/etc/apt/sources.list" "$t"/etc/apt/sources.list.d/*.list "$t"/etc/apt/sources.list.d/*.sources; do
        [ -r "$f" ] || continue
        while IFS= read -r line; do
            case "$line" in
                ''|'#'*) continue ;;
                deb*|URIs:*) ;;
                *) continue ;;
            esac
            rest="$line"
            while [ -n "$rest" ]; do
                word="${rest%%[[:space:]]*}"
                rest="${rest#"$word"}"
                rest="${rest#"${rest%%[![:space:]]*}"}"
                case "$word" in
                    *://*)
                        printf '%s\n' "$word"
                        return 0 ;;
                esac
            done
        done < "$f"
    done
    return 1
}

# Distribution default mirror, used when the build state and the in-rootfs APT
# configuration carry none.
rootfs_deb_default_mirror() { # <distro>
    case "$1" in
        debian) printf 'http://deb.debian.org/debian\n' ;;
        devuan) printf 'http://deb.devuan.org/merged\n' ;;
        ubuntu) printf 'http://archive.ubuntu.com/ubuntu\n' ;;
        kali)   printf 'http://http.kali.org/kali\n' ;;
        *) return 1 ;;
    esac
}

# Checklist wrapper: a dialog that reports success but captures no selection is
# a widget hiccup on some iSH dialog builds, and an empty selection used to mean
# "do nothing" with no explanation. Ask once more, then let the caller decide.
rootfs_ui_check_required() { # <title> <text> <items...> -> selection
    local title="$1" text="$2" out="" rc=0
    shift 2

    out=$(tui_check "$title" "$text" "$@") || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    if [ -z "${out//[[:space:]\"]/}" ]; then
        warn "rootfs: checklist '$title' returned no selection; re-asking"
        out=$(tui_check "$title" \
            "No step was captured from the previous dialog — select the steps to run (SPACE toggles, ENTER applies).

$text" "$@") || return $?
    fi
    printf '%s\n' "$out"
}

# Replace the circular deferred-repair message: name the missing components and
# offer the restore that the caller could not complete.
rootfs_deb_report_incomplete() { # <target> <reason>
    local t="$1" reason="${2:-}" gaps

    gaps=$(rootfs_deb_base_gaps "$t")
    [ -n "$gaps" ] || gaps="essential base packages"

    if ! rootfs_tree_is_deb_family "$t"; then
        tui_msg "Package repair deferred" \
"Essential base components are missing ($gaps), but this tree is not Debian-family.

Automatic bootstrap recovery only applies to dpkg/APT rootfs trees.
Rebuild or re-import this rootfs to restore its package manager."
        return 0
    fi

    case "$reason" in
        failed)
            tui_msg "Base system still incomplete" \
"The bootstrap restore finished, but these essential components are still missing:

  $gaps

The backend did not complete the base system. See $LOGFILE for its output, then
retry the restore or rebuild the rootfs." ;;
        declined)
            tui_msg "Package repair deferred" \
"These essential components are still missing:

  $gaps

dpkg/APT repair cannot run until the base system is restored.
Run this recovery again and keep the "Restore/complete bootstrap base" step
selected, or rebuild the rootfs." ;;
        *)
            tui_msg "Restore not run" \
"These essential components are still missing:

  $gaps

No base restore was run in this pass, so the rootfs is unchanged." ;;
    esac
    return 0
}

# Restore the base using derived metadata; reports its own failures.
rootfs_deb_restore_base() { # <target>
    local t="$1" distro release arch mirror pkgs use_qemu backend

    IFS='|' read -r distro release arch mirror pkgs use_qemu backend <<< "$(rootfs_deb_recovery_metadata "$t")"
    rootfs_recover_deb_base "$t" "$distro" "$release" "$arch" "$mirror" "$pkgs" "$use_qemu" "$backend"
}

# ---------------------------------------------------------------------------
# Continue/recover — hardened final override.
# The bootstrap step is skipped when the readiness repair menu already queued
# it: that menu offers both entries, and running it twice asked the user the
# same question and rebuilt the same base twice.
# ---------------------------------------------------------------------------
rootfs_continue_generation() { # <target>
    local t="$1" distro release arch mirror pkgs use_qemu backend stage action
    local base_incomplete=0 restore_requested=0 bootstrap_done=0 rc=0

    IFS='|' read -r distro release arch mirror pkgs use_qemu backend <<< "$(rootfs_deb_recovery_metadata "$t")"
    stage=$(rootfs_state_get "$t" STAGE 2>/dev/null || true)

    case "$distro" in
        debian|devuan|ubuntu|kali) rootfs_deb_base_incomplete "$t" && base_incomplete=1 ;;
    esac

    case " ${SYSTUI_REPAIR_SELECTED:-} " in
        *" bootstrap "*) restore_requested=1 ;;
    esac

    if [ "$base_incomplete" -eq 1 ]; then
        if [ "$restore_requested" -eq 1 ]; then
            # Already selected in the readiness repair menu: apply it without
            # asking the same question again.
            action="bootstrap"
            if [ -n "${pkgs//[[:space:]]/}" ]; then action="$action packages"; fi
        else
            action=$(rootfs_ui_check_required "Continue generation" \
                "Detected: ${distro:-unknown} ${release:-unknown} ($arch), backend: ${backend:-unknown}, stage: ${stage:-unknown}

Essential base system is incomplete. APT repair is disabled until apt-get and libc6 are restored.
SPACE selects recovery steps:" \
                bootstrap "Restore/complete bootstrap base (apt-get + libc6)" on \
                packages "Install remaining packages after base recovery" on \
                config "Open in-rootfs configuration after recovery" on) || return 0
        fi
    else
        action=$(rootfs_ui_check_required "Continue generation" \
            "Detected: ${distro:-unknown} ${release:-unknown} ($arch), backend: ${backend:-unknown}, stage: ${stage:-unknown}
SPACE selects recovery steps:" \
            second "Complete interrupted debootstrap second stage" on \
            repair "Repair dpkg/APT package configuration" on \
            packages "Install remaining packages from build state" on \
            config "Open in-rootfs configuration after recovery" on) || return 0
    fi
    action=${action//\"/}
    action=${action//$'\n'/ }

    if [ -z "${action//[[:space:]]/}" ] && [ "$base_incomplete" -eq 1 ]; then
        rootfs_deb_report_incomplete "$t" declined
        return 0
    fi

    case " $action " in *" bootstrap "*)
        if rootfs_deb_restore_base "$t"; then
            bootstrap_done=1
            log "rootfs: bootstrap base restored for $t"
        else
            # rootfs_recover_deb_base already reported the concrete failure.
            warn "rootfs: bootstrap restore did not complete for $t"
            return 0
        fi
        if rootfs_deb_base_incomplete "$t"; then
            rootfs_deb_report_incomplete "$t" failed
            return 0
        fi
        ;;
    esac

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

    if rootfs_deb_base_incomplete "$t"; then
        if [ "$bootstrap_done" -eq 1 ]; then
            rootfs_deb_report_incomplete "$t" failed
        elif [ "$restore_requested" -eq 0 ]; then
            # The restore step was offered but not selected: say why the rest of
            # the recovery is blocked and let the user choose to run it now.
            if tui_yesno "Restore missing bootstrap base" \
"These essential components are missing:

  $(rootfs_deb_base_gaps "$t")

Restore the ${distro:-Debian} bootstrap base now?"; then
                if rootfs_deb_restore_base "$t" && ! rootfs_deb_base_incomplete "$t"; then
                    bootstrap_done=1
                else
                    warn "rootfs: bootstrap restore did not complete for $t"
                    return 0
                fi
            else
                rootfs_deb_report_incomplete "$t" declined
                return 0
            fi
        else
            rootfs_deb_report_incomplete "$t" declined
            return 0
        fi
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

# ---------------------------------------------------------------------------
# Readiness repair menu — remembers what the user selected so the recovery it
# triggers does not ask the same question twice.
# ---------------------------------------------------------------------------
rootfs_wb_ish_repair_menu() { # <target>
    local t="$1" selected tag desc state rc=0 fixed=0 failed=0
    local -a args=()

    while IFS='|' read -r tag desc state; do
        [ -n "$tag" ] || continue
        case " ${args[*]} " in *" $tag "*) continue ;; esac
        args+=("$tag" "$desc" "${state:-on}")
    done <<< "$(rootfs_wb_ish_repair_choices "$t")"

    if [ ${#args[@]} -eq 0 ]; then
        tui_msg "iSH-AOK readiness" "No automatically repairable readiness issues were detected.\n\nReview any remaining warnings in the scan report manually."
        return 0
    fi

    selected=$(rootfs_ui_check_required "Repair iSH-AOK readiness" \
        "SPACE selects repairs; ENTER applies them. Only issues detected by the readiness scan are offered." \
        "${args[@]}") || return 0
    selected=${selected//\"/}
    selected=${selected//$'\n'/ }
    if [ -z "${selected//[[:space:]]/}" ]; then
        tui_msg "iSH-AOK readiness" \
"No repair step was selected, so the rootfs was left unchanged.

Re-run the scan and select the repairs to apply with SPACE."
        return 0
    fi

    SYSTUI_REPAIR_SELECTED=" $selected "
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
    unset SYSTUI_REPAIR_SELECTED

    tui_msg "Readiness repairs complete" \
"Completed: $fixed
Failed: $failed

Systui will now run the readiness scan again so you can verify the remaining requirements."
    return 0
}

# ---------------------------------------------------------------------------
# Workbench bootstrap repair — derive metadata (including a default mirror)
# instead of failing on a thin build state.
# ---------------------------------------------------------------------------
rootfs_wb_ish_fix_bootstrap() { # <target>
    local t="$1" distro release arch mirror pkgs use_qemu backend

    IFS='|' read -r distro release arch mirror pkgs use_qemu backend <<< "$(rootfs_deb_recovery_metadata "$t")"
    rootfs_recover_deb_base "$t" "$distro" "$release" "$arch" "$mirror" "$pkgs" "$use_qemu" "$backend"
}
