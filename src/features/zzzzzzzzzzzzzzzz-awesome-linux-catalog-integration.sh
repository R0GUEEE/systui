# shellcheck shell=bash
###############################################################################
# AWESOME LINUX CATALOGUE INTEGRATION
#
# Moves the existing Awesome Linux software catalogue under:
#   System Configuration -> Packages -> Browse the application catalogue
# and removes its standalone Main Menu entry at runtime.
###############################################################################

# Preserve the original catalogue browser and TUI menu implementation once.
if declare -F pkg_catalogue >/dev/null 2>&1 \
    && ! declare -F _systui_base_pkg_catalogue >/dev/null 2>&1; then
    eval "$(declare -f pkg_catalogue | sed '1s/^pkg_catalogue[[:space:]]*()/_systui_base_pkg_catalogue ()/')"
fi

if declare -F tui_menu >/dev/null 2>&1 \
    && ! declare -F _systui_base_tui_menu >/dev/null 2>&1; then
    eval "$(declare -f tui_menu | sed '1s/^tui_menu[[:space:]]*()/_systui_base_tui_menu ()/')"
fi

# Single catalogue front door. The existing Systui application catalogue and
# the existing Awesome Linux catalogue remain independent implementations, but
# users reach both from Packages -> Browse the application catalogue.
pkg_catalogue() {
    local c
    while true; do
        c=$(_systui_base_tui_menu "Application catalogue" \
            "Browse software catalogues:" \
            systui  "Systui application catalogue" \
            awesome "Awesome Linux software catalogue" \
            back    "Back") || return 0
        case "$c" in
            systui) _systui_base_pkg_catalogue ;;
            awesome)
                if declare -F menu_awesome_linux >/dev/null 2>&1; then
                    menu_awesome_linux
                else
                    tui_msg "Awesome Linux" "The Awesome Linux catalogue is not available in this build."
                fi
                ;;
            back|"") return 0 ;;
        esac
    done
}

# install.sh defines main_menu after feature loading, so a feature cannot replace
# main_menu directly. Filter only the exact legacy Awesome Linux option from the
# generic menu call when the generated launcher renders "Main Menu". All other
# tui_menu calls are forwarded byte-for-byte through the preserved implementation.
tui_menu() {
    local title="${1:-}" text="${2:-}"
    shift 2 || true

    if [ "$title" = "Main Menu" ]; then
        local -a filtered=()
        local tag label
        while [ "$#" -ge 2 ]; do
            tag="$1"; label="$2"; shift 2
            if [ "$tag" = awesome ] && [ "$label" = "Awesome Linux (software catalogue)" ]; then
                continue
            fi
            filtered+=("$tag" "$label")
        done
        _systui_base_tui_menu "$title" "$text" "${filtered[@]}"
        return $?
    fi

    _systui_base_tui_menu "$title" "$text" "$@"
}

return 0 2>/dev/null || true
