# shellcheck shell=bash
# PHASE 96 — final menu consolidation.
# Keep capabilities intact while reducing duplicate top-level entry points.

menu_sysconfig_basics() {
    local c host tz
    while true; do
        host="${HOSTNAME:-unknown}"
        [ ! -r /etc/hostname ] || read -r host < /etc/hostname || true
        tz=unknown
        [ ! -r /etc/timezone ] || read -r tz < /etc/timezone || true
        tui_capture_menu c tui_menu_no_tags "System basics" \
            "Core host settings that do not belong to a dedicated section:" \
            hostname "Set hostname ($host)" \
            timezone "Set timezone ($tz)" \
            scan     "Run full system scan" \
            back     "Back" || return $?
        case "$c" in
            hostname) tui_call_menu sysconfig_set_hostname "Hostname" ;;
            timezone) tui_call_menu sysconfig_set_timezone "Timezone" ;;
            scan) tui_call_menu menu_scan_system "System scan" ;;
            back|'') return 0 ;;
        esac
    done
}

# Compatibility name introduced by the earlier menu hardening pass. Keep callers
# and integration tests on one dispatcher while the implementation lives in core.
systui_menu_dispatch() {
    tui_call_menu "$@"
}

# Common Tasks duplicated Packages, Editors, Users, SSH/Network, Services and
# Shells.  Replace it with a small System basics section and leave each feature
# reachable from its single authoritative top-level section.
menu_sysconfig() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "System Configuration" \
            "Detected: package manager = ${PM:-unknown}, init = ${INIT:-unknown}" \
            system       "System basics — hostname, timezone, system scan" \
            packages     "Packages, catalogue, repositories and managers" \
            shells       "Shells, prompts and plugins" \
            editors      "Editors" \
            filemanagers "File managers" \
            network      "Network, SSH, DNS, proxy and time" \
            services     "Services and init systems" \
            users        "Users, sudo, passwords and SSH keys" \
            storage      "Storage, mounts, filesystems and SMART" \
            back         "Back to main menu" || return $?
        case "$c" in
            system)       tui_call_menu menu_sysconfig_basics "System basics" ;;
            packages)     tui_call_menu menu_packages "Packages" ;;
            shells)       tui_call_menu menu_shells "Shells" ;;
            editors)      tui_call_menu menu_editors "Editors" ;;
            filemanagers) tui_call_menu menu_file_managers "File managers" ;;
            network)      tui_call_menu menu_network "Network" ;;
            services)     tui_call_menu menu_services "Services" ;;
            users)        tui_call_menu menu_users "Users" ;;
            storage)      tui_call_menu menu_storage "Storage" ;;
            back|'') return 0 ;;
        esac
    done
}

# Bedrock managers belong under Package Managers, not beside it in Packages.
if declare -F menu_package_managers >/dev/null 2>&1 \
    && ! declare -F _systui_package_managers_before_menu_consolidation >/dev/null 2>&1; then
    _systui_saved_fn=$(declare -f menu_package_managers)
    _systui_saved_fn=${_systui_saved_fn/#menu_package_managers /_systui_package_managers_before_menu_consolidation }
    eval "$_systui_saved_fn"
    unset _systui_saved_fn
fi

menu_package_managers() {
    local c
    while true; do
        local -a opts=(
            native "Native and language package managers"
        )
        if declare -F bedrock_systui_is_installed >/dev/null 2>&1 \
            && bedrock_systui_is_installed 2>/dev/null; then
            opts+=(bedrock "Bedrock strata package managers")
        fi
        opts+=(back "Back")
        tui_capture_menu c tui_menu_no_tags "Package Managers" \
            "Install, remove and configure package-manager ecosystems:" \
            "${opts[@]}" || return $?
        case "$c" in
            native) tui_call_menu _systui_package_managers_before_menu_consolidation "Native package managers" ;;
            bedrock) tui_call_menu bedrock_systui_package_managers_menu "Bedrock package managers" ;;
            back|'') return 0 ;;
        esac
    done
}

# Packages now has one package-manager entry.  Bedrock is nested inside it.
menu_packages() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Package Configuration [${PM:-unknown}]" \
            "Select a package-management section:" \
            packages  "Install, remove, search and update packages" \
            catalogue "Software catalogue" \
            repos      "Repositories and signing keys" \
            managers   "Package managers" \
            advanced   "Advanced package maintenance" \
            back       "Back" || return $?
        case "$c" in
            packages) tui_call_menu menu_package_operations "Package operations" ;;
            catalogue) tui_call_menu pkg_catalogue "Software catalogue" ;;
            repos) tui_call_menu menu_repos "Repositories" ;;
            managers) tui_call_menu menu_package_managers "Package managers" ;;
            advanced) tui_call_menu menu_pkg_advanced "Advanced package maintenance" ;;
            back|'') return 0 ;;
        esac
    done
}

systui_catalogue_categories_menu() {
    local c cat
    local -a opts=()
    declare -F systui_catalogue_ensure_registry >/dev/null 2>&1 \
        && systui_catalogue_ensure_registry >/dev/null 2>&1 || true
    for cat in ${CAT_ORDER:-}; do
        opts+=("$cat" "$(cat_title "$cat")")
    done
    opts+=(back "Back")
    while true; do
        tui_capture_menu c tui_menu_no_tags "Software categories" \
            "Browse software by category:" "${opts[@]}" || return $?
        [ "$c" = back ] || [ -z "$c" ] && return 0
        tui_call_menu browse_category "Software category: $c" "$c"
    done
}

systui_catalogue_manage_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Catalogue management" \
            "Package discovery and maintenance tools:" \
            installed "Installed catalogue software" \
            updates   "Available package updates" \
            search    "Search package repositories" \
            bulk      "Import/export and bulk package actions" \
            health    "Package health and repair" \
            back      "Back" || return $?
        case "$c" in
            installed) catalogue_installed ;;
            updates) catalogue_updates ;;
            search) catalogue_search ;;
            bulk) catalogue_bulk_manage ;;
            health) catalogue_health ;;
            back|'') return 0 ;;
        esac
    done
}

# The old catalogue mixed every category with maintenance/search actions on a
# single screen.  Keep a compact discovery front door and move the rest into
# Categories and Manage submenus.
pkg_catalogue() {
    local detected c
    declare -F systui_catalogue_ensure_registry >/dev/null 2>&1 \
        && systui_catalogue_ensure_registry >/dev/null 2>&1 || true
    if declare -F systui_catalogue_pm >/dev/null 2>&1; then
        detected=$(systui_catalogue_pm 2>/dev/null || printf unknown)
        PM="$detected"; export PM
    fi
    if [ "${PM:-unknown}" = unknown ]; then
        tui_msg "Software Catalogue" "No supported system package manager was detected."
        return 0
    fi
    while true; do
        tui_capture_menu c tui_menu_no_tags "Software Catalogue [${PM}]" \
            "Browse and manage software:" \
            featured    "Featured software" \
            categories  "Browse all categories" \
            collections "Curated software collections" \
            cli         "Terminal-tool checklists" \
            manage      "Search, updates, installed apps and maintenance" \
            awesome     "Awesome Linux catalogue" \
            back        "Back" || return $?
        case "$c" in
            featured) browse_category featured "${FEATURED_APPS:-}" ;;
            categories) systui_catalogue_categories_menu ;;
            collections) catalogue_collections ;;
            cli) pkg_catalogue_cli ;;
            manage) systui_catalogue_manage_menu ;;
            awesome)
                if declare -F menu_awesome_linux >/dev/null 2>&1; then menu_awesome_linux
                else tui_msg "Awesome Linux" "The Awesome Linux catalogue is unavailable in this build."; fi
                ;;
            back|'') return 0 ;;
        esac
    done
}

# Keep the legacy alias pointed at the authoritative final catalogue rather
# than a stale snapshot captured by the old Awesome Linux wrapper.
_systui_base_pkg_catalogue() { pkg_catalogue "$@"; }

return 0 2>/dev/null || true
