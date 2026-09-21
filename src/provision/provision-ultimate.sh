#!/bin/sh
# provision-ultimate.sh
# ---------------------------------------------------------------------------
# Turn a fresh minimal Linux rootfs into a full-featured, terminal-only system.
#
# Supports distributions using apt, apk, pacman, dnf/yum, zypper, XBPS, or
# Portage. Package names and service conventions are selected at runtime.
#
# Features:
#   * generous "ultimate terminal" CLI tool set
#   * services enabled on boot (sshd, rsyslog, cron, chrony, ...)
#   * US/Pacific timezone (configurable)
#   * chrony in iSH-aware monitoring mode (the guest clock is the host clock)
#   * shell niceties: bash login shells, colour prompt, MOTD, login summary,
#     fzf/dircolors integration, machine-id, periodic maintenance via cron
#   * a dependency-free Neovim starter config (OSC52 clipboard on nvim >= 0.10)
#
# It is IDEMPOTENT: safe to run repeatedly. Run as root:
#       sudo sh provision-ultimate.sh
#   or  doas sh provision-ultimate.sh
#
# When run on a terminal it PROMPTS for the timezone and the primary login
# (creating that user if it does not exist). Pre-set any tunable via the
# environment to skip its prompt / run non-interactively:
#       TZ_NAME=America/Los_Angeles    # timezone (else prompted)
#       TARGET_USER=mke                # primary login to set up (else prompted)
#       NEW_HOSTNAME=                  # hostname to set (else prompted)
#       SUDO_NOPASSWD=0                # 1 = passwordless sudo-group sudo
# ---------------------------------------------------------------------------
set -u
export DEBIAN_FRONTEND=noninteractive

# ---- must be root --------------------------------------------------------
if [ "$(id -u)" != 0 ]; then
    echo "This script must run as root:  sudo sh $0" >&2
    exit 1
fi

log()  { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

# Wall-clock markers: a long provisioning run is much easier to trust (and to
# report as "stuck") when each milestone says how long the run has taken.
_PROV_T0=0
_elapsed() {  # seconds since the run started (empty when `date` is unavailable)
    _now="$(date +%s 2>/dev/null)"
    case "${_now:-}" in ''|*[!0-9]*) return 0 ;; esac
    [ "${_PROV_T0:-0}" -gt 0 ] 2>/dev/null || return 0
    printf '%s' "$((_now - _PROV_T0))"
}
_milestone() {  # _milestone <label>
    _el="$(_elapsed)"
    if [ -n "$_el" ]; then note "$1 (elapsed ${_el}s)"; else note "$1"; fi
}
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*"; }

# ---- Distro and init system detection -----------------------------------
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_NAME="${NAME:-unknown}"
        DISTRO_VERSION="${VERSION_ID:-unknown}"
    else
        DISTRO_ID="unknown"
        DISTRO_NAME="Linux"
        DISTRO_VERSION="unknown"
    fi
    export DISTRO_ID DISTRO_NAME DISTRO_VERSION
}

detect_init_system() {
    # INSPECTION ONLY -- /sbin/init is NEVER executed here.
    # On iSH-AOK /sbin/init is a live PID-1 supervisor (systui's systemd
    # compatibility launcher), so probing it with `/sbin/init --version` starts
    # a real init; the probe then blocks forever waiting for that init, and
    # provisioning appears frozen before its first status line. Every check
    # below is a file/process inspection that cannot block.
    SYSTUI_NONBLOCKING_INIT_DETECT=1
    _init_pid1="$(cat /proc/1/comm 2>/dev/null)"
    _init_link="$(readlink /sbin/init 2>/dev/null)"
    _init_is() {  # _init_is <name>: does the PID-1 name or /sbin/init target match?
        case "$_init_pid1 $_init_link" in
            *"$1"*) return 0 ;;
        esac
        return 1
    }
    if _init_is systemd || { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; } || \
       [ -r /etc/systui/ish-systemd-compat.conf ] || \
       [ -x /lib/systemd/systemd ] || [ -x /usr/lib/systemd/systemd ]; then
        INIT_SYSTEM="systemd"
    elif _init_is sysvinit || [ -x /lib/sysvinit/init ] || [ -x /usr/lib/sysvinit/init ]; then
        INIT_SYSTEM="sysvinit"
    elif command -v rc-service >/dev/null 2>&1 || command -v openrc >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    elif _init_is runit || command -v sv >/dev/null 2>&1; then
        INIT_SYSTEM="runit"
    else
        INIT_SYSTEM="unknown"
    fi
    return 0
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then PACKAGE_MANAGER=apt
    elif command -v apk >/dev/null 2>&1; then PACKAGE_MANAGER=apk
    elif command -v pacman >/dev/null 2>&1; then PACKAGE_MANAGER=pacman
    elif command -v dnf >/dev/null 2>&1; then PACKAGE_MANAGER=dnf
    elif command -v yum >/dev/null 2>&1; then PACKAGE_MANAGER=yum
    elif command -v zypper >/dev/null 2>&1; then PACKAGE_MANAGER=zypper
    elif command -v xbps-install >/dev/null 2>&1; then PACKAGE_MANAGER=xbps
    elif command -v emerge >/dev/null 2>&1; then PACKAGE_MANAGER=portage
    else PACKAGE_MANAGER=unknown
    fi
}

detect_distro
detect_init_system
detect_package_manager
_PROV_T0="$(date +%s 2>/dev/null)"
case "${_PROV_T0:-}" in ''|*[!0-9]*) _PROV_T0=0 ;; esac
note "Detected: $DISTRO_NAME ($DISTRO_ID) - packages: $PACKAGE_MANAGER - init: $INIT_SYSTEM"
[ "$PACKAGE_MANAGER" != unknown ] || {
    warn "No supported package manager was found (apt, apk, pacman, dnf/yum, zypper, XBPS, or Portage)."
    exit 2
}

# ---- bounded, non-interactive command runner ------------------------------
# Every step that can block (package managers, service managers, account and
# ssh tooling) must go through _rto. It exists because "provisioning is stuck"
# had three separate causes on emulated hosts, and it removes all three:
#
#   1. a command that waits for input. stdin is always /dev/null, so a
#      maintainer script, a licence/GPG prompt or a compat launcher asking a
#      question gets EOF instead of blocking the whole run forever;
#   2. no wall-clock limit. A hard limit is enforced by a watchdog subshell, so
#      it works even where coreutils 'timeout' is missing or cannot kill a
#      wedged child;
#   3. no feedback. The watchdog prints a heartbeat, so a slow-but-alive step
#      is visibly different from a hang.
#
# Knobs: PROVISION_HEARTBEAT=<secs> (0 disables), PROVISION_TIMEOUT_MAX=<secs>
# caps every limit, PROVISION_NO_TIMEOUT=1 opts out (foreground, blocking).
_STEP_T0=0
_heartbeat="${PROVISION_HEARTBEAT:-20}"
case "$_heartbeat" in ''|*[!0-9]*) _heartbeat=20 ;; esac
_timeout_max="${PROVISION_TIMEOUT_MAX:-}"
case "$_timeout_max" in ''|*[!0-9]*) _timeout_max=0 ;; esac
_HAS_SLEEP=0
command -v sleep >/dev/null 2>&1 && _HAS_SLEEP=1
_heartbeat_tick="$_heartbeat"
[ "$_heartbeat_tick" -gt 0 ] 2>/dev/null || _heartbeat_tick=1
note "Step limits: ${_timeout_max:-no} cap per step, heartbeat every ${_heartbeat}s (PROVISION_NO_TIMEOUT=1 / PROVISION_TIMEOUT_MAX=<s> adjust this)."

_rto() {  # _rto <secs> <cmd...>  -> command status, 124 when the limit fired
    _rto_secs="$1"; shift
    case "$_rto_secs" in ''|*[!0-9]*) _rto_secs=300 ;; esac
    if [ "$_timeout_max" -gt 0 ] && [ "$_rto_secs" -gt "$_timeout_max" ]; then
        _rto_secs="$_timeout_max"
    fi
    if [ "${PROVISION_NO_TIMEOUT:-0}" = 1 ] || [ "$_HAS_SLEEP" != 1 ]; then
        [ "$_HAS_SLEEP" = 1 ] || warn "no 'sleep' on this host: steps cannot be time-bounded"
        ( "$@" ) < /dev/null
        return $?
    fi
    _rto_label="$1"
    ( "$@" ) < /dev/null &
    _rto_pid=$!
    (
        _rto_wait=0
        while kill -0 "$_rto_pid" 2>/dev/null; do
            sleep "$_heartbeat_tick"
            _rto_wait=$((_rto_wait + _heartbeat_tick))
            if [ "$_rto_wait" -ge "$_rto_secs" ]; then
                printf '    ... limit reached (%ss): %s -- terminating it\n' \
                    "$_rto_secs" "$_rto_label" >&2
                kill -TERM "$_rto_pid" 2>/dev/null
                sleep 3
                kill -KILL "$_rto_pid" 2>/dev/null
                exit 0
            fi
            [ "$_heartbeat" -gt 0 ] || continue
            printf '    ... still running (%ss): %s\n' "$_rto_wait" "$_rto_label" >&2
        done
    ) &
    _rto_wd=$!
    wait "$_rto_pid"
    _rto_rc=$?
    kill "$_rto_wd" 2>/dev/null
    wait "$_rto_wd" 2>/dev/null
    case "$_rto_rc" in
        143|137) return 124 ;;  # TERM/KILL -> report it as a time-out, like `timeout`
    esac
    return "$_rto_rc"
}

# ---- bounded service helpers ----------------------------------------------
# Defined before their first use: the SSH section needs them long before the
# service pass runs. (The script used to call an undefined `service_restart`,
# so the hardened sshd_config was never actually picked up by a running sshd.)
_svc_pick() {  # _svc_pick <candidate>... -> first service that exists (stdout)
    _sp_name=""
    for _sp_cand in "$@"; do
        case "$INIT_SYSTEM" in
            systemd) _rto 30 systemctl list-unit-files "$_sp_cand.service" 2>/dev/null | grep -q "^$_sp_cand\.service" && _sp_name="$_sp_cand" ;;
            runit) [ -d "/etc/sv/$_sp_cand" ] && _sp_name="$_sp_cand" ;;
            *) [ -x "/etc/init.d/$_sp_cand" ] && _sp_name="$_sp_cand" ;;
        esac
        [ -z "$_sp_name" ] || break
    done
    [ -n "$_sp_name" ] && printf '%s\n' "$_sp_name"
    return 0
}

_svc_activate() {  # _svc_activate <service> -> 0 ok, 124 the service manager hung
    _sa_svc="$1"; _sa_rc=0
    case "$INIT_SYSTEM" in
        systemd)
            _rto 60 systemctl enable "$_sa_svc" >/dev/null 2>&1 || true
            _rto 90 systemctl restart "$_sa_svc" >/dev/null 2>&1 \
                || _rto 90 systemctl start "$_sa_svc" >/dev/null 2>&1 \
                || _sa_rc=$?
            ;;
        openrc)
            _rto 90 rc-update add "$_sa_svc" default >/dev/null 2>&1 || true
            _rto 90 rc-service "$_sa_svc" restart >/dev/null 2>&1 \
                || _rto 90 rc-service "$_sa_svc" start >/dev/null 2>&1 \
                || _sa_rc=$?
            ;;
        runit)
            if [ -d "/etc/sv/$_sa_svc" ]; then
                mkdir -p /var/service
                ln -sfn "/etc/sv/$_sa_svc" "/var/service/$_sa_svc"
            fi
            _rto 90 sv restart "$_sa_svc" >/dev/null 2>&1 \
                || _rto 90 sv up "$_sa_svc" >/dev/null 2>&1 \
                || _sa_rc=$?
            ;;
        sysvinit)
            command -v update-rc.d >/dev/null 2>&1 && _rto 60 update-rc.d "$_sa_svc" defaults >/dev/null 2>&1 || true
            command -v chkconfig >/dev/null 2>&1 && _rto 60 chkconfig "$_sa_svc" on >/dev/null 2>&1 || true
            _rto 90 service "$_sa_svc" restart >/dev/null 2>&1 \
                || _rto 90 service "$_sa_svc" start >/dev/null 2>&1 \
                || _sa_rc=$?
            ;;
        *) _sa_rc=1 ;;
    esac
    return "$_sa_rc"
}

# ---- config (env overrides; prompts interactively when run on a TTY) ------
NEW_HOSTNAME="${NEW_HOSTNAME:-}"
SUDO_NOPASSWD="${SUDO_NOPASSWD:-0}"

# Defaults offered at the prompts.
DEF_TZ="${TZ_NAME:-America/Los_Angeles}"
DEF_USER="${TARGET_USER:-${SUDO_USER:-}}"
if [ -z "$DEF_USER" ] || [ "$DEF_USER" = root ]; then
    DEF_USER="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)"
fi
[ -n "$DEF_USER" ] || DEF_USER="aok"
DEF_HOSTNAME="$(cat /etc/hostname 2>/dev/null)"
[ -n "$DEF_HOSTNAME" ] && [ "$DEF_HOSTNAME" != localhost ] || DEF_HOSTNAME="linux-ultimate"

# ask <var> <prompt> <default>: keep an env-provided value; else prompt on a
# TTY; else use the default (so piped/ssh runs never block).
ask() {
    eval "_cur=\${$1:-}"
    [ -n "$_cur" ] && return
    if [ -t 0 ]; then
        printf '%s [%s]: ' "$2" "$3"
        read _a || _a=""
        [ -n "$_a" ] || _a="$3"
    else
        _a="$3"
    fi
    eval "$1=\$_a"
}
ask TZ_NAME     "Timezone (e.g. America/New_York, UTC)" "$DEF_TZ"
ask TARGET_USER "Primary login username to set up"      "$DEF_USER"
ask NEW_HOSTNAME "Hostname"                              "$DEF_HOSTNAME"

note "timezone=$TZ_NAME  login=${TARGET_USER:-<none>}  hostname=${NEW_HOSTNAME:-<keep>}  init=$INIT_SYSTEM"

# ===========================================================================
log "Installing packages (this is the slow part under emulation)"
# ===========================================================================
case "$PACKAGE_MANAGER" in
    apt)
        PKGS="bash bash-completion cmake coreutils findutils grep sed gawk diffutils util-linux bsdextrautils procps passwd adduser file less locales openssh-client openssh-server sudo rsyslog iputils-ping chrony cron logrotate dialog tzdata ca-certificates openssl man-db manpages curl wget rsync bind9-dnsutils iproute2 git strace build-essential gdb python3 python3-pip python3-venv vim neovim nano tmux sysstat htop btop ncdu lsof pv tree mc fzf ripgrep fd-find bat eza jq most w3m lynx nmap socat netcat-openbsd mtr-tiny tar unzip zip p7zip-full bzip2 gzip zstd xz-utils fastfetch figlet ncurses-bin ncurses-term"
        [ "$INIT_SYSTEM" = sysvinit ] && PKGS="$PKGS sysvinit-core"
        ;;
    apk)
        PKGS="bash bash-completion cmake coreutils findutils grep sed gawk diffutils util-linux procps shadow file less musl-locales openssh sudo syslog-ng chrony dcron logrotate dialog tzdata ca-certificates openssl mandoc man-pages curl wget rsync bind-tools iproute2 git strace build-base gdb python3 py3-pip py3-virtualenv vim neovim nano tmux htop btop ncdu lsof pv tree mc fzf ripgrep fd bat eza jq most w3m lynx nmap socat netcat-openbsd mtr tar unzip zip p7zip bzip2 gzip zstd xz fastfetch figlet ncurses"
        ;;
    pacman)
        PKGS="bash bash-completion cmake coreutils findutils grep sed gawk diffutils util-linux procps-ng shadow file less glibc openssh sudo syslog-ng chrony cronie logrotate dialog tzdata ca-certificates openssl man-db man-pages curl wget rsync bind iproute2 git strace base-devel gdb python python-pip python-virtualenv vim neovim nano tmux sysstat htop btop ncdu lsof pv tree mc fzf ripgrep fd bat eza jq most w3m lynx nmap socat openbsd-netcat mtr tar unzip zip p7zip bzip2 gzip zstd xz fastfetch figlet ncurses"
        ;;
    dnf|yum)
        PKGS="bash bash-completion cmake coreutils findutils grep sed gawk diffutils util-linux procps-ng shadow-utils file less glibc-langpack-en openssh-clients openssh-server sudo rsyslog chrony cronie logrotate dialog tzdata ca-certificates openssl man-db man-pages curl wget rsync bind-utils iproute git strace gcc gcc-c++ make gdb python3 python3-pip vim-enhanced neovim nano tmux sysstat htop btop ncdu lsof pv tree mc fzf ripgrep fd-find bat eza jq most w3m lynx nmap-ncat nmap mtr tar unzip zip p7zip bzip2 gzip zstd xz fastfetch figlet ncurses"
        ;;
    zypper)
        PKGS="bash bash-completion cmake coreutils findutils grep sed gawk diffutils util-linux procps shadow file less glibc-locale openssh sudo rsyslog chrony cron logrotate dialog timezone ca-certificates openssl man man-pages curl wget rsync bind-utils iproute2 git strace gcc gcc-c++ make gdb python3 python3-pip python3-virtualenv vim neovim nano tmux sysstat htop btop ncdu lsof pv tree mc fzf ripgrep fd bat eza jq most w3m lynx nmap socat netcat-openbsd mtr tar unzip zip p7zip bzip2 gzip zstd xz fastfetch figlet ncurses-utils"
        ;;
    xbps)
        PKGS="bash bash-completion cmake coreutils findutils grep sed gawk diffutils util-linux procps-ng shadow file less glibc-locales openssh sudo socklog-void chrony cronie logrotate dialog tzdata ca-certificates openssl man-db man-pages curl wget rsync bind-utils iproute2 git strace base-devel gdb python3 python3-pip python3-virtualenv vim neovim nano tmux htop btop ncdu lsof pv tree mc fzf ripgrep fd bat eza jq most w3m lynx nmap socat openbsd-netcat mtr tar unzip zip p7zip bzip2 gzip zstd xz fastfetch figlet ncurses"
        ;;
    portage)
        PKGS="app-shells/bash-completion dev-build/cmake sys-apps/coreutils sys-apps/findutils sys-apps/grep sys-apps/sed sys-apps/gawk sys-apps/diffutils sys-apps/util-linux sys-process/procps sys-apps/shadow sys-apps/file sys-apps/less net-misc/openssh app-admin/sudo app-admin/syslog-ng net-misc/chrony sys-process/cronie app-admin/logrotate dev-util/dialog sys-libs/timezone-data app-misc/ca-certificates dev-libs/openssl sys-apps/man-db net-misc/curl net-misc/wget net-misc/rsync net-dns/bind-tools sys-apps/iproute2 dev-vcs/git dev-debug/strace sys-devel/gcc sys-devel/make dev-debug/gdb dev-lang/python dev-python/pip app-editors/vim app-editors/neovim app-editors/nano app-misc/tmux sys-process/htop sys-process/btop sys-fs/ncdu sys-process/lsof sys-apps/pv app-text/tree app-misc/mc app-shells/fzf sys-apps/ripgrep sys-apps/fd app-text/bat app-misc/jq www-client/w3m net-analyzer/nmap net-misc/socat net-analyzer/mtr app-arch/unzip app-arch/zip app-arch/p7zip app-arch/zstd app-misc/fastfetch app-misc/figlet sys-libs/ncurses"
        ;;
esac

# ---- optional package-set tuning (systui passes these through the env) -----
# PKG_EXTRA adds to the distribution list, PKG_SKIP removes names from it, so a
# host can tailor the provision set without editing this script. PROVISION_DRY_RUN
# prints the final list and exits before anything is modified.
if [ -n "${EXTRA_PKGS:-}" ]; then
    PKGS="$PKGS $EXTRA_PKGS"
    note "extra packages requested: $EXTRA_PKGS"
fi
if [ -n "${SKIP_PKGS:-}" ]; then
    _kept=""
    for _p in $PKGS; do
        case " $SKIP_PKGS " in
            *" $_p "*) continue ;;
        esac
        _kept="$_kept $_p"
    done
    PKGS="${_kept# }"
    note "excluding packages: $SKIP_PKGS"
fi
if [ "${SKIP_SERVICES:-0}" = 1 ]; then
    note "service configuration disabled (SKIP_SERVICES=1)"
fi

if [ "${PROVISION_DRY_RUN:-0}" = 1 ]; then
    log "Dry run: no changes will be made"
    printf '    packages (%s):\n' "$PACKAGE_MANAGER"
    printf '      %s\n' $PKGS
    if [ "${SKIP_SERVICES:-0}" = 1 ]; then
        printf '    services: skipped\n'
    else
        printf '    services: logging, ssh, cron, chrony (enable/start)\n'
    fi
    printf '    timezone=%s login=%s hostname=%s init=%s\n' "$TZ_NAME" "${TARGET_USER:-<none>}" "$NEW_HOSTNAME" "$INIT_SYSTEM"
    exit 0
fi

# Pre-seed the timezone so the tzdata postinst never tries to prompt.
if [ -f "/usr/share/zoneinfo/$TZ_NAME" ]; then
    ln -sf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime 2>/dev/null || true
    printf '%s\n' "$TZ_NAME" > /etc/timezone
else
    warn "Timezone $TZ_NAME not found in zoneinfo; clock preset skipped"
fi

refresh_packages() {
    case "$PACKAGE_MANAGER" in
        apt)    _rto 180 apt-get update ;;
        apk)    _rto 180 apk update ;;
        pacman) _rto 300 pacman -Syu --noconfirm ;;   # -Sy alone desynchronises the system
        dnf)    _rto 180 dnf -y makecache ;;
        yum)    _rto 180 yum -y makecache ;;
        zypper) _rto 180 zypper --non-interactive refresh ;;
        xbps)   _rto 180 xbps-install -S ;;
        portage) _rto 600 emerge --sync ;;
    esac
}

install_one() {
    case "$PACKAGE_MANAGER" in
        apt)    _rto 300 apt-get -o Dpkg::Options::="--force-confold" install -y --no-install-recommends "$1" ;;
        apk)    _rto 300 apk add "$1" ;;
        pacman) _rto 300 pacman -S --needed --noconfirm "$1" ;;
        dnf)    _rto 300 dnf install -y --setopt=install_weak_deps=False "$1" ;;
        yum)    _rto 300 yum install -y "$1" ;;
        zypper) _rto 300 zypper --non-interactive install --no-recommends "$1" ;;
        xbps)   _rto 300 xbps-install -y "$1" ;;
        portage) _rto 600 emerge --noreplace "$1" ;;
    esac
}

log "Refreshing package index"
refresh_packages || warn "Package index refresh failed; continuing with the current index"

# Fast path: install all packages in one shot — far fewer PM round-trips and
# much less likely to stall on a single download under slow emulation.
# If the bulk install fails (e.g. one package name not found), fall back to
# per-package installs so the rest still get through.
INSTALLED_COUNT=0 SKIPPED_COUNT=0
_bulk_ok=0
case "$PACKAGE_MANAGER" in
    apt)    _rto 1800 apt-get -o Dpkg::Options::="--force-confold" install -y --no-install-recommends $PKGS && _bulk_ok=1 ;;
    apk)    _rto 1800 apk add $PKGS && _bulk_ok=1 ;;
    pacman) _rto 1800 pacman -S --needed --noconfirm $PKGS && _bulk_ok=1 ;;
    dnf)    _rto 1800 dnf install -y --setopt=install_weak_deps=False $PKGS && _bulk_ok=1 ;;
    yum)    _rto 1800 yum install -y $PKGS && _bulk_ok=1 ;;
    zypper) _rto 1800 zypper --non-interactive install --no-recommends $PKGS && _bulk_ok=1 ;;
    xbps)   _rto 1800 xbps-install -y $PKGS && _bulk_ok=1 ;;
    portage) _rto 3600 emerge --noreplace $PKGS && _bulk_ok=1 ;;
esac
if [ "$_bulk_ok" = 1 ]; then
    note "bulk install succeeded"
    # shellcheck disable=SC2086
    INSTALLED_COUNT=$(echo $PKGS | wc -w); SKIPPED_COUNT=0
else
    note "bulk install failed or timed out; falling back to per-package (slower)..."
    # Progress matters here: a 90-package fallback pass at 300s each can run for
    # hours, and with no output that looks exactly like a hang. Report the
    # position, and stop early when the package manager is wedged instead of
    # grinding through the whole list.
    _pkg_total=0
    for _p in $PKGS; do _pkg_total=$((_pkg_total + 1)); done
    _pkg_idx=0
    _consec_timeouts=0
    _max_consec="${PROVISION_MAX_CONSECUTIVE_TIMEOUTS:-3}"
    case "$_max_consec" in ''|*[!0-9]*) _max_consec=3 ;; esac
    for p in $PKGS; do
        _pkg_idx=$((_pkg_idx + 1))
        note "[$_pkg_idx/$_pkg_total] $p"
        if install_one "$p"; then
            INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
            _consec_timeouts=0
        else
            _install_rc=$?
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            note "skipped: $p (unavailable or timed out)"
            if [ "$_install_rc" = 124 ]; then
                _consec_timeouts=$((_consec_timeouts + 1))
            else
                _consec_timeouts=0
            fi
            if [ "$_consec_timeouts" -ge "$_max_consec" ]; then
                warn "$_consec_timeouts timed-out package operations in a row -- the package manager looks wedged, not merely slow."
                note "Stopping the per-package pass at $_pkg_idx/$_pkg_total; re-run provisioning once the package manager responds."
                break
            fi
        fi
    done
fi
_milestone "package pass complete: $INSTALLED_COUNT installed/already present, $SKIPPED_COUNT skipped"
if [ "$PACKAGE_MANAGER" = apt ]; then
    _rto 600 dpkg --force-confold --configure -a || warn "Some Debian packages remain unconfigured; run: dpkg --configure -a"
    _rto 120 apt-get clean || true
fi

# Account tools and Bash now exist even on a minimal image.
if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != root ] && ! id "$TARGET_USER" >/dev/null 2>&1; then
    _rto 60 adduser --disabled-password --gecos "" --shell /bin/bash "$TARGET_USER" >/dev/null 2>&1 \
        || _rto 60 adduser -D -s /bin/bash "$TARGET_USER" >/dev/null 2>&1 \
        || _rto 60 useradd -m -s /bin/bash "$TARGET_USER" 2>/dev/null \
        || warn "Could not create login '$TARGET_USER'"
    id "$TARGET_USER" >/dev/null 2>&1 && note "created login '$TARGET_USER' (set its password with: passwd $TARGET_USER)"
fi
TARGET_HOME=""
if [ -n "$TARGET_USER" ] && id "$TARGET_USER" >/dev/null 2>&1; then
    TARGET_HOME="$(awk -F: -v u="$TARGET_USER" '$1==u{print $6}' /etc/passwd)"
fi

# Debian/Ubuntu ship these tools under disambiguated names; add the conventional
# command names in /usr/local/bin so muscle memory (and the fzf/profile glue
# below) works. Only created when the target exists and the name is free.
link_alt() {  # <real-binary> <wanted-name>
    command -v "$1" >/dev/null 2>&1 || return 0
    # Refresh if the wrapper symlink is absent or ours; skip real installed binaries.
    if [ ! -e "/usr/local/bin/$2" ] || [ -L "/usr/local/bin/$2" ]; then
        ln -sf "$(command -v "$1")" "/usr/local/bin/$2" && note "ln /usr/local/bin/$2 -> $1"
    fi
}
link_alt batcat bat
link_alt fdfind fd

# ===========================================================================
log "Timezone -> $TZ_NAME"
# ===========================================================================
if [ -f "/usr/share/zoneinfo/$TZ_NAME" ]; then
    ln -sf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime
    echo "$TZ_NAME" > /etc/timezone
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        _rto 30 timedatectl set-timezone "$TZ_NAME" 2>/dev/null || true
    fi
    command -v dpkg-reconfigure >/dev/null 2>&1 && _rto 90 dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true
    note "$(date)"
else
    note "zoneinfo for '$TZ_NAME' not found; leaving clock as-is"
fi

# ===========================================================================
log "Locale -> C.UTF-8"
# ===========================================================================
mkdir -p /etc/default /etc/profile.d
printf 'LANG=C.UTF-8\n' > /etc/default/locale
if ! grep -q '^LANG=' /etc/environment 2>/dev/null; then
    printf 'LANG=C.UTF-8\nLC_ALL=C.UTF-8\n' >> /etc/environment
fi
update-locale LANG=C.UTF-8 2>/dev/null || true
note "LANG=C.UTF-8 (via /etc/default/locale, /etc/environment)"

# ===========================================================================
log "machine-id"
# ===========================================================================
if [ ! -s /etc/machine-id ]; then
    { openssl rand -hex 16 2>/dev/null || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n'; } > /etc/machine-id
    chmod 0444 /etc/machine-id
fi
# Keep the legacy D-Bus machine-id in sync (some tools still read it).
if [ -d /var/lib/dbus ] && [ ! -e /var/lib/dbus/machine-id ]; then
    ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
fi
note "$(cat /etc/machine-id)"

# ===========================================================================
log "Hostname"
# ===========================================================================
if [ -n "$NEW_HOSTNAME" ]; then
    echo "$NEW_HOSTNAME" > /etc/hostname
elif [ ! -s /etc/hostname ] || [ "$(cat /etc/hostname 2>/dev/null)" = localhost ]; then
    echo "linux-ultimate" > /etc/hostname
fi
hostname "$(cat /etc/hostname)" 2>/dev/null || true
if [ "$INIT_SYSTEM" = "systemd" ]; then
    hostnamectl set-hostname "$(cat /etc/hostname)" 2>/dev/null || true
fi
# Make sure the hostname resolves (Debian expects a 127.0.1.1 line).
_hn="$(cat /etc/hostname 2>/dev/null)"
if [ -n "$_hn" ] && ! grep -qE "[[:space:]]$_hn(\$|[[:space:]])" /etc/hosts 2>/dev/null; then
    printf '127.0.1.1\t%s\n' "$_hn" >> /etc/hosts
fi
note "$(cat /etc/hostname)"

# ===========================================================================
ADMIN_GROUP=sudo
case "$PACKAGE_MANAGER" in apt) ;; *) ADMIN_GROUP=wheel ;; esac
log "sudo for the $ADMIN_GROUP group"
# ===========================================================================
getent group "$ADMIN_GROUP" >/dev/null 2>&1 || groupadd "$ADMIN_GROUP" 2>/dev/null || true
mkdir -p /etc/sudoers.d
if [ "$SUDO_NOPASSWD" = 1 ]; then
    printf '%%%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$ADMIN_GROUP" > /etc/sudoers.d/aok-sudo
    note "passwordless sudo for the $ADMIN_GROUP group"
else
    printf '%%%s ALL=(ALL:ALL) ALL\n' "$ADMIN_GROUP" > /etc/sudoers.d/aok-sudo
    note "$ADMIN_GROUP-group sudo (password required; set SUDO_NOPASSWD=1 for passwordless)"
fi
chmod 0440 /etc/sudoers.d/aok-sudo
# Refuse to leave an invalid sudoers fragment in place.
if command -v visudo >/dev/null 2>&1 && ! visudo -cf /etc/sudoers.d/aok-sudo >/dev/null 2>&1; then
    rm -f /etc/sudoers.d/aok-sudo
    note "WARNING: generated sudoers fragment failed validation; removed it"
fi
if [ -n "$TARGET_USER" ] && id "$TARGET_USER" >/dev/null 2>&1; then
    id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$ADMIN_GROUP" \
        || _rto 60 usermod -aG "$ADMIN_GROUP" "$TARGET_USER" >/dev/null 2>&1 \
        || _rto 60 adduser "$TARGET_USER" "$ADMIN_GROUP" >/dev/null 2>&1 \
        || warn "Could not add $TARGET_USER to $ADMIN_GROUP"
    note "$TARGET_USER is in: $(id -nG "$TARGET_USER")"
fi

# ===========================================================================
log "Login shells -> bash"
# ===========================================================================
grep -qx /bin/bash /etc/shells 2>/dev/null || echo /bin/bash >> /etc/shells
for u in root $TARGET_USER; do
    id "$u" >/dev/null 2>&1 || continue
    _rto 60 chsh -s /bin/bash "$u" >/dev/null 2>&1 || _rto 60 usermod -s /bin/bash "$u" 2>/dev/null || true
done
note "root + ${TARGET_USER:-} now use bash"

# ===========================================================================
log "MOTD"
# ===========================================================================
cat > /etc/motd <<'MOTD'

   Linux Ultimate  .  Portable terminal-only userspace
   -------------------------------------------------------------------
   services (systemd):  systemctl {start|stop|status|restart} <name>
   services (OpenRC):   rc-service <name> {start|stop|status}
   services (SysV):     service <name> {start|stop|status}
   on boot (systemd):   systemctl {enable|disable} <name>
   on boot (sysvinit):  update-rc.d <name> {enable|disable}
   time (chrony):       chronyc tracking
   logs:                journalctl (systemd) or /var/log/syslog
   docs:                man <command>
   -------------------------------------------------------------------

MOTD

# ===========================================================================
log "Shell niceties (/etc/profile.d)"
# ===========================================================================
cat > /etc/profile.d/30-aok-niceties.sh <<'NICETIES'
# AOK "full Linux feel" interactive niceties.  Safe for dash & bash.
export EDITOR=vim VISUAL=vim PAGER=less
export LESS='-R -M -i'
export TERM="${TERM:-xterm-256color}"
export LC_ALL="${LC_ALL:-C.UTF-8}" LANG="${LANG:-C.UTF-8}"

case $- in *i*) ;; *) return 2>/dev/null || exit 0;; esac

alias ls='ls --color=auto'
alias ll='ls -alF --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias grep='grep --color=auto'
alias df='df -h'
alias free='free -m'
alias ..='cd ..'
alias ...='cd ../..'

if [ -n "${BASH:-}" ]; then
  if [ "$(id -u)" = 0 ]; then
    PS1='\[\e[1;31m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]# '
  else
    PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
  fi
  HISTSIZE=5000; HISTFILESIZE=10000; HISTCONTROL=ignoreboth
  shopt -s histappend checkwinsize 2>/dev/null
  [ -f /usr/share/bash-completion/bash_completion ] && . /usr/share/bash-completion/bash_completion
fi

if [ -z "${_AOK_SUMMARY_DONE:-}" ]; then
  export _AOK_SUMMARY_DONE=1
  printf '\n  \033[1;36m%s\033[0m  .  kernel \033[1m%s\033[0m  .  %s\n' \
    "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")" \
    "$(uname -r)" "$(uname -m)"
  printf '  uptime:%s\n' "$(uptime 2>/dev/null | sed 's/^[[:space:]]*//;s/^/ /')"
  printf '  disk /: %s   mem: %s\n\n' \
    "$(command df -h / 2>/dev/null | awk 'NR==2{print $3" / "$2" ("$5")"}')" \
    "$(command free -m 2>/dev/null | awk '/^Mem:/{print $3"M / "$2"M"}')"
fi
NICETIES
chmod 0644 /etc/profile.d/30-aok-niceties.sh

cat > /etc/profile.d/40-aok-tools.sh <<'TOOLS'
# Interactive niceties for the installed CLI tool set. Safe for dash & bash.
case $- in *i*) ;; *) return 2>/dev/null || exit 0;; esac

command -v dircolors >/dev/null 2>&1 && eval "$(dircolors -b 2>/dev/null)"
alias ip='ip -color=auto'
# On Debian/Ubuntu these ship as batcat / fdfind; fall back if the
# provisioner's /usr/local/bin/{bat,fd} symlinks are absent.
command -v bat    >/dev/null 2>&1 || { command -v batcat >/dev/null 2>&1 && alias bat='batcat'; }
command -v fd     >/dev/null 2>&1 || { command -v fdfind >/dev/null 2>&1 && alias fd='fdfind'; }
if command -v bat >/dev/null 2>&1 || command -v batcat >/dev/null 2>&1; then export BAT_THEME=ansi; fi

if [ -n "${BASH:-}" ]; then
  # Debian ships fzf's shell glue under /usr/share/doc/fzf/examples.
  for f in /usr/share/doc/fzf/examples/key-bindings.bash \
           /usr/share/doc/fzf/examples/completion.bash \
           /usr/share/fzf/key-bindings.bash /usr/share/fzf/completion.bash; do
    [ -f "$f" ] && . "$f"
  done
  export FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border"
  if command -v fdfind >/dev/null 2>&1; then
    export FZF_DEFAULT_COMMAND='fdfind --type f'
  elif command -v fd >/dev/null 2>&1; then
    export FZF_DEFAULT_COMMAND='fd --type f'
  fi
fi
TOOLS
chmod 0644 /etc/profile.d/40-aok-tools.sh
note "wrote /etc/profile.d/30-aok-niceties.sh and 40-aok-tools.sh"

# ===========================================================================
log "SSH hardening"
# ===========================================================================
if command -v sshd >/dev/null 2>&1; then
    _SSH_MAIN=/etc/ssh/sshd_config
    _SSH_DROP=/etc/ssh/sshd_config.d/20-systui.conf
    # Use a drop-in if the main config already has an Include directive (sshd >=7.3)
    if grep -q "^Include" "$_SSH_MAIN" 2>/dev/null && [ -d /etc/ssh/sshd_config.d ]; then
        note "Writing SSH hardening drop-in: $_SSH_DROP"
        cat > "$_SSH_DROP" <<'_SSHEOF'
# Managed by systui provision -- do not edit manually.
Port 22
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
StrictModes yes
ClientAliveInterval 300
ClientAliveCountMax 3
_SSHEOF
    else
        note "Applying SSH hardening in-place: $_SSH_MAIN"
        for _pair in "Port:22" "PermitRootLogin:no" "PasswordAuthentication:yes" \
                     "PubkeyAuthentication:yes" "StrictModes:yes" \
                     "ClientAliveInterval:300" "ClientAliveCountMax:3"; do
            _k=${_pair%%:*}; _v=${_pair#*:}
            if grep -qE "^[[:space:]]*#?[[:space:]]*${_k}[[:space:]]" "$_SSH_MAIN" 2>/dev/null; then
                sed -i "s|^[[:space:]]*#*[[:space:]]*${_k}[[:space:]].*|${_k} ${_v}|" "$_SSH_MAIN"
            else
                printf '%s %s\n' "$_k" "$_v" >> "$_SSH_MAIN"
            fi
        done
    fi
    if _rto 30 sshd -t 2>/dev/null; then
        _ssh_svc="$(_svc_pick ssh sshd)"
        if [ -n "$_ssh_svc" ]; then
            _svc_activate "$_ssh_svc"
            _sshd_rc=$?
            [ "$_sshd_rc" = 124 ] && warn "sshd did not restart within the limit; restart it manually: service $_ssh_svc restart"
            note "SSH hardening applied"
        else
            note "SSH hardening written; no sshd service found to restart"
        fi
    else
        warn "sshd -t validation failed after hardening -- check $_SSH_MAIN"
    fi
fi

# ===========================================================================
log "chrony (iSH-aware: monitor only, host owns the clock)"
# ===========================================================================
if command -v chronyd >/dev/null 2>&1 || command -v chronyc >/dev/null 2>&1; then
    if [ -d /etc/chrony ]; then CHRONY_CONFIG=/etc/chrony/chrony.conf   # Debian/Ubuntu
    else CHRONY_CONFIG=/etc/chrony.conf                                   # Fedora, Alpine, Arch
    fi
    cat > "$CHRONY_CONFIG" <<'CHRONYCONF'
# chrony.conf -- tuned for iSH-AOK (monitoring mode; chronyd runs with -x)
pool pool.ntp.org iburst
server time.cloudflare.com iburst
server time.google.com iburst
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
# NB: no 'rtcsync' / 'initstepslew' (no clock control under iSH). chronyd is
# started with -x via /etc/default/chrony so it only *monitors* the clock.
CHRONYCONF
    mkdir -p /var/log/chrony
    chown _chrony:_chrony /var/log/chrony 2>/dev/null || chown chrony:chrony /var/log/chrony 2>/dev/null || true

    if [ -f /etc/default/chrony ]; then
        if grep -q '^DAEMON_OPTS=' /etc/default/chrony 2>/dev/null; then
            sed -i 's/^DAEMON_OPTS=.*/DAEMON_OPTS="-x"/' /etc/default/chrony
        else
            echo 'DAEMON_OPTS="-x"' >> /etc/default/chrony
        fi
    elif [ "$PACKAGE_MANAGER" = apt ]; then
        echo 'DAEMON_OPTS="-x"' > /etc/default/chrony
    fi
    note "chronyd: DAEMON_OPTS=-x (monitor only), localhost command port"
fi

# ===========================================================================
log "Periodic maintenance (cron)"
# ===========================================================================
mkdir -p /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly
[ "$PACKAGE_MANAGER" = apt ] && { mkdir -p /var/spool/cron/crontabs; chmod 1730 /var/spool/cron/crontabs 2>/dev/null || true; }
note "cron run-parts dirs present"

# ===========================================================================
log "Neovim starter config"
# ===========================================================================
NVIM_MARKER="-- AOK starter config (provision-ultimate.sh)"
write_nvim() {  # <homedir> <owner>
    _hd="$1"; _own="$2"
    [ -n "$_hd" ] || return 0
    _cfg="$_hd/.config/nvim/init.lua"
    if [ -f "$_cfg" ] && ! grep -qF -e "$NVIM_MARKER" "$_cfg" 2>/dev/null; then
        note "nvim: keeping your existing $_cfg"
        return 0
    fi
    mkdir -p "$_hd/.config/nvim"
    cat > "$_cfg" <<'NVIMCFG'
-- AOK starter config (provision-ultimate.sh)
-- Dependency-free Neovim starter. Edit freely; the provisioner only overwrites
-- this file while the marker line above is present (delete it to keep yours).

vim.g.mapleader = " "
vim.g.maplocalleader = " "

local o = vim.opt
o.number = true
o.relativenumber = true
o.mouse = "a"
o.ignorecase = true
o.smartcase = true
o.incsearch = true
o.hlsearch = true
o.expandtab = true
o.shiftwidth = 4
o.tabstop = 4
o.softtabstop = 4
o.smartindent = true
o.breakindent = true
o.wrap = false
o.scrolloff = 5
o.sidescrolloff = 8
o.termguicolors = true
o.signcolumn = "yes"
o.cursorline = true
o.splitright = true
o.splitbelow = true
o.undofile = true
o.swapfile = false
o.updatetime = 300
o.timeoutlen = 500
o.completeopt = "menuone,noselect"
o.list = true
o.listchars = { tab = "» ", trail = "·", nbsp = "␣" }
o.title = true

pcall(vim.cmd.colorscheme, "habamax")

-- netrw as a light built-in file explorer
vim.g.netrw_banner = 0
vim.g.netrw_liststyle = 3

-- yank to the host clipboard over the terminal (OSC52) on Neovim >= 0.10
if vim.fn.has("nvim-0.10") == 1 then
  local ok, osc52 = pcall(require, "vim.ui.clipboard.osc52")
  if ok then
    vim.g.clipboard = {
      name = "OSC52",
      copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
      paste = { ["+"] = osc52.paste("+"), ["*"] = osc52.paste("*") },
    }
  end
end

local map = vim.keymap.set
map("n", "<leader>w", "<cmd>write<cr>", { desc = "Save" })
map("n", "<leader>q", "<cmd>quit<cr>", { desc = "Quit" })
map("n", "<leader>Q", "<cmd>quitall!<cr>", { desc = "Quit all (force)" })
map("n", "<leader>e", "<cmd>Explore<cr>", { desc = "File explorer" })
map("n", "<esc>", "<cmd>nohlsearch<cr>", { silent = true })
map("n", "<C-h>", "<C-w>h"); map("n", "<C-j>", "<C-w>j")
map("n", "<C-k>", "<C-w>k"); map("n", "<C-l>", "<C-w>l")
map("v", "J", ":m '>+1<cr>gv=gv", { silent = true })
map("v", "K", ":m '<-2<cr>gv=gv", { silent = true })
map("x", "<leader>p", [["_dP]], { desc = "Paste without losing register" })
map({ "n", "v" }, "<leader>y", [["+y]], { desc = "Yank to host clipboard" })

local aug = vim.api.nvim_create_augroup("aok", { clear = true })
vim.api.nvim_create_autocmd("TextYankPost", {
  group = aug,
  callback = function() vim.highlight.on_yank({ timeout = 200 }) end,
})
vim.api.nvim_create_autocmd("BufReadPost", {
  group = aug,
  callback = function()
    local m = vim.api.nvim_buf_get_mark(0, '"')
    if m[1] > 0 and m[1] <= vim.api.nvim_buf_line_count(0) then
      pcall(vim.api.nvim_win_set_cursor, 0, m)
    end
  end,
})

-- Optional plugin manager (lazy.nvim) -- uncomment to enable (needs network):
-- local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
-- if not (vim.uv or vim.loop).fs_stat(lazypath) then
--   vim.fn.system({ "git", "clone", "--filter=blob:none",
--     "https://github.com/folke/lazy.nvim.git", "--branch=stable", lazypath })
-- end
-- vim.opt.rtp:prepend(lazypath)
-- require("lazy").setup({ --[[ plugin specs here ]] })
NVIMCFG
    chown -R "$_own" "$_hd/.config" 2>/dev/null || true
    note "nvim: wrote $_cfg"
}
write_nvim /root root
[ -n "$TARGET_HOME" ] && write_nvim "$TARGET_HOME" "$TARGET_USER"

# ===========================================================================
log "tmux config"
# ===========================================================================
TMUX_MARKER="# AOK tmux.conf (provision-ultimate.sh)"
write_tmux() {  # <homedir> <owner>
    _hd="$1"; _own="$2"
    [ -n "$_hd" ] || return 0
    _cfg="$_hd/.tmux.conf"
    if [ -f "$_cfg" ] && ! grep -qF -e "$TMUX_MARKER" "$_cfg" 2>/dev/null; then
        note "tmux: keeping your existing $_cfg"
        return 0
    fi
    cat > "$_cfg" <<'TMUXCONF'
# AOK tmux.conf (provision-ultimate.sh)
# Minimal, portable tmux configuration.
#
# Enable mouse mode (tmux 2.1 and above)
set -g mouse on

setw -g mode-keys vi
# For system clipboard via X11/Wayland replace with: copy-pipe-and-cancel "xclip -selection clipboard"
bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-selection-and-cancel

# reload config file
bind r source-file ~/.tmux.conf

# split panes using | and -
bind | split-window -h
bind - split-window -v
unbind '"'
unbind %

# don't rename windows automatically
set-option -g allow-rename off

######################
### DESIGN CHANGES ###
######################

# loud or quiet?
set -g visual-activity off
set -g visual-bell off
set -g visual-silence off
setw -g monitor-activity off
set -g bell-action none

# modes
setw -g clock-mode-colour colour5
setw -g mode-style 'fg=colour1 bg=colour18 bold'

# panes
set -g pane-border-style 'fg=colour19 bg=colour0'
set -g pane-active-border-style 'bg=colour0 fg=colour9'

# statusbar
set -g status-position bottom
set -g status-justify left
set -g status-style 'bg=colour18 fg=colour137 dim'
set -g status-left ''
set -g status-right '#[fg=colour233,bg=colour19] %d/%m #[fg=colour233,bg=colour8] %H:%M:%S '
set -g status-right-length 50
set -g status-left-length 20

setw -g window-status-current-style 'fg=colour1 bg=colour19 bold'
setw -g window-status-current-format ' #I#[fg=colour249]:#[fg=colour255]#W#[fg=colour249]#F '

setw -g window-status-style 'fg=colour9 bg=colour18'
setw -g window-status-format ' #I#[fg=colour237]:#[fg=colour250]#W#[fg=colour244]#F '

setw -g window-status-bell-style 'fg=colour255 bg=colour1 bold'

# messages
set -g message-style 'fg=colour232 bg=colour16 bold'
TMUXCONF
    chown "$_own" "$_cfg" 2>/dev/null || true
    note "tmux: wrote $_cfg"
}
write_tmux /root root
[ -n "$TARGET_HOME" ] && write_tmux "$TARGET_HOME" "$TARGET_USER"

# ===========================================================================
log "Enable + start services"
# ===========================================================================
apply_svc() {  # <logical-name> <candidate>...
    _label="$1"; shift
    _svc="$(_svc_pick "$@")"
    [ -n "$_svc" ] || { note "  no service for $_label (skipped)"; return 0; }

    # Service managers are bounded too: a compatible-but-wedged launcher (an
    # iSH-AOK systemd shim, a hanging rc-script) must not freeze the whole run
    # at the last step. 124 = the limit fired.
    _svc_activate "$_svc"
    _svc_rc=$?
    [ "$_svc_rc" = 124 ] && warn "  $_label service call was terminated after its limit; configuration is complete but the service may not be running"
    note "  $_label -> $_svc"
}

if [ "${SKIP_SERVICES:-0}" = 1 ]; then
    note "service enable/start skipped (SKIP_SERVICES=1); configuration files were still written"
else
    # rsyslog first (so other daemons' early logs land), then user-facing daemons.
    apply_svc logging rsyslog syslog-ng socklog-unix
    apply_svc ssh ssh sshd
    apply_svc cron cron crond cronie
    apply_svc chrony chrony chronyd
fi

[ "${SKIP_SERVICES:-0}" = 1 ] || note "services enabled:"
case "$INIT_SYSTEM" in
    systemd) _rto 30 systemctl list-unit-files --state=enabled --type=service 2>/dev/null | grep -E '^(rsyslog|syslog-ng|ssh|sshd|cron|crond|chrony|chronyd)' | awk '{print "      " $1}' || true ;;
    openrc) _rto 30 rc-status default 2>/dev/null | sed 's/^/      /' || true ;;
    runit) ls /var/service 2>/dev/null | sed 's/^/      /' || true ;;
    *) ls /etc/rc2.d/ 2>/dev/null | sed -n 's/^S[0-9]*//p' | sort -u | sed 's/^/      /' || true ;;
esac

# ===========================================================================
log "Done"
# ===========================================================================
printf '    %s\n' "$(date)"
_milestone "provisioning finished"
note "Running services:"
case "$INIT_SYSTEM" in
    systemd) _rto 30 systemctl list-units --type=service --state=running 2>/dev/null | awk '/\.service/{sub(/\.service/,"",$1); printf "%s ",$1} END{print ""}' | sed 's/^/      /' ;;
    openrc) _rto 30 rc-status 2>/dev/null | sed -n '/started/s/^/      /p' || true ;;
    runit) _rto 30 sv status /var/service/* 2>/dev/null | sed 's/^/      /' || true ;;
    *) command -v service >/dev/null 2>&1 && _rto 30 service --status-all 2>&1 | grep -E '\[ \+ \]' | awk '{print $4}' | sort | tr '\n' ' ' | sed 's/^/      /' || true; echo ;;
esac

cat <<EOF

    Next:
      * Re-login (or relaunch the app) to pick up bash + the new prompt/MOTD
      * 'chronyc -h 127.0.0.1 tracking' / '... sources' to see NTP status
      * Service status (systemd): 'systemctl status <service>'
      * Service status (sysvinit): 'service --status-all'
      * Logs (systemd): 'journalctl -u <service>' or 'journalctl -f'
      * Logs (sysvinit): '/var/log/syslog'
EOF
