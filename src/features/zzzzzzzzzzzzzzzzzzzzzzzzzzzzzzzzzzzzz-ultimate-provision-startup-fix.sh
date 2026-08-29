# shellcheck shell=bash
###############################################################################
# ULTIMATE PROVISION — non-blocking init detection
#
# The bundled provision script historically probed SysVinit by executing
# `/sbin/init --version`.  On iSH-AOK a Systui systemd compatibility launcher
# lives at /sbin/init; invoking it is a real PID1 action, not a harmless version
# query, so Ultimate Provision could appear to freeze before its first status
# line.  Patch installed copies to identify init systems without executing PID1.
###############################################################################

script_provision_patch_init_detection() { # <tool-path>
    local tool="$1" tmp
    [ -f "$tool" ] || return 1

    # Already patched.
    grep -q 'SYSTUI_NONBLOCKING_INIT_DETECT=1' "$tool" 2>/dev/null && return 0

    tmp="${SYSTUI_TMP:-/tmp}/provision-init-detect.$$"
    awk '
        BEGIN { replacing=0 }
        /^detect_init_system\(\)[[:space:]]*\{/ {
            print "detect_init_system() {"
            print "    SYSTUI_NONBLOCKING_INIT_DETECT=1"
            print "    # Never execute /sbin/init for detection: on iSH-AOK it may be a PID1 supervisor."
            print "    if [ -r /etc/systui/ish-systemd-compat.conf ] || \\"
            print "       grep -qs \047^REAL_SYSTEMD=\047 /sbin/init 2>/dev/null || \\"
            print "       [ -x /lib/systemd/systemd ] || [ -x /usr/lib/systemd/systemd ]; then"
            print "        INIT_SYSTEM=\"systemd\""
            print "    elif { [ -L /sbin/init ] && readlink /sbin/init 2>/dev/null | grep -qi runit; } || \\"
            print "         [ -x /usr/sbin/runit ] || command -v runit >/dev/null 2>&1 || command -v sv >/dev/null 2>&1; then"
            print "        INIT_SYSTEM=\"runit\""
            print "    elif { [ -L /sbin/init ] && readlink /sbin/init 2>/dev/null | grep -qi openrc; } || \\"
            print "         [ -x /sbin/openrc-init ] || [ -x /bin/openrc-init ] || command -v rc-service >/dev/null 2>&1; then"
            print "        INIT_SYSTEM=\"openrc\""
            print "    elif { [ -L /sbin/init ] && readlink /sbin/init 2>/dev/null | grep -qi sysvinit; } || \\"
            print "         [ -x /lib/sysvinit/init ] || [ -x /usr/lib/sysvinit/init ] || \\"
            print "         grep -qs \047^Package: sysvinit-core$\047 /var/lib/dpkg/status 2>/dev/null; then"
            print "        INIT_SYSTEM=\"sysvinit\""
            print "    elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then"
            print "        INIT_SYSTEM=\"systemd\""
            print "    else"
            print "        INIT_SYSTEM=\"unknown\""
            print "    fi"
            print "}"
            replacing=1
            next
        }
        replacing && /^detect_package_manager\(\)[[:space:]]*\{/ {
            replacing=0
            print
            next
        }
        !replacing { print }
    ' "$tool" > "$tmp" || { rm -f "$tmp"; return 1; }

    # Refuse to replace the tool if the expected function was not found.
    grep -q 'SYSTUI_NONBLOCKING_INIT_DETECT=1' "$tmp" 2>/dev/null || {
        rm -f "$tmp"
        return 1
    }

    cat "$tmp" > "$tool" || { rm -f "$tmp"; return 1; }
    chmod 0755 "$tool" 2>/dev/null || true
    rm -f "$tmp"
    log "provision: patched non-blocking init detection in $tool"
}

if declare -F script_provision_install_tool >/dev/null 2>&1 && \
   ! declare -F _systui_base_script_provision_install_tool_startfix >/dev/null 2>&1; then
    eval "$(declare -f script_provision_install_tool | sed '1s/^script_provision_install_tool[[:space:]]*()/_systui_base_script_provision_install_tool_startfix ()/')"
fi
script_provision_install_tool() {
    _systui_base_script_provision_install_tool_startfix "$@" || return $?
    script_provision_patch_init_detection "$(script_provision_tool_path)" || {
        warn "Could not apply Ultimate Provision non-blocking init detection patch."
        return 1
    }
}

if declare -F script_provision_run >/dev/null 2>&1 && \
   ! declare -F _systui_base_script_provision_run_startfix >/dev/null 2>&1; then
    eval "$(declare -f script_provision_run | sed '1s/^script_provision_run[[:space:]]*()/_systui_base_script_provision_run_startfix ()/')"
fi
script_provision_run() {
    local tool
    tool=$(script_provision_tool_path)
    if [ -f "$tool" ]; then
        script_provision_patch_init_detection "$tool" || {
            tui_msg "Ultimate Provision" \
                "Could not patch unsafe init detection in:\n$tool\n\nProvisioning was not started. Reinstall/update Ultimate Provision and retry."
            return 0
        }
    fi
    _systui_base_script_provision_run_startfix "$@"
}

export -f script_provision_patch_init_detection script_provision_install_tool script_provision_run
