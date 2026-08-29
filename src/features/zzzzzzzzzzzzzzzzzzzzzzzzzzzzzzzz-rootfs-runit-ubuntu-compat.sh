# shellcheck shell=bash
###############################################################################
# ROOTFS BUILDER — Ubuntu runit package compatibility
#
# Ubuntu Questing/Resolute no longer publish the historical `runit-init`
# binary package. The `runit` package itself now ships /usr/sbin/runit,
# /usr/sbin/runit-init and /etc/runit/{1,2,3}. Translate Systui's legacy
# package request during bootstrap and wire the selected init to runit PID 1.
###############################################################################

rootfs_ubuntu_runit_package_compat_needed() { # <distro> <release> <packages>
    [ "$1" = ubuntu ] || return 1
    case "$2" in
        questing|25.10|25.10*|resolute|26.04|26.04*) ;;
        *) return 1 ;;
    esac
    case " $3 " in
        *" runit-init "*) return 0 ;;
    esac
    return 1
}

rootfs_replace_pkg_word() { # <packages> <old> <replacement>
    local packages="$1" old="$2" replacement="$3" word out=""
    for word in $packages; do
        if [ "$word" = "$old" ]; then
            out="${out:+$out }$replacement"
        else
            out="${out:+$out }$word"
        fi
    done
    printf '%s\n' "$out"
}

# Wrap the final Debian-family builder so this runs after the other late rootfs
# package filters. Only the obsolete package name is changed; all other distro
# and init selections pass through untouched.
if declare -F build_debfamily >/dev/null 2>&1 && \
   ! declare -F _systui_base_build_debfamily_runit_ubuntu >/dev/null 2>&1; then
    eval "$(declare -f build_debfamily | sed '1s/^build_debfamily[[:space:]]*()/_systui_base_build_debfamily_runit_ubuntu ()/')"
fi

build_debfamily() { # distro release arch mirror target pkgs use_qemu backend
    local distro="$1" release="$2" target="$5" pkgs="$6" rc=0 use_runit_compat=0
    local -a args=("$@")

    if rootfs_ubuntu_runit_package_compat_needed "$distro" "$release" "$pkgs"; then
        use_runit_compat=1
        args[5]=$(rootfs_replace_pkg_word "$pkgs" runit-init "runit runit-services")
        log "rootfs: Ubuntu $release provides runit without the obsolete runit-init package; using runit + runit-services"
    fi

    _systui_base_build_debfamily_runit_ubuntu "${args[@]}" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    if [ "$use_runit_compat" -eq 1 ]; then
        [ -x "$target/usr/sbin/runit" ] || {
            warn "Ubuntu runit compatibility requested, but /usr/sbin/runit was not installed in $target"
            return 1
        }

        mkdir -p "$target/sbin" "$target/etc/systui" || return 1
        if [ -e "$target/sbin/init" ] || [ -L "$target/sbin/init" ]; then
            if [ ! -e "$target/sbin/init.systui-original" ] && [ ! -L "$target/sbin/init.systui-original" ]; then
                mv "$target/sbin/init" "$target/sbin/init.systui-original" 2>/dev/null || rm -f "$target/sbin/init"
            else
                rm -f "$target/sbin/init"
            fi
        fi
        ln -s ../usr/sbin/runit "$target/sbin/init" || return 1
        printf 'init=runit\nprovider-package=runit\nlegacy-package=runit-init\nrelease=%s\n' "$release" > "$target/etc/systui/runit-init-compat.conf"
        log "rootfs: installed /sbin/init -> /usr/sbin/runit for Ubuntu $release"
    fi

    return 0
}

export -f rootfs_ubuntu_runit_package_compat_needed rootfs_replace_pkg_word build_debfamily
