# shellcheck shell=bash
###############################################################################
# ROOTFS BUILDER — unavailable init package fallback workflow
#
# Keep init choices visible even when a distro stops publishing the historical
# package name. For Ubuntu Questing/Resolute, runit-init is such a package.
# Instead of silently filtering/replacing it, ask how to satisfy the selected
# init: use the distro's current runit packages, add an alternate APT repository,
# build upstream runit from source, or cancel the build.
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
            [ -n "$replacement" ] && out="${out:+$out }$replacement"
        else
            out="${out:+$out }$word"
        fi
    done
    printf '%s\n' "$out"
}

rootfs_runit_wire_init() { # <target> <provider-description>
    local target="$1" provider="$2" runit_bin=""
    for runit_bin in /usr/sbin/runit /usr/local/sbin/runit /command/runit; do
        [ -x "$target$runit_bin" ] && break
    done
    [ -x "$target$runit_bin" ] || {
        warn "runit was requested, but no runit PID1 executable was found in $target"
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
    ln -s "..$runit_bin" "$target/sbin/init" || return 1
    printf 'init=runit\nprovider=%s\nbinary=%s\n' "$provider" "$runit_bin" > "$target/etc/systui/runit-init-compat.conf"
    log "rootfs: installed /sbin/init -> $runit_bin ($provider)"
}

rootfs_runit_install_from_repo() { # <target> <repo-line> <package-list>
    local target="$1" repo_line="$2" packages="$3"
    mkdir -p "$target/etc/apt/sources.list.d" || return 1
    printf '%s\n' "$repo_line" > "$target/etc/apt/sources.list.d/systui-init-fallback.list" || return 1
    rootfs_apt_force_ipv4 "$target" 2>/dev/null || true
    in_chroot "$target" sh -c "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y $packages" || return 1
    rootfs_runit_wire_init "$target" "alternate-apt-repository:$packages"
}

rootfs_runit_build_from_source() { # <target>
    local target="$1"
    rootfs_apt_force_ipv4 "$target" 2>/dev/null || true
    in_chroot "$target" sh -c '
        set -eu
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y build-essential ca-certificates curl gzip tar
        mkdir -p /usr/local/src /package /command
        cd /usr/local/src
        rm -rf runit-2.3.1 admin/runit-2.3.1 runit-2.3.1.tar.gz
        curl -4 -fL --retry 3 -o runit-2.3.1.tar.gz https://smarden.org/runit/runit-2.3.1.tar.gz
        tar -xzf runit-2.3.1.tar.gz
        cd admin/runit-2.3.1
        package/install
        mkdir -p /usr/local/sbin
        for n in runit runit-init sv runsv runsvdir runsvchdir chpst svlogd; do
            if [ -x "/command/$n" ]; then
                ln -sf "/command/$n" "/usr/local/sbin/$n"
            fi
        done
    ' || return 1
    rootfs_runit_wire_init "$target" "upstream-source:runit-2.3.1"
}

rootfs_runit_choose_fallback() { # <distro> <release>
    local distro="$1" release="$2" choice
    choice=$(tui_menu "Init package unavailable" \
        "The selected runit init requires 'runit-init', but $distro $release does not publish that package. Choose how Systui should continue:" \
        native "Use distro runit packages (recommended)" \
        repo   "Install from another APT repository" \
        source "Build runit 2.3.1 from upstream source" \
        cancel "Cancel rootfs build") || return 1
    printf '%s\n' "$choice"
}

# Wrap the final Debian-family builder so the missing init package is removed
# from bootstrap before the backend runs. The selected fallback is then applied
# after a usable base rootfs exists.
if declare -F build_debfamily >/dev/null 2>&1 && \
   ! declare -F _systui_base_build_debfamily_runit_ubuntu >/dev/null 2>&1; then
    eval "$(declare -f build_debfamily | sed '1s/^build_debfamily[[:space:]]*()/_systui_base_build_debfamily_runit_ubuntu ()/')"
fi

build_debfamily() { # distro release arch mirror target pkgs use_qemu backend
    local distro="$1" release="$2" target="$5" pkgs="$6" rc=0 fallback=""
    local repo_line="" repo_pkgs="" choice=""
    local -a args=("$@")

    if rootfs_ubuntu_runit_package_compat_needed "$distro" "$release" "$pkgs"; then
        choice=$(rootfs_runit_choose_fallback "$distro" "$release") || return 1
        [ "$choice" != cancel ] || {
            warn "Rootfs build cancelled because the selected init package is unavailable."
            return 1
        }
        fallback="$choice"

        # Never let the unavailable package poison debootstrap/mmdebstrap. The
        # selected fallback is installed after the base system is available.
        args[5]=$(rootfs_replace_pkg_word "$pkgs" runit-init "")

        case "$fallback" in
            native)
                # These packages are published by current Ubuntu and provide
                # the runit binaries/service tree without the removed package.
                args[5]="${args[5]} runit runit-services"
                ;;
            repo)
                repo_line=$(tui_input "Alternate init repository" \
                    "Enter a complete signed APT source line (for example: deb [signed-by=/path/key.gpg] https://host/repo suite component):" "") || return 1
                [ -n "$repo_line" ] || { warn "No alternate repository was provided."; return 1; }
                repo_pkgs=$(tui_input "Init package names" \
                    "Package(s) to install from that repository:" "runit-init") || return 1
                [ -n "$repo_pkgs" ] || { warn "No init package was provided."; return 1; }
                ;;
            source) ;;
            *) return 1 ;;
        esac
    fi

    _systui_base_build_debfamily_runit_ubuntu "${args[@]}" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    case "$fallback" in
        native)
            rootfs_runit_wire_init "$target" "ubuntu-native:runit+runit-services" || return 1
            ;;
        repo)
            rootfs_runit_install_from_repo "$target" "$repo_line" "$repo_pkgs" || {
                warn "Could not install the selected init from the alternate APT repository."
                return 1
            }
            ;;
        source)
            rootfs_runit_build_from_source "$target" || {
                warn "Could not build runit from upstream source."
                return 1
            }
            ;;
    esac

    return 0
}

export -f rootfs_ubuntu_runit_package_compat_needed rootfs_replace_pkg_word \
    rootfs_runit_wire_init rootfs_runit_install_from_repo rootfs_runit_build_from_source \
    rootfs_runit_choose_fallback build_debfamily
