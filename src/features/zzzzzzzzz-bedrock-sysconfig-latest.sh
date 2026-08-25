# shellcheck shell=bash
# Automatic Bedrock package-source selection for System Configuration.
# Loaded after the base Bedrock/sysconfig integration so it replaces the
# interactive stratum chooser with an all-strata newest-version resolver.

# Query the repository candidate version for one package in one stratum.
# Prints the raw repository version string, or nothing if unavailable.
bedrock_sysconfig_pkg_version() { # <stratum> <package>
    local st="$1" pkg="$2" pm brl q cmd
    bedrock_sysconfig_active || return 1
    brl=$(bedrock_aok_brl) || return 1
    pm=$(bedrock_sysconfig_stratum_pm "$st")
    q=$(bedrock_sysconfig_sh_quote "$pkg")

    case "$pm" in
        apt)
            cmd="apt-cache policy $q 2>/dev/null | awk '/Candidate:/ {print \\$2; exit}'"
            ;;
        apk)
            # apk search -x -v prints name-version. Strip the exact package
            # prefix so hyphens inside package names are preserved.
            cmd="apk search -x -v $q 2>/dev/null | head -1 | sed 's/^${pkg}-//' | awk '{print \\$1}'"
            ;;
        pacman)
            cmd="pacman -Si $q 2>/dev/null | awk -F': *' '/^Version/ {print \\$2; exit}'"
            ;;
        dnf)
            cmd="dnf -q --showduplicates list $q 2>/dev/null | awk -v p=$q '\\$1 ~ (\"^\" p \"([.]|$)\") {print \\$2}' | sort -V | tail -1"
            ;;
        yum)
            cmd="yum -q --showduplicates list $q 2>/dev/null | awk -v p=$q '\\$1 ~ (\"^\" p \"([.]|$)\") {print \\$2}' | sort -V | tail -1"
            ;;
        zypper)
            cmd="zypper --non-interactive --no-refresh info $q 2>/dev/null | awk -F': *' '/^Version[[:space:]]*:/ {print \\$2; exit}'"
            ;;
        xbps)
            cmd="xbps-query -Rs $q 2>/dev/null | awk -v p=$q '\\$2 ~ (\"^\" p \"-\") {v=\\$2; sub(\"^\" p \"-\",\"\",v); print v}' | sort -V | tail -1"
            ;;
        emerge)
            # Portage output varies across versions; prefer equery when present,
            # otherwise parse the first explicit version token from --search.
            cmd="if command -v equery >/dev/null 2>&1; then equery -q list -po $q 2>/dev/null | sed 's/^[^/]*\\///' | sed 's/^${pkg}-//' | sort -V | tail -1; else emerge --search $q 2>/dev/null | awk '/^\\*  [^ ]+\\/'\"$pkg\"'-/ {x=\\$2; sub(/^.*\\/'\"$pkg\"'-/,\"\",x); print x; exit}'; fi"
            ;;
        opkg)
            cmd="opkg list $q 2>/dev/null | awk -F' - ' -v p=$q '\\$1==p {print \\$2}' | sort -V | tail -1"
            ;;
        *) return 1 ;;
    esac

    "$brl" strat -r "$st" /bin/sh -lc "$cmd" 2>/dev/null | head -1
}

# Produce every valid candidate as:
#   version<TAB>stratum<TAB>package-manager
bedrock_sysconfig_package_candidates() { # <package>
    local pkg="$1" st pm ver
    while IFS= read -r st; do
        [ -n "$st" ] || continue
        pm=$(bedrock_sysconfig_stratum_pm "$st")
        [ "$pm" != unknown ] || continue
        ver=$(bedrock_sysconfig_pkg_version "$st" "$pkg" 2>/dev/null || true)
        [ -n "$ver" ] || continue
        [ "$ver" != "(none)" ] || continue
        printf '%s\t%s\t%s\n' "$ver" "$st" "$pm"
    done < <(bedrock_sysconfig_strata)
}

# Select the highest version reported across all strata. GNU/BusyBox sort -V
# is used where available; a stable lexical fallback keeps behavior deterministic
# on unusual minimal systems without version-sort support.
bedrock_sysconfig_best_source() { # <package> => stratum|pm|version
    local pkg="$1" rows best
    rows=$(bedrock_sysconfig_package_candidates "$pkg")
    [ -n "$rows" ] || return 1

    if printf '1.9\n1.10\n' | sort -V >/dev/null 2>&1; then
        best=$(printf '%s\n' "$rows" | LC_ALL=C sort -t $'\t' -k1,1V -k2,2 | tail -1)
    else
        best=$(printf '%s\n' "$rows" | LC_ALL=C sort -t $'\t' -k1,1 -k2,2 | tail -1)
    fi

    [ -n "$best" ] || return 1
    local ver st pm
    IFS=$'\t' read -r ver st pm <<< "$best"
    printf '%s|%s|%s\n' "$st" "$pm" "$ver"
}

# Replace the interactive fallback. Every installed stratum is checked and the
# package is installed automatically from whichever advertises the newest
# candidate version.
bedrock_sysconfig_install_fallback() { # <package>
    local pkg="$1" brl best st pm ver
    bedrock_sysconfig_active || return 1
    brl=$(bedrock_aok_brl) || return 1

    best=$(bedrock_sysconfig_best_source "$pkg") || return 1
    IFS='|' read -r st pm ver <<< "$best"
    [ -n "$st" ] && [ -n "$ver" ] || return 1

    run_cmd "Install $pkg $ver from Bedrock stratum $st [$pm]" \
        "$brl" install "$st" "$pkg" || return 1

    # Make the chosen source immediately participate in the unified system.
    "$brl" enable "$st" >/dev/null 2>&1 || true
    run_cmd "Refresh Bedrock unified command PATH" "$brl" reload || true
    return 0
}

return 0 2>/dev/null || true
