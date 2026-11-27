# shellcheck shell=bash
###############################################################################
# CONTAINER & VIRTUALIZATION SUPPORT — shared core
#
# One place that knows how to install, configure, start and inspect the
# container runtimes the rest of systui depends on:
#
#   docker (Engine + containerd + compose + buildx)   podman (+ rootless)
#   nerdctl/containerd                               lxc / lxd / incus
#   libvirt + qemu/KVM                               waydroid
#   apptainer/singularity                            bubblewrap
#   systemd-nspawn (machinectl)                       udocker
#
# Everything the menus write is stored in systui's own config file under
# `cn_` keys and rendered into the tool's native file, so a setting is never
# lost when the distribution package is upgraded. Rendered files honour the
# SYSTUI_*_FILE environment overrides so tests never touch /etc.
#
# The Rootfs > Distro managers menu uses cn_ensure_engine/cn_engine_ready to
# satisfy the runtimes that distrobox, Toolbx, waydroid and the container
# images need; Rootfs > Containers & virtualization is the full front door.
###############################################################################

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

cn_conf_get() { # <key> [default]
    get_config "cn_$1" "${2:-}"
}

cn_conf_set() { # <key> <value>
    set_config "cn_$1" "$2"
}

cn_bool() { # <value> -> true|false
    case "${1:-}" in
        1|yes|true|on|enabled) printf 'true\n' ;;
        *) printf 'false\n' ;;
    esac
}

cn_is_true() { # <value>
    case "${1:-}" in 1|yes|true|on|enabled) return 0 ;; *) return 1 ;; esac
}

# Split a comma/space separated list into normalized, de-duplicated entries.
cn_split_list() { # <string>
    printf '%s' "${1:-}" | tr ',;' '  ' | tr -s ' \t' '\n' |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d' | awk '!seen[$0]++'
}

cn_json_escape() { # stdin -> escaped for a JSON string
    sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/ /g'
}

cn_json_string_array() { # <list> <indent> -> ["a", "b"] or empty
    local list="$1" indent="${2:-  }" item out="" sep=""
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        out="$out$sep$indent  \"$(printf '%s' "$item" | cn_json_escape)\""
        sep=",
"
    done <<< "$(cn_split_list "$list")"
    [ -n "$out" ] || return 1
    printf '[%s
%s]' "
$out" "$indent"
}

cn_valid_bool() { case "${1:-}" in true|false|1|0|yes|no|on|off) return 0 ;; *) return 1 ;; esac; }

cn_valid_path() { # <path>
    case "${1:-}" in
        /*) printf '%s' "$1" | grep -Eq '^/[A-Za-z0-9._/@:+-]+$' ;;
        *) return 1 ;;
    esac
}

cn_valid_cidr() { printf '%s' "${1:-}" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'; }

cn_valid_host_port() { printf '%s' "${1:-}" | grep -Eq '^[A-Za-z0-9._:-]+(:[0-9]{1,5})?$'; }

cn_valid_driver() { # <engine> <driver>
    case "$1:${2:-}" in
        docker:overlay2|docker:overlay|docker:aufs|docker:btrfs|docker:zfs|docker:vfs|docker:devicemapper) return 0 ;;
        podman:overlay|podman:fuse-overlayfs|podman:vfs|podman:btrfs|podman:zfs) return 0 ;;
        *) return 1 ;;
    esac
}

cn_require_dialog() {
    command -v "${DIALOG:-dialog}" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Native file locations (overridable for tests and unusual installations)
# ---------------------------------------------------------------------------

cn_docker_daemon_file() {
    printf '%s\n' "${SYSTUI_DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"
}

cn_registries_file() {
    printf '%s\n' "${SYSTUI_REGISTRIES_CONF:-/etc/containers/registries.conf}"
}

cn_containers_conf_file() {
    printf '%s\n' "${SYSTUI_CONTAINERS_CONF:-/etc/containers/containers.conf}"
}

cn_storage_conf_file() {
    printf '%s\n' "${SYSTUI_STORAGE_CONF:-/etc/containers/storage.conf}"
}

cn_lxc_conf_file() { printf '%s\n' "${SYSTUI_LXC_CONF:-/etc/lxc/default.conf}"; }

cn_write_file() { # <path> <content-stdin> [mode]
    local path="$1" mode="${2:-0644}" tmp
    mkdir -p "$(dirname "$path")" 2>/dev/null || return 1
    tmp="$path.systui.$$"
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod "$mode" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$path"
}

# ---------------------------------------------------------------------------
# Rendering the native configuration files
# ---------------------------------------------------------------------------

# daemon.json is generated from the cn_docker_* settings. The JSON is written
# by hand rather than parsed: no jq/python dependency on a minimal iSH host,
# and every value is escaped by cn_json_escape before it is emitted.
cn_write_docker_daemon() {
    local file out="" sep="" size files rendered base psize k v gen
    file=$(cn_docker_daemon_file)
    gen="$SYSTUI_TMP/daemon.json.$$"

    {
        cn_json_pair() { # <name> <value>   (value already JSON)
            out="$out$sep  \"$1\": $2"
            sep=",
"
        }

        v=$(cn_conf_get docker_data_root)
        [ -n "$v" ] && cn_json_pair data-root "\"$(printf '%s' "$v" | cn_json_escape)\""
        v=$(cn_conf_get docker_storage_driver)
        [ -n "$v" ] && cn_json_pair storage-driver "\"$(printf '%s' "$v" | cn_json_escape)\""
        v=$(cn_conf_get docker_log_driver)
        if [ -n "$v" ]; then
            cn_json_pair log-driver "\"$(printf '%s' "$v" | cn_json_escape)\""
            size=$(cn_conf_get docker_log_max_size "10m")
            files=$(cn_conf_get docker_log_max_file "3")
            cn_json_pair log-opts "{
    \"max-size\": \"$(printf '%s' "$size" | cn_json_escape)\",
    \"max-file\": \"$(printf '%s' "$files" | cn_json_escape)\"
  }"
        fi
        if rendered=$(cn_json_string_array "$(cn_conf_get docker_registry_mirrors)" "  "); then
            cn_json_pair registry-mirrors "$rendered"
        fi
        if rendered=$(cn_json_string_array "$(cn_conf_get docker_insecure_registries)" "  "); then
            cn_json_pair insecure-registries "$rendered"
        fi
        if rendered=$(cn_json_string_array "$(cn_conf_get docker_dns)" "  "); then
            cn_json_pair dns "$rendered"
        fi
        base=$(cn_conf_get docker_pool_base)
        psize=$(cn_conf_get docker_pool_size "24")
        if [ -n "$base" ]; then
            cn_json_pair default-address-pools "[
    {
      \"base\": \"$(printf '%s' "$base" | cn_json_escape)\",
      \"size\": $psize
    }
  ]"
        fi
        for k in live_restore iptables ip6tables userland_proxy experimental; do
            v=$(cn_conf_get "docker_$k" "")
            [ -n "$v" ] || continue
            case "$k" in
                live_restore) cn_json_pair live-restore "$(cn_bool "$v")" ;;
                iptables) cn_json_pair iptables "$(cn_bool "$v")" ;;
                ip6tables) cn_json_pair ip6tables "$(cn_bool "$v")" ;;
                userland_proxy) cn_json_pair userland-proxy "$(cn_bool "$v")" ;;
                experimental) cn_json_pair experimental "$(cn_bool "$v")" ;;
            esac
        done
        v=$(cn_conf_get docker_userns_remap)
        [ -n "$v" ] && cn_json_pair userns-remap "\"$(printf '%s' "$v" | cn_json_escape)\""
        v=$(cn_conf_get docker_builder_gc)
        [ -n "$v" ] && cn_json_pair builder "[{ \"gc\": { \"enabled\": true, \"defaultKeepStorage\": \"$(printf '%s' "$v" | cn_json_escape)\" } }]"

        printf '{
%s
}
' "$out"
    } > "$gen" || { rm -f "$gen"; return 1; }

    unset -f cn_json_pair
    cn_write_file "$file" 0644 < "$gen" || { rm -f "$gen"; return 1; }
    rm -f "$gen"
    log "container: wrote $file"
}

cn_write_registries_conf() {
    local file out mirrors insecure entry
    file=$(cn_registries_file)
    mirrors=$(cn_conf_get podman_registry_mirrors)
    insecure=$(cn_conf_get podman_insecure_registries)
    {
        echo '# Managed by systui — Container & virtualization.'
        echo '# Edit through systui so the file is not silently regenerated.'
        local -a search=()
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            search+=("\"$entry\"")
        done <<< "$(cn_split_list "$(cn_conf_get podman_search_registries "docker.io quay.io ghcr.io")")"
        printf 'unqualified-search-registries = [%s]\n' "$(printf '%s, ' "${search[@]}" | sed 's/, $//')"
        echo 'short-name-mode = "enforcing"'
        echo
        if [ -n "$(cn_split_list "$mirrors")" ]; then
            echo '# Registry mirrors for docker.io'
            echo '[[registry]]'
            echo 'prefix = "docker.io"'
            echo 'location = "docker.io"'
            while IFS= read -r entry; do
                [ -n "$entry" ] || continue
                echo '[[registry.mirror]]'
                printf 'location = "%s"\n' "$entry"
                echo 'insecure = false'
            done <<< "$(cn_split_list "$mirrors")"
            echo
        fi
        if [ -n "$(cn_split_list "$insecure")" ]; then
            while IFS= read -r entry; do
                [ -n "$entry" ] || continue
                echo '# Insecure (plain HTTP / untrusted TLS) registry'
                echo '[[registry]]'
                printf 'prefix = "%s"\n' "$entry"
                printf 'location = "%s"\n' "$entry"
                echo 'insecure = true'
                echo
            done <<< "$(cn_split_list "$insecure")"
        fi
    } > "$file.tmp.$$" 2>/dev/null || return 1
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    mv -f "$file.tmp.$$" "$file" || return 1
    chmod 0644 "$file" 2>/dev/null || true
    log "container: wrote $file"
}

cn_write_containers_conf() {
    local file runtime cgroup subnet
    file=$(cn_containers_conf_file)
    runtime=$(cn_conf_get podman_runtime "crun")
    cgroup=$(cn_conf_get podman_cgroup "systemd")
    subnet=$(cn_conf_get podman_subnet)
    {
        echo '# Managed by systui — Container & virtualization.'
        echo '[containers]'
        printf 'default_capabilities = [%s]\n' "$(printf '%s' '"CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "NET_BIND_SERVICE", "SETFCAP", "SETGID", "SETPCAP", "SETUID", "SYS_CHROOT"')"
        echo 'log_driver = "k8s-file"'
        echo 'log_size_max = 10485760'
        echo
        echo '[engine]'
        printf 'runtime = "%s"\n' "$runtime"
        printf 'cgroup_manager = "%s"\n' "$cgroup"
        echo 'events_logger = "file"'
        echo 'num_locks = 2048'
        echo
        echo '[network]'
        [ -n "$subnet" ] && printf 'default_subnet = "%s"\n' "$subnet"
        echo 'default_network = "podman"'
    } > "$file.tmp.$$" 2>/dev/null || return 1
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    mv -f "$file.tmp.$$" "$file" || return 1
    chmod 0644 "$file" 2>/dev/null || true
    log "container: wrote $file"
}

cn_write_storage_conf() {
    local file driver graphroot
    file=$(cn_storage_conf_file)
    driver=$(cn_conf_get podman_storage_driver "overlay")
    graphroot=$(cn_conf_get podman_graphroot "/var/lib/containers/storage")
    {
        echo '# Managed by systui — Container & virtualization.'
        echo '[storage]'
        printf 'driver = "%s"\n' "$driver"
        printf 'graphroot = "%s"\n' "$graphroot"
        printf 'runroot = "%s"\n' "$(cn_conf_get podman_runroot "/run/containers/storage")"
        echo 'transient_store = true'
        echo
        echo '[storage.options.overlay]'
        printf 'mount_program = "%s"\n' "$(cn_conf_get podman_mount_program "/usr/bin/fuse-overlayfs")"
    } > "$file.tmp.$$" 2>/dev/null || return 1
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    mv -f "$file.tmp.$$" "$file" || return 1
    chmod 0644 "$file" 2>/dev/null || true
    log "container: wrote $file"
}

cn_apply_engine_config() { # <docker|podman|all>
    local rc=0
    case "${1:-all}" in
        docker) cn_write_docker_daemon || rc=1 ;;
        podman) cn_write_registries_conf || rc=1; cn_write_containers_conf || rc=1; cn_write_storage_conf || rc=1 ;;
        *) cn_write_docker_daemon || rc=1
           cn_write_registries_conf || rc=1
           cn_write_containers_conf || rc=1
           cn_write_storage_conf || rc=1 ;;
    esac
    return "$rc"
}

cn_config_summary() {
    local m
    m=$(cn_split_list "$(cn_conf_get docker_registry_mirrors)" | tr '\n' ' ')
    printf 'mirrors: %s\n' "${m:-none}"
    printf 'docker data-root: %s\n' "$(cn_conf_get docker_data_root /var/lib/docker)"
    printf 'docker driver: %s\n' "$(cn_conf_get docker_storage_driver overlay2)"
    printf 'podman root: %s\n' "$(cn_conf_get podman_graphroot /var/lib/containers/storage)"
    printf 'podman driver: %s\n' "$(cn_conf_get podman_storage_driver overlay)"
    printf 'rootless user: %s\n' "$(cn_conf_get rootless_user none)"
}

# ---------------------------------------------------------------------------
# Tool catalogue
# ---------------------------------------------------------------------------

# tag|binary|label|kind   (kind: engine = container runtime, virt = machine,
#                            sandbox = isolated userspace, front = frontend)
cn_tools() {
    printf '%s\n' \
        'docker|docker|Docker Engine — images, containers, compose, buildx|engine' \
        'podman|podman|Podman — daemonless containers, rootless by default|engine' \
        'containerd|nerdctl|containerd + nerdctl — Kubernetes-style runtime|engine' \
        'lxc|lxc-create|LXC — system containers from distribution templates|engine' \
        'lxd|lxd|LXD — LXC with an API daemon (snap/packages)|engine' \
        'incus|incus|Incus — community fork of LXD|engine' \
        'libvirt|virsh|libvirt + QEMU/KVM — full virtual machines|virt' \
        'waydroid|waydroid|Waydroid — Android in an LXC container|engine' \
        'apptainer|apptainer|Apptainer/Singularity — HPC image runtime|sandbox' \
        'bwrap|bwrap|bubblewrap — unprivileged sandboxing|sandbox' \
        'nspawn|machinectl|systemd-nspawn — namespace machines (machinectl)|virt' \
        'udocker|udocker|udocker — Docker images without root or daemon|front'
}

cn_tool_bin() { # <tag>
    cn_tools | awk -F'|' -v t="$1" '$1 == t { print $2; exit }'
}

cn_tool_label() { # <tag>
    cn_tools | awk -F'|' -v t="$1" '$1 == t { print $3; exit }'
}

cn_tool_installed() { # <tag>
    local bin
    bin=$(cn_tool_bin "$1") || return 1
    [ -n "$bin" ] || return 1
    command -v "$bin" >/dev/null 2>&1
}

cn_tool_version() { # <tag>
    local bin
    bin=$(cn_tool_bin "$1") || return 1
    command -v "$bin" >/dev/null 2>&1 || { printf 'not installed\n'; return 0; }
    case "$1" in
        docker) docker --version 2>/dev/null | head -1 ;;
        podman) podman --version 2>/dev/null | head -1 ;;
        containerd) nerdctl --version 2>/dev/null | head -1 ;;
        lxc) lxc-create --version 2>/dev/null | head -1 ;;
        lxd) lxd --version 2>/dev/null | head -1 ;;
        incus) incus --version 2>/dev/null | head -1 ;;
        libvirt) virsh --version 2>/dev/null | sed 's/^/libvirt /' ;;
        waydroid) waydroid --version 2>/dev/null | head -1 ;;
        apptainer) apptainer --version 2>/dev/null | head -1 ;;
        bwrap) bwrap --version 2>/dev/null | head -1 ;;
        nspawn) systemctl --version 2>/dev/null | head -1 ;;
        udocker) udocker --version 2>/dev/null | head -1 ;;
        *) printf 'installed\n' ;;
    esac
}

# Package names per distribution. Returns one package per line; the caller
# installs them as a single transaction where possible.
cn_tool_packages() { # <tag>
    local tag="$1" pm="${PM:-}"
    case "$tag" in
        docker)
            case "$pm" in
                apt) printf '%s\n' docker.io docker-compose-v2 docker-buildx ;;
                apk) printf '%s\n' docker docker-cli-compose docker-cli-buildx ;;
                pacman) printf '%s\n' docker docker-compose docker-buildx ;;
                dnf|yum) printf '%s\n' docker docker-compose-plugin ;;
                zypper) printf '%s\n' docker docker-compose ;;
                xbps) printf '%s\n' docker docker-compose ;;
                emerge) printf '%s\n' app-containers/docker app-containers/docker-compose ;;
            esac ;;
        podman)
            case "$pm" in
                apt) printf '%s\n' podman podman-compose uidmap slirp4netns fuse-overlayfs ;;
                apk) printf '%s\n' podman podman-compose shadow-uidmap slirp4netns fuse-overlayfs ;;
                pacman) printf '%s\n' podman podman-compose shadow slirp4netns fuse-overlayfs ;;
                dnf|yum) printf '%s\n' podman podman-compose shadow-utils slirp4netns fuse-overlayfs ;;
                zypper) printf '%s\n' podman podman-compose shadow slirp4netns fuse-overlayfs ;;
                xbps) printf '%s\n' podman podman-compose shadow slirp4netns fuse-overlayfs ;;
                emerge) printf '%s\n' app-containers/podman app-containers/podman-compose ;;
            esac ;;
        containerd)
            case "$pm" in
                apt) printf '%s\n' containerd nerdctl ;;
                apk) printf '%s\n' containerd nerdctl ;;
                pacman) printf '%s\n' containerd nerdctl ;;
                dnf|yum) printf '%s\n' containerd nerdctl ;;
                zypper) printf '%s\n' containerd nerdctl ;;
                xbps) printf '%s\n' containerd nerdctl ;;
                emerge) printf '%s\n' app-containers/containerd app-containers/nerdctl ;;
            esac ;;
        lxc)
            case "$pm" in
                apt) printf '%s\n' lxc lxc-templates debootstrap ;;
                apk) printf '%s\n' lxc lxc-templates ;;
                pacman) printf '%s\n' lxc ;;
                dnf|yum) printf '%s\n' lxc lxc-templates ;;
                zypper) printf '%s\n' lxc lxc-templates ;;
                xbps) printf '%s\n' lxc ;;
                emerge) printf '%s\n' app-containers/lxc ;;
            esac ;;
        lxd)
            case "$pm" in
                apt) printf '%s\n' lxd-installer ;;
                pacman) printf '%s\n' lxd ;;
                dnf|yum) printf '%s\n' lxd ;;
                zypper) printf '%s\n' lxd ;;
                emerge) printf '%s\n' app-containers/lxd ;;
            esac ;;
        incus)
            case "$pm" in
                apt) printf '%s\n' incus ;;
                pacman) printf '%s\n' incus ;;
                dnf|yum) printf '%s\n' incus ;;
                zypper) printf '%s\n' incus ;;
                emerge) printf '%s\n' app-containers/incus ;;
            esac ;;
        libvirt)
            case "$pm" in
                apt) printf '%s\n' qemu-system-x86 qemu-utils libvirt-daemon-system virtinst bridge-utils ;;
                apk) printf '%s\n' qemu-system-x86_64 qemu-img libvirt virt-install bridge-utils ;;
                pacman) printf '%s\n' qemu-full libvirt virt-install bridge-utils dnsmasq ;;
                dnf|yum) printf '%s\n' qemu-kvm libvirt virt-install bridge-utils ;;
                zypper) printf '%s\n' qemu-kvm libvirt virt-install bridge-utils ;;
                xbps) printf '%s\n' qemu libvirt virt-install ;;
                emerge) printf '%s\n' app-emulation/qemu app-emulation/libvirt app-emulation/virt-install ;;
            esac ;;
        waydroid)
            case "$pm" in
                apt) printf '%s\n' waydroid ;;
                pacman) printf '%s\n' waydroid ;;
            esac ;;
        apptainer)
            case "$pm" in
                apt|apk|pacman|dnf|yum|zypper) printf '%s\n' apptainer ;;
                emerge) printf '%s\n' app-containers/apptainer ;;
            esac ;;
        bwrap)
            case "$pm" in
                apt|apk|pacman|dnf|yum|zypper|xbps) printf '%s\n' bubblewrap ;;
                emerge) printf '%s\n' sys-apps/bubblewrap ;;
            esac ;;
        nspawn)
            case "$pm" in
                apt|dnf|yum) printf '%s\n' systemd-container ;;
                apk|pacman|zypper|xbps) printf '%s\n' systemd ;;
                emerge) printf '%s\n' sys-apps/systemd ;;
            esac ;;
        udocker)
            case "$pm" in
                apt) printf '%s\n' udocker ;;
            esac ;;
    esac | sed '/^$/d'
}

cn_package_available() { # <package>
    local pkg="$1"
    [ -n "$pkg" ] || return 1
    case "${PM:-}" in
        apt) command -v apt-cache >/dev/null 2>&1 && apt-cache show "$pkg" >/dev/null 2>&1 ;;
        apk) apk search -e "$pkg" 2>/dev/null | grep -q . ;;
        pacman) pacman -Si "$pkg" >/dev/null 2>&1 ;;
        dnf) dnf -q list --available "$pkg" >/dev/null 2>&1 ;;
        yum) yum -q list available "$pkg" >/dev/null 2>&1 ;;
        zypper) zypper --non-interactive search --match-exact "$pkg" 2>/dev/null | grep -Eq "(^|[|[:space:]])${pkg}([|[:space:]]|$)" ;;
        xbps) xbps-query -Rs "^${pkg}-[0-9]" 2>/dev/null | grep -q . ;;
        emerge) command -v emerge >/dev/null 2>&1 && emerge --search "$pkg" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

# Install every package the tool needs, skipping names the current
# distribution does not carry instead of failing the whole transaction.
cn_install_packages() { # <packages...>
    local pkg
    local -a ok=()
    for pkg in "$@"; do
        [ -n "$pkg" ] || continue
        if [ "${PM:-}" != apt ] || cn_package_available "$pkg"; then
            ok+=("$pkg")
        else
            log "container: $pkg is not in the apt repositories, skipping"
        fi
    done
    [ "${#ok[@]}" -gt 0 ] || return 1
    pm_install "${ok[@]}"
}

cn_upstream_install() { # <tag>
    local tmp prefix arch
    prefix=$(get_config dm_install_prefix /usr/local)
    case "$1" in
        docker)
            command -v curl >/dev/null 2>&1 || pm_install curl || return 1
            run_cmd "Install Docker Engine from get.docker.com" sh -c \
                'curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh' || return 1
            mkdir -p /usr/local/lib/docker/cli-plugins
            run_cmd "Install the docker compose plugin" sh -c \
                'curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/lib/docker/cli-plugins/docker-compose' || true
            chmod 0755 /usr/local/lib/docker/cli-plugins/docker-compose 2>/dev/null || true
            ;;
        containerd)
            command -v curl >/dev/null 2>&1 || pm_install curl || return 1
            arch=$(uname -m)
            case "$arch" in aarch64|arm64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; esac
            tmp="${SYSTUI_TMP:-${TMPDIR:-/tmp}}/nerdctl.tgz"
            run_cmd "Download nerdctl" curl -fsSL \
                "https://github.com/containerd/nerdctl/releases/latest/download/nerdctl-full-latest-linux-$arch.tar.gz" \
                -o "$tmp" || return 1
            command -v tar >/dev/null 2>&1 || pm_install tar || return 1
            mkdir -p "$prefix"
            run_cmd "Install nerdctl-full" tar -C "$prefix" -xzf "$tmp" || return 1
            rm -f "$tmp"
            ;;
        lxd)
            command -v snap >/dev/null 2>&1 || {
                tui_msg "LXD needs snap or a package" \
"LXD is not packaged for this distribution.

Install snapd and run: snap install lxd
or use Incus, which packages LXD's feature set natively."
                return 1
            }
            run_cmd "Install LXD with snap" snap install lxd --channel=latest/stable || return 1
            ;;
        incus)
            command -v curl >/dev/null 2>&1 || pm_install curl || return 1
            run_cmd "Add the Zabbly Incus repository" sh -c \
                'curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc && . /etc/os-release && echo "deb [signed-by=/etc/apt/keyrings/zabbly.asc] https://pkgs.zabbly.com/incus/stable $VERSION_CODENAME main" > /etc/apt/sources.list.d/zabbly-incus-stable.list && apt-get update' || return 1
            pm_install incus || return 1
            ;;
        waydroid)
            command -v curl >/dev/null 2>&1 || pm_install curl || return 1
            run_cmd "Install Waydroid from its official repository" sh -c \
                'curl -fsSL https://repo.waydro.id | sh' || return 1
            pm_install waydroid || return 1
            ;;
        udocker)
            rootfs_dm_pip_install udocker || return 1
            run_cmd "Install udocker execution tools" udocker install || true
            ;;
        *) return 2 ;;
    esac
}

cn_install_tool() { # <tag>
    local tag="$1" method pkg
    local -a args=() pkgs=()
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        pkgs+=("$pkg")
    done <<< "$(cn_tool_packages "$tag")"
    if [ "${#pkgs[@]}" -gt 0 ]; then
        args+=(package "Install from ${PM:-the distribution} repositories: ${pkgs[*]}")
    fi
    case "$tag" in
        docker|containerd|lxd|incus|waydroid|udocker)
            args+=(upstream "Install from the upstream release channel") ;;
    esac
    if [ ${#args[@]} -eq 0 ]; then
        tui_msg "No installation path" \
"systui has no automated installation method for $(cn_tool_label "$tag") on this host.

Distribution: ${PM:-unknown}
See the project's own installation instructions."
        return 0
    fi
    args+=(back "Back")
    method=$(tui_menu_no_tags "Install $(cn_tool_label "$tag")" \
        "How should this tool be installed?" "${args[@]}") || return 0
    case "$method" in
        package)
            cn_install_packages "${pkgs[@]}" || {
                tui_msg "Install failed" "The package installation failed.

See $LOGFILE for the exact command output."
                return 0
            } ;;
        upstream)
            cn_upstream_install "$tag" || {
                tui_msg "Install failed" "The upstream installation failed.

See $LOGFILE for the exact command output."
                return 0
            } ;;
        *) return 0 ;;
    esac
    if cn_tool_installed "$tag"; then
        tui_msg "Installed" "$(cn_tool_version "$tag")

Binary: $(command -v "$(cn_tool_bin "$tag")" 2>/dev/null || echo 'not on PATH')"
    else
        tui_msg "Not detected" "$(cn_tool_label "$tag") was not found on PATH after installation.

A re-login (or new shell) may be required. See $LOGFILE."
    fi
}

cn_remove_tool() { # <tag>
    local tag="$1" pkg
    local -a pkgs=()
    tui_yesno "Uninstall $(cn_tool_label "$tag")" \
"Remove the $tag packages?

Images, containers and volumes stored on disk are NOT deleted." || return 0
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        pkgs+=("$pkg")
    done <<< "$(cn_tool_packages "$tag")"
    for pkg in "${pkgs[@]}"; do
        pm_remove "$pkg" >/dev/null 2>&1 || true
    done
    tui_msg "Uninstalled" "Removal completed for $tag."
}

# ---------------------------------------------------------------------------
# Service management (systemd, OpenRC, runit, SysVinit, or none)
# ---------------------------------------------------------------------------

cn_init_kind() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        printf 'systemd\n'; return 0
    fi
    if command -v rc-service >/dev/null 2>&1; then printf 'openrc\n'; return 0; fi
    if command -v sv >/dev/null 2>&1 && { [ -d /etc/sv ] || [ -d /etc/runit/sv ]; }; then
        printf 'runit\n'; return 0
    fi
    if command -v service >/dev/null 2>&1 && [ -d /etc/init.d ]; then printf 'sysvinit\n'; return 0; fi
    printf 'none\n'
}

cn_service() { # <unit> <start|stop|restart|status|enable|disable>
    local unit="$1" action="$2" bare
    case "$unit" in *.*) bare="${unit%%.*}" ;; *) bare="$unit" ;; esac
    case "$(cn_init_kind)" in
        systemd)
            case "$action" in
                enable) systemctl enable --now "$unit" ;;
                disable) systemctl disable --now "$unit" ;;
                *) systemctl "$action" "$unit" ;;
            esac ;;
        openrc)
            case "$action" in
                enable) rc-update add "$bare" default && { rc-service "$bare" start || true; } ;;
                disable) rc-service "$bare" stop 2>/dev/null || true; rc-update del "$bare" default 2>/dev/null || true ;;
                status) rc-service "$bare" status ;;
                *) rc-service "$bare" "$action" ;;
            esac ;;
        runit)
            case "$action" in
                enable)
                    [ -d "/etc/sv/$bare" ] || [ -d "/etc/runit/sv/$bare" ] || return 1
                    mkdir -p /var/service
                    if [ -d "/etc/sv/$bare" ]; then ln -sfn "/etc/sv/$bare" "/var/service/$bare"
                    else ln -sfn "/etc/runit/sv/$bare" "/var/service/$bare"; fi ;;
                disable) rm -f -- "/var/service/$bare" "/run/runit/service/$bare" ;;
                start) sv up "$bare" ;;
                stop) sv down "$bare" ;;
                restart) sv restart "$bare" ;;
                status) sv status "$bare" ;;
            esac ;;
        sysvinit)
            case "$action" in
                enable) command -v update-rc.d >/dev/null 2>&1 && update-rc.d "$bare" defaults && { service "$bare" start || true; } ;;
                disable) service "$bare" stop 2>/dev/null || true; command -v update-rc.d >/dev/null 2>&1 && update-rc.d -f "$bare" remove ;;
                *) service "$bare" "$action" ;;
            esac ;;
        *)
            return 127 ;;
    esac
}

cn_service_menu() { # <title> <unit>
    local title="$1" unit="$2" c init
    init=$(cn_init_kind)
    while true; do
        c=$(tui_menu_no_tags "$title" \
"Init system: $init
Unit: $unit
Status: $(cn_service "$unit" status 2>&1 | head -3 | tr '\n' ' ')" \
            start   "Start $unit" \
            stop    "Stop $unit" \
            restart "Restart $unit" \
            enable  "Enable at boot and start" \
            disable "Disable at boot and stop" \
            status  "Show full status" \
            logs    "Show recent service log" \
            back    "Back") || return 0
        case "$c" in
            start) run_cmd "Start $unit" cn_service "$unit" start ;;
            stop) run_cmd "Stop $unit" cn_service "$unit" stop ;;
            restart) run_cmd "Restart $unit" cn_service "$unit" restart ;;
            enable) run_cmd "Enable $unit" cn_service "$unit" enable ;;
            disable) run_cmd "Disable $unit" cn_service "$unit" disable ;;
            status)
                cn_service "$unit" status > "$(rootfs_report_file)" 2>&1 || true
                tui_text "$unit status" "$(rootfs_report_file)" ;;
            logs)
                {
                    command -v journalctl >/dev/null 2>&1 && journalctl -u "$unit" -n 120 --no-pager 2>&1
                    tail -n 80 /var/log/syslog /var/log/messages /var/log/docker.log 2>/dev/null
                } > "$(rootfs_report_file)" 2>&1
                tui_text "$unit log" "$(rootfs_report_file)" ;;
            back|"") return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Engine readiness — used by distro managers and the container menus
# ---------------------------------------------------------------------------

cn_engine_binaries() { # -> existing docker/podman binaries, docker first
    local e
    for e in docker podman; do
        command -v "$e" >/dev/null 2>&1 && printf '%s\n' "$e"
    done
}

cn_engine_present() { # <docker|podman>
    command -v "$1" >/dev/null 2>&1
}

cn_engine_daemon_up() { # <docker|podman>
    case "$1" in
        docker)
            command -v docker >/dev/null 2>&1 || return 1
            docker info >/dev/null 2>&1 ;;
        podman)
            command -v podman >/dev/null 2>&1 || return 1
            # Podman is daemonless: a successful info call is enough.
            podman info >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

cn_engine_state() { # <docker|podman>
    if ! cn_engine_present "$1"; then
        printf 'not installed\n'
    elif cn_engine_daemon_up "$1"; then
        printf 'running\n'
    else
        printf 'installed, daemon not responding\n'
    fi
}

# Pick a working engine, offering to install one when none is usable.
# Prints the engine name on success; returns 1 when there is nothing usable.
cn_ensure_engine() { # [preferred-engine]
    local preferred="${1:-}" e
    local -a candidates=()

    if [ -n "$preferred" ]; then
        cn_engine_daemon_up "$preferred" && { printf '%s\n' "$preferred"; return 0; }
    fi
    while IFS= read -r e; do
        cn_engine_daemon_up "$e" && { printf '%s\n' "$e"; return 0; }
        candidates+=("$e")
    done <<< "$(cn_engine_binaries)"

    if [ ${#candidates[@]} -gt 0 ]; then
        # Installed but not answering: try to start the service before asking
        # the user to reinstall anything.
        for e in "${candidates[@]}"; do
            cn_service "$e" start >/dev/null 2>&1 || true
            cn_engine_daemon_up "$e" && { printf '%s\n' "$e"; return 0; }
        done
        tui_msg "Container engine not responding" \
"$(printf '%s is installed but its daemon does not answer.\n' "${candidates[@]}")
Try Rootfs > Containers & virtualization > Docker/Podman > Service,
or start it manually:
  sudo dockerd &
  podman info"
        return 1
    fi

    if ! tui_yesno "No container engine" \
"No Docker or Podman installation was found.

Distrobox, Toolbx, Waydroid, nerdctl images and the LXC image
workflows need one of them.

Install Podman now (rootless, no daemon)?"; then
        return 1
    fi
    cn_install_tool podman || return 1
    if cn_engine_daemon_up podman; then
        printf 'podman\n'
        return 0
    fi
    tui_msg "Podman not usable yet" \
"Podman is installed but 'podman info' still fails.

Rootless Podman on a new system usually needs a re-login so the
user namespace and subuid mapping apply, or:

  podman system migrate"
    return 1
}

# ---------------------------------------------------------------------------
# Rootless support
# ---------------------------------------------------------------------------

cn_rootless_user_default() {
    local u
    u=$(cn_conf_get rootless_user "")
    [ -n "$u" ] && { printf '%s\n' "$u"; return 0; }
    u="${SUDO_USER:-}"
    [ -n "$u" ] || u=$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd 2>/dev/null)
    [ -n "$u" ] || u=root
    printf '%s\n' "$u"
}

cn_subid_range_free() { # <file> <user>
    local file="$1" user="$2"
    [ -r "$file" ] || return 0
    ! awk -F: -v u="$user" '$1 == u { found = 1 } END { exit found ? 0 : 1 }' "$file"
}

cn_rootless_subid_setup() { # <user> [size]
    local user="$1" size="${2:-65536}" start=100000 file
    [ -n "$user" ] || return 1
    for file in /etc/subuid /etc/subgid; do
        [ -f "$file" ] || continue
        if cn_subid_range_free "$file" "$user"; then
            printf '%s:%s:%s\n' "$user" "$start" "$size" >> "$file" || return 1
            log "container: added $user to $file ($start:$size)"
        fi
        start=$((start + size))
    done
    return 0
}

cn_rootless_enable_linger() { # <user>
    local user="$1"
    [ -n "$user" ] || return 1
    command -v loginctl >/dev/null 2>&1 || return 1
    run_cmd "Enable linger for $user" loginctl enable-linger "$user"
}

cn_rootless_setup_menu() {
    local c user size state
    while true; do
        user=$(cn_rootless_user_default)
        state=$(cn_conf_get rootless_enabled off)
        c=$(tui_menu_no_tags "Rootless containers" \
"User: $user
Enabled: $state
subuid size: $(cn_conf_get rootless_subid_size 65536)
Linger: $(cn_conf_get rootless_linger off)

Rootless Podman runs entirely in the user's namespace: no daemon,
no root, and every container's files stay owned by that user." \
            user   "Target user: $user" \
            enable "Enable rootless support (subuid/subgid + linger)" \
            disable "Disable rootless support" \
            status "Show the current mapping and storage tree" \
            back   "Back") || return 0
        case "$c" in
            user)
                local new
                new=$(tui_input "Rootless user" \
                    "Which user should own rootless containers?" "$user") || continue
                getent passwd "$new" >/dev/null 2>&1 || { tui_msg "Unknown user" "$new is not a user on this system."; continue; }
                cn_conf_set rootless_user "$new"
                tui_msg "Saved" "Rootless containers will target $new." ;;
            enable)
                size=$(cn_conf_get rootless_subid_size 65536)
                cn_rootless_subid_setup "$user" "$size" || { tui_msg "Failed" "Could not write /etc/subuid or /etc/subgid."; continue; }
                cn_conf_set rootless_linger on
                cn_rootless_enable_linger "$user" || true
                # fuse-overlayfs is what makes a rootless overlay store work.
                case "${PM:-}" in
                    apt|apk|pacman|dnf|yum|zypper|xbps) cn_install_packages fuse-overlayfs >/dev/null 2>&1 || true ;;
                esac
                cn_conf_set rootless_enabled on
                tui_msg "Rootless enabled" \
"Configured for $user:

  /etc/subuid, /etc/subgid : ${size} ids from 100000
  linger                   : $(cn_conf_get rootless_linger off)

Log out and back in as $user, then verify:
  podman info --format '{{.Host.Security.Rootless}}'" ;;
            disable)
                cn_conf_set rootless_enabled off
                tui_msg "Rootless disabled" \
"Rootless mode is marked off in systui.

Existing mappings in /etc/subuid and /etc/subgid are left in
place; remove them by hand if the ids should be reclaimed." ;;
            status)
                {
                    echo "ROOTLESS CONTAINER STATUS"
                    echo
                    echo "User            : $user"
                    echo "systui enabled  : $(cn_conf_get rootless_enabled off)"
                    echo "subid size      : $(cn_conf_get rootless_subid_size 65536)"
                    echo "linger          : $(cn_conf_get rootless_linger off)"
                    echo
                    echo "--- /etc/subuid ---"
                    grep -- "^$user:" /etc/subuid 2>/dev/null || echo 'no entry'
                    echo "--- /etc/subgid ---"
                    grep -- "^$user:" /etc/subgid 2>/dev/null || echo 'no entry'
                    echo "--- user namespaces ---"
                    sysctl kernel.unprivileged_userns_clone 2>/dev/null || echo 'not exposed by this kernel'
                    echo "user.max_user_namespaces = $(sysctl -n user.max_user_namespaces 2>/dev/null || echo unknown)"
                    echo
                    echo "--- podman (as $user) ---"
                    if command -v podman >/dev/null 2>&1; then
                        su - "$user" -c 'podman info --format "{{.Host.Security.Rootless}} {{.Store.GraphRoot}}"' 2>&1 || true
                    else
                        echo 'podman not installed'
                    fi
                } > "$(rootfs_report_file)" 2>&1
                tui_text "Rootless status" "$(rootfs_report_file)" ;;
            back|"") return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Shared prompts
# ---------------------------------------------------------------------------

cn_prompt_bool() { # <title> <text> <current> -> true|false on stdout
    local title="$1" text="$2" cur="$3" sel
    local -a state=()
    if cn_is_true "$cur"; then state=(on off); else state=(off on); fi
    sel=$(tui_menu_no_tags "$title" "$text" \
        true  "true"  "${state[0]}" \
        false "false" "${state[1]}") || return 1
    printf '%s\n' "$sel"
}

cn_prompt_list() { # <title> <text> <current> -> normalized comma list
    local title="$1" text="$2" cur="$3" value
    value=$(tui_input "$title" "$text" "$cur") || return 1
    cn_split_list "$value" | tr '\n' ' ' | sed 's/ $//'
}

cn_json_validate() { # <file>
    [ -s "$1" ] || return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1 && return 0
        return 1
    fi
    # No python: a brace/syntax smoke test only. docker validates the rest.
    awk 'BEGIN { depth = 0 } { for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (c == "{") depth++; if (c == "}") depth-- } } END { exit depth == 0 ? 0 : 1 }' "$1"
}

cn_apply_and_restart() { # <docker|podman>
    local engine="$1" rc=0
    case "$engine" in
        docker)
            cn_write_docker_daemon || { tui_msg "Write failed" "Could not write $(cn_docker_daemon_file)."; return 1; }
            if ! cn_json_validate "$(cn_docker_daemon_file)"; then
                tui_msg "Invalid daemon.json" \
"$(cn_docker_daemon_file) is not valid JSON.

Restore the previous file before restarting Docker, or edit it
through Containers > Docker > Configuration > Show generated file."
                return 1
            fi
            cn_service docker restart || rc=$?
            ;;
        podman)
            cn_apply_engine_config podman || { tui_msg "Write failed" "Could not write the containers configuration."; return 1; }
            rc=0
            ;;
    esac
    [ "$rc" -eq 0 ] || { tui_msg "Restart failed" "The configuration was written but the service restart failed.

See $LOGFILE."; return 1; }
    tui_msg "Applied" "$engine configuration written and applied."
}

cn_show_generated_config() { # <title> <files...>
    local title="$1"; shift
    {
        local f
        for f in "$@"; do
            echo "===== $f ====="
            if [ -r "$f" ]; then cat "$f"; else echo '(not written yet)'; fi
            echo
        done
    } > "$(rootfs_report_file)" 2>&1
    tui_text "$title" "$(rootfs_report_file)"
}

# ---------------------------------------------------------------------------
# Generic setting editors
# ---------------------------------------------------------------------------

cn_setting_input() { # <key> <title> <text> <default> [validator]
    local key="$1" title="$2" text="$3" def="$4" validator="${5:-}" value
    value=$(tui_input "$title" "$text" "$(cn_conf_get "$key" "$def")") || return 1
    if [ -n "$validator" ] && [ -n "$value" ] && ! "$validator" "$value"; then
        tui_msg "Invalid value" "'$value' is not valid for this setting."
        return 1
    fi
    cn_conf_set "$key" "$value"
    return 0
}

cn_setting_list() { # <key> <title> <text> <default>
    local key="$1" title="$2" text="$3" def="$4" value
    value=$(cn_prompt_list "$title" "$text" "$(cn_conf_get "$key" "$def")") || return 1
    cn_conf_set "$key" "$value"
    return 0
}

cn_setting_bool() { # <key> <title> <text> <default>
    local key="$1" title="$2" text="$3" def="$4" value
    value=$(cn_prompt_bool "$title" "$text" "$(cn_conf_get "$key" "$def")") || return 1
    cn_conf_set "$key" "$value"
}

cn_setting_choice() { # <key> <title> <text> <current> <option...>
    local key="$1" title="$2" text="$3" cur="$4"; shift 4
    local opt value
    local -a args=()
    for opt in "$@"; do args+=("$opt" "$opt"); done
    value=$(tui_menu_no_tags "$title" "$text" "${args[@]}") || return 1
    cn_conf_set "$key" "$value"
}

cn_edit_raw_file() { # <title> <path>
    local title="$1" path="$2" tmp rc=0
    [ -r "$path" ] || { tui_msg "Not written yet" "$path does not exist yet.

Apply the configuration once to generate it."; return 0; }
    tmp="$SYSTUI_TMP/editbox.$$"
    cp -- "$path" "$tmp" 2>/dev/null || return 1
    "$DIALOG" --backtitle "$BACKTITLE" --title "$title" --editbox "$tmp" 22 90 3>&1 1>"$SYSTUI_TMP/edited.$$" 2>&3 || rc=$?
    tui_dialog_status "editbox" "$title" "$rc"
    if [ "$rc" -eq 0 ] && [ -s "$SYSTUI_TMP/edited.$$" ]; then
        cp -- "$path" "$path.systui-bak" 2>/dev/null || true
        cp -- "$SYSTUI_TMP/edited.$$" "$path" && tui_msg "Saved" "$path updated.

A copy of the previous file is at $path.systui-bak"
    fi
    rm -f "$tmp" "$SYSTUI_TMP/edited.$$"
}

cn_reset_settings() { # <prefix...>
    local prefix k
    tui_yesno "Reset configuration" "Clear the saved container settings?

Generated files stay on disk until the configuration is applied again." || return 0
    for prefix in "$@"; do
        # Only touch keys this prefix owns.
        while IFS='=' read -r k _; do
            case "$k" in cn_"$prefix"*) set_config "$k" "" ;; esac
        done < "$(systui_config_file)" 2>/dev/null
    done
    tui_msg "Reset" "Saved settings cleared."
}

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------

cn_docker_config_registry() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Docker — registry" \
"Mirrors are tried in order before Docker Hub. A mirror must serve the
same content over HTTPS; it is not a private registry." \
            mirrors  "Registry mirrors      : $(cn_conf_get docker_registry_mirrors none)" \
            insecure "Insecure registries   : $(cn_conf_get docker_insecure_registries none)" \
            login    "Log in to a registry (docker login)" \
            back     "Back") || return 0
        case "$c" in
            mirrors) cn_setting_list docker_registry_mirrors "Registry mirrors" \
                        "Comma or space separated mirror URLs:" "" ;;
            insecure) cn_setting_list docker_insecure_registries "Insecure registries" \
                        "Registries allowed over plain HTTP or with untrusted TLS (host:port):" "" ;;
            login)
                local server
                server=$(tui_input "docker login" "Registry server (blank = Docker Hub):" "") || continue
                clear
                if [ -n "$server" ]; then run_cmd "docker login $server" docker login "$server" || true
                else run_cmd "docker login" docker login || true; fi
                read -rp "(press Enter)" _ || true ;;
            back|"") return 0 ;;
        esac
    done
}

cn_docker_config_storage() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Docker — storage" \
"data-root   : $(cn_conf_get docker_data_root /var/lib/docker)
storage-driver: $(cn_conf_get docker_storage_driver overlay2)
builder cache: $(cn_conf_get docker_builder_gc none)

Changing data-root does not move existing images; use
'Manage > Move data-root' to migrate them." \
            data_root "Data root: $(cn_conf_get docker_data_root /var/lib/docker)" \
            driver    "Storage driver: $(cn_conf_get docker_storage_driver overlay2)" \
            move      "Move the data root (stop, copy, start)" \
            gc        "Builder cache limit: $(cn_conf_get docker_builder_gc none)" \
            back      "Back") || return 0
        case "$c" in
            data_root) cn_setting_input docker_data_root "Docker data root" \
                           "Absolute path for images, containers and volumes:" "/var/lib/docker" cn_valid_path ;;
            driver) cn_setting_choice docker_storage_driver "Storage driver" \
                        "overlay2 is correct on ext4/xfs. vfs is the safe fallback for filesystems without overlay support (some iSH/AOK images)." \
                        "$(cn_conf_get docker_storage_driver overlay2)" overlay2 overlay vfs btrfs zfs ;;
            move) cn_docker_move_data_root ;;
            gc) cn_setting_input docker_builder_gc "Builder cache limit" \
                    "Maximum builder cache size, e.g. 10GB (blank = unlimited):" "" ;;
            back|"") return 0 ;;
        esac
    done
}

cn_docker_move_data_root() {
    local new target
    new=$(cn_conf_get docker_data_root /var/lib/docker)
    [ -d "$new" ] || { tui_msg "Nothing to move" "$new does not exist yet."; return 0; }
    target=$(tui_input "Move data root" \
        "Destination directory (existing contents of $new will be copied):" "") || return 0
    [ -n "$target" ] || return 0
    cn_valid_path "$target" || { tui_msg "Invalid path" "Enter an absolute path."; return 0; }
    tui_yesno "Move data root" \
"This stops Docker, copies $new to $target and switches data-root.

It can take a long time and needs enough free space for a full copy." || return 0
    cn_service docker stop >/dev/null 2>&1 || true
    mkdir -p "$target" || return 1
    run_cmd "Copy $new to $target" cp -a "$new/." "$target/" || {
        tui_msg "Copy failed" "Docker was stopped and nothing was switched.

Start it again from Configuration > Service."
        return 1
    }
    cn_conf_set docker_data_root "$target"
    cn_apply_engine_config docker >/dev/null 2>&1 || true
    cn_service docker start >/dev/null 2>&1 || true
    tui_msg "Moved" "data-root is now $target.

The old tree at $new is untouched; delete it once the new one is verified."
}

cn_docker_config_network() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Docker — network" \
"Default address pool: $(cn_conf_get docker_pool_base none)/$(cn_conf_get docker_pool_size 24)
DNS servers         : $(cn_conf_get docker_dns none)
iptables            : $(cn_conf_get docker_iptables true)
userland-proxy      : $(cn_conf_get docker_userland_proxy true)" \
            pool     "Default address pool" \
            dns      "Container DNS servers" \
            iptables "iptables management: $(cn_conf_get docker_iptables true)" \
            ip6tables "IPv6 iptables: $(cn_conf_get docker_ip6tables false)" \
            proxy    "userland-proxy: $(cn_conf_get docker_userland_proxy true)" \
            back     "Back") || return 0
        case "$c" in
            pool)
                cn_setting_input docker_pool_base "Address pool base" \
                    "Base CIDR for automatically created bridge networks (e.g. 172.31.0.0/16):" "" cn_valid_cidr || continue
                cn_setting_input docker_pool_size "Address pool size" \
                    "Subnet size allocated per network (8-30):" "24" || true ;;
            dns) cn_setting_list docker_dns "Container DNS" \
                    "DNS servers written into daemon.json:" "" ;;
            iptables) cn_setting_bool docker_iptables "iptables" \
                    "Let Docker manage iptables rules? Disable only when another firewall owns them." true ;;
            ip6tables) cn_setting_bool docker_ip6tables "ip6tables" \
                    "Let Docker manage IPv6 firewall rules?" false ;;
            proxy) cn_setting_bool docker_userland_proxy "userland-proxy" \
                    "Keep the userland proxy for published ports? Disabling needs hairpin NAT to work." true ;;
            back|"") return 0 ;;
        esac
    done
}

cn_docker_config_security() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Docker — security & runtime" \
"userns-remap  : $(cn_conf_get docker_userns_remap none)
live-restore  : $(cn_conf_get docker_live_restore false)
experimental  : $(cn_conf_get docker_experimental false)" \
            userns     "userns-remap: $(cn_conf_get docker_userns_remap none)" \
            liverestore "live-restore: $(cn_conf_get docker_live_restore false)" \
            experimental "experimental features: $(cn_conf_get docker_experimental false)" \
            back       "Back") || return 0
        case "$c" in
            userns) cn_setting_input docker_userns_remap "userns-remap" \
                        "User namespace mapping: 'default', user, or user:group (blank = off):" "" ;;
            liverestore) cn_setting_bool docker_live_restore "live-restore" \
                        "Keep containers running while the daemon restarts?" false ;;
            experimental) cn_setting_bool docker_experimental "experimental" \
                        "Enable experimental daemon features?" false ;;
            back|"") return 0 ;;
        esac
    done
}

cn_docker_config_menu() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Docker configuration" \
"$(cn_config_summary)
File: $(cn_docker_daemon_file)" \
            registry "Registry & authentication" \
            storage  "Storage, data root & builder cache" \
            network  "Networking, address pools & DNS" \
            security "Security & runtime behaviour" \
            apply    "Write the configuration and restart Docker" \
            show     "Show the generated daemon.json" \
            raw      "Edit daemon.json directly" \
            reset    "Reset every saved Docker setting" \
            back     "Back") || return 0
        case "$c" in
            registry) cn_docker_config_registry ;;
            storage) cn_docker_config_storage ;;
            network) cn_docker_config_network ;;
            security) cn_docker_config_security ;;
            apply) cn_apply_and_restart docker ;;
            show) cn_show_generated_config "daemon.json" "$(cn_docker_daemon_file)" ;;
            raw) cn_edit_raw_file "daemon.json" "$(cn_docker_daemon_file)" ;;
            reset) cn_reset_settings docker_ ;;
            back|"") return 0 ;;
        esac
    done
}

cn_container_run_prompt() { # <engine> <title>
    local engine="$1" title="$2" image name extra args
    image=$(tui_input "$title" "Image reference (e.g. debian:stable-slim):" "") || return 1
    [ -n "$image" ] || return 1
    name=$(tui_input "$title" "Container name (blank = auto):" "") || return 1
    extra=$(tui_input "$title" "Extra arguments (blank = none):" "") || return 1
    read -r -a args <<< "$extra"
    if [ -n "$name" ]; then
        run_cmd "Run $image as $name" "$engine" run -dit --name "$name" "${args[@]}" "$image"
    else
        run_cmd "Run $image" "$engine" run -dit "${args[@]}" "$image"
    fi
}

cn_engine_prune_menu() { # <engine>
    local engine="$1" c
    while true; do
        c=$(tui_menu_no_tags "Prune — $engine" \
"Reclaim disk space. Every action below asks for confirmation." \
            containers "Remove all stopped containers" \
            images     "Remove unused images" \
            volumes    "Remove unused volumes" \
            networks   "Remove unused networks" \
            builder    "Clear the build cache" \
            all        "Everything above (docker system prune -a --volumes)" \
            disk       "Show disk usage" \
            back       "Back") || return 0
        case "$c" in
            containers) tui_yesno "Prune containers" "Remove every stopped container?" && run_cmd "Prune containers" "$engine" container prune -f ;;
            images) tui_yesno "Prune images" "Remove every image not used by a container?" && run_cmd "Prune images" "$engine" image prune -a -f ;;
            volumes) tui_yesno "Prune volumes" "Remove every unused volume? Their data is lost." && run_cmd "Prune volumes" "$engine" volume prune -f ;;
            networks) tui_yesno "Prune networks" "Remove every unused network?" && run_cmd "Prune networks" "$engine" network prune -f ;;
            builder) tui_yesno "Prune builder cache" "Clear the build cache?" && run_cmd "Prune builder cache" "$engine" builder prune -f ;;
            all) tui_yesno "Prune everything" "Remove stopped containers, unused images, volumes, networks and the build cache?" &&
                 run_cmd "System prune" "$engine" system prune -a -f --volumes ;;
            disk) "$engine" system df > "$(rootfs_report_file)" 2>&1 || true
                  tui_text "$engine disk usage" "$(rootfs_report_file)" ;;
            back|"") return 0 ;;
        esac
    done
}

cn_docker_menu() {
    local c d
    while true; do
        c=$(tui_menu_no_tags "Docker" \
"State: $(cn_engine_state docker)
$(cn_tool_version docker)
Compose: $(docker compose version 2>/dev/null | head -1 || echo 'not installed')" \
            status    "Status and daemon information" \
            install   "Install or update Docker Engine + compose + buildx" \
            configure "Configuration (daemon.json)" \
            service   "Service control (start/stop/enable)" \
            containers "List containers" \
            images    "List images" \
            run       "Run a container from an image" \
            exec      "Open a shell in a running container" \
            logs      "Show container logs" \
            compose   "Compose project actions" \
            prune     "Prune images, containers, volumes, cache" \
            rootless  "Rootless containers" \
            uninstall "Uninstall Docker" \
            help      "Show docker help" \
            back      "Back") || return 0
        case "$c" in
            status) { docker version; echo; docker info; } > "$(rootfs_report_file)" 2>&1 || true
                    tui_text "Docker status" "$(rootfs_report_file)" ;;
            install) cn_install_tool docker ;;
            configure) cn_docker_config_menu ;;
            service) cn_service_menu "Docker service" docker ;;
            containers) rootfs_dm_show_command docker "docker ps" ps -a ;;
            images) rootfs_dm_show_command docker "docker images" images ;;
            run) cn_container_run_prompt docker "Run a container" ;;
            exec)
                d=$(tui_input "docker exec" "Running container name/id:" "") || continue
                [ -n "$d" ] || continue
                clear
                run_cmd "Shell in $d" docker exec -it "$d" /bin/sh || run_cmd "Shell in $d" docker exec -it "$d" bash || true
                read -rp "(press Enter)" _ || true ;;
            logs)
                d=$(tui_input "docker logs" "Container name/id:" "") || continue
                [ -n "$d" ] || continue
                docker logs --tail 200 "$d" > "$(rootfs_report_file)" 2>&1 || true
                tui_text "docker logs $d" "$(rootfs_report_file)" ;;
            compose) cn_compose_menu docker ;;
            prune) cn_engine_prune_menu docker ;;
            rootless) cn_rootless_setup_menu ;;
            uninstall) cn_remove_tool docker ;;
            help) rootfs_dm_show_command docker "docker help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

cn_compose_menu() { # <engine>
    local engine="$1" c dir
    while true; do
        c=$(tui_menu_no_tags "Compose — $engine" \
"Compose v2 is a CLI plugin ($engine compose). Project files are
compose.yaml / docker-compose.yml in the project directory." \
            install "Install/verify the compose plugin" \
            up      "Start a project (up -d)" \
            down    "Stop a project (down)" \
            ps      "List a project's containers" \
            logs    "Follow a project's logs" \
            pull    "Pull a project's images" \
            config  "Validate and print the merged configuration" \
            back    "Back") || return 0
        case "$c" in
            install) case "$engine" in
                         docker) cn_install_packages docker-compose-v2 docker-compose-plugin >/dev/null 2>&1 || true ;;
                         podman) cn_install_packages podman-compose >/dev/null 2>&1 || true ;;
                     esac
                     tui_msg "Compose" "$($engine compose version 2>/dev/null || $engine-compose version 2>/dev/null || echo 'compose is not available yet')" ;;
            up|down|ps|logs|pull|config)
                dir=$(tui_input "Compose project" "Project directory:" "$PWD") || continue
                [ -d "$dir" ] || { tui_msg "Not found" "$dir is not a directory."; continue; }
                clear
                case "$c" in
                    up) ( cd "$dir" && run_cmd "compose up" "$engine" compose up -d ) || true ;;
                    down) ( cd "$dir" && run_cmd "compose down" "$engine" compose down ) || true ;;
                    ps) ( cd "$dir" && "$engine" compose ps > "$(rootfs_report_file)" 2>&1 ) || true
                        tui_text "compose ps" "$(rootfs_report_file)" ;;
                    logs) ( cd "$dir" && timeout 30 "$engine" compose logs --tail 200 > "$(rootfs_report_file)" 2>&1 ) || true
                          tui_text "compose logs" "$(rootfs_report_file)" ;;
                    pull) ( cd "$dir" && run_cmd "compose pull" "$engine" compose pull ) || true ;;
                    config) ( cd "$dir" && "$engine" compose config > "$(rootfs_report_file)" 2>&1 ) || true
                            tui_text "compose config" "$(rootfs_report_file)" ;;
                esac
                read -rp "(press Enter)" _ || true ;;
            back|"") return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Podman
# ---------------------------------------------------------------------------

cn_podman_config_registry() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Podman — registries" \
"Search registries : $(cn_conf_get podman_search_registries "docker.io quay.io ghcr.io")
Mirrors           : $(cn_conf_get podman_registry_mirrors none)
Insecure          : $(cn_conf_get podman_insecure_registries none)
File              : $(cn_registries_file)" \
            search   "Short-name search registries" \
            mirrors  "docker.io mirrors" \
            insecure "Insecure registries" \
            apply    "Write /etc/containers/registries.conf" \
            show     "Show the generated file" \
            back     "Back") || return 0
        case "$c" in
            search) cn_setting_list podman_search_registries "Search registries" \
                        "Registries consulted for unqualified names, in order:" "docker.io quay.io ghcr.io" ;;
            mirrors) cn_setting_list podman_registry_mirrors "Registry mirrors" \
                        "Mirror URLs for docker.io:" "" ;;
            insecure) cn_setting_list podman_insecure_registries "Insecure registries" \
                        "host:port entries allowed over plain HTTP:" "" ;;
            apply) cn_write_registries_conf && tui_msg "Written" "$(cn_registries_file) updated." ;;
            show) cn_show_generated_config "registries.conf" "$(cn_registries_file)" ;;
            back|"") return 0 ;;
        esac
    done
}

cn_podman_config_storage() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Podman — storage" \
"graphroot : $(cn_conf_get podman_graphroot /var/lib/containers/storage)
runroot   : $(cn_conf_get podman_runroot /run/containers/storage)
driver    : $(cn_conf_get podman_storage_driver overlay)
mount prog: $(cn_conf_get podman_mount_program /usr/bin/fuse-overlayfs)

Rootless installs need fuse-overlayfs; vfs works everywhere but
copies whole layers instead of sharing them." \
            graphroot "Graph root: $(cn_conf_get podman_graphroot /var/lib/containers/storage)" \
            runroot   "Run root: $(cn_conf_get podman_runroot /run/containers/storage)" \
            driver    "Storage driver: $(cn_conf_get podman_storage_driver overlay)" \
            mountprog "Overlay mount program: $(cn_conf_get podman_mount_program /usr/bin/fuse-overlayfs)" \
            apply     "Write /etc/containers/storage.conf" \
            show      "Show the generated file" \
            back      "Back") || return 0
        case "$c" in
            graphroot) cn_setting_input podman_graphroot "Podman graph root" \
                           "Absolute path for image and container storage:" "/var/lib/containers/storage" cn_valid_path ;;
            runroot) cn_setting_input podman_runroot "Podman run root" \
                         "Absolute path for runtime state:" "/run/containers/storage" cn_valid_path ;;
            driver) cn_setting_choice podman_storage_driver "Podman storage driver" \
                        "overlay with fuse-overlayfs is the rootless default; vfs always works." \
                        "$(cn_conf_get podman_storage_driver overlay)" overlay fuse-overlayfs vfs btrfs zfs ;;
            mountprog) cn_setting_input podman_mount_program "Overlay mount program" \
                           "Binary used for rootless overlay mounts:" "/usr/bin/fuse-overlayfs" ;;
            apply) cn_write_storage_conf && tui_msg "Written" "$(cn_storage_conf_file) updated." ;;
            show) cn_show_generated_config "storage.conf" "$(cn_storage_conf_file)" ;;
            back|"") return 0 ;;
        esac
    done
}

cn_podman_config_engine() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Podman — engine" \
"runtime       : $(cn_conf_get podman_runtime crun)
cgroup manager: $(cn_conf_get podman_cgroup systemd)
default subnet: $(cn_conf_get podman_subnet none)
socket        : $(cn_conf_get podman_socket off)

crun is the default OCI runtime; runc is the portable fallback.
cgroup v1 hosts must use cgroupfs instead of systemd." \
            runtime "OCI runtime: $(cn_conf_get podman_runtime crun)" \
            cgroup  "cgroup manager: $(cn_conf_get podman_cgroup systemd)" \
            subnet  "Default network subnet: $(cn_conf_get podman_subnet none)" \
            socket  "Enable the podman API socket: $(cn_conf_get podman_socket off)" \
            shim    "Install the podman-docker command shim: $(cn_conf_get podman_shim off)" \
            apply   "Write /etc/containers/containers.conf" \
            show    "Show the generated file" \
            back    "Back") || return 0
        case "$c" in
            runtime) cn_setting_choice podman_runtime "OCI runtime" \
                        "crun is smaller and faster; runc is the reference implementation." \
                        "$(cn_conf_get podman_runtime crun)" crun runc kata-runtime ;;
            cgroup) cn_setting_choice podman_cgroup "cgroup manager" \
                        "systemd needs a running systemd; otherwise use cgroupfs." \
                        "$(cn_conf_get podman_cgroup systemd)" systemd cgroupfs ;;
            subnet) cn_setting_input podman_subnet "Default subnet" \
                        "CIDR for the default podman network (blank = podman's own default):" "" ;;
            socket)
                cn_setting_bool podman_socket "Podman socket" \
                    "Enable the rootless/rootful API socket for docker-compatible clients?" off
                if cn_is_true "$(cn_conf_get podman_socket off)"; then
                    cn_service podman.socket enable >/dev/null 2>&1 ||
                        run_cmd "Enable podman.socket" systemctl --user enable --now podman.socket || true
                fi ;;
            shim)
                cn_setting_bool podman_shim "podman-docker shim" \
                    "Install the package that provides a docker-compatible command name?" off
                if cn_is_true "$(cn_conf_get podman_shim off)"; then
                    cn_install_packages podman-docker >/dev/null 2>&1 || true
                fi ;;
            apply) cn_write_containers_conf && tui_msg "Written" "$(cn_containers_conf_file) updated." ;;
            show) cn_show_generated_config "containers.conf" "$(cn_containers_conf_file)" ;;
            back|"") return 0 ;;
        esac
    done
}

cn_podman_config_menu() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Podman configuration" \
"Rootless: $(cn_conf_get rootless_enabled off)  user: $(cn_rootless_user_default)
graphroot: $(cn_conf_get podman_graphroot /var/lib/containers/storage)
registries: $(cn_registries_file)" \
            registry "Registries, mirrors & insecure endpoints" \
            storage  "Storage layout and driver" \
            engine   "Engine runtime, cgroups, socket" \
            rootless "Rootless containers (subuid/subgid, linger)" \
            apply    "Write every configuration file" \
            show     "Show the generated files" \
            reset    "Reset every saved Podman setting" \
            back     "Back") || return 0
        case "$c" in
            registry) cn_podman_config_registry ;;
            storage) cn_podman_config_storage ;;
            engine) cn_podman_config_engine ;;
            rootless) cn_rootless_setup_menu ;;
            apply) cn_apply_engine_config podman && tui_msg "Applied" "Podman configuration written." ;;
            show) cn_show_generated_config "Podman configuration" \
                    "$(cn_registries_file)" "$(cn_containers_conf_file)" "$(cn_storage_conf_file)" ;;
            reset) cn_reset_settings podman_ ;;
            back|"") return 0 ;;
        esac
    done
}

cn_podman_menu() {
    local c d user
    while true; do
        user=$(cn_rootless_user_default)
        c=$(tui_menu_no_tags "Podman" \
"State: $(cn_engine_state podman)
$(cn_tool_version podman)
Rootless: $(su - "$user" -c 'podman info --format "{{.Host.Security.Rootless}}"' 2>/dev/null || echo unknown)" \
            status    "Status and storage information" \
            install   "Install or update Podman + compose + rootless helpers" \
            configure "Configuration (registries, storage, engine)" \
            service   "Service control (podman.socket)" \
            containers "List containers" \
            images    "List images" \
            run       "Run a container from an image" \
            exec      "Open a shell in a running container" \
            logs      "Show container logs" \
            compose   "Compose project actions" \
            prune     "Prune images, containers, volumes, cache" \
            rootless  "Rootless containers" \
            uninstall "Uninstall Podman" \
            help      "Show podman help" \
            back      "Back") || return 0
        case "$c" in
            status) { podman info; echo; podman system df; } > "$(rootfs_report_file)" 2>&1 || true
                    tui_text "Podman status" "$(rootfs_report_file)" ;;
            install) cn_install_tool podman ;;
            configure) cn_podman_config_menu ;;
            service) cn_service_menu "Podman socket" podman.socket ;;
            containers) rootfs_dm_show_command podman "podman ps" ps -a ;;
            images) rootfs_dm_show_command podman "podman images" images ;;
            run) cn_container_run_prompt podman "Run a container" ;;
            exec)
                d=$(tui_input "podman exec" "Running container name/id:" "") || continue
                [ -n "$d" ] || continue
                clear
                run_cmd "Shell in $d" podman exec -it "$d" /bin/sh || run_cmd "Shell in $d" podman exec -it "$d" bash || true
                read -rp "(press Enter)" _ || true ;;
            logs)
                d=$(tui_input "podman logs" "Container name/id:" "") || continue
                [ -n "$d" ] || continue
                podman logs --tail 200 "$d" > "$(rootfs_report_file)" 2>&1 || true
                tui_text "podman logs $d" "$(rootfs_report_file)" ;;
            compose) cn_compose_menu podman ;;
            prune) cn_engine_prune_menu podman ;;
            rootless) cn_rootless_setup_menu ;;
            uninstall) cn_remove_tool podman ;;
            help) rootfs_dm_show_command podman "podman help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# containerd / nerdctl
# ---------------------------------------------------------------------------

cn_containerd_menu() {
    local c
    while true; do
        c=$(tui_menu_no_tags "containerd + nerdctl" \
"State: $(cn_engine_state containerd)
$(cn_tool_version containerd)
containerd socket: /run/containerd/containerd.sock" \
            status    "Status (containerd + nerdctl info)" \
            install   "Install or update containerd and nerdctl" \
            service   "Service control (containerd)" \
            namespaces "List containerd namespaces" \
            containers "List containers (nerdctl ps)" \
            images    "List images (nerdctl images)" \
            run       "Run a container" \
            exec      "Open a shell in a running container" \
            prune     "Prune nerdctl objects" \
            uninstall "Uninstall containerd/nerdctl" \
            help      "Show nerdctl help" \
            back      "Back") || return 0
        case "$c" in
            status) { containerd --version 2>/dev/null; nerdctl info 2>&1; } > "$(rootfs_report_file)" 2>&1 || true
                    tui_text "containerd status" "$(rootfs_report_file)" ;;
            install) cn_install_tool containerd ;;
            service) cn_service_menu "containerd service" containerd ;;
            namespaces) rootfs_dm_show_command containerd "nerdctl namespaces" namespace ls ;;
            containers) rootfs_dm_show_command containerd "nerdctl ps" ps -a ;;
            images) rootfs_dm_show_command containerd "nerdctl images" images ;;
            run) cn_container_run_prompt nerdctl "Run a container" ;;
            exec)
                local d
                d=$(tui_input "nerdctl exec" "Running container name/id:" "") || continue
                [ -n "$d" ] || continue
                clear
                run_cmd "Shell in $d" nerdctl exec -it "$d" /bin/sh || true
                read -rp "(press Enter)" _ || true ;;
            prune) tui_yesno "Prune" "Remove unused nerdctl images, containers and networks?" &&
                   run_cmd "nerdctl system prune" nerdctl system prune -f ;;
            uninstall) cn_remove_tool containerd ;;
            help) rootfs_dm_show_command containerd "nerdctl help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# LXC / LXD / Incus
# ---------------------------------------------------------------------------

cn_show_command() { # <binary> <title> <args...>
    local bin="$1" title="$2"; shift 2
    "$bin" "$@" > "$(rootfs_report_file)" 2>&1 || true
    tui_text "$title" "$(rootfs_report_file)"
}

cn_lxc_menu() {
    local c name distro
    while true; do
        c=$(tui_menu_no_tags "LXC" \
"Version: $(cn_tool_version lxc)
Binary : $(command -v lxc-create 2>/dev/null || echo 'not installed')
Config: $(cn_lxc_conf_file)" \
            list     "List containers" \
            install  "Install LXC + templates" \
            create   "Create a container from a template" \
            start    "Start a container" \
            stop     "Stop a container" \
            attach   "Open a shell in a running container" \
            destroy  "Destroy a container" \
            config   "Configure the default LXC network/AppArmor profile" \
            service  "Service control (lxc-net)" \
            uninstall "Uninstall LXC" \
            help     "Show lxc help" \
            back     "Back") || return 0
        case "$c" in
            list) cn_show_command lxc-ls "lxc-ls" --fancy ;;
            install) cn_install_tool lxc ;;
            create)
                distro=$(tui_input "LXC template" "Template name (download, debian, alpine, ubuntu):" "download") || continue
                [ -n "$distro" ] || continue
                name=$(tui_input "LXC container name" "Name for the new container:" "systui-lxc") || continue
                [ -n "$name" ] || continue
                clear
                if [ "$distro" = download ]; then
                    run_cmd "Download LXC image list" lxc-create -t download -n "$name" -- --list || true
                    local rel arch
                    rel=$(tui_input "LXC download" "Distribution and release (e.g. debian bookworm):" "debian bookworm") || continue
                    arch=$(tui_input "LXC download" "Architecture:" "amd64") || continue
                    if [ -n "$rel" ]; then
                        run_cmd "Create $name" lxc-create -t download -n "$name" -- --dist "${rel%% *}" --release "${rel##* }" --arch "$arch" || true
                    fi
                else
                    run_cmd "Create $name" lxc-create -t "$distro" -n "$name" || true
                fi
                read -rp "(press Enter)" _ || true ;;
            start|stop|destroy)
                name=$(tui_input "LXC $c" "Container name:" "") || continue
                [ -n "$name" ] || continue
                case "$c" in
                    start) run_cmd "Start $name" lxc-start -n "$name" -d ;;
                    stop) run_cmd "Stop $name" lxc-stop -n "$name" ;;
                    destroy) tui_yesno "Destroy" "Delete container '$name' and its filesystem?" &&
                             run_cmd "Destroy $name" lxc-destroy -n "$name" ;;
                esac ;;
            attach)
                name=$(tui_input "LXC attach" "Container name:" "") || continue
                [ -n "$name" ] || continue
                clear
                run_cmd "Attach to $name" lxc-attach -n "$name" || true
                read -rp "(press Enter)" _ || true ;;
            config) cn_lxc_config_menu ;;
            service) cn_service_menu "lxc-net service" lxc-net ;;
            uninstall) cn_remove_tool lxc ;;
            help) cn_show_command lxc-start "lxc-start help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

cn_lxc_config_menu() {
    local c
    while true; do
        c=$(tui_menu_no_tags "LXC configuration" \
"Default profile: $(cn_lxc_conf_file)
lxcbr0 gateway : $(cn_conf_get lxc_gateway 10.0.3.1)
lxcbr0 CIDR    : $(cn_conf_get lxc_subnet 10.0.3.0/24)" \
            network  "Container network mode (default bridge settings)" \
            gateway  "Bridge gateway address" \
            cidr     "Bridge subnet" \
            apparmor "AppArmor profile for new containers" \
            apply    "Write the default LXC configuration" \
            show     "Show the generated file" \
            back     "Back") || return 0
        case "$c" in
            network) cn_setting_choice lxc_netmode "Network profile" \
                        "veth on lxcbr0 is the default NAT bridge; none keeps the container offline." \
                        "$(cn_conf_get lxc_netmode veth)" veth none ;;
            gateway) cn_setting_input lxc_gateway "LXC gateway" \
                        "Bridge address containers use as their default route:" "10.0.3.1" ;;
            cidr) cn_setting_input lxc_subnet "LXC subnet" \
                        "CIDR for the lxcbr0 bridge (lxc-net reads this from /etc/default/lxc-net):" "10.0.3.0/24" ;;
            apparmor) cn_setting_choice lxc_apparmor "AppArmor profile" \
                        "Profile applied to new containers:" \
                        "$(cn_conf_get lxc_apparmor generated)" generated unconfined lxc-container-default ;;
            apply) cn_write_lxc_conf && tui_msg "Written" "$(cn_lxc_conf_file) updated." ;;
            show) cn_show_generated_config "LXC default.conf" "$(cn_lxc_conf_file)" ;;
            back|"") return 0 ;;
        esac
    done
}

cn_write_lxc_conf() {
    local file
    file=$(cn_lxc_conf_file)
    {
        echo '# Managed by systui — Container & virtualization.'
        if [ "$(cn_conf_get lxc_netmode veth)" = none ]; then
            echo "lxc.net.0.type = empty"
        else
            echo "lxc.net.0.type = veth"
            echo "lxc.net.0.link = lxcbr0"
            echo "lxc.net.0.flags = up"
            echo "lxc.net.0.hwaddr = 00:16:3e:xx:xx:xx"
        fi
        echo "lxc.net.0.ipv4.gateway = $(cn_conf_get lxc_gateway 10.0.3.1)"
        echo "lxc.apparmor.profile = $(cn_conf_get lxc_apparmor generated)"
        echo "lxc.start.auto = 0"
        echo "lxc.idmap = u 0 100000 65536"
        echo "lxc.idmap = g 0 100000 65536"
    } > "$file.tmp.$$" || return 1
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    mv -f "$file.tmp.$$" "$file" || return 1
    chmod 0644 "$file" 2>/dev/null || true
}

cn_lxd_incus_menu() { # <lxd|incus>
    local tool="$1" bin="${1}" c name image
    while true; do
        c=$(tui_menu_no_tags "$(cn_tool_label "$tool")" \
"State: $(cn_engine_state "$tool")
$(cn_tool_version "$tool")
Remote images: images: (images.linuxcontainers.org)" \
            status    "Status and server info" \
            install   "Install or update $bin" \
            service   "Service control ($bin)" \
            list      "List instances" \
            images    "List cached images" \
            launch    "Launch an instance from an image" \
            start     "Start an instance" \
            stop      "Stop an instance" \
            exec      "Open a shell in an instance" \
            delete    "Delete an instance" \
            remotes   "List configured image remotes" \
            uninstall "Uninstall $bin" \
            help      "Show $bin help" \
            back      "Back") || return 0
        case "$c" in
            status) { "$bin" version; echo; "$bin" info; } > "$(rootfs_report_file)" 2>&1 || true
                    tui_text "$bin status" "$(rootfs_report_file)" ;;
            install) cn_install_tool "$tool" ;;
            service) cn_service_menu "$bin service" "$bin" ;;
            list) cn_show_command "$bin" "$bin list" list ;;
            images) cn_show_command "$bin" "$bin image list" image list ;;
            launch)
                image=$(tui_input "$bin launch" "Image alias (e.g. images:debian/12, images:alpine/3.20):" "images:debian/12") || continue
                [ -n "$image" ] || continue
                name=$(tui_input "$bin launch" "Instance name:" "systui-$tool") || continue
                [ -n "$name" ] || continue
                clear
                run_cmd "Launch $name" "$bin" launch "$image" "$name" || true
                read -rp "(press Enter)" _ || true ;;
            start|stop|delete|exec)
                name=$(tui_input "$bin $c" "Instance name:" "") || continue
                [ -n "$name" ] || continue
                case "$c" in
                    start) run_cmd "Start $name" "$bin" start "$name" ;;
                    stop) run_cmd "Stop $name" "$bin" stop "$name" ;;
                    delete) tui_yesno "Delete" "Delete instance '$name' and its storage?" &&
                            run_cmd "Delete $name" "$bin" delete "$name" ;;
                    exec) clear
                          run_cmd "Shell in $name" "$bin" exec "$name" -- /bin/sh || true
                          read -rp "(press Enter)" _ || true ;;
                esac ;;
            remotes) cn_show_command "$bin" "$bin remote list" remote list ;;
            uninstall) cn_remove_tool "$tool" ;;
            help) cn_show_command "$bin" "$bin help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# libvirt + QEMU/KVM
# ---------------------------------------------------------------------------

cn_libvirt_menu() {
    local c name
    while true; do
        c=$(tui_menu_no_tags "libvirt + QEMU/KVM" \
"State: $(cn_engine_state libvirt)
$(cn_tool_version libvirt)
URI: qemu:///system" \
            status   "Status (virsh capabilities/version)" \
            install  "Install QEMU, libvirt and virt-install" \
            service  "Service control (libvirtd)" \
            domains  "List virtual machines" \
            create   "Create a VM with virt-install" \
            start    "Start a VM" \
            shutdown "Graceful shutdown" \
            destroy  "Force off (destroy)" \
            console  "Open the serial console" \
            network  "Default network (virbr0)" \
            pool     "Storage pools" \
            config   "Configure default network and pool paths" \
            uninstall "Uninstall libvirt" \
            help     "Show virsh help" \
            back     "Back") || return 0
        case "$c" in
            status) { virsh version; echo; virsh capabilities | head -40; } > "$(rootfs_report_file)" 2>&1 || true
                    tui_text "libvirt status" "$(rootfs_report_file)" ;;
            install) cn_install_tool libvirt ;;
            service) cn_service_menu "libvirtd service" libvirtd ;;
            domains) cn_show_command virsh "virsh list" list --all ;;
            create) cn_libvirt_create ;;
            start|shutdown|destroy|console)
                name=$(tui_input "libvirt $c" "Domain name:" "") || continue
                [ -n "$name" ] || continue
                case "$c" in
                    start) run_cmd "Start $name" virsh start "$name" ;;
                    shutdown) run_cmd "Shutdown $name" virsh shutdown "$name" ;;
                    destroy) tui_yesno "Force off" "Destroy (hard power-off) '$name'?" &&
                             run_cmd "Destroy $name" virsh destroy "$name" ;;
                    console) clear
                             run_cmd "Console $name" virsh console "$name" || true
                             read -rp "(press Enter)" _ || true ;;
                esac ;;
            network) cn_show_command virsh "virsh net-list" net-list --all ;;
            pool) cn_show_command virsh "virsh pool-list" pool-list --all ;;
            config) cn_libvirt_config_menu ;;
            uninstall) cn_remove_tool libvirt ;;
            help) cn_show_command virsh "virsh help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

cn_libvirt_create() {
    local name mem vcpus disk iso
    name=$(tui_input "New VM" "Domain name:" "systui-vm") || return 0
    [ -n "$name" ] || return 0
    mem=$(tui_input "New VM" "Memory in MiB:" "2048") || return 0
    vcpus=$(tui_input "New VM" "vCPUs:" "2") || return 0
    disk=$(tui_input "New VM" "Disk image path:" "/var/lib/libvirt/images/$name.qcow2") || return 0
    iso=$(tui_input "New VM" "Installer ISO/tree URL (blank = import existing disk):" "") || return 0
    tui_yesno "Create VM" "Create '$name' with ${mem}MiB, ${vcpus} vCPU and $disk?" || return 0
    if [ ! -f "$disk" ]; then
        run_cmd "Create disk $disk" qemu-img create -f qcow2 "$disk" 20G || return 1
    fi
    if [ -n "$iso" ]; then
        run_cmd "virt-install $name" virt-install --name "$name" --memory "$mem" \
            --vcpus "$vcpus" --disk path="$disk",format=qcow2 --cdrom "$iso" \
            --network network=default --graphics none --console pty,target_type=serial || true
    else
        run_cmd "virt-install $name" virt-install --name "$name" --memory "$mem" \
            --vcpus "$vcpus" --disk path="$disk",format=qcow2 --import \
            --network network=default --graphics none --console pty,target_type=serial || true
    fi
}

cn_libvirt_config_menu() {
    local c
    while true; do
        c=$(tui_menu_no_tags "libvirt configuration" \
"Default network : $(cn_conf_get libvirt_network default)
Bridge          : $(cn_conf_get libvirt_bridge virbr0)
Image directory : $(cn_conf_get libvirt_images /var/lib/libvirt/images)
Autostart net   : $(cn_conf_get libvirt_net_autostart on)" \
            network  "Default network name" \
            subnet   "Default network subnet" \
            images   "Image directory" \
            autostart "Autostart the default network: $(cn_conf_get libvirt_net_autostart on)" \
            apply    "Apply the default network settings" \
            show     "Show the current default network XML" \
            back     "Back") || return 0
        case "$c" in
            network) cn_setting_input libvirt_network "Default network" \
                        "libvirt network name handed to new VMs:" "default" ;;
            subnet) cn_setting_input libvirt_subnet "Default network subnet" \
                        "CIDR for the NAT network (e.g. 192.168.123.0/24):" "192.168.123.0/24" cn_valid_cidr ;;
            images) cn_setting_input libvirt_images "Image directory" \
                        "Directory where VM disks are created:" "/var/lib/libvirt/images" cn_valid_path ;;
            autostart) cn_setting_bool libvirt_net_autostart "Autostart default network" \
                        "Start the default NAT network at boot?" on ;;
            apply) cn_libvirt_apply_network ;;
            show) cn_show_command virsh "net-dumpxml" net-dumpxml "$(cn_conf_get libvirt_network default)" ;;
            back|"") return 0 ;;
        esac
    done
}

cn_libvirt_apply_network() {
    local name subnet base
    name=$(cn_conf_get libvirt_network default)
    subnet=$(cn_conf_get libvirt_subnet 192.168.123.0/24)
    base="${subnet%.*}"
    command -v virsh >/dev/null 2>&1 || { tui_msg "virsh missing" "Install libvirt first."; return 0; }
    virsh net-info "$name" >/dev/null 2>&1 && {
        tui_msg "Network exists" "The '$name' network already exists.

Delete it first (virsh net-destroy/net-undefine) if the subnet
must change." 
        return 0
    }
    {
        echo "<network>"
        echo "  <name>$name</name>"
        echo "  <forward mode='nat'/>"
        echo "  <bridge name='virbr0' stp='on' delay='0'/>"
        echo "  <ip address='$base.1' netmask='255.255.255.0'>"
        echo "    <dhcp><range start='$base.2' end='$base.254'/></dhcp>"
        echo "  </ip>"
        echo "</network>"
    } > "$SYSTUI_TMP/libvirt-net.xml"
    run_cmd "Define $name network" virsh net-define "$SYSTUI_TMP/libvirt-net.xml" || return 1
    if cn_is_true "$(cn_conf_get libvirt_net_autostart on)"; then
        run_cmd "Autostart $name" virsh net-autostart "$name" || true
    fi
    run_cmd "Start $name" virsh net-start "$name" || true
}

# ---------------------------------------------------------------------------
# Waydroid
# ---------------------------------------------------------------------------

cn_waydroid_menu() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Waydroid" \
"State: $(cn_engine_state waydroid)
$(cn_tool_version waydroid)
Requires: LXC + binder kernel support + a supported session" \
            status    "Status and container information" \
            install   "Install Waydroid (+ LXC and binder tools)" \
            init      "Initialise Waydroid (download the Android image)" \
            session   "Start/stop the session" \
            show      "Show the Android UI" \
            apps      "List installed Android apps" \
            installapk "Install an APK" \
            config    "Configuration (images, GPU, multi-window)" \
            uninstall "Uninstall Waydroid" \
            help      "Show waydroid help" \
            back      "Back") || return 0
        case "$c" in
            status) { waydroid status; echo; waydroid container status 2>&1; } > "$(rootfs_report_file)" 2>&1 || true
                    tui_text "Waydroid status" "$(rootfs_report_file)" ;;
            install)
                cn_install_tool lxc >/dev/null 2>&1 || true
                cn_install_tool waydroid ;;
            init) run_cmd "Initialise Waydroid" waydroid init || true ;;
            session) cn_waydroid_session_menu ;;
            show) run_cmd "Show Waydroid UI" waydroid show-full-ui || true ;;
            apps) cn_show_command waydroid "Waydroid apps" app list installed ;;
            installapk)
                local apk
                apk=$(tui_input "Install APK" "Absolute path to the .apk file:" "") || continue
                [ -f "$apk" ] || { tui_msg "Not found" "$apk is not a file."; continue; }
                run_cmd "Install $apk" waydroid app install "$apk" || true ;;
            config) cn_waydroid_config_menu ;;
            uninstall) cn_remove_tool waydroid ;;
            help) cn_show_command waydroid "waydroid help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

cn_waydroid_session_menu() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Waydroid session" \
"Session: $(waydroid status 2>/dev/null | sed -n 's/^Session:[[:space:]]*//p' || echo unknown)" \
            start   "Start the session" \
            stop    "Stop the session" \
            restart "Restart container + session" \
            status  "Show status" \
            back    "Back") || return 0
        case "$c" in
            start) run_cmd "Start session" waydroid session start || true ;;
            stop) run_cmd "Stop session" waydroid session stop || true ;;
            restart) run_cmd "Stop container" waydroid container stop || true
                     run_cmd "Start container" waydroid container start || true ;;
            status) cn_show_command waydroid "Waydroid status" status ;;
            back|"") return 0 ;;
        esac
    done
}

cn_waydroid_config_menu() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Waydroid configuration" \
"Vendor image : $(cn_conf_get waydroid_vendor /etc/waydroid-extra/images)
GPU mode     : $(cn_conf_get waydroid_gpu auto)
Multi-window : $(cn_conf_get waydroid_multi_windows off)" \
            gpu      "GPU rendering mode: $(cn_conf_get waydroid_gpu auto)" \
            windows  "Multi-window mode: $(cn_conf_get waydroid_multi_windows off)" \
            images   "Image/channel directory" \
            reinit   "Re-initialise with the system/vendor image" \
            show     "Show waydroid.cfg" \
            back     "Back") || return 0
        case "$c" in
            gpu) cn_setting_choice waydroid_gpu "Waydroid GPU mode" \
                    "auto picks the host GL stack; swiftshader is the software fallback." \
                    "$(cn_conf_get waydroid_gpu auto)" auto swiftshader none ;;
            windows) cn_setting_bool waydroid_multi_windows "Multi-window" \
                        "Run Android apps in individual host windows?" off
                     if cn_is_true "$(cn_conf_get waydroid_multi_windows off)"; then
                         waydroid prop set persist.waydroid.multi_windows true 2>/dev/null || true
                     else
                         waydroid prop set persist.waydroid.multi_windows false 2>/dev/null || true
                     fi ;;
            images) cn_setting_input waydroid_images "Waydroid images" \
                        "Directory containing system.img and vendor.img:" "/etc/waydroid-extra/images" ;;
            reinit) tui_yesno "Re-initialise" "Download/refresh the Android images?" &&
                    run_cmd "waydroid init -f" waydroid init -f || true ;;
            show) cn_show_generated_config "waydroid.cfg" /var/lib/waydroid/waydroid.cfg /etc/waydroid-extra/waydroid.cfg ;;
            back|"") return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Sandboxes: apptainer, bubblewrap, systemd-nspawn
# ---------------------------------------------------------------------------

cn_sandbox_menu() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Sandbox runtimes" \
"apptainer : $(cn_tool_version apptainer)
bubblewrap: $(cn_tool_version bwrap)
nspawn    : $(cn_tool_version nspawn)" \
            apptainer "Apptainer/Singularity — HPC container images" \
            bwrap     "bubblewrap — unprivileged sandbox" \
            nspawn    "systemd-nspawn / machinectl images" \
            back      "Back") || return 0
        case "$c" in
            apptainer) cn_apptainer_menu ;;
            bwrap) cn_bwrap_menu ;;
            nspawn) cn_nspawn_menu ;;
            back|"") return 0 ;;
        esac
    done
}

cn_apptainer_menu() {
    local c image
    while true; do
        c=$(tui_menu_no_tags "Apptainer" \
"$(cn_tool_version apptainer)
Images are single-file .sif archives; pulling does not need root." \
            install "Install Apptainer" \
            pull    "Pull an image (docker:// or library://)" \
            list    "List local images" \
            shell   "Open a shell inside an image" \
            exec    "Run a command inside an image" \
            config  "Configure cache and remote endpoints" \
            uninstall "Uninstall Apptainer" \
            back    "Back") || return 0
        case "$c" in
            install) cn_install_tool apptainer ;;
            pull)
                image=$(tui_input "apptainer pull" "Image URL (docker://debian:stable-slim):" "docker://debian:stable-slim") || continue
                [ -n "$image" ] || continue
                run_cmd "Pull $image" apptainer pull "$image" || true ;;
            list) cn_show_command apptainer "Apptainer images" instance list ;;
            shell)
                image=$(tui_input "apptainer shell" "Image file:" "") || continue
                [ -n "$image" ] || continue
                clear
                run_cmd "Shell in $image" apptainer shell "$image" || true
                read -rp "(press Enter)" _ || true ;;
            exec)
                image=$(tui_input "apptainer exec" "Image file:" "") || continue
                [ -n "$image" ] || continue
                run_cmd "Exec in $image" apptainer exec "$image" /bin/sh || true ;;
            config) cn_apptainer_config_menu ;;
            uninstall) cn_remove_tool apptainer ;;
            back|"") return 0 ;;
        esac
    done
}

cn_apptainer_config_menu() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Apptainer configuration" \
"Cache dir      : $(cn_conf_get apptainer_cachedir ~/.apptainer/cache)
Docker endpoint: $(cn_conf_get apptainer_docker_host docker://)
Setuid install : $(cn_conf_get apptainer_setuid on)" \
            cache    "Cache directory" \
            endpoint "Docker endpoint" \
            setuid   "Setuid mode: $(cn_conf_get apptainer_setuid on)" \
            apply    "Write apptainer.conf overrides" \
            show     "Show the generated file" \
            back     "Back") || return 0
        case "$c" in
            cache) cn_setting_input apptainer_cachedir "Apptainer cache" \
                       "Directory for downloaded images and OCI blobs:" "$HOME/.apptainer/cache" ;;
            endpoint) cn_setting_input apptainer_docker_host "Docker endpoint" \
                          "Prefix used for docker:// pulls:" "docker://" ;;
            setuid) cn_setting_bool apptainer_setuid "Setuid mode" "Allow setuid-based workflows?" on ;;
            apply) cn_write_apptainer_conf && tui_msg "Written" "/etc/apptainer/apptainer.conf updated." ;;
            show) cn_show_generated_config "apptainer.conf" "${SYSTUI_APPTAINER_CONF:-/etc/apptainer/apptainer.conf}" ;;
            back|"") return 0 ;;
        esac
    done
}

cn_write_apptainer_conf() {
    local file
    file="${SYSTUI_APPTAINER_CONF:-/etc/apptainer/apptainer.conf}"
    {
        echo '# Managed by systui — Container & virtualization.'
        echo "cachedir = $(cn_conf_get apptainer_cachedir "$HOME/.apptainer/cache")"
        echo "allow setuid = $(cn_is_true "$(cn_conf_get apptainer_setuid on)" && echo yes || echo no)"
        echo "mount proc = yes"
        echo "mount sys = yes"
        echo "mount dev = yes"
    } > "$file.tmp.$$" || return 1
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    mv -f "$file.tmp.$$" "$file" || return 1
}

cn_bwrap_menu() {
    local c target
    while true; do
        c=$(tui_menu_no_tags "bubblewrap" \
"$(cn_tool_version bwrap)
bwrap builds a namespace sandbox around a single command; it needs
no daemon and no root." \
            install "Install bubblewrap" \
            shell   "Open a sandboxed shell (read-only root)" \
            run     "Run a command in a sandbox" \
            test    "Verify user namespaces work" \
            uninstall "Uninstall bubblewrap" \
            back    "Back") || return 0
        case "$c" in
            install) cn_install_tool bwrap ;;
            shell)
                clear
                run_cmd "Sandboxed shell" bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp \
                    --unshare-all --share-net /bin/sh || true
                read -rp "(press Enter)" _ || true ;;
            run)
                target=$(tui_input "bwrap run" "Command to run inside the sandbox:" "/bin/sh -c 'id; ls /'") || continue
                clear
                run_cmd "Sandboxed command" sh -c "bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --unshare-all --share-net $target" || true
                read -rp "(press Enter)" _ || true ;;
            test) { bwrap --ro-bind / / --unshare-all true && echo 'user namespaces: OK' ||
                    echo 'user namespaces: unavailable (enable kernel.unprivileged_userns_clone or use setuid bwrap)'; } > "$(rootfs_report_file)" 2>&1
                  tui_text "bubblewrap test" "$(rootfs_report_file)" ;;
            uninstall) cn_remove_tool bwrap ;;
            back|"") return 0 ;;
        esac
    done
}

cn_nspawn_menu() {
    local c name
    while true; do
        c=$(tui_menu_no_tags "systemd-nspawn (machinectl)" \
"$(cn_tool_version nspawn)
Machine images: $(cn_conf_get nspawn_images /var/lib/machines)" \
            install "Install systemd-container" \
            images  "List machine images" \
            pull    "Import a tar image from a URL" \
            boot    "Boot a machine" \
            shell   "Open a shell in a machine" \
            poweroff "Power off a machine" \
            config  "Configure the image directory" \
            uninstall "Uninstall systemd-container" \
            back    "Back") || return 0
        case "$c" in
            install) cn_install_tool nspawn ;;
            images) cn_show_command machinectl "machinectl images" list-images ;;
            pull)
                local url
                url=$(tui_input "machinectl pull-tar" "Tar image URL:" "") || continue
                [ -n "$url" ] || continue
                name=$(tui_input "machinectl pull-tar" "Local image name (blank = derive):" "") || continue
                if [ -n "$name" ]; then run_cmd "Import image" machinectl pull-tar "$url" "$name" || true
                else run_cmd "Import image" machinectl pull-tar "$url" || true; fi ;;
            boot|shell|poweroff)
                name=$(tui_input "machinectl" "Machine name:" "") || continue
                [ -n "$name" ] || continue
                case "$c" in
                    boot) run_cmd "Boot $name" machinectl start "$name" ;;
                    shell) clear; run_cmd "Shell in $name" machinectl shell "$name" || true
                           read -rp "(press Enter)" _ || true ;;
                    poweroff) run_cmd "Power off $name" machinectl poweroff "$name" ;;
                esac ;;
            config) cn_show_generated_config "nspawn images" /var/lib/machines ;;
            uninstall) cn_remove_tool nspawn ;;
            back|"") return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Shared configuration, status and the front door
# ---------------------------------------------------------------------------

cn_shared_config_menu() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Shared container configuration" \
"These values are written into every engine that uses them:
  Docker  -> $(cn_docker_daemon_file)
  Podman  -> $(cn_registries_file), $(cn_containers_conf_file), $(cn_storage_conf_file)" \
            mirrors  "Registry mirrors (Docker + Podman): $(cn_conf_get docker_registry_mirrors none)" \
            insecure "Insecure registries (Docker + Podman): $(cn_conf_get docker_insecure_registries none)" \
            dns      "Container DNS servers: $(cn_conf_get docker_dns none)" \
            pool     "Docker address pool: $(cn_conf_get docker_pool_base none)" \
            rootless "Rootless containers" \
            apply    "Write every file for every engine" \
            show     "Show every generated file" \
            reset    "Reset every saved container setting" \
            back     "Back") || return 0
        case "$c" in
            mirrors)
                cn_setting_list docker_registry_mirrors "Registry mirrors" \
                    "Mirror URLs tried before Docker Hub (comma or space separated):" "" || continue
                cn_conf_set podman_registry_mirrors "$(cn_conf_get docker_registry_mirrors)" ;;
            insecure)
                cn_setting_list docker_insecure_registries "Insecure registries" \
                    "host:port entries allowed over plain HTTP:" "" || continue
                cn_conf_set podman_insecure_registries "$(cn_conf_get docker_insecure_registries)" ;;
            dns) cn_setting_list docker_dns "Container DNS" "DNS servers for new containers:" "" ;;
            pool) cn_setting_input docker_pool_base "Address pool" \
                      "Base CIDR for Docker's automatic bridge networks:" "" cn_valid_cidr || continue
                  cn_setting_input docker_pool_size "Address pool size" "Subnet size per network:" "24" || true ;;
            rootless) cn_rootless_setup_menu ;;
            apply) cn_apply_engine_config all && tui_msg "Applied" "Docker and Podman configuration written.

Restart the engines for the daemon-level settings to take effect." ;;
            show) cn_show_generated_config "Generated container configuration" \
                    "$(cn_docker_daemon_file)" "$(cn_registries_file)" \
                    "$(cn_containers_conf_file)" "$(cn_storage_conf_file)" ;;
            reset) cn_reset_settings docker_ podman_ ;;
            back|"") return 0 ;;
        esac
    done
}

cn_status_report() {
    local t bin state
    {
        echo "CONTAINERS & VIRTUALIZATION"
        echo
        echo "Host init system : $(cn_init_kind)"
        echo "Package manager  : ${PM:-unknown}"
        echo "Kernel           : $(uname -sr)"
        echo "Cgroups          : $(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
        echo "User namespaces  : $(sysctl -n user.max_user_namespaces 2>/dev/null || echo unknown)"
        echo "Rootless user    : $(cn_rootless_user_default) ($(cn_conf_get rootless_enabled off))"
        echo
        echo "--- Tools ---"
        while IFS='|' read -r t bin _label state; do
            [ -n "$t" ] || continue
            printf '%-11s %-9s %-10s %s\n' "$t" \
                "$(cn_tool_installed "$t" && echo installed || echo missing)" \
                "$(cn_engine_state "$t" 2>/dev/null | cut -d, -f1)" \
                "$(command -v "$bin" 2>/dev/null || echo '-')"
        done <<< "$(cn_tools | awk -F'|' '{ print $1 "|" $2 "|" $3 "|" $4 }')"
        echo
        echo "--- Versions ---"
        while IFS='|' read -r t _; do
            [ -n "$t" ] || continue
            cn_tool_installed "$t" || continue
            printf '%-11s %s\n' "$t" "$(cn_tool_version "$t" | head -1)"
        done <<< "$(cn_tools)"
        echo
        echo "--- systui settings ---"
        cn_config_summary
        echo
        echo "--- Configuration files ---"
        local f
        for f in "$(cn_docker_daemon_file)" "$(cn_registries_file)" "$(cn_containers_conf_file)" "$(cn_storage_conf_file)" "$(cn_lxc_conf_file)"; do
            printf '%-48s %s\n' "$f" "$([ -r "$f" ] && echo present || echo absent)"
        done
    } > "$(rootfs_report_file)" 2>&1
    tui_text "Container & virtualization status" "$(rootfs_report_file)"
}

cn_cleanup_menu() {
    local c engine
    while true; do
        c=$(tui_menu_no_tags "Reclaim disk space" \
"Pruning is per engine. Every action asks for confirmation." \
            docker  "Prune Docker" \
            podman  "Prune Podman" \
            nerdctl "Prune containerd/nerdctl" \
            lxc     "List LXC container disk usage" \
            virt    "List libvirt storage pools" \
            back    "Back") || return 0
        case "$c" in
            docker|podman) cn_engine_prune_menu "$c" ;;
            nerdctl) tui_yesno "Prune nerdctl" "Remove unused nerdctl images, containers and networks?" &&
                     run_cmd "nerdctl system prune" nerdctl system prune -f ;;
            lxc) cn_show_command du "LXC disk usage" -sh /var/lib/lxc/* 2>/dev/null ;;
            virt) cn_show_command virsh "libvirt pools" pool-list --all --details ;;
            back|"") return 0 ;;
        esac
    done
}

menu_rootfs_containers() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Containers & virtualization" \
"Engines: $(cn_engine_binaries | tr '\n' ' ')
Init: $(cn_init_kind)   Rootless: $(cn_conf_get rootless_enabled off)

Install, configure and operate container runtimes and machine
virtualization. Distro managers that need an engine call into the
same settings, so configuration is never duplicated." \
            status   "Status dashboard (every tool, version, state)" \
            docker   "Docker Engine — install, daemon.json, compose, prune" \
            podman   "Podman — install, rootless, registries, storage" \
            containerd "containerd + nerdctl — namespaces and images" \
            lxc      "LXC — system containers from templates" \
            lxd      "LXD — LXC with an API daemon" \
            incus    "Incus — LXD-compatible, community maintained" \
            libvirt  "libvirt + QEMU/KVM — full virtual machines" \
            waydroid "Waydroid — Android in a container" \
            sandbox  "Sandbox runtimes — apptainer, bubblewrap, nspawn" \
            config   "Shared configuration — mirrors, DNS, storage, rootless" \
            cleanup  "Reclaim disk space" \
            about    "How these tools differ" \
            back     "Back") || return 0
        case "$c" in
            status) cn_status_report ;;
            docker) cn_docker_menu ;;
            podman) cn_podman_menu ;;
            containerd) cn_containerd_menu ;;
            lxc) cn_lxc_menu ;;
            lxd) cn_lxd_incus_menu lxd ;;
            incus) cn_lxd_incus_menu incus ;;
            libvirt) cn_libvirt_menu ;;
            waydroid) cn_waydroid_menu ;;
            sandbox) cn_sandbox_menu ;;
            config) cn_shared_config_menu ;;
            cleanup) cn_cleanup_menu ;;
            about)
                tui_msg "Container runtimes, compared" \
"docker      daemon, root by default, the compatibility baseline.
podman      daemonless, rootless by default, docker-compatible CLI.
containerd  the runtime Docker itself uses; nerdctl is its CLI.
lxc/lxd/incus system containers: a full init, no image layering.
libvirt     real virtual machines with their own kernel (KVM).
waydroid   Android userspace in an LXC container (needs binder).
apptainer   single-file images for HPC; no daemon.
bubblewrap  namespace sandbox around one command.

Distrobox, Toolbx and the Rootfs > Distro managers image workflows
use docker or podman underneath; pick the engine here and those
menus reuse it." ;;
            back|"") return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
