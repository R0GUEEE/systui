# shellcheck shell=bash
# Final System Configuration menu definition.
# Advanced performance tuning lives on the top-level systui menu only.

menu_sysconfig() {
    while true; do
        local c
        c=$(tui_menu_no_tags "System Configuration" \
            "Detected: package manager = $PM, init = $INIT" \
            common       "Common tasks — packages, hostname, timezone, users, SSH" \
            packages     "Packages (catalogue, repositories, apt-fast...)" \
            shells       "Shells & plugins (frameworks, starship, history...)" \
            editors      "Editors (install + per-editor configuration)" \
            filemanagers "File managers (Midnight Commander, lf, Yazi, Ranger...)" \
            network      "Network (SSH, fail2ban, DNS, proxy, time...)" \
            services     "Services ($INIT, logs, unit creator, init swap)" \
            users        "Users (passwords, sudoers, aging, SSH keys...)" \
            storage      "Storage (mounts, labels, format, SMART...)" \
            back         "Back to main menu") || return 0
        case "$c" in
            common)       menu_sysconfig_common ;;
            packages)     menu_packages ;;
            shells)       menu_shells ;;
            editors)      menu_editors ;;
            filemanagers) menu_file_managers ;;
            network)      menu_network ;;
            services)     menu_services ;;
            users)        menu_users ;;
            storage)      menu_storage ;;
            back|"")     return 0 ;;
        esac
    done
}

export -f menu_sysconfig
