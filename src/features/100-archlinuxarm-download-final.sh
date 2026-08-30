# shellcheck shell=bash
# PHASE 100 — Arch Linux ARM rootfs download endpoint repair.
# mirror.archlinuxarm.org currently has a TLS hostname mismatch for some clients.
# Normalize legacy/default URLs to the official rootfs host and fall back to a
# known HTTPS Arch Linux ARM mirror without ever disabling certificate checks.

systui_archlinuxarm_rewrite_url() { # <url> <base>
    local url="$1" base="$2" path
    case "$url" in
        http://mirror.archlinuxarm.org/*|https://mirror.archlinuxarm.org/*)
            path=${url#*://mirror.archlinuxarm.org}
            printf '%s%s\n' "$base" "$path"
            ;;
        *) printf '%s\n' "$url" ;;
    esac
}

systui_archlinuxarm_url_candidates() { # <url>
    local url="$1"
    case "$url" in
        http://mirror.archlinuxarm.org/*|https://mirror.archlinuxarm.org/*)
            systui_archlinuxarm_rewrite_url "$url" 'http://os.archlinuxarm.org'
            systui_archlinuxarm_rewrite_url "$url" 'https://ca.us.mirror.archlinuxarm.org'
            ;;
        *) printf '%s\n' "$url" ;;
    esac
}

rootfs_fetch_file() { # <url> <destination>
    local original="$1" dest="$2" url rc=1
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        rm -f -- "$dest" 2>/dev/null || true
        if command -v curl >/dev/null 2>&1; then
            if curl -4 -fL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 900 -o "$dest" "$url"; then
                return 0
            fi
            rc=$?
        elif command -v wget >/dev/null 2>&1; then
            if wget -4 -q -T 900 -O "$dest" "$url"; then
                return 0
            fi
            rc=$?
        else
            return 127
        fi
        warn "Rootfs download failed from $url; trying the next source."
    done <<< "$(systui_archlinuxarm_url_candidates "$original")"
    rm -f -- "$dest" 2>/dev/null || true
    return "$rc"
}

rootfs_fetch_text() { # <url>
    local original="$1" url rc=1
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        if command -v curl >/dev/null 2>&1; then
            if curl -4 -LfsS --retry 2 --retry-all-errors --connect-timeout 10 --max-time 120 "$url"; then
                return 0
            fi
            rc=$?
        elif command -v wget >/dev/null 2>&1; then
            if wget -4 -qO- -T 120 "$url"; then
                return 0
            fi
            rc=$?
        else
            return 127
        fi
    done <<< "$(systui_archlinuxarm_url_candidates "$original")"
    return "$rc"
}

return 0 2>/dev/null || true
