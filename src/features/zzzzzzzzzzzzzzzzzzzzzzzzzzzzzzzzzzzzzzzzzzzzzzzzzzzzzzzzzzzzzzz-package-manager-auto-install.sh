# shellcheck shell=bash
###############################################################################
# UNATTENDED PACKAGE MANAGER INSTALLATION
#
# Selecting managers in System Configuration > Packages > Managers > Install
# package managers installs them without any further prompt: every manager has
# an automatic strategy (native package, official unattended installer, npm
# global, cargo, official tarball or AUR helper) with fallbacks, and every
# helper runs with stdin closed so upstream installer scripts cannot block on a
# question. Individual menus that offer a choice of method remain available
# under "Configure individual package managers".
#
# Environment:
#   SYSTUI_PM_INSTALL_MODE=auto|menu   auto is the default
#   SYSTUI_PM_AUTO_<TAG>="command"     per-manager command override, e.g.
#                                      SYSTUI_PM_AUTO_BREW="brew update"
#   SYSTUI_PM_AUTO_STRICT=1            report a non-zero exit when any selected
#                                      manager could not be installed
###############################################################################

SYSTUI_PM_INSTALL_MODE=${SYSTUI_PM_INSTALL_MODE:-auto}

# Verification command for a catalogue tag (used for status and summaries).
sysconfig_pm_auto_command() { # <tag>
    case "$1" in
        aptfast) printf 'apt-fast\n' ;;
        nala) printf 'nala\n' ;;
        aptitude) printf 'aptitude\n' ;;
        flatpak) printf 'flatpak\n' ;;
        snap) printf 'snap\n' ;;
        pip) printf 'pip3\n' ;;
        pipx) printf 'pipx\n' ;;
        npm) printf 'npm\n' ;;
        pnpm) printf 'pnpm\n' ;;
        yarn) printf 'yarn\n' ;;
        cargo) printf 'cargo\n' ;;
        gem) printf 'gem\n' ;;
        composer) printf 'composer\n' ;;
        go) printf 'go\n' ;;
        yay) printf 'yay\n' ;;
        paru) printf 'paru\n' ;;
        nix) printf 'nix\n' ;;
        brew) printf 'brew\n' ;;
        *) return 1 ;;
    esac
}

sysconfig_pm_auto_present() { # <tag>
    local cmd
    cmd=$(sysconfig_pm_auto_command "$1" 2>/dev/null || true)
    [ -n "$cmd" ] || return 1
    command -v "$cmd" >/dev/null 2>&1
}

# Native install without the interactive manager chooser.
sysconfig_pm_auto_native() { # <packages...>
    [ "$#" -gt 0 ] || return 1
    SYSTUI_PM_OPTION_PROMPT=0 SYSTUI_PM_OPTIONS_BYPASS=1 \
        SYSTUI_PM_NO_WEB_FALLBACK=1 pm_install "$@"
}

# Download and run an upstream installer unattended (stdin closed).
sysconfig_pm_auto_remote_script() { # <description> <url> [installer args...]
    local desc="$1" url="$2"
    shift 2
    run_cmd "$desc" bash -c '
        set -e
        tmp=$(mktemp "${TMPDIR:-/tmp}/systui-installer.XXXXXX")
        trap "rm -f \"$tmp\"" EXIT
        curl --proto "=https" --tlsv1.2 -fsSL "$1" -o "$tmp"
        [ -s "$tmp" ] || { echo "download was empty" >&2; exit 1; }
        shift
        bash "$tmp" "$@" < /dev/null
    ' _ "$url" "$@"
}

# Build an AUR package without an interactive prompt. makepkg refuses to run as
# root, so the build happens as an unprivileged user when necessary.
sysconfig_pm_auto_makepkg() { # <name> <git-url> <verify-command>
    local name="$1" url="$2" verify="$3" work user cmd
    command -v makepkg >/dev/null 2>&1 || return 1
    work="${SYSTUI_TMP:-/tmp}/systui-aur-$name"
    rm -rf -- "$work"
    run_cmd "Fetch $name AUR source" git clone --depth 1 -- "$url" "$work" || return 1

    if [ "$(id -u)" -eq 0 ]; then
        user=aurbuild
        id "$user" >/dev/null 2>&1 || run_cmd "Create AUR build user" \
            useradd -m -s /bin/bash "$user" >/dev/null 2>&1 || true
        id "$user" >/dev/null 2>&1 || { rm -rf -- "$work"; return 1; }
        chown -R "$user" "$work" 2>/dev/null || true
        cmd="cd '$work' && makepkg -si --noconfirm --needed"
        if command -v runuser >/dev/null 2>&1; then
            run_cmd "Build $name as $user" runuser -u "$user" -- bash -c "$cmd" || { rm -rf -- "$work"; return 1; }
        elif command -v su >/dev/null 2>&1; then
            run_cmd "Build $name as $user" su -s /bin/bash "$user" -c "$cmd" || { rm -rf -- "$work"; return 1; }
        else
            rm -rf -- "$work"
            return 1
        fi
    else
        run_cmd "Build $name" bash -c "cd '$work' && makepkg -si --noconfirm --needed" || { rm -rf -- "$work"; return 1; }
    fi
    rm -rf -- "$work"
    command -v "$verify" >/dev/null 2>&1
}

# Install the newest release binary from a GitHub repository.
sysconfig_pm_auto_github_binary() { # <description> <owner/repo> <asset-pattern> <binary> <install-path>
    local desc="$1" repo="$2" pattern="$3" binary="$4" dest="$5"
    run_cmd "$desc" bash -c '
        set -e
        repo="$1"; pattern="$2"; binary="$3"; dest="$4"
        tag=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
            | sed -n "s/.*\"tag_name\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)
        [ -n "$tag" ] || { echo "could not resolve the latest release tag for $repo" >&2; exit 1; }
        arch=$(uname -m)
        case "$arch" in x86_64|amd64) arch=x86_64 ;; aarch64|arm64) arch=aarch64 ;;
                       armv7l|armv7) arch=armv7h ;; esac
        url="https://github.com/$repo/releases/download/${tag}/$(printf "%s" "$pattern" | sed "s/{tag}/${tag}/g; s/{tagv}/${tag#v}/g; s/{arch}/${arch}/g; s/{binary}/${binary}/g")"
        work=$(mktemp -d)
        trap "rm -rf \"$work\"" EXIT
        curl -fsSL "$url" -o "$work/asset" || { echo "download failed: $url" >&2; exit 1; }
        case "$work/asset" in
            *.tar.gz|*.tgz) tar -xzf "$work/asset" -C "$work" ;;
            *.tar.xz) tar -xJf "$work/asset" -C "$work" ;;
            *.tar.zst) tar --zstd -xf "$work/asset" -C "$work" 2>/dev/null || tar -xI zstd -f "$work/asset" -C "$work" ;;
            *.zip) unzip -q "$work/asset" -d "$work" ;;
            *) install -m 0755 "$work/asset" "$dest"; exit 0 ;;
        esac
        found=$(find "$work" -name "$binary" -type f | head -1)
        [ -n "$found" ] || { echo "$binary was not found in the archive" >&2; exit 1; }
        install -m 0755 "$found" "$dest"
    ' _ "$repo" "$pattern" "$binary" "$dest"
}

# --- per-manager automatic strategies ---------------------------------------

sysconfig_pm_auto_aptfast() {
    sysconfig_pm_auto_present aptfast && return 0
    [ "${PM:-}" = apt ] || { log "apt-fast requires APT"; return 1; }
    sysconfig_pm_auto_native apt-fast || true
    sysconfig_pm_auto_present aptfast && return 0
    sysconfig_pm_auto_native aria2 || true
    sysconfig_pm_auto_remote_script "Install apt-fast (quick-install)" \
        https://raw.githubusercontent.com/ilikenwf/apt-fast/master/quick-install.sh || true
    sysconfig_pm_auto_present aptfast
}

sysconfig_pm_auto_nala() {
    sysconfig_pm_auto_present nala && return 0
    [ "${PM:-}" = apt ] || { log "Nala requires APT"; return 1; }
    sysconfig_pm_auto_native nala || true
    sysconfig_pm_auto_present nala && return 0
    if command -v add-apt-repository >/dev/null 2>&1; then
        run_cmd "Add the Nala PPA" add-apt-repository -y ppa:volian/ppa || true
        sysconfig_pm_auto_native nala || true
    fi
    sysconfig_pm_auto_present nala
}

sysconfig_pm_auto_aptitude() {
    sysconfig_pm_auto_present aptitude && return 0
    sysconfig_pm_auto_native aptitude || true
    sysconfig_pm_auto_present aptitude
}

sysconfig_pm_auto_flatpak() {
    sysconfig_pm_auto_present flatpak && {
        run_cmd "Ensure the Flathub remote" flatpak remote-add --if-not-exists \
            flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
        return 0
    }
    sysconfig_pm_auto_native flatpak || true
    sysconfig_pm_auto_present flatpak || return 1
    run_cmd "Ensure the Flathub remote" flatpak remote-add --if-not-exists \
        flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
    return 0
}

sysconfig_pm_auto_snap() {
    sysconfig_pm_auto_native snapd || true
    sysconfig_pm_auto_present snap || return 1
    run_cmd "Enable the snapd service" bash -c \
        'systemctl enable --now snapd.socket snapd.service 2>/dev/null || true
         ln -sf /var/lib/snapd/snap /snap 2>/dev/null || true' || true
    return 0
}

sysconfig_pm_auto_pip() {
    sysconfig_pm_auto_present pip && return 0
    case "${PM:-}" in
        apk) sysconfig_pm_auto_native py3-pip ;;
        pacman) sysconfig_pm_auto_native python-pip ;;
        *) sysconfig_pm_auto_native python3-pip || sysconfig_pm_auto_native python-pip ;;
    esac || true
    sysconfig_pm_auto_present pip && return 0
    command -v python3 >/dev/null 2>&1 || { log "pip requires python3"; return 1; }
    run_cmd "Bootstrap pip (ensurepip)" python3 -m ensurepip --upgrade || true
    sysconfig_pm_auto_present pip && return 0
    run_cmd "Install pip (get-pip.py)" bash -c '
        set -e
        tmp=$(mktemp "${TMPDIR:-/tmp}/get-pip.XXXXXX.py")
        trap "rm -f \"$tmp\"" EXIT
        curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "$tmp"
        python3 "$tmp" --break-system-packages < /dev/null 2>/dev/null \
            || python3 "$tmp" < /dev/null' || true
    sysconfig_pm_auto_present pip
}

sysconfig_pm_auto_pipx() {
    sysconfig_pm_auto_present pipx && return 0
    case "${PM:-}" in
        pacman) sysconfig_pm_auto_native python-pipx ;;
        apk) sysconfig_pm_auto_native py3-pipx ;;
        *) sysconfig_pm_auto_native pipx ;;
    esac || true
    sysconfig_pm_auto_present pipx && return 0
    sysconfig_pm_auto_pip || true
    sysconfig_pm_auto_present pip || { log "pipx requires pip"; return 1; }
    run_cmd "Install pipx via pip" bash -c '
        set -e
        pip3 install --user pipx --break-system-packages 2>/dev/null \
            || pip3 install --user pipx' || true
    run_cmd "Register pipx on PATH" pipx ensurepath || true
    sysconfig_pm_auto_present pipx
}

sysconfig_pm_auto_npm() {
    sysconfig_pm_auto_present npm && return 0
    sysconfig_pm_auto_native nodejs npm || sysconfig_pm_auto_native nodejs-nodejs || true
    sysconfig_pm_auto_present npm && return 0
    case "${PM:-}" in
        apt)
            sysconfig_pm_auto_remote_script "Add the NodeSource LTS repository" \
                https://deb.nodesource.com/setup_lts.x || true
            sysconfig_pm_auto_native nodejs || true ;;
        dnf|yum)
            sysconfig_pm_auto_remote_script "Add the NodeSource LTS repository" \
                https://rpm.nodesource.com/setup_lts.x || true
            sysconfig_pm_auto_native nodejs || true ;;
    esac
    sysconfig_pm_auto_present npm
}

sysconfig_pm_auto_pnpm() {
    sysconfig_pm_auto_present pnpm && return 0
    if sysconfig_pm_auto_npm; then
        run_cmd "Install pnpm (npm global)" npm install -g pnpm || true
    fi
    sysconfig_pm_auto_present pnpm && return 0
    # Corepack ships with Node.js 16+ and needs no global npm write access.
    run_cmd "Enable pnpm through corepack" bash -c \
        'corepack enable --install-directory /usr/local/bin 2>/dev/null || corepack enable 2>/dev/null; 
         corepack prepare pnpm@latest --activate 2>/dev/null || true' || true
    sysconfig_pm_auto_present pnpm
}

sysconfig_pm_auto_yarn() {
    sysconfig_pm_auto_present yarn && return 0
    if sysconfig_pm_auto_npm; then
        run_cmd "Install Yarn (npm global)" npm install -g yarn || true
    fi
    sysconfig_pm_auto_present yarn && return 0
    run_cmd "Enable Yarn through corepack" bash -c \
        'corepack enable --install-directory /usr/local/bin 2>/dev/null || corepack enable 2>/dev/null;
         corepack prepare yarn@stable --activate 2>/dev/null || true' || true
    sysconfig_pm_auto_present yarn
}

sysconfig_pm_auto_cargo() {
    sysconfig_pm_auto_present cargo && return 0
    sysconfig_pm_auto_native cargo rustc || sysconfig_pm_auto_native rust || true
    sysconfig_pm_auto_present cargo && return 0
    sysconfig_pm_auto_remote_script "Install Rust (rustup, unattended)" \
        https://sh.rustup.rs -y --no-modify-path || true
    if ! sysconfig_pm_auto_present cargo; then
        [ -x "${CARGO_HOME:-$HOME/.cargo}/bin/cargo" ] && \
            ln -sf "${CARGO_HOME:-$HOME/.cargo}/bin/cargo" /usr/local/bin/cargo 2>/dev/null || true
    fi
    sysconfig_pm_auto_present cargo
}

sysconfig_pm_auto_gem() {
    sysconfig_pm_auto_present gem && return 0
    case "${PM:-}" in
        apk) sysconfig_pm_auto_native ruby ruby-dev ;;
        dnf|yum|zypper) sysconfig_pm_auto_native ruby ruby-devel ;;
        *) sysconfig_pm_auto_native ruby ruby-dev || sysconfig_pm_auto_native ruby ;;
    esac || true
    sysconfig_pm_auto_present gem
}

sysconfig_pm_auto_composer() {
    sysconfig_pm_auto_present composer && return 0
    sysconfig_pm_auto_native composer || true
    sysconfig_pm_auto_present composer && return 0
    command -v php >/dev/null 2>&1 || { log "Composer requires PHP"; return 1; }
    run_cmd "Install Composer (official installer)" bash -c '
        set -e
        tmp=$(mktemp "${TMPDIR:-/tmp}/composer.XXXXXX.php")
        trap "rm -f \"$tmp\"" EXIT
        php -r "copy(\"https://getcomposer.org/installer\", \"$tmp\");"
        expected=$(curl -fsSL https://composer.github.io/installer.sig)
        actual=$(php -r "echo hash_file(\"sha384\", \"$tmp\");")
        [ "$expected" = "$actual" ] || { echo "Composer installer signature mismatch" >&2; exit 1; }
        php "$tmp" --install-dir=/usr/local/bin --filename=composer --quiet < /dev/null' || true
    sysconfig_pm_auto_present composer
}

sysconfig_pm_auto_go() {
    sysconfig_pm_auto_present go && return 0
    case "${PM:-}" in
        apt) sysconfig_pm_auto_native golang-go ;;
        dnf|yum|zypper) sysconfig_pm_auto_native golang ;;
        *) sysconfig_pm_auto_native go ;;
    esac || true
    sysconfig_pm_auto_present go && return 0
    run_cmd "Install Go (official tarball)" bash -c '
        set -e
        case "$(uname -m)" in
            x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
            riscv64) arch=riscv64 ;; ppc64le) arch=ppc64le ;; s390x) arch=s390x ;; *) arch=386 ;;
        esac
        ver=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
        [ -n "$ver" ] || { echo "could not resolve the Go version" >&2; exit 1; }
        rm -rf /usr/local/go
        curl -fsSL "https://go.dev/dl/${ver}.linux-${arch}.tar.gz" | tar -xz -C /usr/local
        ln -sf /usr/local/go/bin/go /usr/local/bin/go
        ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt' || true
    sysconfig_pm_auto_present go
}

sysconfig_pm_auto_yay() {
    sysconfig_pm_auto_present yay && return 0
    command -v pacman >/dev/null 2>&1 || { log "yay requires Arch (pacman)"; return 1; }
    case "$(uname -m)" in
        x86_64|aarch64|arm64)
            sysconfig_pm_auto_github_binary "Install yay (release binary)" \
                Jguer/yay 'yay_{tagv}_{arch}.tar.gz' yay /usr/local/bin/yay || true ;;
    esac
    sysconfig_pm_auto_present yay && return 0
    sysconfig_pm_auto_native base-devel git || true
    sysconfig_pm_auto_makepkg yay https://aur.archlinux.org/yay.git yay
}

sysconfig_pm_auto_paru() {
    sysconfig_pm_auto_present paru && return 0
    command -v pacman >/dev/null 2>&1 || { log "paru requires Arch (pacman)"; return 1; }
    case "$(uname -m)" in
        x86_64|aarch64|arm64|armv7l|armv7)
            sysconfig_pm_auto_github_binary "Install paru (release binary)" \
                morganamilo/paru 'paru-{tag}-{arch}.tar.zst' paru /usr/local/bin/paru || true ;;
    esac
    sysconfig_pm_auto_present paru && return 0
    if sysconfig_pm_auto_cargo; then
        run_cmd "Install paru (cargo)" cargo install paru || true
    fi
    sysconfig_pm_auto_present paru && return 0
    sysconfig_pm_auto_native base-devel git || true
    sysconfig_pm_auto_makepkg paru https://aur.archlinux.org/paru.git paru
}

sysconfig_pm_auto_nix() {
    sysconfig_pm_auto_present nix && return 0
    # The official installers are unattended once stdin is closed; the
    # multi-user daemon install is preferred, single-user is the fallback.
    sysconfig_pm_auto_remote_script "Install Nix (multi-user, unattended)" \
        https://nixos.org/nix/install --daemon || true
    sysconfig_pm_auto_present nix && return 0
    sysconfig_pm_auto_remote_script "Install Nix (single-user, unattended)" \
        https://nixos.org/nix/install --no-daemon || true
    sysconfig_pm_auto_present nix && return 0
    if [ -e /nix/var/nix/profiles/default/bin/nix ]; then
        run_cmd "Link the Nix profile into PATH" bash -c \
            'ln -sf /nix/var/nix/profiles/default/bin/nix /usr/local/bin/nix' || true
    fi
    sysconfig_pm_auto_present nix && return 0
    sysconfig_pm_auto_native nix || true
    sysconfig_pm_auto_present nix
}

sysconfig_pm_auto_brew() {
    sysconfig_pm_auto_present brew && return 0
    local helper="${SYSTUI_LIBDIR:-}/share/homebrew/install-homebrew-root.sh"
    if [ -r "$helper" ]; then
        run_cmd "Install Homebrew (systui root-compatible installer)" \
            env NONINTERACTIVE=1 CI=1 bash "$helper" || true
    fi
    sysconfig_pm_auto_present brew && return 0
    # Fall back to the upstream installer with its non-interactive switch.
    run_cmd "Install Homebrew (upstream, non-interactive)" bash -c '
        set -e
        tmp=$(mktemp "${TMPDIR:-/tmp}/brew-install.XXXXXX.sh")
        trap "rm -f \"$tmp\"" EXIT
        curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$tmp"
        NONINTERACTIVE=1 CI=1 bash "$tmp" < /dev/null' || true
    if ! sysconfig_pm_auto_present brew; then
        for candidate in /home/linuxbrew/.linuxbrew/bin/brew /opt/homebrew/bin/brew /usr/local/bin/brew; do
            [ -x "$candidate" ] || continue
            run_cmd "Link Homebrew into PATH" ln -sf "$candidate" /usr/local/bin/brew || true
            break
        done
    fi
    sysconfig_pm_auto_present brew
}

# --- dispatcher --------------------------------------------------------------

sysconfig_pm_auto_custom() { # <tag> -> per-manager command override
    local name var
    name=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
    var="SYSTUI_PM_AUTO_${name}"
    printf '%s\n' "${!var-}"
}

# Install one catalogue manager without any prompt.
sysconfig_pm_auto_install() { # <tag>
    local tag="$1" fn custom
    sysconfig_pm_auto_present "$tag" && return 0
    custom=$(sysconfig_pm_auto_custom "$tag")
    if [ -n "$custom" ]; then
        run_cmd "Install $tag (custom command)" bash -c "$custom" || true
        sysconfig_pm_auto_present "$tag"
        return $?
    fi
    fn="sysconfig_pm_auto_${tag}"
    if declare -F "$fn" >/dev/null 2>&1; then
        "$fn"
        return $?
    fi
    log "systui: no automatic installer is defined for '$tag'"
    return 1
}

sysconfig_pm_auto_install_all() { # <tags...>
    local tag failed=0
    for tag in "$@"; do
        [ -n "$tag" ] || continue
        if sysconfig_pm_auto_present "$tag"; then
            log "systui: $tag is already installed"
            continue
        fi
        if sysconfig_pm_auto_install "$tag"; then
            log "systui: $tag installed without prompting"
        else
            log "systui: $tag could not be installed automatically"
            failed=$((failed + 1))
        fi
    done
    [ "$failed" -eq 0 ]
}

# One-line status report (no dialog, so nothing waits for input).
sysconfig_pm_auto_report() {
    local tag cmd label installed='' missing=''
    while IFS='|' read -r tag cmd label; do
        [ -n "$tag" ] || continue
        if command -v "$cmd" >/dev/null 2>&1; then
            installed="${installed}${installed:+, }$label"
        else
            missing="${missing}${missing:+, }$label"
        fi
    done <<< "$(sysconfig_pm_multi_catalogue)"
    log "systui: package managers available: ${installed:-none}"
    log "systui: package managers not installed: ${missing:-none}"
}

# --- integrate with the existing installation tool ---------------------------
#
# The catalogue tool asks which managers to install, then delegates each
# non-native manager to sysconfig_pm_multi_special_installer. Pointing that at
# the automatic installers removes every follow-up prompt while keeping the
# per-manager method menus available from "Configure individual package
# managers" (SYSTUI_PM_INSTALL_MODE=menu).
if declare -F sysconfig_pm_multi_special_installer >/dev/null 2>&1 \
    && ! declare -F _systui_pm_special_before_auto >/dev/null 2>&1; then
    _systui_pm_saved_fn=$(declare -f sysconfig_pm_multi_special_installer)
    _systui_pm_saved_fn=${_systui_pm_saved_fn/#sysconfig_pm_multi_special_installer /_systui_pm_special_before_auto }
    eval "$_systui_pm_saved_fn"
    unset _systui_pm_saved_fn
fi

sysconfig_pm_multi_special_installer() { # <tag>
    local tag="$1" fn
    if [ "${SYSTUI_PM_INSTALL_MODE:-auto}" = menu ]; then
        _systui_pm_special_before_auto "$tag"
        return $?
    fi
    fn="sysconfig_pm_auto_${tag}"
    declare -F "$fn" >/dev/null 2>&1 || { _systui_pm_special_before_auto "$tag"; return $?; }
    printf '%s\n' "$fn"
}

# Wrap the (possibly Bedrock-aware) multi-install entry point so the native
# package batches never interrupt with a manager chooser and the run ends with
# a log report instead of a modal dialog.
if declare -F sysconfig_pm_multi_install >/dev/null 2>&1 \
    && ! declare -F _systui_pm_multi_before_auto >/dev/null 2>&1; then
    _systui_pm_saved_fn=$(declare -f sysconfig_pm_multi_install)
    _systui_pm_saved_fn=${_systui_pm_saved_fn/#sysconfig_pm_multi_install /_systui_pm_multi_before_auto }
    eval "$_systui_pm_saved_fn"
    unset _systui_pm_saved_fn
fi

sysconfig_pm_multi_install() {
    local rc=0
    if [ "${SYSTUI_PM_INSTALL_MODE:-auto}" = menu ]; then
        _systui_pm_multi_before_auto "$@"
        return $?
    fi
    SYSTUI_PM_OPTION_PROMPT=0 SYSTUI_PM_OPTIONS_BYPASS=1 \
        _systui_pm_multi_before_auto "$@" || rc=$?
    sysconfig_pm_auto_report
    if [ "$rc" -ne 0 ] && [ "${SYSTUI_PM_AUTO_STRICT:-0}" = 1 ]; then
        return "$rc"
    fi
    return 0
}

# A single unattended entry point for scripts: install every catalogue manager
# that is not present yet.
sysconfig_pm_install_all_automatically() {
    local -a tags=()
    local tag cmd label
    while IFS='|' read -r tag cmd label; do
        [ -n "$tag" ] || continue
        sysconfig_pm_auto_present "$tag" || tags+=("$tag")
    done <<< "$(sysconfig_pm_multi_catalogue)"
    [ "${#tags[@]}" -gt 0 ] || { log "systui: every catalogue package manager is already installed"; return 0; }
    log "systui: installing ${#tags[@]} package manager(s) without prompting: ${tags[*]}"
    sysconfig_pm_auto_install_all "${tags[@]}"
}

return 0 2>/dev/null || true
