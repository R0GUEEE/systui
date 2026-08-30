# shellcheck shell=bash
###############################################################################
# AWESOME LINUX CATALOGUE INTEGRATION
#
# Exposes the Awesome Linux software catalogue under:
#   System Configuration -> Packages -> Application catalogue
#
# The generated main menu no longer contains a standalone catalogue entry, so
# this feature only extends the package catalogue and does not wrap tui_menu.
###############################################################################

# Preserve the original package catalogue with Bash builtins only. Avoid a
# declare-f | sed pipeline during feature loading: on iSH that can trigger
# ARG_MAX failures before the late environment cleanup runs.
if declare -F pkg_catalogue >/dev/null 2>&1 \
    && ! declare -F _systui_base_pkg_catalogue >/dev/null 2>&1; then
    _systui_catalogue_fn=$(declare -f pkg_catalogue)
    _systui_catalogue_fn=${_systui_catalogue_fn/#pkg_catalogue ()/_systui_base_pkg_catalogue ()}
    eval "$_systui_catalogue_fn"
    unset _systui_catalogue_fn
fi

pkg_catalogue() {
    local c
    while true; do
        c=$(tui_menu "Application catalogue" \
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

return 0 2>/dev/null || true
