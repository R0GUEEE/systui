# shellcheck shell=bash
###############################################################################
# SYSTEM CONFIGURATION — installation execution guard
#
# Installer/build/download commands launched through run_cmd must not be able to
# block the whole TUI forever on an unseen prompt, stalled Git transport, or a
# network operation that never returns. Ordinary run_cmd uses remain interactive.
###############################################################################

# Preserve the previous run_cmd using Bash builtins only. Avoid an external
# declare -f | sed pipeline here: on iSH an already-large inherited environment
# can make the sed exec fail with E2BIG before cleanup code gets a chance to run.
if declare -F run_cmd >/dev/null 2>&1 && ! declare -F _systui_base_run_cmd_install_guard >/dev/null 2>&1; then
    _systui_run_cmd_def=$(declare -f run_cmd)
    _systui_run_cmd_def=${_systui_run_cmd_def/#run_cmd ()/_systui_base_run_cmd_install_guard ()}
    _systui_run_cmd_def=${_systui_run_cmd_def/#run_cmd()/_systui_base_run_cmd_install_guard()}
    eval "$_systui_run_cmd_def"
    unset _systui_run_cmd_def
fi

systui_installish_run() { # <description> <argv...>
    local desc="${1:-}" cmd="${2:-}" text
    text="${desc,,} ${cmd,,}"
    case "$text" in
        *install*|*reinstall*|*uninstall*|*download*|*fetch*|*clone*|*build*|*bootstrap*|*setup*|*cargo\ add*|*cargo\ install*|*brew\ *|*nvm\ *|*npm\ *|*pnpm\ *|*yarn\ *|*pip\ *|*pip3\ *|*gem\ *|*composer\ *|*go\ install*|*makepkg*|*git\ clone*|*git\ pull*) return 0 ;;
        *) return 1 ;;
    esac
}

systui_guard_timeout_seconds() {
    local v="${SYSTUI_INSTALL_TIMEOUT:-2700}"
    case "$v" in ''|*[!0-9]*) v=2700;; esac
    [ "$v" -ge 60 ] 2>/dev/null || v=60
    printf '%s\n' "$v"
}

systui_guard_export_noninteractive() {
    export CI=1
    export NONINTERACTIVE=1
    export DEBIAN_FRONTEND=noninteractive
    export DEBCONF_NONINTERACTIVE_SEEN=true
    export NEEDRESTART_MODE=a
    export APT_LISTCHANGES_FRONTEND=none
    export GIT_TERMINAL_PROMPT=0
    export GIT_ASKPASS=/bin/false
    export SSH_ASKPASS=/bin/false
    export GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1024}"
    export GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-60}"
    export HOMEBREW_NO_ENV_HINTS=1
}

systui_guard_exec_function() { # <timeout-seconds> <function> [args...]
    local seconds="$1" fn="$2" pid watcher rc=0
    shift 2

    # A Bash function cannot be exec(2)'d by coreutils timeout. Re-exporting
    # every Systui function is also not acceptable on iSH because BASH_FUNC_*
    # quickly exhausts its small ARG_MAX. Run the function in a forked Bash
    # subshell instead; fork preserves the current function table without
    # placing function bodies in the environment.
    (
        systui_guard_export_noninteractive
        "$fn" "$@"
    ) &
    pid=$!

    (
        sleep "$seconds"
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            sleep 2
            kill -KILL "$pid" 2>/dev/null || true
        fi
    ) &
    watcher=$!

    wait "$pid" || rc=$?
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true

    if [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; then
        return 124
    fi
    return "$rc"
}

systui_guard_exec() { # <timeout-seconds> <argv...>
    local seconds="${1:-}" cmd="${2:-}"
    [ -n "$seconds" ] && [ -n "$cmd" ] || return 127

    # Remove both guard metadata arguments. Previously only the timeout was
    # shifted, leaving the command/function name at the front of "$@". The
    # function path then received its own name as argv[1], e.g.:
    #   rootfs_exec_raw rootfs_exec_raw /opt/rootfs/... 
    # which made chroot try to enter a directory literally named
    # "rootfs_exec_raw".
    shift 2

    if declare -F "$cmd" >/dev/null 2>&1; then
        systui_guard_exec_function "$seconds" "$cmd" "$@"
        return $?
    fi

    local -a prefix=(env
        CI=1
        NONINTERACTIVE=1
        DEBIAN_FRONTEND=noninteractive
        DEBCONF_NONINTERACTIVE_SEEN=true
        NEEDRESTART_MODE=a
        APT_LISTCHANGES_FRONTEND=none
        GIT_TERMINAL_PROMPT=0
        GIT_ASKPASS=/bin/false
        SSH_ASKPASS=/bin/false
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

run_cmd() {
    local desc="$1"; shift
    local rc=0 had_errexit=0 timeout_s
    case $- in *e*) had_errexit=1 ;; esac

    if ! systui_installish_run "$desc" "${1:-}"; then
        _systui_base_run_cmd_install_guard "$desc" "$@"
        return $?
    fi

    timeout_s=$(systui_guard_timeout_seconds)
    log "RUN (guarded install, timeout=${timeout_s}s): $desc :: $*"
    clear
    echo ">>> $desc"
    echo ">>> $*"
    echo ">>> installer guard: non-interactive, timeout ${timeout_s}s"
    echo "================================================================="

    set +e
    systui_guard_exec "$timeout_s" "$@" </dev/null 2>&1 | tee -a "$LOGFILE"
    rc=${PIPESTATUS[0]}

    if [ "$had_errexit" -eq 1 ]; then set -e; else set +e; fi

    if [ "$rc" -eq 0 ]; then
        echo "================================================================="
        echo "Done: $desc"
        return 0
    fi

    echo "================================================================="
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ] || [ "$rc" -eq 143 ]; then
        echo "Installer stopped after reaching the ${timeout_s}s safety limit."
        log "TIMEOUT ($rc): $desc"
    else
        log "FAILED ($rc): $desc"
    fi
    read -rp "FAILED ($rc): $desc — see $LOGFILE  (press Enter)" _ || true
    return "$rc"
}

export -n -f run_cmd 2>/dev/null || true
export -n -f systui_installish_run systui_guard_timeout_seconds systui_guard_export_noninteractive systui_guard_exec_function systui_guard_exec 2>/dev/null || true
