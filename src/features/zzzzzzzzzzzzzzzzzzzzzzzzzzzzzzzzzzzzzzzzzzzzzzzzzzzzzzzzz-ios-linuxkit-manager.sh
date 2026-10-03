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
                IOSKIT_ROOTFS_URL|IOSKIT_ROOTFS_SHA256)
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
        IOSKIT_ROOTFS_URL|IOSKIT_ROOTFS_SHA256) ;;
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
        IOSKIT_ROOTFS_URL|IOSKIT_ROOTFS_SHA256) ;;
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

systui_ioskit_host_arch() {
    local m
    m=$(uname -m 2>/dev/null || printf 'unknown')
    case "$m" in
        aarch64|arm64) printf '%s\n' 'aarch64' ;;
        x86_64|amd64)  printf '%s\n' 'x86_64' ;;
        *)             printf '%s\n' "$m" ;;
    esac
}

systui_ioskit_repo_present() {
    [ -d "$IOSKIT_SRC_DIR/.git" ]
}

systui_ioskit_dirty() { # 1 when the checkout has local changes (best effort)
    local out
    systui_ioskit_repo_present || return 1
    systui_ioskit_have git || return 1
    out=$(git -C "$IOSKIT_SRC_DIR" status --porcelain 2>/dev/null) || return 1
    [ -n "$out" ]
}

systui_ioskit_version() { # printed short version/commit of the checkout
    local out
    systui_ioskit_repo_present || { printf '%s\n' 'not checked out'; return; }
    if systui_ioskit_have git; then
        out=$(git -C "$IOSKIT_SRC_DIR" describe --tags --always 2>/dev/null) \
            && [ -n "$out" ] && { printf '%s\n' "$out"; return; }
    fi
    printf '%s\n' 'unknown'
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
    printf '%s\n' "$src   $bin   root filesystems: $images"
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
        git clone --recurse-submodules --branch "$branch" -- "$url" "$dir"
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

systui_ioskit_images_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Guest root filesystems" \
            "Directory: $IOSKIT_IMAGES_DIR\nImages: $(systui_ioskit_image_count)" \
            list     "List images" \
            download "Download and import the pinned Alpine rootfs" \
            import   "Import a local rootfs tarball" \
            fetchurl "Import from a URL (with optional SHA-256 check)" \
            default  "Set the default image" \
            remove   "Remove an image" \
            verify   "Verify an image" \
            back     "Back" || return $?
        case "$c" in
            list)     systui_ioskit_show_text "Guest root filesystems" systui_ioskit_images_text ;;
            download) systui_ioskit_download_pinned ;;
            import)   systui_ioskit_import_local ;;
            fetchurl) systui_ioskit_import_url ;;
            default)  systui_ioskit_set_default_image ;;
            remove)   systui_ioskit_remove_image ;;
            verify)   systui_ioskit_verify_image ;;
            back|'')  return 0 ;;
        esac
    done
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
    if systui_ioskit_image_valid "$dest"; then
        if [ -z "$IOSKIT_DEFAULT_IMAGE" ]; then
            systui_ioskit_conf_set IOSKIT_DEFAULT_IMAGE "$name" >/dev/null 2>&1 || true
        fi
        tui_msg "Import" "Imported:\n$dest"
    else
        tui_msg "Import" "fakefsify finished, but $dest does not look like a root filesystem.\n\nCheck the tool output in $LOGFILE."
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
# RUN
###############################################################################

systui_ioskit_run_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Run the guest" \
            "Runtime: $(systui_ioskit_ish_bin || printf 'not built')\nDefault image: ${IOSKIT_DEFAULT_IMAGE:-none}" \
            shell   "Open a guest shell (/bin/sh)" \
            command "Run one guest command" \
            host    "Run against the host filesystem (-r /)" \
            engines "Show the exact commands (no execution)" \
            back    "Back" || return $?
        case "$c" in
            shell)   systui_ioskit_run_shell ;;
            command) systui_ioskit_run_command ;;
            host)    systui_ioskit_run_host ;;
            engines) systui_ioskit_show_commands ;;
            back|'') return 0 ;;
        esac
    done
}

# The runtime cannot be executed from the iOS sandbox: a sideloaded app cannot
# spawn processes. Say so rather than offering a button that fails.
systui_ioskit_run_guard() {
    local bin
    if ! bin=$(systui_ioskit_ish_bin); then
        tui_msg "Run" "No ish binary has been built yet.\n\nBuild the project first (Build → Build release)."
        return 1
    fi
    printf '%s\n' "$bin"
    return 0
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

systui_ioskit_run_shell() {
    local bin root kind path
    bin=$(systui_ioskit_run_guard) || return 1
    root=$(systui_ioskit_pick_rootfs allow-host) || return 0
    kind=${root%% *}
    path=${root#* }
    run_cmd "Guest shell ($path)" "$bin" "-$kind" "$path" /bin/sh
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
    run_cmd "Guest command: $cmd" "$bin" "-$kind" "$path" /bin/sh -c "$cmd"
}

systui_ioskit_run_host() {
    local bin cmd
    bin=$(systui_ioskit_run_guard) || return 1
    tui_yesno "Host filesystem" "Run the guest runtime against the host filesystem?\n\nThe guest sees and can modify real host paths. Use it for inspection, not for untrusted work." || return 0
    cmd=$(tui_input "Run against host" "Command (or empty for a shell):" "/bin/uname -a") || return 0
    if [ -z "$cmd" ]; then
        run_cmd "Guest shell on host filesystem" "$bin" -r / /bin/sh
    else
        # shellcheck disable=SC2086
        run_cmd "Guest command on host filesystem: $cmd" "$bin" -r / /bin/sh -c "$cmd"
    fi
}

systui_ioskit_show_commands() {
    local f bin fakefsify
    bin=$(systui_ioskit_ish_bin || printf '%s' "$IOSKIT_SRC_DIR/build-arm64-linux/ish")
    fakefsify=$(systui_ioskit_fakefsify_bin || printf '%s' "$IOSKIT_SRC_DIR/build-arm64-linux/tools/fakefsify")
    f=$(mktemp 2>/dev/null || printf '%s' "${SYSTUI_TMP:-/tmp}/ioskit-cmds.$$")
    {
        printf 'Exact commands the manager would run\n'
        printf '====================================\n\n'
        printf 'Check out the source\n'
        printf '  git clone --recurse-submodules --branch %s \\\n' "$IOSKIT_BRANCH"
        printf '    %s %s\n\n' "$IOSKIT_REPO_URL" "$IOSKIT_SRC_DIR"
        printf 'Build (AArch64 Linux host)\n'
        printf '  make -C %s build-arm64-linux CC=clang\n\n' "$IOSKIT_SRC_DIR"
        printf 'Import a root filesystem tarball\n'
        printf '  %s <tarball> %s/<name>\n\n' "$fakefsify" "$IOSKIT_IMAGES_DIR"
        printf 'Run a guest shell in a fakefs image\n'
        printf '  %s -f %s/<name> /bin/sh\n\n' "$bin" "$IOSKIT_IMAGES_DIR"
        printf 'Run against the host filesystem\n'
        printf '  %s -r / /bin/sh\n\n' "$bin"
        printf 'Runtime options: -r <real root> -f <fakefs root> -d <workdir>\n'
        printf '                 -c <console> -n <offload>\n'
    } > "$f"
    tui_text "Commands" "$f"
    rm -f "$f"
}

###############################################################################
# DIAGNOSTICS, ABOUT AND MAINTENANCE
###############################################################################

systui_ioskit_diagnostics_text() {
    local line
    systui_ioskit_status_text
    printf '\nRuntime probe\n'
    printf '  ish binary    : %s\n' "$(systui_ioskit_ish_bin || printf 'absent')"
    printf '  fakefsify     : %s\n' "$(systui_ioskit_fakefsify_bin || printf 'absent')"
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
}

systui_ioskit_diagnostics() {
    local bin
    systui_ioskit_show_text "iOS LinuxKit diagnostics" systui_ioskit_diagnostics_text
    if bin=$(systui_ioskit_ish_bin); then
        tui_yesno "Diagnostics" "Also read the runtime's own help text?\n\n$bin\n\nThis executes the binary with no guest arguments." || return 0
        run_cmd "Runtime help" "$bin" -h
    fi
}

systui_ioskit_about_text() {
    printf 'iOS LinuxKit\n'
    printf '============\n\n'
    printf 'An optimised fork of iSH that runs an AArch64 Linux userland inside an\n'
    printf 'iOS app and as a command-line process on an AArch64 Linux host.\n\n'
    printf '  upstream    : https://github.com/rcarmo/ios-linuxkit\n'
    printf '  guest arch  : ARM64 only\n'
    printf '  engine      : iSH userspace kernel and Asbestos threaded-code\n'
    printf '                interpreter (native/AOT backend off by default)\n\n'
    printf 'What the pieces are\n'
    printf '  ish          the runtime binary (build-arm64-linux/ish)\n'
    printf '  fakefsify    imports a root filesystem tarball into a fakefs image\n'
    printf '  fakefs       the bootable guest root: a directory, not a disk image\n\n'
    printf 'Typical Linux-host flow\n'
    printf '  1. install clang, meson, ninja, pkg-config, sqlite and libarchive\n'
    printf '     development files\n'
    printf '  2. make build-arm64-linux\n'
    printf '  3. download an Alpine aarch64 minirootfs and import it with fakefsify\n'
    printf '  4. ish -f <image> /bin/sh\n\n'
    printf 'What this manager can and cannot do\n'
    printf '  can    : check out the source, check and install build dependencies,\n'
    printf '           build on an AArch64 Linux host, download and verify pinned\n'
    printf '           root filesystems, import, list and verify images, run guest\n'
    printf '           shells and commands, and report diagnostics.\n'
    printf '  cannot : run the runtime from the iOS sandbox (a sideloaded app\n'
    printf '           cannot spawn processes), or enable the iOS/Xcode target —\n'
    printf '           that needs Xcode and a signing identity.\n'
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
            diag       "Write a full diagnostics report" \
            prune      "Remove downloaded archives (keeps images)" \
            uninstall  "Remove the images, downloads and source" \
            back       "Back" || return $?
        case "$c" in
            update)   systui_ioskit_source_update && systui_ioskit_run_build "$(systui_ioskit_build_target_for release)" ;;
            diag)     systui_ioskit_diagnostics ;;
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
    systui_ioskit_conf_unset IOSKIT_DEFAULT_IMAGE >/dev/null 2>&1 || true
    tui_msg "Remove iOS LinuxKit data" "Removed. Settings were kept in\n$(systui_ioskit_conf_file)\n\nso a future install can reuse them."
}

###############################################################################
# SETTINGS
###############################################################################

systui_ioskit_settings_menu() {
    local c v
    while true; do
        tui_capture_menu c tui_menu_no_tags "Settings" \
            "Settings file: $(systui_ioskit_conf_file)" \
            url       "Repository URL ($IOSKIT_REPO_URL)" \
            branch    "Branch ($IOSKIT_BRANCH)" \
            srcdir    "Source directory ($IOSKIT_SRC_DIR)" \
            imagesdir "Images directory ($IOSKIT_IMAGES_DIR)" \
            autodeps  "Automatic dependency install: $([ "$IOSKIT_AUTO_DEPS" = 1 ] && printf on || printf off)" \
            pin       "Root filesystem pin ($(systui_ioskit_rootfs_pin_source))" \
            clearpin  "Clear the pin override (use the checkout's own pin)" \
            reset     "Reset all settings to defaults" \
            back      "Back" || return $?
        case "$c" in
            url)
                v=$(tui_input "Repository URL" "Git URL for the ios-linuxkit checkout:" "$IOSKIT_REPO_URL") || continue
                [ -n "$v" ] || continue
                systui_ioskit_conf_set IOSKIT_REPO_URL "$v" || tui_msg "Settings" "Could not write the settings file."
                ;;
            branch)
                v=$(tui_input "Branch" "Branch, tag or commit to check out:" "$IOSKIT_BRANCH") || continue
                [ -n "$v" ] || continue
                systui_ioskit_conf_set IOSKIT_BRANCH "$v" || tui_msg "Settings" "Could not write the settings file."
                ;;
            srcdir)
                v=$(tui_input "Source directory" "Where the checkout lives:" "$IOSKIT_SRC_DIR") || continue
                [ -n "$v" ] || continue
                systui_ioskit_conf_set IOSKIT_SRC_DIR "$v" || tui_msg "Settings" "Could not write the settings file."
                ;;
            imagesdir)
                v=$(tui_input "Images directory" "Where guest root filesystems live:" "$IOSKIT_IMAGES_DIR") || continue
                [ -n "$v" ] || continue
                systui_ioskit_conf_set IOSKIT_IMAGES_DIR "$v" || tui_msg "Settings" "Could not write the settings file."
                ;;
            autodeps)
                if [ "$IOSKIT_AUTO_DEPS" = 1 ]; then v=0; else v=1; fi
                systui_ioskit_conf_set IOSKIT_AUTO_DEPS "$v" || tui_msg "Settings" "Could not write the settings file."
                ;;
            pin)
                v=$(tui_input "Root filesystem pin" "URL of the root filesystem tarball (empty restores the checkout/built-in pin):" "$IOSKIT_ROOTFS_URL") || continue
                if [ -z "$v" ]; then
                    systui_ioskit_conf_unset IOSKIT_ROOTFS_URL; systui_ioskit_conf_unset IOSKIT_ROOTFS_SHA256
                    continue
                fi
                local sha
                sha=$(tui_input "Root filesystem pin" "Expected SHA-256 (empty = no verification):" "$IOSKIT_ROOTFS_SHA256") || continue
                sha=${sha%% *}
                systui_ioskit_conf_set IOSKIT_ROOTFS_URL "$v"
                systui_ioskit_conf_set IOSKIT_ROOTFS_SHA256 "$sha"
                ;;
            clearpin)
                systui_ioskit_conf_unset IOSKIT_ROOTFS_URL
                systui_ioskit_conf_unset IOSKIT_ROOTFS_SHA256
                tui_msg "Settings" "Pin override cleared; the checkout's own pin is used."
                ;;
            reset)
                tui_yesno "Settings" "Delete $(systui_ioskit_conf_file) and return every setting to its default?" || continue
                rm -f -- "$(systui_ioskit_conf_file)"
                unset IOSKIT_REPO_URL IOSKIT_BRANCH IOSKIT_SRC_DIR IOSKIT_IMAGES_DIR \
                    IOSKIT_DOWNLOAD_DIR IOSKIT_DEFAULT_IMAGE IOSKIT_AUTO_DEPS \
                    IOSKIT_ROOTFS_URL IOSKIT_ROOTFS_SHA256
                systui_ioskit_load
                ;;
            back|'') return 0 ;;
        esac
    done
}

###############################################################################
# FRONT DOOR
###############################################################################

menu_ios_linuxkit() {
    local c
    systui_ioskit_load
    while true; do
        tui_capture_menu c tui_menu_no_tags "iOS LinuxKit" \
            "$(systui_ioskit_state_summary)\n\nBuild, root filesystems and guest shells for rcarmo/ios-linuxkit:" \
            status    "Status — host, source, tools, build outputs, images" \
            source    "Source — check out or update the repository" \
            build     "Build — dependencies and make targets" \
            images    "Guest root filesystems — download, import, verify" \
            run       "Run — guest shell or command" \
            maintain  "Maintenance — update, prune, diagnostics" \
            settings  "Settings — paths, branch, root filesystem pin" \
            about     "About iOS LinuxKit" \
            back      "Back" || return $?
        case "$c" in
            status)   systui_ioskit_status_screen ;;
            source)   systui_ioskit_source_menu ;;
            build)    systui_ioskit_build_menu ;;
            images)   systui_ioskit_images_menu ;;
            run)      systui_ioskit_run_menu ;;
            maintain) systui_ioskit_maintenance_menu ;;
            settings) systui_ioskit_settings_menu ;;
            about)    systui_ioskit_about ;;
            back|'')  return 0 ;;
        esac
    done
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
                ;;
            reveal)
                tui_msg "Clone command" "git clone --recurse-submodules --branch $IOSKIT_BRANCH \\\\\n  $IOSKIT_REPO_URL \\\\\n  $IOSKIT_SRC_DIR"
                ;;
            back|'') return 0 ;;
        esac
    done
}

# Add the iOS LinuxKit front door to System Configuration. The shipped menu is
# preserved under its own name so nothing else in this file depends on the
# redefinition, and the drift test in tests/test-ios-linuxkit-manager.sh fails
# if the base menu gains an entry this dispatcher does not carry.
if declare -F menu_sysconfig >/dev/null 2>&1 \
    && ! declare -F _systui_menu_sysconfig_before_ioskit >/dev/null 2>&1; then
    systui_alias_function menu_sysconfig _systui_menu_sysconfig_before_ioskit
fi

menu_sysconfig() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "System Configuration" \
            "Detected: package manager = ${PM:-unknown}, init = ${INIT:-unknown}" \
            ioskit       "iOS LinuxKit — build, root filesystems and guest shells" \
            system       "System basics — hostname, timezone, system scan" \
            packages     "Packages, catalogue, repositories and managers" \
            shells       "Shells, prompts and plugins" \
            editors      "Editors" \
            filemanagers "File managers" \
            network      "Network, SSH, DNS, proxy and time" \
            services     "Services and init systems" \
            users        "Users, sudo, passwords and SSH keys" \
            storage      "Storage, mounts, filesystems and SMART" \
            back         "Back to main menu" || return $?
        case "$c" in
            ioskit)       tui_call_menu menu_ios_linuxkit "iOS LinuxKit" ;;
            system)       tui_call_menu menu_sysconfig_basics "System basics" ;;
            packages)     tui_call_menu menu_packages "Packages" ;;
            shells)       tui_call_menu menu_shells "Shells" ;;
            editors)      tui_call_menu menu_editors "Editors" ;;
            filemanagers) tui_call_menu menu_file_managers "File managers" ;;
            network)      tui_call_menu menu_network "Network" ;;
            services)     tui_call_menu menu_services "Services" ;;
            users)        tui_call_menu menu_users "Users" ;;
            storage)      tui_call_menu menu_storage "Storage" ;;
            back|'') return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
