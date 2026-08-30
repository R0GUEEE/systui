#!/bin/bash
# Versioned metadata API for Systui-managed root filesystems.

SYSTUI_ROOTFS_SCHEMA=1

systui_rootfs_metadata_file() { printf '%s/etc/systui/rootfs.conf\n' "$1"; }

systui_rootfs_metadata_get() { # <target> <key> [default]
    local target="$1" key="$2" default="${3:-}" file line
    file=$(systui_rootfs_metadata_file "$target")
    [ -r "$file" ] || { printf '%s\n' "$default"; return 0; }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "$key="*) printf '%s\n' "${line#*=}"; return 0;; esac
    done < "$file"
    printf '%s\n' "$default"
}

systui_rootfs_metadata_valid_key() {
    case "${1:-}" in schema|distro|release|arch|backend|init|runtime|created|updated) return 0;; *) return 1;; esac
}

systui_rootfs_metadata_valid_value() {
    case "${1:-}" in
        *$'\n'*|*$'\r'*|*=*) return 1 ;;
        *) return 0 ;;
    esac
}

systui_rootfs_metadata_set() { # <target> <key> <value>
    local target="$1" key="$2" value="$3" dir file tmp line found=0
    [ -d "$target" ] || return 66
    systui_rootfs_metadata_valid_key "$key" || return 64
    systui_rootfs_metadata_valid_value "$value" || return 64
    dir="$target/etc/systui"; file="$dir/rootfs.conf"
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "$dir/.rootfs.conf.XXXXXX") || return 1
    if [ -r "$file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "$key="*)
                    if [ "$found" -eq 0 ]; then printf '%s=%s\n' "$key" "$value" >> "$tmp"; found=1; fi
                    ;;
                *) printf '%s\n' "$line" >> "$tmp" ;;
            esac
        done < "$file"
    fi
    [ "$found" -eq 1 ] || printf '%s=%s\n' "$key" "$value" >> "$tmp"
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file"
}

systui_rootfs_metadata_init() { # <target> [distro] [release] [arch] [backend] [init] [runtime]
    local target="$1" distro="${2:-unknown}" release="${3:-unknown}" arch="${4:-unknown}" backend="${5:-unknown}" init="${6:-unknown}" runtime="${7:-unknown}" now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)
    systui_rootfs_metadata_set "$target" schema "$SYSTUI_ROOTFS_SCHEMA" || return
    systui_rootfs_metadata_set "$target" distro "$distro" || return
    systui_rootfs_metadata_set "$target" release "$release" || return
    systui_rootfs_metadata_set "$target" arch "$arch" || return
    systui_rootfs_metadata_set "$target" backend "$backend" || return
    systui_rootfs_metadata_set "$target" init "$init" || return
    systui_rootfs_metadata_set "$target" runtime "$runtime" || return
    [ -n "$(systui_rootfs_metadata_get "$target" created)" ] || systui_rootfs_metadata_set "$target" created "$now" || return
    systui_rootfs_metadata_set "$target" updated "$now"
}

systui_rootfs_metadata_show() {
    local file; file=$(systui_rootfs_metadata_file "$1")
    [ -r "$file" ] && cat "$file" || return 1
}

export -n -f systui_rootfs_metadata_file systui_rootfs_metadata_get systui_rootfs_metadata_valid_key systui_rootfs_metadata_valid_value systui_rootfs_metadata_set systui_rootfs_metadata_init systui_rootfs_metadata_show 2>/dev/null || true
