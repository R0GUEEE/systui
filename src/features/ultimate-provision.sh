#!/bin/bash
# Install, configure, and manage Ultimate Provision.

script_provision_source_path() {
    printf '%s\n' "$LIBDIR/src/provision/provision-ultimate.sh"
}

script_provision_tool_path() {
    printf '%s\n' "${SYSTUI_PROVISION_TOOL:-/usr/local/sbin/provision-ultimate}"
}

script_provision_tool_status() {
    local source tool
    source=$(script_provision_source_path)
    tool=$(script_provision_tool_path)
    if [ ! -f "$tool" ]; then
        printf '%s\n' "not installed"
    elif [ -r "$source" ] && cmp -s "$source" "$tool"; then
        printf '%s\n' "installed (current)"
    else
        printf '%s\n' "installed (update available or locally modified)"
    fi
}

script_provision_system_status() {
    local manager=${PM:-}
    [ -n "$manager" ] || {
        if command -v apt-get >/dev/null 2>&1; then manager=apt
        elif command -v apk >/dev/null 2>&1; then manager=apk
        elif command -v pacman >/dev/null 2>&1; then manager=pacman
        elif command -v dnf >/dev/null 2>&1; then manager=dnf
        elif command -v yum >/dev/null 2>&1; then manager=yum
        elif command -v zypper >/dev/null 2>&1; then manager=zypper
        elif command -v xbps-install >/dev/null 2>&1; then manager=xbps
        elif command -v emerge >/dev/null 2>&1; then manager=portage
        else manager=unknown
        fi
    }
    case "$manager" in
        apt|apk|pacman|dnf|yum|zypper|xbps|portage) printf 'compatible (%s)\n' "$manager" ;;
        *) printf '%s\n' "unsupported (no recognized package manager)" ;;
    esac
}

script_provision_install_tool() {
    local source tool tool_dir
    source=$(script_provision_source_path)
    tool=$(script_provision_tool_path)
    tool_dir=$(dirname "$tool")
    [ -r "$source" ] || return 1
    mkdir -p "$tool_dir" || return 1
    install -m 0755 "$source" "$tool"
}

script_provision_remove_tool() {
    local tool
    tool=$(script_provision_tool_path)
    [ ! -e "$tool" ] || rm -f -- "$tool"
}

script_provision_defaults() {
    : "${SCRIPT_PROV_TZ:=America/Los_Angeles}"
    : "${SCRIPT_PROV_USER:=${SUDO_USER:-}}"
    if [ -z "$SCRIPT_PROV_USER" ] || [ "$SCRIPT_PROV_USER" = root ]; then
        SCRIPT_PROV_USER=$(awk -F: '$3>=1000 && $3<2000 {print $1; exit}' /etc/passwd 2>/dev/null || true)
    fi
    : "${SCRIPT_PROV_USER:=aok}"
    : "${SCRIPT_PROV_HOST:=$(cat /etc/hostname 2>/dev/null || true)}"
    [ -n "$SCRIPT_PROV_HOST" ] && [ "$SCRIPT_PROV_HOST" != localhost ] || SCRIPT_PROV_HOST=linux-ultimate
    : "${SCRIPT_PROV_NOPASS:=0}"
}

script_provision_config_file() {
    printf '%s\n' "${SYSTUI_PROVISION_CONFIG:-/etc/systui/provision-ultimate.conf}"
}

script_provision_load() {
    local config_file key value
    config_file=$(script_provision_config_file)
    if [ -r "$config_file" ]; then
        while IFS='=' read -r key value; do
            case "$key" in
                SCRIPT_PROV_TZ) SCRIPT_PROV_TZ="$value" ;;
                SCRIPT_PROV_USER) SCRIPT_PROV_USER="$value" ;;
                SCRIPT_PROV_HOST) SCRIPT_PROV_HOST="$value" ;;
                SCRIPT_PROV_NOPASS) SCRIPT_PROV_NOPASS="$value" ;;
            esac
        done < "$config_file"
    fi
    script_provision_defaults
}

script_provision_save() {
    local config_file config_dir
    config_file=$(script_provision_config_file)
    config_dir=$(dirname "$config_file")
    mkdir -p "$config_dir"
    {
        printf 'SCRIPT_PROV_TZ=%s\n' "$SCRIPT_PROV_TZ"
        printf 'SCRIPT_PROV_USER=%s\n' "$SCRIPT_PROV_USER"
        printf 'SCRIPT_PROV_HOST=%s\n' "$SCRIPT_PROV_HOST"
        printf 'SCRIPT_PROV_NOPASS=%s\n' "$SCRIPT_PROV_NOPASS"
    } > "$config_file"
    chmod 0600 "$config_file"
}

script_provision_review() {
    local review_file="$SYSTUI_TMP/provision-ultimate.review" tool
    tool=$(script_provision_tool_path)
    {
        echo "ULTIMATE PROVISION"
        echo
        echo "Bundled source: $(script_provision_source_path)"
        echo "Installed tool: $tool"
        echo "Status: $(script_provision_tool_status)"
        echo "Detected system: ${DISTRO_PRETTY_NAME:-${DISTRO:-unknown}}"
        echo "Package manager: ${PM:-unknown}"
        echo "Init system: ${INIT:-unknown}"
        echo "Compatibility: $(script_provision_system_status)"
        echo
        echo "Timezone: $SCRIPT_PROV_TZ"
        echo "Primary login: $SCRIPT_PROV_USER"
        echo "Hostname: $SCRIPT_PROV_HOST"
        if [ "$SCRIPT_PROV_NOPASS" = 1 ]; then
            echo "Sudo: passwordless for members of the sudo group"
        else
            echo "Sudo: password required"
        fi
        echo
        echo "The script installs and configures its complete terminal toolset,"
        echo "services, shell environment, Neovim starter, and tmux configuration."
        echo "It supports APT, APK, pacman, DNF/YUM, zypper, XBPS, and Portage systems."
    } > "$review_file"
    tui_text "Ultimate Provision Review" "$review_file" || true
}

script_provision_configure() {
    local choice value selected
    while true; do
        choice=$(tui_menu "Configure Ultimate Provision" "Settings passed to the bundled provision script:" \
            timezone "Timezone: $SCRIPT_PROV_TZ" \
            username "Primary login: $SCRIPT_PROV_USER" \
            hostname "Hostname: $SCRIPT_PROV_HOST" \
            sudo "Sudo policy: $([ "$SCRIPT_PROV_NOPASS" = 1 ] && echo passwordless || echo password-required)" \
            review "Review current settings" \
            reset "Reset to script defaults" \
            back "Save and return") || { script_provision_save; return 0; }
        case "$choice" in
            timezone)
                value=$(tui_input "Timezone" "Timezone (for example America/New_York or UTC)" "$SCRIPT_PROV_TZ") || continue
                case "$value" in
                    ''|*[!a-zA-Z0-9_+./-]*)
                        tui_msg "Invalid Timezone" "Use a tzdata name such as America/New_York or UTC."
                        ;;
                    *) SCRIPT_PROV_TZ="$value" ;;
                esac
                ;;
            username)
                value=$(tui_input "Primary Login" "Existing or new username" "$SCRIPT_PROV_USER") || continue
                case "$value" in
                    ''|root) tui_msg "Invalid Username" "Enter a non-root username." ;;
                    *[!a-zA-Z0-9_.-]*|[0-9]*|[-.]*)
                        tui_msg "Invalid Username" "Use letters, numbers, underscore, dot, or hyphen; do not start with a number, dot, or hyphen."
                        ;;
                    *) SCRIPT_PROV_USER="$value" ;;
                esac
                ;;
            hostname)
                value=$(tui_input "Hostname" "Hostname to configure" "$SCRIPT_PROV_HOST") || continue
                case "$value" in
                    ''|*[!a-zA-Z0-9.-]*|.*|-*|*.)
                        tui_msg "Invalid Hostname" "Use letters, numbers, dots, and hyphens."
                        ;;
                    *) SCRIPT_PROV_HOST="$value" ;;
                esac
                ;;
            sudo)
                local password_state nopass_state
                if [ "$SCRIPT_PROV_NOPASS" = 0 ]; then
                    password_state=on; nopass_state=off
                else
                    password_state=off; nopass_state=on
                fi
                selected=$(tui_radio "Sudo Policy" "Choose how sudo authenticates:" \
                    password "Require the user's password" "$password_state" \
                    nopass "Allow passwordless sudo" "$nopass_state") || continue
                [ "$selected" = nopass ] && SCRIPT_PROV_NOPASS=1 || SCRIPT_PROV_NOPASS=0
                ;;
            review) script_provision_review ;;
            reset)
                if tui_yesno "Reset Settings" "Reset all provision-script settings to their defaults?"; then
                    unset SCRIPT_PROV_TZ SCRIPT_PROV_USER SCRIPT_PROV_HOST SCRIPT_PROV_NOPASS
                    script_provision_defaults
                fi
                ;;
            back) script_provision_save; return 0 ;;
        esac
        script_provision_save
    done
}

script_provision_install_action() {
    local status
    status=$(script_provision_tool_status)
    if [ "$status" != "not installed" ]; then
        tui_yesno "Update Ultimate Provision" "Replace the installed provision tool with the bundled version?" || return 0
    fi
    if script_provision_install_tool; then
        tui_msg "Ultimate Provision" "Ultimate Provision is installed and current at:\n$(script_provision_tool_path)"
    else
        tui_msg "Installation Failed" "Could not install the bundled provision tool."
    fi
}

script_provision_remove_action() {
    local tool config_file
    tool=$(script_provision_tool_path)
    config_file=$(script_provision_config_file)
    [ -e "$tool" ] || {
        tui_msg "Ultimate Provision" "The provision tool is not installed."
        return 0
    }
    tui_yesno "Remove Ultimate Provision" "Remove the installed tool?\n\n$tool\n\nSaved configuration will be kept." || return 0
    if script_provision_remove_tool; then
        tui_msg "Ultimate Provision Removed" "Removed $tool\n\nConfiguration was kept at:\n$config_file"
    else
        tui_msg "Removal Failed" "Could not remove $tool"
    fi
}

script_provision_status() {
    script_provision_review
}

script_provision_run() {
    local script rc=0
    script=$(script_provision_tool_path)
    [ -x "$script" ] || {
        tui_msg "Ultimate Provision Not Installed" "Install Ultimate Provision before running it."
        return 0
    }
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

script_provision_quick_setup() {
    if [ "$(script_provision_tool_status)" != "installed (current)" ]; then
        script_provision_install_action
    fi
    [ -x "$(script_provision_tool_path)" ] || return 0
    script_provision_configure
    script_provision_run
}

menu_ultimate_provision() {
    local choice
    script_provision_load
    while true; do
        choice=$(tui_menu "Ultimate Provision" \
            "Tool: $(script_provision_tool_status) | System: $(script_provision_system_status)" \
            quick "Quick setup (install/update, configure, and run)" \
            install "Install or update Ultimate Provision" \
            configure "Configure quick-setup settings" \
            status "Show status and current settings" \
            run "Run Ultimate Provision now" \
            remove "Remove installed Ultimate Provision" \
            back "Back to main menu") || return 0
        case "$choice" in
            quick) script_provision_quick_setup ;;
            install) script_provision_install_action ;;
            configure) script_provision_configure ;;
            status) script_provision_status ;;
            run) script_provision_run ;;
            remove) script_provision_remove_action ;;
            back) return 0 ;;
        esac
    done
}

export -f menu_ultimate_provision
