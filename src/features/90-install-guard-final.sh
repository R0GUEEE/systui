# shellcheck shell=bash
# Phase 90: final installer dispatcher. New phase-based modules replace the
# historical zzz filename-priority convention.

systui_guard_exec() { # <timeout-seconds> <command-or-function> [args...]
    local seconds="${1:-}" cmd="${2:-}"
    [ -n "$seconds" ] && [ -n "$cmd" ] || return 127
    shift 2

    if declare -F "$cmd" >/dev/null 2>&1; then
        systui_guard_exec_function "$seconds" "$cmd" "$@"
        return $?
    fi

    local -a prefix=(env
        CI=1 NONINTERACTIVE=1 DEBIAN_FRONTEND=noninteractive
        DEBCONF_NONINTERACTIVE_SEEN=true NEEDRESTART_MODE=a
        APT_LISTCHANGES_FRONTEND=none GIT_TERMINAL_PROMPT=0
        GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false
        "GIT_HTTP_LOW_SPEED_LIMIT=${GIT_HTTP_LOW_SPEED_LIMIT:-1024}"
        "GIT_HTTP_LOW_SPEED_TIME=${GIT_HTTP_LOW_SPEED_TIME:-60}"
        HOMEBREW_NO_ENV_HINTS=1)

    if command -v timeout >/dev/null 2>&1; then
        if timeout --help 2>&1 | grep -q -- '--kill-after'; then
            "${prefix[@]}" timeout --foreground --signal=TERM --kill-after=15s "${seconds}s" "$cmd" "$@"
        else
            "${prefix[@]}" timeout "$seconds" "$cmd" "$@"
        fi
    else
        "${prefix[@]}" "$cmd" "$@"
    fi
}

export -n -f systui_guard_exec 2>/dev/null || true
