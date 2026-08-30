#!/bin/bash
# Central feature-manifest loader.

systui_unexport_all_functions() {
    local decl attrs fn
    while read -r decl attrs fn; do
        [ "$decl" = declare ] || continue
        [ -n "${fn:-}" ] || continue
        export -n -f "$fn" 2>/dev/null || true
    done < <(declare -Fx)
}

systui_should_scrub_function_exports() {
    case "${SYSTUI_SCRUB_FUNCTION_EXPORTS:-auto}" in
        1|yes|true|always) return 0 ;;
        0|no|false|never) return 1 ;;
    esac
    # In auto mode, constrained iSH runtimes need aggressive scrubbing. Native
    # Linux keeps legacy export behavior until remaining feature callers migrate.
    if declare -F systui_is_ish >/dev/null 2>&1; then
        systui_is_ish
    else
        return 1
    fi
}

systui_load_features() { # [manifest]
    local manifest="${1:-$SYSTUI_LIBDIR/src/features/.load-order}" rel feature
    [ -r "$manifest" ] || {
        echo "systui: missing feature load manifest: $manifest" >&2
        return 1
    }
    while IFS= read -r rel || [ -n "$rel" ]; do
        case "$rel" in ''|'#'*) continue ;; esac
        feature="$SYSTUI_LIBDIR/src/features/$rel"
        [ -f "$feature" ] || {
            echo "systui: feature manifest references missing file: $rel" >&2
            return 1
        }
        # shellcheck disable=SC1090
        . "$feature" || {
            echo "systui: failed to load $feature" >&2
            return 1
        }
        systui_should_scrub_function_exports && systui_unexport_all_functions
    done < "$manifest"
}

export -n -f systui_unexport_all_functions systui_should_scrub_function_exports systui_load_features 2>/dev/null || true
