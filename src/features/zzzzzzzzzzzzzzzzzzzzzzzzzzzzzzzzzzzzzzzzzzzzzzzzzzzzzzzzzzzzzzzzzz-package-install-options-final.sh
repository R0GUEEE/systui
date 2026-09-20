# shellcheck shell=bash
###############################################################################
# UNIVERSAL INSTALL SOURCE CHOOSER
#
# Final wrapper around pm_install.  Before any Systui path installs packages it
# offers every already-installed package/application manager that can plausibly
# install software on this host (native PM, Homebrew, Nix, Python, Node, Rust,
# Ruby, PHP/Composer, Go, Flatpak, plus a custom command).  Set
# SYSTUI_PM_OPTION_PROMPT=0 or SYSTUI_PM_OPTIONS_BYPASS=1 for non-interactive
# batch/test paths that need the historical direct native-PM behavior.
###############################################################################

systui_mgr_quote_words() { # args...
    local out='' x q
    for x in "$@"; do
        printf -v q '%q' "$x"
        out+="${out:+ }$q"
    done
    printf '%s' "$out"
}

systui_installed_install_managers() {
    local have_native=0
    case "${PM:-}" in apt|apk|pacman|dnf|yum|zypper|xbps|emerge) have_native=1 ;; esac
    [ "$have_native" -eq 1 ] && printf 'native|Native system package manager (%s)\n' "${PM:-unknown}"
    command -v brew >/dev/null 2>&1 && printf 'brew|Homebrew (brew install)\n'
    command -v nix >/dev/null 2>&1 && printf 'nix|Nix profile (nix profile install nixpkgs#...)\n'
    command -v snap >/dev/null 2>&1 && printf 'snap|Snap packages (snap install)\n'
    command -v yay >/dev/null 2>&1 && printf 'yay|Arch AUR/packages (yay -S)\n'
    command -v paru >/dev/null 2>&1 && printf 'paru|Arch AUR/packages (paru -S)\n'
    if command -v python3 >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
        printf 'pip|Python pip (python3 -m pip install)\n'
    elif command -v pip3 >/dev/null 2>&1; then
        printf 'pip|Python pip (pip3 install)\n'
    fi
    command -v pipx >/dev/null 2>&1 && printf 'pipx|Python pipx applications (pipx install)\n'
    command -v npm  >/dev/null 2>&1 && printf 'npm|Node npm globals (npm install -g)\n'
    command -v pnpm >/dev/null 2>&1 && printf 'pnpm|Node pnpm globals (pnpm add -g)\n'
    command -v yarn >/dev/null 2>&1 && printf 'yarn|Node yarn globals (yarn global add)\n'
    command -v cargo >/dev/null 2>&1 && printf 'cargo|Rust Cargo crates (cargo install)\n'
    command -v gem >/dev/null 2>&1 && printf 'gem|Ruby gems (gem install)\n'
    command -v composer >/dev/null 2>&1 && printf 'composer|PHP Composer globals (composer global require)\n'
    command -v go >/dev/null 2>&1 && printf 'go|Go tools (go install module@latest)\n'
    command -v flatpak >/dev/null 2>&1 && printf 'flatpak|Flatpak apps (flatpak install flathub)\n'
}

systui_install_with_manager() { # <manager> <packages...>
    local mgr="$1" words p
    shift
    [ "$#" -gt 0 ] || return 1
    words=$(systui_mgr_quote_words "$@")
    case "$mgr" in
        native)
            SYSTUI_PM_OPTIONS_BYPASS=1 _systui_pm_install_before_universal_options "$@" ;;
        brew)
            run_cmd "brew install $*" brew install --formula -- "$@" ;;
        nix)
            local -a refs=()
            for p in "$@"; do case "$p" in *#*) refs+=("$p") ;; *) refs+=("nixpkgs#$p") ;; esac; done
            run_cmd "nix profile install ${refs[*]}" nix profile install "${refs[@]}" ;;
        snap)
            run_cmd "snap install $*" snap install "$@" ;;
        yay)
            run_cmd "yay -S $*" yay -S --noconfirm --needed -- "$@" ;;
        paru)
            run_cmd "paru -S $*" paru -S --noconfirm --needed -- "$@" ;;
        pip)
            local -a pip_args=(install --upgrade)
            if command -v python3 >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
                if python3 -m pip install --help 2>&1 | grep -q -- '--break-system-packages'; then
                    pip_args+=(--break-system-packages)
                fi
                run_cmd "pip install $*" python3 -m pip "${pip_args[@]}" "$@"
            else
                run_cmd "pip3 install $*" pip3 install --upgrade "$@"
            fi ;;
        pipx)
            local rc=0
            for p in "$@"; do run_cmd "pipx install $p" pipx install "$p" || rc=1; done
            return "$rc" ;;
        npm)
            run_cmd "npm install -g $*" npm install -g -- "$@" ;;
        pnpm)
            run_cmd "pnpm add -g $*" pnpm add -g -- "$@" ;;
        yarn)
            run_cmd "yarn global add $*" yarn global add "$@" ;;
        cargo)
            run_cmd "cargo install $*" cargo install "$@" ;;
        gem)
            run_cmd "gem install $*" gem install "$@" ;;
        composer)
            run_cmd "composer global require $*" composer global require "$@" ;;
        go)
            local rc=0 ref
            for p in "$@"; do case "$p" in *@*) ref="$p" ;; *) ref="$p@latest" ;; esac; run_cmd "go install $ref" go install "$ref" || rc=1; done
            return "$rc" ;;
        flatpak)
            run_cmd "flatpak install $*" flatpak install -y flathub "$@" ;;
        custom)
            local cmd default
            default="# Replace package names if this manager uses different IDs. Requested: $words"
            cmd=$(tui_input "Custom install command" "Command to install: $words" "$default") || return 1
            [ -n "$cmd" ] || return 1
            case "$cmd" in \#*) return 1 ;; esac
            run_cmd "Custom install: $*" bash -c "$cmd" ;;
        *) return 1 ;;
    esac
}

systui_choose_install_manager() { # <context> <packages...>
    local context="$1" line tag label choice list_count=0
    shift
    local -a menu=()
    local _mgr_tmp="${SYSTUI_TMP:-/tmp}/systui-install-managers.$$"
    systui_installed_install_managers > "$_mgr_tmp" 2>/dev/null || : > "$_mgr_tmp"
    while IFS='|' read -r tag label; do
        [ -n "$tag" ] || continue
        menu+=("$tag" "$label")
        list_count=$((list_count + 1))
    done < "$_mgr_tmp"
    rm -f -- "$_mgr_tmp" 2>/dev/null || true
    menu+=(custom "Custom install command")
    menu+=(skip "Skip / cancel")

    # Automation hook used by tests and by callers that deliberately selected a
    # manager earlier in a workflow.
    if [ -n "${SYSTUI_INSTALL_MANAGER:-}" ]; then
        printf '%s\n' "$SYSTUI_INSTALL_MANAGER"
        return 0
    fi

    if [ "$list_count" -eq 1 ] && [ "${SYSTUI_PM_OPTION_PROMPT:-1}" = 0 ]; then
        printf 'native\n'
        return 0
    fi

    choice=$(tui_menu "Install packages" \
        "Install: $*\n\nChoose which installed package manager/source to use for ${context:-this request}. Package names may differ between ecosystems; use Custom if needed." \
        "${menu[@]}") || return 1
    [ "$choice" = skip ] && return 1
    [ -n "$choice" ] || return 1
    printf '%s\n' "$choice"
}

# Preserve whichever pm_install implementation all earlier recovery/Bedrock
# layers produced, then make this the final entrypoint.
if declare -F pm_install >/dev/null 2>&1 \
    && ! declare -F _systui_pm_install_before_universal_options >/dev/null 2>&1; then
    _systui_saved_fn=$(declare -f pm_install)
    _systui_saved_fn=${_systui_saved_fn/#pm_install /_systui_pm_install_before_universal_options }
    eval "$_systui_saved_fn"
    unset _systui_saved_fn
fi

pm_install() {
    validate_packages "$@" || return 1
    if [ "${SYSTUI_PM_OPTIONS_BYPASS:-0}" = 1 ] || [ "${SYSTUI_PM_OPTION_PROMPT:-1}" = 0 ]; then
        _systui_pm_install_before_universal_options "$@"
        return
    fi

    local mgr rc
    if [ "${SYSTUI_PM_FALLBACK_MANAGERS:-0}" = 1 ]; then
        # Bootstrap/recovery mode: try the distro's default repository first.
        # Only if it cannot provide the tool do we offer alternate installed
        # ecosystems (snap/pip/pipx/npm/pnpm/yarn/cargo/gem/composer/go/yay/
        # paru/nix/brew/flatpak/custom). This keeps normal bootstrap installs
        # fast and native, while still giving every installed manager a chance
        # before declaring the tool unavailable.
        if SYSTUI_PM_OPTIONS_BYPASS=1 _systui_pm_install_before_universal_options "$@"; then
            return 0
        fi
        rc=$?
        mgr=$(systui_choose_install_manager "fallback after ${PM:-native} could not install the requested package(s)" "$@") || return "$rc"
        [ "$mgr" = native ] && return "$rc"
        systui_install_with_manager "$mgr" "$@"
        return
    fi

    mgr=$(systui_choose_install_manager "package installation" "$@") || return 1
    systui_install_with_manager "$mgr" "$@"
}

return 0 2>/dev/null || true
