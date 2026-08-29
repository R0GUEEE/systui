# shellcheck shell=bash
###############################################################################
# ROOTFS DOWNLOAD — prebuilt official/community root filesystems
###############################################################################

rootfs_download_arch_menu() { # <distro>
    local distro="$1" _arch _label _state default=0
    local -a items=()
    while IFS='|' read -r _arch _label; do
        [ -n "$_arch" ] || continue
        if [ "$_arch" = amd64 ]; then _state=on; default=1; else _state=off; fi
        items+=("$_arch" "${_label:-$_arch}" "$_state")
    done <<< "$(rootfs_distro_archs "$distro" 2>/dev/null)"
    [ ${#items[@]} -gt 0 ] || return 1
    [ "$default" = 1 ] || items[2]=on
    tui_radio "Download rootfs" "Target architecture (SPACE to select):" "${items[@]}"
}

rootfs_download_distro_menu() {
    tui_radio "Download rootfs" "Distribution (same catalogue as Build):" \
        debian "Debian" on devuan "Devuan" off ubuntu "Ubuntu" off kali "Kali Linux" off \
        alpine "Alpine Linux" off arch "Arch Linux" off fedora "Fedora" off \
        opensuse "openSUSE Leap" off tumbleweed "openSUSE Tumbleweed" off \
        gentoo "Gentoo" off void "Void Linux" off bedrock "Bedrock Linux" off
}

rootfs_download_community_url() { # <distro> <release> <arch>
    local distro="$1" release="$2" arch="$3" image_distro="$1" image_release="$2" base html latest
    case "$distro" in
        arch) image_distro=archlinux; image_release=current ;;
        void) image_distro=voidlinux ;;
        tumbleweed) image_distro=opensuse; image_release=tumbleweed ;;
        bedrock) return 1 ;;
    esac
    base="https://images.linuxcontainers.org/images/$image_distro/$image_release/$arch/default"
    html=$(rootfs_fetch_text "$base/" 2>/dev/null) || return 1
    latest=$(printf '%s\n' "$html" | grep -oE 'href="[0-9]{8}_[0-9]{2}:[0-9]{2}/"' | sed 's/^href="//;s|/"$||' | sort | tail -1)
    [ -n "$latest" ] || return 1
    printf '%s/%s/rootfs.tar.xz\n' "$base" "$latest"
}

rootfs_download_official_url() { # <distro> <release> <arch>
    local distro="$1" release="$2" arch="$3" base html file native_arch
    case "$distro" in
        ubuntu)
            base="https://cdimage.ubuntu.com/ubuntu-base/releases/$release/release"
            html=$(rootfs_fetch_text "$base/" 2>/dev/null) || return 1
            file=$(printf '%s\n' "$html" | grep -oE "ubuntu-base-[0-9.]+-base-${arch}\\.tar\\.gz" | sort | tail -1)
            [ -n "$file" ] || return 1; printf '%s/%s\n' "$base" "$file" ;;
        alpine)
            case "$arch" in amd64) native_arch=x86_64 ;; arm64) native_arch=aarch64 ;; armhf) native_arch=armv7 ;; i386) native_arch=x86 ;; riscv64) native_arch=riscv64 ;; *) return 1 ;; esac
            base="https://dl-cdn.alpinelinux.org/alpine/$release/releases/$native_arch"
            html=$(rootfs_fetch_text "$base/" 2>/dev/null) || return 1
            file=$(printf '%s\n' "$html" | grep -oE "alpine-minirootfs-[0-9.]+-${native_arch}\\.tar\\.gz" | sort | tail -1)
            [ -n "$file" ] || return 1; printf '%s/%s\n' "$base" "$file" ;;
        arch)
            case "$arch" in amd64) printf '%s\n' "https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst" ;; arm64) printf '%s\n' "http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz" ;; armhf) printf '%s\n' "http://os.archlinuxarm.org/os/ArchLinuxARM-armv7-latest.tar.gz" ;; *) return 1 ;; esac ;;
        void)
            case "$arch" in amd64) native_arch=x86_64 ;; arm64) native_arch=aarch64 ;; armhf) native_arch=armv7l ;; i386) native_arch=i686 ;; riscv64) native_arch=riscv64 ;; *) return 1 ;; esac
            base="https://repo-default.voidlinux.org/live/current"
            html=$(rootfs_fetch_text "$base/" 2>/dev/null) || return 1
            file=$(printf '%s\n' "$html" | grep -oE "void-${native_arch}-ROOTFS-[0-9_]+\\.tar\\.xz" | sort | tail -1)
            [ -n "$file" ] || return 1; printf '%s/%s\n' "$base" "$file" ;;
        *) return 1 ;;
    esac
}

rootfs_download_to_gz() { # <url> <output.tar.gz>
    local url="$1" output="$2" tmp archive work packroot first count
    tmp=$(mktemp -d "${SYSTUI_TMP:-${TMPDIR:-/tmp}}/systui-rootfs-download.XXXXXX") || return 1
    archive="$tmp/source"; work="$tmp/rootfs"; mkdir -p "$work" "$(dirname "$output")"
    run_cmd "Downloading prebuilt rootfs" rootfs_fetch_file "$url" "$archive" || { rm -rf "$tmp"; return 1; }
    case "$url" in
        *.tar.gz|*.tgz) tar -xzf "$archive" -C "$work" ;;
        *.tar.xz) tar -xJf "$archive" -C "$work" ;;
        *.tar.zst)
            if tar --zstd -xf "$archive" -C "$work" 2>/dev/null; then :
            elif command -v zstd >/dev/null 2>&1; then zstd -dc "$archive" | tar -xf - -C "$work"
            else rm -rf "$tmp"; tui_msg "Missing zstd" "zstd is required to normalize this archive to tar.gz."; return 1; fi ;;
        *) rm -rf "$tmp"; return 1 ;;
    esac || { rm -rf "$tmp"; return 1; }
    count=$(find "$work" -mindepth 1 -maxdepth 1 -print 2>/dev/null | wc -l | tr -d ' ')
    first=$(find "$work" -mindepth 1 -maxdepth 1 -print 2>/dev/null | head -1)
    packroot="$work"
    if [ "$count" = 1 ] && [ -d "$first" ] && [ -d "$first/etc" ]; then packroot="$first"; fi
    rootfs_tar_create gz "$packroot" "$output" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
}

rootfs_download_unpack() { # <archive.tar.gz> <target-dir>
    local archive="$1" target="$2"
    if [ -e "$target" ]; then
        if [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
            tui_yesno "Replace rootfs" "$target already contains files. Replace it?" || return 1
            rootfs_rm_tree "$target" || return 1
        fi
    fi
    mkdir -p "$target" || return 1
    if run_cmd "Unpacking rootfs" tar -xzf "$archive" -C "$target"; then
        return 0
    fi
    rootfs_rm_tree "$target" 2>/dev/null || true
    return 1
}

rootfs_download() {
    local distro arch release source url output name target
    distro=$(rootfs_download_distro_menu) || return 0; [ -n "$distro" ] || return 0
    arch=$(rootfs_download_arch_menu "$distro") || return 0; [ -n "$arch" ] || return 0
    release=$(rootfs_release_menu "$distro" "$arch") || return 0; [ -n "$release" ] || return 0
    source=$(tui_radio "Download $distro $release" "Prebuilt rootfs source:" official "Official distribution rootfs (when published)" on community "Linux Containers community image server" off) || return 0
    case "$source" in official) url=$(rootfs_download_official_url "$distro" "$release" "$arch" 2>/dev/null || true) ;; community) url=$(rootfs_download_community_url "$distro" "$release" "$arch" 2>/dev/null || true) ;; esac
    if [ -z "$url" ]; then tui_msg "No prebuilt rootfs" "No $source prebuilt rootfs could be resolved for:\n$distro $release ($arch)\n\nTry the other source, or use Rootfs > Build."; return 0; fi

    # Imported archives live directly in ROOTFS_BASE alongside managed rootfs
    # directories. This makes downloads first-class Rootfs assets instead of a
    # separate downloads collection.
    name="${distro}-${release}-${arch}-${source}"
    output="$ROOTFS_BASE/${name}.tar.gz"
    target="$ROOTFS_BASE/$name"
    mkdir -p "$ROOTFS_BASE"
    if [ -e "$output" ]; then tui_yesno "Replace download" "$output already exists. Replace it?" || return 0; rm -f -- "$output"; fi

    if ! rootfs_download_to_gz "$url" "$output"; then
        tui_msg "Download failed" "Could not download or normalize the selected rootfs.\nSee $LOGFILE for details."
        return 0
    fi

    if tui_yesno "Unpack rootfs" "Imported archive:\n$output\n\nUnpack it now to:\n$target ?"; then
        if rootfs_download_unpack "$output" "$target"; then
            tui_msg "Rootfs imported" "Archive:\n$output\n\nUnpacked rootfs:\n$target"
        else
            tui_msg "Unpack failed" "The archive was imported successfully, but could not be unpacked to:\n$target"
        fi
    else
        tui_msg "Rootfs imported" "Archive imported to:\n$output\n\nYou can unpack it later from Rootfs management."
    fi
}

menu_rootfs() {
    while true; do
        local c
        c=$(tui_menu "Rootfs" "Mini root filesystems:" build "Build a new rootfs (guided)" download "Download a prebuilt rootfs (always tar.gz)" manage "Manage existing rootfs directories" workbench "Chroot workbench" bootstrap "Bootstrap tools" distros "Distro managers" back "Back") || return 0
        [ -n "$c" ] || return 0
        case "$c" in build) rootfs_builder || true ;; download) rootfs_download || true ;; manage) rootfs_manage || true ;; workbench) menu_rootfs_workbench || true ;; bootstrap) menu_rootfs_bootstrap_tools || true ;; distros) menu_rootfs_distro_managers || true ;; back) return 0 ;; esac
    done
}
