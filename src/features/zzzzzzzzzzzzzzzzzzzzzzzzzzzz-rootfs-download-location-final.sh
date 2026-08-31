# shellcheck shell=bash
###############################################################################
# ROOTFS DOWNLOAD LOCATION — keep downloaded tarballs under /opt/rootfs
###############################################################################

ROOTFS_DOWNLOAD_DIR="/opt/rootfs"

rootfs_download_source_extension() { # <url>
    case "$1" in
        *.tar.gz)  printf '.tar.gz\n' ;;
        *.tgz)     printf '.tgz\n' ;;
        *.tar.xz)  printf '.tar.xz\n' ;;
        *.tar.zst) printf '.tar.zst\n' ;;
        *.tar)     printf '.tar\n' ;;
        *)         printf '.tar\n' ;;
    esac
}

# Rootfs downloads must not use the generic installer watchdog. The downloader
# already provides its own retry/connect/transfer timeouts, and the extra
# function watchdog can stall after curl/wget has reached 100% on iSH-like
# environments. Return to the caller as soon as rootfs_fetch_file exits.
rootfs_download_fetch_direct() { # <url> <destination>
    local url="$1" dest="$2" rc=0

    mkdir -p "$(dirname "$dest")" || return 1
    rm -f -- "$dest"

    clear
    printf '>>> Downloading prebuilt rootfs\n'
    printf '>>> %s\n' "$url"
    printf '>>> Saving to: %s\n' "$dest"
    printf '%s\n' '================================================================='
    log "ROOTFS DOWNLOAD: $url -> $dest"

    rootfs_fetch_file "$url" "$dest" || rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f -- "$dest"
        log "ROOTFS DOWNLOAD FAILED ($rc): $url"
        printf '%s\n' '================================================================='
        printf 'Download failed (%s).\n' "$rc"
        return "$rc"
    fi

    if [ ! -s "$dest" ]; then
        rm -f -- "$dest"
        log "ROOTFS DOWNLOAD FAILED: empty file from $url"
        printf '%s\n' '================================================================='
        printf 'Download failed: downloaded file is empty.\n'
        return 1
    fi

    sync "$dest" 2>/dev/null || sync 2>/dev/null || true
    printf '%s\n' '================================================================='
    printf 'Download complete: %s\n' "$dest"
    printf 'Continuing to next phase...\n'
    log "ROOTFS DOWNLOAD COMPLETE: $dest"
    return 0
}

# Download the original upstream archive into /opt/rootfs, then normalize from
# that persistent copy. This replaces the older temp-workspace source download.
rootfs_download_to_gz() { # <url> <output.tar.gz>
    local url="$1" requested_output="$2" destdir base stem ext source output tmpout

    destdir="$ROOTFS_DOWNLOAD_DIR"
    mkdir -p "$destdir" || return 1

    base=$(basename "$requested_output")
    stem=${base%.tar.gz}
    ext=$(rootfs_download_source_extension "$url")
    source="$destdir/${stem}${ext}"
    output="$destdir/${stem}.tar.gz"

    # If the source itself is already the normalized destination, download it
    # directly without creating a second copy.
    if [ "$source" = "$output" ]; then
        rm -f -- "$output.part"
        rootfs_download_fetch_direct "$url" "$output.part" || { rm -f -- "$output.part"; return 1; }
        gzip -t "$output.part" >/dev/null 2>&1 || { rm -f -- "$output.part"; return 1; }
        mv -f -- "$output.part" "$output"
        printf 'Archive saved: %s\n' "$output"
        return 0
    fi

    rm -f -- "$source.part"
    rootfs_download_fetch_direct "$url" "$source.part" || { rm -f -- "$source.part"; return 1; }
    mv -f -- "$source.part" "$source" || return 1
    printf 'Downloaded source archive: %s\n' "$source"
    printf 'Starting normalization immediately...\n'

    tmpout="$output.part"
    rm -f -- "$tmpout"
    printf 'Normalizing archive to: %s\n' "$output"
    case "$ext" in
        .tar.xz)
            command -v xz >/dev/null 2>&1 || { tui_msg "Missing xz" "xz is required to normalize $source."; return 1; }
            ( set -o pipefail; xz -dc -- "$source" | gzip -c > "$tmpout" ) || { rm -f -- "$tmpout"; return 1; }
            ;;
        .tar.zst)
            command -v zstd >/dev/null 2>&1 || { tui_msg "Missing zstd" "zstd is required to normalize $source."; return 1; }
            ( set -o pipefail; zstd -dc -- "$source" | gzip -c > "$tmpout" ) || { rm -f -- "$tmpout"; return 1; }
            ;;
        .tgz|.tar.gz)
            cp -f -- "$source" "$tmpout" || return 1
            ;;
        .tar)
            gzip -c -- "$source" > "$tmpout" || { rm -f -- "$tmpout"; return 1; }
            ;;
        *) return 1 ;;
    esac

    gzip -t "$tmpout" >/dev/null 2>&1 || { rm -f -- "$tmpout"; return 1; }
    mv -f -- "$tmpout" "$output" || return 1
    printf 'Normalized archive saved: %s\n' "$output"
}

# Force all download import callers to use /opt/rootfs for both archives and
# unpack targets, even if some other feature changes ROOTFS_BASE later.
if declare -F rootfs_download_import_url >/dev/null 2>&1 \
    && ! declare -F _rootfs_download_import_url_before_location_final >/dev/null 2>&1; then
    _rootfs_dl_import_def=$(declare -f rootfs_download_import_url)
    _rootfs_dl_import_def=${_rootfs_dl_import_def/#rootfs_download_import_url ()/_rootfs_download_import_url_before_location_final ()}
    _rootfs_dl_import_def=${_rootfs_dl_import_def/#rootfs_download_import_url()/_rootfs_download_import_url_before_location_final()}
    eval "$_rootfs_dl_import_def"
    unset _rootfs_dl_import_def
fi

rootfs_download_import_url() {
    local old_base="${ROOTFS_BASE:-}"
    ROOTFS_BASE="$ROOTFS_DOWNLOAD_DIR"
    _rootfs_download_import_url_before_location_final "$@"
    local rc=$?
    if [ -n "$old_base" ]; then ROOTFS_BASE="$old_base"; else unset ROOTFS_BASE; fi
    return "$rc"
}

return 0 2>/dev/null || true
