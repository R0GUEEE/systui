# shellcheck shell=bash
###############################################################################
# ROOTFS BOOTSTRAP: TOOL CONFIGURATION, BUILD DEFAULTS AND BUILD MODE
#
# Two problems this fixes:
#
#  1. The Rootfs Bootstrap Tools menu could only show static help text for a
#     tool ("View/edit configuration" printed a paragraph). It now offers real
#     configuration: the tool's own configuration files, systui build defaults
#     for that tool, its version and host requirements, and the settings a build
#     would actually use.
#  2. Rootfs builds were forced into automatic mode, which replaced the
#     bootstrap-tool choice (Rootfs Builder 4/13) and the per-tool configuration
#     step with "pick the first available tool". Automatic mode is now opt-in,
#     from this menu or with SYSTUI_ROOTFS_AUTOMATIC_BUILD=1.
###############################################################################

# standalone safety: pull in the alias helper when this feature is sourced
# without core/common.sh (tests, reduced builds).
if ! declare -F systui_alias_function >/dev/null 2>&1; then
    _systui_alias_mod="${SYSTUI_LIBDIR:-$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)}/src/core/alias.sh"
    # shellcheck disable=SC1090
    [ -r "$_systui_alias_mod" ] && . "$_systui_alias_mod"
    unset _systui_alias_mod
fi

# --- persisted settings ------------------------------------------------------

systui_bsc_file() {
    printf '%s/rootfs-bootstrap.conf\n' "${SYSTUI_STATE_DIR:-/etc/systui}"
}

systui_bsc_get() { # <key> [default]
    local key="$1" def="${2:-}" file line
    file=$(systui_bsc_file)
    if [ -r "$file" ]; then
        while IFS='=' read -r line || [ -n "$line" ]; do
            case "$line" in ''|'#'*) continue ;; esac
            case "$line" in
                "$key="*) printf '%s\n' "${line#*=}"; return 0 ;;
            esac
        done < "$file"
    fi
    printf '%s\n' "$def"
}

systui_bsc_set() { # <key> <value>
    local key="$1" value="$2" file dir tmp line written=0
    file=$(systui_bsc_file)
    dir=${file%/*}
    mkdir -p "$dir" 2>/dev/null || return 1
    tmp="${SYSTUI_TMP:-${TMPDIR:-/tmp}}/.systui-bootstrap-conf.$$"
    if [ -r "$file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "$key="*) [ "$written" -eq 1 ] && continue; printf '%s=%s\n' "$key" "$value" >> "$tmp"; written=1 ;;
                *) printf '%s\n' "$line" >> "$tmp" ;;
            esac
        done < "$file"
    fi
    [ "$written" -eq 1 ] || printf '%s=%s\n' "$key" "$value" >> "$tmp"
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file"
}

systui_bsc_automatic() {
    if [ -n "${SYSTUI_ROOTFS_AUTOMATIC_BUILD:-}" ]; then
        case "$SYSTUI_ROOTFS_AUTOMATIC_BUILD" in 1|yes|true|on) return 0 ;; *) return 1 ;; esac
    fi
    case "$(systui_bsc_get automatic 0)" in 1|yes|true|on) return 0 ;; *) return 1 ;; esac
}

systui_bsc_default_tool() { systui_bsc_get default_tool ''; }

# --- per-tool configuration files --------------------------------------------

# Config files that belong to each bootstrap tool. Tools without a file of their
# own get a systui-managed override, listed with the leading marker "new:".
systui_bsc_tool_files() { # <tag>
    case "$1" in
        debootstrap) printf '%s\n' /etc/debootstrap/config /etc/debootstrap/scripts ;;
        cdebootstrap) printf '%s\n' /etc/cdebootstrap/cdebootstrap.conf /etc/cdebootstrap/sources.list /etc/cdebootstrap/scripts ;;
        multistrap) printf '%s\n' /etc/multistrap.conf /etc/apt/multistrap.conf ;;
        mmdebstrap|bdebstrap) printf '%s\n' new:/etc/mmdebstrap.conf new:/etc/debootstrap/config ;;
        qemu-user-static|binfmt-support) printf '%s\n' /etc/qemu-binfmt.conf /etc/binfmt.d/qemu.conf ;;
        schroot) printf '%s\n' /etc/schroot/schroot.conf /etc/schroot/default/config ;;
        systemd-container) printf '%s\n' /etc/systemd/nspawn/default.nspawn ;;
        proot) printf '%s\n' new:/etc/proot.conf ;;
        fakechroot|fakeroot) printf '%s\n' /etc/fakechroot/fakechroot.conf new:/etc/systui/fakeroot.conf ;;
        arch-install-scripts) printf '%s\n' /etc/pacman.conf /etc/pacman.d/mirrorlist ;;
        xbps-tools) printf '%s\n' /etc/xbps.d/00-repository-main.conf /etc/xbps.d/10-repository-multilib.conf ;;
        dnf) printf '%s\n' /etc/dnf/dnf.conf /etc/yum.repos.d/fedora.repo ;;
        zypper) printf '%s\n' /etc/zypp/zypp.conf /etc/zypp/repos.d/ ;;
        chroot-distro) printf '%s\n' new:/etc/systui/chroot-distro.conf ;;
        rinse) printf '%s\n' new:/etc/systui/rinse.conf ;;
        zstd|xz-utils|tar) printf '%s\n' new:/etc/systui/compression.conf ;;
        *) return 1 ;;
    esac
}

systui_bsc_edit_file() { # <path> [template]
    local path="$1" template="${2:-}" dir
    dir=${path%/*}
    if [ ! -e "$path" ]; then
        if ! tui_yesno "Create configuration file" "$path does not exist yet.\n\nCreate it with a documented template?"; then
            return 0
        fi
        mkdir -p "$dir" 2>/dev/null || { tui_msg "Cannot create" "Could not create $dir."; return 1; }
        {
            printf '# %s\n' "$path"
            printf '# Created by systui — edit freely, values here are read by the rootfs build.\n'
            [ -z "$template" ] || printf '%s\n' "$template"
        } > "$path" || { tui_msg "Cannot write" "Could not write $path."; return 1; }
    fi
    if declare -F safe_edit >/dev/null 2>&1; then
        safe_edit "$path" || return 1
    else
        "${EDITOR:-vi}" "$path" || return 1
    fi
    return 0
}

# Real per-tool configuration, replacing the former static help text.
systui_bsc_tool_config_menu() { # <tag> <label>
    local tag="$1" label="$2" c path entries=() entry
    while true; do
        c=$(tui_menu "$label configuration" \
            "Configure the bootstrap tool itself. Build-wide defaults live under 'Build defaults'." \
            files "Edit configuration files" \
            defaults "Systui build defaults for $tag" \
            default_tool "Use $tag for new builds" \
            info "Version, host requirements and detection" \
            state "Show the settings a build would use" \
            instructions "How systui invokes $tag" \
            back "← Back") || return 0
        case "$c" in
            files)
                entries=()
                local file_list="${SYSTUI_TMP:-/tmp}/systui-bsc-files.$$"
                systui_bsc_tool_files "$tag" > "$file_list" 2>/dev/null || : > "$file_list"
                while IFS= read -r entry; do
                    [ -n "$entry" ] || continue
                    case "$entry" in
                        new:*) path=${entry#new:}; entries+=("$path" "$(basename "$path") — create/edit systui override") ;;
                        *)     path=$entry
                               if [ -e "$path" ]; then
                                   entries+=("$path" "$(basename "$path") — edit")
                               else
                                   entries+=("$path" "$(basename "$path") — not present (create)")
                               fi ;;
                    esac
                done < "$file_list"
                rm -f -- "$file_list"
                if [ "${#entries[@]}" -eq 0 ]; then
                    tui_msg "No configuration files" "$tag has no dedicated configuration file on this host.\n\nUse 'Systui build defaults' to control how it is invoked."
                    continue
                fi
                path=$(tui_menu "$label files" "Files shipped with $tag:" "${entries[@]}" back "← Back") || continue
                [ "$path" = back ] && continue
                [ -n "$path" ] || continue
                systui_bsc_edit_file "$path" "$(systui_bsc_template_for "$tag")" || true
                ;;
            defaults) systui_bsc_defaults_menu ;;
            default_tool)
                systui_bsc_set default_tool "$tag"
                tui_msg "Default bootstrap tool" "New rootfs builds will preselect $tag."
                ;;
            info) systui_bsc_tool_info "$tag" "$label" ;;
            state) systui_bsc_show_state ;;
            instructions) systui_bsc_instructions "$tag" ;;
            back|'') return 0 ;;
        esac
    done
}

systui_bsc_template_for() { # <tag>
    case "$1" in
        mmdebstrap|bdebstrap|debootstrap)
            printf '# variant=%s\n# components=main\n# include=\n# exclude=\n# mirror=' \
                "$(systui_bsc_get variant minbase)" ;;
        xz-utils) printf '# Systui compression defaults\n# level=6\n' ;;
        zstd) printf '# Systui compression defaults\n# level=3\n' ;;
        *) printf '' ;;
    esac
}

systui_bsc_tool_info() { # <tag> <label>
    local tag="$1" label="$2" out reqs cmd version=""
    out="${SYSTUI_TMP:-/tmp}/systui-bsc-info.$$"
    reqs=$(rootfs_backend_requirements "$tag" 2>/dev/null || true)
    cmd=$(rootfs_backend_command "$tag" 2>/dev/null || printf '%s' "$tag")
    if command -v "$cmd" >/dev/null 2>&1; then
        version=$( { "$cmd" --version 2>&1 || "$cmd" -V 2>&1 || true; } | head -n 1 )
    fi
    {
        printf 'Tool: %s (%s)\n' "$label" "$tag"
        printf 'Command: %s\n' "$cmd"
        printf 'Detected: %s\n' "$(command -v "$cmd" 2>/dev/null || echo 'not installed')"
        printf 'Version: %s\n' "${version:-unknown}"
        printf 'Host requirements: %s\n' "${reqs:-none beyond a POSIX shell}"
        printf 'Systui default tool: %s\n' "$(systui_bsc_default_tool || echo none)"
        printf 'Build mode: %s\n' "$(systui_bsc_automatic && echo automatic || echo interactive)"
    } > "$out"
    tui_text "$label — information" "$out" || true
    rm -f -- "$out"
}

systui_bsc_instructions() { # <tag>
    local tag="$1" out
    out="${SYSTUI_TMP:-/tmp}/systui-bsc-invoke.$$"
    case "$tag" in
        debootstrap) printf 'debootstrap --variant=%s --components=%s [--include=...] <release> <target> <mirror>\n' "$(systui_bsc_get variant minbase)" "$(systui_bsc_get components main)" ;;
        mmdebstrap)  printf 'mmdebstrap --mode=%s%s --variant=%s <release> <target> <mirror>\n' \
                        "$(systui_bsc_get mmdebstrap_mode root)" \
                        "$([ "$(systui_bsc_get mmdebstrap_prune yes)" = yes ] && printf ' --prune=yes' || true)" \
                        "$(systui_bsc_get variant minbase)" ;;
        cdebootstrap) printf 'cdebootstrap --flavour=%s <release> <target> <mirror>\n' "$(systui_bsc_get variant minimal)" ;;
        multistrap)  printf 'multistrap -f <generated.conf> -d <target>\n' ;;
        *)           printf '%s is driven by the settings under "Build defaults"; systui builds the\ncommand line for the selected distribution and release.\n' "$tag" ;;
    esac > "$out"
    tui_text "$tag — how systui invokes it" "$out" || true
    rm -f -- "$out"
}

# --- build-wide defaults -----------------------------------------------------

systui_bsc_defaults_menu() {
    local c value
    while true; do
        c=$(tui_menu "Bootstrap build defaults" \
            "Applied to every new build (Rootfs Builder shows them pre-filled):" \
            variant "Base variant: $(systui_bsc_get variant minbase)" \
            components "Archive components: $(systui_bsc_get components main)" \
            include "Bootstrap include: $(systui_bsc_get include none)" \
            exclude "Bootstrap exclude: $(systui_bsc_get exclude none)" \
            mirror "Default mirror: $(systui_bsc_get mirror auto)" \
            mode "mmdebstrap mode: $(systui_bsc_get mmdebstrap_mode root)" \
            prune "mmdebstrap prune docs/locales: $(systui_bsc_get mmdebstrap_prune yes)" \
            tool "Preferred bootstrap tool: $(systui_bsc_default_tool || echo automatic)" \
            clear "Reset all build defaults" \
            back "← Back") || return 0
        case "$c" in
            variant|components|include|exclude|mirror|mmdebstrap_mode|mmdebstrap_prune)
                value=$(tui_input "Bootstrap default" \
                    "Value for '$c' (blank clears it):" "$(systui_bsc_get "$c" '')") || continue
                if [ -z "$value" ]; then
                    systui_bsc_set "$c" ''
                else
                    systui_bsc_set "$c" "$value"
                fi
                ;;
            tool)
                value=$(tui_input "Preferred bootstrap tool" \
                    "Tool tag (debootstrap, mmdebstrap, cdebootstrap, multistrap, ...; blank for automatic):" \
                    "$(systui_bsc_default_tool)") || continue
                systui_bsc_set default_tool "$value"
                ;;
            prune)
                if [ "$(systui_bsc_get mmdebstrap_prune yes)" = yes ]; then
                    systui_bsc_set mmdebstrap_prune no
                else
                    systui_bsc_set mmdebstrap_prune yes
                fi
                ;;
            clear)
                tui_yesno "Reset build defaults" "Remove every stored bootstrap default?" || continue
                rm -f -- "$(systui_bsc_file)"
                tui_msg "Bootstrap defaults" "Stored defaults removed; systui defaults apply again."
                ;;
            back|'') return 0 ;;
        esac
    done
}

systui_bsc_show_state() {
    local out="${SYSTUI_TMP:-/tmp}/systui-bsc-state.$$"
    {
        printf 'File: %s\n' "$(systui_bsc_file)"
        printf 'Exists: %s\n\n' "$([ -r "$(systui_bsc_file)" ] && echo yes || echo no)"
        printf 'Build mode: %s\n' "$(systui_bsc_automatic && echo automatic || echo interactive)"
        printf 'Preferred tool: %s\n\n' "$(systui_bsc_default_tool || echo automatic)"
        printf 'variant=%s\ncomponents=%s\ninclude=%s\nexclude=%s\nmirror=%s\nmmdebstrap_mode=%s\nmmdebstrap_prune=%s\n' \
            "$(systui_bsc_get variant minbase)" \
            "$(systui_bsc_get components main)" \
            "$(systui_bsc_get include none)" \
            "$(systui_bsc_get exclude none)" \
            "$(systui_bsc_get mirror auto)" \
            "$(systui_bsc_get mmdebstrap_mode root)" \
            "$(systui_bsc_get mmdebstrap_prune yes)"
    } > "$out"
    tui_text "Bootstrap build state" "$out" || true
    rm -f -- "$out"
}

# Replaces the static help text that "View/edit configuration" used to print.
_bs_config() { # <tag> <label>
    if declare -F rootfs_backend_requirements >/dev/null 2>&1 \
        || declare -F systui_bsc_tool_files >/dev/null 2>&1; then
        systui_bsc_tool_config_menu "$1" "${2:-$1}"
        return $?
    fi
    tui_msg "$2 configuration" "No configuration helper is available in this build."
}

# --- bootstrap tools menu: configuration and build mode ----------------------

if declare -F menu_rootfs_bootstrap_tools >/dev/null 2>&1 \
    && ! declare -F _systui_bsc_base_bootstrap_menu >/dev/null 2>&1; then
    systui_alias_function menu_rootfs_bootstrap_tools _systui_bsc_base_bootstrap_menu
fi

menu_rootfs_bootstrap_tools() {
    local c mode
    while true; do
        if systui_bsc_automatic; then mode=automatic; else mode=interactive; fi
        c=$(tui_menu_no_tags "Rootfs Bootstrap Tools" \
            "Install bootstrap tools, configure them, and choose how rootfs builds behave.\nBuild mode: $mode  ·  Preferred tool: $(systui_bsc_default_tool || echo automatic)" \
            multi "Install multiple tools (SPACE to select)" \
            single "Manage individual bootstrap tools (install, remove, configure)" \
            defaults "Build defaults — variant, components, include/exclude, mirror" \
            mode "Build mode — switch between interactive and automatic" \
            state "Show the settings a build would use" \
            back "← Back") || return 0
        case "$c" in
            multi|single) _systui_bsc_base_bootstrap_menu "$@" ;;
            defaults) systui_bsc_defaults_menu ;;
            mode) systui_bsc_toggle_mode ;;
            state) systui_bsc_show_state ;;
            back|'') return 0 ;;
        esac
    done
}

systui_bsc_toggle_mode() {
    if systui_bsc_automatic; then
        if tui_yesno "Build mode" \
            "Automatic builds skip the bootstrap-tool choice, the per-tool configuration step, the compression choice and account passwords.\n\nSwitch back to interactive builds?"; then
            systui_bsc_set automatic 0
            tui_msg "Build mode" "Interactive builds restored: every build asks for the bootstrap tool and its options."
        fi
    else
        if tui_yesno "Build mode" \
            "Interactive builds ask for the bootstrap tool (Rootfs Builder 4/13) and its configuration on every build.\n\nSwitch to automatic builds instead?"; then
            systui_bsc_set automatic 1
            tui_msg "Build mode" "Automatic builds enabled. SYSTUI_ROOTFS_AUTOMATIC_BUILD=0 overrides this for one run."
        fi
    fi
}

# --- build integration -------------------------------------------------------

# Apply the persisted defaults on top of whichever defaults the build computed,
# so stored values win over the built-in (and auto-optimized) ones.
systui_bsc_apply_defaults() {
    local v
    v=$(systui_bsc_get variant '');          [ -n "$v" ] && ROOTFS_BACKEND_VARIANT="$v"
    v=$(systui_bsc_get components '');       [ -n "$v" ] && ROOTFS_BACKEND_COMPONENTS="$v"
    v=$(systui_bsc_get include '');          [ -n "$v" ] && ROOTFS_BACKEND_INCLUDE="$v"
    v=$(systui_bsc_get exclude '');          [ -n "$v" ] && ROOTFS_BACKEND_EXCLUDE="$v"
    v=$(systui_bsc_get mmdebstrap_mode '');  [ -n "$v" ] && ROOTFS_MMDEBSTRAP_MODE="$v"
    v=$(systui_bsc_get mmdebstrap_prune ''); [ -n "$v" ] && ROOTFS_MMDEBSTRAP_PRUNE="$v"
    return 0
}

if declare -F rootfs_backend_config_defaults >/dev/null 2>&1 \
    && ! declare -F _systui_bsc_base_backend_defaults >/dev/null 2>&1; then
    systui_alias_function rootfs_backend_config_defaults _systui_bsc_base_backend_defaults
fi
rootfs_backend_config_defaults() {
    _systui_bsc_base_backend_defaults "$@"
    systui_bsc_apply_defaults
}

if declare -F rootfs_backend_auto_optimize >/dev/null 2>&1 \
    && ! declare -F _systui_bsc_base_auto_optimize >/dev/null 2>&1; then
    systui_alias_function rootfs_backend_auto_optimize _systui_bsc_base_auto_optimize
fi
rootfs_backend_auto_optimize() {
    _systui_bsc_base_auto_optimize "$@"
    systui_bsc_apply_defaults
}

# "Automatic" in the backend picker means "the preferred tool, else the first
# usable one" — the picker label calls this too, so the choice is visible.
if declare -F rootfs_resolve_backend >/dev/null 2>&1 \
    && ! declare -F _systui_bsc_base_resolve_backend >/dev/null 2>&1; then
    systui_alias_function rootfs_resolve_backend _systui_bsc_base_resolve_backend
fi
rootfs_resolve_backend() { # <distro> <selected> [arch] [release]
    local distro="$1" selected="${2:-auto}" arch="${3:-}" release="${4:-}" preferred
    if [ "$selected" = auto ]; then
        preferred=$(systui_bsc_default_tool 2>/dev/null || true)
        if [ -n "$preferred" ] && rootfs_backend_supported "$distro" "$preferred" "$arch" "$release" 2>/dev/null \
            && rootfs_backend_available "$preferred" 2>/dev/null; then
            printf '%s\n' "$preferred"
            return 0
        fi
    fi
    _systui_bsc_base_resolve_backend "$@"
}

# Honour the stored mirror as the default for Rootfs Builder 7/13.
if declare -F tui_input >/dev/null 2>&1 \
    && ! declare -F _systui_bsc_base_tui_input >/dev/null 2>&1; then
    systui_alias_function tui_input _systui_bsc_base_tui_input
fi
tui_input() {
    if [ "${1:-}" = "Rootfs Builder 7/13" ] && [ -z "${3:-}" ]; then
        local _bsc_mirror
        _bsc_mirror=$(systui_bsc_get mirror '' 2>/dev/null || true)
        [ -n "$_bsc_mirror" ] && set -- "$1" "$2" "$_bsc_mirror"
    fi
    _systui_bsc_base_tui_input "$@"
}

# Automatic builds stay available, but only when they were asked for: the flag
# used to be forced here, which silently removed the bootstrap-tool choice and
# the tool configuration step from every build.
if declare -F rootfs_builder_impl >/dev/null 2>&1 \
    && ! declare -F _systui_bsc_base_builder_impl >/dev/null 2>&1; then
    systui_alias_function rootfs_builder_impl _systui_bsc_base_builder_impl
fi
rootfs_builder_impl() {
    if systui_bsc_automatic; then
        if [ "${SYSTUI_ROOTFS_AUTOMATIC_CONFIRMED:-0}" != 1 ] && [ "${SYSTUI_ROOTFS_AUTOMATIC_BUILD:-0}" != 1 ]; then
            tui_yesno "Automatic build" \
"Automatic mode skips the bootstrap-tool choice, per-tool configuration, the compression choice and account passwords.\n\nContinue with an automatic build?" || {
                systui_bsc_set automatic 0
                tui_msg "Build mode" "Interactive builds restored."
                return 0
            }
        fi
        local SYSTUI_ROOTFS_AUTOMATIC_BUILD=1 SYSTUI_ROOTFS_AUTOMATIC_CONFIRMED=1
        _systui_bsc_base_builder_impl "$@"
        return
    fi
    # Interactive builds must not go through the automatic-mode wrapper, which
    # would force the flag back on and skip the bootstrap-tool choice.
    if declare -F _systui_base_rootfs_builder_impl >/dev/null 2>&1; then
        _systui_base_rootfs_builder_impl "$@"
    else
        _systui_bsc_base_builder_impl "$@"
    fi
    return
}

return 0 2>/dev/null || true
