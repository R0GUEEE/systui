# shellcheck shell=bash
# PHASE 99 — final distro-manager/Distrobox compatibility.
# Fix Distrobox dependency detection, installed-container parsing, image fallback,
# and package availability without changing the other distro-manager backends.

if declare -F rootfs_dm_package >/dev/null 2>&1 \
    && ! declare -F _systui_rootfs_dm_package_before_distrobox_final >/dev/null 2>&1; then
    eval "$(declare -f rootfs_dm_package | sed '1s/^rootfs_dm_package[[:space:]]*()/_systui_rootfs_dm_package_before_distrobox_final ()/')"
fi
if declare -F rootfs_dm_installed_names >/dev/null 2>&1 \
    && ! declare -F _systui_rootfs_dm_installed_names_before_distrobox_final >/dev/null 2>&1; then
    eval "$(declare -f rootfs_dm_installed_names | sed '1s/^rootfs_dm_installed_names[[:space:]]*()/_systui_rootfs_dm_installed_names_before_distrobox_final ()/')"
fi
if declare -F rootfs_dm_install >/dev/null 2>&1 \
    && ! declare -F _systui_rootfs_dm_install_before_distrobox_final >/dev/null 2>&1; then
    eval "$(declare -f rootfs_dm_install | sed '1s/^rootfs_dm_install[[:space:]]*()/_systui_rootfs_dm_install_before_distrobox_final ()/')"
fi

rootfs_dm_repo_has_package() { # <package>
    local pkg="$1"
    [ -n "$pkg" ] || return 1
    case "${PM:-}" in
        apt) command -v apt-cache >/dev/null 2>&1 && apt-cache show "$pkg" >/dev/null 2>&1 ;;
        apk) apk search -e "$pkg" 2>/dev/null | grep -qx "$pkg" ;;
        pacman) pacman -Si "$pkg" >/dev/null 2>&1 ;;
        dnf) dnf -q list --available "$pkg" >/dev/null 2>&1 || dnf -q list --installed "$pkg" >/dev/null 2>&1 ;;
        yum) yum -q list available "$pkg" >/dev/null 2>&1 || yum -q list installed "$pkg" >/dev/null 2>&1 ;;
        zypper) zypper --non-interactive search --match-exact "$pkg" 2>/dev/null | grep -Eq "(^|[|[:space:]])${pkg}([|[:space:]]|$)" ;;
        xbps) xbps-query -Rs "^${pkg}-[0-9]" 2>/dev/null | grep -q . ;;
        emerge) command -v emerge >/dev/null 2>&1 && emerge --search "$pkg" 2>/dev/null | grep -Eq "^[* ]*${pkg}([[:space:]]|$)|/${pkg}([[:space:]]|$)" ;;
        *) return 1 ;;
    esac
}

rootfs_dm_package() {
    if [ "${1:-}" = distrobox ]; then
        rootfs_dm_repo_has_package distrobox && printf 'distrobox\n'
        return 0
    fi
    _systui_rootfs_dm_package_before_distrobox_final "$@"
}

rootfs_dm_distrobox_engine() {
    local e
    for e in podman docker lilipod; do
        command -v "$e" >/dev/null 2>&1 && { printf '%s\n' "$e"; return 0; }
    done
    return 1
}

rootfs_dm_distrobox_engine_package() {
    case "${PM:-}" in
        apt|apk|pacman|dnf|yum|zypper|xbps) printf 'podman\n' ;;
        emerge) printf 'app-containers/podman\n' ;;
        *) return 1 ;;
    esac
}

rootfs_dm_distrobox_ensure_engine() {
    local engine pkg
    engine=$(rootfs_dm_distrobox_engine 2>/dev/null || true)
    [ -n "$engine" ] && return 0

    pkg=$(rootfs_dm_distrobox_engine_package 2>/dev/null || true)
    if [ -n "$pkg" ] && rootfs_dm_repo_has_package "${pkg##*/}"; then
        if tui_yesno "Distrobox dependency" \
            "Distrobox requires Podman, Docker or Lilipod. None was found.\n\nInstall Podman now?"; then
            pm_install "$pkg" || return 1
            engine=$(rootfs_dm_distrobox_engine 2>/dev/null || true)
            [ -n "$engine" ] && return 0
        fi
    fi

    tui_msg "Distrobox dependency missing" \
"Distrobox requires a working container manager. Install and configure one of:\n\n  podman\n  docker\n  lilipod\n\nRootless Podman is the recommended default on Linux."
    return 1
}

rootfs_dm_distrobox_static_images() {
    cat <<'EOF'
quay.io/toolbx-images/alpine-toolbox:latest|Alpine Toolbox
quay.io/toolbx/arch-toolbox:latest|Arch Linux Toolbox
quay.io/toolbx-images/debian-toolbox:13|Debian 13 Toolbox
quay.io/toolbx-images/fedora-toolbox:latest|Fedora Toolbox
quay.io/toolbx-images/ubuntu-toolbox:latest|Ubuntu Toolbox
docker.io/library/alpine:latest|Alpine
docker.io/library/archlinux:latest|Arch Linux
docker.io/library/debian:stable|Debian stable
docker.io/library/fedora:latest|Fedora
docker.io/library/ubuntu:latest|Ubuntu
registry.opensuse.org/opensuse/tumbleweed:latest|openSUSE Tumbleweed
quay.io/centos/centos:stream9|CentOS Stream 9
EOF
}

rootfs_dm_distrobox_compatibility() {
    local out parsed
    out=$(rootfs_dm_capture distrobox create --compatibility 2>/dev/null || true)
    if [ -n "$out" ]; then
        parsed=$(printf '%s\n' "$out" | tr ' \t|,()' '\n' |
            sed -E 's/^["`]+//; s/["`,;]+$//' |
            grep -E '^(docker\.io|quay\.io|ghcr\.io|registry\.[A-Za-z0-9._-]+|[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._/-]*)(:[A-Za-z0-9._-]+)?$' |
            sort -u | awk '{print $0 "|compatible image"}' || true)
        [ -n "$parsed" ] && { printf '%s\n' "$parsed"; return 0; }
    fi
    rootfs_dm_distrobox_static_images
}

rootfs_dm_distrobox_list_names() {
    local out
    out=$(rootfs_dm_capture distrobox list --no-color 2>/dev/null ||
          rootfs_dm_capture distrobox list 2>/dev/null || true)
    [ -n "$out" ] || return 1
    printf '%s\n' "$out" | awk -F'|' '
        function trim(s){gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s}
        /\|/ {
            f1=trim($1); f2=trim($2)
            if (toupper(f1)=="ID" || toupper(f2)=="NAME") next
            if (f2 ~ /^[A-Za-z0-9_.-]+$/) print f2
            else if (f1 ~ /^[A-Za-z0-9_.-]+$/ && f1 !~ /^[0-9a-f]{8,}$/) print f1
        }
    ' | sort -u
}

rootfs_dm_installed_names() {
    if [ "${1:-}" = distrobox ]; then
        rootfs_dm_distrobox_list_names
        return $?
    fi
    _systui_rootfs_dm_installed_names_before_distrobox_final "$@"
}

rootfs_dm_install() {
    if [ "${1:-}" != distrobox ]; then
        _systui_rootfs_dm_install_before_distrobox_final "$@"
        return $?
    fi

    _systui_rootfs_dm_install_before_distrobox_final distrobox || return $?
    rootfs_dm_distrobox_ensure_engine || true
}

rootfs_dm_menu_distrobox() {
    local c d engine
    while true; do
        engine=$(rootfs_dm_distrobox_engine 2>/dev/null || printf 'missing')
        c=$(tui_menu_no_tags "$(rootfs_dm_label distrobox)" \
            "Container engine: $engine. Distrobox requires Podman, Docker or Lilipod." \
            install   "Install or update Distrobox" \
            engine    "Check/install container engine" \
            browse    "Browse/select/create compatible Distroboxes" \
            installed "List Distroboxes" \
            enter     "Enter a Distrobox" \
            stop      "Stop a Distrobox" \
            remove    "Remove a Distrobox" \
            configure "Configure run-as user" \
            uninstall "Uninstall Distrobox" \
            help      "Show Distrobox help" \
            back      "Back") || return 0
        case "$c" in
            install) rootfs_dm_install distrobox ;;
            engine) rootfs_dm_distrobox_ensure_engine || true ;;
            browse)
                rootfs_dm_distrobox_ensure_engine || continue
                rootfs_dm_browse_install distrobox ;;
            installed) rootfs_dm_show_command distrobox "distrobox list" list --no-color ;;
            enter)
                rootfs_dm_distrobox_ensure_engine || continue
                d=$(rootfs_dm_pick_installed distrobox) || continue
                [ -n "$d" ] || continue
                clear
                rootfs_dm_run distrobox "Enter $d" enter "$d" || true
                read -rp "(press Enter)" _ || true ;;
            stop)
                d=$(rootfs_dm_pick_installed distrobox) || continue
                [ -n "$d" ] || continue
                rootfs_dm_run distrobox "Stop $d" stop --yes "$d" ||
                    rootfs_dm_run distrobox "Stop $d" stop "$d" || true ;;
            remove)
                d=$(rootfs_dm_pick_installed distrobox) || continue
                [ -n "$d" ] || continue
                tui_yesno "Remove" "Delete Distrobox '$d'?" || continue
                rootfs_dm_run distrobox "Remove $d" rm --force --yes "$d" || true ;;
            configure) rootfs_dm_config_menu distrobox ;;
            uninstall) rootfs_dm_remove distrobox ;;
            help) rootfs_dm_show_command distrobox "distrobox help" --help ;;
            back|'') return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
