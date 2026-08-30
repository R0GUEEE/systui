# shellcheck shell=bash
# PHASE 64 — Bedrock-AOK host capability compatibility layer.
#
# This layer never claims a kernel feature exists when the host cannot provide
# it. It probes real syscall-backed capabilities, enables recoverable settings,
# installs missing userspace prerequisites when possible, and records explicit
# fallback modes for constrained runtimes such as iSH-AOK.

bedrock_aok_compat_has() { command -v "$1" >/dev/null 2>&1; }

bedrock_aok_compat_try_install_tools() {
    local -a pkgs=()
    bedrock_aok_compat_has mount && bedrock_aok_compat_has unshare || pkgs+=(util-linux)
    bedrock_aok_compat_has ip || pkgs+=(iproute2)
    bedrock_aok_compat_has ps || pkgs+=(procps)
    [ ${#pkgs[@]} -gt 0 ] || return 0

    if declare -F pm_install >/dev/null 2>&1; then
        pm_install "${pkgs[@]}" >/dev/null 2>&1 || true
        return 0
    fi

    case "${PM:-}" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}" >/dev/null 2>&1 || true ;;
        apk) apk add --no-progress "${pkgs[@]}" >/dev/null 2>&1 || true ;;
        pacman) pacman -S --noconfirm --needed "${pkgs[@]}" >/dev/null 2>&1 || true ;;
        dnf) dnf install -y "${pkgs[@]}" >/dev/null 2>&1 || true ;;
        yum) yum install -y "${pkgs[@]}" >/dev/null 2>&1 || true ;;
        zypper) zypper --non-interactive install "${pkgs[@]}" >/dev/null 2>&1 || true ;;
    esac
}

bedrock_aok_compat_probe_bind_mount() {
    bedrock_aok_compat_has mount && bedrock_aok_compat_has umount || return 1
    local d="${SYSTUI_TMP:-${TMPDIR:-/tmp}}/bedrock-cap-bind.$$"
    mkdir -p "$d/src" "$d/dst" || return 1
    : > "$d/src/probe"
    if mount --bind "$d/src" "$d/dst" >/dev/null 2>&1; then
        umount "$d/dst" >/dev/null 2>&1 || true
        rm -rf "$d"
        return 0
    fi
    rm -rf "$d"
    return 1
}

bedrock_aok_compat_probe_namespace() { # <unshare-flag>
    local flag="$1"
    bedrock_aok_compat_has unshare || return 1
    case "$flag" in
        --pid) unshare --pid --fork true >/dev/null 2>&1 ;;
        --user) unshare --user --map-root-user true >/dev/null 2>&1 ;;
        *) unshare "$flag" true >/dev/null 2>&1 ;;
    esac
}

bedrock_aok_compat_probe_seccomp() {
    [ -r /proc/self/status ] || return 1
    grep -q '^Seccomp:' /proc/self/status 2>/dev/null || return 1
    [ -e /proc/sys/kernel/seccomp/actions_avail ] || [ -d /proc/sys/kernel/seccomp ] || return 1
}

bedrock_aok_compat_probe_cgroup() {
    [ -d /sys/fs/cgroup ] || return 1
    [ -r /proc/self/cgroup ] || return 1
    return 0
}

bedrock_aok_compat_enable_userns() {
    local f
    f=/proc/sys/kernel/unprivileged_userns_clone
    if [ -w "$f" ]; then
        printf '1\n' > "$f" 2>/dev/null || true
    fi
    f=/proc/sys/user/max_user_namespaces
    if [ -r "$f" ] && [ -w "$f" ]; then
        local n
        read -r n < "$f" || n=0
        case "$n" in ''|*[!0-9]*) n=0 ;; esac
        [ "$n" -gt 0 ] || printf '1024\n' > "$f" 2>/dev/null || true
    fi
}

bedrock_aok_compat_enable_cgroup2() {
    [ -d /sys/fs/cgroup ] || mkdir -p /sys/fs/cgroup 2>/dev/null || return 0
    [ -r /proc/filesystems ] || return 0
    grep -qw cgroup2 /proc/filesystems 2>/dev/null || return 0
    grep -qE '[[:space:]]/sys/fs/cgroup[[:space:]]' /proc/mounts 2>/dev/null && return 0
    mount -t cgroup2 none /sys/fs/cgroup >/dev/null 2>&1 || true
}

bedrock_aok_compat_capability_state() { # <capability>
    case "$1" in
        bind_mount) bedrock_aok_compat_probe_bind_mount && printf 'native\n' || printf 'fallback\n' ;;
        mount_ns)   bedrock_aok_compat_probe_namespace --mount && printf 'native\n' || printf 'fallback\n' ;;
        user_ns)    bedrock_aok_compat_probe_namespace --user && printf 'native\n' || printf 'fallback\n' ;;
        pid_ns)     bedrock_aok_compat_probe_namespace --pid && printf 'native\n' || printf 'fallback\n' ;;
        net_ns)     bedrock_aok_compat_probe_namespace --net && printf 'native\n' || printf 'fallback\n' ;;
        ipc_ns)     bedrock_aok_compat_probe_namespace --ipc && printf 'native\n' || printf 'fallback\n' ;;
        cgroup_ns)  bedrock_aok_compat_probe_namespace --cgroup && printf 'native\n' || printf 'fallback\n' ;;
        cgroup)     bedrock_aok_compat_probe_cgroup && printf 'native\n' || printf 'fallback\n' ;;
        seccomp)    bedrock_aok_compat_probe_seccomp && printf 'native\n' || printf 'unsupported\n' ;;
        *) return 2 ;;
    esac
}

bedrock_aok_compat_fallback() { # <capability>
    case "$1" in
        bind_mount) printf 'symlink-crossfs\n' ;;
        mount_ns)   printf 'shared-host-mounts\n' ;;
        user_ns)    printf 'host-uid-map\n' ;;
        pid_ns)     printf 'host-pid-space\n' ;;
        net_ns)     printf 'host-network\n' ;;
        ipc_ns)     printf 'host-ipc\n' ;;
        cgroup_ns)  printf 'host-cgroup-namespace\n' ;;
        cgroup)     printf 'no-cgroup-isolation\n' ;;
        seccomp)    printf 'no-seccomp-filter\n' ;;
        *) printf 'none\n' ;;
    esac
}

bedrock_aok_compat_write_config() {
    local out cap state fallback runtime
    runtime="${SYSTUI_ENVIRONMENT:-unknown}"
    out="${1:-/etc/systui/bedrock-capabilities.conf}"
    mkdir -p "$(dirname "$out")" 2>/dev/null || return 1
    {
        printf 'schema=1\n'
        printf 'runtime=%s\n' "$runtime"
        for cap in bind_mount mount_ns user_ns pid_ns net_ns ipc_ns cgroup_ns cgroup seccomp; do
            state=$(bedrock_aok_compat_capability_state "$cap" 2>/dev/null || printf 'unsupported\n')
            fallback=$(bedrock_aok_compat_fallback "$cap")
            printf '%s=%s\n' "$cap" "$state"
            printf '%s_fallback=%s\n' "$cap" "$fallback"
        done
    } > "$out"
    chmod 0644 "$out" 2>/dev/null || true

    if [ -d /bedrock/etc ]; then
        cp -f "$out" /bedrock/etc/systui-compat.conf 2>/dev/null || true
        chmod 0644 /bedrock/etc/systui-compat.conf 2>/dev/null || true
    fi
}

bedrock_aok_compat_install_helper() {
    [ -d /bedrock/bin ] || return 0
    cat > /bedrock/bin/brl-capabilities <<'EOF'
#!/bin/sh
conf=/bedrock/etc/systui-compat.conf
[ -r "$conf" ] || conf=/etc/systui/bedrock-capabilities.conf
if [ ! -r "$conf" ]; then
    echo "Bedrock compatibility profile not generated." >&2
    exit 1
fi
cat "$conf"
EOF
    chmod 0755 /bedrock/bin/brl-capabilities 2>/dev/null || true
}

bedrock_aok_compat_prepare() {
    bedrock_aok_compat_try_install_tools
    bedrock_aok_compat_enable_userns
    bedrock_aok_compat_enable_cgroup2
    bedrock_aok_compat_write_config || true
}

bedrock_aok_compat_finalize() {
    bedrock_aok_compat_write_config || true
    bedrock_aok_compat_install_helper
}

bedrock_aok_compat_summary() {
    local cap state line=''
    for cap in bind_mount mount_ns user_ns pid_ns net_ns ipc_ns cgroup_ns cgroup seccomp; do
        state=$(bedrock_aok_compat_capability_state "$cap" 2>/dev/null || printf unsupported)
        line+="$cap=$state\n"
    done
    printf '%b' "$line"
}

# Install hook: prepare the host before Bedrock runs its installer, then refresh
# the profile after installation so /bedrock/etc receives the final capability
# state. Builtin function preservation avoids exec-time ARG_MAX pressure.
if declare -F bedrock_aok_install >/dev/null 2>&1 \
    && ! declare -F _systui_base_bedrock_aok_install_compat >/dev/null 2>&1; then
    _systui_bedrock_install_def=$(declare -f bedrock_aok_install)
    _systui_bedrock_install_def=${_systui_bedrock_install_def/#bedrock_aok_install ()/_systui_base_bedrock_aok_install_compat ()}
    eval "$_systui_bedrock_install_def"
    unset _systui_bedrock_install_def
fi

bedrock_aok_install() {
    bedrock_aok_compat_prepare
    local rc=0
    _systui_base_bedrock_aok_install_compat "$@" || rc=$?
    bedrock_aok_compat_finalize
    return "$rc"
}

export -n -f bedrock_aok_install _systui_base_bedrock_aok_install_compat 2>/dev/null || true
return 0 2>/dev/null || true
