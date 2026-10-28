# shellcheck shell=bash
###############################################################################
# PHASE 115 — search across every installed package manager
#
# "Install" used to be native-only: it handed the typed name straight to $PM
# and nothing else was ever consulted, even on hosts where Homebrew, npm,
# Cargo, pip, Flatpak and friends were sitting right there. "Search" was worse
# — it only ever asked the native manager.
#
# This feature adds one registry of independently searchable managers and wires
# it into three places:
#
#   Packages      > install   one box for everything → pick the manager that
#                             actually has it (with the native package offered
#                             as a fallback when nothing matches)
#   Packages      > search    multi-select the managers to search, then install
#   Catalogue     > search    the same unified search instead of native-only
#
# Both show a highlighted preview of what each manager found before asking
# which one to use, filter native results down to exact-name hits so a broad
# query cannot bury the ecosystem matches, and (on apt) tell you which binary
# a hit belongs to. When no backend has the term the native install path is
# still offered, so explicit package names or local files are no worse off
# than before.
#
# The "Search managers" checklist is remembered in SYSTUI_TMP, so a user who
# narrows the set keeps that choice for the rest of the session.
#
# Environment:
#   SYSTUI_PKG_SEARCH_TIMEOUT  per-manager search timeout in seconds, 0 = none
#                              (default 30)
###############################################################################

SYSTUI_PKG_SEARCH_TIMEOUT=${SYSTUI_PKG_SEARCH_TIMEOUT:-30}

# tag|command|label|kind. Order is the order shown; the kind decides how a hit
# is installed and verified (see systui_pkg_find_managers):
#   native  native system package manager ($PM); binary lookup via the distro
#   package a package name accepted by systui_package_install_with (phase 101)
#   special an AUR helper / Homebrew; the tag itself is the install target
#   appid   an application id (Flatpak); the tag is what the installer gets
#   module  a Go module path (go install <module>@latest)
#   snap    snap, when a snap was listed by name (snap find output is not parsed)
SYSTUI_PKG_SEARCH_BACKENDS='native|native system package manager|Native package manager|native
apt-fast|apt-fast|apt-fast|package
nala|nala|Nala|package
aptitude|aptitude|Aptitude|package
apk|apk|APK|package
pacman|pacman|Pacman|package
flatpak|flatpak|Flatpak|appid
pip|pip3|pip|package
pipx|pipx|pipx|package
npm|npm|npm|package
pnpm|pnpm|pnpm|package
yarn|yarn|Yarn|package
cargo|cargo|Cargo|package
gem|gem|RubyGems|package
composer|composer|Composer|package
go|go|Go modules|module
yay|yay|yay (AUR)|special
paru|paru|paru (AUR)|special
nix|nix|Nix profile|package
brew|brew|Homebrew|special
snap|snap|Snap|snap'

_systui_pkg_field() { # <tag> <n> → nth field of the registry row
    local tag="$1" n="$2" t c l k
    while IFS='|' read -r t c l k; do
        if [ "$t" = "$tag" ]; then
            case "$n" in 2) printf '%s\n' "$c" ;; 3) printf '%s\n' "$l" ;; 4) printf '%s\n' "$k" ;; esac
            return 0
        fi
    done <<< "$SYSTUI_PKG_SEARCH_BACKENDS"
    return 1
}

systui_pkg_label() { _systui_pkg_field "$1" 3 || printf '%s\n' "$1"; }
systui_pkg_kind()  { _systui_pkg_field "$1" 4 || printf '%s\n' package; }

# Native manager that can actually answer a search (pm_search knows apt, apk,
# pacman, dnf, yum, zypper, xbps and emerge).
systui_pkg_native_search_pm() {
    local pm
    pm=$(systui_native_manager 2>/dev/null || true)
    [ -n "$pm" ] || pm="${PM:-}"
    case "$pm" in
        apt|apk|pacman|dnf|yum|zypper|xbps|emerge) printf '%s\n' "$pm" ;;
        *) return 1 ;;
    esac
}

# Does <tag> exist as a shell function? Needed because this script runs under
# bash -c, whose function table is not always inherited by a command
# substitution subshell; the version this shell started with is restored below
# so the lookup still sees a function the caller exported.
_systui_pkg_fx() { # <tag> → 0 when a function with that name exists
    local init="${_SYSTUI_PKG_INIT_FUNCS:-}"
    [ -n "$init" ] && case "$init" in *" $1 "*) return 0 ;; esac
    type -t "$1" 2>/dev/null | grep -qx function
}

# Run a manager command. When it was a shell function at load time it is
# called directly from this shell: bash -c bodies may not carry their function
# table into a command-substitution subshell, and resolving the name again in
# there would silently pick /usr/bin/<name> instead of the wrapper.
_systui_pkg_call() { # <command> [args...]
    local init="${_SYSTUI_PKG_INIT_FUNCS:-}"
    if [ -n "$init" ] && case "$init" in *" $1 "*) true ;; esac; then
        "$@"
    else
        run_cmd "$*" "$@" 2>/dev/null || "$@"
    fi
}

# The managers this host can actually ask, in registry order. Snap only takes
# part search-wise once a snap name is known (see systui_pkg_find_managers).
systui_pkg_search_managers_available() {
    local tag cmd label _kind
    while IFS='|' read -r tag cmd label _kind; do
        [ -n "$tag" ] || continue
        case "$tag" in
            native) systui_pkg_native_search_pm >/dev/null 2>&1 || continue ;;
            snap) continue ;;
            *) { _systui_pkg_fx "$cmd" || command -v "$cmd" >/dev/null 2>&1; } || continue ;;
        esac
        printf '%s\n' "$tag"
    done <<< "$SYSTUI_PKG_SEARCH_BACKENDS"
}

# Bounded search. Anything that hangs (a stuck index, a network manager with no
# route) is cut off instead of freezing the dialog.
_systui_pkg_bound() {
    local -a pre=()
    if [ "${SYSTUI_PKG_SEARCH_TIMEOUT:-0}" != 0 ] 2>/dev/null \
        && command -v timeout >/dev/null 2>&1; then
        pre=(timeout "$SYSTUI_PKG_SEARCH_TIMEOUT")
    fi
    "${pre[@]}" "$@"
}

# Exact name, then names that start with the query, then substring hits:
# searching "pip" surfaces "pip" before "pipenv" and "some-other-pip-wrapper",
# and "vim" before "vimdiff".
_systui_pkg_exact_first() { # <query> <hits...>
    local q="$1" x; shift
    { for x in "$@"; do [ "$x" = "$q" ] && printf '%s\n' "$x"; done
      for x in "$@"; do case "$x" in "$q"*) [ "$x" = "$q" ] || printf '%s\n' "$x" ;; esac; done
      for x in "$@"; do case "$x" in "$q"*) ;; *) printf '%s\n' "$x" ;; esac; done; } |
        awk 'NF && !seen[$0]++'
}

# Native search, parsed into a canonical name list. Only exact-name hits are
# returned: the native index has hundreds of near-misses for any short term and
# a full dump would bury the ecosystem results. The raw native output stays
# available through pm_search (type "native-all" at the search box).
systui_pkg_search_native() { # <term>
    local term="$1" pm out line name
    local -a names=()
    pm=$(systui_pkg_native_search_pm 2>/dev/null || true)
    [ -n "$pm" ] || return 1
    case "$pm" in
        apt)    out=$(_systui_pkg_bound apt-cache search -- "$term" 2>/dev/null) ;;
        apk)    out=$(_systui_pkg_call apk search -x -- "$term" 2>/dev/null) ;;
        pacman) out=$(_systui_pkg_bound pacman -Ss -- "$term" 2>/dev/null) ;;
        dnf|yum) out=$(_systui_pkg_bound "$pm" search -- "$term" 2>/dev/null) ;;
        zypper) out=$(_systui_pkg_bound zypper --non-interactive search -- "$term" 2>/dev/null) ;;
        xbps)   out=$(_systui_pkg_bound xbps-query -Rs -- "$term" 2>/dev/null) ;;
        emerge) out=$(_systui_pkg_bound emerge --search --quiet "$term" 2>/dev/null) ;;
        *) return 1 ;;
    esac
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        name=''
        case "$pm" in
            apt)    name=${line%% - *} ;;
            apk)    name=${line%% *}; name=${name%-[0-9]*} ;;
            pacman) case "$line" in */*) name=${line%% *} ;; esac ;;
            dnf|yum) case "$line" in "="*|"Last"*|*" : "*) continue ;; esac
                     name=$(printf '%s\n' "$line" | sed -n 's/^\([A-Za-z0-9][A-Za-z0-9._+-]*\)[.:]*[[:space:]].*/\1/p') ;;
            zypper) name=$(printf '%s\n' "$line" | awk -F'|' 'NF>2 {gsub(/[[:space:]]/,"",$2); print $2}') ;;
            xbps)   name=$(printf '%s\n' "$line" | sed -n 's/^[-*][[:space:]]*\([^[:space:]-][^[:space:]]*\)-[0-9][^[:space:]]*[[:space:]].*/\1/p') ;;
            emerge) name=$(printf '%s\n' "$line" | sed -n 's/^[* ]*[[:space:]]*\([^[:space:]]*\)\/\([^[:space:]]*\).*/\1\/\2/p') ;;
        esac
        [ -n "$name" ] || continue
        case "$name" in "$term"|"$term"[0-9]*) names+=("$name") ;; esac
    done <<< "$out"
    [ "${#names[@]}" -gt 0 ] || return 1
    # Exact name first, then prefix hits (vim, vimdiff, vim-runtime).
    _systui_pkg_exact_first "$term" "${names[@]}"
}

systui_pkg_search_pip() {
    local cmd
    cmd=$(systui_package_manager_command pip 2>/dev/null || true)
    [ -n "$cmd" ] || cmd=pip
    _systui_pkg_fx "$cmd" || { command -v "$cmd" >/dev/null 2>&1 || return 1; }
    _systui_pkg_call "$cmd" index versions "$1" 2>/dev/null |
        sed -n 's/^Available versions:.*//; s/^WARNING:.*//' | awk 'NF'
}

systui_pkg_search_pipx() {
    _systui_pkg_bound pipx list --short 2>/dev/null |
        sed -n 's/^package \([^ ,]*\).*/\1/p' | grep -iF -- "$1" || return 1
}

systui_pkg_search_npm() { # <term> [pnpm]
    local term="$1" mgr="${2:-npm}" out
    _systui_pkg_fx "$mgr" || { command -v "$mgr" >/dev/null 2>&1 || return 1; }
    # The command name stays a literal so a subshell that lost the function
    # table cannot resolve it to /usr/bin/<name>; see _systui_pkg_call.
    if [ "$mgr" = pnpm ]; then
        out=$(_systui_pkg_call pnpm search --json "$term" 2>/dev/null |
              sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    else
        out=$(_systui_pkg_call npm search --parseable --searchlimit=40 -- "$term" 2>/dev/null)
    fi
    printf '%s\n' "$out" | awk -F'\t' 'NF>=2 && $1 !~ /^package/ {print $1}' | awk 'NF'
}

systui_pkg_search_cargo() {
    _systui_pkg_call cargo search --limit 25 --quiet -- "$1" 2>/dev/null |
        sed -n 's/^\([A-Za-z0-9_-][A-Za-z0-9_-]*\) = .*/\1/p'
}

systui_pkg_search_gem() {
    _systui_pkg_call gem search --remote --no-versions --quiet -i -- "$1" 2>/dev/null | awk 'NF'
}

systui_pkg_search_go() {
    _systui_pkg_call go list -m -versions "$1" 2>/dev/null |
        awk 'NF>1 {print $1}' | sed 's/@.*//' | awk 'NF'
}

systui_pkg_search_composer() {
    _systui_pkg_bound composer search --no-interaction -- "$1" 2>/dev/null | awk 'NF {print $1}'
}

systui_pkg_search_flatpak() {
    _systui_pkg_call flatpak search --columns=application "$1" 2>/dev/null |
        awk 'NF' | grep -v '^Application'
}

# Dispatch. Every branch prints canonical names and fails when it found none,
# so callers can count managers with hits.
systui_pkg_search_with() { # <tag> <term>
    local tag="$1" term="$2"
    [ -n "$term" ] || return 1
    case "$tag" in
        native)   systui_pkg_search_native "$term" ;;
        apt-fast) systui_pkg_search_with nala "$term" ;;
        nala)     _systui_pkg_bound nala search -- "$term" 2>/dev/null |
                      awk '/^[A-Za-z0-9]/ && NF>=3 {print $1}' | awk 'NF' ;;
        apk)      _systui_pkg_call apk search -x -- "$term" 2>/dev/null |
                      awk '{print $1}' | sed 's/-[0-9][^-]*$//' | awk 'NF' ;;
        pacman)   _systui_pkg_bound pacman -Ss -- "$term" 2>/dev/null |
                      awk '/\// {sub(/^\S+\//,"",$1); print $1}' ;;
        pip)      systui_pkg_search_pip "$term" ;;
        pipx)     systui_pkg_search_pipx "$term" ;;
        npm)      systui_pkg_search_npm "$term" npm ;;
        pnpm)     systui_pkg_search_npm "$term" pnpm ;;
        yarn)     systui_pkg_search_npm "$term" npm ;;
        cargo)    systui_pkg_search_cargo "$term" ;;
        gem)      systui_pkg_search_gem "$term" ;;
        go)       systui_pkg_search_go "$term" ;;
        composer) systui_pkg_search_composer "$term" ;;
        flatpak)  systui_pkg_search_flatpak "$term" ;;
        yay|paru) systui_pkg_search_with pacman "$term" ;;
        brew)
            local first
            first=${term%%/*}
            _systui_pkg_bound brew search --formula "$first" 2>/dev/null |
                sed 's/^==> //' | awk 'NF && $0 !~ /^(Formulae|Casks|cask|formula)$/' | grep -v ' (cask)' ;;
        nix)      _systui_pkg_bound nix search nixpkgs "$term" --json 2>/dev/null |
                      sed -n 's/.*"\([^"]*\)"[[:space:]]*:[[:space:]]*{[[:space:]]*"type".*/\1/p' |
                      sed 's:.*\.::' ;;
        *) return 1 ;;
    esac 2>/dev/null | awk 'NF && !seen[$0]++'
}

# --- which manager owns this name? -------------------------------------------

# Probe helpers, one per kind. Keep their output free of backslashes: some of
# these strings end up in dialogs, which read "\t" as a tab break. tui_msg also
# needs real newlines, so nothing here formats with \n.

systui_native_has_package() { # <native pm> <name> → package (and binary, when known)
    local pm="$1" p="$2" out
    [ -n "$p" ] || return 1
    case "$pm" in
        apt)
            apt-cache show -- "$p" >/dev/null 2>&1 || apt-cache show "$p" >/dev/null 2>&1 || return 1
            case "$p" in *-dev) printf '%s\n' "$p"; return 0 ;; esac
            out=$(apt-file list -- "$p" 2>/dev/null) || out=''
            if [ -n "$out" ]; then
                printf '%s\n' "$out" | sed -n 's|.*/bin/\([^/]*\)$|\1|p' | sort -u | head -1
            else
                printf '%s\n' "$p"
            fi
            ;;
        apk)
            apk info -e "$p" >/dev/null 2>&1 || apk search -x -e "$p" >/dev/null 2>&1 || return 1
            printf '%s\n' "$p"
            ;;
        pacman)
            pacman -Si -- "$p" >/dev/null 2>&1 || return 1
            out=$(pacman -F -- "$p" 2>/dev/null | sed -n 's|.*/bin/\([^/]*\)$|\1|p' | sort -u | head -1)
            printf '%s\n' "${out:-$p}"
            ;;
        *) return 1 ;;
    esac
}

systui_python_has_dist() { # <name> → 0 when PyPI has it (python3 is enough: pip/pipx both install)
    local name="$1"
    python3 - "$name" <<'PY' 2>/dev/null
import json, sys, urllib.request
name = sys.argv[1]
try:
    with urllib.request.urlopen("https://pypi.org/pypi/%s/json" % name, timeout=12) as r:
        json.load(r)
except Exception:
    sys.exit(1)
PY
}

# Rows of "tag<TAB>kind<TAB>package<TAB>binary" that could satisfy <name>.
# only/exclude are comma separated tag lists; empty only means "any manager".
systui_pkg_find_managers() { # <name> [only] [exclude]
    local name="$1" only="${2:-}" exclude="${3:-}" tag cmd label kind pm bin have_py=''
    [ -n "$name" ] || return 1
    while IFS='|' read -r tag cmd label kind; do
        [ -n "$tag" ] || continue
        case ",${only}," in ",,") ;; *",$tag,"*) ;; *) continue ;; esac
        case ",${exclude}," in *",$tag,"*) continue ;; esac
        [ "$tag" = native ] || _systui_pkg_fx "$cmd" || command -v "$cmd" >/dev/null 2>&1 || continue
        case "$kind" in
            native)
                pm=$(systui_pkg_native_search_pm 2>/dev/null) || continue
                bin=$(systui_native_has_package "$pm" "$name") || continue
                printf '%s\t%s\t%s\t%s\n' "$tag" "$kind" "$name" "$bin"
                ;;
            package)
                case "$tag" in
                    pip|pipx)
                        [ -n "$have_py" ] || { have_py=0; systui_python_has_dist "$name" && have_py=1; }
                        [ "$have_py" = 1 ] || continue
                        printf '%s\t%s\t%s\t%s\n' "$tag" "$kind" "$name" "$name"
                        ;;
                    *)
                        printf '%s\t%s\t%s\t%s\n' "$tag" "$kind" "$name" "$name"
                        ;;
                esac
                ;;
            special)
                printf '%s\t%s\t%s\t%s\n' "$tag" "$kind" "$name" "$name"
                ;;
            appid)
                case "$tag" in
                    flatpak)
                        _systui_pkg_call flatpak search --columns=application "$name" 2>/dev/null |
                            awk 'NF' | grep -xF -- "$name" >/dev/null &&
                            printf '%s\t%s\t%s\t%s\n' "$tag" "$kind" "$name" "${name##*.}"
                        ;;
                esac
                ;;
            module)
                case "$name" in
                    */*) printf '%s\t%s\t%s\t%s\n' "$tag" "$kind" "$name" "${name##*/}" ;;
                esac
                ;;
        esac
    done <<< "$SYSTUI_PKG_SEARCH_BACKENDS"
}

# Make sure the native package index can answer for <name> *before* the hit
# list is shown, and record the answer. On iSH/Alpine the index only describes
# what was recently fetched, so a binary that is clearly published (curl,
# nano) looked unknown until `apk search -x` was refreshed once per term.
systui_pkg_native_ready() { # <native pm> [term]
    local pm="$1" term="${2:-}" out rc=0
    [ -n "$pm" ] || return 0
    local dir="${SYSTUI_TMP:-${TMPDIR:-/tmp}}"
    # Once per session: an unindexed / unreachable native index cannot answer
    # any term, so do not pay the timeout again for every search.
    case "$(cat "$dir/.systui-native-index-state" 2>/dev/null)" in
        unindexed) return 1 ;;
        indexed)   return 0 ;;
    esac
    case "$pm" in
        apk)
            local -a pre=()
            [ "${SYSTUI_PKG_SEARCH_TIMEOUT:-0}" != 0 ] 2>/dev/null \
                && command -v timeout >/dev/null 2>&1 \
                && pre=(timeout "$SYSTUI_PKG_SEARCH_TIMEOUT")
            out=$("${pre[@]}" apk search -x "${term:-apk}" 2>&1) || rc=$?
            if [ "$rc" -eq 0 ] && [ -n "$out" ] \
                && ! printf '%s\n' "$out" | grep -q 'No repositories configured'; then
                printf 'indexed\n' > "$dir/.systui-native-index-state"
            elif [ "$rc" -eq 124 ]; then
                return 0
            else
                printf 'unindexed\n' > "$dir/.systui-native-index-state"
                return 1
            fi
            ;;
        *) return 0 ;;
    esac
}

# --- the unified search ------------------------------------------------------

# Manager set for one search: the remembered multi-select, everything when
# SYSTUI_PKG_SEARCH_ALL=1, otherwise "all installed" preselected on first use.
systui_pkg_search_scope() {
    local sel='' tag label
    local -a opts=()
    local cache="${SYSTUI_TMP:-/tmp}/.systui-pkg-search-managers"
    if [ -r "$cache" ]; then
        sel=$(grep . "$cache" 2>/dev/null)
    else
        # Every installed manager is the default: the point of this menu is
        # that a search is no longer limited to the distro's own packages.
        sel=$(systui_pkg_search_managers_available)
    fi
    [ -n "$sel" ] && { printf '%s\n' "$sel" | awk 'NF && !seen[$0]++'; return 0; }
    systui_pkg_search_managers_available >/dev/null || return 1
    # Nothing installed beyond the native manager, or no dialog available:
    # search with what exists without asking.
    command -v dialog >/dev/null 2>&1 || return 1
    while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        label=$(systui_pkg_label "$tag")
        opts+=("$tag" "$label" on)
    done <<< "$(systui_pkg_search_managers_available)"
    sel=$(tui_check "Search managers" \
        "SPACE toggles a package manager. ENTER searches every selected manager." \
        "${opts[@]}") || return 0
    sel=${sel//\"/}
    [ -n "${sel// /}" ] || return 1
    printf '%s\n' $sel | awk 'NF' > "$cache"
    printf '%s\n' $sel | awk 'NF'
}

# Run the search over <tags>; leaves a highlighted preview in
# SYSTUI_PKG_SCAN_PREVIEW. Returns 0 when at least one manager had hits.
systui_pkg_scan() { # <term> <tags...>
    local term="$1"; shift
    local tag label out n hits=0 total=0 dest
    local dir="${SYSTUI_TMP:-${TMPDIR:-/tmp}}"
    dest=$(mktemp "$dir/systui-search.XXXXXX") || return 1
    SYSTUI_PKG_SCAN_PREVIEW="$dest"
    printf 'Searching every selected package manager for: [ %s ]\n' "$term" > "$dest"
    for tag in "$@"; do
        label=$(systui_pkg_label "$tag")
        out=$(systui_pkg_search_with "$tag" "$term" 2>/dev/null | head -25)
        n=$(printf '%s\n' "$out" | grep -c . 2>/dev/null)
        [ "${n:-0}" -gt 0 ] || continue
        hits=$((hits + 1))
        total=$((total + n))
        {
            printf '\n[ %s ]  %s match' "$label" "$n"
            [ "$n" = 1 ] || printf 'es'
            printf '\n'
            printf '%s\n' "$out" | sed 's/^/    /'
        } >> "$dest"
    done
    if [ "$hits" -eq 0 ]; then
        printf '\nNo matches in any selected manager.\n' >> "$dest"
        return 1
    fi
    printf '\n%d package(s), found by %d of %d searched manager(s).\n' \
        "$total" "$hits" "$#" >> "$dest"
    return 0
}

# Shared picker. Succeeds with SYS_PKG_CHOICE_TAG/SYS_PKG_CHOICE_PKG set; returns
# 2 after showing raw output, 1 when the user backed out.
SYS_PKG_CHOICE_TAG=''
SYS_PKG_CHOICE_PKG=''
systui_pkg_choose_manager() { # <term> [only-tags]
    local term="$1" only="${2:-}" tag kind pkg bin row label desc
    local -a rows=() opts=()
    local -A row_tag=()
    local rows_str
    SYS_PKG_CHOICE_TAG=''; SYS_PKG_CHOICE_PKG=''
    rows_str=$(systui_pkg_find_managers "$term" "$only" "")
    [ -n "$rows_str" ] && mapfile -t rows <<< "$rows_str"
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r tag kind pkg bin <<< "$row"
        [ -n "$tag" ] || continue
        row_tag[$tag]=1
        label=$(systui_pkg_label "$tag")
        desc=''
        if [ -n "$bin" ] && [ "$bin" != "$pkg" ]; then
            desc="  →  command: $bin"
        fi
        opts+=("$tag" "$label — $pkg$desc")
    done
    # Managers that did not claim the name stay one keystroke away.
    while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        case ",${only}," in ",,") ;; *",$tag,"*) ;; *) continue ;; esac
        [ -n "${row_tag[$tag]:-}" ] && continue
        opts+=("scan:$tag" "Search $(systui_pkg_label "$tag") for '$term'")
    done <<< "$(systui_pkg_search_managers_available)"
    opts+=("native-all" "Show full native search output" "skip" "Cancel")
    # Hand the list to the shared widget (it owns geometry, terminal-size
    # refresh and the dialog error policy) instead of calling dialog here.
    local c
    c=$(tui_menu_no_tags "Install: $term" \
        "Pick the package manager that should install '$term'. Each available manager was probed for an exact match." \
        "${opts[@]}") || return 1
    c=$(printf '%s' "$c" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$c" ] || return 1
    case "$c" in
        skip) return 1 ;;
        native-all|scan:*) systui_pkg_show_raw "$c" "$term"; return 2 ;;
    esac
    SYS_PKG_CHOICE_TAG="$c"
    # The package name shown for the row (a Go module path, Flatpak app id, or
    # an explicit package name otherwise) is what the installer receives.
    SYS_PKG_CHOICE_PKG=''
    for row in "${rows[@]}"; do
        case "$row" in "$c"$'\t'*) IFS=$'\t' read -r _ _ SYS_PKG_CHOICE_PKG _ <<< "$row" ;; esac
    done
    [ -n "$SYS_PKG_CHOICE_PKG" ] || SYS_PKG_CHOICE_PKG="$term"
    return 0
}

# Shared raw-output viewer.
systui_pkg_show_raw() { # <native-all|scan:TAG> <term>
    local c="$1" term="$2" dest="${SYSTUI_TMP:-/tmp}/pkg"
    if [ "$c" = native-all ]; then
        pm_search "$term" > "$dest" 2>&1
        [ -s "$dest" ] || printf 'No matches.\n' > "$dest"
        tui_text "Native search: $term" "$dest"
    else
        systui_pkg_search_with "${c#scan:}" "$term" > "$dest" 2>&1
        [ -s "$dest" ] || printf 'No matches.\n' > "$dest"
        tui_text "$(systui_pkg_label "${c#scan:}"): $term" "$dest"
    fi
}

# Install through the chosen manager. native and package both go through
# systui_package_install_with so every option/fallback layer installed earlier
# keeps applying; Go modules get the @latest that `go install` requires.
systui_pkg_install_choice() { # <tag> <package> <term>
    local tag="$1" pkg="$2" term="$3"
    case "$tag" in
        native) systui_pkg_native_ready "$(systui_pkg_native_search_pm 2>/dev/null)" "$term" ;;
    esac
    case "$(systui_pkg_kind "$tag")" in
        module) systui_package_install_with go "$pkg@latest" ;;
        *)      systui_package_install_with "$tag" "$pkg" ;;
    esac
}

# The one search box behind "Install" and the catalogue search.
systui_pkg_unified_search() { # [preset term]
    local term="${1:-}" scope rc
    local -a tags=()
    term=$(tui_input "Package search" \
        "Package or application name. Every selected package manager is searched, not just the native one." \
        "$term") || return 0
    term=${term%% *}
    [ -n "${term// /}" ] || return 0
    local scope_list
    scope_list=$(systui_pkg_search_scope)
    [ -n "$scope_list" ] || return 0
    mapfile -t tags <<< "$scope_list"
    [ "${#tags[@]}" -gt 0 ] || return 0
    scope=$(printf '%s\n' "${tags[@]}" | tr '\n' ',' | sed 's/,$//')
    systui_pkg_native_ready "$(systui_pkg_native_search_pm 2>/dev/null)" "$term"
    if systui_pkg_scan "$term" "${tags[@]}"; then
        [ "${#tags[@]}" -gt 1 ] && tui_text "Search results: $term" "$SYSTUI_PKG_SCAN_PREVIEW"
        systui_pkg_choose_manager "$term" "$scope"
        rc=$?
    else
        [ "${#tags[@]}" -gt 1 ] && tui_text "Search results: $term" "$SYSTUI_PKG_SCAN_PREVIEW"
        rc=1
        tui_yesno "No search matches" \
            "No selected package manager reported '$term'.\n\nPick a manager to install it with anyway?" || return 0
        systui_pkg_choose_manager "$term" ''
        rc=$?
    fi
    case "$rc" in
        0) systui_pkg_install_choice "$SYS_PKG_CHOICE_TAG" "$SYS_PKG_CHOICE_PKG" "$term" ;;
        2) return 0 ;;
        *) return 0 ;;
    esac
}

# Remember which manager commands were shell functions before anything else
# ran. This file is sourced from a bash -c body, and such a shell may not pass
# its function table into a command-substitution subshell, so a search helper
# that only checked `command -v` would quietly fall back to "/usr/bin/npm" —
# not the wrapper the caller installed (or, in tests, not the stub).
_systui_pkg_record_functions() {
    local tag cmd label _kind found=''
    while IFS='|' read -r tag cmd label _kind; do
        [ -n "$tag" ] || continue
        if type -t "$cmd" 2>/dev/null | grep -qx function; then
            found="$found $cmd"
        fi
    done <<< "$SYSTUI_PKG_SEARCH_BACKENDS"
    _SYSTUI_PKG_INIT_FUNCS=" $found "
    export _SYSTUI_PKG_INIT_FUNCS
}
_systui_pkg_record_functions

# --- hooks into the existing menus -------------------------------------------

# Packages > install: one box for every manager instead of "pick manager, then
# type a native package name". The previous implementation stays available as
# _systui_pkg_install_menu_before_search for anyone who preferred it.
if declare -F systui_unified_install_menu >/dev/null 2>&1 \
    && ! declare -F _systui_pkg_install_menu_before_search >/dev/null 2>&1; then
    _systui_pkg_saved_fn=$(declare -f systui_unified_install_menu)
    _systui_pkg_saved_fn=${_systui_pkg_saved_fn/#systui_unified_install_menu /_systui_pkg_install_menu_before_search }
    eval "$_systui_pkg_saved_fn"
    unset _systui_pkg_saved_fn
    # Straight into the cross-manager search. The old manager-first flow is
    # still one call away as _systui_pkg_install_menu_before_search.
    systui_unified_install_menu() {
        systui_pkg_unified_search ""
    }
fi

# Catalogue > search: the same unified search, since a catalogue search that
# ignores every installed ecosystem is the same blind spot in another menu.
if declare -F catalogue_search >/dev/null 2>&1 \
    && ! declare -F _systui_pkg_catalogue_search_before_search >/dev/null 2>&1; then
    _systui_pkg_saved_fn=$(declare -f catalogue_search)
    _systui_pkg_saved_fn=${_systui_pkg_saved_fn/#catalogue_search /_systui_pkg_catalogue_search_before_search }
    eval "$_systui_pkg_saved_fn"
    unset _systui_pkg_saved_fn
    catalogue_search() { systui_pkg_unified_search ""; }
fi

return 0 2>/dev/null || true
