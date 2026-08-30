#!/bin/bash
# Strict child execution using the same feature loader as the main wrapper.

run_strict() { # <description> <function> [args...]
    local desc="$1" fn="$2"; shift 2
    if ! declare -F "$fn" >/dev/null 2>&1; then
        declare -F warn >/dev/null 2>&1 && warn "run_strict: no such function: $fn"
        return 127
    fi

    SYSTUI_STRICT_CHILD=1 \
    SYSTUI_TMP="$SYSTUI_TMP" \
    SYSTUI_LIBDIR="$SYSTUI_LIBDIR" \
    SYSTUI_LOGFILE="$LOGFILE" \
    SYSTUI_STRICT_DESC="$desc" \
    bash -c '
        set -eE
        . "$SYSTUI_LIBDIR/src/core/config.sh"
        . "$SYSTUI_LIBDIR/src/core/tui-widgets.sh"
        . "$SYSTUI_LIBDIR/src/core/common.sh"
        . "$SYSTUI_LIBDIR/src/core/platform.sh"
        . "$SYSTUI_LIBDIR/src/core/loader.sh"
        systui_load_features
        detect_pm; detect_init; detect_distro
        trap '"'"'warn "$SYSTUI_STRICT_DESC: unexpected error on line $LINENO"; exit 1'"'"' ERR
        "$@"
    ' _ "$fn" "$@"
}

export -n -f run_strict 2>/dev/null || true
