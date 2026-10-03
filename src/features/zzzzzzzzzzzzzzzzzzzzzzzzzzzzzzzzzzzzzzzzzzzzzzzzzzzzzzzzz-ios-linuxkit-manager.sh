# shellcheck shell=bash
###############################################################################
# SYSTEM CONFIGURATION — iOS LinuxKit manager
#
# rcarmo/ios-linuxkit runs an AArch64 Linux userland inside an iOS app and as a
# command-line process on an AArch64 Linux host. It derives from iSH and ships
# a single guest architecture (ARM64): a Meson/Ninja C build, the `ish` runtime
# binary, and `tools/fakefsify`, which turns a root filesystem tarball into the
# fakefs image the runtime boots from.
#
# This module gives System Configuration one front door for that toolchain:
# check out the source, check (and optionally provide) the build dependencies,
# build it, manage guest root filesystems, run guest shells and commands, and
# diagnose the result.
#
# Design rules followed throughout (they are the point of the module):
#   * No silent work. Every action shows the exact command it will run and the
#     path it will touch before it runs.
#   * No invented facts. A probe that cannot answer reports "unknown", never
#     "missing" -- otherwise the menu would plan pointless installs.
#   * No dead buttons. A capability this host cannot provide is stated with the
#     reason and the manual command to use elsewhere.
#   * Guest downloads are pinned: the ROOTFS_URL/ROOTFS_SHA256 pair is the
#     release authority (app/GuestARM64.xcconfig), and the archive's architecture
#     is validated before it is imported.
###############################################################################

# Standalone safety: pull in the alias helper when this feature is sourced
# without core/common.sh (tests, reduced builds).
if ! declare -F systui_alias_function >/dev/null 2>&1; then
    _systui_ioskit_alias_mod="${SYSTUI_LIBDIR:-$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)}/src/core/alias.sh"
    # shellcheck disable=SC1090
    [ -r "$_systui_ioskit_alias_mod" ] && . "$_systui_ioskit_alias_mod"
    unset _systui_ioskit_alias_mod
fi

###############################################################################
# STATE AND CONFIGURATION
###############################################################################

# The release pin this module ships with, used when the source tree (and thus
# its own app/GuestARM64.xcconfig) is not available yet. Keep these in step with
# the upstream xcconfig; the source tree always wins when it is present.
SYSTUI_IOSKIT_FALLBACK_ROOTFS_URL="dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-minirootfs-3.24.2-aarch64.tar.gz"
SYSTUI_IOSKIT_FALLBACK_ROOTFS_SHA256="9bf70a7f18ea44094cbb5f70c58f9af129c8214745743db0e68e5502cc2ce773"

systui_ioskit_conf_file() {
    printf '%s\n' "${SYSTUI_IOSKIT_CONF:-${SYSTUI_STATE_DIR:-/etc/systui}/ios-linuxkit.conf}"
}

systui_ioskit_root_default() {
    printf '%s\n' "${SYSTUI_IOSKIT_ROOT:-/opt/ios-linuxkit}"
}

# Load settings. Values already present in the environment win, so an operator
# can point the manager at an existing checkout without editing files.
systui_ioskit_load() {
    local root
    root=$(systui_ioskit_root_default)
    IOSKIT_REPO_URL="${IOSKIT_REPO_URL:-https://github.com/rcarmo/ios-linuxkit.git}"
    IOSKIT_BRANCH="${IOSKIT_BRANCH:-master}"
    IOSKIT_SRC_DIR="${IOSKIT_SRC_DIR:-$root/src}"
    IOSKIT_IMAGES_DIR="${IOSKIT_IMAGES_DIR:-$root/images}"
    IOSKIT_DOWNLOAD_DIR="${IOSKIT_DOWNLOAD_DIR:-$root/downloads}"
    IOSKIT_DEFAULT_IMAGE="${IOSKIT_DEFAULT_IMAGE:-}"
    IOSKIT_AUTO_DEPS="${IOSKIT_AUTO_DEPS:-1}"
    IOSKIT_ROOTFS_URL="${IOSKIT_ROOTFS_URL:-}"
    IOSKIT_ROOTFS_SHA256="${IOSKIT_ROOTFS_SHA256:-}"
    IOSKIT_BIND_MOUNTS="${IOSKIT_BIND_MOUNTS:-}"
    IOSKIT_NETLINK="${IOSKIT_NETLINK:-0}"
    IOSKIT_RUNTIME="${IOSKIT_RUNTIME:-release}"

    local f line key val
    f=$(systui_ioskit_conf_file)
    if [ -r "$f" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in ''|'#'*) continue ;; esac
            key=${line%%=*}
            val=${line#*=}
            case "$key" in
                IOSKIT_REPO_URL|IOSKIT_BRANCH|IOSKIT_SRC_DIR|IOSKIT_IMAGES_DIR|\
                IOSKIT_DOWNLOAD_DIR|IOSKIT_DEFAULT_IMAGE|IOSKIT_AUTO_DEPS|\
                IOSKIT_ROOTFS_URL|IOSKIT_ROOTFS_SHA256|IOSKIT_BIND_MOUNTS|\
                IOSKIT_NETLINK|IOSKIT_RUNTIME)
                    printf -v "$key" '%s' "$val"
                    ;;
            esac
        done < "$f"
    fi
}

# Persist one setting. Only the keys this module owns are accepted, so a stray
# name can never rewrite an unrelated variable or inject a line.
systui_ioskit_conf_set() { # <key> <value>
    local key="$1" val="$2" f tmp line
    case "$key" in
        IOSKIT_REPO_URL|IOSKIT_BRANCH|IOSKIT_SRC_DIR|IOSKIT_IMAGES_DIR|\
        IOSKIT_DOWNLOAD_DIR|IOSKIT_DEFAULT_IMAGE|IOSKIT_AUTO_DEPS|\
        IOSKIT_ROOTFS_URL|IOSKIT_ROOTFS_SHA256|IOSKIT_BIND_MOUNTS|\
        IOSKIT_NETLINK|IOSKIT_RUNTIME) ;;
        *) return 2 ;;
    esac
    case "$val" in *$'\n'*) return 2 ;; esac

    f=$(systui_ioskit_conf_file)
    mkdir -p "${f%/*}" 2>/dev/null || true
    tmp="$f.systui.$$"
    if [ -r "$f" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in "$key="*) continue ;; esac
            printf '%s\n' "$line" >> "$tmp"
        done < "$f"
    fi
    printf '%s=%s\n' "$key" "$val" >> "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 1; }
    printf -v "$key" '%s' "$val"
    return 0
}

# Clear a setting by rewriting the file without it (used to fall back to the
# built-in defaults rather than pinning a stale value forever).
systui_ioskit_conf_unset() { # <key>
    local key="$1" f tmp line
    case "$key" in
        IOSKIT_REPO_URL|IOSKIT_BRANCH|IOSKIT_SRC_DIR|IOSKIT_IMAGES_DIR|\
        IOSKIT_DOWNLOAD_DIR|IOSKIT_DEFAULT_IMAGE|IOSKIT_AUTO_DEPS|\
        IOSKIT_ROOTFS_URL|IOSKIT_ROOTFS_SHA256|IOSKIT_BIND_MOUNTS|\
        IOSKIT_NETLINK|IOSKIT_RUNTIME) ;;
        *) return 2 ;;
    esac
    f=$(systui_ioskit_conf_file)
    [ -r "$f" ] || return 0
    tmp="$f.systui.$$"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "$key="*) continue ;; esac
        printf '%s\n' "$line" >> "$tmp"
    done < "$f"
    mv "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 1; }
    printf -v "$key" '%s' ''
    return 0
}

# Establish defaults at load time as well as from the menus, so every helper is
# safe to call directly (tests, reduced builds, another feature) without the
# caller having to know that a load pass exists first.
systui_ioskit_load

###############################################################################
# DETECTION AND STATUS
###############################################################################

systui_ioskit_have() { # <command>
    command -v "$1" >/dev/null 2>&1
}

# Resolved once: the machine architecture cannot change while the app runs, and
# the recommendation line asks for it on every redraw.
_SYSTUI_IOSKIT_ARCH=''

systui_ioskit_host_arch() {
    local m
    # Populated by systui_ioskit_cache_warm, which runs before every menu draw.
    # A value resolved through command substitution could not be cached -- a
    # command substitution runs in its own process -- so if the global is unset
    # the probe happens here and simply is not remembered.
    if [ -n "${_SYSTUI_IOSKIT_ARCH:-}" ]; then
        printf '%s\n' "$_SYSTUI_IOSKIT_ARCH"
        return
    fi
    m=$(uname -m 2>/dev/null || printf 'unknown')
    case "$m" in
        aarch64|arm64) m='aarch64' ;;
        x86_64|amd64)  m='x86_64' ;;
    esac
    printf '%s\n' "$m"
}

_systui_ioskit_resolve_arch() {
    local m
    [ -n "${_SYSTUI_IOSKIT_ARCH:-}" ] && return 0
    m=$(uname -m 2>/dev/null || printf 'unknown')
    case "$m" in
        aarch64|arm64) m='aarch64' ;;
        x86_64|amd64)  m='x86_64' ;;
    esac
    _SYSTUI_IOSKIT_ARCH="$m"
    return 0
}

systui_ioskit_repo_present() {
    [ -n "${IOSKIT_SRC_DIR:-}" ] || return 1
    [ -d "$IOSKIT_SRC_DIR/.git" ]
}

systui_ioskit_dirty() { # 1 when the checkout has local changes (best effort)
    local out
    systui_ioskit_repo_present || return 1
    systui_ioskit_have git || return 1
    if [ -n "${_SYSTUI_IOSKIT_CACHE_READY:-}" ]; then
        [ "${_SYSTUI_IOSKIT_DIRTY:-0}" = 1 ]
        return
    fi
    out=$(git -C "$IOSKIT_SRC_DIR" status --porcelain 2>/dev/null) || return 1
    [ -n "$out" ]
}

systui_ioskit_version() { # printed short version/commit of the checkout
    local out
    if [ -n "${_SYSTUI_IOSKIT_CACHE_READY:-}" ]; then
        printf '%s\n' "${_SYSTUI_IOSKIT_VERSION:-unknown}"
        return
    fi
    systui_ioskit_repo_present || { printf '%s\n' 'not checked out'; return; }
    if systui_ioskit_have git; then
        out=$(git -C "$IOSKIT_SRC_DIR" describe --tags --always 2>/dev/null) \
            && [ -n "$out" ] && { printf '%s\n' "$out"; return; }
    fi
    printf '%s\n' 'unknown'
}

# A menu redraw runs the status probes every keystroke, and each miss here is a
# `git` process. iSH and other emulated hosts fork slowly, so the answer is
# cached for the lifetime of the menu session and invalidated by the handful of
# actions that can actually change it (clone, update, build, import).
systui_ioskit_cache_invalidate() {
    unset _SYSTUI_IOSKIT_CACHE_READY _SYSTUI_IOSKIT_DIRTY _SYSTUI_IOSKIT_VERSION \
        _SYSTUI_IOSKIT_BIN _SYSTUI_IOSKIT_IMAGE_COUNT _SYSTUI_IOSKIT_ARCH
}

systui_ioskit_cache_warm() {
    local out d
    _SYSTUI_IOSKIT_CACHE_READY=1
    _SYSTUI_IOSKIT_DIRTY=0
    _SYSTUI_IOSKIT_VERSION='not checked out'
    _SYSTUI_IOSKIT_BIN=''
    if systui_ioskit_repo_present; then
        if systui_ioskit_have git; then
            out=$(git -C "$IOSKIT_SRC_DIR" describe --tags --always 2>/dev/null) || out=''
            [ -n "$out" ] && _SYSTUI_IOSKIT_VERSION="$out"
            out=$(git -C "$IOSKIT_SRC_DIR" status --porcelain 2>/dev/null) || out=''
            [ -n "$out" ] && _SYSTUI_IOSKIT_DIRTY=1
        fi
    fi
    for d in $(systui_ioskit_build_dirs); do
        if [ -x "$IOSKIT_SRC_DIR/$d/ish" ]; then
            _SYSTUI_IOSKIT_BIN="$IOSKIT_SRC_DIR/$d/ish"
            break
        fi
    done
    _SYSTUI_IOSKIT_IMAGE_COUNT=$(systui_ioskit_count_images_now)
    _systui_ioskit_resolve_arch
}

# The build outputs to look for, most-preferred first. Kept in one place so the
# build menu, the runner and the status report can never disagree.
systui_ioskit_build_dirs() {
    printf '%s\n' \
        "build-arm64-linux" \
        "build-arm64-linux-debug" \
        "build-arm64-native-release"
}

systui_ioskit_ish_bin() {
    local d
    if [ -n "${_SYSTUI_IOSKIT_CACHE_READY:-}" ]; then
        [ -n "${_SYSTUI_IOSKIT_BIN:-}" ] || return 1
        printf '%s\n' "$_SYSTUI_IOSKIT_BIN"
        return 0
    fi
    for d in $(systui_ioskit_build_dirs); do
        if [ -x "$IOSKIT_SRC_DIR/$d/ish" ]; then
            printf '%s\n' "$IOSKIT_SRC_DIR/$d/ish"
            return 0
        fi
    done
    return 1
}

systui_ioskit_ish_bin_for() { # <build-dir-name>
    printf '%s\n' "$IOSKIT_SRC_DIR/$1/ish"
}

systui_ioskit_fakefsify_bin() {
    local d
    for d in $(systui_ioskit_build_dirs); do
        if [ -x "$IOSKIT_SRC_DIR/$d/tools/fakefsify" ]; then
            printf '%s\n' "$IOSKIT_SRC_DIR/$d/tools/fakefsify"
            return 0
        fi
    done
    return 1
}

# unfakefsify is a symlink to fakefsify in the build tree; the tool selects the
# export direction from its own argv[0], so the link has to be used, not a
# copy under a new name.
systui_ioskit_unfakefsify_bin() {
    local d
    for d in $(systui_ioskit_build_dirs); do
        if [ -x "$IOSKIT_SRC_DIR/$d/tools/unfakefsify" ]; then
            printf '%s\n' "$IOSKIT_SRC_DIR/$d/tools/unfakefsify"
            return 0
        fi
    done
    return 1
}

# The debug build is the one upstream asks for when the change touches memory,
# signals, concurrency or translated execution.
systui_ioskit_debug_bin() {
    if [ -x "$IOSKIT_SRC_DIR/build-arm64-linux-debug/ish" ]; then
        printf '%s\n' "$IOSKIT_SRC_DIR/build-arm64-linux-debug/ish"
        return 0
    fi
    return 1
}

systui_ioskit_require_tool() { # <tool> <what>
    if systui_ioskit_have "$1"; then
        return 0
    fi
    tui_msg "$2" "$1 is not installed on this host.\n\nInstall it, or use the manual command shown under \"Show the exact commands\"."
    return 1
}

# Binary build tool plus the library its pkg-config name resolves to. The
# dev-library entry is probed separately because a compiler alone does not
# build the runtime.
systui_ioskit_tool_bins() {
    printf '%s\n' git make meson ninja clang pkg-config curl tar file sha256sum
}

systui_ioskit_devlibs() {
    printf '%s\n' sqlite3 libarchive
}

systui_ioskit_tool_state() { # <tool> -> ready|missing
    if systui_ioskit_have "$1"; then
        printf '%s\n' ready
    else
        printf '%s\n' missing
    fi
}

# pkg-config answers "is the dev package installed?" but only if pkg-config
# itself exists. Without it the honest answer is "unknown", not "missing".
systui_ioskit_devlib_state() { # <pkg-config-name> -> ready|missing|unknown
    if ! systui_ioskit_have pkg-config; then
        printf '%s\n' unknown
        return
    fi
    if pkg-config --exists "$1" 2>/dev/null; then
        printf '%s\n' ready
    else
        printf '%s\n' missing
    fi
}

systui_ioskit_pm_family() {
    case "${PM:-}" in
        apt|apt-get) printf '%s\n' apt ;;
        apk)         printf '%s\n' apk ;;
        dnf)         printf '%s\n' dnf ;;
        yum)         printf '%s\n' yum ;;
        pacman)      printf '%s\n' pacman ;;
        zypper)      printf '%s\n' zypper ;;
        '')          printf '%s\n' unknown ;;
        *)           printf '%s\n' "$PM" ;;
    esac
}

# Package names per build requirement and package manager. These were verified
# against real indexes rather than assumed: Alpine has no plain `ninja` (that
# name resolves to samurai, a different tool) and ships `pkgconf`, while the
# Debian family ships `pkg-config`. An empty result means "no known package
# name for this manager" -- the caller must say so instead of guessing.
systui_ioskit_pkg_for() { # <requirement> <family>
    local req="$1" fam="$2"
    case "$req:$fam" in
        git:apt|git:dnf|git:yum|git:pacman|git:zypper) printf '%s\n' git ;;
        git:apk) printf '%s\n' git ;;
        make:apt|make:dnf|make:yum|make:pacman|make:zypper|make:apk) printf '%s\n' make ;;
        meson:apt|meson:dnf|meson:yum|meson:pacman|meson:zypper|meson:apk) printf '%s\n' meson ;;
        ninja:apt) printf '%s\n' ninja-build ;;
        ninja:dnf|ninja:yum|ninja:zypper) printf '%s\n' ninja-build ;;
        ninja:pacman) printf '%s\n' ninja ;;
        ninja:apk) printf '%s\n' ninja-build ;;
        clang:apt|clang:apk) printf '%s\n' clang ;;
        clang:dnf|clang:yum) printf '%s\n' clang ;;
        clang:pacman) printf '%s\n' clang ;;
        clang:zypper) printf '%s\n' clang ;;
        pkg-config:apt|pkg-config:dnf|pkg-config:yum|pkg-config:zypper) printf '%s\n' pkg-config ;;
        pkg-config:pacman) printf '%s\n' pkgconf ;;
        pkg-config:apk) printf '%s\n' pkgconf ;;
        curl:apt|curl:dnf|curl:yum|curl:pacman|curl:zypper|curl:apk) printf '%s\n' curl ;;
        tar:apt|tar:dnf|tar:yum|tar:pacman|tar:zypper|tar:apk) printf '%s\n' tar ;;
        file:apt|file:dnf|file:yum|file:pacman|file:zypper|file:apk) printf '%s\n' file ;;
        sha256sum:apt|sha256sum:dnf|sha256sum:yum|sha256sum:zypper|sha256sum:apk) printf '%s\n' coreutils ;;
        sha256sum:pacman) printf '%s\n' coreutils ;;
        sqlite3:apt) printf '%s\n' libsqlite3-dev ;;
        sqlite3:apk) printf '%s\n' sqlite-dev ;;
        sqlite3:dnf|sqlite3:yum) printf '%s\n' sqlite-devel ;;
        sqlite3:zypper) printf '%s\n' sqlite3-devel ;;
        sqlite3:pacman) printf '%s\n' sqlite ;;
        libarchive:apt) printf '%s\n' libarchive-dev ;;
        libarchive:apk) printf '%s\n' libarchive-dev ;;
        libarchive:dnf|libarchive:yum) printf '%s\n' libarchive-devel ;;
        libarchive:zypper) printf '%s\n' libarchive-devel ;;
        libarchive:pacman) printf '%s\n' libarchive ;;
        *) : ;;
    esac
}

# Requirements that are genuinely missing for a host build, one per line, as
# "<requirement> <package-or-dash>". Distinguishes "unknown" (pkg-config absent)
# from "missing" so a failed probe never triggers a mass install.
systui_ioskit_missing_requirements() {
    local fam tool state pkg
    fam=$(systui_ioskit_pm_family)
    for tool in $(systui_ioskit_tool_bins); do
        state=$(systui_ioskit_tool_state "$tool")
        [ "$state" = ready ] && continue
        pkg=$(systui_ioskit_pkg_for "$tool" "$fam")
        printf '%s %s\n' "$tool" "${pkg:--}"
    done
    for tool in $(systui_ioskit_devlibs); do
        state=$(systui_ioskit_devlib_state "$tool")
        [ "$state" = ready ] && continue
        [ "$state" = unknown ] && { printf '%s %s\n' "${tool}-dev" '-'; continue; }
        pkg=$(systui_ioskit_pkg_for "$tool" "$fam")
        printf '%s %s\n' "${tool}-dev" "${pkg:--}"
    done
}

# One install command for every missing package that has a known name. Returns
# 1 when nothing can be installed, so the caller can explain instead of running
# an empty command.
systui_ioskit_install_plan() {
    local req pkg fam line out=()
    fam=$(systui_ioskit_pm_family)
    if [ "$fam" = unknown ]; then
        return 1
    fi
    while IFS=' ' read -r req pkg; do
        [ -n "$req" ] || continue
        [ "$pkg" = '-' ] && continue
        out+=("$pkg")
    done <<EOF
$(systui_ioskit_missing_requirements)
EOF
    [ "${#out[@]}" -gt 0 ] || return 1
    printf '%s\n' "${out[*]}"
    return 0
}

systui_ioskit_state_summary() {
    local src bin images
    if systui_ioskit_repo_present; then
        src="source: $(systui_ioskit_version)"
        systui_ioskit_dirty && src="$src (local changes)"
    else
        src="source: not checked out"
    fi
    if bin=$(systui_ioskit_ish_bin); then
        bin="runtime: ${bin#"$IOSKIT_SRC_DIR"/}"
    else
        bin="runtime: not built"
    fi
    images=$(systui_ioskit_image_count)
    local extra=''
    [ -n "${IOSKIT_BIND_MOUNTS:-}" ] && extra="$extra   bind mounts: on"
    [ "${IOSKIT_NETLINK:-0}" = 1 ] && extra="$extra   netlink stub: on"
    printf '%s\n' "$src   $bin   root filesystems: $images$extra"
}

systui_ioskit_status_text() { # full report for the status screen
    local line tool state pkg fam arch
    arch=$(systui_ioskit_host_arch)
    fam=$(systui_ioskit_pm_family)
    printf 'iOS LinuxKit — status\n'
    printf '=====================\n\n'
    printf 'Host\n'
    printf '  architecture : %s\n' "$arch"
    printf '  package mgr  : %s\n' "${PM:-unknown}"
    printf '  state dir     : %s\n' "$(systui_ioskit_conf_file)"
    printf '\nSource\n'
    printf '  repository   : %s\n' "$IOSKIT_REPO_URL"
    printf '  branch       : %s\n' "$IOSKIT_BRANCH"
    printf '  checkout     : %s (%s)\n' "$IOSKIT_SRC_DIR" \
        "$(systui_ioskit_repo_present && printf 'present' || printf 'absent')"
    printf '  version      : %s\n' "$(systui_ioskit_version)"
    if systui_ioskit_dirty; then
        printf '  local changes: yes — update will refuse to run destructively\n'
    fi
    printf '\nBuild tools\n'
    for tool in $(systui_ioskit_tool_bins); do
        state=$(systui_ioskit_tool_state "$tool")
        printf '  %-12s : %s\n' "$tool" "$state"
    done
    for tool in $(systui_ioskit_devlibs); do
        state=$(systui_ioskit_devlib_state "$tool")
        printf '  %-12s : %s' "${tool}-dev" "$state"
        pkg=$(systui_ioskit_pkg_for "$tool" "$fam")
        [ "$state" = missing ] && [ -n "$pkg" ] && printf ' (package: %s)' "$pkg"
        printf '\n'
    done
    printf '\nBuild outputs\n'
    for line in $(systui_ioskit_build_dirs); do
        if [ -x "$IOSKIT_SRC_DIR/$line/ish" ]; then
            printf '  %-24s : built\n' "$line"
        else
            printf '  %-24s : absent\n' "$line"
        fi
    done
    printf '\nGuest root filesystems (%s)\n' "$IOSKIT_IMAGES_DIR"
    if [ -d "$IOSKIT_IMAGES_DIR" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            printf '  %s\n' "$line"
        done <<EOF
$(systui_ioskit_image_list)
EOF
    else
        printf '  (no images directory yet)\n'
    fi
    printf '\nHonest limits\n'
    printf '  * The Linux-host build targets AArch64 hosts. On %s the\n' "$arch"
    printf '    supported path is the iOS/Xcode target, or building on an\n'
    printf '    aarch64 Linux machine (make build-arm64-linux).\n'
    printf '  * Nothing here can run guest binaries from the iOS sandbox:\n'
    printf '    the app cannot spawn processes. Use the Linux host build, or\n'
    printf '    the ios-linuxkit app itself, to execute a guest.\n'
    printf '  * The optional native/AOT backend is off by default upstream;\n'
    printf '    this manager does not enable it.\n'
}

###############################################################################
# SOURCE TREE
###############################################################################

systui_ioskit_src_parent() {
    printf '%s\n' "${IOSKIT_SRC_DIR%/*}"
}

systui_ioskit_source_clone() { # <url> <branch> <dir>
    local url="$1" branch="$2" dir="$3"
    mkdir -p "${dir%/*}" 2>/dev/null || true
    if [ -e "$dir" ] && [ ! -d "$dir/.git" ]; then
        tui_msg "Source" "Refusing to clone into $dir:\n\nit exists but is not a git checkout.\n\nMove or remove it first (the manager will not delete it for you)."
        return 1
    fi
    if systui_ioskit_have git && [ -d "$dir/.git" ]; then
        tui_msg "Source" "Already a checkout:\n$dir"
        return 0
    fi
    run_cmd "Check out ios-linuxkit ($url, branch $branch)" \
        git clone --recurse-submodules --branch "$branch" -- "$url" "$dir" || return 1
    systui_ioskit_cache_invalidate
    return 0
}

systui_ioskit_source_update() { # fast-forward only, keeps local edits
    local dirty=0
    systui_ioskit_repo_present || { tui_msg "Source" "No checkout at $IOSKIT_SRC_DIR yet."; return 1; }
    systui_ioskit_have git || { tui_msg "Source" "git is not installed; cannot update the checkout."; return 1; }
    systui_ioskit_dirty && dirty=1
    if [ "$dirty" = 1 ]; then
        tui_yesno "Source" "The checkout has local changes.\n\nUpdating uses a fast-forward-only pull; it will stop rather than merge or discard your edits. Continue?" || return 0
    fi
    run_cmd "Update submodules" git -C "$IOSKIT_SRC_DIR" submodule update --init --recursive || return 1
    run_cmd "Fast-forward pull" git -C "$IOSKIT_SRC_DIR" pull --ff-only || return 1
    systui_ioskit_cache_invalidate
    return 0
}

###############################################################################
# BUILD
###############################################################################

systui_ioskit_build_target_for() { # <kind: release|debug>
    case "$1" in
        debug) printf '%s\n' build-arm64-linux-debug ;;
        *)     printf '%s\n' build-arm64-linux ;;
    esac
}

# A host build only makes sense on an AArch64 host: the runtime's host gadgets
# are architecture-specific and upstream documents AArch64 Linux bring-up.
systui_ioskit_build_supported() {
    [ "$(systui_ioskit_host_arch)" = aarch64 ]
}

systui_ioskit_check_tools() {
    local missing
    missing=$(systui_ioskit_missing_requirements)
    [ -z "$missing" ]
}

systui_ioskit_build_menu() {
    local c target plan
    while true; do
        tui_capture_menu c tui_menu_no_tags "Build ios-linuxkit" \
            "Rebuild toolchain check:\n$(systui_ioskit_tool_brief)" \
            check    "Check build dependencies" \
            install  "Install missing build dependencies" \
            release  "Build release (make build-arm64-linux)" \
            debug    "Build debug (make build-arm64-linux-debug)" \
            all      "Build release and debug" \
            back     "Back" || return $?
        case "$c" in
            check)   systui_ioskit_deps_report ;;
            install) systui_ioskit_install_deps ;;
            release) target=$(systui_ioskit_build_target_for release); systui_ioskit_run_build "$target" ;;
            debug)   target=$(systui_ioskit_build_target_for debug); systui_ioskit_run_build "$target" ;;
            all)
                systui_ioskit_run_build "$(systui_ioskit_build_target_for release)" || continue
                systui_ioskit_run_build "$(systui_ioskit_build_target_for debug)" || continue
                ;;
            back|'') return 0 ;;
        esac
    done
}

systui_ioskit_tool_brief() {
    local tool state parts=()
    for tool in git make meson ninja clang; do
        state=$(systui_ioskit_tool_state "$tool")
        parts+=("$tool=$state")
    done
    printf '%s\n' "${parts[*]}"
}

systui_ioskit_deps_report() {
    systui_ioskit_show_text "Build dependencies" systui_ioskit_deps_text
}

systui_ioskit_deps_text() {
    local fam req pkg state plan
    fam=$(systui_ioskit_pm_family)
    printf 'Build requirements for ios-linuxkit\n'
    printf '===================================\n\n'
    printf 'Detected package manager: %s\n' "${PM:-unknown}"
    printf 'Host architecture: %s\n' "$(systui_ioskit_host_arch)"
    if ! systui_ioskit_build_supported; then
        printf '\nNOTE: the Linux-host build targets AArch64 hosts. On this host\n'
        printf 'the build may not produce a runnable binary; the dependencies\n'
        printf 'below are still what the upstream build needs.\n'
    fi
    printf '\nRequirement   State     Package for this manager\n'
    printf '-----------   -------   -----------------------\n'
    while IFS=' ' read -r req pkg; do
        [ -n "$req" ] || continue
        case "$req" in
            *-dev) state=$(systui_ioskit_devlib_state "${req%-dev}") ;;
            *)     state=$(systui_ioskit_tool_state "$req") ;;
        esac
        [ -z "$pkg" ] && pkg='-'
        printf '%-12s  %-8s  %s\n' "$req" "$state" "$pkg"
    done <<EOF
$(systui_ioskit_dep_rows)
EOF
    printf '\n"unknown" means pkg-config is not installed, so the development\n'
    printf 'library could not be probed either way.\n'
    printf '\nPlan: %s\n' "$(systui_ioskit_install_plan || printf 'nothing to install')"
}

# Same rows as missing_requirements, but including satisfied requirements so the
# report shows the whole picture.
systui_ioskit_dep_rows() {
    local fam tool state pkg
    fam=$(systui_ioskit_pm_family)
    for tool in $(systui_ioskit_tool_bins); do
        state=$(systui_ioskit_tool_state "$tool")
        pkg=$(systui_ioskit_pkg_for "$tool" "$fam")
        printf '%s %s\n' "$tool" "${pkg:--}"
    done
    for tool in $(systui_ioskit_devlibs); do
        state=$(systui_ioskit_devlib_state "$tool")
        pkg=$(systui_ioskit_pkg_for "$tool" "$fam")
        [ "$state" = unknown ] && pkg='-'
        printf '%s-dev %s\n' "$tool" "${pkg:--}"
    done
}

systui_ioskit_install_deps() {
    local plan
    plan=$(systui_ioskit_install_plan)
    if [ -z "$plan" ]; then
        tui_msg "Build dependencies" "Nothing installable was identified.\n\nEither every requirement is present, the package manager is unknown, or no package name is known for one of the missing items. See \"Check build dependencies\" for the exact list and install manually."
        return 0
    fi
    if ! declare -F pm_install >/dev/null 2>&1; then
        tui_msg "Build dependencies" "This systui build has no package installer available.\n\nInstall manually:\n\n$plan"
        return 0
    fi
    tui_yesno "Build dependencies" "Install with the system package manager ($PM)?\n\n$plan" || return 0
    # shellcheck disable=SC2086
    pm_install $plan
}

systui_ioskit_run_build() { # <make-target>
    local target="$1" binary
    systui_ioskit_repo_present || {
        tui_msg "Build" "No source checkout at\n$IOSKIT_SRC_DIR\n\nUse Source → Check out."
        return 1
    }
    if ! systui_ioskit_have make; then
        tui_msg "Build" "make is not installed.\n\nUse Build → Install missing build dependencies, or install it manually."
        return 1
    fi
    if ! systui_ioskit_check_tools; then
        if [ "$IOSKIT_AUTO_DEPS" = 1 ]; then
            tui_yesno "Build" "Some build requirements are missing.\n\nInstall them now with $PM? (you can turn this off in Settings)" || return 0
            systui_ioskit_install_deps
        else
            tui_msg "Build" "Build requirements are missing and automatic installation is off.\n\nRun Build → Check build dependencies to see what is missing."
            return 1
        fi
    fi
    if ! systui_ioskit_build_supported; then
        tui_yesno "Build" "This host is $(systui_ioskit_host_arch), not aarch64.\n\nUpstream documents the Linux-host build for AArch64. The build may fail or produce a binary that cannot run here.\n\nRun it anyway?" || return 0
    fi

    run_cmd "Build ios-linuxkit ($target)" \
        make -C "$IOSKIT_SRC_DIR" "$target" CC=clang || return 1

    systui_ioskit_cache_invalidate
    if binary=$(systui_ioskit_ish_bin); then
        tui_msg "Build" "Build finished.\n\nRuntime: $binary"
    else
        tui_msg "Build" "The build command finished, but no ish binary was found under:\n\n$IOSKIT_SRC_DIR/build-arm64-linux/"
    fi
    return 0
}

###############################################################################
# GUEST ROOT FILESYSTEMS
###############################################################################

systui_ioskit_image_path() { # <name> -> path
    printf '%s\n' "${IOSKIT_IMAGES_DIR:-}/$1"
}

systui_ioskit_image_list() {
    local d
    [ -d "$IOSKIT_IMAGES_DIR" ] || return 0
    for d in "$IOSKIT_IMAGES_DIR"/*; do
        [ -d "$d" ] || continue
        printf '%s\n' "${d##*/}"
    done
}

systui_ioskit_image_count() {
    if [ -n "${_SYSTUI_IOSKIT_CACHE_READY:-}" ]; then
        printf '%s\n' "${_SYSTUI_IOSKIT_IMAGE_COUNT:-0}"
        return
    fi
    systui_ioskit_count_images_now
}

systui_ioskit_count_images_now() {
    local n=0 d
    [ -d "$IOSKIT_IMAGES_DIR" ] || { printf '%s\n' 0; return; }
    for d in "$IOSKIT_IMAGES_DIR"/*; do
        [ -d "$d" ] && n=$((n + 1))
    done
    printf '%s\n' "$n"
}

systui_ioskit_image_size() { # <path>
    local out
    if systui_ioskit_have du; then
        out=$(du -sh "$1" 2>/dev/null) || out=''
        [ -n "$out" ] && { printf '%s\n' "${out%%[[:space:]]*}"; return; }
    fi
    printf '%s\n' 'unknown'
}

systui_ioskit_image_valid() { # <path> -> a fakefs image is a directory tree
    [ -d "$1" ] || return 1
    [ -d "$1/bin" ] || [ -d "$1/usr" ] || [ -d "$1/etc" ]
}

# The leading "/" is not part of a name, and neither are path separators or
# parent references: an image name must be a single directory entry.
systui_ioskit_image_name_ok() { # <name>
    case "$1" in
        ''|.|..|*/*|*\\*) return 1 ;;
    esac
    return 0
}

# Upstream pin: the app's xcconfig carries ROOTFS_URL/ROOTFS_SHA256. The URL
# there has no scheme (the app builds it), so we normalise it to https.
systui_ioskit_xcconfig_file() {
    printf '%s\n' "$IOSKIT_SRC_DIR/app/GuestARM64.xcconfig"
}

systui_ioskit_xcconfig_get() { # <key> -> value
    local key="$1" f line k v
    f=$(systui_ioskit_xcconfig_file)
    [ -r "$f" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%%//*}
        k=${line%%=*}
        k=${k#"${k%%[![:space:]]*}"}
        k=${k%"${k##*[![:space:]]}"}
        [ -n "$k" ] || continue
        [ "$k" = "$key" ] || continue
        v=${line#*=}
        v=${v#"${v%%[![:space:]]*}"}
        v=${v%"${v##*[![:space:]]}"}
        [ -n "$v" ] || return 1
        printf '%s\n' "$v"
        return 0
    done < "$f"
    return 1
}

# Effective pin as "url sha256 name": settings override, then the checkout's own
# xcconfig, then the built-in release pin.
systui_ioskit_rootfs_pin() {
    local url sha name
    url="${IOSKIT_ROOTFS_URL:-}"
    sha="${IOSKIT_ROOTFS_SHA256:-}"
    if [ -z "$url" ]; then
        url=$(systui_ioskit_xcconfig_get ROOTFS_URL || true)
        sha=$(systui_ioskit_xcconfig_get ROOTFS_SHA256 || true)
    fi
    [ -n "$url" ] || url="$SYSTUI_IOSKIT_FALLBACK_ROOTFS_URL"
    [ -n "$sha" ] || sha="$SYSTUI_IOSKIT_FALLBACK_ROOTFS_SHA256"
    case "$url" in
        http://*|https://*) ;;
        */alpine/*) url="https://$url" ;;
        *) url="https://$url" ;;
    esac
    name=${url##*/}
    printf '%s %s %s\n' "$url" "$sha" "$name"
}

systui_ioskit_rootfs_pin_source() {
    if [ -n "${IOSKIT_ROOTFS_URL:-}" ]; then
        printf '%s\n' 'settings override'
    elif systui_ioskit_xcconfig_get ROOTFS_URL >/dev/null 2>&1; then
        printf '%s\n' 'checkout (app/GuestARM64.xcconfig)'
    else
        printf '%s\n' 'built-in release pin'
    fi
}

systui_ioskit_sha256() { # <file> -> hash
    local out
    if systui_ioskit_have sha256sum; then
        out=$(sha256sum "$1" 2>/dev/null) && { printf '%s\n' "${out%% *}"; return 0; }
    fi
    if systui_ioskit_have shasum; then
        out=$(shasum -a 256 "$1" 2>/dev/null) && { printf '%s\n' "${out%% *}"; return 0; }
    fi
    return 1
}

# Download with the first available fetcher. curl and wget both follow
# redirects and fail on an HTTP error, so a partial file can never be treated as
# a successful download.
systui_ioskit_fetch() { # <url> <dest>
    if systui_ioskit_have curl; then
        curl -fL --progress-bar -o "$2" "$1"
    elif systui_ioskit_have wget; then
        wget -O "$2" "$1"
    else
        return 127
    fi
}

# Download to a staging file, verify, and only then move it into place. A
# failed fetch or a bad checksum can therefore never replace a good archive,
# and a partial file is never handed to fakefsify.
systui_ioskit_download_verified() { # <url> <expected-sha256|-> <dest>
    local url="$1" sha="$2" dest="$3" part got
    part="$dest.part"
    rm -f -- "$part"
    run_cmd "Download $url" systui_ioskit_fetch "$url" "$part" || { rm -f -- "$part"; return 1; }
    if [ -n "$sha" ] && [ "$sha" != '-' ]; then
        got=$(systui_ioskit_sha256 "$part" || true)
        if [ -z "$got" ]; then
            tui_msg "Download" "No SHA-256 tool is installed, so the download could not be verified.\n\nThe archive was kept at:\n$part"
            return 1
        fi
        if [ "$got" != "$sha" ]; then
            tui_msg "Download" "Checksum mismatch — the download was discarded.\n\nexpected $sha\ngot      $got"
            rm -f -- "$part"
            return 1
        fi
    fi
    mv -f -- "$part" "$dest" || { rm -f -- "$part"; return 1; }
    return 0
}


# its architecture. Reading the header of the binary that is actually packed is
# the only check a filename or a manifest cannot fool. "unknown" means this host
# lacks the tools to decide -- not that the archive is wrong.
# Mirror the app's own downloader: unpack just bin/busybox and ask file(1) for
# its architecture. Reading the header of the binary that is actually packed is
# the only check a filename or a manifest cannot fool. "unknown" means this host
# lacks the tools to decide -- not that the archive is wrong.
systui_ioskit_archive_arch() { # <tarball> -> aarch64|x86_64|unknown
    local tmp desc rc=0
    if ! systui_ioskit_have tar || ! systui_ioskit_have file; then
        printf '%s\n' unknown
        return 0
    fi
    tmp=$(mktemp -d 2>/dev/null) || { printf '%s\n' unknown; return 0; }
    tar -xzf "$1" -C "$tmp" ./bin/busybox 2>/dev/null || \
        tar -xzf "$1" -C "$tmp" bin/busybox 2>/dev/null || rc=1
    if [ "$rc" -ne 0 ] || [ ! -e "$tmp/bin/busybox" ]; then
        rm -rf -- "$tmp"
        printf '%s\n' unknown
        return 0
    fi
    desc=$(file "$tmp/bin/busybox" 2>/dev/null) || desc=''
    rm -rf -- "$tmp"
    case "$desc" in
        *"ARM aarch64"*) printf '%s\n' aarch64 ;;
        *x86-64*)        printf '%s\n' x86_64 ;;
        *)               printf '%s\n' unknown ;;
    esac
    return 0
}

# Show the output of a report function in a textbox without leaking temp files.
systui_ioskit_show_text() { # <title> <function> [args...]
    local title="$1" f
    shift
    f=$(mktemp 2>/dev/null || printf '%s' "${SYSTUI_TMP:-/tmp}/ioskit-text.$$")
    "$@" > "$f" 2>&1 || true
    tui_text "$title" "$f"
    rm -f -- "$f"
}

# Import and export are the two directions of the same operation and shared the
# same menu shape; grouping them keeps the everyday actions (list, default,
# remove, verify) above the fold of the dialog's visible list.
systui_ioskit_images_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Guest root filesystems" \
            "Directory: $IOSKIT_IMAGES_DIR\nImages: $(systui_ioskit_image_count)   default: ${IOSKIT_DEFAULT_IMAGE:-none}" \
            list    "List images" \
            add     "Add an image — pinned download, local tarball or URL" \
            export  "Export an image to a portable tarball" \
            default "Set the default image" \
            verify  "Verify an image" \
            remove  "Remove an image" \
            back    "Back" || return $?
        case "$c" in
            list)    systui_ioskit_show_text "Guest root filesystems" systui_ioskit_images_text ;;
            add)     systui_ioskit_image_add_menu ;;
            export)  systui_ioskit_export_image ;;
            default) systui_ioskit_set_default_image ;;
            verify)  systui_ioskit_verify_image ;;
            remove)  systui_ioskit_remove_image ;;
            back|'') return 0 ;;
        esac
    done
}

systui_ioskit_image_add_menu() {
    local c pin
    pin=$(systui_ioskit_rootfs_pin)
    while true; do
        tui_capture_menu c tui_menu_no_tags "Add an image" \
            "Pinned Alpine rootfs (from $(systui_ioskit_rootfs_pin_source)):\n${pin%% *}" \
            pinned "Download and import the pinned Alpine rootfs" \
            local  "Import a local rootfs tarball" \
            url    "Import from a URL (with optional SHA-256 check)" \
            back   "Back" || return $?
        case "$c" in
            pinned) systui_ioskit_download_pinned ;;
            local)  systui_ioskit_import_local ;;
            url)    systui_ioskit_import_url ;;
            back|'') return 0 ;;
        esac
    done
}

# fakefsify is built only when Meson finds libarchive. Without it neither import
# nor export exists, and the honest answer is "rebuild the tools", not "no
# images found".
systui_ioskit_fakefs_tool_warning() {
    local f
    if f=$(systui_ioskit_fakefsify_bin); then
        [ -x "$f" ] && return 0
    fi
    printf '\nNote: the fakefs tools are not built yet.\n'
    printf '  Meson creates tools/fakefsify (and the unfakefsify link) only when\n'
    printf '  it finds the libarchive development files. Install them, then\n'
    printf '  rebuild:\n'
    local pkg
    pkg=$(systui_ioskit_pkg_for libarchive "$(systui_ioskit_pm_family)")
    printf '    %s\n' "${pkg:-<libarchive development package>}"
    printf '    make -C %s build-arm64-linux CC=clang\n' "$IOSKIT_SRC_DIR"
}

systui_ioskit_export_image() {
    local name path out fakefsify unfakefsify ff
    if [ "$(systui_ioskit_image_count)" = 0 ]; then
        tui_msg "Export image" "No images to export.\n\nImport one first.$(systui_ioskit_fakefs_tool_warning)"
        return 0
    fi
    if ! unfakefsify=$(systui_ioskit_unfakefsify_bin); then
        tui_msg "Export image" "unfakefsify is not available.$(systui_ioskit_fakefs_tool_warning)"
        return 1
    fi
    name=$(systui_ioskit_choose_image) || return 0
    [ -n "$name" ] || return 0
    path="$IOSKIT_IMAGES_DIR/$name"
    if [ "$name" = __host__ ]; then
        tui_msg "Export image" "The host filesystem is not a guest image and cannot be exported."
        return 0
    fi
    out=$(tui_input "Export image" "Destination tarball:" "$IOSKIT_DOWNLOAD_DIR/${name}-export.tar.gz") || return 0
    [ -n "$out" ] || return 0

    # Upstream requires every guest using the image to be stopped first: the
    # export reads data/, meta.db and any SQLite WAL/SHM files together, and a
    # live guest can leave them inconsistent.
    tui_yesno "Export image" "Stop every guest using this image first.\n\nBefore continuing, confirm that:\n  * no ish process is running against $name;\n  * the app is not booted from this image.\n\nExport it now?" || return 0
    if [ -e "$out" ]; then
        tui_yesno "Export image" "Already exists:\n$out\n\nReplace it?" || return 0
    fi
    mkdir -p "${out%/*}" 2>/dev/null || true
    run_cmd "Export $name to $out" "$unfakefsify" "$path" "$out" || return 1
    if [ -s "$out" ]; then
        printf -v ff '%s\n' "$(systui_ioskit_sha256 "$out" || true)"
        tui_msg "Export image" "Exported:\n$out\n\nSHA-256:\n${ff:-unavailable}\n\nA portable export carries guest permissions and symlinks through fakefsify, which assigns new host inode numbers on import."
    else
        tui_msg "Export image" "The export tool finished but $out is missing or empty."
    fi
    # A raw snapshot needs the metadata database and its WAL/SHM siblings kept
    # together; say so once, where it matters.
    if [ -d "$path" ] && [ -e "$path/meta.db" ]; then
        tui_yesno "Export image" "The image also keeps a SQLite metadata database.\n\nA raw snapshot must copy data/, meta.db and any meta.db-wal / meta.db-shm together. Show the exact rsync command?" || return 0
        tui_msg "Raw snapshot" "rsync -a \\\\\n  --include 'data/***' --include 'meta.db*' --exclude '*' \\\\\n  $path/ <destination>/\n\nThe portable tarball above is usually the better choice."
    fi
}

systui_ioskit_images_text() {
    local d name size valid default marker
    default="$IOSKIT_DEFAULT_IMAGE"
    printf 'Guest root filesystems\n'
    printf '======================\n\n'
    printf 'Directory : %s\n' "$IOSKIT_IMAGES_DIR"
    printf 'Default   : %s\n' "${default:-none}"
    printf '\n'
    if [ ! -d "$IOSKIT_IMAGES_DIR" ]; then
        printf 'No images directory yet. Use "Download and import the pinned\n'
        printf 'Alpine rootfs" or "Import a local rootfs tarball".\n'
        return 0
    fi
    if [ "$(systui_ioskit_image_count)" = 0 ]; then
        printf 'The images directory exists but holds no images.\n'
        return 0
    fi
    printf '%-28s %-9s %-8s %s\n' NAME SIZE STATE NOTE
    printf '%-28s %-9s %-8s %s\n' ---- ---- ----- ----
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        d="$IOSKIT_IMAGES_DIR/$name"
        size=$(systui_ioskit_image_size "$d")
        if systui_ioskit_image_valid "$d"; then valid=ok; else valid=incomplete; fi
        marker=''
        [ "$name" = "$default" ] && marker='default'
        printf '%-28s %-9s %-8s %s\n' "$name" "$size" "$valid" "$marker"
    done <<EOF
$(systui_ioskit_image_list)
EOF
    if ! systui_ioskit_have fakefsify && [ ! -x "$IOSKIT_SRC_DIR/build-arm64-linux/tools/fakefsify" ]; then
        printf '\nNote: fakefsify is not built yet. Build the project first, then\n'
        printf 'import images — the manager uses the tool from the build tree.\n'
    fi
}

# Import one already-downloaded tarball into the images directory.
systui_ioskit_import_tarball() { # <tarball> <image-name>
    local tarball="$1" name="$2" dest fakefsify
    if ! systui_ioskit_image_name_ok "$name"; then
        tui_msg "Import" "Invalid image name: $name"
        return 1
    fi
    [ -r "$tarball" ] || { tui_msg "Import" "Cannot read:\n$tarball"; return 1; }
    if ! fakefsify=$(systui_ioskit_fakefsify_bin); then
        tui_msg "Import" "fakefsify is not built.\n\nIt is produced by the build in tools/fakefsify. Run Build first, then import."
        return 1
    fi
    if [ -z "${IOSKIT_IMAGES_DIR:-}" ]; then
        tui_msg "Import" "The images directory is not configured; refusing to write anything."
        return 1
    fi
    dest="$IOSKIT_IMAGES_DIR/$name"
    if [ -e "$dest" ]; then
        tui_yesno "Import" "Already exists:\n$dest\n\nReplace it?" || return 0
        rm -rf -- "${IOSKIT_IMAGES_DIR:?}/$name"
    fi
    mkdir -p "$IOSKIT_IMAGES_DIR" 2>/dev/null || true
    run_cmd "Import rootfs into $name" "$fakefsify" "$tarball" "$dest" || return 1
    systui_ioskit_cache_invalidate
    if systui_ioskit_image_valid "$dest"; then
        if [ -z "$IOSKIT_DEFAULT_IMAGE" ]; then
            systui_ioskit_conf_set IOSKIT_DEFAULT_IMAGE "$name" >/dev/null 2>&1 || true
        fi
        tui_msg "Import" "Imported:\n$dest"
    else
        tui_msg "Import" "fakefsify finished, but $dest does not look like a root filesystem.\n\nCheck the tool output in ${LOGFILE:-the systui log}."
    fi
    return 0
}

systui_ioskit_download_pinned() {
    local pin url sha name dl existing
    pin=$(systui_ioskit_rootfs_pin)
    url=${pin%% *}
    sha=${pin#* }
    name=${sha#* }
    sha=${sha%% *}
    name=${name%.tar.gz}
    [ -n "$name" ] || name="rootfs"

    tui_yesno "Download rootfs" "Source: $(systui_ioskit_rootfs_pin_source)\n\nURL:\n$url\n\nSHA-256:\n$sha\n\nDownload to $IOSKIT_DOWNLOAD_DIR and import as:\n$name" || return 0

    mkdir -p "$IOSKIT_DOWNLOAD_DIR" 2>/dev/null || true
    dl="$IOSKIT_DOWNLOAD_DIR/${url##*/}"

    existing=''
    [ -f "$dl" ] && existing=$(systui_ioskit_sha256 "$dl" || true)
    if [ "$existing" = "$sha" ]; then
        tui_msg "Download rootfs" "Already downloaded and verified:\n$dl"
    else
        if ! systui_ioskit_have curl && ! systui_ioskit_have wget; then
            tui_msg "Download rootfs" "Neither curl nor wget is installed.\n\nInstall one, or download the archive yourself and use \"Import a local rootfs tarball\":\n\n$url"
            return 1
        fi
        systui_ioskit_download_verified "$url" "$sha" "$dl" || return 1
    fi

    if ! systui_ioskit_have tar; then
        tui_msg "Download rootfs" "tar is not installed; cannot inspect the archive.\n\nArchive: $dl"
        return 1
    fi
    local arch
    arch=$(systui_ioskit_archive_arch "$dl")
    if [ "$arch" != aarch64 ]; then
        tui_yesno "Download rootfs" "The archive architecture reported as \"$arch\", not aarch64.\n\nios-linuxkit runs ARM64 guests only. Import it anyway?" || return 0
    fi
    systui_ioskit_import_tarball "$dl" "$name"
}

systui_ioskit_import_local() {
    local path name
    path=$(tui_input "Import rootfs" "Path to a root filesystem tarball\n(.tar.gz / .tar.xz / .tar):" "") || return 0
    [ -n "$path" ] || return 0
    if [ ! -r "$path" ]; then
        tui_msg "Import rootfs" "Cannot read:\n$path"
        return 1
    fi
    name=$(tui_input "Import rootfs" "Image name:" "${path##*/}") || return 0
    name=${name%.tar.gz}
    name=${name%.tar.xz}
    name=${name%.tar}
    [ -n "$name" ] || { tui_msg "Import rootfs" "An image name is required."; return 1; }
    systui_ioskit_import_tarball "$path" "$name"
}

systui_ioskit_import_url() {
    local url sha dl pin
    url=$(tui_input "Import from URL" "Root filesystem tarball URL:" "") || return 0
    [ -n "$url" ] || return 0
    pin=$(systui_ioskit_rootfs_pin)
    sha=$(tui_input "Import from URL" "Expected SHA-256 (leave empty to skip verification):" "${pin#* }") || return 0
    sha=${sha%% *}
    if [ -z "$sha" ]; then
        tui_yesno "Import from URL" "No checksum will be verified for:\n$url\n\nContinue?" || return 0
    fi
    if ! systui_ioskit_have curl && ! systui_ioskit_have wget; then
        tui_msg "Import from URL" "Neither curl nor wget is installed."
        return 1
    fi
    mkdir -p "$IOSKIT_DOWNLOAD_DIR" 2>/dev/null || true
    dl="$IOSKIT_DOWNLOAD_DIR/${url##*/}"
    systui_ioskit_download_verified "$url" "$sha" "$dl" || return 1
    systui_ioskit_import_tarball "$dl" "${dl##*/}"
}

systui_ioskit_choose_image() { # [allow-host]
    local -a opts=() name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        opts+=("$name" "$name ($(systui_ioskit_image_size "$IOSKIT_IMAGES_DIR/$name"))")
    done <<EOF
$(systui_ioskit_image_list)
EOF
    if [ "${1:-}" = allow-host ]; then
        opts+=("__host__" "Host filesystem (-r /, not a guest image)")
    fi
    [ "${#opts[@]}" -gt 0 ] || return 1
    tui_menu "Choose root filesystem" \
        "Which root filesystem should the guest use?\nDefault: ${IOSKIT_DEFAULT_IMAGE:-none}" \
        "${opts[@]}"
}

systui_ioskit_set_default_image() {
    local name
    if [ "$(systui_ioskit_image_count)" = 0 ]; then
        tui_msg "Default image" "No images to choose from.\n\nImport one first."
        return 0
    fi
    name=$(systui_ioskit_choose_image) || return 0
    [ -n "$name" ] || return 0
    systui_ioskit_conf_set IOSKIT_DEFAULT_IMAGE "$name" || {
        tui_msg "Default image" "Could not write $(systui_ioskit_conf_file)"
        return 1
    }
    tui_msg "Default image" "Default image is now:\n$name"
}

systui_ioskit_remove_image() {
    local name
    if [ "$(systui_ioskit_image_count)" = 0 ]; then
        tui_msg "Remove image" "No images to remove."
        return 0
    fi
    name=$(systui_ioskit_choose_image) || return 0
    [ -n "$name" ] || return 0
    if [ -z "${IOSKIT_IMAGES_DIR:-}" ]; then
        tui_msg "Remove image" "The images directory is not configured; refusing to delete anything."
        return 1
    fi
    tui_yesno "Remove image" "Delete the image and everything in it?\n\n$IOSKIT_IMAGES_DIR/$name\n\nThis cannot be undone." || return 0
    rm -rf -- "${IOSKIT_IMAGES_DIR:?}/$name"
    systui_ioskit_cache_invalidate
    if [ "$IOSKIT_DEFAULT_IMAGE" = "$name" ]; then
        systui_ioskit_conf_unset IOSKIT_DEFAULT_IMAGE >/dev/null 2>&1 || true
    fi
    tui_msg "Remove image" "Removed $name"
}

systui_ioskit_verify_image() {
    local name path f
    if [ "$(systui_ioskit_image_count)" = 0 ]; then
        tui_msg "Verify image" "No images to verify."
        return 0
    fi
    name=$(systui_ioskit_choose_image) || return 0
    [ -n "$name" ] || return 0
    path="$IOSKIT_IMAGES_DIR/$name"
    f=$(mktemp 2>/dev/null || printf '%s' "${SYSTUI_TMP:-/tmp}/ioskit-verify.$$")
    {
        printf 'Image : %s\n' "$path"
        printf 'Size  : %s\n\n' "$(systui_ioskit_image_size "$path")"
        printf 'Expected layout entries:\n'
        for d in bin usr etc lib; do
            if [ -d "$path/$d" ]; then printf '  %-4s present\n' "$d"; else printf '  %-4s absent\n' "$d"; fi
        done
        printf '\nKernel device nodes:\n'
        if [ -d "$path/dev" ]; then
            printf '  /dev present\n'
            for d in null zero tty; do
                if [ -e "$path/dev/$d" ]; then printf '  /dev/%-5s present\n' "$d"; else printf '  /dev/%-5s absent\n' "$d"; fi
            done
        else
            printf '  /dev absent — the guest may fail to boot\n'
        fi
        printf '\nA fakefs image is a directory tree, not a disk image. It is\n'
        printf 'usable when /bin and /etc are present and the runtime can open it.\n'
    } > "$f"
    tui_text "Verify image" "$f"
    rm -f "$f"
}

###############################################################################
# HOST INTEGRATION — bind mounts, native offload, route netlink
###############################################################################

# Bind mounts are a host-boundary feature: they expose a real host directory
# inside the guest, so the manager validates both sides and never invents a
# source path.
systui_ioskit_bind_spec_ok() { # <guest>=<host>[:ro|:rw]
    local spec="$1" guest host mode
    case "$spec" in
        *=*) ;;
        *) return 1 ;;
    esac
    guest=${spec%%=*}
    host=${spec#*=}
    mode=${host##*:}
    case "$mode" in ro|rw) host=${host%:*} ;; esac
    case "$guest" in /*) ;; *) return 1 ;; esac
    case "$host" in /*) ;; *) return 1 ;;
    esac
    return 0
}

systui_ioskit_bind_mounts_state() { # <list>
    local spec guest host mode problems=0
    printf 'Bind mount request\n'
    printf '==================\n\n'
    printf 'Value: %s\n\n' "${1:-(empty)}"
    if [ -z "${1:-}" ]; then
        printf 'An empty value passes no bind mounts to the guest.\n'
        return 0
    fi
    printf '%-24s %-30s %-6s %s\n' GUEST HOST MODE STATE
    printf '%-24s %-30s %-6s %s\n' ----- ---- ---- -----
    local IFS=','
    for spec in $1; do
        [ -n "$spec" ] || continue
        guest=${spec%%=*}
        host=${spec#*=}
        mode=rw
        case "${host##*:}" in
            ro) mode=ro; host=${host%:*} ;;
            rw) mode=rw; host=${host%:*} ;;
        esac
        local state
        if ! systui_ioskit_bind_spec_ok "$spec"; then
            state='invalid — guest and host paths must both be absolute'
            problems=$((problems + 1))
        elif [ ! -d "$host" ]; then
            state="invalid — host path does not exist"
            problems=$((problems + 1))
        else
            state=ok
        fi
        printf '%-24s %-30s %-6s %s\n' "$guest" "$host" "$mode" "$state"
    done
    unset IFS
    printf '\nBoth paths must be absolute. The suffix defaults to read-write;\n'
    printf 'use :ro to mount the host directory read-only.\n'
    printf '\nA bind mount bypasses the ordinary fakefs storage boundaries for the\n'
    printf 'selected host directory. It stays inside the outer iOS sandbox, but it\n'
    printf 'is a trust boundary: never point it at a directory you would not hand\n'
    printf 'to the guest directly.\n'
    if [ "$problems" -gt 0 ]; then
        printf '\n%s entry(ies) would be refused before the guest starts.\n' "$problems"
    fi
    return 0
}

systui_ioskit_bind_mount_prompt() {
    local v
    v=$(tui_input "Bind mounts" "ISH_BIND_MOUNTS value (comma separated guest=host[:ro|:rw]):" "${IOSKIT_BIND_MOUNTS:-}") || return 0
    if [ -z "$v" ]; then
        systui_ioskit_conf_set IOSKIT_BIND_MOUNTS '' >/dev/null 2>&1 || true
        IOSKIT_BIND_MOUNTS=''
        return 0
    fi
    if ! systui_ioskit_bind_mounts_state "$v" >/dev/null 2>&1; then
        tui_msg "Bind mounts" "Could not parse that value."
        return 1
    fi
    systui_ioskit_show_text "Bind mounts" systui_ioskit_bind_mounts_state "$v"
    tui_yesno "Bind mounts" "Save this value for the Run section?" || return 0
    systui_ioskit_conf_set IOSKIT_BIND_MOUNTS "$v" || tui_msg "Bind mounts" "Could not write the settings file."
    IOSKIT_BIND_MOUNTS="$v"
}

systui_ioskit_offload_text() {
    printf 'Native offload\n'
    printf '==============\n\n'
    printf 'Native offload substitutes a registered host handler or executable for\n'
    printf 'selected guest commands. It runs with the host process privileges and\n'
    printf 'adds no sandbox of its own.\n\n'
    printf 'What the supplied schemes actually register\n'
    printf '  iSH-ARM64          no production cooperative handler\n'
    printf '  iSH-ARM64-ffmpeg   the legacy fake FFmpeg *test* handler only\n\n'
    printf 'Registration rules worth respecting\n'
    printf '  * Registration must finish at startup, before the first guest thread\n'
    printf '    launches or runs; the registry stays frozen afterwards.\n'
    printf '  * A cooperative handler runs on the calling guest task: sibling or\n'
    printf '    exiting guest groups are refused with EBUSY, and its context must\n'
    printf '    not escape to workers.\n'
    printf '  * Only connected INET/INET6 TCP stdio is admitted. TTYs, files, pipes\n'
    printf '    and Unix or datagram sockets are refused before exec commits.\n'
    printf '  * Stream calls request at most 4096 bytes, with a 1 MiB input budget\n'
    printf '    and a shared 1 MiB stdout/stderr budget; a stream call may retry for\n'
    printf '    at most 250 ms.\n\n'
    printf 'Disabling generic selection\n'
    printf '  The generic ffmpeg/ffprobe offloads match exact /bin, /usr/bin or\n'
    printf '  /usr/local/bin paths; relative and private paths already fall through\n'
    printf '  to guest execution. In the guest environment set either:\n\n'
    printf '    NO_OFFLOAD=1\n'
    printf '    MINIS_NO_FFMPEG_OFFLOAD=1\n\n'
    printf '  Synthetic command names keep their own policy and are unaffected.\n\n'
    printf 'Linux host builds\n'
    printf '  Ordinary Linux builds reject native offload. The focused fixtures\n'
    printf '  compile the actual portable dispatcher against test-only adapters:\n\n'
    printf '    make test-arm64-offload-setup\n'
    printf '    make test-arm64-native-fs\n'
    printf '    make test-arm64-offload-context\n'
    printf '    make test-arm64-offload-io\n'
    printf '    make test-arm64-offload-local-copy\n\n'
    printf '  Passing them validates the contracts on Linux. It does not validate\n'
    printf '  Darwin process discovery, Apple terminal behaviour or any app scheme.\n'
}

systui_ioskit_netlink_text() {
    printf 'Route netlink (opt-in)\n'
    printf '======================\n\n'
    printf 'With ISH_NETLINK_STUB=1 the command-line runtime answers RTM_GETLINK and\n'
    printf 'RTM_GETADDR dumps from read-only host interface snapshots. The switch is\n'
    printf 'off by default.\n\n'
    printf 'What is reported\n'
    printf '  interface indices, names, flags, MTUs, hardware addresses where\n'
    printf '  available, IPv4/IPv6 addresses and prefix lengths, using Linux message\n'
    printf '  layouts and kernel sender addresses with per-socket port IDs.\n\n'
    printf 'What is bounded or absent\n'
    printf '  * requests and complete replies are bounded at 4096 bytes; an oversized\n'
    printf '    request returns EMSGSIZE and a snapshot that will not fit becomes\n'
    printf '    NLMSG_ERROR(-ENOBUFS) instead of a partial successful dump;\n'
    printf '  * batched requests and individual interface queries are unsupported;\n'
    printf '  * routes stay empty and no multicast notifications are generated;\n'
    printf '  * host routes, addresses and interfaces cannot be changed through this\n'
    printf '    path, and the reported interfaces are not an isolated guest network\n'
    printf '    namespace.\n\n'
    printf 'Guest SO_BINDTODEVICE is supported when the switch is on, so an official\n'
    printf 'ARM64 tailscaled can run with userspace networking. Never use the host\n'
    printf 'daemon or a running app filesystem as the guest root; build a disposable\n'
    printf 'Alpine fakefs and import the tailscale binaries with fakefsify, because\n'
    printf 'copying files into fakefs data/ does not create the metadata records.\n\n'
    printf 'Typical guest start:\n\n'
    printf '  ISH_NETLINK_STUB=1 %s -f %s/<image> /bin/sh\n\n' "${IOSKIT_SRC_DIR:-.}/build-arm64-linux/ish" "${IOSKIT_IMAGES_DIR:-<images>}"
    printf 'Then, inside the guest:\n\n'
    printf '  tailscaled --tun=userspace-networking --state=mem: \\\\\n'
    printf '    --socket=/tmp/ish-netlink-test.sock --port=0 \\\\\n'
    printf '    --socks5-server=127.0.0.1:0 >/tmp/ish-netlink-test.log 2>&1 &\n'
    printf '  sleep 8\n'
    printf '  tailscale --socket=/tmp/ish-netlink-test.sock status\n\n'
    printf 'An authentication URL in the log is not proof of account login or tunnel\n'
    printf 'traffic; without a browser authorisation the node times out by design.\n'
}

systui_ioskit_host_text() {
    printf 'Host integration\n'
    printf '================\n\n'
    printf 'Bind mounts (ISH_BIND_MOUNTS)\n'
    printf '  %s\n\n' "${IOSKIT_BIND_MOUNTS:-<none set>}"
    printf 'Native offload\n'
    printf '  ISH_BIND_MOUNTS and native offload both widen the guest''s access to the\n'
    printf '  host. Read the offload page (Host integration -> Native offload) before\n'
    printf '  enabling either, and keep both away from untrusted guest code.\n\n'
    printf 'Route netlink\n'
    printf '  ISH_NETLINK_STUB=1 is off by default. See Host integration -> Route\n'
    printf '  netlink for what it reports and what it deliberately does not.\n'
}

systui_ioskit_host_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Host integration" \
            "Guest access to host paths, offload handlers and interface discovery." \
            overview "Overview" \
            binds    "Bind mounts (ISH_BIND_MOUNTS)" \
            check    "Check a bind mount value" \
            offload  "Native offload — contracts and opt-outs" \
            netlink  "Route netlink and Tailscale — opt-in" \
            back     "Back" || return $?
        case "$c" in
            overview) systui_ioskit_show_text "Host integration" systui_ioskit_host_text ;;
            binds)    systui_ioskit_bind_mount_prompt ;;
            check)
                systui_ioskit_bind_mounts_state "${IOSKIT_BIND_MOUNTS:-}" >/dev/null 2>&1 || true
                systui_ioskit_show_text "Bind mounts" systui_ioskit_bind_mounts_state "${IOSKIT_BIND_MOUNTS:-}"
                ;;
            offload)  systui_ioskit_show_text "Native offload" systui_ioskit_offload_text ;;
            netlink)  systui_ioskit_show_text "Route netlink" systui_ioskit_netlink_text ;;
            back|'')  return 0 ;;
        esac
    done
}

###############################################################################
# DIAGNOSTICS
###############################################################################

# Every variable in the table is documented by upstream as "disabled unless
# named". Turning one on in an exact-output run changes the output, so the page
# says that rather than presenting them as harmless flags.
systui_ioskit_diag_vars_text() {
    printf 'Runtime diagnostics\n'
    printf '===================\n\n'
    printf 'These are off unless named below or enabled by a debug build. Do not use\n'
    printf 'trace or statistics settings in exact-output test runs: they add output\n'
    printf 'and perturb timing.\n\n'
    printf '%-42s %s\n' VARIABLE EFFECT
    printf '%-42s %s\n' -------- ------
    printf '%-42s %s\n' 'ISH_TRACE_FAULTS=1' 'guest fault and translated-block diagnostics'
    printf '%-42s %s\n' 'ISH_TRACE_HIGHBITS=1' 'high-bit register traces from fault work'
    printf '%-42s %s\n' 'ISH_TRACE_PCS=...' 'trace selected guest program counters'
    printf '%-42s %s\n' 'ISH_TRACE_GATE_PC' 'bound a trace around a PC condition'
    printf '%-42s %s\n' 'ISH_TRACE_GATE_X4' 'bound a trace around a register condition'
    printf '%-42s %s\n' 'ISH_TRACE_GATE_BUDGET' 'budget for the gated trace'
    printf '%-42s %s\n' 'ISH_ARM64_BLOCK_STATS=1' 'block-cache, chaining and prechain counters at exit'
    printf '%-42s %s\n' 'ISH_ARM64_FUSION_STATS=1' 'instruction-fusion counters'
    printf '%-42s %s\n' 'ISH_ARM64_EAGER_PRECHAIN=0' 'disable outgoing eager prechain'
    printf '%-42s %s\n' 'ISH_ARM64_EAGER_PRECHAIN_INCOMING=0' 'disable guarded incoming prechain'
    printf '%-42s %s\n' 'ISH_ARM64_INTERNAL_CONTINUE=1' 'experimental internal-continue path'
    printf '%-42s %s\n' 'ISH_ARM64_INTERNAL_CONTINUE_TAKEN=1' 'the associated taken-path mode'
    printf '\nGuest environment defaults the runtime sets deliberately:\n\n'
    printf '  GODEBUG=asyncpreemptoff=1     no Go asynchronous preemption\n'
    printf '  GOMAXPROCS=2                  limited Go scheduler parallelism\n'
    printf '  JSC_numberOfGCMarkers=1       serialised JavaScriptCore GC\n'
    printf '  JSC_useConcurrentGC=0         serialised JavaScriptCore GC\n\n'
    printf 'Overriding them can reintroduce the signal and GC failures they avoid.\n'
    printf 'Node starts with the V8 JIT disabled and a 512 MiB old-space limit.\n'
    printf 'Native/AOT builds also expose read-only /proc/ish/jit-layout; the\n'
    printf 'endpoint is absent from gadget builds.\n'
}

systui_ioskit_limits_text() {
    printf 'Known limits\n'
    printf '============\n\n'
    printf 'Security boundary\n'
    printf '  The runtime assumes one user inside an outer iOS sandbox. Guest\n'
    printf '  permissions and memory safety do not confine hostile code, and a guest\n'
    printf '  can exercise any host integration the app exposes. Do not use it to\n'
    printf '  contain untrusted workloads.\n\n'
    printf 'Guest architecture\n'
    printf '  AArch64 only; the Linux command-line build also needs an AArch64 host\n'
    printf '  because the gadgets run directly on the host CPU. Unsupported or\n'
    printf '  unrecognised encodings raise the guest undefined-instruction path.\n\n'
    printf 'Absent or incomplete Linux facilities\n'
    printf '  kernel modules and direct kernel control; Linux namespaces, cgroups and\n'
    printf '  the mount behaviour Docker needs; GPU and arbitrary USB passthrough; a\n'
    printf '  general seccomp/BPF/perf/fanotify implementation; complete AIO and\n'
    printf '  io_uring semantics; every modern syscall, socket option, procfs field\n'
    printf '  and filesystem edge case; X11 or Wayland in the supplied app.\n'
    printf '  Optional probes may receive ENOSYS and fall back, so a program can\n'
    printf '  continue without the facility.\n\n'
    printf 'Memory and code protection\n'
    printf '  In ordinary builds, an unmapped read fault may be served with readable\n'
    printf '  zeros when a mapped neighbour exists within 16 pages (64 KiB). A\n'
    printf '  single-page unmap can therefore fail to deliver the SIGSEGV native\n'
    printf '  Linux would deliver. Guest page permissions are not a security control\n'
    printf '  against the host process.\n\n'
    printf 'Host differences\n'
    printf '  A Linux-host pass does not establish iOS behaviour for app lifecycle\n'
    printf '  and suspension, memory pressure and jetsam, entitlements and sandbox\n'
    printf '  paths, signing/installation/App Store processing, or device terminal\n'
    printf '  input and rendering.\n\n'
    printf 'Rootfs and package state\n'
    printf '  Most language and CLI results depend on the packaged distribution and\n'
    printf '  installed versions. Test scripts can install or update packages in\n'
    printf '  place, so keep an untouched copy where reproducibility matters.\n\n'
    printf 'AOT\n'
    printf '  Images require compatible emulator layouts and matching guest modules;\n'
    printf '  package changes can reduce image use and old ABI images are rejected.\n'
    printf '  Image tables and native text increase binary size and memory use.\n'
    printf '  Apple reuse needs target ABI and symbol checks, app recovery and build\n'
    printf '  integration, and physical-device validation.\n'
}


systui_ioskit_compat_text() {
    printf 'Runtime compatibility settings\n'
    printf '==============================\n\n'
    printf 'The guest environment supplies conservative defaults so that a program\n'
    printf 'continues instead of hitting a known signal or GC failure:\n\n'
    printf '  GOFLAGS not set\n'
    printf '  GODEBUG=asyncpreemptoff=1\n'
    printf '  GOMAXPROCS=2\n'
    printf '  JSC_numberOfGCMarkers=1\n'
    printf '  JSC_useConcurrentGC=0\n\n'
    printf 'Consequences\n'
    printf '  * Go programs run without asynchronous preemption and with limited\n'
    printf '    scheduler parallelism, so they execute with less concurrency than on\n'
    printf '    native Linux.\n'
    printf '  * JavaScriptCore garbage collection is serialised.\n'
    printf '  * Node starts with the V8 JIT disabled, a 512 MiB old-space limit and\n'
    printf '    the exposed WebAssembly path initially disabled. Later execve\n'
    printf '    launches can load rootfs polyfills for selected packages.\n\n'
    printf 'Overriding these variables is possible and can reintroduce the failures\n'
    printf 'they exist to avoid. This is not native V8 JIT or general native\n'
    printf 'WebAssembly behaviour.\n\n'
    printf 'Environment overrides the runtime itself reads\n\n'
    printf '  %-28s %s\n' VARIABLE EFFECT
    printf '  %-28s %s\n' -------- ------
    printf '  %-28s %s\n' 'NO_OFFLOAD=1' 'disable generic ffmpeg/ffprobe offload selection'
    printf '  %-28s %s\n' 'MINIS_NO_FFMPEG_OFFLOAD=1' 'upstream-compatible spelling of the above'
    printf '  %-28s %s\n' 'ISH_BIND_MOUNTS=...' 'comma-separated guest=host[:ro|:rw] mounts'
    printf '  %-28s %s\n' 'ISH_NETLINK_STUB=1' 'opt-in read-only interface discovery'
    printf '  %-28s %s\n' 'ISH_ARM64_INTERNAL_CONTINUE=1' 'experimental executor path'
}

systui_ioskit_run_menu() {
    local c binds netlink
    while true; do
        binds='off'
        [ -n "${IOSKIT_BIND_MOUNTS:-}" ] && binds='on'
        netlink='off'
        [ "${IOSKIT_NETLINK:-0}" = 1 ] && netlink='on'
        tui_capture_menu c tui_menu_no_tags "Run the guest" \
            "Runtime: $(systui_ioskit_ish_bin || printf 'not built')\nDefault image: ${IOSKIT_DEFAULT_IMAGE:-none}\nBind mounts: $binds   Netlink stub: $netlink" \
            shell   "Open a guest shell (/bin/sh)" \
            command "Run one guest command" \
            host    "Run against the host filesystem (-r /)" \
            session "Session options — runtime, bind mounts, netlink" \
            engines "Show the exact commands (no execution)" \
            back    "Back" || return $?
        case "$c" in
            shell)   systui_ioskit_run_shell ;;
            command) systui_ioskit_run_command ;;
            host)    systui_ioskit_run_host ;;
            session) systui_ioskit_session_menu ;;
            engines) systui_ioskit_show_commands ;;
            back|'') return 0 ;;
        esac
    done
}

# The two session toggles were peer entries beside "open a shell", which made
# the run menu read as a settings screen. They only matter when a guest is
# started, so they live together, one level down.
systui_ioskit_session_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Session options" \
            "Runtime: ${IOSKIT_RUNTIME:-release}   Bind mounts: $([ -n "${IOSKIT_BIND_MOUNTS:-}" ] && printf on || printf off)   Netlink: $([ "${IOSKIT_NETLINK:-0}" = 1 ] && printf on || printf off)" \
            runtime "Runtime build: ${IOSKIT_RUNTIME:-release}" \
            binds   "Bind mounts (${IOSKIT_BIND_MOUNTS:-none})" \
            netlink "Netlink stub: $([ "${IOSKIT_NETLINK:-0}" = 1 ] && printf on || printf off)" \
            back    "Back" || return $?
        case "$c" in
            runtime) systui_ioskit_pick_runtime ;;
            binds)   systui_ioskit_session_binds ;;
            netlink) systui_ioskit_toggle_netlink ;;
            back|'') return 0 ;;
        esac
    done
}

# The runtime cannot be executed from the iOS sandbox: a sideloaded app cannot
# spawn processes. Say so rather than offering a button that fails.
systui_ioskit_run_guard() {
    local bin
    case "${IOSKIT_RUNTIME:-release}" in
        debug)   bin=$(systui_ioskit_debug_bin) || {
                     tui_msg "Run" "No debug runtime has been built.\n\nBuild → Build debug creates build-arm64-linux-debug/ish."
                     return 1
                 } ;;
        release) bin=$(systui_ioskit_ish_bin) || {
                     tui_msg "Run" "No ish binary has been built yet.\n\nBuild the project first (Build → Build release)."
                     return 1
                 } ;;
        *)       bin=$(systui_ioskit_ish_bin) || return 1 ;;
    esac
    printf '%s\n' "$bin"
    return 0
}

systui_ioskit_pick_runtime() {
    local c
    c=$(tui_menu_no_tags "Runtime" "Which build should Run use?\n\nUpstream asks for the debug build when a change touches memory, signals, concurrency or translated execution." \
        release "Release  ($(systui_ioskit_ish_bin || printf 'not built'))" \
        debug   "Debug    ($(systui_ioskit_debug_bin || printf 'not built'))") || return 0
    [ -n "$c" ] || return 0
    IOSKIT_RUNTIME="$c"
    systui_ioskit_conf_set IOSKIT_RUNTIME "$c" >/dev/null 2>&1 || true
}

systui_ioskit_toggle_netlink() {
    local new=1
    [ "${IOSKIT_NETLINK:-0}" = 1 ] && new=0
    if [ "$new" = 1 ]; then
        tui_yesno "Route netlink" "Start guests with ISH_NETLINK_STUB=1?\n\nThis enables read-only host interface discovery for the command-line runtime. Routes stay empty and no change events arrive.\n\nIt also enables guest SO_BINDTODEVICE, which the runtime does not silently ignore." || return 0
    fi
    IOSKIT_NETLINK="$new"
    systui_ioskit_conf_set IOSKIT_NETLINK "$new" >/dev/null 2>&1 || true
    tui_msg "Route netlink" "ISH_NETLINK_STUB is now $([ "$new" = 1 ] && printf on || printf off) for Run actions."
}

systui_ioskit_session_binds() {
    local v
    v=$(tui_input "Bind mounts" "ISH_BIND_MOUNTS for this session (empty clears):" "${IOSKIT_BIND_MOUNTS:-}") || return 0
    if [ -n "$v" ] && ! systui_ioskit_bind_spec_ok "${v%%,*}"; then
        tui_msg "Bind mounts" "The first entry is not guest=host[:ro|:rw]:\n${v%%,*}"
        return 1
    fi
    IOSKIT_BIND_MOUNTS="$v"
    systui_ioskit_conf_set IOSKIT_BIND_MOUNTS "$v" >/dev/null 2>&1 || true
    systui_ioskit_show_text "Bind mounts" systui_ioskit_bind_mounts_state "$v"
}

systui_ioskit_pick_rootfs() { # [allow-host] -> "f <path>" or "r <path>"
    local name
    name=$(systui_ioskit_choose_image "${1:-}") || {
        tui_msg "Run" "No guest root filesystem is available.\n\nImport one under \"Guest root filesystems\", or use Run → host filesystem."
        return 1
    }
    [ -n "$name" ] || return 1
    if [ "$name" = __host__ ]; then
        printf 'r /\n'
    else
        printf 'f %s\n' "$IOSKIT_IMAGES_DIR/$name"
    fi
}

# Export the session settings that change guest behaviour, then hand the command
# to run_cmd. Keeping this in one place means the diagnostics and netlink
# switches cannot be applied to one entry point and forgotten in another.
systui_ioskit_guest_run() { # <description> <bin> <args...>
    local desc="$1" bin="$2"
    shift 2
    local -a envcmd=()
    if [ -n "${IOSKIT_BIND_MOUNTS:-}" ]; then
        envcmd+=(env "ISH_BIND_MOUNTS=$IOSKIT_BIND_MOUNTS")
    fi
    if [ "${IOSKIT_NETLINK:-0}" = 1 ]; then
        envcmd+=(env "ISH_NETLINK_STUB=1")
    fi
    if [ "${#envcmd[@]}" -gt 0 ]; then
        run_cmd "$desc" "${envcmd[@]}" "$bin" "$@"
    else
        run_cmd "$desc" "$bin" "$@"
    fi
}

systui_ioskit_run_shell() {
    local bin root kind path
    bin=$(systui_ioskit_run_guard) || return 1
    root=$(systui_ioskit_pick_rootfs allow-host) || return 0
    kind=${root%% *}
    path=${root#* }
    systui_ioskit_guest_run "Guest shell ($path)" "$bin" "-$kind" "$path" /bin/sh
}

systui_ioskit_run_command() {
    local bin root kind path cmd
    bin=$(systui_ioskit_run_guard) || return 1
    root=$(systui_ioskit_pick_rootfs allow-host) || return 0
    kind=${root%% *}
    path=${root#* }
    cmd=$(tui_input "Run guest command" "Command to run in the guest:" "/bin/uname -a") || return 0
    [ -n "$cmd" ] || return 0
    # shellcheck disable=SC2086
    systui_ioskit_guest_run "Guest command: $cmd" "$bin" "-$kind" "$path" /bin/sh -c "$cmd"
}

systui_ioskit_run_host() {
    local bin cmd
    bin=$(systui_ioskit_run_guard) || return 1
    tui_yesno "Host filesystem" "Run the guest runtime against the host filesystem?\n\nThe guest sees and can modify real host paths. Prefer a restricted directory for ordinary tests: this runtime is not a security boundary for hostile guest code, even with a restricted realfs root.\n\nA harmless-looking warning is expected from the launcher here — it tries to enforce guest /dev/shm permissions on the host mount and reports 'Operation not permitted' when it cannot. The command still exits with the guest program's status." || return 0
    cmd=$(tui_input "Run against host" "Command (or empty for a shell):" "/bin/uname -a") || return 0
    if [ -z "$cmd" ]; then
        systui_ioskit_guest_run "Guest shell on host filesystem" "$bin" -r / /bin/sh
    else
        # shellcheck disable=SC2086
        systui_ioskit_guest_run "Guest command on host filesystem: $cmd" "$bin" -r / /bin/sh -c "$cmd"
    fi
}

systui_ioskit_show_commands() {
    systui_ioskit_show_text "Commands" systui_ioskit_commands_text
}

systui_ioskit_commands_text() {
    local bin fakefsify unfakefsify
    bin=$(systui_ioskit_ish_bin || printf '%s' "$IOSKIT_SRC_DIR/build-arm64-linux/ish")
    fakefsify=$(systui_ioskit_fakefsify_bin || printf '%s' "$IOSKIT_SRC_DIR/build-arm64-linux/tools/fakefsify")
    unfakefsify=$(systui_ioskit_unfakefsify_bin || printf '%s' "$IOSKIT_SRC_DIR/build-arm64-linux/tools/unfakefsify")
    printf 'Exact commands the manager would run\n'
    printf '====================================\n\n'
    printf 'Check out the source\n'
    printf '  git clone --recurse-submodules --branch %s \\\n' "$IOSKIT_BRANCH"
    printf '    %s %s\n' "$IOSKIT_REPO_URL" "$IOSKIT_SRC_DIR"
    printf '  git -C %s submodule update --init --recursive\n\n' "$IOSKIT_SRC_DIR"
    printf 'Build (AArch64 Linux host; Clang uses its integrated assembler)\n'
    printf '  CC=clang make -C %s build-arm64-linux\n' "$IOSKIT_SRC_DIR"
    printf '  CC=clang make -C %s build-arm64-linux-debug\n' "$IOSKIT_SRC_DIR"
    printf '  # first-time equivalent:\n'
    printf '  CC=clang meson setup %s/build-arm64-linux -Dguest_arch=arm64 --buildtype=release\n' "$IOSKIT_SRC_DIR"
    printf '  ninja -C %s/build-arm64-linux\n\n' "$IOSKIT_SRC_DIR"
    printf 'Import a root filesystem tarball\n'
    printf '  %s <tarball> %s/<name>\n\n' "$fakefsify" "$IOSKIT_IMAGES_DIR"
    printf 'Export an image back to a portable tarball (stop every guest first)\n'
    printf '  %s %s/<name> <rootfs-export.tar.gz>\n\n' "$unfakefsify" "$IOSKIT_IMAGES_DIR"
    printf 'Raw snapshot (portable export is usually better)\n'
    printf '  rsync -a --include '\''data/***'\'' --include '\''meta.db*'\'' --exclude '\''*'\'' \\\n'
    printf '    %s/<name>/ <destination>/\n\n' "$IOSKIT_IMAGES_DIR"
    printf 'Run a guest shell in a fakefs image\n'
    printf '  %s -f %s/<name> /bin/sh\n\n' "$bin" "$IOSKIT_IMAGES_DIR"
    printf 'Run against the host filesystem\n'
    printf '  %s -r / /bin/sh\n\n' "$bin"
    printf 'Bind host paths into the guest\n'
    printf '  ISH_BIND_MOUNTS='\''/mnt/src=/home/me/src:ro,/mnt/out=/tmp/out:rw'\'' \\\n'
    printf '    %s -f %s/<name> /bin/sh\n\n' "$bin" "$IOSKIT_IMAGES_DIR"
    printf 'Opt-in interface discovery\n'
    printf '  ISH_NETLINK_STUB=1 %s -f %s/<name> /bin/sh\n\n' "$bin" "$IOSKIT_IMAGES_DIR"
    printf 'Disable generic ffmpeg/ffprobe offload selection (inside the guest)\n'
    printf '  NO_OFFLOAD=1   (or MINIS_NO_FFMPEG_OFFLOAD=1)\n\n'
    printf 'Runtime options: -r <real root> -f <fakefs root> -d <workdir>\n'
    printf '                 -c <console> -n <offload>   (Darwin hosts only for -n)\n'
}

###############################################################################
# VALIDATION GATES
###############################################################################

# The focused targets a change actually needs, with the side effects each one
# carries. A gate listed as "needs a prepared Debian fakefs" cannot be run from
# here if that tree does not exist, and saying so is the point.
systui_ioskit_gates_rows() { # <requirement-id> <label> <target|-> <note>
    while IFS='|' read -r id label target note; do
        [ -n "$id" ] || continue
        printf '%s|%s|%s|%s\n' "$id" "$label" "$target" "$note"
    done <<'ROWS'
build|Release and debug build|build-arm64-linux-all|the build gate; treat new compiler, assembler and linker warnings as failures
fcvt|AdvSIMD FP conversions|test-arm64-fcvt-vector|needs the Debian fakefs; uses the host CPU as the floating-point oracle
saturation|Scalar saturation|test-arm64-scalar-saturation|19,696 native/guest add-subtract cases with FPSR.QC and NZCV
loadpc|Precise load fault PC|test-arm64-load64-fault-pc|needs the Debian fakefs; native oracle plus 18 guest cases
procmem|proc mem seeks|test-arm64-proc-mem-seek|needs the Debian fakefs
lseek|Full-width seeks|test-arm64-lseek-width|needs the Debian fakefs with Python
poke|CPU poke delivery|test-arm64-poke-stress|needs the Debian fakefs
poll|Regular-file readiness|test-arm64-poll-regular|needs a prepared fakefs via ROOTFS_DIR
upstream|Upstream correctness and lifetime|test-arm64-upstream|the broad correctness and lifetime gate
procexit|Procfs and exit stress|test-arm64-proc-exit-race|two 25 s guest runs with 16 forkers
offloadsetup|Native offload setup|test-arm64-offload-setup|offload contracts; Linux adapters only
nativefs|Offload filesystem context|test-arm64-native-fs|owns CWD, mount and metadata semantics
offloadctx|Cooperative context execution|test-arm64-offload-context|raw argv and retained guest VFS
offloadio|Bounded streams and tokens|test-arm64-offload-io|39 TCP modes plus 1,000 signal/completion races
localcopy|Cooperative local copy|test-arm64-offload-local-copy|test-only handler on realfs and fakefs
runtime|Release runtime coverage|test-arm64-runtime-coverage|shell, packages, C fixtures and language runtimes
runtimedbg|Debug runtime coverage|test-arm64-runtime-coverage-debug|memory, signal, concurrency and translated-execution changes
cli|CLI corner cases|test-arm64-cli-corner-smoke|TUI, DNS, HTTPS, Git and container probes
perf|Pinned performance|perf-bench|repeated pinned workloads with percentiles; needs Bun
gadgetguard|Xcode gadget guard|test-xcode-gadget-guard|asserts the app bridge keeps gadget-only settings
aotkit|AOT generator and kit|test-aot-generator|tool validation for recording and artifact kits
rootfsdl|Rootfs downloader|test-rootfs-download|accepts a good archive and rejects bad fetch, hash and architecture
docslinks|Documentation links|check-docs|needs Bun
docsstyle|Documentation style|check-docs-style|needs Bun
ROWS
}

systui_ioskit_gates_text() {
    local id label target note bin debug
    bin=$(systui_ioskit_ish_bin || printf 'not built')
    debug=$(systui_ioskit_debug_bin || printf 'not built')
    printf 'Validation gates\n'
    printf '================\n\n'
    printf 'Binaries\n'
    printf '  release : %s\n' "$bin"
    printf '  debug   : %s\n\n' "$debug"
    printf 'Root filesystems available to gates\n'
    if [ "$(systui_ioskit_image_count)" = 0 ]; then
        printf '  none imported yet\n'
    else
        systui_ioskit_image_list | while IFS= read -r id; do
            [ -n "$id" ] && printf '  %s\n' "$id"
        done
    fi
    printf '\nGates\n'
    printf '  %-12s %-36s %s\n' ID TARGET NOTE
    printf '  %-12s %-36s %s\n' -- ------ ----
    while IFS='|' read -r id label target note; do
        [ -n "$id" ] || continue
        printf '  %-12s %-36s %s\n' "$id" "$target" "$note"
    done <<EOF
$(systui_ioskit_gates_rows)
EOF
    printf '\nRunning a gate here\n'
    printf '  * Every gate runs with the gate list you choose in "Run validation\n'
    printf '    gates"; the report goes to the terminal and to %s.\n' "${LOGFILE:-the systui log}"
    printf '  * Gates that need a prepared Debian fakefs will build one through\n'
    printf '    sudo debootstrap if it is missing; that downloads packages and\n'
    printf '    deletes its temporary output directories.\n'
    printf '  * Unsupported facilities must be reported as unsupported with a\n'
    printf '    reason. A missing package is not an emulator failure, and a\n'
    printf '    package-manager failure is recorded separately from a test result.\n'
    printf '  * Keep %s out of exact-output runs: statistics and\n' 'ISH_ARM64_BLOCK_STATS=1'
    printf '    tracing add output and perturb timing.\n'
}

# A gate list is defined by which upstream .PHONY targets exist. Reading them
# from the checkout keeps this page honest when upstream adds or renames one.
systui_ioskit_gate_available() { # <make-target>
    local mf="$IOSKIT_SRC_DIR/Makefile"
    [ -r "$mf" ] || return 1
    rg -q "^${1}:" "$mf" 2>/dev/null && return 0
    grep -q "^${1}:" "$mf" 2>/dev/null
}

systui_ioskit_run_gates() {
    local -a targets=() labels=()
    local chosen id label target note
    systui_ioskit_repo_present || {
        tui_msg "Validation" "No source checkout at\n$IOSKIT_SRC_DIR\n\nUse Source → Check out first."
        return 1
    }
    if ! systui_ioskit_have make; then
        tui_msg "Validation" "make is not installed.\n\nInstall it, or run the gates manually — the exact commands are on this page."
        return 1
    fi
    while IFS='|' read -r id label target note; do
        [ -n "$id" ] || continue
        labels+=("$id" "$label ($target)")
    done <<EOF
$(systui_ioskit_gates_rows)
EOF
    chosen=$(tui_check "Run validation gates" "SPACE selects; ENTER runs the selected gates in order.\n\nGates that need a Debian fakefs are much slower the first time." "${labels[@]}") || return 0
    [ -n "$chosen" ] || { tui_msg "Validation" "No gate was selected."; return 0; }
    for id in $chosen; do
        id=${id//\"/}
        while IFS='|' read -r gid label target note; do
            [ "$gid" = "$id" ] || continue
            [ -n "$target" ] && [ "$target" != '-' ] && targets+=("$target")
        done <<EOF
$(systui_ioskit_gates_rows)
EOF
    done
    if [ "${#targets[@]}" -eq 0 ]; then
        tui_msg "Validation" "None of the selected gates resolved to a make target."
        return 0
    fi
    tui_yesno "Validation" "Run ${#targets[@]} gate(s) in order?\n\n${targets[*]}\n\nThis may take a long time, and the Debian-dependent gates can install packages." || return 0
    for target in "${targets[@]}"; do
        if ! systui_ioskit_gate_available "$target"; then
            printf 'systui: gate %s is not defined in this checkout \u2014 skipped\n' "$target" >&2
            [ -n "${LOGFILE:-}" ] && printf 'gate %s skipped: not defined in this checkout\n' "$target" >> "$LOGFILE"
            continue
        fi
        run_cmd "Gate: $target" make -C "$IOSKIT_SRC_DIR" "$target" CC=clang || {
            tui_yesno "Validation" "Gate $target failed.\n\nStop here, or continue with the remaining gates?" || break
        }
    done
    tui_msg "Validation" "Finished. Full output is in\n${LOGFILE:-the systui log}"
}

###############################################################################
# APPLICATION BUNDLE AND RELEASES
###############################################################################

systui_ioskit_version_text() {
    local appcfg projectcfg marketing builds
    appcfg="$IOSKIT_SRC_DIR/app/AppARM64.xcconfig"
    projectcfg="$IOSKIT_SRC_DIR/iSH.xcodeproj/project.pbxproj"
    printf 'Versions and release provenance\n'
    printf '===============================\n\n'
    if [ -r "$appcfg" ]; then
        marketing=$(sed -n 's/^[[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*//p' "$appcfg" | head -n1)
        printf '  ARM64 release version : %s\n' "${marketing:-unknown}"
        printf '  source                : app/AppARM64.xcconfig (MARKETING_VERSION)\n'
    else
        printf '  ARM64 release version : no checkout\n'
    fi
    if [ -r "$projectcfg" ]; then
        builds=$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = //p' "$projectcfg" | tr -d ';' | sort -u | tr '\n' ' ')
        printf '  Apple build number(s) : %s\n' "${builds:-unknown}"
        printf '  source                : iSH.xcodeproj/project.pbxproj\n'
    fi
    printf '\nRules from the release guide\n'
    printf '  * Version: semantic. Patch for compatible fixes, minor for compatible\n'
    printf '    runtime/terminal/integration capability, major for incompatible app,\n'
    printf '    rootfs or embedding changes.\n'
    printf '  * The Apple build number increments for every uploaded build, including\n'
    printf '    rebuilds of the same version, and is never reused.\n'
    printf '  * All project build configurations must print the same build number.\n'
    printf '  * Verify the fields with:\n\n'
    printf '      grep -n '\''MARKETING_VERSION'\'' app/Project.xcconfig app/AppARM64.xcconfig\n'
    printf '      grep -n '\''CURRENT_PROJECT_VERSION = '\'' iSH.xcodeproj/project.pbxproj\n\n'
    printf '  * Then: rebuild, rerun the release validation gates, add a dated report\n'
    printf '    under docs/reports/releases/, commit version+docs+evidence together,\n'
    printf '    create an annotated tag on that commit and push it.\n'
    printf '  * A tag records source provenance only. It does not prove an archive\n'
    printf '    was signed, installed or uploaded.\n'
}

systui_ioskit_tags_text() {
    local line
    printf 'Tags\n'
    printf '====\n\n'
    if ! systui_ioskit_repo_present; then
        printf 'No checkout.\n'
        return 0
    fi
    if ! systui_ioskit_have git; then
        printf 'git is not installed.\n'
        return 0
    fi
    printf 'Recent tags (app releases use plain v<version>; arm64-openjdk21-prod-*\n'
    printf 'tags are dated Linux runtime baselines, not app versions):\n\n'
    git -C "$IOSKIT_SRC_DIR" tag --sort=-creatordate 2>/dev/null | head -n 15 | while IFS= read -r line; do
        [ -n "$line" ] && printf '  %s\n' "$line"
    done
    printf '\nCurrent checkout: %s\n' "$(systui_ioskit_version)"
    printf 'HEAD            : %s\n' "$(git -C "$IOSKIT_SRC_DIR" rev-parse --short HEAD 2>/dev/null || printf unknown)"
    printf '\nThe v2.0.0 tag points to a divergent release commit and is retained for\n'
    printf 'provenance only; it is not an ancestor of this branch.\n'
}

systui_ioskit_appcfg_text() {
    local f base url sha arch
    f="$IOSKIT_SRC_DIR/app/iSH.xcconfig"
    printf 'Application bundle configuration\n'
    printf '================================\n\n'
    if [ ! -r "$f" ]; then
        printf 'No checkout: %s is not readable.\n\n' "$f"
        printf 'Once checked out, set ROOT_BUNDLE_IDENTIFIER there to an identifier\n'
        printf 'your team owns, choose an Apple development team before signing, and\n'
        printf 'remember that the FFmpeg target appends .arm64.ffmpeg to its bundle and\n'
        printf 'app-group identifiers. This repository contains no credentials or\n'
        printf 'provisioning profiles.\n'
        return 0
    fi
    base=$(sed -n 's/^[[:space:]]*ROOT_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*//p' "$f" | head -n1)
    printf '  iSH.xcconfig ROOT_BUNDLE_IDENTIFIER : %s\n' "${base:-unknown}"
    printf '\nEffective root filesystem pin\n'
    if url=$(systui_ioskit_xcconfig_get ROOTFS_URL); then
        sha=$(systui_ioskit_xcconfig_get ROOTFS_SHA256 || printf 'unknown')
        arch=$(systui_ioskit_xcconfig_get ROOTFS_ARCH || printf 'aarch64')
        printf '  ROOTFS_URL    : %s\n' "$url"
        printf '  ROOTFS_SHA256 : %s\n' "$sha"
        printf '  ROOTFS_ARCH   : %s\n' "$arch"
        printf '\n  The app downloader fetches this URL into a temporary file, verifies\n'
        printf '  the checksum, extracts bin/busybox, runs file(1) and requires an\n'
        printf '  AArch64 executable before atomically installing root.tar.gz. A failed\n'
        printf '  fetch or check leaves an existing bundle archive unchanged.\n'
    else
        printf '  app/GuestARM64.xcconfig has no ROOTFS_URL.\n'
    fi
    printf '\nThe pin is what "Guest root filesystems → Download" checks out, so the\n'
    printf 'manager and the app always provision the same userland.\n'
}

systui_ioskit_pin_help() {
    tui_yesno "Change the app rootfs pin" "The app packaging pin lives in app/GuestARM64.xcconfig.\n\nChanging it is a source edit that needs a reviewed checksum and a test of the packaged image.\n\nShow the exact steps?" || return 0
    local f
    f=$(mktemp 2>/dev/null || printf '%s' "${SYSTUI_TMP:-/tmp}/ioskit-pin.$$")
    {
        printf 'Changing the packaged root filesystem\n'
        printf '=====================================\n\n'
        printf 'File: %s/app/GuestARM64.xcconfig\n\n' "$IOSKIT_SRC_DIR"
        printf '  1. Point ROOTFS_URL at the new archive. The value has no scheme; the\n'
        printf '     app prepends https:// at download time.\n'
        printf '  2. Compute the checksum of the reviewed archive:\n\n'
        printf '       sha256sum <archive>.tar.gz\n\n'
        printf '  3. Put that value in ROOTFS_SHA256 and keep ROOTFS_ARCH consistent\n'
        printf '     with the archive that URL actually serves.\n'
        printf '  4. Test the packaged image before publishing: the current pin does not\n'
        printf '     upgrade already-installed userlands, so existing guests keep their\n'
        printf '     old userland until they are rebuilt.\n\n'
        printf 'A changed URL with an old checksum fails the downloader and leaves the\n'
        printf 'previous bundle archive in place, which is the intended failure mode.\n'
    } > "$f"
    tui_text "Root filesystem pin" "$f"
    rm -f "$f"
}

systui_ioskit_app_text() {
    printf 'Build the iOS application\n'
    printf '=========================\n\n'
    printf 'This host cannot do it, and the reason is worth stating plainly:\n\n'
    printf '  * Xcode, the iOS SDK and a signing identity are required. The Meson\n'
    printf '    libraries are also built by an Xcode shell phase through\n'
    printf '    app/xcode-meson.sh, which needs Meson and Ninja visible to Xcode.\n'
    printf '  * The Xcode build downloads from the network while preparing the\n'
    printf '    bundled rootfs.\n'
    printf '  * Apple archive, signing and physical-device validation have to run on\n'
    printf '    Apple hardware. A Linux-host pass does not establish iOS behaviour\n'
    printf '    for app lifecycle, memory pressure, entitlements or device rendering.\n\n'
    printf 'What the manager can still do here\n'
    printf '  * The exact xcodebuild command, on the Application bundle page.\n'
    printf '  * Bundle identifiers, version fields and the root filesystem pin,\n'
    printf '    read from the checkout, so an Apple machine can be prepared first.\n'
    printf '  * The gadget-only guard gate (make test-xcode-gadget-guard), which\n'
    printf '    checks the Xcode/Meson bridge with fixture responses rather than\n'
    printf '    running Xcode.\n\n'
    printf 'Requirements on the Mac\n'
    printf '  macOS with Xcode and the command-line tools, Homebrew meson and ninja,\n'
    printf '  Python 3, curl, tar and file. Initialise submodules before opening the\n'
    printf '  project:\n\n'
    printf '    git submodule update --init --recursive\n\n'
    printf 'Schemes\n'
    printf '  iSH-ARM64          iSH ARM64.app — the main reference application\n'
    printf '  iSH-ARM64-ffmpeg   test target defining ISH_FFMPEG_TEST=1 and the\n'
    printf '                     built-in fake FFmpeg handler\n\n'
    printf 'Before distribution\n'
    printf '  Build and smoke-test the exact signed archive on a physical device:\n'
    printf '  terminal and upgrade-session creation, offload wrappers and opt-outs,\n'
    printf '  timers and interrupted sleeps, repeated fork/exec/exit with concurrent\n'
    printf '  procfs and ps scans, memory pressure, precise load faults, and\n'
    printf '  foreground/background transitions.\n\n'
    printf 'The inherited Fastlane lanes target upstream iSH identifiers and\n'
    printf 'repositories. Do not use them for this fork until their schemes, bundle\n'
    printf 'identifiers, signing repository, TestFlight groups and repository targets\n'
    printf 'have been changed and reviewed.\n'
}

# Version/bundle facts are read from the checkout; the static guide pages live
# under one entry instead of occupying four slots beside the two things a host
# can actually run here.
systui_ioskit_app_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Versions and Apple paths" \
            "Version: $(systui_ioskit_app_version)   Tags: $(systui_ioskit_tag_count)" \
            versions "Versions and release provenance" \
            bundle   "Bundle configuration and the packaging rootfs pin" \
            guides   "Guides — Xcode build, changing the pin" \
            gadget   "Run the Xcode gadget guard gate" \
            back     "Back" || return $?
        case "$c" in
            versions) systui_ioskit_show_text "Versions" systui_ioskit_version_text ;;
            bundle)   systui_ioskit_show_text "Bundle configuration" systui_ioskit_appcfg_text ;;
            guides)   systui_ioskit_app_guides_menu ;;
            gadget)   systui_ioskit_run_single_gate test-xcode-gadget-guard ;;
            back|'')  return 0 ;;
        esac
    done
}

systui_ioskit_app_guides_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Apple guides" \
            "Static procedures this host cannot run." \
            app     "Build the iOS application — requirements and steps" \
            pinhelp "How to change the packaged rootfs pin" \
            back    "Back" || return $?
        case "$c" in
            app)     systui_ioskit_show_text "iOS application" systui_ioskit_app_text ;;
            pinhelp) systui_ioskit_pin_help ;;
            back|'') return 0 ;;
        esac
    done
}

# Cheap probes so the menu header can show a fact instead of a slogan.
systui_ioskit_app_version() {
    local v
    if v=$(systui_ioskit_xcconfig_get MARKETING_VERSION 2>/dev/null); then
        printf '%s\n' "$v"
        return 0
    fi
    printf 'unknown\n'
}

systui_ioskit_tag_count() {
    local n
    systui_ioskit_repo_present || { printf 'none\n'; return 0; }
    systui_ioskit_have git || { printf 'unknown\n'; return 0; }
    n=$(git -C "$IOSKIT_SRC_DIR" tag 2>/dev/null | wc -l)
    printf '%s\n' "${n// /}"
}

systui_ioskit_run_single_gate() { # <make-target>
    systui_ioskit_repo_present || { tui_msg "Gate" "No source checkout yet."; return 1; }
    systui_ioskit_have make || { tui_msg "Gate" "make is not installed."; return 1; }
    if ! systui_ioskit_gate_available "$1"; then
        tui_msg "Gate" "$1 is not defined in this checkout's Makefile."
        return 1
    fi
    run_cmd "Gate: $1" make -C "$IOSKIT_SRC_DIR" "$1" CC=clang
}

###############################################################################
# NATIVE / AOT PIPELINE
###############################################################################

# AOT is disabled by default and the app schemes do not enable it. The manager
# describes the pipeline and can run the Bun-based tool gates, but it never
# pretends an image can be executed on iOS today.
systui_ioskit_aot_text() {
    printf 'Native / AOT backend\n'
    printf '====================\n\n'
    printf 'Status in this repository\n'
    printf '  The native/AOT backend is available through Meson and tested with\n'
    printf '  linked Linux ELF images. It is disabled by default, and the existing\n'
    printf '  Xcode schemes neither configure it nor link images: they keep the\n'
    printf '  gadget-only configuration. Apple archive/signing/device validation has\n'
    printf '  not been run for the current source release.\n\n'
    printf 'Pipeline stages\n'
    printf '  1. Build the recorder: make build-arm64-native (a Linux build with\n'
    printf '     -Djit=true), then record a workload with a Bun tool. Recordings\n'
    printf '     contain native words and baked structure offsets.\n'
    printf '  2. Freeze a reusable input set with tools/jit_aot/kit.ts prepare, and\n'
    printf '     verify it. A seed carries the raw fakefs snapshot, a portable guest\n'
    printf '     archive, the JSONL recordings, the original images and recorder,\n'
    printf '     the workload and the package and toolchain records.\n'
    printf '  3. Generate ELF (or Mach-O) assemblies and link a no-emitter image.\n'
    printf '  4. Run the linked image and compare it with the gadget build.\n\n'
    printf 'Commands from the artifact guide (absolute paths required; prepare and\n'
    printf 'build refuse a working tree with changes; outputs must be new):\n\n'
    printf '  bun tools/jit_aot/kit.ts prepare "$ROOT" "$RECORDINGS" \\\\\n'
    printf '      "$GADGET_BUILD" "$SEED" --quiescent\n'
    printf '  bun tools/jit_aot/kit.ts verify "$SEED"\n'
    printf '  make test-aot-generator test-aot-kit\n'
    printf '  make test-arm64-native-emitter\n'
    printf '  make test-arm64-linked-aot      # needs a separately linked no-emitter CLI\n\n'
    printf 'Freezing a guest\n'
    printf '  Stop every guest using the root first, and keep data/, meta.db and the\n'
    printf '  SQLite WAL/SHM files together. Guest permissions and symlink types live\n'
    printf '  in the metadata, so archiving data/ alone loses them. Use\n'
    printf '  "Guest root filesystems -> Export" for the portable form.\n\n'
    printf 'Honest limits\n'
    printf '  * A seed manifest can be edited: distribute a trusted archive checksum\n'
    printf '    separately. The kit does not sandbox helpers or validate hostile tar\n'
    printf '    files.\n'
    printf '  * Publication renames a staging directory on the same filesystem; it\n'
    printf '    protects against an incomplete run, not against a second writer.\n'
    printf '  * Package upgrades can invalidate images, old ABI images are rejected,\n'
    printf '    and untranslated code falls back to gadgets.\n'
    printf '  * The measured prototype improved shell and zlib workloads by about\n'
    printf '    12-13%% while Python took about 15%% longer and used considerably more\n'
    printf '    memory. Do not extrapolate those numbers to a device.\n'
    printf '  * Apple reuse needs target ABI and symbol checks, app recovery and build\n'
    printf '    integration and physical-device validation. Linux recordings cannot\n'
    printf '    substitute for an observed Apple contract.\n\n'
    printf 'What this manager runs\n'
    printf '  Only the tool gates above (test-aot-generator, test-aot-kit, and the\n'
    printf '  gadget guard). Recording, training and image linkage belong on the\n'
    printf '  AArch64 Linux host, and Mach-O generation belongs on an Apple Silicon\n'
    printf '  Mac.\n'
}

systui_ioskit_aot_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Native / AOT pipeline" \
            "AOT is available on master and disabled by default in every app scheme." \
            about   "Overview, pipeline stages and honest limits" \
            kit     "Run the AOT tool gates (test-aot-generator, test-aot-kit)" \
            freeze  "Freeze a guest for recording (portable export)" \
            back    "Back" || return $?
        case "$c" in
            about)  systui_ioskit_show_text "Native / AOT" systui_ioskit_aot_text ;;
            kit)
                systui_ioskit_run_single_gate test-aot-generator || continue
                systui_ioskit_run_single_gate test-aot-kit || continue
                ;;
            freeze) systui_ioskit_freeze_guest ;;
            back|'') return 0 ;;
        esac
    done
}

# Freezing for a recording is the same operation as the export the guest
# filesystem menu performs, so the checklist leads into that action instead of
# describing a procedure the user then has to find again.
systui_ioskit_freeze_guest() {
    systui_ioskit_show_text "Freeze a guest" systui_ioskit_freeze_text
    tui_yesno "Freeze a guest" "Export the selected image now?\n\nThe checklist above is your confirmation; the export asks again before writing." || return 0
    systui_ioskit_export_image
}

systui_ioskit_freeze_text() {
    printf 'Freeze a guest before recording or exporting\n'
    printf '===========================================\n\n'
    printf 'Checklist\n'
    printf '  [ ] every guest using the image is stopped\n'
    printf '  [ ] the iOS app is not booted from this image\n'
    printf '  [ ] the checkout is clean (prepare and build refuse a dirty tree)\n'
    printf '  [ ] outputs go outside the checkout, and do not already exist\n\n'
    printf 'Keep together\n'
    printf '  data/          the backing files\n'
    printf '  meta.db        the SQLite metadata\n'
    printf '  meta.db-wal    if present\n'
    printf '  meta.db-shm    if present\n\n'
    printf 'Portable export (restores guest permissions and symlinks, assigns new\n'
    printf 'host inode numbers on import):\n\n'
    printf '  Guest root filesystems -> Export an image to a portable tarball\n\n'
    printf 'Raw snapshot, if a byte-level copy is really what is wanted:\n\n'
    printf '  rsync -a --include '\''data/***'\'' --include '\''meta.db*'\'' \\\\\n'
    printf '    --exclude '\''*'\'' %s/<image>/ <destination>/\n' "$IOSKIT_IMAGES_DIR"
}

###############################################################################
# DIAGNOSTICS, ABOUT AND MAINTENANCE
###############################################################################

systui_ioskit_diagnostics_text() {
    local line
    systui_ioskit_status_text
    printf '\nRuntime probe\n'
    printf '  ish binary    : %s\n' "$(systui_ioskit_ish_bin || printf 'absent')"
    printf '  debug runtime : %s\n' "$(systui_ioskit_debug_bin || printf 'absent')"
    printf '  fakefsify     : %s\n' "$(systui_ioskit_fakefsify_bin || printf 'absent')"
    printf '  unfakefsify   : %s\n' "$(systui_ioskit_unfakefsify_bin || printf 'absent')"
    printf '  pinned rootfs : %s\n' "$(systui_ioskit_rootfs_pin)"
    printf '  pin source    : %s\n' "$(systui_ioskit_rootfs_pin_source)"
    printf '  settings file : %s (%s)\n' "$(systui_ioskit_conf_file)" \
        "$([ -r "$(systui_ioskit_conf_file)" ] && printf readable || printf absent)"
    printf '\nSubmodules (git)\n'
    if systui_ioskit_repo_present && systui_ioskit_have git; then
        git -C "$IOSKIT_SRC_DIR" submodule status 2>/dev/null | while IFS= read -r line; do
            printf '  %s\n' "$line"
        done
    else
        printf '  no checkout\n'
    fi
    printf '\nDisk usage\n'
    for line in "$IOSKIT_SRC_DIR" "$IOSKIT_IMAGES_DIR" "$IOSKIT_DOWNLOAD_DIR"; do
        if [ -d "$line" ]; then
            printf '  %-40s %s\n' "$line" "$(systui_ioskit_image_size "$line")"
        else
            printf '  %-40s absent\n' "$line"
        fi
    done
    printf '\nSettings in effect\n'
    printf '  %-22s %s\n' IOSKIT_REPO_URL "$IOSKIT_REPO_URL"
    printf '  %-22s %s\n' IOSKIT_BRANCH "$IOSKIT_BRANCH"
    printf '  %-22s %s\n' IOSKIT_SRC_DIR "$IOSKIT_SRC_DIR"
    printf '  %-22s %s\n' IOSKIT_IMAGES_DIR "$IOSKIT_IMAGES_DIR"
    printf '  %-22s %s\n' IOSKIT_DOWNLOAD_DIR "$IOSKIT_DOWNLOAD_DIR"
    printf '  %-22s %s\n' IOSKIT_DEFAULT_IMAGE "${IOSKIT_DEFAULT_IMAGE:-none}"
    printf '  %-22s %s\n' IOSKIT_AUTO_DEPS "$IOSKIT_AUTO_DEPS"
    printf '  %-22s %s\n' IOSKIT_BIND_MOUNTS "${IOSKIT_BIND_MOUNTS:-none}"
    printf '  %-22s %s\n' IOSKIT_NETLINK "${IOSKIT_NETLINK:-0}"
    printf '  %-22s %s\n' IOSKIT_RUNTIME "${IOSKIT_RUNTIME:-release}"
}

# The report is a document, not a menu action that then starts running
# binaries: the old flow offered to execute the runtime right after a page that
# exists to be read.
systui_ioskit_diagnostics() {
    systui_ioskit_show_text "iOS LinuxKit diagnostics" systui_ioskit_diagnostics_text
}

systui_ioskit_about_text() {
    printf 'iOS LinuxKit\n'
    printf '============\n\n'
    printf 'An optimised fork of iSH that runs an AArch64 Linux userland inside an\n'
    printf 'iOS app and as a command-line process on an AArch64 Linux host.\n\n'
    printf '  upstream    : https://github.com/rcarmo/ios-linuxkit\n'
    printf '  guest arch  : ARM64 only\n'
    printf '  engine      : iSH userspace kernel and Asbestos threaded-code\n'
    printf '                interpreter (native/AOT backend off by default)\n'
    printf '  version     : %s\n\n' "$(systui_ioskit_version)"
    printf 'What the pieces are\n'
    printf '  ish          the runtime binary (build-arm64-linux/ish)\n'
    printf '  fakefsify    imports a root filesystem tarball into a fakefs image\n'
    printf '  unfakefsify  exports an image back to a portable tarball (same binary,\n'
    printf '               selected by argv[0])\n'
    printf '  fakefs       the bootable guest root: a directory, not a disk image\n'
    printf '  meta.db      the SQLite metadata that holds guest permissions and\n'
    printf '               symlink types; keep the WAL/SHM siblings with it\n\n'
    printf 'Typical Linux-host flow (AArch64 host, Clang, Meson, Ninja)\n'
    printf '  1. install clang, make, meson, ninja, pkg-config, git, curl, file,\n'
    printf '     tar, libsqlite3-dev and libarchive-dev\n'
    printf '  2. CC=clang make build-arm64-linux\n'
    printf '  3. download an Alpine aarch64 minirootfs and import it with fakefsify\n'
    printf '  4. ish -f ./alpine-arm64-fakefs /bin/sh\n\n'
    printf 'Guides behind this manager\n'
    printf '  docs/LINUX_DEVELOPMENT.md    host to guest, fakefs, bind mounts, tracing\n'
    printf '  docs/IOS_APPLICATION.md      schemes, rootfs packaging, offload, device checks\n'
    printf '  docs/VALIDATION.md           gates, failure rules, dated evidence\n'
    printf '  docs/LIMITATIONS.md          security model and unsupported workloads\n'
    printf '  docs/RELEASES.md             versions, tags and release checks\n'
    printf '  docs/NATIVE_OFFLOAD.md       offload contracts and bounded streams\n'
    printf '  docs/NETLINK_TAILSCALE.md    opt-in interface discovery\n'
    printf '  docs/NATIVE_AOT_IOS.md       Apple image generation and integration\n\n'
    printf 'What this manager can and cannot do\n'
    printf '  can    : source, build, root filesystems (import and export), run with\n'
    printf '           bind mounts and the netlink switch, validation gates,\n'
    printf '           diagnostics, bundle and version inspection, AOT tool gates.\n'
    printf '  cannot : run the runtime from the iOS sandbox (a sideloaded app cannot\n'
    printf '           spawn processes), run Xcode, or execute a Mach-O AOT image.\n'
    printf '           Those need a Linux host, an Apple machine and a signing\n'
    printf '           identity respectively.\n'
}

systui_ioskit_about() {
    systui_ioskit_show_text "About iOS LinuxKit" systui_ioskit_about_text
}

systui_ioskit_maintenance_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Maintenance" \
            "Update the checkout, prune downloads or report diagnostics." \
            update     "Update the source (fast-forward) and rebuild" \
            prune      "Remove downloaded archives (keeps images)" \
            uninstall  "Remove the images, downloads and source" \
            back       "Back" || return $?
        case "$c" in
            update)
                systui_ioskit_source_update && systui_ioskit_run_build "$(systui_ioskit_build_target_for release)"
                systui_ioskit_cache_invalidate
                ;;
            prune)    systui_ioskit_prune_downloads ;;
            uninstall) systui_ioskit_uninstall ;;
            back|'')  return 0 ;;
        esac
    done
}

systui_ioskit_prune_downloads() {
    local n=0 f
    [ -d "$IOSKIT_DOWNLOAD_DIR" ] || { tui_msg "Prune downloads" "Nothing downloaded yet."; return 0; }
    for f in "$IOSKIT_DOWNLOAD_DIR"/*; do
        [ -f "$f" ] && n=$((n + 1))
    done
    if [ "$n" = 0 ]; then
        tui_msg "Prune downloads" "No archives in $IOSKIT_DOWNLOAD_DIR"
        return 0
    fi
    tui_yesno "Prune downloads" "Delete $n downloaded archive(s) from\n$IOSKIT_DOWNLOAD_DIR?\n\nImported images are not affected." || return 0
    rm -f -- "$IOSKIT_DOWNLOAD_DIR"/*
    tui_msg "Prune downloads" "Removed $n archive(s)."
}

systui_ioskit_uninstall() {
    tui_yesno "Remove iOS LinuxKit data" "This deletes:\n\n  $IOSKIT_IMAGES_DIR\n  $IOSKIT_DOWNLOAD_DIR\n  $IOSKIT_SRC_DIR\n\nThe source checkout can be re-cloned at any time; images and local edits cannot be recovered." || return 0
    tui_yesno "Confirm removal" "Really delete those three directories?" || return 0
    rm -rf -- "$IOSKIT_IMAGES_DIR" "$IOSKIT_DOWNLOAD_DIR" "$IOSKIT_SRC_DIR"
    systui_ioskit_cache_invalidate
    systui_ioskit_conf_unset IOSKIT_DEFAULT_IMAGE >/dev/null 2>&1 || true
    tui_msg "Remove iOS LinuxKit data" "Removed. Settings were kept in\n$(systui_ioskit_conf_file)\n\nso a future install can reuse them."
}

###############################################################################
# SETTINGS
###############################################################################

# Settings is split by what a change affects: where files live, how the guest
# behaves, and the packaging pin. One twelve-entry list mixed a repository URL
# with a save-time pin override, and pushed the destructive reset off the list.
systui_ioskit_settings_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Settings" \
            "File: $(systui_ioskit_conf_file)" \
            config    "Source and directories — repository, branch, paths" \
            guest     "Guest and session — dependencies, bind mounts, netlink, runtime" \
            pin       "Root filesystem pin ($(systui_ioskit_rootfs_pin_source))" \
            reset     "Reset all settings to defaults" \
            back      "Back" || return $?
        case "$c" in
            config)  systui_ioskit_settings_config_menu ;;
            guest)   systui_ioskit_settings_guest_menu ;;
            pin)     systui_ioskit_settings_pin_menu ;;
            reset)   systui_ioskit_settings_reset ;;
            back|'') return 0 ;;
        esac
    done
}

systui_ioskit_settings_config_menu() {
    local c v
    while true; do
        tui_capture_menu c tui_menu_no_tags "Source and directories" \
            "Where the checkout, images and downloads live." \
            url       "Repository URL ($IOSKIT_REPO_URL)" \
            branch    "Branch ($IOSKIT_BRANCH)" \
            srcdir    "Source directory ($IOSKIT_SRC_DIR)" \
            imagesdir "Images directory ($IOSKIT_IMAGES_DIR)" \
            back      "Back" || return $?
        case "$c" in
            url)
                v=$(tui_input "Repository URL" "Git URL for the ios-linuxkit checkout:" "$IOSKIT_REPO_URL") || continue
                [ -n "$v" ] || continue
                systui_ioskit_conf_set IOSKIT_REPO_URL "$v" || tui_msg "Settings" "Could not write the settings file."                ;;
            branch)
                v=$(tui_input "Branch" "Branch, tag or commit to check out:" "$IOSKIT_BRANCH") || continue
                [ -n "$v" ] || continue
                systui_ioskit_conf_set IOSKIT_BRANCH "$v" || tui_msg "Settings" "Could not write the settings file."                ;;
            srcdir)
                v=$(tui_input "Source directory" "Where the checkout lives:" "$IOSKIT_SRC_DIR") || continue
                [ -n "$v" ] || continue
                systui_ioskit_conf_set IOSKIT_SRC_DIR "$v" || tui_msg "Settings" "Could not write the settings file."
                systui_ioskit_cache_invalidate                ;;
            imagesdir)
                v=$(tui_input "Images directory" "Where guest root filesystems live:" "$IOSKIT_IMAGES_DIR") || continue
                [ -n "$v" ] || continue
                systui_ioskit_conf_set IOSKIT_IMAGES_DIR "$v" || tui_msg "Settings" "Could not write the settings file."
                systui_ioskit_cache_invalidate                ;;
            back|'') return 0 ;;
        esac
    done
}

systui_ioskit_settings_guest_menu() {
    local c v
    while true; do
        tui_capture_menu c tui_menu_no_tags "Guest and session" \
            "Defaults applied to every guest this manager starts." \
            autodeps  "Automatic dependency install: $([ "$IOSKIT_AUTO_DEPS" = 1 ] && printf on || printf off)" \
            binds     "Bind mounts (${IOSKIT_BIND_MOUNTS:-none})" \
            netlink   "Route netlink stub: $([ "${IOSKIT_NETLINK:-0}" = 1 ] && printf on || printf off)" \
            runtime   "Preferred runtime: ${IOSKIT_RUNTIME:-release}" \
            back      "Back" || return $?
        case "$c" in
            autodeps)
                if [ "$IOSKIT_AUTO_DEPS" = 1 ]; then v=0; else v=1; fi
                systui_ioskit_conf_set IOSKIT_AUTO_DEPS "$v" || tui_msg "Settings" "Could not write the settings file."                ;;
            binds)   systui_ioskit_bind_mount_prompt ;;
            netlink)
                if [ "${IOSKIT_NETLINK:-0}" = 1 ]; then v=0; else v=1; fi
                IOSKIT_NETLINK="$v"
                systui_ioskit_conf_set IOSKIT_NETLINK "$v" || tui_msg "Settings" "Could not write the settings file."                ;;
            runtime) systui_ioskit_pick_runtime ;;
            back|'') return 0 ;;
        esac
    done
}

systui_ioskit_settings_pin_menu() {
    local c v
    while true; do
        tui_capture_menu c tui_menu_no_tags "Root filesystem pin" \
            "Source: $(systui_ioskit_rootfs_pin_source)\n$(systui_ioskit_rootfs_pin)" \
            set   "Set a pin override (URL and SHA-256)" \
            clear "Clear the override (use the checkout's own pin)" \
            show  "Show the effective pin and where it comes from" \
            back  "Back" || return $?
        case "$c" in
            set)
                v=$(tui_input "Root filesystem pin" "URL of the root filesystem tarball (empty restores the checkout/built-in pin):" "$IOSKIT_ROOTFS_URL") || continue
                if [ -z "$v" ]; then
                    systui_ioskit_conf_unset IOSKIT_ROOTFS_URL; systui_ioskit_conf_unset IOSKIT_ROOTFS_SHA256
                    continue
                fi
                local sha
                sha=$(tui_input "Root filesystem pin" "Expected SHA-256 (empty = no verification):" "$IOSKIT_ROOTFS_SHA256") || continue
                sha=${sha%% *}
                systui_ioskit_conf_set IOSKIT_ROOTFS_URL "$v"
                systui_ioskit_conf_set IOSKIT_ROOTFS_SHA256 "$sha"                ;;
            clear)
                systui_ioskit_conf_unset IOSKIT_ROOTFS_URL
                systui_ioskit_conf_unset IOSKIT_ROOTFS_SHA256
                tui_msg "Settings" "Pin override cleared; the checkout's own pin is used."                ;;
            show) systui_ioskit_show_text "Root filesystem pin" systui_ioskit_pin_text ;;
            back|'') return 0 ;;
        esac
    done
}

systui_ioskit_settings_reset() {
    tui_yesno "Settings" "Delete $(systui_ioskit_conf_file) and return every setting to its default?" || return 0
    rm -f -- "$(systui_ioskit_conf_file)"
    unset IOSKIT_REPO_URL IOSKIT_BRANCH IOSKIT_SRC_DIR IOSKIT_IMAGES_DIR \
        IOSKIT_DOWNLOAD_DIR IOSKIT_DEFAULT_IMAGE IOSKIT_AUTO_DEPS \
        IOSKIT_ROOTFS_URL IOSKIT_ROOTFS_SHA256 IOSKIT_BIND_MOUNTS \
        IOSKIT_NETLINK IOSKIT_RUNTIME
    systui_ioskit_load
    systui_ioskit_cache_invalidate
    tui_msg "Settings" "All settings are back at their defaults."
}

systui_ioskit_pin_text() {
    printf 'Effective root filesystem pin\n'
    printf '==============================\n\n'
    printf '  source : %s\n' "$(systui_ioskit_rootfs_pin_source)"
    printf '  pin    : %s\n\n' "$(systui_ioskit_rootfs_pin)"
    printf 'Precedence\n'
    printf '  1. a settings override in %s\n' "$(systui_ioskit_conf_file)"
    printf '  2. the checkout'"'"'s own app/GuestARM64.xcconfig\n'
    printf '  3. the built-in release pin shipped with systui\n\n'
    printf 'The app downloader validates whatever this pin names: a temporary file,\n'
    printf 'a SHA-256 check, a bin/busybox extraction and an AArch64 file(1) check\n'
    printf 'before it atomically installs root.tar.gz. A failed check leaves the\n'
    printf 'previous bundle archive untouched.\n'
}

###############################################################################
# FRONT DOOR
###############################################################################

# The front door is deliberately task-shaped: what a host can do to a guest
# root filesystem, to a host build, and on Apple hardware. The previous flat
# list had fourteen peer entries, which mixed a critical warning (an AArch64
# host) in with a static guide page and pushed real actions past the dialog's
# visible list height. Everything that was reachable is still reachable, one
# group deep, and nothing was dropped.
menu_ios_linuxkit() {
    local c
    systui_ioskit_load
    systui_ioskit_cache_warm
    while true; do
        tui_capture_menu c tui_menu_no_tags "iOS-linuxkit configuration" \
            "Configure iOS-linuxkit for iSH-AOK.\n\n$(systui_ioskit_state_summary)\n\n$(systui_ioskit_recommendation)" \
            setup    "Install / setup iOS-linuxkit — guided quick setup or advanced controls" \
            status   "Status and diagnostics — host, source, tools, limits" \
            guestfs  "Guest root filesystems — import, export, run, host access" \
            verify   "Validate and release — gates, versions, AOT" \
            settings "Settings — paths, branch, pin, session switches" \
            about    "About iOS LinuxKit" \
            back     "Back" || return $?
        case "$c" in
            status)   systui_ioskit_status_menu ;;
            setup)    systui_ioskit_setup_menu; systui_ioskit_cache_warm ;;
            guestfs)  systui_ioskit_guestfs_menu; systui_ioskit_cache_warm ;;
            verify)   systui_ioskit_verify_menu ;;
            settings) systui_ioskit_settings_menu ;;
            about)    systui_ioskit_about ;;
            back|'')  return 0 ;;
        esac
    done
}

# One short line that says what to do next, or what is already ready. It is
# computed from real probes, so it cannot claim a state the host is not in.
systui_ioskit_recommendation() {
    # The architecture comes from the cache that systui_ioskit_cache_warm
    # populated; no fork happens here on a redraw.
    local arch="${_SYSTUI_IOSKIT_ARCH:-}"
    if [ -z "$arch" ]; then
        arch=$(systui_ioskit_host_arch)
    fi
    if [ "$arch" != aarch64 ]; then
        printf 'Host is %s: the Linux-host build needs AArch64. Apple path: Validate and release.\n' "$arch"
        return 0
    fi
    if ! systui_ioskit_repo_present; then
        printf 'Next: Set up and build — check out the source.\n'
        return 0
    fi
    if ! systui_ioskit_ish_bin >/dev/null 2>&1; then
        printf 'Next: Set up and build — install dependencies, then build.\n'
        return 0
    fi
    if [ "$(systui_ioskit_image_count)" = 0 ]; then
        printf 'Next: Guest root filesystems — download the pinned Alpine rootfs.\n'
        return 0
    fi
    printf 'Ready: %s image(s), %s runtime.\n' \
        "$(systui_ioskit_image_count)" "${IOSKIT_RUNTIME:-release}"
}

# "Status and diagnostics" merges two former front-door entries that both ended
# in a report about this host.
systui_ioskit_status_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Status and diagnostics" \
            "What this host has, what it can do, and what it cannot." \
            status  "Full status report (host, source, tools, outputs, images)" \
            vars    "Runtime variables (ISH_* traces) and guest environment" \
            compat  "Runtime compatibility settings (Go, Node, JavaScriptCore)" \
            limits  "Known limits (security, facilities, memory, host)" \
            back    "Back" || return $?
        case "$c" in
            status) systui_ioskit_status_screen ;;
            vars)   systui_ioskit_show_text "Runtime diagnostics" systui_ioskit_diag_vars_text ;;
            compat) systui_ioskit_show_text "Runtime compatibility" systui_ioskit_compat_text ;;
            limits) systui_ioskit_show_text "Known limits" systui_ioskit_limits_text ;;
            back|'') return 0 ;;
        esac
    done
}

systui_ioskit_setup_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Set up and build" \
            "Checkout: $(systui_ioskit_version)   Runtime: $(systui_ioskit_ish_bin || printf 'not built')" \
            source  "Source — check out, update, submodules" \
            build   "Build — dependencies and make targets" \
            maint   "Maintenance — update and rebuild, prune, remove" \
            back    "Back" || return $?
        case "$c" in
            source) systui_ioskit_source_menu ;;
            build)  systui_ioskit_build_menu ;;
            maint)  systui_ioskit_maintenance_menu ;;
            back|'') return 0 ;;
        esac
    done
}

# Guest images, running a guest and host integration belong together: all three
# are about the guest's view of its filesystem and the host.
systui_ioskit_guestfs_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Guest root filesystems" \
            "Images: $(systui_ioskit_image_count)   default: ${IOSKIT_DEFAULT_IMAGE:-none}" \
            manage "Manage images — download, import, export, verify, remove" \
            run    "Run — guest shell, command or host filesystem" \
            host   "Host integration — bind mounts, offload, netlink" \
            back   "Back" || return $?
        case "$c" in
            manage) systui_ioskit_images_menu ;;
            run)    systui_ioskit_run_menu ;;
            host)   systui_ioskit_host_menu ;;
            back|'') return 0 ;;
        esac
    done
}

# Everything that produces evidence or ships a version.
systui_ioskit_verify_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Validate and release" \
            "Gates, versions and the Apple and AOT paths." \
            gates    "Validation gates — list, run, failure rules" \
            versions "Versions, bundle and release provenance" \
            app      "Build the iOS application — requirements and steps" \
            aot      "Native / AOT pipeline" \
            back     "Back" || return $?
        case "$c" in
            gates)    systui_ioskit_validation_menu ;;
            versions) systui_ioskit_app_menu ;;
            app)      systui_ioskit_show_text "iOS application" systui_ioskit_app_text ;;
            aot)      systui_ioskit_aot_menu ;;
            back|'')  return 0 ;;
        esac
    done
}

# The gate chooser and the gate report belong together: picking gates without
# seeing what they check is how a "quick run" turns into an hour of debootstrap.
systui_ioskit_validation_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Validation" \
            "Focused gates, runtime coverage and the failure rules." \
            gates   "Show the gate list" \
            run     "Run validation gates" \
            runtime "Run the release runtime coverage gate" \
            debug   "Run the debug runtime coverage gate" \
            rules   "Failure rules and diagnostics during tests" \
            back    "Back" || return $?
        case "$c" in
            gates)   systui_ioskit_show_text "Validation gates" systui_ioskit_gates_text ;;
            run)     systui_ioskit_run_gates ;;
            runtime) systui_ioskit_run_single_gate test-arm64-runtime-coverage ;;
            debug)   systui_ioskit_run_single_gate test-arm64-runtime-coverage-debug ;;
            rules)   systui_ioskit_show_text "Failure rules" systui_ioskit_rules_text ;;
            back|'') return 0 ;;
        esac
    done
}

systui_ioskit_rules_text() {
    printf 'Failure rules and test evidence\n'
    printf '===============================\n\n'
    printf 'A row fails when any of these happen\n'
    printf '  1. the command exits non-zero;\n'
    printf '  2. the harness reaches its timeout or kills the process;\n'
    printf '  3. SAFETY-VALVE appears in a non-diagnostic row;\n'
    printf '  4. unexpected fault, illegal-instruction or NETDIAG output appears;\n'
    printf '  5. a required row is skipped or silently reported as success;\n'
    printf '  6. the expected output came from stale artifacts.\n\n'
    printf 'Unsupported facilities must be reported as unsupported with a reason.\n'
    printf 'A missing package and a rootfs packaging error are not emulator passes\n'
    printf 'and are recorded separately from instruction or syscall results.\n\n'
    printf 'Keep with a result\n'
    printf '  * source revision and dirty-tree state;\n'
    printf '  * release or debug binary path and checksum when needed;\n'
    printf '  * rootfs name and the relevant package versions;\n'
    printf '  * the complete command and environment;\n'
    printf '  * exit status and a diagnostic excerpt.\n\n'
    printf 'Cold-toolchain trap\n'
    printf '  A cold Go cache can exceed the ordinary timeout because Alpine may\n'
    printf '  ship standard-library source without precompiled archives. Raise\n'
    printf '  TIMEOUT_S for a first run instead of reading a harness kill as a pass.\n'
}

systui_ioskit_status_screen() {
    systui_ioskit_show_text "iOS LinuxKit status" systui_ioskit_status_text
}

systui_ioskit_source_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Source" \
            "Checkout: $IOSKIT_SRC_DIR ($(systui_ioskit_version))" \
            clone   "Check out the repository (git clone --recurse-submodules)" \
            update  "Update in place (fast-forward only)" \
            submods "Refresh submodules" \
            reveal  "Show the exact clone command" \
            back    "Back" || return $?
        case "$c" in
            clone)   systui_ioskit_source_clone "$IOSKIT_REPO_URL" "$IOSKIT_BRANCH" "$IOSKIT_SRC_DIR" ;;
            update)  systui_ioskit_source_update ;;
            submods)
                systui_ioskit_repo_present || { tui_msg "Source" "No checkout yet."; continue; }
                run_cmd "Refresh submodules" git -C "$IOSKIT_SRC_DIR" submodule update --init --recursive
                systui_ioskit_cache_invalidate
                ;;
            reveal)
                tui_msg "Clone command" "git clone --recurse-submodules --branch $IOSKIT_BRANCH \\\\\n  $IOSKIT_REPO_URL \\\\\n  $IOSKIT_SRC_DIR"
                ;;
            back|'') return 0 ;;
        esac
    done
}

# iOS-linuxkit is integrated under Rootfs by the late iSH-AOK integration layer.
# Keep this module focused on the iOS-linuxkit feature itself; it must not
# override System Configuration or any other top-level menu.

return 0 2>/dev/null || true
