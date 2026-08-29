# shellcheck shell=bash
###############################################################################
# ULTIMATE PROVISION — non-blocking Debian/Ubuntu package installation
#
# Debian's /etc/apt/apt.conf.d/70debconf registers dpkg-preconfigure as an APT
# Pre-Install-Pkgs hook.  On iSH-AOK that helper can block indefinitely at
# "Preconfiguring packages ..." even with DEBIAN_FRONTEND=noninteractive.
# Patch the installed provision tool so that hook is disabled only while the
# provision script runs.  Also prevent package maintainer scripts from trying
# to start daemons in the chroot/userspace during the install pass.
###############################################################################

script_provision_patch_apt_nonblocking() { # <tool-path>
    local tool="$1" tmp
    [ -f "$tool" ] || return 1

    grep -q 'SYSTUI_APT_NONBLOCKING=1' "$tool" 2>/dev/null && return 0

    tmp="${SYSTUI_TMP:-/tmp}/provision-apt-nonblocking.$$"
    awk '
        { print }
        /^export DEBIAN_FRONTEND=noninteractive[[:space:]]*$/ && !done {
            print ""
            print "# SYSTUI_APT_NONBLOCKING=1"
            print "# Keep Debian/Ubuntu package installation fully noninteractive on iSH-AOK."
            print "export DEBCONF_NONINTERACTIVE_SEEN=true"
            print "export APT_LISTCHANGES_FRONTEND=none"
            print "export NEEDRESTART_MODE=a"
            print "export UCF_FORCE_CONFFOLD=1"
            print ""
            print "_systui_debconf_cfg=/etc/apt/apt.conf.d/70debconf"
            print "_systui_debconf_saved="
            print "_systui_policy_created=0"
            print "_systui_apt_nonblocking_prepare() {"
            print "    [ \"${PACKAGE_MANAGER:-unknown}\" = apt ] || return 0"
            print "    if [ -f \"$_systui_debconf_cfg\" ]; then"
            print "        _systui_debconf_saved=\"${_systui_debconf_cfg}.systui-disabled.$$\""
            print "        mv -f -- \"$_systui_debconf_cfg\" \"$_systui_debconf_saved\" 2>/dev/null || _systui_debconf_saved="
            print "    fi"
            print "    if [ ! -e /usr/sbin/policy-rc.d ]; then"
            print "        mkdir -p /usr/sbin"
            print "        printf \047#!/bin/sh\\nexit 101\\n\047 > /usr/sbin/policy-rc.d"
            print "        chmod 0755 /usr/sbin/policy-rc.d"
            print "        _systui_policy_created=1"
            print "    fi"
            print "}"
            print "_systui_apt_nonblocking_cleanup() {"
            print "    if [ -n \"$_systui_debconf_saved\" ] && [ -f \"$_systui_debconf_saved\" ]; then"
            print "        mv -f -- \"$_systui_debconf_saved\" \"$_systui_debconf_cfg\" 2>/dev/null || true"
            print "    fi"
            print "    if [ \"$_systui_policy_created\" = 1 ]; then rm -f -- /usr/sbin/policy-rc.d 2>/dev/null || true; fi"
            print "}"
            print "trap \047_systui_apt_nonblocking_cleanup\047 EXIT"
            print "trap \047_systui_apt_nonblocking_cleanup; exit 130\047 INT"
            print "trap \047_systui_apt_nonblocking_cleanup; exit 143\047 TERM HUP"
            done=1
        }
        /^detect_distro$/ && !prepared {
            print "# Package-manager-specific preparation happens after detection below."
            prepared=1
        }
        /^detect_package_manager$/ && !called {
            print "_systui_apt_nonblocking_prepare"
            called=1
        }
    ' "$tool" > "$tmp" || { rm -f "$tmp"; return 1; }

    grep -q 'SYSTUI_APT_NONBLOCKING=1' "$tmp" 2>/dev/null || {
        rm -f "$tmp"
        return 1
    }
    grep -q '^_systui_apt_nonblocking_prepare$' "$tmp" 2>/dev/null || {
        rm -f "$tmp"
        return 1
    }

    cat "$tmp" > "$tool" || { rm -f "$tmp"; return 1; }
    chmod 0755 "$tool" 2>/dev/null || true
    rm -f "$tmp"
    log "provision: patched non-blocking APT/debconf package setup in $tool"
}

if declare -F script_provision_install_tool >/dev/null 2>&1 && \
   ! declare -F _systui_base_script_provision_install_tool_aptfix >/dev/null 2>&1; then
    eval "$(declare -f script_provision_install_tool | sed '1s/^script_provision_install_tool[[:space:]]*()/_systui_base_script_provision_install_tool_aptfix ()/')"
fi
script_provision_install_tool() {
    _systui_base_script_provision_install_tool_aptfix "$@" || return $?
    script_provision_patch_apt_nonblocking "$(script_provision_tool_path)" || {
        warn "Could not apply Ultimate Provision non-blocking APT patch."
        return 1
    }
}

if declare -F script_provision_run >/dev/null 2>&1 && \
   ! declare -F _systui_base_script_provision_run_aptfix >/dev/null 2>&1; then
    eval "$(declare -f script_provision_run | sed '1s/^script_provision_run[[:space:]]*()/_systui_base_script_provision_run_aptfix ()/')"
fi
script_provision_run() {
    local tool
    tool=$(script_provision_tool_path)
    if [ -f "$tool" ]; then
        script_provision_patch_apt_nonblocking "$tool" || {
            tui_msg "Ultimate Provision" \
                "Could not patch the blocking APT preconfiguration hook in:\n$tool\n\nProvisioning was not started. Reinstall/update Ultimate Provision and retry."
            return 0
        }
    fi
    _systui_base_script_provision_run_aptfix "$@"
}

export -f script_provision_patch_apt_nonblocking script_provision_install_tool script_provision_run
