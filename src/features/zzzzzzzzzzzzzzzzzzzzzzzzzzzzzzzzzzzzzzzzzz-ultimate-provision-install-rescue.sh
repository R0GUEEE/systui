# shellcheck shell=bash
###############################################################################
# ULTIMATE PROVISION — installation rescue / validated optional patches
###############################################################################

# The bundled provision script is the authoritative install payload. Late
# compatibility optimizations must never make a successful file installation
# look like a failed install in the UI.
script_provision_install_tool() {
    local source tool tool_dir
    source=$(script_provision_source_path)
    tool=$(script_provision_tool_path)
    tool_dir=$(dirname "$tool")

    [ -r "$source" ] || return 1
    mkdir -p "$tool_dir" || return 1
    install -m 0755 "$source" "$tool" || return 1

    # Apply compatibility patches opportunistically. A rejected transform must
    # leave the valid bundled tool installed instead of failing installation.
    if declare -F script_provision_patch_init_detection >/dev/null 2>&1; then
        script_provision_patch_init_detection "$tool" || warn "Ultimate Provision init-detection patch was skipped."
    fi
    if declare -F script_provision_patch_apt_nonblocking >/dev/null 2>&1; then
        script_provision_patch_apt_nonblocking "$tool" || warn "Ultimate Provision non-blocking APT patch was skipped."
    fi
    if declare -F script_provision_patch_apt_batches >/dev/null 2>&1; then
        script_provision_patch_apt_batches "$tool" || warn "Ultimate Provision APT batching patch was skipped."
    fi

    # Never leave a malformed transformed script installed. If any optional
    # patch produced invalid shell syntax, restore the pristine bundled copy.
    if ! sh -n "$tool" >/dev/null 2>&1; then
        warn "Ultimate Provision compatibility transform produced invalid shell; restoring bundled tool."
        install -m 0755 "$source" "$tool" || return 1
        if declare -F script_provision_patch_init_detection >/dev/null 2>&1; then
            script_provision_patch_init_detection "$tool" >/dev/null 2>&1 || true
        fi
        if declare -F script_provision_patch_apt_nonblocking >/dev/null 2>&1; then
            script_provision_patch_apt_nonblocking "$tool" >/dev/null 2>&1 || true
        fi
        # Do not retry the batching transform after a syntax failure.
        sh -n "$tool" >/dev/null 2>&1 || {
            install -m 0755 "$source" "$tool" || return 1
        }
    fi

    chmod 0755 "$tool" 2>/dev/null || true
    return 0
}

# Running an already-installed tool should also tolerate an optional batching
# patch failure. The startup and non-blocking APT fixes remain best-effort here;
# the installed tool itself is still runnable if those transforms cannot apply.
script_provision_run() {
    local script rc=0
    script=$(script_provision_tool_path)
    [ -x "$script" ] || {
        tui_msg "Ultimate Provision Not Installed" "Install Ultimate Provision before running it."
        return 0
    }

    if declare -F script_provision_patch_init_detection >/dev/null 2>&1; then
        script_provision_patch_init_detection "$script" >/dev/null 2>&1 || true
    fi
    if declare -F script_provision_patch_apt_nonblocking >/dev/null 2>&1; then
        script_provision_patch_apt_nonblocking "$script" >/dev/null 2>&1 || true
    fi
    if declare -F script_provision_patch_apt_batches >/dev/null 2>&1; then
        script_provision_patch_apt_batches "$script" >/dev/null 2>&1 || true
    fi

    if ! sh -n "$script" >/dev/null 2>&1; then
        tui_msg "Ultimate Provision" "The installed provision tool failed shell syntax validation. Reinstall it from the Ultimate Provision menu."
        return 0
    fi

    case "$(script_provision_system_status)" in
        compatible*) ;;
        *)
            tui_msg "Unsupported System" "No supported package manager was found. Supported: APT, APK, pacman, DNF/YUM, zypper, XBPS, and Portage."
            return 0
            ;;
    esac

    script_provision_review
    tui_yesno "Confirm Provisioning" "Run the bundled provision script now?\n\nThis installs packages and changes system-wide configuration." || return 0
    script_provision_save
    clear
    if env TZ_NAME="$SCRIPT_PROV_TZ" \
        TARGET_USER="$SCRIPT_PROV_USER" \
        NEW_HOSTNAME="$SCRIPT_PROV_HOST" \
        SUDO_NOPASSWD="$SCRIPT_PROV_NOPASS" \
        sh "$script"; then
        rc=0
    else
        rc=$?
    fi
    echo
    if [ "$rc" -eq 0 ]; then
        echo "Provisioning completed successfully."
    else
        echo "Provisioning failed with status $rc."
    fi
    read -rp "Press Enter to return to systui..." _ || true
    return 0
}

export -f script_provision_install_tool script_provision_run
