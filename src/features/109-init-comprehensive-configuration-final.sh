# shellcheck shell=bash
###############################################################################
# PHASE 109 — comprehensive init-system configuration
###############################################################################

systui_init_backup_file() { # <path>
    local f="$1" stamp backup
    [ -e "$f" ] || return 0
    stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || date +%s)
    backup="$f.systui-$stamp.bak"
    cp -a -- "$f" "$backup" || return 1
    printf '%s\n' "$backup"
}

systui_init_edit_file() { # <path>
    local f="$1" backup
    mkdir -p "${f%/*}" || return 1
    [ -e "$f" ] || : > "$f"
    backup=$(systui_init_backup_file "$f" 2>/dev/null || true)
    if declare -F safe_edit >/dev/null 2>&1; then safe_edit "$f"; else ${EDITOR:-vi} "$f"; fi
    [ -n "$backup" ] && printf 'Backup: %s\n' "$backup"
}

systui_init_view_file() { # <title> <path>
    local title="$1" f="$2" out="$SYSTUI_TMP/init-config-view"
    if [ -r "$f" ]; then cp "$f" "$out"; else printf '(not present)\n%s\n' "$f" > "$out"; fi
    tui_text "$title" "$out"
}

systui_systemd_set_conf_value() { # <file> <section> <key> <value>
    local f="$1" section="$2" key="$3" value="$4" tmp
    mkdir -p "${f%/*}"; [ -e "$f" ] || printf '[%s]\n' "$section" > "$f"
    systui_init_backup_file "$f" >/dev/null 2>&1 || true
    tmp="$f.systui.$$"
    awk -v section="$section" -v key="$key" -v value="$value" '
        BEGIN { insec=0; done=0; seen=0 }
        /^\[/ {
            if (insec && !done) { print key "=" value; done=1 }
            insec=($0=="[" section "]")
            if (insec) seen=1
        }
        insec && $0 ~ "^[#;]*[[:space:]]*" key "=" {
            if (!done) { print key "=" value; done=1 }
            next
        }
        { print }
        END {
            if (!seen) { print ""; print "[" section "]" }
            if (!done) print key "=" value
        }
    ' "$f" > "$tmp" && mv -f "$tmp" "$f"
}

systui_systemd_manager_settings() {
    local c v f=/etc/systemd/system.conf
    while true; do
        c=$(tui_menu_no_tags "systemd manager settings" "Configure system.conf [Manager] values:" \
            timeout_start "DefaultTimeoutStartSec" timeout_stop "DefaultTimeoutStopSec" restart "DefaultRestartSec" \
            watchdog "RuntimeWatchdogSec" shutdown_watchdog "RebootWatchdogSec" jobs "DefaultTimeoutAbortSec" \
            show "View system.conf" edit "Edit system.conf" back "Back") || return 0
        case "$c" in
            timeout_start) v=$(tui_input "DefaultTimeoutStartSec" "Example: 90s, 30s, infinity" "90s") || continue; systui_systemd_set_conf_value "$f" Manager DefaultTimeoutStartSec "$v" ;;
            timeout_stop) v=$(tui_input "DefaultTimeoutStopSec" "Example: 90s" "90s") || continue; systui_systemd_set_conf_value "$f" Manager DefaultTimeoutStopSec "$v" ;;
            restart) v=$(tui_input "DefaultRestartSec" "Restart delay for services" "100ms") || continue; systui_systemd_set_conf_value "$f" Manager DefaultRestartSec "$v" ;;
            watchdog) v=$(tui_input "RuntimeWatchdogSec" "0 disables watchdog" "0") || continue; systui_systemd_set_conf_value "$f" Manager RuntimeWatchdogSec "$v" ;;
            shutdown_watchdog) v=$(tui_input "RebootWatchdogSec" "Watchdog during reboot/shutdown" "10min") || continue; systui_systemd_set_conf_value "$f" Manager RebootWatchdogSec "$v" ;;
            jobs) v=$(tui_input "DefaultTimeoutAbortSec" "Abort timeout" "") || continue; systui_systemd_set_conf_value "$f" Manager DefaultTimeoutAbortSec "$v" ;;
            show) systui_init_view_file "systemd system.conf" "$f" ;;
            edit) systui_init_edit_file "$f" ;;
            back|'') return 0 ;;
        esac
    done
}

systui_systemd_journald_settings() {
    local c v f=/etc/systemd/journald.conf
    while true; do
        c=$(tui_menu_no_tags "systemd journal settings" "Configure journald storage and retention:" \
            storage "Storage (auto/persistent/volatile/none)" maxuse "SystemMaxUse" runtimeuse "RuntimeMaxUse" maxfile "SystemMaxFileSize" \
            retention "MaxRetentionSec" rate "RateLimitBurst" forwarding "ForwardToSyslog" compress "Compress" seal "Seal" \
            show "View journald.conf" edit "Edit journald.conf" vacuum "Vacuum journal" back "Back") || return 0
        case "$c" in
            storage) v=$(tui_input "Storage" "auto, persistent, volatile, none" "auto") || continue; systui_systemd_set_conf_value "$f" Journal Storage "$v" ;;
            maxuse) v=$(tui_input "SystemMaxUse" "Example: 500M" "500M") || continue; systui_systemd_set_conf_value "$f" Journal SystemMaxUse "$v" ;;
            runtimeuse) v=$(tui_input "RuntimeMaxUse" "Example: 100M" "100M") || continue; systui_systemd_set_conf_value "$f" Journal RuntimeMaxUse "$v" ;;
            maxfile) v=$(tui_input "SystemMaxFileSize" "Example: 64M" "64M") || continue; systui_systemd_set_conf_value "$f" Journal SystemMaxFileSize "$v" ;;
            retention) v=$(tui_input "MaxRetentionSec" "Example: 2week" "2week") || continue; systui_systemd_set_conf_value "$f" Journal MaxRetentionSec "$v" ;;
            rate) v=$(tui_input "RateLimitBurst" "Messages per interval" "10000") || continue; systui_systemd_set_conf_value "$f" Journal RateLimitBurst "$v" ;;
            forwarding) v=$(tui_radio "ForwardToSyslog" "Forward journal to syslog?" yes yes on no no off) || continue; systui_systemd_set_conf_value "$f" Journal ForwardToSyslog "$v" ;;
            compress) v=$(tui_radio "Compress" "Compress journal files?" yes yes on no no off) || continue; systui_systemd_set_conf_value "$f" Journal Compress "$v" ;;
            seal) v=$(tui_radio "Seal" "Enable forward-secure sealing?" yes yes on no no off) || continue; systui_systemd_set_conf_value "$f" Journal Seal "$v" ;;
            show) systui_init_view_file "journald.conf" "$f" ;;
            edit) systui_init_edit_file "$f" ;;
            vacuum) if command -v journalctl >/dev/null 2>&1; then v=$(tui_input "Vacuum journal" "Keep size, e.g. 250M" "250M") || continue; journalctl --vacuum-size="$v" || true; fi ;;
            back|'') return 0 ;;
        esac
    done
}

systui_systemd_logind_settings() {
    local c v f=/etc/systemd/logind.conf
    while true; do
        c=$(tui_menu_no_tags "systemd logind settings" "Login/session/power behavior:" \
            lid "HandleLidSwitch" power "HandlePowerKey" suspend "HandleSuspendKey" hibernate "HandleHibernateKey" idle "IdleAction" idle_sec "IdleActionSec" \
            killuser "KillUserProcesses" sessions "UserStopDelaySec" show "View logind.conf" edit "Edit logind.conf" back "Back") || return 0
        case "$c" in
            lid) v=$(tui_input "HandleLidSwitch" "ignore, poweroff, reboot, halt, suspend, hibernate, hybrid-sleep, lock" "suspend") || continue; systui_systemd_set_conf_value "$f" Login HandleLidSwitch "$v" ;;
            power) v=$(tui_input "HandlePowerKey" "poweroff, reboot, halt, ignore, lock" "poweroff") || continue; systui_systemd_set_conf_value "$f" Login HandlePowerKey "$v" ;;
            suspend) v=$(tui_input "HandleSuspendKey" "suspend or ignore" "suspend") || continue; systui_systemd_set_conf_value "$f" Login HandleSuspendKey "$v" ;;
            hibernate) v=$(tui_input "HandleHibernateKey" "hibernate or ignore" "hibernate") || continue; systui_systemd_set_conf_value "$f" Login HandleHibernateKey "$v" ;;
            idle) v=$(tui_input "IdleAction" "ignore, poweroff, reboot, suspend, hibernate, lock" "ignore") || continue; systui_systemd_set_conf_value "$f" Login IdleAction "$v" ;;
            idle_sec) v=$(tui_input "IdleActionSec" "Example: 30min" "30min") || continue; systui_systemd_set_conf_value "$f" Login IdleActionSec "$v" ;;
            killuser) v=$(tui_radio "KillUserProcesses" "Kill user processes on logout?" yes yes on no no off) || continue; systui_systemd_set_conf_value "$f" Login KillUserProcesses "$v" ;;
            sessions) v=$(tui_input "UserStopDelaySec" "Example: 10s, infinity" "10s") || continue; systui_systemd_set_conf_value "$f" Login UserStopDelaySec "$v" ;;
            show) systui_init_view_file "logind.conf" "$f" ;;
            edit) systui_init_edit_file "$f" ;;
            back|'') return 0 ;;
        esac
    done
}

systui_systemd_unit_defaults_menu() {
    local c dir=/etc/systemd/system.conf.d f=$dir/99-systui.conf v
    mkdir -p "$dir"
    while true; do
        c=$(tui_menu_no_tags "systemd service defaults" "Global defaults applied by PID 1:" \
            oom "DefaultOOMPolicy" startlimit "DefaultStartLimitBurst" interval "DefaultStartLimitIntervalSec" \
            timer "DefaultTimerAccuracySec" env "DefaultEnvironment" edit "Edit SystUI drop-in" back "Back") || return 0
        case "$c" in
            oom) v=$(tui_input "DefaultOOMPolicy" "stop, continue, kill" "stop") || continue; systui_systemd_set_conf_value "$f" Manager DefaultOOMPolicy "$v" ;;
            startlimit) v=$(tui_input "DefaultStartLimitBurst" "Restart burst count" "5") || continue; systui_systemd_set_conf_value "$f" Manager DefaultStartLimitBurst "$v" ;;
            interval) v=$(tui_input "DefaultStartLimitIntervalSec" "Example: 10s" "10s") || continue; systui_systemd_set_conf_value "$f" Manager DefaultStartLimitIntervalSec "$v" ;;
            timer) v=$(tui_input "DefaultTimerAccuracySec" "Example: 1min" "1min") || continue; systui_systemd_set_conf_value "$f" Manager DefaultTimerAccuracySec "$v" ;;
            env) v=$(tui_input "DefaultEnvironment" "Example: FOO=bar BAR=baz" "") || continue; systui_systemd_set_conf_value "$f" Manager DefaultEnvironment "$v" ;;
            edit) systui_init_edit_file "$f" ;;
            back|'') return 0 ;;
        esac
    done
}

systui_systemd_validate() {
    local out="$SYSTUI_TMP/systemd-verify"
    : > "$out"
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze verify /etc/systemd/system/*.service /etc/systemd/system/*.target > "$out" 2>&1 || true
        [ -s "$out" ] || printf 'systemd-analyze verify reported no errors.\n' > "$out"
    else
        printf 'systemd-analyze is unavailable.\n' > "$out"
    fi
    tui_text "systemd validation" "$out"
}

systui_openrc_comprehensive_config() {
    local c f
    while true; do
        c=$(tui_menu_no_tags "OpenRC comprehensive configuration" "Global runtime, boot, logging and runlevels:" \
            rcconf "Edit /etc/rc.conf" confd "Browse/edit /etc/conf.d" runlevels "Manage runlevels" locald "Edit /etc/local.d scripts" \
            modules "Edit /etc/conf.d/modules" hostname "Edit /etc/conf.d/hostname" keymaps "Edit /etc/conf.d/keymaps" clock "Edit /etc/conf.d/hwclock" \
            logging "Configure rc_logger / rc_log_path" parallel "Configure rc_parallel" interactive "Configure rc_interactive" timeout "Configure rc_timeout_stopsec" \
            validate "Run OpenRC status/config diagnostics" back "Back") || return 0
        case "$c" in
            rcconf) systui_init_edit_file /etc/rc.conf ;;
            confd) f=$(tui_input "OpenRC conf.d" "File name under /etc/conf.d:" "") || continue; [ -n "$f" ] && systui_init_edit_file "/etc/conf.d/$f" ;;
            runlevels) systui_openrc_runlevel_menu ;;
            locald) f=$(tui_input "OpenRC local.d" "Script name (without .start/.stop):" "local") || continue; systui_init_edit_file "/etc/local.d/$f.start"; chmod +x "/etc/local.d/$f.start" 2>/dev/null || true ;;
            modules) systui_init_edit_file /etc/conf.d/modules ;;
            hostname) systui_init_edit_file /etc/conf.d/hostname ;;
            keymaps) systui_init_edit_file /etc/conf.d/keymaps ;;
            clock) systui_init_edit_file /etc/conf.d/hwclock ;;
            logging) printf '\nrc_logger="YES"\nrc_log_path="/var/log/rc.log"\n' >> /etc/rc.conf ;;
            parallel) printf '\nrc_parallel="YES"\n' >> /etc/rc.conf ;;
            interactive) printf '\nrc_interactive="NO"\n' >> /etc/rc.conf ;;
            timeout) printf '\nrc_timeout_stopsec="90"\n' >> /etc/rc.conf ;;
            validate) { command -v rc-status >/dev/null 2>&1 && rc-status -a; echo; command -v rc-update >/dev/null 2>&1 && rc-update show -v; } > "$SYSTUI_TMP/openrc-check" 2>&1; tui_text "OpenRC diagnostics" "$SYSTUI_TMP/openrc-check" ;;
            back|'') return 0 ;;
        esac
    done
}

systui_runit_comprehensive_config() {
    local c f base
    if [ -d /etc/runit ]; then base=/etc/runit; else base=/etc; fi
    while true; do
        c=$(tui_menu_no_tags "runit comprehensive configuration" "Boot stages, Ctrl-Alt-Del, shutdown and supervision:" \
            stage1 "Edit stage 1" stage2 "Edit stage 2" stage3 "Edit stage 3" ctrlaltdel "Edit ctrlaltdel" stopit "Edit stopit" reboot "Edit reboot" \
            services "Edit service run script" finish "Edit service finish script" log "Edit service log/run" env "Edit service env directory" \
            enable "Enable service directory link" disable "Disable service directory link" status "Show supervised services" back "Back") || return 0
        case "$c" in
            stage1) systui_init_edit_file "$base/1" ;; stage2) systui_init_edit_file "$base/2" ;; stage3) systui_init_edit_file "$base/3" ;;
            ctrlaltdel) systui_init_edit_file "$base/ctrlaltdel" ;; stopit) systui_init_edit_file "$base/stopit" ;; reboot) systui_init_edit_file "$base/reboot" ;;
            services|finish|log|env|enable|disable)
                f=$(tui_input "runit service" "Service name:" "") || continue; [ -n "$f" ] || continue
                case "$c" in
                    services) systui_init_edit_file "/etc/sv/$f/run"; chmod +x "/etc/sv/$f/run" 2>/dev/null || true ;;
                    finish) systui_init_edit_file "/etc/sv/$f/finish"; chmod +x "/etc/sv/$f/finish" 2>/dev/null || true ;;
                    log) systui_init_edit_file "/etc/sv/$f/log/run"; chmod +x "/etc/sv/$f/log/run" 2>/dev/null || true ;;
                    env) mkdir -p "/etc/sv/$f/env"; systui_init_edit_file "/etc/sv/$f/env/PATH" ;;
                    enable) mkdir -p /var/service; ln -sfn "/etc/sv/$f" "/var/service/$f" ;;
                    disable) rm -f -- "/var/service/$f" "/service/$f" "/run/runit/service/$f" ;;
                esac ;;
            status) { command -v sv >/dev/null 2>&1 && sv status /var/service/* 2>&1 || true; } > "$SYSTUI_TMP/runit-status"; tui_text "runit status" "$SYSTUI_TMP/runit-status" ;;
            back|'') return 0 ;;
        esac
    done
}

systui_sysv_comprehensive_config() {
    local c svc
    while true; do
        c=$(tui_menu_no_tags "SysVinit comprehensive configuration" "inittab, runlevels, startup/shutdown and service defaults:" \
            inittab "Edit /etc/inittab" runlevel "Set default runlevel" rcS "Edit /etc/default/rcS" tmpfs "Edit /etc/default/tmpfs" halt "Edit /etc/default/halt" \
            service "Edit init script" defaults "Edit service /etc/default file" enable "Enable service in runlevels" disable "Disable service" \
            sequence "Show rc?.d boot ordering" status "Show service status list" back "Back") || return 0
        case "$c" in
            inittab) systui_init_edit_file /etc/inittab ;; runlevel) systui_sysv_runlevel_menu ;; rcS) systui_init_edit_file /etc/default/rcS ;; tmpfs) systui_init_edit_file /etc/default/tmpfs ;; halt) systui_init_edit_file /etc/default/halt ;;
            service|defaults|enable|disable)
                svc=$(tui_input "SysV service" "Service name:" "") || continue; [ -n "$svc" ] || continue
                case "$c" in service) systui_init_edit_file "/etc/init.d/$svc"; chmod +x "/etc/init.d/$svc" 2>/dev/null || true ;; defaults) systui_init_edit_file "/etc/default/$svc" ;; enable) command -v update-rc.d >/dev/null 2>&1 && update-rc.d "$svc" defaults ;; disable) command -v update-rc.d >/dev/null 2>&1 && update-rc.d -f "$svc" remove ;; esac ;;
            sequence) { for d in /etc/rc?.d; do [ -d "$d" ] && { echo "== $d =="; ls -1 "$d"; }; done; } > "$SYSTUI_TMP/sysv-order"; tui_text "SysV boot ordering" "$SYSTUI_TMP/sysv-order" ;;
            status) service --status-all > "$SYSTUI_TMP/sysv-status" 2>&1 || true; tui_text "SysV services" "$SYSTUI_TMP/sysv-status" ;;
            back|'') return 0 ;;
        esac
    done
}

systui_busybox_comprehensive_config() {
    local c action line
    while true; do
        c=$(tui_menu_no_tags "BusyBox init comprehensive configuration" "Manage /etc/inittab actions and boot lifecycle:" \
            edit "Edit /etc/inittab" view "View /etc/inittab" sysinit "Add sysinit entry" respawn "Add respawn service" askfirst "Add askfirst console" wait "Add wait entry" once "Add once entry" \
            ctrlaltdel "Add ctrlaltdel action" shutdown "Add shutdown action" restart "Add restart action" initd "Edit /etc/init.d script" reload "Reload init table" back "Back") || return 0
        case "$c" in
            edit) systui_init_edit_file /etc/inittab ;; view) systui_init_view_file "BusyBox /etc/inittab" /etc/inittab ;;
            sysinit|respawn|askfirst|wait|once|ctrlaltdel|shutdown|restart)
                action="$c"; line=$(tui_input "BusyBox $action" "Command:" "/bin/sh") || continue; mkdir -p /etc; touch /etc/inittab; systui_init_backup_file /etc/inittab >/dev/null 2>&1 || true; printf '::%s:%s\n' "$action" "$line" >> /etc/inittab ;;
            initd) line=$(tui_input "Init script" "Script name under /etc/init.d:" "") || continue; [ -n "$line" ] && systui_init_edit_file "/etc/init.d/$line" && chmod +x "/etc/init.d/$line" 2>/dev/null || true ;;
            reload) kill -HUP 1 2>/dev/null || tui_msg "BusyBox init" "PID 1 did not accept SIGHUP; changes will apply on next init start." ;;
            back|'') return 0 ;;
        esac
    done
}

# Final comprehensive provider configuration router.
systui_init_provider_config_menu() {
    case "$1" in
        systemd)
            local c
            while true; do
                c=$(tui_menu_no_tags "systemd comprehensive configuration" "Manager, journal, login, targets, service defaults and validation:" \
                    manager "PID 1 manager defaults" journal "Journal storage/retention" login "Login/session/power behavior" \
                    defaults "Global service/timer defaults" target "Default boot target" presets "Unit preset policy files" tmpfiles "tmpfiles.d configuration" sysusers "sysusers.d configuration" \
                    generators "Generator/environment directories" validate "Validate units" reload "daemon-reload" back "Back") || return 0
                case "$c" in
                    manager) systui_systemd_manager_settings ;; journal) systui_systemd_journald_settings ;; login) systui_systemd_logind_settings ;; defaults) systui_systemd_unit_defaults_menu ;;
                    target) systui_systemd_target_menu ;; presets) systui_init_edit_file /etc/systemd/system-preset/99-systui.preset ;; tmpfiles) systui_init_edit_file /etc/tmpfiles.d/systui.conf ;; sysusers) systui_init_edit_file /etc/sysusers.d/systui.conf ;;
                    generators) mkdir -p /etc/systemd/system-generators /etc/systemd/user-environment-generators; tui_msg "systemd generators" "System generators: /etc/systemd/system-generators\nUser environment generators: /etc/systemd/user-environment-generators" ;;
                    validate) systui_systemd_validate ;; reload) command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true ;; back|'') return 0 ;;
                esac
            done
            ;;
        openrc) systui_openrc_comprehensive_config ;;
        runit) systui_runit_comprehensive_config ;;
        sysvinit) systui_sysv_comprehensive_config ;;
        busybox) systui_busybox_comprehensive_config ;;
        *) tui_msg "Init configuration" "Unsupported provider: $1" ;;
    esac
}

return 0 2>/dev/null || true
