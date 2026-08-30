# shellcheck shell=bash
# PHASE 85 — full Bedrock strata capability integration.
# When Bedrock is installed, inspect every stratum and surface discovered
# package managers/configuration paths directly in Systui's Packages menu.

BEDROCK_SYSTUI_CAP_CACHE=${BEDROCK_SYSTUI_CAP_CACHE:-/bedrock/etc/systui-strata-capabilities.cache}

bedrock_systui_is_installed() {
    [ -d /bedrock/strata ] && declare -F bedrock_aok_brl >/dev/null 2>&1 && bedrock_aok_brl >/dev/null 2>&1
}

bedrock_systui_strata() {
    local p
    [ -d /bedrock/strata ] || return 0
    for p in /bedrock/strata/*; do
        [ -d "$p" ] || continue
        case "${p##*/}" in .*|bedrock) continue ;; esac
        printf '%s\n' "${p##*/}"
    done | LC_ALL=C sort -u
}

bedrock_systui_stratum_root() { printf '/bedrock/strata/%s\n' "$1"; }

bedrock_systui_has_cmd() { # <stratum> <command>
    local root cmd p
    root=$(bedrock_systui_stratum_root "$1")
    cmd="$2"
    for p in bin sbin usr/bin usr/sbin usr/local/bin usr/local/sbin nix/var/nix/profiles/default/bin; do
        [ -x "$root/$p/$cmd" ] && return 0
    done
    return 1
}

bedrock_systui_pm_config_path() { # <stratum> <manager>
    local st="$1" pm="$2" root
    root=$(bedrock_systui_stratum_root "$st")
    case "$pm" in
        apt) [ -e "$root/etc/apt/apt.conf" ] && printf '/etc/apt/apt.conf\n' || printf '/etc/apt/sources.list\n' ;;
        nala) printf '/etc/nala/nala.conf\n' ;;
        apk) printf '/etc/apk/repositories\n' ;;
        pacman) printf '/etc/pacman.conf\n' ;;
        dnf) printf '/etc/dnf/dnf.conf\n' ;;
        yum) printf '/etc/yum.conf\n' ;;
        zypper) printf '/etc/zypp/zypper.conf\n' ;;
        xbps) printf '/etc/xbps.d/00-repository-main.conf\n' ;;
        emerge) printf '/etc/portage/make.conf\n' ;;
        opkg) printf '/etc/opkg/opkg.conf\n' ;;
        nix) printf '/etc/nix/nix.conf\n' ;;
        flatpak) printf '/var/lib/flatpak/repo/config\n' ;;
        pip|pip3) printf '/etc/pip.conf\n' ;;
        npm) printf '/etc/npmrc\n' ;;
        yarn) printf '/etc/yarnrc\n' ;;
        pnpm) printf '/etc/pnpmrc\n' ;;
        cargo) printf '/root/.cargo/config.toml\n' ;;
        gem) printf '/etc/gemrc\n' ;;
        composer) printf '/root/.config/composer/config.json\n' ;;
        *) return 1 ;;
    esac
}

bedrock_systui_manager_rows_for() { # <stratum> -> stratum|manager|class|config
    local st="$1" pm cfg
    for pm in apt nala apk pacman dnf yum zypper xbps emerge opkg nix flatpak pip3 pip npm yarn pnpm cargo gem composer; do
        bedrock_systui_has_cmd "$st" "$pm" || continue
        cfg=$(bedrock_systui_pm_config_path "$st" "$pm" 2>/dev/null || true)
        case "$pm" in
            apt|nala|apk|pacman|dnf|yum|zypper|xbps|emerge|opkg|nix) printf '%s|%s|system|%s\n' "$st" "$pm" "$cfg" ;;
            *) printf '%s|%s|secondary|%s\n' "$st" "$pm" "$cfg" ;;
        esac
    done
}

bedrock_systui_scan_capabilities() {
    local tmp st
    bedrock_systui_is_installed || return 1
    mkdir -p "${BEDROCK_SYSTUI_CAP_CACHE%/*}" || return 1
    tmp=$(mktemp "${SYSTUI_TMP:-${TMPDIR:-/tmp}}/bedrock-caps.XXXXXX") || return 1
    {
        printf '# schema=1\n'
        printf '# stratum|manager|class|config\n'
        while IFS= read -r st; do
            [ -n "$st" ] || continue
            bedrock_systui_manager_rows_for "$st"
        done <<< "$(bedrock_systui_strata)"
    } > "$tmp"
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$BEDROCK_SYSTUI_CAP_CACHE"
}

bedrock_systui_capability_rows() {
    bedrock_systui_is_installed || return 0
    [ -r "$BEDROCK_SYSTUI_CAP_CACHE" ] || bedrock_systui_scan_capabilities >/dev/null 2>&1 || true
    grep -Ev '^[[:space:]]*(#|$)' "$BEDROCK_SYSTUI_CAP_CACHE" 2>/dev/null || true
}

bedrock_systui_exec() { # <stratum> <command-string>
    local st="$1" cmd="$2" brl
    brl=$(bedrock_aok_brl) || return 1
    "$brl" strat -r "$st" /bin/sh -lc "$cmd"
}

bedrock_systui_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"
}

bedrock_systui_install_command() { # <manager> <validated package list>
    local pm="$1" pkgs="$2"
    case "$pm" in
        apt) printf 'apt-get install -y -- %s\n' "$pkgs" ;;
        nala) printf 'nala install -y %s\n' "$pkgs" ;;
        apk) printf 'apk add -- %s\n' "$pkgs" ;;
        pacman) printf 'pacman -S --noconfirm --needed -- %s\n' "$pkgs" ;;
        dnf) printf 'dnf install -y -- %s\n' "$pkgs" ;;
        yum) printf 'yum install -y -- %s\n' "$pkgs" ;;
        zypper) printf 'zypper --non-interactive install -- %s\n' "$pkgs" ;;
        xbps) printf 'xbps-install -Sy -- %s\n' "$pkgs" ;;
        emerge) printf 'emerge --ask=n %s\n' "$pkgs" ;;
        opkg) printf 'opkg install %s\n' "$pkgs" ;;
        nix) printf 'nix profile install %s\n' "$pkgs" ;;
        flatpak) printf 'flatpak install -y %s\n' "$pkgs" ;;
        pip|pip3) printf '%s install %s\n' "$pm" "$pkgs" ;;
        npm) printf 'npm install -g %s\n' "$pkgs" ;;
        yarn) printf 'yarn global add %s\n' "$pkgs" ;;
        pnpm) printf 'pnpm add -g %s\n' "$pkgs" ;;
        cargo) printf 'cargo install %s\n' "$pkgs" ;;
        gem) printf 'gem install %s\n' "$pkgs" ;;
        composer) printf 'composer global require %s\n' "$pkgs" ;;
        *) return 1 ;;
    esac
}

bedrock_systui_valid_packages() {
    local p
    [ -n "${1//[[:space:]]/}" ] || return 1
    for p in $1; do
        case "$p" in *[!A-Za-z0-9+._:@/=-]*|'') return 1 ;; esac
    done
}

bedrock_systui_edit_config() { # <stratum> <manager> <config-path>
    local st="$1" pm="$2" cfg="$3" root file
    [ -n "$cfg" ] || { tui_msg "Bedrock config" "No known config path for $pm in $st."; return 1; }
    root=$(bedrock_systui_stratum_root "$st")
    file="$root$cfg"
    mkdir -p "${file%/*}" || return 1
    [ -e "$file" ] || : > "$file"
    if declare -F safe_edit >/dev/null 2>&1; then safe_edit "$file"; else "${EDITOR:-vi}" "$file"; fi
}

bedrock_systui_manager_menu() { # <stratum> <manager> <class> <config>
    local st="$1" pm="$2" class="$3" cfg="$4" c pkgs cmd out
    while true; do
        c=$(tui_menu "Bedrock: $st [$pm]" "Detected in stratum '$st' ($class manager)." \
            install "Install package(s) with $pm" \
            config "View/edit $pm configuration" \
            shell "Open shell in $st" \
            refresh "Rescan all Bedrock strata" \
            back "Back") || return 0
        case "$c" in
            install)
                pkgs=$(tui_input "Install via $st/$pm" "Package names:" "") || continue
                bedrock_systui_valid_packages "$pkgs" || { tui_msg "Invalid packages" "Use package-name tokens only."; continue; }
                cmd=$(bedrock_systui_install_command "$pm" "$pkgs") || { tui_msg "Unsupported" "No install mapping for $pm."; continue; }
                run_cmd "Install in Bedrock stratum $st via $pm" bedrock_systui_exec "$st" "$cmd" || true
                ;;
            config)
                if [ -n "$cfg" ] && [ -r "$(bedrock_systui_stratum_root "$st")$cfg" ]; then
                    c=$(tui_menu "$st/$pm config" "Path: $cfg" view "View config" edit "Edit config" back "Back") || continue
                    case "$c" in
                        view)
                            out="${SYSTUI_TMP:?}/bedrock-config-${st}-${pm}"
                            cp "$(bedrock_systui_stratum_root "$st")$cfg" "$out" 2>/dev/null || printf '(not present)\n' > "$out"
                            tui_text "$st/$pm config" "$out"
                            ;;
                        edit) bedrock_systui_edit_config "$st" "$pm" "$cfg" ;;
                    esac
                else
                    bedrock_systui_edit_config "$st" "$pm" "$cfg"
                fi
                ;;
            shell)
                clear
                bedrock_systui_exec "$st" 'exec ${SHELL:-/bin/sh}' || true
                ;;
            refresh) bedrock_systui_scan_capabilities && tui_msg "Bedrock integration" "Strata capabilities rescanned." ;;
            back|'') return 0 ;;
        esac
    done
}

bedrock_systui_integrated_packages_menu() {
    local c row st pm class cfg key
    local -a opts=()
    bedrock_systui_scan_capabilities >/dev/null 2>&1 || true
    opts+=(native "Host package/config menus [${PM:-unknown}]")
    while IFS='|' read -r st pm class cfg; do
        [ -n "$st" ] && [ -n "$pm" ] || continue
        key="br_${st}_${pm}"
        key=${key//[^A-Za-z0-9_]/_}
        opts+=("$key" "$st → $pm [$class]")
    done <<< "$(bedrock_systui_capability_rows)"
    opts+=(rescan "Rescan Bedrock strata capabilities" back "Back")

    while true; do
        c=$(tui_menu "Packages — host + Bedrock" "Bedrock is installed; package managers discovered in strata are integrated below." "${opts[@]}") || return 0
        case "$c" in
            native) _systui_packages_before_bedrock_full_integration ;;
            rescan)
                bedrock_systui_scan_capabilities && tui_msg "Bedrock integration" "Strata capabilities rescanned. Reopen Packages to refresh the list."
                ;;
            back|'') return 0 ;;
            br_*)
                while IFS='|' read -r st pm class cfg; do
                    key="br_${st}_${pm}"; key=${key//[^A-Za-z0-9_]/_}
                    [ "$key" = "$c" ] || continue
                    bedrock_systui_manager_menu "$st" "$pm" "$class" "$cfg"
                    break
                done <<< "$(bedrock_systui_capability_rows)"
                ;;
        esac
    done
}

# Final Packages front door: Bedrock integration is automatic only when Bedrock
# is actually installed; otherwise retain the native Systui package UI exactly.
if declare -F menu_packages >/dev/null 2>&1 && ! declare -F _systui_packages_before_bedrock_full_integration >/dev/null 2>&1; then
    eval "$(declare -f menu_packages | sed '1s/^menu_packages[[:space:]]*()/_systui_packages_before_bedrock_full_integration ()/')"
fi
menu_packages() {
    if bedrock_systui_is_installed; then
        bedrock_systui_integrated_packages_menu
    else
        _systui_packages_before_bedrock_full_integration
    fi
}

# Rebuild capability cache after Bedrock finalization/install when possible.
if declare -F bedrock_aok_compat_finalize >/dev/null 2>&1 && ! declare -F _bedrock_aok_compat_finalize_before_full_integration >/dev/null 2>&1; then
    eval "$(declare -f bedrock_aok_compat_finalize | sed '1s/^bedrock_aok_compat_finalize[[:space:]]*()/_bedrock_aok_compat_finalize_before_full_integration ()/')"
    bedrock_aok_compat_finalize() {
        _bedrock_aok_compat_finalize_before_full_integration "$@"
        bedrock_systui_scan_capabilities >/dev/null 2>&1 || true
    }
fi

return 0 2>/dev/null || true
