#!/bin/bash
# Central feature-manifest loader.

systui_unexport_all_functions() {
    local line fn
    while IFS= read -r line; do
        fn=${line##* }
        [ -n "${fn:-}" ] || continue
        export -n -f "${fn?}" 2>/dev/null || true
    done < <(declare -Fx)
}

systui_should_scrub_function_exports() {
    case "${SYSTUI_SCRUB_FUNCTION_EXPORTS:-auto}" in
        1|yes|true|always) return 0 ;;
        0|no|false|never) return 1 ;;
    esac
    if declare -F systui_is_ish >/dev/null 2>&1; then
        systui_is_ish
    else
        return 1
    fi
}

# Feature filenames historically used growing z-prefixes to control load order.
# If an update leaves a manifest from one revision beside feature files from
# another revision, resolve a missing z-prefixed entry by its stable suffix.
# Only accept a unique match so genuinely missing/ambiguous features still fail.
systui_resolve_feature_path() { # <manifest entry>
    local rel="$1" feature suffix candidate found=""
    feature="$SYSTUI_LIBDIR/src/features/$rel"

    if [ -f "$feature" ]; then
        printf '%s\n' "$feature"
        return 0
    fi

    case "$rel" in
        z*-*.sh) suffix="${rel#*-}" ;;
        *) return 1 ;;
    esac

    for candidate in "$SYSTUI_LIBDIR"/src/features/z*-"$suffix"; do
        [ -f "$candidate" ] || continue
        if [ -n "$found" ]; then
            return 1
        fi
        found="$candidate"
    done

    [ -n "$found" ] || return 1
    printf '%s\n' "$found"
}

systui_load_features() { # [manifest]
    local manifest="${1:-$SYSTUI_LIBDIR/src/features/.load-order}" rel feature resolved
    [ -r "$manifest" ] || {
        echo "systui: missing feature load manifest: $manifest" >&2
        return 1
    }
    while IFS= read -r rel || [ -n "$rel" ]; do
        case "$rel" in ''|'#'*) continue ;; esac
        feature="$SYSTUI_LIBDIR/src/features/$rel"
        if [ ! -f "$feature" ]; then
            resolved=$(systui_resolve_feature_path "$rel") || {
                echo "systui: feature manifest references missing file: $rel" >&2
                return 1
            }
            echo "systui: recovered stale feature manifest entry: $rel -> ${resolved##*/}" >&2
            feature="$resolved"
        fi
        # shellcheck disable=SC1090
        . "$feature" || {
            echo "systui: failed to load $feature" >&2
            return 1
        }
        # Do not let a deliberate "no scrub needed" result become the loader's
        # return status on native Linux. A completed feature load is success.
        if systui_should_scrub_function_exports; then
            systui_unexport_all_functions
        fi
    done < "$manifest"
    return 0
}

export -n -f systui_unexport_all_functions systui_should_scrub_function_exports systui_resolve_feature_path systui_load_features 2>/dev/null || true
