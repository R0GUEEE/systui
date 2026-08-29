#!/usr/bin/env bash
# systui Homebrew installer for Linux.
#
# Homebrew refuses to run as root because formula/build scripts are not a safe
# root execution boundary. This installer may itself be launched as root, but
# the actual Homebrew checkout and every brew command run as a dedicated
# unprivileged `linuxbrew` account.

set -Eeuo pipefail

readonly BREW_USER="${SYSTUI_BREW_USER:-linuxbrew}"
readonly BREW_HOME="${SYSTUI_BREW_HOME:-/home/linuxbrew}"
readonly BREW_PREFIX="${SYSTUI_BREW_PREFIX:-$BREW_HOME/.linuxbrew}"
readonly BREW_REPOSITORY="$BREW_PREFIX/Homebrew"
readonly REAL_BREW="$BREW_REPOSITORY/bin/brew"
readonly BREW_LINK="$BREW_PREFIX/bin/brew"
readonly ROOT_WRAPPER="/usr/local/bin/brew"
readonly PROFILE_FILE="/etc/profile.d/homebrew.sh"

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
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$BREW_USER" -- env HOME="$BREW_HOME" USER="$BREW_USER" LOGNAME="$BREW_USER" "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -H -u "$BREW_USER" env HOME="$BREW_HOME" USER="$BREW_USER" LOGNAME="$BREW_USER" "$@"
    elif command -v su >/dev/null 2>&1; then
        local quoted=() arg
        for arg in "$@"; do printf -v arg '%q' "$arg"; quoted+=("$arg"); done
        su -s /bin/bash "$BREW_USER" -c "HOME=$(printf %q "$BREW_HOME") USER=$(printf %q "$BREW_USER") LOGNAME=$(printf %q "$BREW_USER") ${quoted[*]}"
    else
        die "Need runuser, sudo, or su to execute Homebrew without root privileges."
    fi
}

install_deps() {
    log "Installing Homebrew prerequisites"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends bash build-essential ca-certificates curl file git procps gcc g++ make libc6-dev patch perl python3 ruby tar gzip bzip2 xz-utils unzip
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y bash gcc gcc-c++ make curl file git procps-ng patch perl python3 ruby tar gzip bzip2 xz unzip ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y bash gcc gcc-c++ make curl file git procps-ng patch perl python3 ruby tar gzip bzip2 xz unzip ca-certificates
    elif command -v pacman >/dev/null 2>&1; then
        # Arch does not support partial upgrades: refresh and upgrade together.
        pacman -Syu --noconfirm --needed base-devel curl file git python ruby ca-certificates
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive refresh
        zypper --non-interactive install bash gcc gcc-c++ make curl file git procps patch perl python3 ruby tar gzip bzip2 xz unzip ca-certificates
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash build-base curl file git python3 ruby patch perl tar gzip bzip2 xz unzip ca-certificates
    else
        die "No supported package manager found for Homebrew prerequisites."
    fi
}

ensure_user() {
    log "Preparing unprivileged Homebrew account: $BREW_USER"
    if ! id -u "$BREW_USER" >/dev/null 2>&1; then
        command -v useradd >/dev/null 2>&1 || die "useradd is required to create $BREW_USER."
        useradd -m -d "$BREW_HOME" -s /bin/bash -c "Homebrew package manager" "$BREW_USER"
    fi
    install -d -m 0755 -o "$BREW_USER" -g "$BREW_USER" "$BREW_HOME" "$BREW_PREFIX"
    chown -R "$BREW_USER:$BREW_USER" "$BREW_PREFIX"
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

install_wrapper() {
    log "Installing root-safe brew wrapper"
    cat > "$ROOT_WRAPPER" <<EOF_WRAPPER
#!/usr/bin/env bash
set -euo pipefail
BREW_USER=$(printf %q "$BREW_USER")
BREW_HOME=$(printf %q "$BREW_HOME")
REAL_BREW=$(printf %q "$REAL_BREW")
if [ "\$(id -u)" -eq 0 ]; then
    if command -v runuser >/dev/null 2>&1; then
        exec runuser -u "\$BREW_USER" -- env HOME="\$BREW_HOME" USER="\$BREW_USER" LOGNAME="\$BREW_USER" "\$REAL_BREW" "\$@"
    elif command -v sudo >/dev/null 2>&1; then
        exec sudo -H -u "\$BREW_USER" env HOME="\$BREW_HOME" USER="\$BREW_USER" LOGNAME="\$BREW_USER" "\$REAL_BREW" "\$@"
    else
        echo "brew: root invocation requires runuser or sudo to drop privileges" >&2
        exit 1
    fi
fi
exec "\$REAL_BREW" "\$@"
EOF_WRAPPER
    chmod 0755 "$ROOT_WRAPPER"

    cat > "$PROFILE_FILE" <<EOF_PROFILE
export HOMEBREW_PREFIX="$BREW_PREFIX"
export HOMEBREW_CELLAR="$BREW_PREFIX/Cellar"
export HOMEBREW_REPOSITORY="$BREW_REPOSITORY"
export PATH="/usr/local/bin:$BREW_PREFIX/bin:$BREW_PREFIX/sbin:\$PATH"
export MANPATH="$BREW_PREFIX/share/man\${MANPATH+:\$MANPATH}"
export INFOPATH="$BREW_PREFIX/share/info\${INFOPATH+:\$INFOPATH}"
EOF_PROFILE
    chmod 0644 "$PROFILE_FILE"
}

install_deps
ensure_user
install_brew
install_wrapper

log "Verifying Homebrew through the privilege-dropping wrapper"
"$ROOT_WRAPPER" --version

cat <<EOF_DONE

Homebrew installation completed.

The `brew` command may be invoked from a root shell, but systui will always
execute Homebrew itself as the unprivileged '$BREW_USER' account.

  source $PROFILE_FILE
  brew --version
  brew install <formula>
EOF_DONE
