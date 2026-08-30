#!/bin/bash
# Shared runtime analysis and distribution adapters for provision scripts.

_PROVISION_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)
[ -r "$_PROVISION_ROOT/src/core/platform.sh" ] && . "$_PROVISION_ROOT/src/core/platform.sh"
unset _PROVISION_ROOT

provision_analyze_system() {
    PROV_OS_ID=unknown PROV_OS_LIKE='' PROV_OS_NAME=unknown PROV_OS_VERSION=unknown
    local f k v
    for f in /etc/os-release /usr/lib/os-release; do
        [ -r "$f" ] || continue
        while IFS='=' read -r k v; do
            v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
            case "$k" in
                ID) PROV_OS_ID=$v ;;
                ID_LIKE) PROV_OS_LIKE=$v ;;
                PRETTY_NAME) PROV_OS_NAME=$v ;;
                VERSION_ID) PROV_OS_VERSION=$v ;;
            esac
        done < "$f"
        break
    done
    PROV_ARCH=$(uname -m 2>/dev/null || echo unknown)
    PROV_KERNEL=$(uname -s 2>/dev/null || echo unknown)
    PROV_CONTAINER=0
    if declare -F systui_is_container >/dev/null 2>&1 && systui_is_container; then PROV_CONTAINER=1; fi
    PROV_CHROOT=0
    [ -r /proc/1/root ] && [ "$(stat -c %d:%i / 2>/dev/null)" != "$(stat -Lc %d:%i /proc/1/root 2>/dev/null)" ] && PROV_CHROOT=1

    if declare -F systui_detect_init >/dev/null 2>&1; then
        systui_detect_init
        PROV_INIT=${INIT:-none}
        PROV_INIT_PROVIDER=${SYSTUI_INIT_PROVIDER:-unknown}
        PROV_SERVICE_RUNTIME=${SYSTUI_SERVICE_RUNTIME:-none}
    elif command -v rc-service >/dev/null 2>&1; then PROV_INIT=openrc; PROV_INIT_PROVIDER=openrc; PROV_SERVICE_RUNTIME=openrc
    elif command -v sv >/dev/null 2>&1; then PROV_INIT=runit; PROV_INIT_PROVIDER=runit; PROV_SERVICE_RUNTIME=runit
    elif command -v service >/dev/null 2>&1; then PROV_INIT=sysvinit; PROV_INIT_PROVIDER=sysvinit; PROV_SERVICE_RUNTIME=sysvinit
    else PROV_INIT=none; PROV_INIT_PROVIDER=unknown; PROV_SERVICE_RUNTIME=none; fi

    if command -v apk >/dev/null 2>&1; then PROV_PM=apk
    elif command -v apt-get >/dev/null 2>&1; then PROV_PM=apt
    elif command -v pacman >/dev/null 2>&1; then PROV_PM=pacman
    elif command -v dnf >/dev/null 2>&1; then PROV_PM=dnf
    elif command -v yum >/dev/null 2>&1; then PROV_PM=yum
    elif command -v xbps-install >/dev/null 2>&1; then PROV_PM=xbps
    elif command -v zypper >/dev/null 2>&1; then PROV_PM=zypper
    elif command -v emerge >/dev/null 2>&1; then PROV_PM=portage
    else PROV_PM=unknown; fi
    export PROV_OS_ID PROV_OS_LIKE PROV_OS_NAME PROV_OS_VERSION PROV_ARCH PROV_KERNEL PROV_CONTAINER PROV_CHROOT PROV_INIT PROV_INIT_PROVIDER PROV_SERVICE_RUNTIME PROV_PM
}

provision_family_matches() {
    local expected="$1" all=" $PROV_OS_ID $PROV_OS_LIKE "
    case "$expected" in
        alpine) [[ "$all" == *" alpine "* ]] ;;
        archlinux) [[ "$all" == *" arch "* || "$all" == *" archlinux "* ]] ;;
        debian) [[ "$all" == *" debian "* || "$all" == *" ubuntu "* ]] && [[ "$PROV_OS_ID" != devuan ]] ;;
        devuan) [ "$PROV_OS_ID" = devuan ] || [[ "$all" == *" devuan "* ]] ;;
        *) return 1 ;;
    esac
}

provision_require_family() {
    local expected="$1"
    provision_analyze_system
    log "System analysis: ${PROV_OS_NAME} (${PROV_OS_ID} ${PROV_OS_VERSION}), arch=${PROV_ARCH}, init=${PROV_INIT}, runtime=${PROV_SERVICE_RUNTIME}, package-manager=${PROV_PM}, container=${PROV_CONTAINER}, chroot=${PROV_CHROOT}"
    provision_family_matches "$expected" || {
        log "ERROR: This template targets $expected but detected ${PROV_OS_ID} (${PROV_OS_LIKE:-no ID_LIKE})."
        return 2
    }
}

provision_service_enable_start() {
    local service_name="$1" boot_name="${2:-$1}" rc=0
    [ "$PROV_CHROOT" = 1 ] && return 0
    case "${PROV_SERVICE_RUNTIME:-$PROV_INIT}" in
        systemd)
            systemctl enable "$service_name" >/dev/null 2>&1 || rc=$?
            systemctl restart "$service_name" >/dev/null 2>&1 || systemctl start "$service_name" >/dev/null 2>&1 || rc=$?
            ;;
        init-script)
            if command -v systemctl >/dev/null 2>&1; then systemctl enable "$service_name" >/dev/null 2>&1 || true; fi
            if [ -x "/etc/init.d/$boot_name" ]; then "/etc/init.d/$boot_name" restart >/dev/null 2>&1 || "/etc/init.d/$boot_name" start >/dev/null 2>&1 || rc=$?
            elif command -v service >/dev/null 2>&1; then service "$boot_name" restart >/dev/null 2>&1 || service "$boot_name" start >/dev/null 2>&1 || rc=$?
            else rc=1; fi
            ;;
        openrc)
            rc-update add "$boot_name" default >/dev/null 2>&1 || rc=$?
            rc-service "$boot_name" restart >/dev/null 2>&1 || rc-service "$boot_name" start >/dev/null 2>&1 || rc=$?
            ;;
        runit)
            [ -d "/etc/sv/$boot_name" ] && { mkdir -p /var/service; ln -sfn "/etc/sv/$boot_name" "/var/service/$boot_name"; }
            sv restart "$boot_name" >/dev/null 2>&1 || sv up "$boot_name" >/dev/null 2>&1 || rc=$?
            ;;
        sysvinit)
            update-rc.d "$boot_name" defaults >/dev/null 2>&1 || update-rc.d "$boot_name" enable >/dev/null 2>&1 || rc=$?
            service "$boot_name" restart >/dev/null 2>&1 || service "$boot_name" start >/dev/null 2>&1 || rc=$?
            ;;
        *) rc=1 ;;
    esac
    [ "$rc" -eq 0 ] || log "WARN: service activation failed for $service_name (runtime=${PROV_SERVICE_RUNTIME:-$PROV_INIT}, rc=$rc)"
    return "$rc"
}

provision_add_packages_available() {
    local p
    case "$PROV_PM" in
        apt)
            apt-get update || return 1
            for p in "$@"; do apt-cache show "$p" >/dev/null 2>&1 && apt-get install -y --no-install-recommends "$p" || log "Skipping unavailable package: $p"; done ;;
        apk) for p in "$@"; do apk search -e "$p" >/dev/null 2>&1 && apk add --no-progress "$p" || log "Skipping unavailable package: $p"; done ;;
        pacman) for p in "$@"; do pacman -Si "$p" >/dev/null 2>&1 && pacman -S --needed --noconfirm "$p" || log "Skipping unavailable package: $p"; done ;;
        dnf) for p in "$@"; do dnf info "$p" >/dev/null 2>&1 && dnf install -y "$p" || log "Skipping unavailable package: $p"; done ;;
        yum) for p in "$@"; do yum info "$p" >/dev/null 2>&1 && yum install -y "$p" || log "Skipping unavailable package: $p"; done ;;
        zypper) for p in "$@"; do zypper search -e "$p" >/dev/null 2>&1 && zypper --non-interactive install "$p" || log "Skipping unavailable package: $p"; done ;;
        xbps) for p in "$@"; do xbps-query -Rs "$p" >/dev/null 2>&1 && xbps-install -y "$p" || log "Skipping unavailable package: $p"; done ;;
        portage) for p in "$@"; do emerge --info "$p" >/dev/null 2>&1 && emerge -v "$p" || log "Skipping unavailable package: $p"; done ;;
        *) log "provision_add_packages_available: unsupported PROV_PM=$PROV_PM, skipping: $*"; return 1 ;;
    esac
}

provision_configure_sshd() {
    local port="$1" root_login="$2" x11="${3:-no}" cfg=/etc/ssh/sshd_config
    local dropin_dir=/etc/ssh/sshd_config.d dropin="$dropin_dir/20-systui.conf" root_policy backup
    case "$port" in ''|*[!0-9]*) log "ERROR: refusing invalid sshd port: $port"; return 1;; esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    [ -f "$cfg" ] || { log "ERROR: $cfg does not exist"; return 1; }
    [ "$root_login" = 1 ] && root_policy=yes || root_policy=no
    mkdir -p "$dropin_dir" || return 1
    chmod 0755 "$dropin_dir" 2>/dev/null || true
    if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$cfg"; then
        backup="$cfg.systui.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$cfg" "$backup" || return 1
        { printf 'Include /etc/ssh/sshd_config.d/*.conf\n\n'; cat "$cfg"; } > "$cfg.systui.new" || return 1
        cat "$cfg.systui.new" > "$cfg" && rm -f "$cfg.systui.new"
        if command -v sshd >/dev/null 2>&1 && ! sshd -t 2>/dev/null; then
            cat "$backup" > "$cfg"
            provision_configure_sshd_inplace "$port" "$root_policy" "$x11"
            return $?
        fi
    fi
    cat > "$dropin" <<EOF
# Managed by systui.
Port $port
PermitRootLogin $root_policy
PasswordAuthentication yes
PubkeyAuthentication yes
X11Forwarding $x11
StrictModes yes
ClientAliveInterval 300
EOF
    chmod 0644 "$dropin" || true
    if command -v sshd >/dev/null 2>&1 && ! sshd -t 2>>"${LOGFILE:-/dev/null}"; then rm -f "$dropin"; return 1; fi
}

provision_configure_sshd_inplace() {
    local port="$1" root_policy="$2" x11="$3" cfg=/etc/ssh/sshd_config key value pair
    set -- "Port:$port" "PermitRootLogin:$root_policy" "PasswordAuthentication:yes" "X11Forwarding:$x11" "StrictModes:yes" "ClientAliveInterval:300"
    for pair in "$@"; do
        key=${pair%%:*}; value=${pair#*:}
        if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]" "$cfg"; then
            sed -i "0,/^[[:space:]]*#\{0,1\}[[:space:]]*${key}[[:space:]].*/s//${key} ${value}/" "$cfg"
        else
            printf '%s %s\n' "$key" "$value" >> "$cfg"
        fi
    done
    command -v sshd >/dev/null 2>&1 && ! sshd -t 2>>"${LOGFILE:-/dev/null}" && return 1
    return 0
}

# Configuration is DATA, never executable shell. Accepted syntax is KEY=VALUE,
# blank lines, and comments. Only conservative variable names are accepted.
provision_load_config() {
    local file="$1" line key value
    [ -n "$file" ] && [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue;; esac
        case "$line" in *=*) key=${line%%=*}; value=${line#*=};; *) log "WARN: ignoring malformed config line: $line"; continue;; esac
        case "$key" in
            [A-Za-z_]* ) ;;
            *) log "WARN: ignoring invalid config key: $key"; continue;;
        esac
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { log "WARN: ignoring invalid config key: $key"; continue; }
        case "$key" in
            LOGFILE|WARNFILE|SYSTUI_TMP|SYSTUI_TMP_ROOT|SYSTUI_LIBDIR|PATH|IFS|PM|INIT|DISTRO|DISTRO_*|PROV_PM|PROV_INIT|PROV_OS_ID)
                log "WARN: refusing protected config key: $key"; continue ;;
        esac
        printf -v "$key" '%s' "$value"
    done < "$file"
    return 0
}
