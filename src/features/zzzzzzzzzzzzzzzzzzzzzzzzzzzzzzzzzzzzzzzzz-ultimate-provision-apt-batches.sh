# shellcheck shell=bash
###############################################################################
# ULTIMATE PROVISION — bounded APT batches for iSH-AOK
#
# Large cached APT transactions can appear to hang after dependency resolution
# on iSH-AOK while apt hands hundreds of packages to dpkg. Patch the installed
# provision tool to use small, visible batches, disable dpkg's pseudo-terminal,
# and keep each batch under the existing timeout helper.
###############################################################################

script_provision_patch_apt_batches() { # <tool-path>
    local tool="$1" tmp
    [ -f "$tool" ] || return 1

    grep -q 'SYSTUI_APT_BATCHES=1' "$tool" 2>/dev/null && return 0

    tmp="${SYSTUI_TMP:-/tmp}/provision-apt-batches.$$"
    awk '
        /^install_one\(\)[[:space:]]*\{/ && !helper_done {
            print "# SYSTUI_APT_BATCHES=1"
            print "_systui_apt_install_cmd() {"
            print "    _secs=$1; shift"
            print "    _rto \"$_secs\" apt-get \\\"
            print "        -o Dpkg::Use-Pty=0 \\\"
            print "        -o Dpkg::Options::=--force-confold \\\"
            print "        -o APT::Color=0 \\\"
            print "        install -y --no-install-recommends \"$@\""
            print "}"
            print ""
            print "_systui_apt_install_batches() {"
            print "    _all=$1"
            print "    _batch=\"\""
            print "    _n=0"
            print "    _batch_no=1"
            print "    _total=$(printf \047%s\\n\047 \"$_all\" | wc -w | tr -d \047 \047)"
            print "    for _pkg in $_all; do"
            print "        _batch=\"$_batch $_pkg\""
            print "        _n=$((_n + 1))"
            print "        if [ \"$_n\" -ge 15 ]; then"
            print "            note \"APT batch $_batch_no: installing $_n packages ($_total requested total)\""
            print "            # shellcheck disable=SC2086"
            print "            _systui_apt_install_cmd 600 $_batch || return 1"
            print "            _batch=\"\"; _n=0; _batch_no=$((_batch_no + 1))"
            print "        fi"
            print "    done"
            print "    if [ \"$_n\" -gt 0 ]; then"
            print "        note \"APT batch $_batch_no: installing final $_n packages ($_total requested total)\""
            print "        # shellcheck disable=SC2086"
            print "        _systui_apt_install_cmd 600 $_batch || return 1"
            print "    fi"
            print "    return 0"
            print "}"
            print ""
            helper_done=1
        }

        /^[[:space:]]*apt\)[[:space:]]+_rto 300 apt-get -o Dpkg::Options::=/ {
            print "        apt)    _systui_apt_install_cmd 300 \"$1\" ;;"
            next
        }

        /^[[:space:]]*apt\)[[:space:]]+_rto 1800 apt-get -o Dpkg::Options::=/ {
            print "    apt)    _systui_apt_install_batches \"$PKGS\" && _bulk_ok=1 ;;"
            next
        }

        { print }
    ' "$tool" > "$tmp" || { rm -f "$tmp"; return 1; }

    grep -q 'SYSTUI_APT_BATCHES=1' "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    grep -q '_systui_apt_install_batches "\$PKGS"' "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }

    cat "$tmp" > "$tool" || { rm -f "$tmp"; return 1; }
    chmod 0755 "$tool" 2>/dev/null || true
    rm -f "$tmp"
    log "provision: patched bounded APT package batches in $tool"
}

if declare -F script_provision_install_tool >/dev/null 2>&1 && \
   ! declare -F _systui_base_script_provision_install_tool_aptbatch >/dev/null 2>&1; then
    eval "$(declare -f script_provision_install_tool | sed '1s/^script_provision_install_tool[[:space:]]*()/_systui_base_script_provision_install_tool_aptbatch ()/')"
fi
script_provision_install_tool() {
    _systui_base_script_provision_install_tool_aptbatch "$@" || return $?
    script_provision_patch_apt_batches "$(script_provision_tool_path)" || {
        warn "Could not apply Ultimate Provision APT batching patch."
        return 1
    }
}

if declare -F script_provision_run >/dev/null 2>&1 && \
   ! declare -F _systui_base_script_provision_run_aptbatch >/dev/null 2>&1; then
    eval "$(declare -f script_provision_run | sed '1s/^script_provision_run[[:space:]]*()/_systui_base_script_provision_run_aptbatch ()/')"
fi
script_provision_run() {
    local tool
    tool=$(script_provision_tool_path)
    if [ -f "$tool" ]; then
        script_provision_patch_apt_batches "$tool" || {
            tui_msg "Ultimate Provision" \
                "Could not apply the bounded APT install patch to:\n$tool\n\nProvisioning was not started. Reinstall/update Ultimate Provision and retry."
            return 0
        }
    fi
    _systui_base_script_provision_run_aptbatch "$@"
}

export -f script_provision_patch_apt_batches script_provision_install_tool script_provision_run
