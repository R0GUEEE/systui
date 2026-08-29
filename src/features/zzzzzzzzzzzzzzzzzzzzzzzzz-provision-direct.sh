# shellcheck shell=bash
###############################################################################
# ULTIMATE PROVISION — direct main-menu quick setup
###############################################################################

# The main menu already dispatches Provision through menu_ultimate_provision.
# Redefine that entry point so selecting Provision immediately runs the quick
# setup workflow instead of showing the management submenu.
menu_ultimate_provision() {
    script_provision_load
    script_provision_quick_setup
}

export -f menu_ultimate_provision
