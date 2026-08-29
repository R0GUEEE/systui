# shellcheck shell=bash
###############################################################################
# ROOTFS BUILD AUTO-CONFIGURATION
#
# Loaded after rootfs.sh. Keeps the mature build implementation intact while
# replacing only the interactive decision points that can be derived safely
# from the selected distro/release/architecture and current host.
###############################################################################

# The canonical rootfs store. rootfs.sh already uses this value; keep the
# override here so later feature layers cannot accidentally drift it.
ROOTFS_BASE=/opt/rootfs

rootfs_backend_auto_select() { # <distro> <arch> <release>
    local distro="$1" arch="$2" release="$3" backend _desc first=""

    # Catalogue order is preference order. Prefer the quickest compatible
    # backend that is already usable on this host, avoiding any install/setup.
    while IFS='|' read -r backend _desc; do
        [ -n "$backend" ] || continue
        rootfs_backend_release_supported "$distro" "$backend" "$release" "$arch" || continue
        [ -n "$first" ] || first="$backend"
        if rootfs_backend_available "$backend"; then
            printf '%s\n' "$backend"
            return 0
        fi
    done <<< "$(rootfs_backend_catalog "$distro" "$arch" "$release" 2>/dev/null)"

    # Nothing is ready yet. Return the highest-priority compatible backend;
    # rootfs_check_host_deps will install its native host prerequisites in one
    # package-manager operation where possible.
    [ -n "$first" ] && { printf '%s\n' "$first"; return 0; }
    return 1
}

rootfs_autoconfig_backend() { # <distro> <backend>
    local distro="$1" backend="$2"
    case "$distro" in
        debian|devuan|ubuntu|kali|bedrock)
            rootfs_backend_auto_optimize "$distro" "$backend"
            ;;
    esac
}

rootfs_target_collision_resolve() { # <distro> <release> <arch> <initial-target>
    local distro="$1" release="$2" arch="$3" target="$4" action name

    while [ -e "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; do
        action=$(tui_menu_no_tags "Rootfs already exists" \
            "A rootfs already exists at:\n$target\n\nChoose how to continue:" \
            overwrite "Overwrite the existing rootfs" \
            rename "Use a different rootfs name" \
            back "Cancel build") || return 1
        case "$action" in
            overwrite)
                rootfs_rm_tree "$target" || {
                    tui_msg "Overwrite failed" "Could not remove the existing rootfs:\n$target"
                    return 1
                }
                break
                ;;
            rename)
                name=$(tui_input "Rootfs name" "Name under $ROOTFS_BASE:" \
                    "${distro}-${release}-${arch}-2") || return 1
                [ -n "$name" ] || continue
                if ! valid_safe_name "$name"; then
                    tui_msg "Invalid name" "Use letters, numbers, dots, underscores and hyphens only."
                    continue
                fi
                target="$ROOTFS_BASE/$name"
                ;;
            *) return 1 ;;
        esac
    done
    printf '%s\n' "$target"
}

# Rewrite only stable, comment-delimited sections of rootfs_builder_impl.
# This avoids carrying a second copy of the large builder while allowing the
# derived configuration to remain automatic.
if declare -F rootfs_builder_impl >/dev/null 2>&1; then
    _systui_rootfs_builder_src=$(declare -f rootfs_builder_impl)
    _systui_rootfs_builder_src=$(printf '%s\n' "$_systui_rootfs_builder_src" | awk '
        BEGIN { backend=0; target=0 }
        /# ---- 4: bootstrap backend \(release-aware\) ----/ {
            backend=1
            print "    # ---- 4: bootstrap backend (automatic, host-aware) ----"
            print "    backend=$(rootfs_backend_auto_select \"$distro\" \"$arch\" \"$release\") || {"
            print "        tui_msg \"No compatible bootstrap\" \"No supported bootstrap backend is available for $distro $release $arch.\""
            print "        return 0"
            print "    }"
            print "    rootfs_autoconfig_backend \"$distro\" \"$backend\""
            print "    rootfs_check_host_deps \"$distro\" \"$backend\" \"$arch\" gz || return 0"
            print "    log \"rootfs: auto-selected backend=$backend for $distro/$release/$arch\""
            next
        }
        backend && /if needs_qemu \"\$arch\"; then/ { backend=0; print; next }
        backend { next }

        /pkgs=\$\(rootfs_package_catalog \"\$distro\" \"\$pkgs\"\)/ {
            print "    # Always seed basic network/source retrieval tools; skip the extra package catalogue."
            print "    pkgs=\"$pkgs git curl wget\""
            next
        }

        /# ---- 7: target directory ----/ { target=1; print; next }
        target && /mkdir -p \"\$target\"/ {
            print "    target=$(rootfs_target_collision_resolve \"$distro\" \"$release\" \"$arch\" \"$target\") || return 0"
            print "    mkdir -p \"$target\""
            target=0
            next
        }
        target { 
            # Preserve the target input itself, but drop the old abort-on-exists block.
            if ($0 ~ /target=\$\(tui_input/ || $0 ~ /\"\$ROOTFS_BASE\/\$\{distro\}-\$\{release\}-\$\{arch\}\"\) \|\| return 0/) print
            next
        }
        { print }
    ')
    eval "$_systui_rootfs_builder_src"
    unset _systui_rootfs_builder_src
fi

return 0 2>/dev/null || true
