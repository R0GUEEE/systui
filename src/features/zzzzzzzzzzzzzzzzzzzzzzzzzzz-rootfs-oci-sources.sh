# shellcheck shell=bash
###############################################################################
# ROOTFS OCI SOURCES — import OCI/container images as rootfs tarballs
###############################################################################

rootfs_oci_engine() {
    if command -v podman >/dev/null 2>&1; then printf 'podman\n'
    elif command -v docker >/dev/null 2>&1; then printf 'docker\n'
    elif command -v skopeo >/dev/null 2>&1; then printf 'skopeo\n'
    else return 1
    fi
}

rootfs_oci_sanitize_name() {
    printf '%s' "$1" | sed 's|^[a-zA-Z0-9+.-]*://||; s|[^A-Za-z0-9_.-]|-|g'
}

rootfs_oci_export_with_engine() { # <engine> <image> <target-dir>
    local engine="$1" image="$2" target="$3" cid
    mkdir -p "$target" || return 1
    case "$engine" in
        podman)
            run_cmd "Pull OCI image" podman pull "$image" || return 1
            cid=$(podman create "$image") || return 1
            podman export "$cid" | tar -xf - -C "$target"
            local rc=$?
            podman rm -f "$cid" >/dev/null 2>&1 || true
            return "$rc"
            ;;
        docker)
            run_cmd "Pull OCI image" docker pull "$image" || return 1
            cid=$(docker create "$image") || return 1
            docker export "$cid" | tar -xf - -C "$target"
            local rc=$?
            docker rm -f "$cid" >/dev/null 2>&1 || true
            return "$rc"
            ;;
        skopeo)
            # Skopeo alone copies image manifests/layers; use dir: transport and
            # apply layers in manifest order, including OCI whiteouts.
            local tmp manifest layer digest layerfile wh
            tmp=$(mktemp -d "${SYSTUI_TMP:-${TMPDIR:-/tmp}}/systui-oci.XXXXXX") || return 1
            run_cmd "Copy OCI image" skopeo copy "docker://$image" "dir:$tmp/image" || { rm -rf "$tmp"; return 1; }
            manifest="$tmp/image/manifest.json"
            [ -r "$manifest" ] || { rm -rf "$tmp"; return 1; }
            if command -v jq >/dev/null 2>&1; then
                while IFS= read -r digest; do
                    [ -n "$digest" ] || continue
                    layerfile="$tmp/image/${digest#sha256:}"
                    [ -r "$layerfile" ] || continue
                    tar -xf "$layerfile" -C "$target" || { rm -rf "$tmp"; return 1; }
                    while IFS= read -r wh; do
                        case "$(basename "$wh")" in
                            .wh..wh..opq) find "$(dirname "$target/$wh")" -mindepth 1 -maxdepth 1 ! -name '.wh.*' -exec rm -rf -- {} + 2>/dev/null || true ;;
                            .wh.*) rm -rf -- "$(dirname "$target/$wh")/$(basename "$wh" | sed 's/^\.wh\.//')" 2>/dev/null || true ;;
                        esac
                        rm -f -- "$target/$wh" 2>/dev/null || true
                    done < <(find "$target" -name '.wh.*' -print 2>/dev/null)
                done < <(jq -r '.layers[].digest' "$manifest")
            else
                rm -rf "$tmp"
                tui_msg "OCI importer" "skopeo import requires jq when Podman/Docker are unavailable."
                return 1
            fi
            rm -rf "$tmp"
            ;;
        *) return 1 ;;
    esac
}

rootfs_download_oci_image() { # <image-ref> [source-tag]
    local image="$1" source="${2:-oci}" engine tmp name output target
    [ -n "$image" ] || return 1
    engine=$(rootfs_oci_engine) || {
        tui_msg "OCI importer" "Install podman, docker, or skopeo to import OCI/container images."
        return 1
    }
    tmp=$(mktemp -d "${SYSTUI_TMP:-${TMPDIR:-/tmp}}/systui-oci-rootfs.XXXXXX") || return 1
    mkdir -p "$tmp/rootfs" "$ROOTFS_BASE"
    rootfs_oci_export_with_engine "$engine" "$image" "$tmp/rootfs" || { rm -rf "$tmp"; return 1; }
    name="oci-$(rootfs_oci_sanitize_name "$image")"
    output="$ROOTFS_BASE/$name.tar.gz"
    target="$ROOTFS_BASE/$name"
    rootfs_tar_create gz "$tmp/rootfs" "$output" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    if tui_yesno "Unpack OCI rootfs" "Imported $image using $engine.\n\nArchive:\n$output\n\nUnpack now to:\n$target ?"; then
        rootfs_download_unpack "$output" "$target" || return 1
    fi
    tui_msg "OCI rootfs imported" "Image:\n$image\n\nArchive:\n$output${target:+\n\nTarget:\n$target}"
}

rootfs_oci_known_image_menu() {
    local c image
    c=$(tui_menu "OCI image catalogue" "Choose a common public image or enter any OCI reference:" \
        debian "Docker Hub — Debian" \
        ubuntu "Docker Hub — Ubuntu" \
        alpine "Docker Hub — Alpine" \
        arch "Docker Hub — Arch Linux" \
        fedora "Fedora Registry — Fedora" \
        centos "Quay — CentOS Stream" \
        rocky "Quay/Docker Hub — Rocky Linux" \
        almalinux "Docker Hub — AlmaLinux" \
        opensuse "Registry — openSUSE" \
        kali "Docker Hub — Kali Linux" \
        busybox "Docker Hub — BusyBox" \
        ghcr "GitHub Container Registry (ghcr.io)" \
        quay "Quay.io image" \
        custom "Custom OCI/Docker registry reference" \
        back "Back") || return 0
    case "$c" in
        debian) image=$(tui_input "Debian OCI" "Image tag/reference:" "debian:forky") ;;
        ubuntu) image=$(tui_input "Ubuntu OCI" "Image tag/reference:" "ubuntu:26.04") ;;
        alpine) image=$(tui_input "Alpine OCI" "Image tag/reference:" "alpine:latest") ;;
        arch) image=$(tui_input "Arch OCI" "Image tag/reference:" "archlinux:latest") ;;
        fedora) image=$(tui_input "Fedora OCI" "Image tag/reference:" "registry.fedoraproject.org/fedora:latest") ;;
        centos) image=$(tui_input "CentOS OCI" "Image tag/reference:" "quay.io/centos/centos:stream10") ;;
        rocky) image=$(tui_input "Rocky OCI" "Image tag/reference:" "rockylinux:latest") ;;
        almalinux) image=$(tui_input "AlmaLinux OCI" "Image tag/reference:" "almalinux:latest") ;;
        opensuse) image=$(tui_input "openSUSE OCI" "Image tag/reference:" "opensuse/tumbleweed:latest") ;;
        kali) image=$(tui_input "Kali OCI" "Image tag/reference:" "kalilinux/kali-rolling:latest") ;;
        busybox) image=$(tui_input "BusyBox OCI" "Image tag/reference:" "busybox:latest") ;;
        ghcr) image=$(tui_input "GitHub Container Registry" "ghcr.io/OWNER/IMAGE:TAG" "ghcr.io/") ;;
        quay) image=$(tui_input "Quay.io" "quay.io/ORG/IMAGE:TAG" "quay.io/") ;;
        custom) image=$(tui_input "OCI image" "Registry/image:tag or image@digest:" "") ;;
        *) return 0 ;;
    esac
    [ -n "$image" ] || return 0
    rootfs_download_oci_image "$image" "$c"
}

if declare -F rootfs_download_source_hub >/dev/null 2>&1 \
    && ! declare -F _rootfs_download_source_hub_before_oci >/dev/null 2>&1; then
    eval "$(declare -f rootfs_download_source_hub | sed '1s/^rootfs_download_source_hub[[:space:]]*()/_rootfs_download_source_hub_before_oci ()/')"
fi

rootfs_download_source_hub() {
    local c
    while true; do
        c=$(tui_menu 'Rootfs download sources' \
            'Browse live rootfs repositories and OCI/container registries.' \
            oci 'OCI/container images — Podman/Docker/GHCR/Quay/custom registries' \
            debian 'Debian official Docker/rootfs artifacts' \
            ubuntu 'Ubuntu Base official rootfs' \
            alpine 'Alpine official minirootfs' \
            arch 'Arch Linux / ArchLinuxARM bootstrap rootfs' \
            void 'Void Linux official ROOTFS images' \
            gentoo 'Gentoo official stage3 autobuilds' \
            lxc 'Linux Containers multi-distro image catalogue' \
            legacy 'Legacy official/community compatibility catalogue' \
            back 'Back') || return 0
        case "$c" in
            oci) rootfs_oci_known_image_menu || true ;;
            debian) rootfs_source_debian || true ;;
            ubuntu) rootfs_source_ubuntu_base || true ;;
            alpine) rootfs_source_alpine || true ;;
            arch) rootfs_source_arch || true ;;
            void) rootfs_source_void || true ;;
            gentoo) rootfs_source_gentoo || true ;;
            lxc) rootfs_source_linuxcontainers || true ;;
            legacy)
                if declare -F _rootfs_download_before_web_catalogue >/dev/null 2>&1; then _rootfs_download_before_web_catalogue || true
                else tui_msg 'Rootfs download' 'Legacy downloader is unavailable.'; fi ;;
            back|'') return 0 ;;
        esac
    done
}

rootfs_download() { rootfs_download_source_hub; }

return 0 2>/dev/null || true
