# shellcheck shell=bash
###############################################################################
# DISTRO MANAGER COMMAND COMPATIBILITY
#
# Loaded after rootfs.sh (the feature loader sources *.sh alphabetically).
# This file keeps the distro-manager integrations aligned with the managers'
# real CLIs without making the large rootfs builder depend on a specific
# release of any third-party manager.
###############################################################################

rootfs_dm_is_termux() {
    [ -n "${TERMUX_VERSION:-}" ] || [ -n "${TERMUX_APP__PACKAGE_NAME:-}" ] ||
        case "${PREFIX:-}" in /data/data/com.termux/*) return 0 ;; *) return 1 ;; esac
}

# Keep the same manager IDs used by rootfs.sh, but describe what each tool
# actually does. In particular, chroot-distro is the cross-Linux Python tool
# from sabamdarif/chroot-distro, not the old Android-only Magisk module.
rootfs_dm_managers() {
    printf '%s\n' \
        'proot-distro|proot-distro|proot-distro — rootless OCI/Docker distro manager (PRoot)' \
        'chroot-distro|chroot-distro|chroot-distro — native chroot OCI/Docker distro manager' \
        'distrobox|distrobox|distrobox — integrated OCI containers sharing the host home' \
        'toolbx|toolbox|Toolbx — developer OCI environments' \
        'schroot|schroot|schroot — session manager for preconfigured chroots' \
        'udocker|udocker|udocker — rootless Docker-image containers' \
        'machinectl|machinectl|machinectl — systemd-nspawn machine/image manager' \
        'arch-chroot|arch-chroot|arch-chroot — enter an existing Arch-style root tree'
}

rootfs_dm_install_hint() { # <tag>
    case "$1" in
        proot-distro)
            printf '%s\n' 'Termux: pkg install proot-distro. Regular Linux: install proot + Python/pip, then python3 -m pip install proot-distro.' ;;
        chroot-distro)
            printf '%s\n' 'Python 3.10+: python3 -m pip install chroot-distro (sabamdarif/chroot-distro). On regular Linux, chroot-distro setup can optionally configure passwordless access.' ;;
        distrobox)   printf '%s\n' 'Package "distrobox", or the upstream installer from github.com/89luca89/distrobox.' ;;
        toolbx)      printf '%s\n' 'Package "toolbox" (Fedora/Arch) or "podman-toolbox" where packaged.' ;;
        schroot)     printf '%s\n' 'Package "schroot".' ;;
        udocker)     printf '%s\n' 'pip install udocker, or use the distribution package where available.' ;;
        machinectl)  printf '%s\n' 'Install the systemd-container package (machinectl/systemd-nspawn).' ;;
        arch-chroot) printf '%s\n' 'Install arch-install-scripts.' ;;
    esac
}

# Install current upstream proot-distro/chroot-distro releases from PyPI.
# Their modern repositories are Python projects; the old clone-and-copy logic
# in rootfs.sh targets historical shell-script layouts and no longer works.
rootfs_dm_python() {
    command -v python3 2>/dev/null || command -v python 2>/dev/null
}

rootfs_dm_ensure_python_pip() {
    local py
    py=$(rootfs_dm_python 2>/dev/null || true)
    if [ -z "$py" ]; then
        if rootfs_dm_is_termux; then
            pm_install python || return 1
        else
            pm_install python3 || pm_install python || return 1
        fi
        py=$(rootfs_dm_python 2>/dev/null || true)
    fi
    [ -n "$py" ] || return 1
    "$py" -m pip --version >/dev/null 2>&1 && return 0
    if rootfs_dm_is_termux; then
        pm_install python-pip >/dev/null 2>&1 || true
    else
        pm_install python3-pip >/dev/null 2>&1 || true
    fi
    "$py" -m pip --version >/dev/null 2>&1
}

rootfs_dm_pip_install() { # <package>
    local pkg="$1" py
    rootfs_dm_ensure_python_pip || return 1
    py=$(rootfs_dm_python) || return 1
    run_cmd "Install $pkg from PyPI" "$py" -m pip install --upgrade --break-system-packages "$pkg" ||
        run_cmd "Install $pkg from PyPI" "$py" -m pip install --upgrade "$pkg"
}

rootfs_dm_install_upstream() { # <tag>
    local tag="$1" prefix
    prefix=$(get_config dm_install_prefix /usr/local)
    case "$tag" in
        proot-distro)
            command -v proot >/dev/null 2>&1 || pm_install proot || return 1
            rootfs_dm_pip_install proot-distro
            ;;
        chroot-distro)
            rootfs_dm_pip_install chroot-distro
            ;;
        distrobox)
            command -v curl >/dev/null 2>&1 || pm_install curl
            run_cmd "Run the upstream distrobox installer" sh -c \
                "curl -fsSL https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix '$prefix'"
            ;;
        udocker)
            rootfs_dm_pip_install udocker || return 1
            # udocker's Python package is only the frontend; its execution
            # engines are installed by the tool's own install command.
            rootfs_dm_run udocker "Install udocker execution tools" install
            ;;
        *)
            tui_msg "No upstream installer" \
"systui has no upstream installation method for $tag.

$(rootfs_dm_install_hint "$tag")"
            return 1
            ;;
    esac
}

# Avoid offering a package-install path when the current package manager does
# not actually advertise that package. This is especially important on normal
# Debian/Ubuntu, where proot-distro is typically installed from PyPI rather than
# from the distro archive, while Termux does ship a package by that name.
rootfs_dm_package() { # <tag>
    local tag="$1" pkg=""
    case "$tag" in
        proot-distro)
            if rootfs_dm_is_termux; then
                pkg=proot-distro
            elif [ "${PM:-}" = apt ] && command -v apt-cache >/dev/null 2>&1 && apt-cache show proot-distro >/dev/null 2>&1; then
                pkg=proot-distro
            fi ;;
        chroot-distro) : ;;
        distrobox) pkg=distrobox ;;
        toolbx)
            case "${PM:-}" in dnf|yum|pacman) pkg=toolbox ;; apt) pkg=podman-toolbox ;; esac ;;
        schroot) pkg=schroot ;;
        udocker)
            case "${PM:-}" in apt) pkg=udocker ;; esac ;;
        machinectl)
            case "${PM:-}" in apt|dnf|yum) pkg=systemd-container ;; esac ;;
        arch-chroot)
            case "${PM:-}" in pacman|apt) pkg=arch-install-scripts ;; esac ;;
    esac
    [ -n "$pkg" ] && printf '%s\n' "$pkg"
}

rootfs_dm_install() { # <tag> -- install the manager itself
    local tag="$1" pkg method
    local -a args=()
    pkg=$(rootfs_dm_package "$tag")
    [ -n "$pkg" ] && args+=(package "Install '$pkg' with ${PM:-the system package manager}")
    case "$tag" in
        proot-distro|chroot-distro|udocker)
            args+=(upstream "Install current upstream release") ;;
            distrobox) args+=(upstream "Install from 89luca89/distrobox (GitHub)") ;;
    esac
    if [ ${#args[@]} -eq 0 ]; then
        tui_msg "Install $tag" \
"systui has no automated installation method for $tag on this host.

$(rootfs_dm_install_hint "$tag")"
        return 0
    fi
    args+=(back "Back")
    method=$(tui_menu_no_tags "Install $(rootfs_dm_label "$tag")" \
        "Choose an installation source:" "${args[@]}") || return 0
    case "$method" in
        package) pm_install "$pkg" ;;
        upstream) rootfs_dm_install_upstream "$tag" || return 0 ;;
        *) return 0 ;;
    esac
    if rootfs_dm_available "$tag"; then
        tui_msg "Installed" "$tag is available at $(command -v "$(rootfs_dm_binary "$tag")")."
    else
        tui_msg "Not detected" "$tag was not found on PATH after installation. See $LOGFILE."
    fi
}

# ---------------------------------------------------------------------------
# Runtime data locations
# ---------------------------------------------------------------------------
# Modern proot-distro and chroot-distro both use:
#   <runtime>/containers/<name>/rootfs
# while older proot-distro used installed-rootfs/<name>. Return the runtime
# root here and let rootfs_dm_installed_dirs understand both layouts.
rootfs_dm_store_default() { # <tag>
    local tag="$1" u home d
    u=$(rootfs_dm_target_user "$tag")
    home=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
    [ -n "$home" ] || home="${HOME:-/root}"
    case "$tag" in
        proot-distro)
            for d in \
                "${PREFIX:-}/var/lib/proot-distro" \
                /data/data/com.termux/files/usr/var/lib/proot-distro \
                "$home/.local/share/proot-distro" \
                /root/.local/share/proot-distro \
                /var/lib/proot-distro; do
                [ -n "$d" ] || continue
                [ -d "$d/containers" ] || [ -d "$d/installed-rootfs" ] || continue
                printf '%s\n' "$d"; return 0
            done
            ;;
        chroot-distro)
            for d in \
                "${PREFIX:-}/var/lib/chroot-distro" \
                /data/data/com.termux/files/usr/var/lib/chroot-distro \
                "$home/.local/share/chroot-distro" \
                /root/.local/share/chroot-distro \
                /var/lib/chroot-distro; do
                [ -n "$d" ] || continue
                [ -d "$d/containers" ] || continue
                printf '%s\n' "$d"; return 0
            done
            ;;
        schroot)
            for d in /srv/chroot /var/lib/schroot/chroots; do
                [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
            done
            ;;
        machinectl)
            [ -d /var/lib/machines ] && { printf '%s\n' /var/lib/machines; return 0; }
            ;;
        distrobox|toolbx|udocker|arch-chroot)
            return 1
            ;;
    esac
    return 1
}

rootfs_dm_installed_dirs() { # <tag> -> actual rootfs directories
    local tag="$1" store d
    store=$(rootfs_dm_store "$tag" 2>/dev/null) || return 1
    [ -d "$store" ] || return 1
    case "$tag" in
        proot-distro|chroot-distro)
            if [ -d "$store/containers" ]; then
                for d in "$store"/containers/*/rootfs; do
                    [ -d "$d" ] && printf '%s\n' "$d"
                done
            elif [ "$(basename "$store")" = containers ]; then
                for d in "$store"/*/rootfs; do
                    [ -d "$d" ] && printf '%s\n' "$d"
                done
            fi
            # Legacy proot-distro layout / explicit overrides that point there.
            if [ "$tag" = proot-distro ]; then
                if [ -d "$store/installed-rootfs" ]; then
                    for d in "$store"/installed-rootfs/*; do [ -d "$d" ] && printf '%s\n' "$d"; done
                elif [ "$(basename "$store")" = installed-rootfs ]; then
                    for d in "$store"/*; do [ -d "$d" ] && printf '%s\n' "$d"; done
                fi
            fi
            ;;
        *)
            for d in "$store"/*/; do [ -d "$d" ] && printf '%s\n' "${d%/}"; done
            ;;
    esac
}

rootfs_dm_rootfs_name() { # <tag> <rootfs-path>
    case "$1" in
        proot-distro|chroot-distro)
            [ "$(basename "$2")" = rootfs ] && basename "$(dirname "$2")" || basename "$2" ;;
        *) basename "$2" ;;
    esac
}

# ---------------------------------------------------------------------------
# Catalogue/search parsing
# ---------------------------------------------------------------------------

rootfs_dm_has_search() { # <tag>
    rootfs_dm_capture "$1" search --help >/dev/null 2>&1
}

# Legacy static-catalogue parser. Old proot-distro builds expose supported
# aliases through `list`; some historical chroot-distro builds did the same.
# Modern releases use `search` and their `list` command means *installed*.
rootfs_dm_parse_distros() { # <tag> -- legacy catalogue only
    local tag="$1" out
    out=$(rootfs_dm_capture "$tag" list 2>/dev/null || true)
    [ -n "$out" ] || return 1
    case "$tag" in
        proot-distro)
            printf '%s\n' "$out" | awk '
                /^[^[:space:]]/ { name = $0; sub(/[[:space:]]+$/, "", name) }
                /^[[:space:]]*Alias:[[:space:]]*/ {
                    alias = $0
                    sub(/^[[:space:]]*Alias:[[:space:]]*/, "", alias)
                    sub(/[[:space:]]+$/, "", alias)
                    if (alias != "") printf "%s|%s\n", alias, (name != "" ? name : alias)
                }
            '
            ;;
        chroot-distro)
            printf '%s\n' "$out" |
                grep -oE '^[[:space:]]*[a-z][a-z0-9._-]{1,63}[[:space:]]*$' |
                tr -d ' \t' | sort -u |
                awk '{ print $0 "|available distribution" }'
            ;;
        *)
            printf '%s\n' "$out" | sed -E 's/^[[:space:]]+//' |
                grep -oE '^[a-z][a-z0-9._:/-]+' | sort -u |
                awk '{ print $0 "|entry" }'
            ;;
    esac
}

rootfs_dm_parse_search_table() {
    # Pull the first field from table/stacked search output, but only accept
    # Docker/OCI-style repository names. This intentionally excludes headings,
    # counts and URLs printed around the results.
    awk '
        {
            if ($0 ~ /^[[:space:]]+/) next
            item=$1
            gsub(/^[|`*+-]+|[|`,;]+$/, "", item)
            if (item ~ /^https?:/) next
            if (item ~ /^(NAME|REPOSITORY|IMAGE|Showing|Search|Results|OFFICIAL|STARS|PULLS)$/) next
            if (item ~ /^[a-z0-9][a-z0-9._-]*(\/[a-z0-9][a-z0-9._-]*)*(\:[A-Za-z0-9._-]+)?$/)
                print item "|" item
        }
    ' | sort -u
}

rootfs_dm_search_distros() { # <tag> <query> -> image|description
    local tag="$1" query="$2" out
    [ -n "$query" ] || return 1
    case "$tag" in
        proot-distro)
            # Current proot-distro has a script-friendly --quiet search mode.
            out=$(rootfs_dm_capture "$tag" search --quiet "$query" 2>/dev/null || true)
            if printf '%s\n' "$out" | grep -Eq '^[a-z0-9][a-z0-9._/-]*(\:[A-Za-z0-9._-]+)?$'; then
                printf '%s\n' "$out" |
                    grep -E '^[a-z0-9][a-z0-9._/-]*(\:[A-Za-z0-9._-]+)?$' |
                    sort -u | awk '{ print $0 "|Docker Hub image" }'
                return 0
            fi
            out=$(rootfs_dm_capture "$tag" search "$query" 2>/dev/null || true)
            printf '%s\n' "$out" | rootfs_dm_parse_search_table
            ;;
        chroot-distro)
            # sabamdarif/chroot-distro search accepts --limit and prints a table.
            out=$(rootfs_dm_capture "$tag" search --limit 100 "$query" 2>/dev/null ||
                  rootfs_dm_capture "$tag" search "$query" 2>/dev/null || true)
            printf '%s\n' "$out" | rootfs_dm_parse_search_table
            ;;
        udocker)
            # -a prevents the pager from pausing after each page.
            out=$(rootfs_dm_capture "$tag" search -a "$query" 2>/dev/null ||
                  rootfs_dm_capture "$tag" search "$query" 2>/dev/null || true)
            printf '%s\n' "$out" | rootfs_dm_parse_search_table
            ;;
        *) return 1 ;;
    esac
}

rootfs_dm_distrobox_compatibility() {
    local out
    out=$(rootfs_dm_capture distrobox create --compatibility 2>/dev/null || true)
    [ -n "$out" ] || return 1
    # Compatibility output changes formatting between distrobox releases. Pull
    # image references from every field instead of depending on a column width.
    printf '%s\n' "$out" | tr ' \t|,()' '\n' |
        sed -E 's/^["]+//; s/["]+$//' |
        grep -E '^[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)+(:[A-Za-z0-9._-]+)?$|^[a-z0-9][a-z0-9._-]*:[A-Za-z0-9._-]+$' |
        grep -Ev '^(https?|man):' | sort -u |
        awk '{ print $0 "|compatible distrobox image" }'
}

rootfs_dm_catalog_for_install() { # <tag> [query]
    local tag="$1" query="${2:-}"
    case "$tag" in
        proot-distro|chroot-distro)
            if rootfs_dm_has_search "$tag"; then
                rootfs_dm_search_distros "$tag" "$query"
            else
                rootfs_dm_parse_distros "$tag"
            fi
            ;;
        distrobox) rootfs_dm_distrobox_compatibility ;;
        udocker) rootfs_dm_search_distros "$tag" "$query" ;;
        *) return 1 ;;
    esac
}

rootfs_dm_select_catalog_entries() { # <tag> <query> -> selected refs, one/line
    local tag="$1" query="${2:-}" ref desc selected count=0
    local -a args=()
    while IFS='|' read -r ref desc; do
        [ -n "$ref" ] || continue
        args+=("$ref" "${desc:-$ref}" off)
        count=$((count + 1))
    done <<< "$(rootfs_dm_catalog_for_install "$tag" "$query" 2>/dev/null || true)"
    [ "$count" -gt 0 ] || return 1
    selected=$(tui_check "Install with $tag" \
        "SPACE selects one or more distributions/images; Enter installs the selected entries." \
        "${args[@]}") || return 2
    selected=${selected//\"/}
    [ -n "${selected//[[:space:]]/}" ] || return 2
    # Image references cannot contain whitespace; dialog therefore gives us a
    # safe whitespace-delimited set after quote removal.
    for ref in $selected; do printf '%s\n' "$ref"; done
}

rootfs_dm_install_image() { # <tag> <image> [name]
    local tag="$1" image="$2" name="${3:-}"
    case "$tag" in
        proot-distro|chroot-distro)
            # Both current CLIs use exactly: <tool> install [opts] IMAGE.
            # Never emit the removed/incorrect `download` subcommand.
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

rootfs_dm_browse_install() { # <tag> -- combined browse/list + install workflow
    local tag="$1" query="" image name selected="" failed="" manual=""
    case "$tag" in
        proot-distro|chroot-distro)
            if rootfs_dm_has_search "$tag"; then
                query=$(tui_input "Browse and install" \
                    "Search Docker Hub for installable distributions/images:" "ubuntu") || return 0
                [ -n "$query" ] || return 0
            fi
            ;;
        udocker)
            query=$(tui_input "Browse and install" \
                "Search Docker Hub for installable images:" "ubuntu") || return 0
            [ -n "$query" ] || return 0
            ;;
        distrobox) : ;;
        toolbx)
            image=$(tui_input "Create Toolbx" "OCI image to use:" "registry.fedoraproject.org/fedora-toolbox:latest") || return 0
            [ -n "$image" ] || return 0
            name=$(tui_input "Create Toolbx" "Container name:" "systui-toolbox") || return 0
            [ -n "$name" ] || return 0
            rootfs_dm_install_image "$tag" "$image" "$name" || true
            return 0
            ;;
        *) return 1 ;;
    esac

    if selected=$(rootfs_dm_select_catalog_entries "$tag" "$query"); then
        :
    else
        # Search/catalogue parsing can fail because a manager changed output,
        # Docker Hub is unavailable, or the query had no hits. Keep a manual
        # path instead of guessing an image name.
        manual=$(tui_input "Install with $tag" \
            "No selectable catalogue entries were returned. Enter an image/reference manually (blank cancels):" "") || return 0
        [ -n "$manual" ] || return 0
        selected="$manual"
    fi

    while IFS= read -r image; do
        [ -n "$image" ] || continue
        if [ "$tag" = distrobox ]; then
            name=$(printf '%s' "$image" | sed 's|.*/||; s/:.*//; s/[^A-Za-z0-9_.-]/-/g')
            name=$(tui_input "Distrobox name" "Container name for $image:" "$name") || continue
            [ -n "$name" ] || continue
            rootfs_dm_install_image "$tag" "$image" "$name" || failed="$failed $image"
        elif [ "$tag" = udocker ]; then
            name=$(printf '%s' "$image" | sed 's|.*/||; s/:.*//; s/[^A-Za-z0-9_.-]/-/g')
            name=$(tui_input "udocker name" "Container name for $image:" "$name") || continue
            [ -n "$name" ] || continue
            rootfs_dm_install_image "$tag" "$image" "$name" || failed="$failed $image"
        else
            rootfs_dm_install_image "$tag" "$image" || failed="$failed $image"
        fi
    done <<< "$selected"

    [ -z "$failed" ] || tui_msg "Some installs failed" "Failed:$failed\n\nSee $LOGFILE for command output."
}

# ---------------------------------------------------------------------------
# Installed-container helpers
# ---------------------------------------------------------------------------
rootfs_dm_installed_names() { # <tag>
    local tag="$1" out d name
    case "$tag" in
        proot-distro|chroot-distro)
            out=$(rootfs_dm_capture "$tag" list --quiet 2>/dev/null ||
                  rootfs_dm_capture "$tag" list -q 2>/dev/null || true)
            if printf '%s\n' "$out" | grep -Eq '^[A-Za-z0-9_.-]+$'; then
                printf '%s\n' "$out" | grep -E '^[A-Za-z0-9_.-]+$' | sort -u
                return 0
            fi
            while IFS= read -r d; do
                [ -n "$d" ] || continue
                rootfs_dm_rootfs_name "$tag" "$d"
            done <<< "$(rootfs_dm_installed_dirs "$tag" 2>/dev/null || true)"
            ;;
        schroot)
            rootfs_dm_capture "$tag" --list 2>/dev/null | sed -E 's/^[^:]+://' | sed '/^[[:space:]]*$/d'
            ;;
        *) return 1 ;;
    esac
}

rootfs_dm_pick_installed() { # <tag> -> name
    local tag="$1" name sel
    local -a args=()
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        args+=("$name" "$name")
    done <<< "$(rootfs_dm_installed_names "$tag" 2>/dev/null || true)"
    if [ ${#args[@]} -eq 0 ]; then
        tui_input "$tag" "Installed container/session name:" ""
        return
    fi
    sel=$(tui_menu_no_tags "$(rootfs_dm_label "$tag")" "Installed entries:" "${args[@]}") || return 1
    printf '%s\n' "$sel"
}

rootfs_dm_show_command() { # <tag> <title> <args...>
    local tag="$1" title="$2"; shift 2
    rootfs_dm_capture "$tag" "$@" > "$(rootfs_report_file)" 2>&1 || true
    tui_text "$title" "$(rootfs_report_file)"
}

rootfs_dm_adopt() { # <tag>
    local tag="$1" d name sel store
    local -a args=()
    store=$(rootfs_dm_store "$tag" 2>/dev/null || true)
    [ -n "$store" ] || {
        tui_msg "Not available" "$tag does not expose a plain rootfs tree that systui can open in the chroot workbench."
        return 0
    }
    while IFS= read -r d; do
        [ -d "$d" ] || continue
        name=$(rootfs_dm_rootfs_name "$tag" "$d")
        args+=("$d" "$name  $(du -sh "$d" 2>/dev/null | cut -f1)")
    done <<< "$(rootfs_dm_installed_dirs "$tag" 2>/dev/null || true)"
    [ ${#args[@]} -gt 0 ] || { tui_msg "Nothing installed" "No usable rootfs trees found under $store."; return 0; }
    sel=$(tui_menu_no_tags "Open in workbench" "Installed roots:" "${args[@]}") || return 0
    [ -n "$sel" ] && rootfs_wb_menu_for "$sel"
}

# ---------------------------------------------------------------------------
# Per-manager menus with real command names/arguments
# ---------------------------------------------------------------------------
rootfs_dm_menu_proot_chroot() { # <tag>
    local tag="$1" c d
    while true; do
        c=$(tui_menu_no_tags "$(rootfs_dm_label "$tag")" \
            "Browse/search results are parsed into a SPACE-to-select install menu." \
            browse    "Browse/select/install distributions (combined workflow)" \
            installed "List installed containers" \
            login     "Log in to an installed container" \
            remove    "Remove an installed container" \
            adopt     "Open an installed rootfs in the chroot workbench" \
            configure "Configure rootfs location and run-as user" \
            uninstall "Uninstall the $tag tool itself" \
            help      "Show $tag help" \
            back      "Back") || return 0
        case "$c" in
            browse) rootfs_dm_browse_install "$tag" ;;
            installed) rootfs_dm_show_command "$tag" "$tag — installed" list ;;
            login)
                d=$(rootfs_dm_pick_installed "$tag") || continue
                [ -n "$d" ] || continue
                clear
                rootfs_dm_run "$tag" "Log in to $d" login "$d" || true
                read -rp "(press Enter)" _ || true
                ;;
            remove)
                d=$(rootfs_dm_pick_installed "$tag") || continue
                [ -n "$d" ] || continue
                tui_yesno "Remove" "Delete '$d' and its rootfs from $tag?" || continue
                # Both current CLIs remove/unmount as part of `remove`.
                rootfs_dm_run "$tag" "Remove $d via $tag" remove "$d" || true
                ;;
            adopt) rootfs_dm_adopt "$tag" ;;
            configure) rootfs_dm_config_menu "$tag" ;;
            uninstall) rootfs_dm_remove "$tag" ;;
            help) rootfs_dm_show_command "$tag" "$tag help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

rootfs_dm_menu_distrobox() {
    local c d
    while true; do
        c=$(tui_menu_no_tags "$(rootfs_dm_label distrobox)" \
            "distrobox uses create/enter/list/rm; compatible images are parsed from create --compatibility." \
            install   "Install or update distrobox" \
            browse    "Browse/select/create compatible distroboxes" \
            installed "List distroboxes" \
            enter     "Enter a distrobox" \
            remove    "Remove a distrobox" \
            configure "Configure run-as user" \
            uninstall "Uninstall distrobox" \
            help      "Show distrobox help" \
            back      "Back") || return 0
        case "$c" in
            install) rootfs_dm_install distrobox ;;
            browse) rootfs_dm_browse_install distrobox ;;
            installed) rootfs_dm_show_command distrobox "distrobox list" list ;;
            enter)
                d=$(tui_input "Enter distrobox" "Container name:" "") || continue
                [ -n "$d" ] && rootfs_dm_run distrobox "Enter $d" enter "$d" || true ;;
            remove)
                d=$(tui_input "Remove distrobox" "Container name:" "") || continue
                [ -n "$d" ] || continue
                tui_yesno "Remove" "Delete distrobox '$d'?" || continue
                rootfs_dm_run distrobox "Remove $d" rm --force --yes "$d" || true ;;
            configure) rootfs_dm_config_menu distrobox ;;
            uninstall) rootfs_dm_remove distrobox ;;
            help) rootfs_dm_show_command distrobox "distrobox help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

rootfs_dm_menu_toolbx() {
    local c d
    while true; do
        c=$(tui_menu_no_tags "$(rootfs_dm_label toolbx)" \
            "Toolbx accepts OCI images with create --image and enters them with toolbox enter." \
            create    "Create a Toolbx from an OCI image" \
            installed "List Toolbx containers/images" \
            enter     "Enter a Toolbx" \
            remove    "Remove a Toolbx" \
            configure "Configure run-as user" \
            uninstall "Uninstall Toolbx" \
            help      "Show toolbox help" \
            back      "Back") || return 0
        case "$c" in
            create) rootfs_dm_browse_install toolbx ;;
            installed) rootfs_dm_show_command toolbx "toolbox list" list ;;
            enter)
                d=$(tui_input "Enter Toolbx" "Container name (blank = default):" "") || continue
                clear
                if [ -n "$d" ]; then rootfs_dm_run toolbx "Enter $d" enter "$d" || true
                else rootfs_dm_run toolbx "Enter default Toolbx" enter || true; fi
                read -rp "(press Enter)" _ || true ;;
            remove)
                d=$(tui_input "Remove Toolbx" "Container name:" "") || continue
                [ -n "$d" ] || continue
                tui_yesno "Remove" "Delete Toolbx '$d'?" || continue
                rootfs_dm_run toolbx "Remove $d" rm --force "$d" ||
                    rootfs_dm_run toolbx "Remove $d" rm "$d" || true ;;
            configure) rootfs_dm_config_menu toolbx ;;
            uninstall) rootfs_dm_remove toolbx ;;
            help) rootfs_dm_show_command toolbx "toolbox help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

rootfs_dm_menu_udocker() {
    local c d
    while true; do
        c=$(tui_menu_no_tags "$(rootfs_dm_label udocker)" \
            "udocker installs a runnable container as pull IMAGE -> create --name=NAME IMAGE." \
            browse    "Search/select/pull/create images" \
            images    "List downloaded images" \
            containers "List created containers" \
            run       "Run a created container" \
            remove    "Remove a created container" \
            configure "Configure run-as user" \
            uninstall "Uninstall udocker" \
            help      "Show udocker help" \
            back      "Back") || return 0
        case "$c" in
            browse) rootfs_dm_browse_install udocker ;;
            images) rootfs_dm_show_command udocker "udocker images" images ;;
            containers) rootfs_dm_show_command udocker "udocker containers" ps -m -s ;;
            run)
                d=$(tui_input "Run udocker" "Container name/id:" "") || continue
                [ -n "$d" ] || continue
                clear
                rootfs_dm_run udocker "Run $d" run "$d" || true
                read -rp "(press Enter)" _ || true ;;
            remove)
                d=$(tui_input "Remove udocker container" "Container name/id:" "") || continue
                [ -n "$d" ] || continue
                tui_yesno "Remove" "Delete udocker container '$d'?" || continue
                rootfs_dm_run udocker "Remove $d" rm "$d" || true ;;
            configure) rootfs_dm_config_menu udocker ;;
            uninstall) rootfs_dm_remove udocker ;;
            help) rootfs_dm_show_command udocker "udocker help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

rootfs_dm_menu_schroot() {
    local c d
    while true; do
        c=$(tui_menu_no_tags "$(rootfs_dm_label schroot)" \
            "schroot manages configured chroots; it does not download/install distributions itself." \
            list      "List configured chroots" \
            enter     "Start a shell in a configured chroot" \
            adopt     "Open a chroot tree in the systui workbench" \
            configure "Configure detected chroot location" \
            uninstall "Uninstall schroot" \
            help      "Show schroot help" \
            back      "Back") || return 0
        case "$c" in
            list) rootfs_dm_show_command schroot "schroot list" --list ;;
            enter)
                d=$(rootfs_dm_pick_installed schroot) || continue
                [ -n "$d" ] || continue
                clear
                rootfs_dm_run schroot "Enter $d" -c "$d" || true
                read -rp "(press Enter)" _ || true ;;
            adopt) rootfs_dm_adopt schroot ;;
            configure) rootfs_dm_config_menu schroot ;;
            uninstall) rootfs_dm_remove schroot ;;
            help) rootfs_dm_show_command schroot "schroot help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

rootfs_dm_menu_machinectl() {
    local c d url name
    while true; do
        c=$(tui_menu_no_tags "$(rootfs_dm_label machinectl)" \
            "machinectl manages systemd machine images; importing requires an explicit tar/raw URL rather than a distro alias." \
            list    "List machine images" \
            pulltar "Import a tar image from URL (pull-tar)" \
            shell   "Open a shell in a machine" \
            remove  "Remove a machine image" \
            help    "Show machinectl help" \
            back    "Back") || return 0
        case "$c" in
            list) rootfs_dm_show_command machinectl "machinectl images" list-images ;;
            pulltar)
                url=$(tui_input "machinectl pull-tar" "Tar image URL:" "") || continue
                [ -n "$url" ] || continue
                name=$(tui_input "machinectl pull-tar" "Local image name (blank = derive from URL):" "") || continue
                if [ -n "$name" ]; then rootfs_dm_run machinectl "Import $name" pull-tar "$url" "$name" || true
                else rootfs_dm_run machinectl "Import image" pull-tar "$url" || true; fi ;;
            shell)
                d=$(tui_input "machinectl shell" "Machine name:" "") || continue
                [ -n "$d" ] || continue
                clear
                rootfs_dm_run machinectl "Shell in $d" shell "$d" || true
                read -rp "(press Enter)" _ || true ;;
            remove)
                d=$(tui_input "machinectl remove" "Image name:" "") || continue
                [ -n "$d" ] || continue
                tui_yesno "Remove" "Delete machine image '$d'?" || continue
                rootfs_dm_run machinectl "Remove $d" remove "$d" || true ;;
            help) rootfs_dm_show_command machinectl "machinectl help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

rootfs_dm_menu_arch_chroot() {
    local c path
    while true; do
        c=$(tui_menu_no_tags "$(rootfs_dm_label arch-chroot)" \
            "arch-chroot is an entry helper for an existing root tree; it is not a distro downloader." \
            enter "Enter an existing root directory" \
            help  "Show arch-chroot help" \
            back  "Back") || return 0
        case "$c" in
            enter)
                path=$(tui_input "arch-chroot" "Existing rootfs directory:" "$ROOTFS_BASE") || continue
                [ -d "$path" ] || { tui_msg "Not found" "$path is not a directory."; continue; }
                clear
                rootfs_dm_run arch-chroot "Enter $path" "$path" || true
                read -rp "(press Enter)" _ || true ;;
            help) rootfs_dm_show_command arch-chroot "arch-chroot help" --help ;;
            back|"") return 0 ;;
        esac
    done
}

rootfs_dm_menu_one() { # <tag>
    case "$1" in
        proot-distro|chroot-distro) rootfs_dm_menu_proot_chroot "$1" ;;
        distrobox) rootfs_dm_menu_distrobox ;;
        toolbx) rootfs_dm_menu_toolbx ;;
        udocker) rootfs_dm_menu_udocker ;;
        schroot) rootfs_dm_menu_schroot ;;
        machinectl) rootfs_dm_menu_machinectl ;;
        arch-chroot) rootfs_dm_menu_arch_chroot ;;
        *) tui_msg "Unsupported manager" "No command map exists for $1." ;;
    esac
}
