# shellcheck shell=bash
# Load the authoritative platform detector before any feature module can make
# environment/init decisions. A final routing layer later reasserts the public
# service/rootfs functions after legacy compatibility modules have loaded.

[ -r "$SYSTUI_LIBDIR/src/core/platform.sh" ] || {
    echo "systui: missing core platform capability layer" >&2
    return 1
}
. "$SYSTUI_LIBDIR/src/core/platform.sh"

detect_init() {
    systui_detect_init
    log "Detected init: ${INIT:-unknown} (provider=${SYSTUI_INIT_PROVIDER:-unknown}, runtime=${SYSTUI_SERVICE_RUNTIME:-unknown}, env=${SYSTUI_ENVIRONMENT:-unknown})"
}

detect_init 2>/dev/null || true
