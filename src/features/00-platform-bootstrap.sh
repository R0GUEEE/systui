# shellcheck shell=bash
# Load authoritative core modules before legacy feature code. Legacy feature
# files may still override behavior during migration, but new code should use
# these stable APIs instead of creating additional wrapper layers.

for _systui_core_module in \
    "$SYSTUI_LIBDIR/src/core/platform.sh" \
    "$SYSTUI_LIBDIR/src/core/package-map-data.sh" \
    "$SYSTUI_LIBDIR/src/rootfs/metadata.sh" \
    "$SYSTUI_LIBDIR/src/rootfs/api.sh"
do
    [ -r "$_systui_core_module" ] || {
        echo "systui: missing core module: $_systui_core_module" >&2
        return 1
    }
    # shellcheck disable=SC1090
    . "$_systui_core_module"
done
unset _systui_core_module

detect_init() {
    systui_detect_init
    log "Detected init: ${INIT:-unknown} (provider=${SYSTUI_INIT_PROVIDER:-unknown}, runtime=${SYSTUI_SERVICE_RUNTIME:-unknown}, env=${SYSTUI_ENVIRONMENT:-unknown})"
}

detect_init 2>/dev/null || true
