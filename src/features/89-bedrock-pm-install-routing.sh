# shellcheck shell=bash
# PHASE 89 — final pm_install Bedrock routing.
#
# Phase 88 adds target selection to menu_*_install entry points.  This phase
# covers installation actions that call pm_install directly (package
# operations, fail2ban, VNC, future menus) and ensures an already-selected host
# target does not prompt twice.

systui_bedrock_quote_words() { # args...
    local out='' x q
    for x in "$@"; do
        printf -v q '%q' "$x"
        out+="${out:+ }$q"
    done
    printf '%s\n' "$out"
}

systui_bedrock_pm_install_raw() { # <stratum> <packages...>
    local st="$1" pm cmd words p
    shift
    [ "$#" -gt 0 ] || return 1
    pm=$(systui_bedrock_stratum_pm "$st" 2>/dev/null || true)
    [ -n "$pm" ] || {
        tui_msg "Install unavailable" "No supported package manager was detected in Bedrock stratum '$st'."
        return 1
    }

    if [ "$pm" = nix ]; then
        local -a refs=()
        for p in "$@"; do
            case "$p" in nixpkgs#*) refs+=("$p") ;; *) refs+=("nixpkgs#$p") ;; esac
        done
        words=$(systui_bedrock_quote_words "${refs[@]}")
        cmd="nix profile install $words"
    else
        words=$(systui_bedrock_quote_words "$@")
        case "$pm" in
            apt) cmd="DEBIAN_FRONTEND=noninteractive apt-get install -y -- $words" ;;
            apk) cmd="apk add -- $words" ;;
            pacman) cmd="pacman -S --noconfirm --needed -- $words" ;;
            dnf) cmd="dnf install -y -- $words" ;;
            yum) cmd="yum install -y -- $words" ;;
            zypper) cmd="zypper --non-interactive install -- $words" ;;
            xbps) cmd="xbps-install -Sy -- $words" ;;
            emerge) cmd="emerge --ask=n $words" ;;
            opkg) cmd="opkg install $words" ;;
            *) return 1 ;;
        esac
    fi

    if run_cmd "Install in Bedrock stratum $st [$pm]: $*" systui_bedrock_exec_stratum "$st" "$cmd"; then
        declare -F bedrock_systui_scan_capabilities >/dev/null 2>&1 \
            && bedrock_systui_scan_capabilities >/dev/null 2>&1 || true
        return 0
    fi
    return 1
}

# Preserve the final native pm_install implementation from all earlier audit
# and recovery layers.
if declare -F pm_install >/dev/null 2>&1 \
    && ! declare -F _systui_pm_install_before_bedrock_targets >/dev/null 2>&1; then
    eval "$(declare -f pm_install | sed '1s/^pm_install[[:space:]]*()/_systui_pm_install_before_bedrock_targets ()/')"
fi

pm_install() {
    local target="${SYSTUI_INSTALL_TARGET:-}"

    # No Bedrock: preserve existing behavior byte-for-byte at the function
    # boundary.  Explicit host targeting also bypasses the picker.
    if ! systui_bedrock_install_active 2>/dev/null; then
        _systui_pm_install_before_bedrock_targets "$@"
        return
    fi

    if [ -z "$target" ]; then
        target=$(systui_bedrock_install_target_menu "packages") || return 0
    fi

    case "$target" in
        host|'') _systui_pm_install_before_bedrock_targets "$@" ;;
        stratum:*) systui_bedrock_pm_install_raw "${target#stratum:}" "$@" ;;
        *)
            tui_msg "Invalid install target" "Unknown installation target: $target"
            return 1
            ;;
    esac
}

# Rebuild phase-88 wrappers so a target selected at the menu entry point is
# carried into any nested pm_install call.  Stratum selections still bypass
# host-only vendor/source installer code and use the native stratum package
# manager directly.
systui_bedrock_rebind_install_wrappers() {
    local fn saved canonical
    while read -r _ fn; do
        case "$fn" in menu_*_install) ;; *) continue ;; esac
        case "$fn" in menu_bedrock_*|menu_rootfs_*|_*) continue ;; esac
        saved="_systui_bedrock_target_original_${fn}"
        declare -F "$saved" >/dev/null 2>&1 || continue
        canonical=${fn#menu_}; canonical=${canonical%_install}
        eval "$fn() { local _target; if ! systui_bedrock_install_active; then SYSTUI_INSTALL_TARGET=host $saved \"\$@\"; return; fi; _target=\$(systui_bedrock_install_target_menu '$canonical') || return 0; case \"\$_target\" in host|'') SYSTUI_INSTALL_TARGET=host $saved \"\$@\" ;; stratum:*) systui_bedrock_install_canonical \"\${_target#stratum:}\" '$canonical' ;; esac; }"
    done < <(declare -F)
}
systui_bedrock_rebind_install_wrappers

# Carry the chosen target through the package-manager multi-install host path
# as well, preventing pm_install from prompting a second time.
if declare -F _systui_bedrock_target_original_sysconfig_pm_multi_install >/dev/null 2>&1; then
    sysconfig_pm_multi_install() {
        local target
        if ! systui_bedrock_install_active; then
            SYSTUI_INSTALL_TARGET=host _systui_bedrock_target_original_sysconfig_pm_multi_install "$@"
            return
        fi
        target=$(systui_bedrock_install_target_menu "package managers") || return 0
        case "$target" in
            host|'') SYSTUI_INSTALL_TARGET=host _systui_bedrock_target_original_sysconfig_pm_multi_install "$@" ;;
            stratum:*) systui_bedrock_stratum_multi_pm_install "${target#stratum:}" ;;
        esac
    }
fi

return 0 2>/dev/null || true
