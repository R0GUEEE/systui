# shellcheck shell=bash
###############################################################################
# PACKAGE INSTALL RECOVERY
#
# Loaded last so every package-install entrypoint, including Bedrock's wrapper,
# gets the same behavior:
#   1. install all requested packages in one native PM command
#   2. refresh package indexes on failure
#   3. retry the same package batch once
#   4. analyze distro/package availability and offer repository recovery
#   5. retry all still-missing packages together after repository changes
#   6. use Bedrock as a final managed fallback when available
#   7. skip unresolved items in a multi-install; return failure for a single item
###############################################################################

systui_pkg_is_installed() { # <package>
    local pkg="$1"
    case "${PM:-}" in
        apt) dpkg-query -W -f='${Status}' -- "$pkg" 2>/dev/null | grep -q 'install ok installed' ;;
        apk) apk info -e "$pkg" >/dev/null 2>&1 ;;
        pacman) pacman -Q -- "$pkg" >/dev/null 2>&1 ;;
        dnf|yum) rpm -q -- "$pkg" >/dev/null 2>&1 ;;
        zypper) rpm -q -- "$pkg" >/dev/null 2>&1 ;;
        xbps) xbps-query -p pkgver "$pkg" >/dev/null 2>&1 ;;
        emerge) qlist -IC "$pkg" >/dev/null 2>&1 || emerge --info "$pkg" >/dev/null 2>&1 ;;
        *) command -v "$pkg" >/dev/null 2>&1 ;;
    esac
}

systui_pm_install_batch() { # <packages...>
    [ "$#" -gt 0 ] || return 0
    case "${PM:-}" in
        apt) run_cmd "apt install $*" apt-get install -y -- "$@" ;;
        apk) run_cmd "apk add $*" apk add -- "$@" ;;
        pacman) run_cmd "pacman -S $*" pacman -S --noconfirm --needed -- "$@" ;;
        dnf) run_cmd "dnf install $*" dnf install -y -- "$@" ;;
        yum) run_cmd "yum install $*" yum install -y -- "$@" ;;
        zypper) run_cmd "zypper install $*" zypper --non-interactive install -- "$@" ;;
        xbps) run_cmd "xbps-install $*" xbps-install -y -- "$@" ;;
        emerge) run_cmd "emerge $*" emerge --ask=n -- "$@" ;;
        *) tui_msg "Error" "No supported package manager found."; return 1 ;;
    esac
}

systui_pm_refresh_indexes() {
    case "${PM:-}" in
        apt) run_cmd "Refresh APT package indexes" apt-get update ;;
        apk) run_cmd "Refresh APK package indexes" apk update ;;
        pacman)
            # -Syy only refreshes databases and does not perform the unsafe
            # partial package upgrade that `pacman -Sy <pkg>` would cause.
            run_cmd "Refresh Pacman package databases" pacman -Syy --noconfirm ;;
        dnf) run_cmd "Refresh DNF metadata" dnf makecache --refresh -y ;;
        yum) run_cmd "Refresh YUM metadata" yum makecache -y ;;
        zypper) run_cmd "Refresh Zypper repositories" zypper --non-interactive refresh --force ;;
        xbps) run_cmd "Refresh XBPS repositories" xbps-install -S ;;
        emerge) run_cmd "Sync Portage repositories" emerge --sync ;;
        *) return 1 ;;
    esac
}

systui_missing_packages() { # <packages...>
    local pkg
    for pkg in "$@"; do
        systui_pkg_is_installed "$pkg" || printf '%s\n' "$pkg"
    done
}

systui_os_id() {
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        printf '%s\n' "${ID:-unknown}"
    else
        printf 'unknown\n'
    fi
}

systui_os_codename() {
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        printf '%s\n' "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    fi
}

# Produce a compact availability report using the existing Repology helper.
# The report is advisory: repositories are never enabled without confirmation.
systui_pkg_availability_report() { # <package>
    local pkg="$1" results=""
    if declare -F pkg_web_search >/dev/null 2>&1; then
        results=$(pkg_web_search "$pkg" 2>/dev/null || true)
    fi
    if [ -n "$results" ]; then
        printf '%s\n' "$results"
    else
        printf '%s\n' 'No remote availability data was returned.'
    fi
}

systui_repo_add_apt() { # <package>
    local pkg="$1" id codename choice
    id=$(systui_os_id)
    codename=$(systui_os_codename)
    case "$id" in
        ubuntu)
            choice=$(tui_menu "Repository recovery" \
                "'$pkg' is still unavailable. Choose an Ubuntu repository component to enable:" \
                universe "Enable Ubuntu Universe" \
                multiverse "Enable Ubuntu Multiverse" \
                custom "Add a custom APT repository" \
                skip "Skip") || return 1
            case "$choice" in
                universe|multiverse)
                    command -v add-apt-repository >/dev/null 2>&1 || pm_install software-properties-common || return 1
                    run_cmd "Enable Ubuntu $choice" add-apt-repository -y "$choice" ;;
                custom)
                    local repo
                    repo=$(tui_input "Custom APT repository" "Enter a deb line or PPA (ppa:owner/name):" "") || return 1
                    [ -n "$repo" ] || return 1
                    command -v add-apt-repository >/dev/null 2>&1 || pm_install software-properties-common || return 1
                    run_cmd "Add APT repository" add-apt-repository -y "$repo" ;;
                *) return 1 ;;
            esac
            ;;
        debian)
            choice=$(tui_menu "Repository recovery" \
                "'$pkg' is still unavailable on Debian${codename:+ $codename}. Add an official component or a custom repository:" \
                contrib "Add official contrib component" \
                nonfree "Add official non-free + non-free-firmware components" \
                custom "Add a custom APT repository" \
                skip "Skip") || return 1
            local component repo
            case "$choice" in
                contrib) component='contrib' ;;
                nonfree) component='contrib non-free non-free-firmware' ;;
                custom)
                    repo=$(tui_input "Custom APT repository" "Enter a complete deb repository line:" "") || return 1
                    [ -n "$repo" ] || return 1
                    printf '%s\n' "$repo" >> /etc/apt/sources.list.d/systui-extra.list
                    return 0 ;;
                *) return 1 ;;
            esac
            [ -n "$codename" ] || return 1
            printf 'deb http://deb.debian.org/debian %s main %s\n' "$codename" "$component" \
                > /etc/apt/sources.list.d/systui-extra.list
            ;;
        kali)
            choice=$(tui_menu "Repository recovery" \
                "'$pkg' is still unavailable. Restore the official Kali rolling repository or add a custom repository:" \
                rolling "Add kali-rolling main/contrib/non-free/non-free-firmware" \
                custom "Add a custom APT repository" \
                skip "Skip") || return 1
            case "$choice" in
                rolling) printf '%s\n' 'deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware' > /etc/apt/sources.list.d/systui-kali.list ;;
                custom)
                    local repo
                    repo=$(tui_input "Custom APT repository" "Enter a complete deb repository line:" "") || return 1
                    [ -n "$repo" ] || return 1
                    printf '%s\n' "$repo" >> /etc/apt/sources.list.d/systui-extra.list ;;
                *) return 1 ;;
            esac
            ;;
        *)
            local repo
            repo=$(tui_input "Repository recovery" \
                "'$pkg' is unavailable. Enter a complete APT deb repository line (blank skips):" "") || return 1
            [ -n "$repo" ] || return 1
            printf '%s\n' "$repo" >> /etc/apt/sources.list.d/systui-extra.list
            ;;
    esac
}

systui_repo_add_apk() { # <package>
    local pkg="$1" choice base release
    base=$(awk 'NF && $1 !~ /^#/ {print $1; exit}' /etc/apk/repositories 2>/dev/null)
    release=$(printf '%s' "$base" | sed -nE 's#(.*/(v[0-9]+\.[0-9]+|edge))/.*#\2#p')
    [ -n "$release" ] || release=edge
    base=$(printf '%s' "$base" | sed -E 's#/(main|community|testing)$##')
    choice=$(tui_menu "Repository recovery" \
        "'$pkg' is still unavailable. Enable another Alpine repository:" \
        community "Enable $release/community" \
        testing "Enable $release/testing" \
        custom "Add a custom APK repository" \
        skip "Skip") || return 1
    case "$choice" in
        community|testing) [ -n "$base" ] || return 1; printf '%s/%s\n' "$base" "$choice" >> /etc/apk/repositories ;;
        custom)
            local repo
            repo=$(tui_input "Custom APK repository" "Repository URL:" "") || return 1
            [ -n "$repo" ] || return 1
            printf '%s\n' "$repo" >> /etc/apk/repositories ;;
        *) return 1 ;;
    esac
}

systui_repo_add_rpm() { # <package>
    local pkg="$1" id choice repo
    id=$(systui_os_id)
    case "$id" in
        fedora)
            choice=$(tui_menu "Repository recovery" \
                "'$pkg' is still unavailable. Enable an additional Fedora repository:" \
                rpmfusion-free "Enable RPM Fusion Free" \
                rpmfusion-nonfree "Enable RPM Fusion Free + Nonfree" \
                custom "Add a custom DNF repository URL" \
                skip "Skip") || return 1
            case "$choice" in
                rpmfusion-free)
                    systui_pm_install_batch "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" ;;
                rpmfusion-nonfree)
                    systui_pm_install_batch \
                        "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
                        "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" ;;
                custom)
                    repo=$(tui_input "Custom DNF repository" "Repository/base URL:" "") || return 1
                    [ -n "$repo" ] || return 1
                    command -v dnf >/dev/null 2>&1 && dnf config-manager addrepo --from-repofile="$repo" || return 1 ;;
                *) return 1 ;;
            esac
            ;;
        *)
            repo=$(tui_input "Repository recovery" "'$pkg' is unavailable. Enter a repository URL (blank skips):" "") || return 1
            [ -n "$repo" ] || return 1
            case "${PM:-}" in
                dnf) dnf config-manager addrepo --from-repofile="$repo" ;;
                yum) yum-config-manager --add-repo "$repo" ;;
                *) return 1 ;;
            esac
            ;;
    esac
}

systui_offer_repository_for_package() { # <package>
    local pkg="$1" report answer
    report=$(systui_pkg_availability_report "$pkg")
    local tmp="${SYSTUI_TMP:-/tmp}/pkg-availability-$$.txt"
    {
        printf 'Package: %s\nHost package manager: %s\nDistribution: %s\n\nKnown Linux availability:\n%s\n' \
            "$pkg" "${PM:-unknown}" "$(systui_os_id)" "$report"
    } > "$tmp"
    tui_text "Package availability: $pkg" "$tmp"
    rm -f "$tmp"

    tui_yesno "Add repository?" \
        "'$pkg' was still not found after refreshing package indexes. Add/enable another repository and retry?" || return 1
    case "${PM:-}" in
        apt) systui_repo_add_apt "$pkg" ;;
        apk) systui_repo_add_apk "$pkg" ;;
        dnf|yum) systui_repo_add_rpm "$pkg" ;;
        zypper)
            local repo
            repo=$(tui_input "Add Zypper repository" "Repository URL for '$pkg' (blank skips):" "") || return 1
            [ -n "$repo" ] || return 1
            run_cmd "Add Zypper repository" zypper --non-interactive ar -f "$repo" "systui-extra-$(date +%s)" ;;
        xbps)
            local repo
            repo=$(tui_input "Add XBPS repository" "Repository URL for '$pkg' (blank skips):" "") || return 1
            [ -n "$repo" ] || return 1
            mkdir -p /etc/xbps.d
            printf 'repository=%s\n' "$repo" >> /etc/xbps.d/99-systui-extra.conf ;;
        pacman)
            tui_msg "Repository recovery" \
                "Arch packages not present in enabled repositories are commonly in the AUR rather than an official repository. Use System Configuration → Packages/Repositories to add a trusted repository or install via an AUR helper."
            return 1 ;;
        emerge)
            tui_msg "Repository recovery" \
                "Gentoo packages outside the main tree are normally provided by overlays. Use eselect repository or your overlay manager to add a trusted overlay, then retry."
            return 1 ;;
        *) return 1 ;;
    esac
}

# Final package-install entrypoint. Deliberately does not call the previously
# wrapped pm_install because that implementation performs per-package fallback
# immediately after the first failed batch; this layer owns the retry order.
pm_install() {
    validate_packages "$@" || return 1
    local multi=0 pkg
    [ "$#" -gt 1 ] && multi=1
    local -a requested=("$@") missing=() after_repo=() unresolved=()

    # One command for the entire selection.
    if systui_pm_install_batch "${requested[@]}"; then
        return 0
    fi

    # Refresh once, then retry the full unresolved set in one command.
    systui_pm_refresh_indexes || true
    mapfile -t missing < <(systui_missing_packages "${requested[@]}")
    [ "${#missing[@]}" -eq 0 ] && return 0
    systui_pm_install_batch "${missing[@]}" || true

    mapfile -t missing < <(systui_missing_packages "${requested[@]}")
    [ "${#missing[@]}" -eq 0 ] && return 0

    # Analyze and offer repository recovery per unresolved package. We only add
    # repositories here; installation is deferred so all packages can still be
    # retried together in one command after the choices are complete.
    for pkg in "${missing[@]}"; do
        systui_offer_repository_for_package "$pkg" || true
    done

    systui_pm_refresh_indexes || true
    mapfile -t after_repo < <(systui_missing_packages "${requested[@]}")
    [ "${#after_repo[@]}" -eq 0 ] && return 0
    systui_pm_install_batch "${after_repo[@]}" || true

    mapfile -t unresolved < <(systui_missing_packages "${requested[@]}")
    [ "${#unresolved[@]}" -eq 0 ] && return 0

    # Bedrock is a final managed fallback. It is intentionally tried only after
    # the host's own repositories and repository recovery have been exhausted.
    if declare -F bedrock_sysconfig_install_fallback >/dev/null 2>&1; then
        local -a still=()
        for pkg in "${unresolved[@]}"; do
            bedrock_sysconfig_install_fallback "$pkg" || still+=("$pkg")
        done
        unresolved=("${still[@]}")
    fi

    [ "${#unresolved[@]}" -eq 0 ] && return 0

    if [ "$multi" -eq 1 ]; then
        tui_msg "Packages skipped" \
            "These packages could not be located after refresh/repository recovery and were skipped:\n\n${unresolved[*]}"
        return 0
    fi

    tui_msg "Package unavailable" \
        "'${unresolved[0]}' could not be located after refreshing indexes and repository recovery. Returning to the previous menu."
    return 1
}

return 0 2>/dev/null || true
