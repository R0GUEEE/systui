# shellcheck shell=bash
###############################################################################
# Distro-manager Docker image normalization
#
# Docker Official Images are multi-architecture. Search backends can still
# return historical architecture namespaces such as aarch64/debian or
# arm64v8/ubuntu. Passing those legacy aliases to udocker/proot/chroot managers
# can fail manifest resolution even though the canonical official image has a
# valid ARM64 manifest. Normalize only a conservative allowlist of known Docker
# Official Images; arbitrary third-party namespaces are preserved verbatim.
###############################################################################

rootfs_dm_normalize_image_ref() { # <image-ref>
    local ref="$1" rest
    case "$ref" in
        aarch64/*) rest=${ref#aarch64/} ;;
        arm64/*)   rest=${ref#arm64/} ;;
        arm64v8/*) rest=${ref#arm64v8/} ;;
        *) printf '%s\n' "$ref"; return 0 ;;
    esac

    case "$rest" in
        debian|debian:*|ubuntu|ubuntu:*|alpine|alpine:*|archlinux|archlinux:*|busybox|busybox:*)
            printf '%s\n' "$rest"
            ;;
        *)
            printf '%s\n' "$ref"
            ;;
    esac
}

rootfs_dm_install_image() { # <tag> <image> [name]
    local tag="$1" image="$2" name="${3:-}" normalized
    normalized=$(rootfs_dm_normalize_image_ref "$image")
    if [ "$normalized" != "$image" ]; then
        log "Distro manager: normalized legacy ARM image '$image' -> '$normalized'"
        image=$normalized
    fi

    case "$tag" in
        proot-distro|chroot-distro)
            # Current CLIs use: <tool> install [opts] IMAGE.
            rootfs_dm_run "$tag" "Install $image via $tag" install "$image"
            ;;
        distrobox)
            [ -n "$name" ] || name=$(printf '%s' "$image" | sed 's|.*/||; s/:.*//; s/[^A-Za-z0-9_.-]/-/g')
            rootfs_dm_run "$tag" "Create distrobox $name" create --yes --name "$name" --image "$image"
            ;;
        toolbx)
            [ -n "$name" ] || name=$(printf '%s' "$image" | sed 's|.*/||; s/:.*//; s/[^A-Za-z0-9_.-]/-/g')
            rootfs_dm_run "$tag" "Create Toolbx $name" create --image "$image" "$name"
            ;;
        udocker)
            [ -n "$name" ] || name=$(printf '%s' "$image" | sed 's|.*/||; s/:.*//; s/[^A-Za-z0-9_.-]/-/g')
            rootfs_dm_run "$tag" "Pull $image" pull "$image" || return 1
            rootfs_dm_run "$tag" "Create udocker container $name" create "--name=$name" "$image"
            ;;
        *) return 2 ;;
    esac
}
