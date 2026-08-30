# shellcheck shell=bash
# PHASE 50 — validated repository input compatibility layer.

# shellcheck source=../sysconfig/repositories.sh
. "$SYSTUI_LIBDIR/src/sysconfig/repositories.sh"

sysconfig_repo_add_custom() {
    systui_sysconfig_repo_add_custom "$@"
}

export -n -f sysconfig_repo_add_custom 2>/dev/null || true
