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
systui_dm_save_fn rootfs_dm_browse_install _systui_dm_browse_prev


# ---------------------------------------------------------------------------
# Catalogue
# ---------------------------------------------------------------------------

rootfs_dm_managers() {
    _systui_dm_managers_prev
}

# Docker, Podman, LXC and Incus are managed by Containers & virtualization,
# where their daemon, storage and network settings live. The distro-manager
# menu links there instead of offering a second, thinner copy of each menu.
rootfs_dm_container_tools() {
    printf '%s\n' podman docker lxc incus
}

rootfs_dm_is_container_tool() { # <tag>
    case "$1" in podman|docker|lxc|incus) return 0 ;; *) return 1 ;; esac
}

rootfs_dm_engine_tags() { # managers that cannot work without an external engine
    printf '%s\n' distrobox toolbx
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
            policy=$(cn_conf_get "dm_${tag}_pull" "$(cn_conf_get dm_pull always)")
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





# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


rootfs_dm_config_menu() { # <tag>
    local tag="$1" c value store detected
    while true; do
        store=$(get_config "dm_store_$tag" "")
        detected=$(rootfs_dm_store_default "$tag" 2>/dev/null || echo "none detected")
        c=$(tui_menu_no_tags "Configure $(rootfs_dm_label "$tag")" \
"Rootfs store: ${store:-auto ($detected)}
Runs as     : $(rootfs_dm_target_user "$tag")
Engine      : $(rootfs_dm_engine_preference "$tag" 2>/dev/null || echo n/a)

Install prefix, engine preference and pull policy are shared by
every manager — see 'Defaults' on the Distro managers menu." \
            store    "Rootfs location: ${store:-automatic}" \
            detect   "Re-detect the rootfs location" \
            user     "Run as user: $(rootfs_dm_target_user "$tag")" \
            settings "Show every saved setting for $tag" \
            reset    "Clear saved settings for $tag" \
            back     "Back") || return 0
        case "$c" in
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
            settings)
                {
                    echo "SAVED SETTINGS — $tag"
                    echo
                    grep -E "^(dm_|cn_dm_)" "$(systui_config_file)" 2>/dev/null | sort || echo '(none)'
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
                tui_msg "Reset" "Saved settings for $tag were cleared." ;;
            back|"") return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

rootfs_dm_menu_one() { # <tag>
    if rootfs_dm_is_container_tool "$1"; then
        # Defence in depth: a stale tag from an older menu still lands on the
        # real engine menu instead of "unsupported manager".
        menu_rootfs_containers
        return 0
    fi
    # Engine-backed managers get the engine check first so their menus are
    # never entered half-working.
    if rootfs_dm_needs_engine "$1" && rootfs_dm_available "$1"; then
        rootfs_dm_require_engine "$1" || return 0
    fi
    _systui_dm_menu_one_prev "$1"
}

# Bulk installers iterate rootfs_dm_managers, so the new tools are picked up
# automatically; this override only adds engine readiness to the front door.
menu_rootfs_distro_managers() {
    local c tag _bin label status
    while true; do
        local -a args=(
            multi-install "Install multiple managers (SPACE to select)"
            defaults      "Defaults — install prefix, engine, pull policy"
            engines       "Container engines & virtualization"
        )
        while IFS='|' read -r tag _bin label; do
            [ -n "$tag" ] || continue
            if rootfs_dm_available "$tag"; then status="installed"; else status="not installed"; fi
            args+=("$tag" "$label — $status")
        done <<< "$(rootfs_dm_managers)"
        args+=(about "How these differ from bootstrap backends")
        args+=(back "Back")
        c=$(tui_menu_no_tags "Distro Managers" \
"Engines: $(cn_engine_binaries 2>/dev/null | tr '\n' ' ' || true)

These install a ready-made distribution into their own store.
Docker, Podman, LXC and Incus live under Containers & virtualization." \
            "${args[@]}") || return 0
        case "$c" in
            multi-install) rootfs_dm_install_multiple_managers ;;
            defaults) rootfs_dm_settings_menu ;;
            engines) menu_rootfs_containers ;;
            about)
                tui_msg "Distro managers vs bootstrap backends" \
"Bootstrap backends (debootstrap, mmdebstrap, pacstrap, rinse...)
build a rootfs to YOUR target directory, release, mirror and
architecture — the Rootfs Builder asks for all four.

Distro managers ship one pinned version per distribution into
their own store and choose their own mirrors, so those options
do not apply. Some also refuse to run as root.

Install with a manager, then open the tree in the workbench.

Container engines (docker, podman) and system containers (lxc,
incus) have their own front door: Containers & virtualization." ;;
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



# ---------------------------------------------------------------------------
# Image browsing for the container-backed managers
#
# The earlier browse workflow only understood proot-distro, chroot-distro,
# distrobox, toolbx and udocker, so choosing "browse" for podman/docker/lxc/
# incus did nothing at all. One implementation now covers them.
# ---------------------------------------------------------------------------

rootfs_dm_browse_install() { # <tag>
    local tag="$1" query="" selected="" image name failed=""
    case "$tag" in
        podman|docker|lxc|incus) : ;;
        *) _systui_dm_browse_prev "$tag"; return $? ;;
    esac

    case "$tag" in
        podman|docker)
            query=$(tui_input "Create from an image" \
                "Search Docker Hub (blank = curated distribution list):" "") || return 0
            ;;
        *)
            query=""
            ;;
    esac

    local select_rc=0
    selected=$(rootfs_dm_select_catalog_entries "$tag" "$query") || select_rc=$?
    case "$select_rc" in
        0) ;;
        2) return 0 ;;
        *)
            selected=$(tui_input "Create with $tag" \
                "No catalogue entries were returned. Enter an image reference (blank cancels):" "") || return 0
            [ -n "$selected" ] || return 0
            ;;
    esac

    while IFS= read -r image; do
        [ -n "$image" ] || continue
        name=$(printf '%s' "$image" | sed 's|.*/||; s/:.*//; s/[^A-Za-z0-9_.-]/-/g')
        name=$(tui_input "$(rootfs_dm_label "$tag")" \
            "Name for the container created from $image:" "$name") || continue
        [ -n "$name" ] || continue
        rootfs_dm_install_image "$tag" "$image" "$name" || failed="$failed $image"
    done <<< "$selected"

    [ -z "$failed" ] || tui_msg "Some containers failed" \
"Failed:$failed

See $LOGFILE for the command output."
}

# ---------------------------------------------------------------------------
# Global distro-manager defaults
#
# Settings that are not per manager live here instead of being repeated in
# every manager's configuration menu.
# ---------------------------------------------------------------------------

rootfs_dm_settings_menu() {
    local c value
    while true; do
        c=$(tui_menu_no_tags "Distro manager defaults" \
"Upstream install prefix : $(get_config dm_install_prefix /usr/local)
Preferred engine        : $(cn_conf_get dm_engine auto)
Image pull policy       : $(cn_conf_get dm_pull always)
Detected engines        : $(cn_engine_binaries | tr '\n' ' ')" \
            prefix "Upstream install prefix: $(get_config dm_install_prefix /usr/local)" \
            engine "Preferred engine: $(cn_conf_get dm_engine auto)" \
            pull   "Image pull policy: $(cn_conf_get dm_pull always)" \
            reset  "Reset these defaults" \
            back   "Back") || return 0
        case "$c" in
            prefix)
                value=$(tui_input "Install prefix" \
                    "Prefix used when installing managers from upstream:" \
                    "$(get_config dm_install_prefix /usr/local)") || continue
                case "$value" in /*) set_config dm_install_prefix "$value" ;;
                    *) tui_msg "Invalid path" "Enter an absolute path." ;; esac ;;
            engine) cn_setting_choice dm_engine "Preferred engine" \
                        "Distrobox and Toolbx use this engine when both are installed." \
                        "$(cn_conf_get dm_engine auto)" auto podman docker ;;
            pull) cn_setting_choice dm_pull "Image pull policy" \
                        "always downloads on every create, missing only what is absent, never skips pulls entirely." \
                        "$(cn_conf_get dm_pull always)" always missing never ;;
            reset)
                tui_yesno "Reset defaults" "Clear the shared distro-manager defaults?" || continue
                set_config dm_install_prefix ""; set_config dm_engine ""; set_config dm_pull ""
                tui_msg "Reset" "Shared defaults cleared." ;;
            back|"") return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
