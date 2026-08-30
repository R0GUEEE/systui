# shellcheck shell=bash
###############################################################################
# SYSTEM CONFIGURATION — shell launch / boot command management
###############################################################################

SYSCONFIG_RUNTIME_DIR=/etc/systui
SYSCONFIG_LAUNCH_CMD_FILE=$SYSCONFIG_RUNTIME_DIR/launch-command
SYSCONFIG_BOOT_CMD_FILE=$SYSCONFIG_RUNTIME_DIR/boot-command
SYSCONFIG_LAUNCH_HELPER=/usr/local/sbin/systui-launch
SYSCONFIG_BOOT_HELPER=/usr/local/sbin/systui-boot

sysconfig_runtime_one_line() {
    [ -n "${1:-}" ] && [ "$1" != *$'\n'* ] && [ "$1" != *$'\r'* ]
}

sysconfig_runtime_first_word() {
    local s="${1:-}"
    s=${s#"${s%%[![:space:]]*}"}
    printf '%s\n' "${s%%[[:space:]]*}"
}

sysconfig_runtime_cmd_valid() {
    local cmd="${1:-}" exe
    sysconfig_runtime_one_line "$cmd" || return 1
    exe=$(sysconfig_runtime_first_word "$cmd")
    case "$exe" in
        /*) [ -x "$exe" ] ;;
        *) command -v "$exe" >/dev/null 2>&1 ;;
    esac
}

sysconfig_runtime_read() { # <file> <default>
    local f="$1" d="$2" v
    if [ -r "$f" ]; then
        IFS= read -r v < "$f" || true
        [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
    fi
    printf '%s\n' "$d"
}

sysconfig_runtime_write() { # <file> <command>
    local f="$1" cmd="$2" tmp
    sysconfig_runtime_one_line "$cmd" || return 1
    mkdir -p "$SYSCONFIG_RUNTIME_DIR" || return 1
    tmp=$(mktemp "$SYSCONFIG_RUNTIME_DIR/.runtime.XXXXXX") || return 1
    printf '%s\n' "$cmd" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$f"
}

sysconfig_runtime_install_helpers() {
    mkdir -p /usr/local/sbin "$SYSCONFIG_RUNTIME_DIR" || return 1

    cat > "$SYSCONFIG_LAUNCH_HELPER" <<'EOF'
#!/bin/sh
cfg=/etc/systui/launch-command
cmd='/bin/bash --login'
[ -r "$cfg" ] && IFS= read -r cmd < "$cfg"
[ -n "$cmd" ] || cmd='/bin/bash --login'
exec /bin/sh -c "exec $cmd"
EOF

    cat > "$SYSCONFIG_BOOT_HELPER" <<'EOF'
#!/bin/sh
cfg=/etc/systui/boot-command
cmd='/sbin/init'
[ -r "$cfg" ] && IFS= read -r cmd < "$cfg"
[ -n "$cmd" ] || cmd='/sbin/init'
if [ "$cmd" = /sbin/init ] && [ -x /sbin/init ]; then
    exec /sbin/init "$@"
fi
exec /bin/sh -c "exec $cmd \"\$@\"" sh "$@"
EOF

    chmod 0755 "$SYSCONFIG_LAUNCH_HELPER" "$SYSCONFIG_BOOT_HELPER"
}

sysconfig_launch_cmd_current() {
    sysconfig_runtime_read "$SYSCONFIG_LAUNCH_CMD_FILE" '/bin/bash --login'
}

sysconfig_boot_cmd_current() {
    sysconfig_runtime_read "$SYSCONFIG_BOOT_CMD_FILE" '/sbin/init'
}

sysconfig_launch_cmd_set() {
    local cur choice custom shell_path
    cur=$(sysconfig_launch_cmd_current)
    shell_path=$(getent passwd "${SUDO_USER:-root}" 2>/dev/null | awk -F: 'NR==1{print $7}')
    [ -x "$shell_path" ] || shell_path=/bin/bash

    choice=$(tui_radio "Launch command" "Current: $cur\n\nCommand executed by /usr/local/sbin/systui-launch:" \
        '/bin/login -f root' "Auto-login root through /bin/login" off \
        '/bin/bash --login' "Bash login shell" off \
        '/bin/bash -l' "Bash login shell (short form)" off \
        '/bin/sh -l' "POSIX sh login shell" off \
        "$shell_path -l" "Current account shell as login shell ($shell_path)" off \
        custom "Custom launch command" off) || return 0

    [ -n "$choice" ] || return 0
    if [ "$choice" = custom ]; then
        custom=$(tui_input "Custom launch command" "One-line command. Example:\n/bin/login -f root\n/bin/bash --login" "$cur") || return 0
        choice="$custom"
    fi
    sysconfig_runtime_cmd_valid "$choice" || {
        tui_msg "Launch command" "The command executable could not be found or the command is malformed:\n\n$choice"
        return 0
    }
    sysconfig_runtime_install_helpers || return 1
    sysconfig_runtime_write "$SYSCONFIG_LAUNCH_CMD_FILE" "$choice" || return 1
    tui_msg "Launch command" "Saved:\n$choice\n\nRun it with:\n$SYSCONFIG_LAUNCH_HELPER"
}

sysconfig_launch_cmd_test() {
    local cmd
    cmd=$(sysconfig_launch_cmd_current)
    sysconfig_runtime_cmd_valid "$cmd" || { tui_msg "Launch command" "Configured command is not currently executable:\n$cmd"; return 0; }
    tui_yesno "Test launch command" "This will replace the current Systui process with:\n\n$cmd\n\nContinue?" || return 0
    exec "$SYSCONFIG_LAUNCH_HELPER"
}

sysconfig_boot_candidates() {
    local p
    printf '%s\n' /sbin/init
    for p in /lib/systemd/systemd /usr/lib/systemd/systemd /sbin/openrc-init /usr/sbin/openrc-init /sbin/runit-init /usr/bin/runit-init /sbin/init.sysvinit /lib/sysvinit/init /usr/lib/sysvinit/init /bin/busybox /usr/bin/busybox; do
        [ -x "$p" ] && printf '%s\n' "$p"
    done | awk 'NF && !seen[$0]++'
}

sysconfig_boot_cmd_set() {
    local cur p state choice custom
    local -a args=()
    cur=$(sysconfig_boot_cmd_current)
    while IFS= read -r p; do
        [ "$p" = "$cur" ] && state=on || state=off
        args+=("$p" "$p" "$state")
    done < <(sysconfig_boot_candidates)
    args+=(custom "Custom boot command" off)

    choice=$(tui_radio "Boot command" "Current: $cur\n\nCommand executed by /usr/local/sbin/systui-boot:" "${args[@]}") || return 0
    [ -n "$choice" ] || return 0
    if [ "$choice" = custom ]; then
        custom=$(tui_input "Custom boot command" "One-line boot/init command:" "$cur") || return 0
        choice="$custom"
    fi
    sysconfig_runtime_cmd_valid "$choice" || {
        tui_msg "Boot command" "The command executable could not be found or the command is malformed:\n\n$choice"
        return 0
    }
    sysconfig_runtime_install_helpers || return 1
    sysconfig_runtime_write "$SYSCONFIG_BOOT_CMD_FILE" "$choice" || return 1
    tui_msg "Boot command" "Saved:\n$choice\n\nRun it with:\n$SYSCONFIG_BOOT_HELPER"
}

sysconfig_boot_apply_init() {
    local cmd exe resolved backup
    cmd=$(sysconfig_boot_cmd_current)
    exe=$(sysconfig_runtime_first_word "$cmd")
    case "$exe" in /*) ;; *) exe=$(command -v "$exe" 2>/dev/null || true);; esac
    [ -x "$exe" ] || { tui_msg "Boot command" "Configured boot executable is unavailable:\n$cmd"; return 0; }

    if [ "$cmd" != "$exe" ]; then
        tui_msg "Boot command" "The configured boot command contains arguments:\n\n$cmd\n\n/sbin/init can only be pointed directly at an executable. The saved command remains available through systui-boot."
        return 0
    fi

    resolved=$(readlink -f /sbin/init 2>/dev/null || true)
    [ "$resolved" = "$(readlink -f "$exe" 2>/dev/null || printf '%s' "$exe")" ] && {
        tui_msg "Boot command" "/sbin/init already resolves to $exe."; return 0;
    }

    if declare -F sysconfig_is_ish >/dev/null 2>&1 && sysconfig_is_ish; then
        tui_yesno "iSH-AOK warning" "Systui currently protects /sbin/init with an iSH compatibility layer on many rootfs installs. Replacing it can disable those compatibility fixes.\n\nPoint /sbin/init directly to $exe anyway?" || return 0
    else
        tui_yesno "Change /sbin/init" "Point /sbin/init to:\n$exe\n\nA timestamped backup will be created first. This affects the next real boot." || return 0
    fi

    backup="/sbin/init.systui-backup.$(date +%Y%m%d-%H%M%S)"
    if [ -e /sbin/init ] || [ -L /sbin/init ]; then
        cp -a /sbin/init "$backup" 2>/dev/null || {
            [ -L /sbin/init ] && cp -P /sbin/init "$backup" 2>/dev/null || true
        }
    fi
    ln -sfn "$exe" /sbin/init || return 1
    tui_msg "Boot command" "/sbin/init now points to $exe.\n\nBackup: $backup"
}

sysconfig_boot_restore_init() {
    local f choice
    local -a args=()
    for f in /sbin/init.systui-backup.*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        args+=("$f" "$(basename "$f")")
    done
    [ "${#args[@]}" -gt 0 ] || { tui_msg "Boot command" "No Systui /sbin/init backups were found."; return 0; }
    choice=$(tui_menu "Restore /sbin/init" "Select a backup:" "${args[@]}" back "Back") || return 0
    [ "$choice" = back ] && return 0
    case "$choice" in /sbin/init.systui-backup.*) ;; *) return 1;; esac
    tui_yesno "Restore /sbin/init" "Restore $choice as /sbin/init?" || return 0
    rm -f /sbin/init
    cp -a "$choice" /sbin/init || return 1
}

sysconfig_runtime_summary() {
    sysconfig_runtime_install_helpers 2>/dev/null || true
    {
        echo "Launch command : $(sysconfig_launch_cmd_current)"
        echo "Launch helper  : $SYSCONFIG_LAUNCH_HELPER"
        echo
        echo "Boot command   : $(sysconfig_boot_cmd_current)"
        echo "Boot helper    : $SYSCONFIG_BOOT_HELPER"
        echo "/sbin/init      : $(readlink -f /sbin/init 2>/dev/null || echo unavailable)"
        echo "PID 1          : $(cat /proc/1/comm 2>/dev/null || echo unknown)"
        echo "Detected init  : ${INIT:-unknown}"
    } > "$SYSTUI_TMP/shell-runtime"
    tui_text "Shell runtime configuration" "$SYSTUI_TMP/shell-runtime"
}

menu_shell_runtime_commands() {
    local c
    while true; do
        detect_init 2>/dev/null || true
        c=$(tui_menu "Shell runtime configuration" "Configure login/launch and boot/init commands:" \
            status "Show current launch and boot commands" \
            launch "Configure launch command" \
            testlaunch "Test configured launch command (replaces current process)" \
            boot "Configure boot command" \
            applyinit "Apply boot executable as /sbin/init" \
            restoreinit "Restore a Systui /sbin/init backup" \
            back "Back") || return 0
        case "$c" in
            status) sysconfig_runtime_summary ;;
            launch) sysconfig_launch_cmd_set ;;
            testlaunch) sysconfig_launch_cmd_test ;;
            boot) sysconfig_boot_cmd_set ;;
            applyinit) sysconfig_boot_apply_init ;;
            restoreinit) sysconfig_boot_restore_init ;;
            back|"") return 0 ;;
        esac
    done
}

# Integrate into the existing Shells > Managers menu created by the previous
# late module, keeping all account/login/init controls in one place.
if declare -F menu_shell_hierarchy >/dev/null 2>&1 && ! declare -F _systui_base_menu_shell_hierarchy_runtime >/dev/null 2>&1; then
    eval "$(declare -f menu_shell_hierarchy | sed '1s/^menu_shell_hierarchy[[:space:]]*()/_systui_base_menu_shell_hierarchy_runtime ()/')"
fi

menu_shell_hierarchy() {
    local c
    while true; do
        detect_init 2>/dev/null || true
        c=$(tui_menu "Shell Managers" "Install/configure shells and manage login/init/runtime defaults. Current init: ${INIT:-unknown}" \
            shells "Install, remove & configure shell managers/frameworks" \
            runtime "Shell runtime configuration (launch cmd / boot cmd)" \
            user "Change a user's default login shell" \
            newuser "Set default login shell for NEW users" \
            accounts "List users and their login shells" \
            shellsfile "Manage /etc/shells" \
            shprovider "Manage system /bin/sh provider" \
            initstatus "Show detected init system / PID 1" \
            initswap "Change init system (systemd/OpenRC/runit/SysVinit)" \
            services "Open service/init manager" \
            back "Back") || return 0
        case "$c" in
            shells)
                if declare -F _systui_base_menu_shell_hierarchy_logininit >/dev/null 2>&1; then
                    _systui_base_menu_shell_hierarchy_logininit
                elif declare -F _systui_base_menu_shell_hierarchy_runtime >/dev/null 2>&1; then
                    _systui_base_menu_shell_hierarchy_runtime
                else
                    tui_msg "Shell Managers" "The original shell manager hierarchy is unavailable."
                fi ;;
            runtime) menu_shell_runtime_commands ;;
            user) sysconfig_shell_set_user ;;
            newuser) sysconfig_shell_set_new_user_default ;;
            accounts) sysconfig_shell_show_accounts ;;
            shellsfile) sysconfig_shells_file_menu ;;
            shprovider) sysconfig_sh_provider ;;
            initstatus) sysconfig_init_summary ;;
            initswap) declare -F initswap_current >/dev/null 2>&1 && initswap_current || tui_msg "Init system" "Init switching is unavailable in this build." ;;
            services) declare -F menu_services >/dev/null 2>&1 && menu_services || tui_msg "Services" "Service management is unavailable in this build." ;;
            back|"") return 0 ;;
        esac
    done
}

# Deliberately do not export these functions. Systui sources all feature files
# into one Bash process, so exporting them only serializes their full bodies
# into the environment of every child command. On systems with a small ARG_MAX
# (notably iSH/chroot-style environments), that can make even /usr/bin/date fail
# with E2BIG / "Argument list too long".
