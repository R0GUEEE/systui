# shellcheck shell=bash
# Advanced performance tuning is exposed directly by the top-level systui menu.
# Remove the duplicate entry from System Configuration while preserving the
# existing menu_performance implementation.

if declare -F menu_sysconfig >/dev/null 2>&1; then
    eval "$(declare -f menu_sysconfig | awk '
        /performance[[:space:]]+\"Advanced performance tuning\"/ { next }
        /performance\)[[:space:]]+menu_performance/ { next }
        { print }
    ')"
fi
