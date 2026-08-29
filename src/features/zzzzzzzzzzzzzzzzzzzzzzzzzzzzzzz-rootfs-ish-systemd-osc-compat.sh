# shellcheck shell=bash
###############################################################################
# ROOTFS BUILDER — iSH-AOK systemd shell/procfs compatibility
###############################################################################

rootfs_ish_patch_systemd_osc_profile() { # <target>
    local t="$1" profile tmp

    for profile in \
        "$t/usr/lib/profile.d/80-systemd-osc-context.sh" \
        "$t/etc/profile.d/80-systemd-osc-context.sh"
    do
        [ -f "$profile" ] || continue
        grep -q 'SYSTUI_ISH_OSC_PROCFS_GUARD' "$profile" 2>/dev/null && continue

        tmp="$profile.systui-tmp.$$"
        {
            cat <<'EOF'
# SYSTUI_ISH_OSC_PROCFS_GUARD
# systemd's OSC shell integration expects Linux procfs UUID interfaces that
# iSH-AOK does not implement. Disable only this optional prompt integration
# when those interfaces are absent; normal Linux kernels continue unchanged.
if [ ! -r /proc/sys/kernel/random/uuid ] || [ ! -r /proc/sys/kernel/random/boot_id ]; then
    return 0 2>/dev/null || exit 0
fi
EOF
            cat "$profile"
        } > "$tmp" || { rm -f "$tmp"; return 1; }
        cat "$tmp" > "$profile" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
        log "rootfs: guarded systemd OSC procfs probes for iSH-AOK in $profile"
    done
}

rootfs_ish_install_proc_random_cat() { # <target>
    local t="$1"
    mkdir -p "$t/usr/local/bin" "$t/run" || return 1

    cat > "$t/usr/local/bin/cat" <<'EOF'
#!/bin/sh
# Systui iSH-AOK procfs compatibility wrapper.
# Only emulates procfs random UUID interfaces missing from iSH. Every other
# invocation is delegated unchanged to the distro-provided cat.

REAL_CAT=/usr/bin/cat
[ -x "$REAL_CAT" ] || REAL_CAT=/bin/cat

is_ish_kernel() {
    v=''
    [ -r /proc/version ] && IFS= read -r v < /proc/version 2>/dev/null || true
    case "$v" in *-ish*|*ish_aok*|*iSH-AOK*|*iSH*) return 0 ;; esac
    [ -e /proc/ish ]
}

new_id128() {
    id=''
    if [ -x /usr/bin/systemd-id128 ]; then
        id=$(/usr/bin/systemd-id128 new 2>/dev/null || true)
    elif [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
        id=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    fi
    case "$id" in
        ????????????????????????????????) ;;
        *)
            # Last-resort deterministic seed. This is only a compatibility ID,
            # not a cryptographic token.
            seed="${PPID:-0}.$$.${SECONDS:-0}.$(date +%s 2>/dev/null || printf 0)"
            if command -v sha256sum >/dev/null 2>&1; then
                id=$(printf '%s' "$seed" | sha256sum | awk '{print substr($1,1,32)}')
            else
                id=00000000000000000000000000000001
            fi
            ;;
    esac
    printf '%s-%s-%s-%s-%s\n' \
        "${id%????????????????????????}" \
        "${id#????????}" | : 2>/dev/null
    printf '%.8s-%.4s-%.4s-%.4s-%.12s\n' \
        "$id" "${id#????????}" "${id#????????????}" \
        "${id#????????????????}" "${id#????????????????????}"
}

# A real Linux procfs always wins. The wrapper is intentionally inert there.
if ! is_ish_kernel; then
    exec "$REAL_CAT" "$@"
fi

# Match the common single-path form exactly. Multi-file/options behavior remains
# the real cat's responsibility so this wrapper cannot subtly change cat.
if [ "$#" -eq 1 ]; then
    case "$1" in
        /proc/sys/kernel/random/uuid)
            if [ -r "$1" ]; then exec "$REAL_CAT" "$1"; fi
            new_id128
            exit 0
            ;;
        /proc/sys/kernel/random/boot_id)
            if [ -r "$1" ]; then exec "$REAL_CAT" "$1"; fi
            boot_file=/run/systui-ish-boot-id
            if [ ! -s "$boot_file" ]; then
                umask 022
                new_id128 > "$boot_file" 2>/dev/null || exit 1
            fi
            exec "$REAL_CAT" "$boot_file"
            ;;
    esac
fi

exec "$REAL_CAT" "$@"
EOF
    chmod 0755 "$t/usr/local/bin/cat" || return 1
    log "rootfs: installed iSH-AOK procfs random UUID cat compatibility wrapper"
}

# Add compatibility whenever the systemd compatibility layer is installed or
# refreshed, including fresh builds, Workbench repair and final pre-pack checks.
if declare -F rootfs_install_ish_systemd_compat >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_install_ish_systemd_compat_osc >/dev/null 2>&1; then
    eval "$(declare -f rootfs_install_ish_systemd_compat | sed '1s/^rootfs_install_ish_systemd_compat[[:space:]]*()/_systui_base_rootfs_install_ish_systemd_compat_osc ()/')"
fi

rootfs_install_ish_systemd_compat() {
    local t="$1" rc=0
    _systui_base_rootfs_install_ish_systemd_compat_osc "$@" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    rootfs_ish_patch_systemd_osc_profile "$t" || {
        warn "Could not install the iSH-AOK systemd OSC procfs compatibility guard."
        return 1
    }
    rootfs_ish_install_proc_random_cat "$t" || {
        warn "Could not install the iSH-AOK procfs random UUID cat compatibility wrapper."
        return 1
    }
}

export -f rootfs_ish_patch_systemd_osc_profile rootfs_ish_install_proc_random_cat \
    rootfs_install_ish_systemd_compat
