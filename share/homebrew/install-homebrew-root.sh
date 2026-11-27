#!/usr/bin/env bash
# systui Homebrew installer for Linux.
#
# Homebrew refuses to run as root because formula/build scripts are not a safe
# root execution boundary. This installer may itself be launched as root, but
# the actual Homebrew checkout and every brew command run as a dedicated
# unprivileged `linuxbrew` account.
#
# Installed formulae are wired onto the default PATH as well: their links are
# mirrored into /usr/local/bin and /usr/local/sbin by systui-brew-path, and the
# root wrapper re-runs that mirror after every mutating brew command, so a
# formula becomes runnable in the shell that installed it.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly BREW_USER="${SYSTUI_BREW_USER:-linuxbrew}"
readonly BREW_HOME="${SYSTUI_BREW_HOME:-/home/linuxbrew}"
readonly BREW_PREFIX="${SYSTUI_BREW_PREFIX:-/home/linuxbrew/.linuxbrew}"
readonly BREW_REPOSITORY="$BREW_PREFIX/Homebrew"
readonly REAL_BREW="$BREW_REPOSITORY/bin/brew"
readonly BREW_LINK="$BREW_PREFIX/bin/brew"
readonly ROOT_WRAPPER="/usr/local/bin/brew"
readonly ROOT_ENV_DIR="/etc/systui"
readonly ROOT_ENV_FILE="${ROOT_ENV_DIR}/homebrew.env"
readonly PROFILE_FILE="/etc/profile.d/homebrew.sh"
readonly PATH_HELPER="/usr/local/bin/systui-brew-path"
readonly PATH_HELPER_SOURCE="${SCRIPT_DIR}/systui-brew-path.sh"
readonly HOOK_BEGIN="# >>> systui homebrew >>>"
readonly HOOK_END="# <<< systui homebrew <<<"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this installer as root."
[[ $(uname -s) == Linux ]] || die "This installer only supports Linux."

case "$(uname -m)" in
    x86_64|aarch64|arm64) ;;
    *) die "Homebrew on Linux supports x86_64 and aarch64; found $(uname -m)." ;;
esac

run_as_brew_user() {
    local workdir="$PWD"
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$BREW_USER" -- test -x "$workdir" >/dev/null 2>&1 || workdir="$BREW_HOME"
        runuser -u "$BREW_USER" -- env HOME="$BREW_HOME" USER="$BREW_USER" LOGNAME="$BREW_USER" \
            bash -c 'cd "$1" && shift && exec "$@"' bash "$workdir" "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -H -u "$BREW_USER" test -x "$workdir" >/dev/null 2>&1 || workdir="$BREW_HOME"
        sudo -H -u "$BREW_USER" env HOME="$BREW_HOME" USER="$BREW_USER" LOGNAME="$BREW_USER" \
            bash -c 'cd "$1" && shift && exec "$@"' bash "$workdir" "$@"
    elif command -v su >/dev/null 2>&1; then
        local quoted=() arg
        if ! su -s /bin/bash "$BREW_USER" -c "test -x $(printf %q "$workdir")" >/dev/null 2>&1; then workdir="$BREW_HOME"; fi
        for arg in "$@"; do printf -v arg '%q' "$arg"; quoted+=("$arg"); done
        su -s /bin/bash "$BREW_USER" -c "cd $(printf %q "$workdir") && HOME=$(printf %q "$BREW_HOME") USER=$(printf %q "$BREW_USER") LOGNAME=$(printf %q "$BREW_USER") ${quoted[*]}"
    else
        die "Need runuser, sudo, or su to execute Homebrew without root privileges."
    fi
}

install_deps() {
    log "Installing Homebrew prerequisites"
    # The distribution's own manager must win over whatever is on PATH: on
    # Alpine an installed 'apt' package would otherwise pull Debian packages
    # into a musl root. (install.sh and update.sh decide this the same way.)
    if [[ -f /etc/alpine-release ]] && command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash build-base curl file git python3 ruby patch perl tar gzip bzip2 xz unzip ca-certificates diffutils
    elif command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends bash build-essential ca-certificates curl file git procps gcc g++ make libc6-dev patch perl python3 ruby tar gzip bzip2 xz-utils unzip diffutils
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y bash gcc gcc-c++ make curl file git procps-ng patch perl python3 ruby tar gzip bzip2 xz unzip ca-certificates diffutils
    elif command -v yum >/dev/null 2>&1; then
        yum install -y bash gcc gcc-c++ make curl file git procps-ng patch perl python3 ruby tar gzip bzip2 xz unzip ca-certificates diffutils
    elif command -v pacman >/dev/null 2>&1; then
        # Arch does not support partial upgrades. Make the system-wide impact
        # explicit before pacman performs its required synchronized upgrade.
        warn "Arch Linux detected: a full 'pacman -Syu' may be needed before installing prereleases."
        if [[ "${SYSTUI_ALLOW_FULL_UPGRADE:-0}" != 1 ]]; then
            die "Refusing to upgrade the whole system. Run 'pacman -Syu' yourself, or set SYSTUI_ALLOW_FULL_UPGRADE=1."
        fi
        pacman -Syu --noconfirm --needed base-devel curl file git python ruby ca-certificates diffutils
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive refresh
        zypper --non-interactive install bash gcc gcc-c++ make curl file git procps patch perl python3 ruby tar gzip bzip2 xz unzip ca-certificates diffutils
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash build-base curl file git python3 ruby patch perl tar gzip bzip2 xz unzip ca-certificates diffutils
    else
        die "No supported package manager found for Homebrew prerequisites."
    fi
}

ensure_user() {
    log "Preparing unprivileged Homebrew account: $BREW_USER"
    if ! id -u "$BREW_USER" >/dev/null 2>&1; then
        command -v useradd >/dev/null 2>&1 || die "useradd is required to create $BREW_USER."
        # -U makes useradd create the same-named group the rest of this script
        # assumes; without it (USERGROUPS_ENAB=no) the later chown/chgrp fail
        # after the account and prerequisites have already been created.
        useradd -m -U -d "$BREW_HOME" -s /bin/bash -c "Homebrew package manager" "$BREW_USER"
    fi
    install -d -m 0755 -o "$BREW_USER" -g "$BREW_USER" "$BREW_HOME" "$BREW_PREFIX"
    chown -R "$BREW_USER:$BREW_USER" "$BREW_PREFIX"
}

ensure_env_file() {
    log "Preparing root-owned Homebrew settings"
    install -d -m 0755 -o root -g root "$ROOT_ENV_DIR"
    if [[ ! -e "$ROOT_ENV_FILE" ]]; then
        cat > "$ROOT_ENV_FILE" <<'EOF_ENV'
# systui-managed Homebrew behavior settings.
# Only HOMEBREW_* variables belong here; Homebrew itself still runs unprivileged.
HOMEBREW_NO_ANALYTICS=1
HOMEBREW_NO_ENV_HINTS=1
EOF_ENV
    fi
    chown root:root "$ROOT_ENV_FILE"
    chmod 0644 "$ROOT_ENV_FILE"
}

install_brew() {
    if [[ -d "$BREW_REPOSITORY" && ! -x "$REAL_BREW" ]]; then
        log "Removing incomplete Homebrew checkout"
        rm -rf -- "$BREW_REPOSITORY"
    fi
    if [[ ! -x "$REAL_BREW" ]]; then
        log "Cloning Homebrew as $BREW_USER"
        run_as_brew_user git -c http.version=HTTP/1.1 clone --depth=1 --single-branch --branch=main --no-tags https://github.com/Homebrew/brew.git "$BREW_REPOSITORY"
    else
        log "Existing Homebrew checkout found"
    fi
    run_as_brew_user mkdir -p "$BREW_PREFIX/bin" "$BREW_PREFIX/sbin" "$BREW_PREFIX/Cellar" "$BREW_PREFIX/Caskroom" "$BREW_PREFIX/opt" "$BREW_PREFIX/var/homebrew"
    ln -sfn "$REAL_BREW" "$BREW_LINK"
    chown -h "$BREW_USER:$BREW_USER" "$BREW_LINK"
}

# Replaces a marked block in a shell startup file without disturbing anything
# else in it, and without rewriting the file when the block is already correct.
write_hook_block() { # <file>
    local file="$1" tmp perms=""
    [[ -f "$file" ]] || return 0
    tmp="$(mktemp "$(dirname "$file")/.systui-homebrew.XXXXXX")" || { warn "cannot write next to $file"; return 0; }
    awk -v b="$HOOK_BEGIN" -v e="$HOOK_END" '
        $0 == b { skip = 1; next }
        skip && $0 == e { skip = 0; next }
        !skip { print }
    ' "$file" > "$tmp"
    {
        printf '%s\n' "$HOOK_BEGIN"
        printf '[ -r %s ] && . %s\n' "$PROFILE_FILE" "$PROFILE_FILE"
        printf '%s\n' "$HOOK_END"
    } >> "$tmp"
    if cmp -s "$tmp" "$file"; then
        rm -f -- "$tmp"
        return 0
    fi
    perms=$(stat -c '%a' "$file" 2>/dev/null || true)
    chmod "${perms:-0644}" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
    mv -f -- "$tmp" "$file"
}

install_path_integration() {
    log "Wiring installed formulae onto PATH"
    if [[ -r "$PATH_HELPER_SOURCE" ]]; then
        install -m 0755 -o root -g root "$PATH_HELPER_SOURCE" "$PATH_HELPER"
    else
        warn "PATH helper $PATH_HELPER_SOURCE is missing; only shell profiles will be updated."
    fi

    cat > "$PROFILE_FILE" <<EOF_PROFILE
# systui-managed Homebrew environment.
# Sourced from /etc/profile.d and again from the marked block in the shell rc
# files, so the guard keeps a nested login shell from stacking the prefix.
if [ -z "\${SYSTUI_HOMEBREW_ENV:-}" ]; then
    SYSTUI_HOMEBREW_ENV=1
    export SYSTUI_HOMEBREW_ENV
    export HOMEBREW_PREFIX="$BREW_PREFIX"
    export HOMEBREW_CELLAR="$BREW_PREFIX/Cellar"
    export HOMEBREW_REPOSITORY="$BREW_REPOSITORY"
    case ":\$PATH:" in
        *":$BREW_PREFIX/bin:"*) ;;
        *) PATH="/usr/local/bin:$BREW_PREFIX/bin:$BREW_PREFIX/sbin:\$PATH" ;;
    esac
    export PATH
    MANPATH="$BREW_PREFIX/share/man\${MANPATH+:\$MANPATH}"
    INFOPATH="$BREW_PREFIX/share/info\${INFOPATH+:\$INFOPATH}"
    export MANPATH INFOPATH
    # Formula executables are also mirrored into /usr/local/bin by
    # systui-brew-path, which keeps them reachable in shells that never read
    # this file (non-login shells, running sessions, root cron jobs).
fi
EOF_PROFILE
    chmod 0644 "$PROFILE_FILE"

    # Login shells read /etc/profile.d; interactive non-login shells (the ones
    # a TUI spawns, and `bash -c`) read their own rc files instead.
    write_hook_block /etc/profile
    write_hook_block /etc/bash.bashrc
    write_hook_block /etc/bash/bashrc
    write_hook_block /etc/bashrc
    write_hook_block /etc/zsh/zshrc
    write_hook_block /etc/zshrc

    if [[ -d /etc/fish ]]; then
        install -d -m 0755 /etc/fish/conf.d
        cat > /etc/fish/conf.d/systui-homebrew.fish <<EOF_FISH
# systui-managed Homebrew environment.
set -gx HOMEBREW_PREFIX "$BREW_PREFIX"
set -gx HOMEBREW_CELLAR "$BREW_PREFIX/Cellar"
set -gx HOMEBREW_REPOSITORY "$BREW_REPOSITORY"
set -gx MANPATH "$BREW_PREFIX/share/man" \$MANPATH
set -gx INFOPATH "$BREW_PREFIX/share/info" \$INFOPATH
fish_add_path --global --move-to-front /usr/local/bin "$BREW_PREFIX/bin" "$BREW_PREFIX/sbin"
EOF_FISH
        chmod 0644 /etc/fish/conf.d/systui-homebrew.fish
    fi

    if [[ -x "$PATH_HELPER" ]]; then
        "$PATH_HELPER" --quiet || warn "Initial PATH mirror pass reported a problem."
    fi
}

install_wrapper() {
    log "Installing root-safe brew wrapper"
    cat > "$ROOT_WRAPPER" <<EOF_WRAPPER
#!/usr/bin/env bash
set -euo pipefail
BREW_USER=$(printf %q "$BREW_USER")
BREW_HOME=$(printf %q "$BREW_HOME")
REAL_BREW=$(printf %q "$REAL_BREW")
ROOT_ENV_FILE=$(printf %q "$ROOT_ENV_FILE")
PATH_HELPER=$(printf %q "$PATH_HELPER")
if [ -r "\$ROOT_ENV_FILE" ]; then
    while IFS='=' read -r key value; do
        case "\$key" in HOMEBREW_[A-Z0-9_]*) export "\$key=\$value" ;; esac
    done < "\$ROOT_ENV_FILE"
fi
AS_ROOT=0
BREW_RUN=("\$REAL_BREW")
if [ "\$(id -u)" -eq 0 ]; then
    AS_ROOT=1
    BREW_CWD="\$PWD"
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "\$BREW_USER" -- test -x "\$BREW_CWD" >/dev/null 2>&1 || BREW_CWD="\$BREW_HOME"
        BREW_RUN=(runuser -u "\$BREW_USER" -- env HOME="\$BREW_HOME" USER="\$BREW_USER" LOGNAME="\$BREW_USER" bash -c 'cd "\$1" && shift && exec "\$@"' bash "\$BREW_CWD" "\$REAL_BREW")
    elif command -v sudo >/dev/null 2>&1; then
        sudo -H -u "\$BREW_USER" test -x "\$BREW_CWD" >/dev/null 2>&1 || BREW_CWD="\$BREW_HOME"
        BREW_RUN=(sudo -H -u "\$BREW_USER" env HOME="\$BREW_HOME" USER="\$BREW_USER" LOGNAME="\$BREW_USER" bash -c 'cd "\$1" && shift && exec "\$@"' bash "\$BREW_CWD" "\$REAL_BREW")
    else
        echo "brew: root invocation requires runuser or sudo to drop privileges" >&2
        exit 1
    fi
fi
status=0
"\${BREW_RUN[@]}" "\$@" || status=\$?
# Anything that changes what is installed also changes what belongs on PATH.
# Re-mirror before returning so the command the user just installed runs in
# the very shell that installed it, with no re-login and no PATH edit.
case "\${1:-}" in
    install|uninstall|remove|upgrade|reinstall|link|unlink|pin|unpin|tap|untap|cleanup|update)
        if [ -x "\$PATH_HELPER" ]; then
            if [ "\$AS_ROOT" -eq 1 ]; then
                "\$PATH_HELPER" --quiet || true
            elif command -v sudo >/dev/null 2>&1; then
                sudo -n "\$PATH_HELPER" --quiet || true
            fi
        fi
        ;;
esac
exit \$status
EOF_WRAPPER
    chmod 0755 "$ROOT_WRAPPER"
}

install_deps
ensure_user
ensure_env_file
install_brew
install_wrapper
install_path_integration

log "Verifying Homebrew through the privilege-dropping wrapper"
( cd "$BREW_HOME"; "$ROOT_WRAPPER" --version )

cat <<EOF_DONE

Homebrew installation completed.

The brew command may be invoked from a root shell, but systui will always
execute Homebrew itself as the unprivileged '$BREW_USER' account.

Installed formulae are mirrored into /usr/local/bin and /usr/local/sbin, so
they are on PATH for root and every user the moment they are installed --
no re-login, no shell profile edit. Run 'systui-brew-path --status' to see
the mirrors, or 'systui-brew-path --remove' to drop them.

  source $PROFILE_FILE
  brew --version
  brew install <formula>
EOF_DONE
