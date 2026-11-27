# shellcheck shell=bash
###############################################################################
# DISTRO MANAGERS — extended catalogue, engine wiring and configuration
#
# Loaded after zz-rootfs-distro-managers.sh / 99-distro-manager-distrobox-final.sh
# so it sees (and reuses) every earlier implementation:
#
#   * four more managers: podman, docker, lxc, incus
#   * every engine-backed manager is wired to Rootfs > Containers &
#     virtualization: the engine is detected, started, or installed from here
#   * configuration grows from "where does it store trees" to the settings the
#     managers actually read: engine selection, image pull policy, network
#     mode, home mount, extra arguments and pull-on-create
#
# Existing managers keep their tested command mappings: the previous
# implementations are preserved under _systui_dm_*_prev and delegated to.
###############################################################################

systui_dm_save_fn() { # <function> <preserved-name>
    declare -F "$1" >/dev/null 2>&1 || return 0
    declare -F "$2" >/dev/null 2>&1 && return 0
    local body
    body=$(declare -f "$1") || return 1
    body="${body/#$1 /$2 }"
    eval "$body"
}

systui_dm_save_fn rootfs_dm_managers          _systui_dm_managers_prev
systui_dm_save_fn rootfs_dm_install_hint      _systui_dm_hint_prev
systui_dm_save_fn rootfs_dm_package           _systui_dm_package_prev
systui_dm_save_fn rootfs_dm_install_upstream  _systui_dm_upstream_prev
systui_dm_save_fn rootfs_dm_install           _systui_dm_install_prev
systui_dm_save_fn rootfs_dm_install_image     _systui_dm_image_prev
systui_dm_save_fn rootfs_dm_catalog_for_install _systui_dm_catalog_prev
systui_dm_save_fn rootfs_dm_menu_one          _systui_dm_menu_one_prev
systui_dm_save_fn rootfs_dm_installed_names   _systui_dm_names_prev
systui_dm_save_fn rootfs_dm_store_default     _systui_dm_store_prev

# ---------------------------------------------------------------------------
# Catalogue
# ---------------------------------------------------------------------------

rootfs_dm_managers() {
    _systui_dm_managers_prev
    printf '%s\n' \
        'podman|podman|podman — run distribution images as rootless containers' \
        'docker|docker|docker — run distribution images as containers' \
        'lxc|lxc-create|LXC — system containers from distribution templates' \
        'incus|incus|Incus — LXD-compatible system containers'
}

rootfs_dm_engine_tags() { # managers that cannot work without an external engine
    printf '%s\n' distrobox toolbx
}

rootfs_dm_runtime_tags() { # managers that have their own runtime settings
    printf '%s\n' podman docker lxc incus
}

rootfs_dm_needs_engine() { # <tag>
    local t
    for t in $(rootfs_dm_engine_tags); do
        [ "$t" = "$1" ] && return 0
    done
    return 1
}

rootfs_dm_engine_preference() { # <tag> -> docker|podman|<empty>
    case "$1" in
        docker) printf 'docker\n' ;;
        podman|lxc|incus) printf 'podman\n' ;;
        distrobox|toolbx)
            # Distrobox prefers podman; honour an explicit systui preference.
            case "$(cn_conf_get dm_engine auto)" in
                docker) printf 'docker\n' ;;
                podman) printf 'podman\n' ;;
                *) : ;;
            esac ;;
    esac
}

# Ensure a usable engine for an engine-backed manager. Returns 0 when usable.
rootfs_dm_require_engine() { # <tag>
    local tag="$1" engine pref
    rootfs_dm_needs_engine "$tag" || return 0
    pref=$(rootfs_dm_engine_preference "$tag")
    if [ -n "$pref" ] && cn_engine_daemon_up "$pref"; then
        return 0
    fi
    engine=$(cn_ensure_engine "$pref") || return 1
    log "distro-manager: $tag will use $engine"
    return 0
}

# ---------------------------------------------------------------------------
# Install hints / package names / installation
# ---------------------------------------------------------------------------

rootfs_dm_install_hint() { # <tag>
    case "$1" in
        podman)
            printf '%s\n' 'Package "podman" (+ fuse-overlayfs, slirp4netns, uidmap). Rootless by default; run systui'"'"'s Containers > Podman > Rootless to set up subuid/subgid.' ;;
        docker)
            printf '%s\n' 'Package "docker.io"/"docker" (+ compose, buildx), or https://get.docker.com. Needs the daemon running; enable it from Containers > Docker > Service.' ;;
        lxc)
            printf '%s\n' 'Package "lxc" + "lxc-templates" (and debootstrap for Debian-family templates).' ;;
        incus)
            printf '%s\n' 'Package "incus" (Debian/Ubuntu/Arch/Fedora), or the Zabbly repository on other apt hosts.' ;;
        *)
            _systui_dm_hint_prev "$1" ;;
    esac
}

rootfs_dm_package() { # <tag>
    local tag="$1" pkg=""
    case "$tag" in
        podman)
            case "${PM:-}" in
                apt|apk|pacman|dnf|yum|zypper|xbps) pkg=podman ;;
                emerge) pkg=app-containers/podman ;;
            esac ;;
        docker)
            case "${PM:-}" in
                apt) pkg=docker.io ;;
                apk|pacman|dnf|yum|zypper|xbps) pkg=docker ;;
                emerge) pkg=app-containers/docker ;;
            esac ;;
        lxc)
            case "${PM:-}" in
                apt|apk|pacman|dnf|yum|zypper|xbps) pkg=lxc ;;
                emerge) pkg=app-containers/lxc ;;
            esac ;;
        incus)
            case "${PM:-}" in
                apt|apk|pacman|dnf|yum|zypper|xbps) pkg=incus ;;
                emerge) pkg=app-containers/incus ;;
            esac ;;
        *) _systui_dm_package_prev "$tag"; return $? ;;
    esac
    [ -n "$pkg" ] && printf '%s\n' "$pkg"
}

rootfs_dm_install_upstream() { # <tag>
    case "$1" in
        podman|docker|lxc|incus) cn_upstream_install "$1" ;;
        *) _systui_dm_upstream_prev "$1" ;;
    esac
}

rootfs_dm_install() { # <tag>
    local tag="$1" pkg method
    local -a args=()
    case "$tag" in
        podman|docker|lxc|incus)
            pkg=$(rootfs_dm_package "$tag")
            [ -n "$pkg" ] && args+=(package "Install '$pkg' with ${PM:-the system package manager}")
            case "$tag" in
                podman|docker|incus) args+=(upstream "Install from the upstream release channel") ;;
            esac
            args+=(back "Back")
            method=$(tui_menu_no_tags "Install $(rootfs_dm_label "$tag")" \
                "Choose an installation source:" "${args[@]}") || return 0
            case "$method" in
                package) pm_install "$pkg" ;;
                upstream) rootfs_dm_install_upstream "$tag" || return 0 ;;
                *) return 0 ;;
            esac
            if rootfs_dm_available "$tag"; then
                tui_msg "Installed" "$tag is available at $(command -v "$(rootfs_dm_binary "$tag")")."
            else
                tui_msg "Not detected" "$tag was not found on PATH after installation. See $LOGFILE."
            fi
            ;;
        *)
            _systui_dm_install_prev "$tag"
            local rc=$?
            rootfs_dm_needs_engine "$tag" && rootfs_dm_require_engine "$tag" >/dev/null 2>&1 || true
            return "$rc"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Runtime data locations and installed entries
# ---------------------------------------------------------------------------

rootfs_dm_store_default() { # <tag>
    local d
    case "$1" in
        lxc)
            for d in /var/lib/lxc /var/lib/containers/lxc; do
                [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
            done
            return 1 ;;
        incus)
            for d in /var/lib/incus/containers /var/lib/incus/storage-pools; do
                [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
            done
            return 1 ;;
        podman|docker)
            # Images live in the engine's layered store, not as directories.
            return 1 ;;
        *) _systui_dm_store_prev "$1" ;;
    esac
}

rootfs_dm_installed_names() { # <tag>
    case "$1" in
        lxc) lxc-ls 2>/dev/null | tr ' ' '\n' | sed '/^$/d' ;;
        incus)
            rootfs_dm_capture incus list --format csv -c n 2>/dev/null || return 1 ;;
        podman) podman ps -a --format '{{.Names}}' 2>/dev/null ;;
        docker) docker ps -a --format '{{.Names}}' 2>/dev/null ;;
        *) _systui_dm_names_prev "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# Images and distribution catalogues
# ---------------------------------------------------------------------------

rootfs_dm_static_images() { # <tag>
    case "$1" in
        lxc|incus)
            cat <<'EOF'
debian/12|Debian 12 (bookworm)
debian/13|Debian 13 (trixie)
ubuntu/24.04|Ubuntu 24.04 LTS
ubuntu/22.04|Ubuntu 22.04 LTS
alpine/3.20|Alpine 3.20
alpine/edge|Alpine edge
archlinux/current|Arch Linux
fedora/40|Fedora 40
centos/9-Stream|CentOS Stream 9
rockylinux/9|Rocky Linux 9
EOF
            ;;
        podman|docker)
            cat <<'EOF'
docker.io/library/debian:stable-slim|Debian stable (slim)
docker.io/library/debian:bookworm|Debian 12
docker.io/library/ubuntu:24.04|Ubuntu 24.04 LTS
docker.io/library/ubuntu:22.04|Ubuntu 22.04 LTS
docker.io/library/alpine:latest|Alpine latest
docker.io/library/archlinux:latest|Arch Linux
docker.io/library/fedora:latest|Fedora
docker.io/library/rockylinux:9|Rocky Linux 9
quay.io/centos/centos:stream9|CentOS Stream 9
EOF
            ;;
    esac
}

rootfs_dm_catalog_for_install() { # <tag> [query]
    local tag="$1" query="${2:-}" out
    case "$tag" in
        lxc|incus)
            if [ -n "$query" ]; then
                printf '%s\n' "$(rootfs_dm_static_images "$tag")" |
                    grep -i -- "$query" || rootfs_dm_static_images "$tag"
            else
                rootfs_dm_static_images "$tag"
            fi
            ;;
        podman|docker)
            if [ -n "$query" ]; then
                out=$("$tag" search "$query" 2>/dev/null | sed -E 's/^[[:space:]]+//' || true)
                if [ -n "$out" ]; then
                    printf '%s\n' "$out" | awk '
                        NR == 1 { next }
                        { name = $1; if (name ~ /^[a-z0-9][a-z0-9._\/-]*(:[A-Za-z0-9._-]+)?$/) print "docker.io/" name "|" $0 }
                    ' | sort -u | head -40
                else
                    rootfs_dm_static_images "$tag"
                fi
            else
                rootfs_dm_static_images "$tag"
            fi
            ;;
        *) _systui_dm_catalog_prev "$tag" "$query" ;;
    esac
}

rootfs_dm_install_image() { # <tag> <image> [name]
    local tag="$1" image="$2" name="${3:-}" extra policy
    case "$tag" in
        podman|docker)
            [ -n "$name" ] || name=$(printf '%s' "$image" | sed 's|.*/||; s/:.*//; s/[^A-Za-z0-9_.-]/-/g')
            [ -n "$name" ] || name="systui-${tag}"
            policy=$(cn_conf_get "dm_${tag}_pull" always)
            if [ "$policy" = always ]; then
                rootfs_dm_run "$tag" "Pull $image" pull "$image" || return 1
            fi
            read -r -a extra <<< "$(cn_conf_get "dm_${tag}_args" "")"
            if [ "${#extra[@]}" -gt 0 ]; then
                rootfs_dm_run "$tag" "Create $name from $image" create --name "$name" "${extra[@]}" "$image"
            else
                rootfs_dm_run "$tag" "Create $name from $image" create --name "$name" -it "$image"
            fi
            ;;
        lxc)
            [ -n "$name" ] || name=$(printf '%s' "$image" | sed 's|.*/||; s/[^A-Za-z0-9_.-]/-/g')
            [ -n "$name" ] || name=systui-lxc
            rootfs_dm_run lxc "Create LXC container $name" launch "$image" "$name" ||
                rootfs_dm_run lxc "Create LXC container $name" create "$image" --name "$name"
            ;;
        incus)
            [ -n "$name" ] || name=$(printf '%s' "$image" | sed 's|.*/||; s/[^A-Za-z0-9_.-]/-/g')
            [ -n "$name" ] || name=systui-incus
            rootfs_dm_run incus "Launch Incus instance $name" launch "images:$image" "$name"
            ;;
        *) _systui_dm_image_prev "$tag" "$image" "$name" ;;
    esac
}

# ---------------------------------------------------------------------------
# Per-manager menus for the new engines
# ---------------------------------------------------------------------------

rootfs_dm_menu_podman() {
    local c d
    while true; do
        c=$(tui_menu_no_tags "Podman (distributions)" \
"State: $(cn_engine_state podman)
Rootless user: $(cn_rootless_user_default)
Store: $(cn_conf_get podman_graphroot /var/lib/containers/storage)" \
            browse    "Browse/select distribution images and create containers" \
            installed "List containers created from images" \
            images    "List pulled images" \
            enter     "Open a shell in a container" \
            start     "Start a container" \
            stop      "Stop a container" \
            remove    "Remove a container" \
            engine    "Open the full Podman manager (config, prune, rootless)" \
            configure "Configure this manager" \
            uninstall "Uninstall Podman" \
            help      "Show podman help" \
            back      "Back") || return 0
        case "$c" in
            browse) rootfs_dm_browse_install podman ;;
            installed) rootfs_dm_show_command podman "podman ps" ps -a ;;
            images) rootfs_dm_show_command podman "podman images" images ;;
            enter|start|stop|remove)
                d=$(rootfs_dm_pick_installed podman) || continue
                [ -n "$d" ] || continue
                case "$c" in
                    enter) clear
                           rootfs_dm_run podman "Shell in $d" exec -it "$d" /bin/sh || true
                           read -rp "(press Enter)" _ || true ;;
                    start) rootfs_dm_run podman "Start $d" start "$d" ;;
                    stop) rootfs_dm_run podman "Stop $d" stop "$d" ;;
                    remove) tui_yesno "Remove" "Delete container '$d'?" &&
                            rootfs_dm_run podman "Remove $d" rm -f "$d" ;;
                esac ;;
            engine) cn_podman_menu ;;
            configure) rootfs_dm_config_menu podman ;;
            uninstall) rootfs_dm_remove podman ;;
            help) rootfs_dm_show_command podman "podman help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

rootfs_dm_menu_docker() {
    local c d
    while true; do
        c=$(tui_menu_no_tags "Docker (distributions)" \
"State: $(cn_engine_state docker)
Data root: $(cn_conf_get docker_data_root /var/lib/docker)" \
            browse    "Browse/select distribution images and create containers" \
            installed "List containers created from images" \
            images    "List pulled images" \
            enter     "Open a shell in a container" \
            start     "Start a container" \
            stop      "Stop a container" \
            remove    "Remove a container" \
            engine    "Open the full Docker manager (daemon.json, compose, prune)" \
            configure "Configure this manager" \
            uninstall "Uninstall Docker" \
            help      "Show docker help" \
            back      "Back") || return 0
        case "$c" in
            browse) rootfs_dm_browse_install docker ;;
            installed) rootfs_dm_show_command docker "docker ps" ps -a ;;
            images) rootfs_dm_show_command docker "docker images" images ;;
            enter|start|stop|remove)
                d=$(rootfs_dm_pick_installed docker) || continue
                [ -n "$d" ] || continue
                case "$c" in
                    enter) clear
                           rootfs_dm_run docker "Shell in $d" exec -it "$d" /bin/sh || true
                           read -rp "(press Enter)" _ || true ;;
                    start) rootfs_dm_run docker "Start $d" start "$d" ;;
                    stop) rootfs_dm_run docker "Stop $d" stop "$d" ;;
                    remove) tui_yesno "Remove" "Delete container '$d'?" &&
                            rootfs_dm_run docker "Remove $d" rm -f "$d" ;;
                esac ;;
            engine) cn_docker_menu ;;
            configure) rootfs_dm_config_menu docker ;;
            uninstall) rootfs_dm_remove docker ;;
            help) rootfs_dm_show_command docker "docker help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

rootfs_dm_menu_lxc() {
    local c d
    while true; do
        c=$(tui_menu_no_tags "LXC (distributions)" \
"Store: $(rootfs_dm_store lxc 2>/dev/null || echo /var/lib/lxc)
Templates: $(ls /usr/share/lxc/templates 2>/dev/null | wc -l | tr -d ' ')" \
            browse    "Create a container from the image catalogue" \
            installed "List containers" \
            enter     "Open a shell in a container" \
            start     "Start a container" \
            stop      "Stop a container" \
            remove    "Destroy a container" \
            adopt     "Open a container rootfs in the chroot workbench" \
            engine    "Open the full LXC manager (network profile, config)" \
            configure "Configure this manager" \
            uninstall "Uninstall LXC" \
            help      "Show lxc help" \
            back      "Back") || return 0
        case "$c" in
            browse) rootfs_dm_browse_install lxc ;;
            installed) rootfs_dm_show_command lxc "lxc-ls" ls --fancy ;;
            enter|start|stop|remove)
                d=$(rootfs_dm_pick_installed lxc) || continue
                [ -n "$d" ] || continue
                case "$c" in
                    enter) clear
                           rootfs_dm_run lxc "Attach to $d" attach -n "$d" || true
                           read -rp "(press Enter)" _ || true ;;
                    start) rootfs_dm_run lxc "Start $d" start -n "$d" -d ;;
                    stop) rootfs_dm_run lxc "Stop $d" stop -n "$d" ;;
                    remove) tui_yesno "Destroy" "Delete container '$d' and its filesystem?" &&
                            rootfs_dm_run lxc "Destroy $d" destroy -n "$d" ;;
                esac ;;
            adopt) rootfs_dm_adopt lxc ;;
            engine) cn_lxc_menu ;;
            configure) rootfs_dm_config_menu lxc ;;
            uninstall) rootfs_dm_remove lxc ;;
            help) rootfs_dm_show_command lxc "lxc-start help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

rootfs_dm_menu_incus() {
    local c d
    while true; do
        c=$(tui_menu_no_tags "Incus (distributions)" \
"State: $(cn_engine_state incus)
Images: images: (images.linuxcontainers.org)" \
            browse    "Launch an instance from the image catalogue" \
            installed "List instances" \
            enter     "Open a shell in an instance" \
            start     "Start an instance" \
            stop      "Stop an instance" \
            remove    "Delete an instance" \
            engine    "Open the full Incus manager (remotes, service)" \
            configure "Configure this manager" \
            uninstall "Uninstall Incus" \
            help      "Show incus help" \
            back      "Back") || return 0
        case "$c" in
            browse) rootfs_dm_browse_install incus ;;
            installed) rootfs_dm_show_command incus "incus list" list ;;
            enter|start|stop|remove)
                d=$(rootfs_dm_pick_installed incus) || continue
                [ -n "$d" ] || continue
                case "$c" in
                    enter) clear
                           rootfs_dm_run incus "Shell in $d" exec "$d" -- /bin/sh || true
                           read -rp "(press Enter)" _ || true ;;
                    start) rootfs_dm_run incus "Start $d" start "$d" ;;
                    stop) rootfs_dm_run incus "Stop $d" stop "$d" ;;
                    remove) tui_yesno "Delete" "Delete instance '$d' and its storage?" &&
                            rootfs_dm_run incus "Delete $d" delete "$d" ;;
                esac ;;
            engine) cn_lxd_incus_menu incus ;;
            configure) rootfs_dm_config_menu incus ;;
            uninstall) rootfs_dm_remove incus ;;
            help) rootfs_dm_show_command incus "incus help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

rootfs_dm_runtime_config_menu() { # <tag>
    local tag="$1" c
    while true; do
        case "$tag" in
            podman|docker)
                c=$(tui_menu_no_tags "Image & container defaults — $tag" \
"Pull policy : $(cn_conf_get "dm_${tag}_pull" always)
Create args : $(cn_conf_get "dm_${tag}_args" none)

These arguments are reused for every container this menu creates
from an image." \
                    pull "Pull policy: $(cn_conf_get "dm_${tag}_pull" always)" \
                    args "Extra create arguments" \
                    engine "Open the engine configuration" \
                    back "Back") || return 0
                case "$c" in
                    pull) cn_setting_choice "dm_${tag}_pull" "Pull policy" \
                              "always re-pulls the image; missing only pulls what is absent." \
                              "$(cn_conf_get "dm_${tag}_pull" always)" always missing never ;;
                    args) cn_setting_input "dm_${tag}_args" "Create arguments" \
                              "Arguments inserted before the image name (e.g. --network host -v /:/host):" "" ;;
                    engine) case "$tag" in podman) cn_podman_config_menu ;; docker) cn_docker_config_menu ;; esac ;;
                    back|"") return 0 ;;
                esac
                ;;
            lxc|incus)
                c=$(tui_menu_no_tags "Container defaults — $tag" \
"Network bridge: $(cn_conf_get "dm_${tag}_network" lxcbr0)
Autostart     : $(cn_conf_get "dm_${tag}_autostart" off)" \
                    network "Network bridge: $(cn_conf_get "dm_${tag}_network" lxcbr0)" \
                    autostart "Autostart new containers: $(cn_conf_get "dm_${tag}_autostart" off)" \
                    engine "Open the engine configuration" \
                    back "Back") || return 0
                case "$c" in
                    network) cn_setting_input "dm_${tag}_network" "Network bridge" \
                                 "Bridge new containers attach to:" "lxcbr0" ;;
                    autostart) cn_setting_bool "dm_${tag}_autostart" "Autostart" \
                                   "Start new containers with the host?" off ;;
                    engine) case "$tag" in lxc) cn_lxc_menu ;; incus) cn_lxd_incus_menu incus ;; esac ;;
                    back|"") return 0 ;;
                esac
                ;;
            distrobox|toolbx)
                c=$(tui_menu_no_tags "Container engine — $tag" \
"Manager preference: $(cn_conf_get dm_engine auto)
Detected engine   : $(cn_engine_binaries | tr '\n' ' ')" \
                    prefer "Preferred engine: $(cn_conf_get dm_engine auto)" \
                    engine "Open the engine configuration" \
                    check  "Verify the engine works now" \
                    back   "Back") || return 0
                case "$c" in
                    prefer) cn_setting_choice dm_engine "Preferred engine" \
                                "podman is rootless and needs no daemon; docker is the compatibility baseline." \
                                "$(cn_conf_get dm_engine auto)" auto podman docker ;;
                    engine) case "$(rootfs_dm_engine_preference "$tag")" in
                                docker) cn_docker_config_menu ;;
                                *) cn_podman_config_menu ;;
                            esac ;;
                    check) rootfs_dm_require_engine "$tag" &&
                               tui_msg "Engine ready" "$(cn_engine_binaries | tr '\n' ' ') is usable." ||
                               tui_msg "Engine unavailable" "No container engine is usable yet.

Install one with Rootfs > Containers & virtualization." ;;
                    back|"") return 0 ;;
                esac
                ;;
            *) return 1 ;;
        esac
    done
}

rootfs_dm_config_menu() { # <tag>
    local tag="$1" c value store detected
    while true; do
        store=$(get_config "dm_store_$tag" "")
        detected=$(rootfs_dm_store_default "$tag" 2>/dev/null || echo "none detected")
        local -a extra=()
        case "$tag" in
            podman|docker|lxc|incus) extra+=(runtime "Container runtime: images, pull policy, network") ;;
            distrobox|toolbx) extra+=(runtime "Container runtime: engine preference and configuration") ;;
        esac
        c=$(tui_menu_no_tags "Configure $(rootfs_dm_label "$tag")" \
"Rootfs store: ${store:-auto ($detected)}
Runs as: $(rootfs_dm_target_user "$tag")
Engine: $(rootfs_dm_engine_preference "$tag" 2>/dev/null || echo n/a)" \
            "${extra[@]}" \
            store   "Rootfs location: ${store:-automatic}" \
            detect  "Re-detect the rootfs location" \
            user    "Run as user: $(rootfs_dm_target_user "$tag")" \
            prefix  "Upstream install prefix: $(get_config dm_install_prefix /usr/local)" \
            settings "Show every saved setting for $tag" \
            reset   "Clear saved settings for $tag" \
            back    "Back") || return 0
        case "$c" in
            runtime) rootfs_dm_runtime_config_menu "$tag" || true ;;
            store)
                value=$(tui_input "Rootfs location" \
                    "Directory where $tag keeps installed distributions:" "${store:-$detected}") || continue
                [ -n "$value" ] || { set_config "dm_store_$tag" ""; continue; }
                case "$value" in /*) ;; *) tui_msg "Invalid path" "Enter an absolute directory path."; continue ;; esac
                if [ ! -d "$value" ]; then
                    tui_yesno "Create?" "$value does not exist.

Create it?" || continue
                    mkdir -p "$value" || { tui_msg "Error" "Could not create $value."; continue; }
                fi
                set_config "dm_store_$tag" "$value"
                tui_msg "Saved" "$tag rootfs location set to:
$value" ;;
            detect)
                if detected=$(rootfs_dm_store_default "$tag" 2>/dev/null); then
                    set_config "dm_store_$tag" ""
                    tui_msg "Detected" "Automatic detection found:
$detected

The manual override was cleared."
                else
                    tui_msg "Not found" \
"No rootfs store could be detected for $tag.

Either nothing is installed yet, or this manager keeps its
trees inside a container engine rather than as directories."
                fi ;;
            user)
                if rootfs_dm_runs_as_root "$tag"; then
                    tui_msg "Runs as root" "$tag runs as root and does not need an unprivileged user."
                    continue
                fi
                value=$(tui_input "Run as user" \
                    "$tag refuses to run as root; which user should it run as?" \
                    "$(rootfs_dm_target_user "$tag")") || continue
                [ -n "$value" ] || continue
                getent passwd "$value" >/dev/null 2>&1 || { tui_msg "Unknown user" "$value is not a user on this system."; continue; }
                set_config "dm_user_$tag" "$value"
                tui_msg "Saved" "$tag will run as $value." ;;
            prefix)
                value=$(tui_input "Install prefix" \
                    "Prefix used when installing managers from upstream:" "$(get_config dm_install_prefix /usr/local)") || continue
                case "$value" in /*) set_config dm_install_prefix "$value" ;;
                    *) tui_msg "Invalid path" "Enter an absolute path." ;; esac ;;
            settings)
                {
                    echo "SAVED SETTINGS — $tag"
                    echo
                    grep -E "^(dm_|cn_dm_engine)" "$(systui_config_file)" 2>/dev/null | sort || echo '(none)'
                    echo
                    echo "Detected store : $(rootfs_dm_store_default "$tag" 2>/dev/null || echo none)"
                    echo "Effective store: $(rootfs_dm_store "$tag" 2>/dev/null || echo none)"
                    echo "Runs as        : $(rootfs_dm_target_user "$tag")"
                    echo "Engine         : $(rootfs_dm_engine_preference "$tag" 2>/dev/null || echo n/a)"
                } > "$(rootfs_report_file)" 2>&1
                tui_text "$tag settings" "$(rootfs_report_file)" ;;
            reset)
                tui_yesno "Reset" "Clear systui's saved settings for $tag?" || continue
                set_config "dm_store_$tag" ""; set_config "dm_user_$tag" ""
                set_config "dm_${tag}_pull" ""; set_config "dm_${tag}_args" ""
                set_config "dm_${tag}_network" ""; set_config "dm_${tag}_autostart" ""
                tui_msg "Reset" "Saved settings for $tag were cleared." ;;
            back|"") return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

rootfs_dm_menu_one() { # <tag>
    case "$1" in
        podman) rootfs_dm_menu_podman ;;
        docker) rootfs_dm_menu_docker ;;
        lxc) rootfs_dm_menu_lxc ;;
        incus) rootfs_dm_menu_incus ;;
        *)
            # Engine-backed managers from the earlier layers get the engine
            # check first so their menus are never entered half-working.
            if rootfs_dm_needs_engine "$1" && rootfs_dm_available "$1"; then
                rootfs_dm_require_engine "$1" || return 0
            fi
            _systui_dm_menu_one_prev "$1" ;;
    esac
}

# Bulk installers iterate rootfs_dm_managers, so the new tools are picked up
# automatically; this override only adds engine readiness to the front door.
menu_rootfs_distro_managers() {
    local c tag _bin label status engine_line
    while true; do
        local -a args=(
            multi-install "Install multiple managers (SPACE to select)"
            engines       "Container runtimes & virtualization (engines, config)"
        )
        while IFS='|' read -r tag _bin label; do
            [ -n "$tag" ] || continue
            if rootfs_dm_available "$tag"; then status="installed"; else status="not installed"; fi
            args+=("$tag" "$label — $status")
        done <<< "$(rootfs_dm_managers)"
        args+=(about "How these differ from bootstrap backends")
        args+=(back "Back")
        engine_line=$(cn_engine_binaries 2>/dev/null | tr '\n' ' ')
        c=$(tui_menu_no_tags "Distro Managers" \
"Engines: ${engine_line:-none installed}

Select a manager, install several with SPACE, or configure the
container runtimes they depend on." "${args[@]}") || return 0
        case "$c" in
            multi-install) rootfs_dm_install_multiple_managers ;;
            engines) menu_rootfs_containers ;;
            about)
                tui_msg "Distro managers vs bootstrap backends" \
"Bootstrap backends (debootstrap, mmdebstrap, pacstrap, rinse...)
build a rootfs to YOUR target directory, release, mirror and
architecture — the Rootfs Builder asks for all four.

Distro managers ship one pinned version per distribution into
their own store and choose their own mirrors, so those options
do not apply. Some also refuse to run as root.

Container-backed managers (podman, docker, lxc, incus) live in
Containers & virtualization where their daemon, storage and
network settings are shared with the rest of systui." ;;
            back|"") return 0 ;;
            *)
                if rootfs_dm_available "$c"; then
                    rootfs_dm_menu_one "$c"
                elif tui_yesno "$(rootfs_dm_label "$c")" \
"$c is not installed on this host.

$(rootfs_dm_install_hint "$c")

Install it now?"; then
                    rootfs_dm_install "$c"
                    rootfs_dm_available "$c" && rootfs_dm_menu_one "$c"
                fi ;;
        esac
    done
}

return 0 2>/dev/null || true
