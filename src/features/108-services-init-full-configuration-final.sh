# shellcheck shell=bash
###############################################################################
# PHASE 108 — full Services + Init Systems configuration tool
#
# Final authoritative front-end for service lifecycle, provider management,
# init installation/switching, service-file creation, boot configuration,
# logging, diagnostics and provider-native configuration.
###############################################################################

systui_init_name() {
    case "${1:-}" in
        systemd) printf 'systemd\n' ;;
        openrc) printf 'OpenRC\n' ;;
        runit) printf 'runit\n' ;;
        sysvinit) printf 'SysVinit\n' ;;
        busybox) printf 'BusyBox init\n' ;;
        *) printf '%s\n' "${1:-unknown}" ;;
    esac
}

systui_init_refresh() {
    if declare -F sysconfig_refresh_init_state >/dev/null 2>&1; then
        sysconfig_refresh_init_state >/dev/null 2>&1 || true
    elif declare -F systui_detect_init >/dev/null 2>&1; then
        systui_detect_init >/dev/null 2>&1 || true
    elif declare -F detect_init >/dev/null 2>&1; then
        detect_init >/dev/null 2>&1 || true
    fi
}

systui_init_current() {
    systui_init_refresh
    printf '%s\n' "${SYSTUI_INIT_PROVIDER:-${INIT:-unknown}}"
}

systui_init_installed() {
    if declare -F sysconfig_init_provider_available >/dev/null 2>&1; then
        sysconfig_init_provider_available "$1"
        return $?
    fi
    case "$1" in
        systemd) command -v systemctl >/dev/null 2>&1 ;;
        openrc) command -v rc-service >/dev/null 2>&1 ;;
        runit) command -v sv >/dev/null 2>&1 ;;
        sysvinit) command -v service >/dev/null 2>&1 ;;
        busybox) command -v busybox >/dev/null 2>&1 && [ -e /etc/inittab ] ;;
        *) return 1 ;;
    esac
}

systui_init_provider_status_line() {
    local p="$1" current="$2" state
    if [ "$p" = "$current" ]; then state=active
    elif systui_init_installed "$p"; then state=installed
    else state='not installed'; fi
    printf '%s [%s]\n' "$(systui_init_name "$p")" "$state"
}

systui_service_name_prompt() {
    local provider="$1" s
    s=$(tui_input "$(systui_init_name "$provider") service" "Service/unit name:" "") || return 1
    [ -n "$s" ] || return 1
    if declare -F sysconfig_valid_token >/dev/null 2>&1; then
        sysconfig_valid_token "$s" || { tui_msg "Invalid service" "Service names cannot contain slashes or whitespace."; return 1; }
    fi
    printf '%s\n' "$s"
}

systui_service_do() { # <provider> <action> <service>
    local provider="$1" action="$2" service="$3"
    if declare -F sysconfig_service_action_for >/dev/null 2>&1; then
        run_cmd "$(systui_init_name "$provider") $action $service" sysconfig_service_action_for "$provider" "$action" "$service"
        return $?
    fi
    return 1
}

systui_service_list() { # <provider>
    local provider="$1" out="$SYSTUI_TMP/services-$provider"
    if declare -F sysconfig_service_list_for >/dev/null 2>&1; then
        sysconfig_service_list_for "$provider" "$out" || true
    else
        : > "$out"
    fi
    tui_text "$(systui_init_name "$provider") services" "$out"
}

systui_service_logs() { # <provider> <service>
    local provider="$1" service="$2" bare="${2%.service}" out="$SYSTUI_TMP/service-logs"
    : > "$out"
    case "$provider" in
        systemd)
            if command -v journalctl >/dev/null 2>&1; then
                journalctl -u "$service" -n 200 --no-pager > "$out" 2>&1 || true
            else printf 'journalctl is unavailable.\n' > "$out"; fi
            ;;
        openrc)
            {
                command -v rc-service >/dev/null 2>&1 && rc-service "$bare" status 2>&1 || true
                echo
                for f in "/var/log/$bare.log" "/var/log/$bare/current" "/var/log/$bare/error.log"; do
                    [ -r "$f" ] && { echo "== $f =="; tail -n 200 "$f"; echo; }
                done
            } > "$out"
            ;;
        runit)
            {
                command -v sv >/dev/null 2>&1 && sv status "$bare" 2>&1 || true
                echo
                for f in "/var/log/$bare/current" "/etc/sv/$bare/log/main/current" "/etc/runit/sv/$bare/log/main/current"; do
                    [ -r "$f" ] && { echo "== $f =="; tail -n 200 "$f"; echo; }
                done
            } > "$out"
            ;;
        sysvinit|busybox)
            {
                [ -x "/etc/init.d/$bare" ] && "/etc/init.d/$bare" status 2>&1 || true
                echo
                for f in /var/log/syslog /var/log/messages; do
                    [ -r "$f" ] && { echo "== $f (filtered) =="; grep -i -- "$bare" "$f" | tail -n 200; echo; }
                done
            } > "$out"
            ;;
    esac
    tui_text "Logs — $service" "$out"
}

systui_service_config_file() { # <provider> <service>
    local provider="$1" service="$2"
    if declare -F sysconfig_service_config_path_for >/dev/null 2>&1; then
        sysconfig_service_config_path_for "$provider" "$service"
        return
    fi
    case "$provider" in
        systemd) printf '/etc/systemd/system/%s.service.d/override.conf\n' "${service%.service}" ;;
        openrc) printf '/etc/conf.d/%s\n' "${service%.service}" ;;
        runit) printf '/etc/sv/%s/run\n' "${service%.service}" ;;
        sysvinit) printf '/etc/init.d/%s\n' "${service%.service}" ;;
        busybox) printf '/etc/inittab\n' ;;
    esac
}

systui_service_config_menu() { # <provider> <service>
    local provider="$1" service="$2" c file
    file=$(systui_service_config_file "$provider" "$service")
    while true; do
        c=$(tui_menu_no_tags "Service configuration — $service" "Provider: $(systui_init_name "$provider")\nNative path: $file" \
            view "View configuration" \
            edit "Edit configuration" \
            reload "Reload provider configuration" \
            back "Back") || return 0
        case "$c" in
            view)
                if [ -r "$file" ]; then cp "$file" "$SYSTUI_TMP/service-config-view"; else printf '(not present)\n%s\n' "$file" > "$SYSTUI_TMP/service-config-view"; fi
                tui_text "Service configuration — $service" "$SYSTUI_TMP/service-config-view"
                ;;
            edit)
                mkdir -p "${file%/*}" || continue
                [ -e "$file" ] || : > "$file"
                if declare -F safe_edit >/dev/null 2>&1; then safe_edit "$file"; else ${EDITOR:-vi} "$file"; fi
                ;;
            reload)
                case "$provider" in
                    systemd) command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null || tui_msg "systemd" "Configuration saved for the next systemd runtime." ;;
                    openrc) tui_msg "OpenRC" "OpenRC reads /etc/conf.d when services start or restart." ;;
                    runit) tui_msg "runit" "runit reads service scripts when the service is started/restarted." ;;
                    sysvinit|busybox) tui_msg "Service configuration" "Restart the service or init runtime to apply changes." ;;
                esac
                ;;
            back|'') return 0 ;;
        esac
    done
}

systui_service_manage_menu() { # <provider>
    local provider="$1" c service action
    while true; do
        c=$(tui_menu_no_tags "$(systui_init_name "$provider") — service manager" \
            "Lifecycle, boot state, logs and service configuration:" \
            list "List services" \
            start "Start service" stop "Stop service" restart "Restart service" status "Status" \
            enable "Enable at boot" disable "Disable at boot" \
            logs "View service logs" config "Edit service configuration" \
            mask "Mask/unmask unit (systemd)" \
            create "Create a new service definition" \
            back "Back") || return 0
        case "$c" in
            list) systui_service_list "$provider" ;;
            start|stop|restart|status|enable|disable)
                service=$(systui_service_name_prompt "$provider") || continue
                systui_service_do "$provider" "$c" "$service" || true
                ;;
            logs)
                service=$(systui_service_name_prompt "$provider") || continue
                systui_service_logs "$provider" "$service"
                ;;
            config)
                service=$(systui_service_name_prompt "$provider") || continue
                systui_service_config_menu "$provider" "$service"
                ;;
            mask)
                [ "$provider" = systemd ] || { tui_msg "Mask" "Mask/unmask is a systemd operation."; continue; }
                action=$(tui_radio "systemd unit mask" "Action:" mask Mask on unmask Unmask off) || continue
                service=$(systui_service_name_prompt "$provider") || continue
                if declare -F sysconfig_systemd_mask_service >/dev/null 2>&1; then sysconfig_systemd_mask_service "$action" "$service" || true
                else systui_service_do systemd "$action" "$service" || true; fi
                ;;
            create) systui_service_create_menu "$provider" ;;
            back|'') return 0 ;;
        esac
    done
}

systui_service_create_menu() { # <provider>
    local provider="$1" name desc command user path runlevel
    name=$(tui_input "Create service" "Service name:" "") || return 0
    [ -n "$name" ] || return 0
    if declare -F sysconfig_valid_token >/dev/null 2>&1; then sysconfig_valid_token "$name" || { tui_msg "Invalid name" "Unsafe service name."; return 1; }; fi
    desc=$(tui_input "Create service" "Description:" "$name service") || return 0
    command=$(tui_input "Create service" "Command to run:" "/usr/bin/$name") || return 0
    [ -n "$command" ] || return 0
    case "$provider" in
        systemd)
            user=$(tui_input "Create systemd service" "User (blank = root):" "") || true
            path="/etc/systemd/system/$name.service"
            cat > "$path" <<EOF
[Unit]
Description=$desc
After=network.target

[Service]
Type=simple
${user:+User=$user}
ExecStart=$command
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
            command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null || true
            ;;
        openrc)
            path="/etc/init.d/$name"
            cat > "$path" <<EOF
#!/sbin/openrc-run
description="$desc"
command="${command%% *}"
command_args="${command#${command%% *}}"
command_background="yes"
pidfile="/run/$name.pid"
depend() { need net; }
EOF
            chmod 0755 "$path"
            ;;
        runit)
            path="/etc/sv/$name/run"; mkdir -p "${path%/*}"
            cat > "$path" <<EOF
#!/bin/sh
exec 2>&1
exec $command
EOF
            chmod 0755 "$path"
            ;;
        sysvinit)
            path="/etc/init.d/$name"
            cat > "$path" <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          $name
# Required-Start:    \$remote_fs \$network
# Required-Stop:     \$remote_fs \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: $desc
### END INIT INFO
case "\$1" in
  start) $command & ;;
  stop) pkill -f -- '$command' 2>/dev/null || true ;;
  restart) \$0 stop; sleep 1; \$0 start ;;
  status) pgrep -af -- '$command' ;;
  *) echo "Usage: \$0 {start|stop|restart|status}"; exit 2 ;;
esac
EOF
            chmod 0755 "$path"
            ;;
        busybox)
            path="/etc/inittab"
            mkdir -p /etc
            touch "$path"
            printf '::respawn:%s\n' "$command" >> "$path"
            ;;
    esac
    tui_msg "Service created" "Created $(systui_init_name "$provider") service definition:\n$path"
}

systui_init_provider_config_menu() { # <provider>
    local provider="$1" c f
    while true; do
        case "$provider" in
            systemd)
                c=$(tui_menu_no_tags "systemd configuration" "Manager, logging, login and boot defaults:" \
                    manager "Edit /etc/systemd/system.conf" journald "Edit /etc/systemd/journald.conf" logind "Edit /etc/systemd/logind.conf" target "Default boot target" reload "daemon-reload" back "Back") || return 0
                case "$c" in
                    manager) f=/etc/systemd/system.conf ;;
                    journald) f=/etc/systemd/journald.conf ;;
                    logind) f=/etc/systemd/logind.conf ;;
                    target) systui_systemd_target_menu; continue ;;
                    reload) command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true; continue ;;
                    back|'') return 0 ;;
                esac
                ;;
            openrc)
                c=$(tui_menu_no_tags "OpenRC configuration" "OpenRC runtime and service defaults:" rcconf "Edit /etc/rc.conf" confd "Browse /etc/conf.d" runlevels "Runlevel configuration" back "Back") || return 0
                case "$c" in rcconf) f=/etc/rc.conf ;; confd) f=/etc/conf.d ;; runlevels) systui_openrc_runlevel_menu; continue ;; back|'') return 0 ;; esac
                ;;
            runit)
                c=$(tui_menu_no_tags "runit configuration" "runit service directories and boot scripts:" stage1 "Edit /etc/runit/1" stage2 "Edit /etc/runit/2" stage3 "Edit /etc/runit/3" services "Browse service directory" back "Back") || return 0
                case "$c" in stage1) f=/etc/runit/1 ;; stage2) f=/etc/runit/2 ;; stage3) f=/etc/runit/3 ;; services) f=/etc/sv ;; back|'') return 0 ;; esac
                ;;
            sysvinit)
                c=$(tui_menu_no_tags "SysVinit configuration" "Runlevels and system defaults:" inittab "Edit /etc/inittab" defaults "Browse /etc/default" runlevel "Set default runlevel" back "Back") || return 0
                case "$c" in inittab) f=/etc/inittab ;; defaults) f=/etc/default ;; runlevel) systui_sysv_runlevel_menu; continue ;; back|'') return 0 ;; esac
                ;;
            busybox)
                c=$(tui_menu_no_tags "BusyBox init configuration" "BusyBox init uses /etc/inittab:" inittab "Edit /etc/inittab" view "View /etc/inittab" back "Back") || return 0
                case "$c" in inittab) f=/etc/inittab ;; view) [ -r /etc/inittab ] && cp /etc/inittab "$SYSTUI_TMP/inittab" || : > "$SYSTUI_TMP/inittab"; tui_text "BusyBox /etc/inittab" "$SYSTUI_TMP/inittab"; continue ;; back|'') return 0 ;; esac
                ;;
        esac
        if [ -d "$f" ]; then
            find "$f" -maxdepth 2 -mindepth 1 -printf '%p\n' 2>/dev/null | sort > "$SYSTUI_TMP/init-config-list"
            tui_text "$(systui_init_name "$provider") configuration" "$SYSTUI_TMP/init-config-list"
        else
            mkdir -p "${f%/*}"; [ -e "$f" ] || : > "$f"
            if declare -F safe_edit >/dev/null 2>&1; then safe_edit "$f"; else ${EDITOR:-vi} "$f"; fi
        fi
    done
}

systui_systemd_target_menu() {
    local c target
    c=$(tui_menu_no_tags "systemd default target" "Choose default boot target:" multi-user.target "multi-user.target" graphical.target "graphical.target" rescue.target "rescue.target" emergency.target "emergency.target" custom "Custom target" back "Back") || return 0
    [ "$c" = back ] && return 0
    if [ "$c" = custom ]; then target=$(tui_input "Default target" "Target name:" "") || return 0; else target="$c"; fi
    [ -n "$target" ] || return 0
    if command -v systemctl >/dev/null 2>&1; then systemctl set-default "$target" 2>/dev/null || ln -sfn "/usr/lib/systemd/system/$target" /etc/systemd/system/default.target
    else ln -sfn "/usr/lib/systemd/system/$target" /etc/systemd/system/default.target; fi
}

systui_openrc_runlevel_menu() {
    local c svc level
    c=$(tui_radio "OpenRC runlevel" "Action:" add Add on del Remove off) || return 0
    svc=$(tui_input "OpenRC service" "Service name:" "") || return 0
    level=$(tui_input "OpenRC runlevel" "Runlevel:" "default") || return 0
    [ -n "$svc" ] && [ -n "$level" ] || return 0
    command -v rc-update >/dev/null 2>&1 && rc-update "$c" "$svc" "$level" || true
}

systui_sysv_runlevel_menu() {
    local level f=/etc/inittab tmp
    level=$(tui_input "Default SysV runlevel" "Runlevel (typically 2-5):" "3") || return 0
    case "$level" in 0|1|2|3|4|5|6|S|s) ;; *) tui_msg "Runlevel" "Invalid runlevel."; return 1 ;; esac
    touch "$f"
    tmp="$SYSTUI_TMP/inittab.$$"
    awk -v l="$level" 'BEGIN{done=0} /^id:[0-6Ss]:initdefault:/ {if(!done){print "id:" l ":initdefault:";done=1};next} {print} END{if(!done) print "id:" l ":initdefault:"}' "$f" > "$tmp" && mv -f "$tmp" "$f"
}

systui_init_provider_admin_menu() { # <provider>
    local provider="$1" current state c
    while true; do
        current=$(systui_init_current)
        if [ "$provider" = "$current" ]; then state=active
        elif systui_init_installed "$provider"; then state=installed
        else state='not installed'; fi
        c=$(tui_menu_no_tags "$(systui_init_name "$provider") [$state]" \
            "Provider administration and configuration:" \
            services "Manage services" \
            config "Provider configuration" \
            install "Install / reinstall provider" \
            switch "Switch system to this init provider" \
            remove "Remove provider" \
            files "Show provider files/directories" \
            back "Back") || return 0
        case "$c" in
            services)
                if systui_init_installed "$provider"; then systui_service_manage_menu "$provider"
                else tui_msg "$(systui_init_name "$provider")" "Provider is not installed."; fi
                ;;
            config) systui_init_provider_config_menu "$provider" ;;
            install)
                if declare -F systui_ensure_init_installer_loaded >/dev/null 2>&1; then systui_ensure_init_installer_loaded || continue; fi
                if declare -F sysconfig_install_init_provider >/dev/null 2>&1; then sysconfig_install_init_provider "$provider" || true
                else tui_msg "Init installer" "Init provider installer is unavailable."; fi
                ;;
            switch)
                if ! systui_init_installed "$provider"; then
                    tui_yesno "Install provider" "$(systui_init_name "$provider") is not installed. Install it first?" || continue
                    if declare -F systui_ensure_init_installer_loaded >/dev/null 2>&1; then systui_ensure_init_installer_loaded || continue; fi
                    declare -F sysconfig_install_init_provider >/dev/null 2>&1 && sysconfig_install_init_provider "$provider" || continue
                fi
                if declare -F initswap_current >/dev/null 2>&1; then initswap_current
                elif declare -F menu_init_manager >/dev/null 2>&1; then menu_init_manager
                else tui_msg "Init switch" "Init switching backend is unavailable."; fi
                ;;
            remove)
                [ "$provider" = "$current" ] && { tui_msg "Remove provider" "Refusing to remove the active init provider. Switch providers first."; continue; }
                if declare -F systui_ensure_init_installer_loaded >/dev/null 2>&1; then systui_ensure_init_installer_loaded || continue; fi
                declare -F sysconfig_remove_init_provider >/dev/null 2>&1 && sysconfig_remove_init_provider "$provider" || true
                ;;
            files)
                systui_init_provider_files "$provider"
                ;;
            back|'') return 0 ;;
        esac
    done
}

systui_init_provider_files() {
    local p="$1" out="$SYSTUI_TMP/init-files"
    : > "$out"
    case "$p" in
        systemd) for f in /etc/systemd /run/systemd /usr/lib/systemd /lib/systemd; do [ -e "$f" ] && echo "$f"; done > "$out" ;;
        openrc) for f in /etc/rc.conf /etc/conf.d /etc/init.d /etc/runlevels; do [ -e "$f" ] && echo "$f"; done > "$out" ;;
        runit) for f in /etc/runit /etc/sv /etc/runit/sv /var/service /run/runit/service /service; do [ -e "$f" ] && echo "$f"; done > "$out" ;;
        sysvinit) for f in /etc/inittab /etc/init.d /etc/rc0.d /etc/rc1.d /etc/rc2.d /etc/rc3.d /etc/rc4.d /etc/rc5.d /etc/rc6.d /etc/default; do [ -e "$f" ] && echo "$f"; done > "$out" ;;
        busybox) for f in /etc/inittab /etc/init.d /bin/busybox /usr/bin/busybox; do [ -e "$f" ] && echo "$f"; done > "$out" ;;
    esac
    tui_text "$(systui_init_name "$p") files" "$out"
}

systui_services_diagnostics() {
    local out="$SYSTUI_TMP/init-diagnostics" current pid1 exe p
    current=$(systui_init_current)
    pid1=$(cat /proc/1/comm 2>/dev/null || echo unknown)
    exe=$(readlink -f /proc/1/exe 2>/dev/null || echo unknown)
    {
        printf 'Detected provider: %s\n' "$current"
        printf 'PID 1 command:     %s\n' "$pid1"
        printf 'PID 1 executable:  %s\n' "$exe"
        printf 'Environment:       %s\n' "${SYSTUI_ENVIRONMENT:-unknown}"
        printf 'Service runtime:   %s\n' "${SYSTUI_SERVICE_RUNTIME:-unknown}"
        printf 'Systemd state:     %s\n' "${SYSTUI_SYSTEMD_STATE:-unknown}"
        printf '\nInstalled providers:\n'
        for p in systemd openrc runit sysvinit busybox; do
            if systui_init_installed "$p"; then printf '  %-12s yes\n' "$(systui_init_name "$p")"; else printf '  %-12s no\n' "$(systui_init_name "$p")"; fi
        done
        printf '\nKey commands:\n'
        for p in systemctl journalctl rc-service rc-update sv service update-rc.d busybox; do
            command -v "$p" 2>/dev/null || true
        done
        printf '\nKernel/runtime notes:\n'
        uname -a 2>/dev/null || true
        [ -r /proc/1/status ] && sed -n '1,12p' /proc/1/status
    } > "$out"
    tui_text "Services / init diagnostics" "$out"
}

systui_services_boot_analysis() {
    local out="$SYSTUI_TMP/boot-analysis" current
    current=$(systui_init_current)
    : > "$out"
    case "$current" in
        systemd)
            if command -v systemd-analyze >/dev/null 2>&1 && systemd-analyze time >/dev/null 2>&1; then
                { systemd-analyze time; echo; systemd-analyze blame | head -50; echo; systemd-analyze critical-chain; } > "$out" 2>&1
            else printf 'systemd-analyze requires a running systemd manager.\n' > "$out"; fi
            ;;
        openrc) { command -v rc-status >/dev/null 2>&1 && rc-status -a; echo; [ -r /var/log/rc.log ] && tail -n 200 /var/log/rc.log; } > "$out" 2>&1 ;;
        runit) { echo 'Enabled runit services:'; for p in /var/service/* /run/runit/service/* /service/*; do [ -d "$p" ] && basename "$p"; done; } > "$out" 2>&1 ;;
        sysvinit) { echo 'Current runlevel:'; command -v runlevel >/dev/null 2>&1 && runlevel; echo; echo 'Enabled rc links:'; find /etc/rc?.d -maxdepth 1 -type l 2>/dev/null | sort; } > "$out" ;;
        busybox) { echo '/etc/inittab:'; cat /etc/inittab 2>/dev/null || true; } > "$out" ;;
        *) printf 'No supported active init provider detected.\n' > "$out" ;;
    esac
    tui_text "Boot analysis — $current" "$out"
}

# Compatibility aliases: old entry points now land in the full provider manager.
menu_services_provider() { systui_service_manage_menu "$1"; }
systui_service_provider_menu() { systui_init_provider_admin_menu "$1"; }

menu_init_manager() {
    local c current p label
    local -a opts
    while true; do
        current=$(systui_init_current)
        opts=()
        for p in systemd openrc runit sysvinit busybox; do
            label=$(systui_init_provider_status_line "$p" "$current")
            opts+=("$p" "$label")
        done
        opts+=(runtime "Launch/boot command configuration" diagnostics "Detection and PID 1 diagnostics" back "Back")
        c=$(tui_menu_no_tags "Init systems [active: $current]" "Install, switch and configure init providers:" "${opts[@]}") || return 0
        case "$c" in
            systemd|openrc|runit|sysvinit|busybox) systui_init_provider_admin_menu "$c" ;;
            runtime) if declare -F menu_shell_runtime_commands >/dev/null 2>&1; then menu_shell_runtime_commands; else tui_msg "Runtime" "Runtime command manager is unavailable."; fi ;;
            diagnostics) systui_services_diagnostics ;;
            back|'') return 0 ;;
        esac
    done
}

menu_services() {
    local c current p label
    local -a opts
    while true; do
        current=$(systui_init_current)
        opts=()
        opts+=(active "Manage active provider — $(systui_init_name "$current")")
        for p in systemd openrc runit sysvinit busybox; do
            label=$(systui_init_provider_status_line "$p" "$current")
            opts+=("$p" "$label")
        done
        opts+=(initmgr "Init systems — install, switch and provider configuration" \
              boot "Boot/runlevel/target analysis" \
              diagnostics "Diagnostics and provider detection" \
              advanced "Legacy advanced service settings" \
              back "Back")
        c=$(tui_menu_no_tags "Services & Init Systems [active: $current]" \
            "Full service lifecycle, init-provider installation/switching, boot configuration, logs and service definitions:" \
            "${opts[@]}") || return 0
        case "$c" in
            active)
                case "$current" in systemd|openrc|runit|sysvinit|busybox) systui_service_manage_menu "$current" ;; *) tui_msg "Services" "No supported active provider detected." ;; esac
                ;;
            systemd|openrc|runit|sysvinit|busybox) systui_init_provider_admin_menu "$c" ;;
            initmgr) menu_init_manager ;;
            boot) systui_services_boot_analysis ;;
            diagnostics) systui_services_diagnostics ;;
            advanced) if declare -F menu_svc_advanced >/dev/null 2>&1; then menu_svc_advanced; else tui_msg "Advanced services" "Legacy advanced service settings are unavailable."; fi ;;
            back|'') return 0 ;;
        esac
    done
}

export -f menu_services menu_init_manager menu_services_provider 2>/dev/null || true
return 0 2>/dev/null || true
