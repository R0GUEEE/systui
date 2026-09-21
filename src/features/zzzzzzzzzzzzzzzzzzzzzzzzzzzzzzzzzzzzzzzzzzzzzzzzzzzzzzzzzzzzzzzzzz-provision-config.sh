# shellcheck shell=bash
###############################################################################
# ULTIMATE PROVISION — package set, service configuration and status accuracy
#
# Two things this fixes:
#
#  1. `script_provision_tool_status` compared the installed tool with the
#     *pristine* bundled script, but the installer applies compatibility patches
#     (init detection, non-blocking APT, APT batching). The patched copy can
#     therefore never match, so every visit reported "update available or locally
#     modified" and Quick setup reinstalled every time. Status now compares
#     against the expected patched content.
#  2. The provisioned package set and service pass were fixed in the script with
#     no way to tune them from systui. Extra/excluded packages and the service
#     pass are now configurable, persisted with the other provision settings and
#     passed to the script through the environment; PROVISION_DRY_RUN=1 lets the
#     package set be previewed without changing anything.
###############################################################################

# standalone safety: pull in the alias helper when this feature is sourced
# without core/common.sh (tests, reduced builds).
if ! declare -F systui_alias_function >/dev/null 2>&1; then
    _systui_alias_mod="${SYSTUI_LIBDIR:-$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)}/src/core/alias.sh"
    [ -r "$_systui_alias_mod" ] && . "$_systui_alias_mod"
    unset _systui_alias_mod
fi

# The installed tool with the same compatibility patches the installer applies.
# No process substitution: this runs on hosts without /dev/fd.
script_provision_expected_file() {
    local out fn
    out="${SYSTUI_TMP:-${TMPDIR:-/tmp}}/.systui-provision-expected.$$"
    install -m 0755 "$(script_provision_source_path)" "$out" 2>/dev/null || return 1
    for fn in script_provision_patch_init_detection \
              script_provision_patch_apt_nonblocking \
              script_provision_patch_apt_batches; do
        declare -F "$fn" >/dev/null 2>&1 || continue
        "$fn" "$out" >/dev/null 2>&1 || true
    done
    printf '%s\n' "$out"
}

# Compare against the expected content, not the pristine payload.
script_provision_tool_status() {
    local expected status
    if [ ! -f "$(script_provision_tool_path)" ]; then
        printf '%s\n' "not installed"
        return 0
    fi
    expected=$(script_provision_expected_file)
    if [ -n "$expected" ] && cmp -s "$expected" "$(script_provision_tool_path)"; then
        status="installed (current)"
    else
        status="installed (update available or locally modified)"
    fi
    [ -z "$expected" ] || rm -f -- "$expected" 2>/dev/null || true
    printf '%s\n' "$status"
}

# --- package set and service configuration -----------------------------------

script_provision_defaults_extra() {
    : "${SCRIPT_PROV_EXTRA_PKGS:=}"
    : "${SCRIPT_PROV_SKIP_PKGS:=}"
    : "${SCRIPT_PROV_SKIP_SERVICES:=0}"
}

if declare -F script_provision_load >/dev/null 2>&1 \
    && ! declare -F _systui_prov_base_load >/dev/null 2>&1; then
    systui_alias_function script_provision_load _systui_prov_base_load
fi
script_provision_load() {
    _systui_prov_base_load
    local config_file key value
    config_file=$(script_provision_config_file)
    if [ -r "$config_file" ]; then
        while IFS='=' read -r key value || [ -n "$key" ]; do
            case "$key" in
                SCRIPT_PROV_EXTRA_PKGS)     SCRIPT_PROV_EXTRA_PKGS="$value" ;;
                SCRIPT_PROV_SKIP_PKGS)      SCRIPT_PROV_SKIP_PKGS="$value" ;;
                SCRIPT_PROV_SKIP_SERVICES)  SCRIPT_PROV_SKIP_SERVICES="$value" ;;
            esac
        done < "$config_file"
    fi
    script_provision_defaults_extra
}

if declare -F script_provision_save >/dev/null 2>&1 \
    && ! declare -F _systui_prov_base_save >/dev/null 2>&1; then
    systui_alias_function script_provision_save _systui_prov_base_save
fi
script_provision_save() {
    _systui_prov_base_save || return 1
    local config_file tmp key value
    config_file=$(script_provision_config_file)
    tmp="${SYSTUI_TMP:-${TMPDIR:-/tmp}}/.systui-provision-conf.$$"
    : > "$tmp" || return 1
    for key in SCRIPT_PROV_EXTRA_PKGS SCRIPT_PROV_SKIP_PKGS SCRIPT_PROV_SKIP_SERVICES; do
        eval "value=\${$key-}"
        case "$key" in
            SCRIPT_PROV_EXTRA_PKGS|SCRIPT_PROV_SKIP_PKGS)
                # Package lists are space-separated; anything else is rejected.
                case "$value" in *[!\ A-Za-z0-9_.:@+/-]*) continue ;; esac ;;
        esac
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    done
    if [ -s "$tmp" ]; then
        grep -v -E '^SCRIPT_PROV_(EXTRA_PKGS|SKIP_PKGS|SKIP_SERVICES)=' "$config_file" > "${tmp}.base" 2>/dev/null || : > "${tmp}.base"
        cat "$tmp" >> "${tmp}.base"
        chmod 0600 "${tmp}.base"
        mv -f "${tmp}.base" "$config_file"
    fi
    rm -f -- "$tmp"
    return 0
}

script_provision_packages_menu() {
    local c value
    while true; do
        c=$(tui_menu "Provision package set" \
            "Tune what Ultimate Provision installs. Names are space-separated and use the host distribution's own package names." \
            extra "Extra packages: ${SCRIPT_PROV_EXTRA_PKGS:-none}" \
            skip "Excluded packages: ${SCRIPT_PROV_SKIP_PKGS:-none}" \
            services "Service configuration: $([ "$SCRIPT_PROV_SKIP_SERVICES" = 1 ] && echo disabled || echo enabled)" \
            preview "Preview the package set (dry run, changes nothing)" \
            back "Save and return") || { script_provision_save; return 0; }
        case "$c" in
            extra)
                value=$(tui_input "Extra packages" \
                    "Packages to add to the provision set (space-separated; blank to clear):" \
                    "$SCRIPT_PROV_EXTRA_PKGS") || continue
                case "$value" in
                    *[!\ A-Za-z0-9_.:@+/-]*) tui_msg "Invalid package list" "Use package names separated by spaces." ;;
                    *) SCRIPT_PROV_EXTRA_PKGS="$value" ;;
                esac
                ;;
            skip)
                value=$(tui_input "Excluded packages" \
                    "Packages to leave out, e.g. openssh-server rsyslog chrony (blank to clear):" \
                    "$SCRIPT_PROV_SKIP_PKGS") || continue
                case "$value" in
                    *[!\ A-Za-z0-9_.:@+/-]*) tui_msg "Invalid package list" "Use package names separated by spaces." ;;
                    *) SCRIPT_PROV_SKIP_PKGS="$value" ;;
                esac
                ;;
            services)
                if [ "$SCRIPT_PROV_SKIP_SERVICES" = 1 ]; then
                    SCRIPT_PROV_SKIP_SERVICES=0
                else
                    tui_yesno "Service configuration" \
                        "Skip enabling and starting services (rsyslog, ssh, cron, chrony)?\n\nUseful in containers and under emulation where no service manager owns PID 1." \
                        && SCRIPT_PROV_SKIP_SERVICES=1 || true
                fi
                ;;
            preview) script_provision_preview ;;
            back|'') script_provision_save; return 0 ;;
        esac
        script_provision_save
    done
}

script_provision_preview() {
    local script out
    script=$(script_provision_tool_path)
    if [ ! -x "$script" ]; then
        tui_msg "Ultimate Provision Not Installed" "Install Ultimate Provision before previewing the package set."
        return 0
    fi
    out="${SYSTUI_TMP:-/tmp}/provision-preview.txt"
    env TZ_NAME="$SCRIPT_PROV_TZ" \
        TARGET_USER="$SCRIPT_PROV_USER" \
        NEW_HOSTNAME="$SCRIPT_PROV_HOST" \
        SUDO_NOPASSWD="$SCRIPT_PROV_NOPASS" \
        EXTRA_PKGS="$SCRIPT_PROV_EXTRA_PKGS" \
        SKIP_PKGS="$SCRIPT_PROV_SKIP_PKGS" \
        SKIP_SERVICES="$SCRIPT_PROV_SKIP_SERVICES" \
        PROVISION_DRY_RUN=1 \
        sh "$script" > "$out" 2>&1 || true
    [ -s "$out" ] || printf '%s\n' "(the provision tool produced no output)" > "$out"
    tui_text "Provision package set (dry run)" "$out" || true
}

# --- menu and run integration ------------------------------------------------

if declare -F menu_ultimate_provision >/dev/null 2>&1 \
    && ! declare -F _systui_prov_base_menu >/dev/null 2>&1; then
    systui_alias_function menu_ultimate_provision _systui_prov_base_menu
fi
menu_ultimate_provision() {
    local choice
    script_provision_load
    while true; do
        choice=$(tui_menu "Ultimate Provision" \
            "Tool: $(script_provision_tool_status) | System: $(script_provision_system_status)" \
            quick "Quick setup (install/update, configure, and run)" \
            install "Install or update Ultimate Provision" \
            packages "Package set — extra and excluded packages, service pass" \
            configure "Configure quick-setup settings" \
            status "Show status and current settings" \
            run "Run Ultimate Provision now" \
            remove "Remove installed Ultimate Provision" \
            back "Back to main menu") || return 0
        case "$choice" in
            packages) script_provision_packages_menu ;;
            *) _systui_prov_base_menu_from "$choice" ;;
        esac
    done
}

# Dispatch one already-chosen entry through the previous menu implementation so
# every original action keeps working unchanged.
_systui_prov_base_menu_from() {
    local choice="$1"
    case "$choice" in
        quick) script_provision_quick_setup ;;
        install) script_provision_install_action ;;
        configure) script_provision_configure ;;
        status) script_provision_status ;;
        run) script_provision_run ;;
        remove) script_provision_remove_action ;;
        back|'') return 0 ;;
        *) return 0 ;;
    esac
}

return 0 2>/dev/null || true
