#!/usr/bin/env bash
# Root-managed Homebrew installer — any Linux, any architecture.
#
# WARNING: Homebrew does not officially support operation as root. This script
# installs a small LD_PRELOAD compatibility shim so Homebrew and its subprocesses
# observe a non-root UID while retaining the root process's real filesystem access.

set -Eeuo pipefail

readonly BREW_PREFIX="/home/linuxbrew/.linuxbrew"
readonly BREW_REPOSITORY="${BREW_PREFIX}/Homebrew"
readonly REAL_BREW="${BREW_REPOSITORY}/bin/brew"
readonly BREW_LINK="${BREW_PREFIX}/bin/brew"
readonly ROOT_WRAPPER="/usr/local/bin/brew"
readonly SHIM_DIR="/usr/local/lib/homebrew-root"
readonly SHIM_SOURCE="${SHIM_DIR}/fakeuid.c"
readonly SHIM_LIBRARY="${SHIM_DIR}/libhomebrew_fakeuid.so"
readonly ROOT_ENV_DIR="/etc/systui"
readonly ROOT_ENV_FILE="${ROOT_ENV_DIR}/homebrew.env"
readonly PROFILE_FILE="/etc/profile.d/homebrew.sh"
readonly FAKE_UID="1000"
readonly FAKE_GID="1000"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this installer as root."
[[ $(uname -s) == Linux ]] || die "This installer only supports Linux."

# Homebrew officially supports Linux on x86_64 and aarch64 only; there are no
# riscv64 (or 32-bit) bottles or a riscv64 brew build, so refuse early with a
# clear message instead of letting the clone/install fail halfway.
case "$(uname -m)" in
    x86_64|aarch64|arm64) ;;
    *)
        die "Homebrew does not support $(uname -m) Linux. Supported Linux architectures: x86_64, aarch64."
        ;;
esac

log "Detected: $(uname -m) / $(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}" || printf unknown)"

# ---- Install build dependencies using whatever PM is available ---------------
_install_brew_deps() {
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends \
            bash build-essential ca-certificates curl file git procps \
            gcc g++ make libc6-dev patch perl python3 ruby \
            tar gzip bzip2 xz-utils unzip
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y \
            bash gcc gcc-c++ make curl file git procps-ng \
            patch perl python3 ruby tar gzip bzip2 xz unzip ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y \
            bash gcc gcc-c++ make curl file git procps-ng \
            patch perl python3 ruby tar gzip bzip2 xz unzip ca-certificates
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm --needed \
            base-devel curl file git python ruby ca-certificates
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install \
            bash gcc gcc-c++ make curl file git procps \
            patch perl python3 ruby tar gzip bzip2 xz unzip ca-certificates
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache \
            bash gcc g++ make curl file git python3 ruby \
            patch perl tar gzip bzip2 xz unzip ca-certificates
    else
        warn "No recognised package manager found — build dependencies may be missing."
    fi
}

log "Installing build dependencies"
_install_brew_deps

log "Creating linuxbrew user and home directory"
if ! id -u linuxbrew >/dev/null 2>&1; then
  useradd -r -m -d /home/linuxbrew -s /bin/bash -c "Homebrew package manager" linuxbrew 2>/dev/null || true
fi
install -d -m 0755 -o linuxbrew -g linuxbrew /home/linuxbrew
chmod 0755 /home/linuxbrew

log "Preparing root-owned Homebrew prefix"
install -d -m 0755 -o root -g root "$BREW_PREFIX"

if [[ -d "$BREW_REPOSITORY" && ! -x "$REAL_BREW" ]]; then
  log "Removing incomplete Homebrew checkout"
  rm -rf "$BREW_REPOSITORY"
fi

if [[ ! -x "$REAL_BREW" ]]; then
  log "Cloning a lightweight Homebrew checkout"
  git \
    -c http.version=HTTP/1.1 \
    -c http.maxRequests=1 \
    -c core.compression=0 \
    clone \
    --depth=1 \
    --single-branch \
    --branch=main \
    --no-tags \
    https://github.com/Homebrew/brew.git \
    "$BREW_REPOSITORY"
else
  log "Existing Homebrew checkout found"
fi

log "Creating Homebrew directory layout"
install -d -m 0755 -o root -g root \
  "$BREW_PREFIX/bin" \
  "$BREW_PREFIX/sbin" \
  "$BREW_PREFIX/etc" \
  "$BREW_PREFIX/include" \
  "$BREW_PREFIX/lib" \
  "$BREW_PREFIX/opt" \
  "$BREW_PREFIX/share" \
  "$BREW_PREFIX/share/man" \
  "$BREW_PREFIX/share/info" \
  "$BREW_PREFIX/var" \
  "$BREW_PREFIX/var/homebrew" \
  "$BREW_PREFIX/var/homebrew/linked" \
  "$BREW_PREFIX/Cellar" \
  "$BREW_PREFIX/Caskroom" \
  "$BREW_PREFIX/Frameworks"

ln -sfn "$REAL_BREW" "$BREW_LINK"
chown -h root:root "$BREW_LINK"
chown -R root:root /home/linuxbrew

log "Building Homebrew root-compatibility UID shim"
install -d -m 0755 -o root -g root "$SHIM_DIR"
cat > "$SHIM_SOURCE" <<EOF_C
#define _GNU_SOURCE
#include <sys/types.h>
#include <unistd.h>

uid_t getuid(void)  { return (uid_t)${FAKE_UID}; }
uid_t geteuid(void) { return (uid_t)${FAKE_UID}; }
gid_t getgid(void)  { return (gid_t)${FAKE_GID}; }
gid_t getegid(void) { return (gid_t)${FAKE_GID}; }

int getresuid(uid_t *ruid, uid_t *euid, uid_t *suid) {
    if (ruid) *ruid = (uid_t)${FAKE_UID};
    if (euid) *euid = (uid_t)${FAKE_UID};
    if (suid) *suid = (uid_t)${FAKE_UID};
    return 0;
}

int getresgid(gid_t *rgid, gid_t *egid, gid_t *sgid) {
    if (rgid) *rgid = (gid_t)${FAKE_GID};
    if (egid) *egid = (gid_t)${FAKE_GID};
    if (sgid) *sgid = (gid_t)${FAKE_GID};
    return 0;
}
EOF_C

gcc -shared -fPIC -O2 -Wall -Wextra \
  -o "$SHIM_LIBRARY" "$SHIM_SOURCE"
chmod 0755 "$SHIM_LIBRARY"

log "Installing permanent Homebrew compatibility environment"
install -d -m 0755 -o root -g root "$ROOT_ENV_DIR"
if [[ ! -f "$ROOT_ENV_FILE" ]]; then
  cat > "$ROOT_ENV_FILE" <<EOF_ENV
# systui managed Homebrew root-compat defaults
HOMEBREW_ROOT_COMPAT=1
HOMEBREW_NO_ANALYTICS=1
HOMEBREW_NO_ENV_HINTS=1
HOMEBREW_NO_AUTO_UPDATE=1
HOMEBREW_NO_INSTALL_CLEANUP=1
EOF_ENV
  chmod 0644 "$ROOT_ENV_FILE"
fi

log "Installing root-enabled brew wrapper"
cat > "$ROOT_WRAPPER" <<EOF_WRAPPER
#!/usr/bin/env bash
set -e

# Detect if running as root or non-root
if [ "\$(id -u)" -eq 0 ]; then
  export HOME="/root"
  export USER="root"
  export LOGNAME="root"
else
  export HOME="/home/linuxbrew"
  export USER="linuxbrew"
  export LOGNAME="linuxbrew"
fi

export HOMEBREW_PREFIX="$BREW_PREFIX"
export HOMEBREW_CELLAR="$BREW_PREFIX/Cellar"
export HOMEBREW_REPOSITORY="$BREW_REPOSITORY"
export PATH="$BREW_PREFIX/bin:$BREW_PREFIX/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
if [ -r "$ROOT_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ROOT_ENV_FILE"
fi
: "\${HOMEBREW_NO_ANALYTICS:=1}"
: "\${HOMEBREW_NO_ENV_HINTS:=1}"
: "\${HOMEBREW_NO_AUTO_UPDATE:=1}"
: "\${HOMEBREW_NO_INSTALL_CLEANUP:=1}"
export HOMEBREW_NO_ANALYTICS HOMEBREW_NO_ENV_HINTS HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_INSTALL_CLEANUP
export LD_PRELOAD="$SHIM_LIBRARY\${LD_PRELOAD:+:\$LD_PRELOAD}"

exec "$REAL_BREW" "\$@"
EOF_WRAPPER
chmod 0755 "$ROOT_WRAPPER"

# Prevent the prefix symlink from bypassing the root wrapper.
rm -f "$BREW_LINK"
ln -s "$ROOT_WRAPPER" "$BREW_LINK"

# Make Homebrew directories accessible to linuxbrew user
chown -R linuxbrew:linuxbrew "$BREW_PREFIX/Cellar" 2>/dev/null || true
chown -R linuxbrew:linuxbrew "$BREW_PREFIX/Caskroom" 2>/dev/null || true
chown -R linuxbrew:linuxbrew "$BREW_PREFIX/opt" 2>/dev/null || true
chmod -R u+w "$BREW_PREFIX/Cellar" 2>/dev/null || true
chmod -R u+w "$BREW_PREFIX/Caskroom" 2>/dev/null || true
chmod -R u+w "$BREW_PREFIX/opt" 2>/dev/null || true

# Ensure linuxbrew can write to var
chown -R linuxbrew:linuxbrew "$BREW_PREFIX/var/homebrew" 2>/dev/null || true
chmod -R u+w "$BREW_PREFIX/var/homebrew" 2>/dev/null || true

log "Writing system-wide root Homebrew environment"
cat > "$PROFILE_FILE" <<EOF_PROFILE
export HOMEBREW_PREFIX="$BREW_PREFIX"
export HOMEBREW_CELLAR="$BREW_PREFIX/Cellar"
export HOMEBREW_REPOSITORY="$BREW_REPOSITORY"
export PATH="/usr/local/bin:$BREW_PREFIX/bin:$BREW_PREFIX/sbin:\$PATH"
export MANPATH="$BREW_PREFIX/share/man\${MANPATH+:\$MANPATH}"
export INFOPATH="$BREW_PREFIX/share/info\${INFOPATH+:\$INFOPATH}"
[ -r "$ROOT_ENV_FILE" ] && . "$ROOT_ENV_FILE"
EOF_PROFILE
chmod 0644 "$PROFILE_FILE"

for profile in /root/.bashrc /root/.profile; do
  touch "$profile"
  if ! grep -Fq '/etc/profile.d/homebrew.sh' "$profile"; then
    cat >> "$profile" <<'EOF_PROFILE_LOAD'

# Root-managed Homebrew
[ -r /etc/profile.d/homebrew.sh ] && . /etc/profile.d/homebrew.sh
EOF_PROFILE_LOAD
  fi
done

log "Verifying root-enabled Homebrew"
"$ROOT_WRAPPER" --version

cat <<EOF_DONE

Root-managed Homebrew installation completed.

Use Homebrew directly as root:
  source /etc/profile.d/homebrew.sh
  brew --version
  brew install <formula>
  brew update
  brew upgrade

Compatibility layer assets:
  Wrapper: $ROOT_WRAPPER
  Env file: $ROOT_ENV_FILE
  Shim:    $SHIM_LIBRARY

Note: Homebrew running as root uses a UID shim (LD_PRELOAD) to satisfy
Homebrew's non-root requirement. This is unsupported upstream.
EOF_DONE
