# shellcheck shell=bash
###############################################################################
# SYSTEM CONFIGURATION — nonblocking Oh My Bash installer
###############################################################################

# Run one Git operation as the target user with prompting disabled and bounded
# transfer stalls. `timeout` supplies a hard ceiling where available; Git's
# HTTP low-speed settings still stop dead transfers on minimal systems without
# coreutils timeout.
omb_git_as_user() { # <user> <git args...>
    local u="$1"; shift
    local -a cmd=(su - "$u" -c)
    local git_cmd q arg

    git_cmd='GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false git -c credential.interactive=false -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=20'
    for arg in "$@"; do
        printf -v q '%q' "$arg"
        git_cmd+=" $q"
    done

    if command -v timeout >/dev/null 2>&1; then
        timeout --signal=TERM --kill-after=5 90 "${cmd[@]}" "$git_cmd"
    else
        "${cmd[@]}" "$git_cmd"
    fi
}

omb_write_systui_block() { # <bashrc> <osh-path>
    local rc="$1" osh="$2" tmp
    tmp=$(mktemp "${rc}.systui-omb.XXXXXX") || return 1

    # Remove any older systui OMB block and comment out active legacy OMB
    # declarations. This is deliberately awk-only: installing Oh My Bash must
    # not require Python on a minimal system.
    awk '
        $0 == "# >>> systui oh-my-bash >>>" { in_block=1; next }
        $0 == "# <<< systui oh-my-bash <<<" { in_block=0; next }
        in_block { next }
        /^[[:space:]]*#/ { print; next }
        /^[[:space:]]*(export[[:space:]]+OSH=|OSH_THEME=|plugins=\(|completions=\(|aliases=\(|(source|\.)[[:space:]].*oh-my-bash\.sh)/ {
            print "# disabled by systui: " $0
            next
        }
        { print }
    ' "$rc" > "$tmp" || { rm -f "$tmp"; return 1; }

    cat >> "$tmp" <<EOF

# >>> systui oh-my-bash >>>
# Systui performs updates explicitly from the OMB menu. Disable OMB's startup
# network update check so an unavailable GitHub connection cannot hang Bash.
export OSH="$osh"
DISABLE_AUTO_UPDATE=true
OSH_THEME="font"
plugins=(git bashmarks)
completions=(git ssh)
aliases=(general)
if [ -n "\${BASH_VERSION-}" ] && [ -r "\$OSH/oh-my-bash.sh" ]; then
    . "\$OSH/oh-my-bash.sh"
fi
# <<< systui oh-my-bash <<<
EOF

    mv -f "$tmp" "$rc"
}

omb_validate_install() { # <user> <home> <osh>
    local u="$1" home_dir="$2" osh="$3" out="${SYSTUI_TMP}/omb-check.$$"
    local test_cmd
    test_cmd="HOME=$(printf '%q' "$home_dir") OSH=$(printf '%q' "$osh") DISABLE_AUTO_UPDATE=true bash --noprofile --norc -ic 'OSH_THEME=font; plugins=(git bashmarks); completions=(git ssh); aliases=(general); . \"\$OSH/oh-my-bash.sh\"; exit' </dev/null"

    if command -v timeout >/dev/null 2>&1; then
        timeout --signal=TERM --kill-after=3 20 su - "$u" -c "$test_cmd" >"$out" 2>&1
    else
        su - "$u" -c "$test_cmd" >"$out" 2>&1
    fi
}

omb_install_compatible() {
    local u="$1" home_dir="$2" mode="${3:-install}"
    local osh="$home_dir/.oh-my-bash" rc="$home_dir/.bashrc"
    local stamp backup validation

    stamp=$(date +%Y%m%d-%H%M%S)
    backup="$home_dir/.bashrc.systui-omb-$stamp.bak"

    command -v bash >/dev/null 2>&1 || { tui_msg "Missing" "Bash must be installed first."; return 1; }
    command -v git >/dev/null 2>&1 || pm_install git || return 1
    id "$u" >/dev/null 2>&1 || { tui_msg "Oh My Bash" "User '$u' does not exist."; return 1; }
    [ -d "$home_dir" ] || { tui_msg "Oh My Bash" "Home directory does not exist: $home_dir"; return 1; }

    [ -f "$rc" ] || : > "$rc"
    cp -p "$rc" "$backup" || return 1
    chown "$u":"$(id -gn "$u")" "$backup" 2>/dev/null || true

    if [ -d "$osh/.git" ]; then
        case "$mode" in
            repair)
                run_cmd "Repairing Oh My Bash" omb_git_as_user "$u" -C "$osh" reset --hard HEAD || return 1
                run_cmd "Cleaning Oh My Bash" omb_git_as_user "$u" -C "$osh" clean -fd || return 1
                run_cmd "Updating Oh My Bash" omb_git_as_user "$u" -C "$osh" pull --ff-only || return 1
                ;;
            *)
                # A failed refresh must not make a healthy existing install
                # unusable. Continue with the local checkout after reporting it.
                run_cmd "Updating Oh My Bash" omb_git_as_user "$u" -C "$osh" pull --ff-only || \
                    warn "Oh My Bash update failed or timed out; using existing checkout."
                ;;
        esac
    else
        if [ -e "$osh" ]; then
            mv -- "$osh" "$osh.pre-systui-$stamp" || return 1
        fi
        if ! run_cmd "Installing Oh My Bash for $u" omb_git_as_user "$u" clone --depth 1 --single-branch \
            https://github.com/ohmybash/oh-my-bash.git "$osh"; then
            [ -e "$osh" ] && rm -rf -- "$osh"
            [ -e "$osh.pre-systui-$stamp" ] && mv -- "$osh.pre-systui-$stamp" "$osh" 2>/dev/null || true
            tui_msg "Oh My Bash install failed" "GitHub clone failed or stopped responding. The previous installation, if any, was restored.\n\nSee $LOGFILE."
            return 1
        fi
    fi

    omb_write_systui_block "$rc" "$osh" || {
        cp -p "$backup" "$rc"
        return 1
    }
    chown "$u":"$(id -gn "$u")" "$rc" 2>/dev/null || true

    if omb_validate_install "$u" "$home_dir" "$osh"; then
        rm -f "${SYSTUI_TMP}/omb-check.$$"
        tui_msg "Installed" "Oh My Bash is configured for $u.\n\nStartup auto-update checks are disabled so Bash cannot block on GitHub. Use the OMB Update menu action for explicit updates.\n\nExisting config backup: $backup"
        return 0
    fi

    validation=$(tail -20 "${SYSTUI_TMP}/omb-check.$$" 2>/dev/null)
    rm -f "${SYSTUI_TMP}/omb-check.$$"
    cp -p "$backup" "$rc"
    chown "$u":"$(id -gn "$u")" "$rc" 2>/dev/null || true
    tui_msg "Validation failed" "The previous .bashrc was restored.\n\n${validation:-Oh My Bash validation failed or timed out.}"
    return 1
}

export -f omb_git_as_user omb_write_systui_block omb_validate_install omb_install_compatible
