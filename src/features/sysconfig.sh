# shellcheck shell=bash
# PART 2 — SYSTEM CONFIGURATION (current system)
###############################################################################

# ---- Environment detection -------------------------------------------------
# Package-manager and init detection are provided by src/core/config.sh.
# Keep local fallbacks for standalone sourcing and support every advertised PM.
PM="${PM:-}"; INIT="${INIT:-}"
if ! declare -F detect_pm >/dev/null 2>&1; then
    detect_pm() {
        if command -v apt-get >/dev/null 2>&1; then PM=apt
        elif command -v apk >/dev/null 2>&1; then PM=apk
        elif command -v pacman >/dev/null 2>&1; then PM=pacman
        elif command -v dnf >/dev/null 2>&1; then PM=dnf
        elif command -v yum >/dev/null 2>&1; then PM=yum
        elif command -v zypper >/dev/null 2>&1; then PM=zypper
        elif command -v xbps-install >/dev/null 2>&1; then PM=xbps
        elif command -v emerge >/dev/null 2>&1; then PM=emerge
        else PM=unknown; fi
        export PM
    }
fi
if ! declare -F detect_init >/dev/null 2>&1; then
    detect_init() {
        if [ -d /run/systemd/system ]; then INIT=systemd
        elif command -v rc-service >/dev/null 2>&1; then INIT=openrc
        elif [ -d /etc/runit ] || [ -d /run/runit ]; then INIT=runit
        elif [ -f /etc/inittab ]; then INIT=sysvinit
        else INIT=unknown; fi
        export INIT
    }
fi

st() { command -v "$1" >/dev/null 2>&1 && echo "[installed]" || echo ""; }
stp() { [ -e "$1" ] && echo "[installed]" || echo ""; }

valid_safe_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; }
valid_username() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,31}$ ]] && getent passwd "$1" >/dev/null 2>&1; }
valid_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
valid_pkg_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9+._:@%/~=-]*$ ]]; }
validate_packages() {
    local p
    [ "$#" -gt 0 ] || return 1
    for p in "$@"; do
        valid_pkg_name "$p" || { tui_msg "Invalid package" "Unsafe or invalid package name: $p"; return 1; }
    done
}
parse_package_input() { # <string> <array-name>
    local input="$1" out_name="$2" p
    local -a parsed=()
    read -r -a parsed <<< "$input"
    [ "${#parsed[@]}" -gt 0 ] || return 1
    validate_packages "${parsed[@]}" || return 1
    eval "$out_name=(\"\${parsed[@]}\")"
}

pm_install() {
    validate_packages "$@" || return 1
    local _pm_rc=0
    case "$PM" in
        apt) run_cmd "apt install $*" apt-get install -y -- "$@"; _pm_rc=$? ;;
        apk) run_cmd "apk add $*" apk add -- "$@"; _pm_rc=$? ;;
        pacman) run_cmd "pacman -S $*" pacman -S --noconfirm --needed -- "$@"; _pm_rc=$? ;;
        dnf) run_cmd "dnf install $*" dnf install -y -- "$@"; _pm_rc=$? ;;
        yum) run_cmd "yum install $*" yum install -y -- "$@"; _pm_rc=$? ;;
        zypper) run_cmd "zypper install $*" zypper --non-interactive install -- "$@"; _pm_rc=$? ;;
        xbps) run_cmd "xbps-install $*" xbps-install -Sy -- "$@"; _pm_rc=$? ;;
        emerge) run_cmd "emerge $*" emerge --ask=n -- "$@"; _pm_rc=$? ;;
        *) tui_msg "Error" "No supported package manager found."; return 1 ;;
    esac

    # Universal fallback: if the native package manager failed, automatically
    # scan every cross-distribution package index systui knows about (Debian,
    # Ubuntu/Launchpad, Kali, Devuan, Alpine, Arch, Fedora, openSUSE, Gentoo,
    # Void) for each package still missing, and offer to force-install a .deb
    # (with dependencies resolved) wherever one is found. This makes the
    # fallback apply to every install path in systui, since pm_install is the
    # single install entrypoint used throughout the project. Set
    # SYSTUI_PM_NO_WEB_FALLBACK=1 to skip this for silent/bulk probing loops.
    if [ "$_pm_rc" -ne 0 ] && [ "${SYSTUI_PM_NO_WEB_FALLBACK:-0}" != "1" ] \
        && declare -F pkg_web_fallback >/dev/null 2>&1; then
        local _pm_pkg
        for _pm_pkg in "$@"; do
            command -v "$_pm_pkg" >/dev/null 2>&1 && continue
            { command -v dpkg >/dev/null 2>&1 && dpkg -s "$_pm_pkg" >/dev/null 2>&1; } && continue
            pkg_web_fallback "$_pm_pkg"
        done
    fi

    return "$_pm_rc"
}

# Fetch plain text from a URL using curl or wget (IPv4-forced, silent).
_sys_fetch_text() { # <url>
    if command -v curl >/dev/null 2>&1; then
        curl -4 -LfsS --connect-timeout 8 --max-time 60 "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -4 -qO- -T 60 "$1"
    else
        return 127
    fi
}

# pkg_web_search <pkgname>
# Query repology.org for the package and return a newline-separated list of
# "repo: reponame | pkg: pkgname" lines. Prints nothing on network error.
pkg_web_search() {
    local name="$1"
    local url="https://repology.org/api/v1/project/${name}"
    local json
    json=$(_sys_fetch_text "$url" 2>/dev/null) || return 0
    # Parse JSON with only POSIX tools — extract repo and srcname fields.
    printf '%s\n' "$json" | tr '},{' '\n' \
        | awk '/"repo"/ && /"srcname"/ {
            repo=""; pkg=""
            match($0,/"repo": *"([^"]+)"/); if (RSTART) repo=substr($0,RSTART+7,RLENGTH-8)
            match($0,/"srcname": *"([^"]+)"/); if (RSTART) pkg=substr($0,RSTART+10,RLENGTH-11)
            if (!pkg) { match($0,/"binname": *"([^"]+)"/); if (RSTART) pkg=substr($0,RSTART+10,RLENGTH-11) }
            if (repo && pkg) printf "  %-28s %s\n", repo":", pkg
        }' | sort -u | head -30
}

# pkg_web_fallback <pkgname>
# Called when a package is not available via the native PM. Searches repology
# and every cross-distribution package index systui knows about (Debian,
# Ubuntu/Launchpad, Kali, Devuan, Alpine, Arch, Fedora, openSUSE, Gentoo,
# Void), offering to force-install a matching .deb (with dependencies
# resolved) wherever one is found — this is the same engine the rootfs
# bootstrap-tools menu uses, so it's shared across every install path in
# systui. Falls back to manual rename/custom-command entry if nothing helps.
pkg_web_fallback() {
    local name="$1"
    tui_msg "Package not found" "'$name' was not found in the $PM repository.\n\nSearching repology.org and cross-distribution package indexes…"

    local results
    results=$(pkg_web_search "$name")
    if [ -z "$results" ]; then
        results="(No results found — check your internet connection or try a different name)"
    fi

    local tmpf="${SYSTUI_TMP}/pkgweb_$$.txt"
    printf 'Alternative package names found on repology.org for: %s\n\n%s\n' "$name" "$results" > "$tmpf"
    tui_text "Web search: $name" "$tmpf"
    rm -f "$tmpf"

    local -a menu_opts=()
    if declare -F _rootfs_bs_known_repos >/dev/null 2>&1; then
        menu_opts+=(indexes "Scan all package indexes (Debian/Ubuntu/Kali/Devuan/Alpine/Arch/Fedora/openSUSE/Gentoo/Void)")
    fi
    menu_opts+=(rename "Try a different package name with $PM")
    menu_opts+=(cmd    "Run a custom install command")
    menu_opts+=(back   "Back / skip")

    local action
    action=$(tui_menu "Install alternatives" "How would you like to proceed?" "${menu_opts[@]}") || return 1

    case "$action" in
        indexes)
            _rootfs_bs_known_repos "$name"
            ;;
        rename)
            local alt
            alt=$(tui_input "Alternative package name" "Enter the package name to try with $PM:" "$name") || return 1
            [ -z "$alt" ] && return 1
            pm_install "$alt"
            ;;
        cmd)
            local icmd
            icmd=$(tui_input "Custom install command" "Shell command to install $name:" "") || return 1
            [ -z "$icmd" ] && return 1
            run_cmd "Custom install: $name" bash -c "$icmd"
            ;;
        back|"") return 1 ;;
    esac
}
pm_remove() {
    validate_packages "$@" || return 1
    case "$PM" in
        apt) run_cmd "apt remove $*" apt-get remove -y -- "$@" ;;
        apk) run_cmd "apk del $*" apk del -- "$@" ;;
        pacman) run_cmd "pacman -R $*" pacman -Rns --noconfirm -- "$@" ;;
        dnf) run_cmd "dnf remove $*" dnf remove -y -- "$@" ;;
        yum) run_cmd "yum remove $*" yum remove -y -- "$@" ;;
        zypper) run_cmd "zypper remove $*" zypper --non-interactive remove -- "$@" ;;
        xbps) run_cmd "xbps-remove $*" xbps-remove -Ry -- "$@" ;;
        emerge) run_cmd "emerge unmerge $*" emerge --ask=n --unmerge "$@" ;;
        *) tui_msg "Error" "No supported package manager found."; return 1 ;;
    esac
}
pm_update() {
    case "$PM" in
        apt) run_cmd "apt update && upgrade" bash -o pipefail -c 'apt-get update && apt-get upgrade -y' ;;
        apk) run_cmd "apk upgrade" bash -o pipefail -c 'apk update && apk upgrade' ;;
        pacman) run_cmd "pacman -Syu" pacman -Syu --noconfirm ;;
        dnf) run_cmd "dnf upgrade" dnf upgrade -y ;;
        yum) run_cmd "yum update" yum update -y ;;
        zypper) run_cmd "zypper update" zypper --non-interactive refresh --force && run_cmd "zypper update" zypper --non-interactive update ;;
        xbps) run_cmd "xbps upgrade" xbps-install -Suy ;;
        emerge) run_cmd "Portage sync/update" emerge --sync && emerge --ask=n --update --deep --newuse @world ;;
        *) return 1 ;;
    esac
}
pm_search() {
    case "$PM" in
        apt) apt-cache search -- "$1" ;; apk) apk search -v -- "$1" ;; pacman) pacman -Ss -- "$1" ;;
        dnf) dnf search -- "$1" ;; yum) yum search -- "$1" ;; zypper) zypper search -- "$1" ;;
        xbps) xbps-query -Rs -- "$1" ;; emerge) emerge --search "$1" ;;
    esac
}
pm_clean() {
    case "$PM" in
        apt) run_cmd "apt clean + autoremove" bash -o pipefail -c 'apt-get autoremove -y && apt-get clean' ;;
        apk) run_cmd "apk cache clean" sh -c 'apk cache clean 2>/dev/null || rm -rf /var/cache/apk/*' ;;
        pacman) run_cmd "pacman cache clean" sh -c 'pacman -Sc --noconfirm; orphans=$(pacman -Qtdq 2>/dev/null || true); [ -z "$orphans" ] || pacman -Rns --noconfirm -- $orphans' ;;
        dnf) run_cmd "dnf clean + autoremove" sh -c 'dnf autoremove -y && dnf clean all' ;;
        yum) run_cmd "yum clean" yum clean all ;;
        zypper) run_cmd "zypper clean" zypper clean --all ;;
        xbps) run_cmd "xbps clean" xbps-remove -Ooy ;;
        emerge) run_cmd "Portage depclean" emerge --ask=n --depclean ;;
    esac
}
local_pkg_map() {
    case "$PM" in
        apk) map_packages alpine "$@" ;; pacman) map_packages arch "$@" ;;
        dnf|yum|zypper) map_packages fedora "$@" ;; xbps) map_packages void "$@" ;;
        *) printf '%s\n' "$*" ;;
    esac
}

safe_edit() {
    local file="$1" editor_spec="${EDITOR:-nano}"; shift || true
    local -a editor_argv=()
    read -r -a editor_argv <<< "$editor_spec"
    [ "${#editor_argv[@]}" -gt 0 ] && command -v "${editor_argv[0]}" >/dev/null 2>&1 || editor_argv=(nano)
    "${editor_argv[@]}" "$file" "$@"
}
atomic_install_file() { # <source> <destination> [mode]
    local src="$1" dst="$2" mode="${3:-0644}" dir tmp
    dir=$(dirname "$dst"); mkdir -p "$dir"
    tmp=$(mktemp "$dir/.systui.XXXXXX") || return 1
    install -m "$mode" "$src" "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dst"
}
safe_template_expand() { # explicit variables only; never eval
    local value="$1"
    value=${value//\$ID/$ID}; value=${value//\$CODENAME/$CODENAME}; value=${value//\$ARCH/$ARCH}; value=${value//\$K/$K}
    printf '%s' "$value"
}
# ---- System scanner ---------------------------------------------------------
# Inventory of known software: "command|display name|category"
SW_INVENTORY="
bash|GNU Bash|Shells
zsh|Zsh|Shells
fish|Fish|Shells
nu|Nushell|Shells
starship|Starship prompt|Shells
dash|dash (Debian Almquist)|Shells
ksh|KornShell|Shells
mksh|MirBSD Korn shell|Shells
tcsh|tcsh (TENEX C shell)|Shells
elvish|Elvish|Shells
xonsh|xonsh|Shells
yash|yash|Shells
pwsh|PowerShell|Shells
nano|nano|Editors
vim|vim|Editors
nvim|Neovim|Editors
micro|micro|Editors
emacs|Emacs|Editors
sshd|OpenSSH server|Network
vncserver|TigerVNC|Network
x11vnc|x11vnc|Network
ufw|ufw firewall|Network
fail2ban-server|fail2ban|Network
nmap|nmap|Network
tcpdump|tcpdump|Network
git|Git|Development
gcc|GCC|Development
make|make|Development
cmake|CMake|Development
python3|Python 3|Development
pip3|pip|Development
node|Node.js|Development
docker|Docker|Development
htop|htop|Monitoring
iotop|iotop|Monitoring
ncdu|ncdu|Monitoring
strace|strace|Monitoring
smartctl|smartmontools|Monitoring
tmux|tmux|Utilities
rsync|rsync|Utilities
fzf|fzf|Utilities
rg|ripgrep|Utilities
jq|jq|Utilities
zstd|zstd|Utilities
flatpak|Flatpak|Packaging
snap|snapd|Packaging
apt-fast|apt-fast|Packaging
nala|nala|Packaging
debootstrap|debootstrap|Bootstrap
pacstrap|pacstrap|Bootstrap
"

scan_pkg_count() {
    case "$PM" in
        apt)    dpkg-query -W 2>/dev/null | wc -l ;;
        apk)    apk info 2>/dev/null | wc -l ;;
        pacman) pacman -Q 2>/dev/null | wc -l ;;
        dnf)    rpm -qa 2>/dev/null | wc -l ;;
        *)      echo "?" ;;
    esac
}

scan_full_report() {
    local rpt="${SYSTUI_TMP}/scan"
    {
        echo "==================================================================="
        echo " systui system scan — $(date '+%F %T')"
        echo "==================================================================="
        echo
        echo "--- System ---"
        if [ -r /etc/os-release ]; then . /etc/os-release; echo "OS        : ${PRETTY_NAME:-$NAME}"; fi
        echo "Kernel    : $(uname -r) ($(uname -m))"
        echo "Hostname  : $(hostname)"
        echo "Uptime    : $(uptime -p 2>/dev/null || uptime)"
        echo "Init      : $INIT"
        echo "Pkg mgr   : $PM ($(scan_pkg_count) packages installed)"
        echo
        echo "--- Hardware ---"
        echo "CPU       : $(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ //')"
        echo "Cores     : $(nproc)"
        awk '/MemTotal|MemAvailable|SwapTotal/{gsub(":","",$1); printf "%-10s: %.1f GiB\n", $1, $2/1048576}' /proc/meminfo
        echo
        echo "--- Storage ---"
        df -hT -x tmpfs -x devtmpfs 2>/dev/null || df -h
        echo
        echo "--- Software inventory ---"
        local line cmd name cat lastcat=""
        while IFS='|' read -r cmd name cat; do
            [ -z "$cmd" ] && continue
            [ "$cat" != "$lastcat" ] && { echo; echo "[$cat]"; lastcat="$cat"; }
            if command -v "$cmd" >/dev/null 2>&1; then
                printf "  [x] %-20s %s\n" "$name" "$(command -v "$cmd")"
            else
                printf "  [ ] %-20s not installed\n" "$name"
            fi
        done <<< "$SW_INVENTORY"
        echo
        echo "--- Shell frameworks (per-user) ---"
        local u h
        while IFS=: read -r u _ uid _ _ h _; do
            [ "$uid" -ge 1000 ] 2>/dev/null && [ "$uid" -lt 65534 ] || [ "$u" = root ] || continue
            [ -d "$h" ] || continue
            [ -d "$h/.oh-my-bash" ] && echo "  $u: oh-my-bash"
            [ -d "$h/.bash_it" ]    && echo "  $u: bash-it"
            [ -d "$h/.oh-my-zsh" ]  && echo "  $u: oh-my-zsh"
            [ -d "$h/.local/share/zinit" ] && echo "  $u: zinit"
            [ -f "$h/.config/starship.toml" ] && echo "  $u: starship config"
        done < /etc/passwd
        echo
        echo "--- Running services ---"
        case "$INIT" in
            systemd)  systemctl list-units --type=service --state=running --no-pager --no-legend | awk '{print "  "$1}' ;;
            openrc)   rc-status -a 2>/dev/null | grep started | awk '{print "  "$1}' ;;
            runit)    for s in /var/service/* /run/runit/service/*; do [ -d "$s" ] && echo "  $(basename "$s")"; done 2>/dev/null ;;
            sysvinit) service --status-all 2>&1 | grep '+' | awk '{print "  "$NF}' ;;
        esac
        echo
        echo "--- Listening ports ---"
        ss -tulnH 2>/dev/null | awk '{printf "  %-6s %s\n",$1,$5}' | sort -u
        echo
        echo "--- Enabled repositories ---"
        case "$PM" in
            apt)    grep -rh '^deb ' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | sed 's/^/  /'
                    grep -rh '^URIs' /etc/apt/sources.list.d/*.sources 2>/dev/null | sed 's/^/  /' ;;
            apk)    sed 's/^/  /' /etc/apk/repositories 2>/dev/null ;;
            pacman) grep '^\[' /etc/pacman.conf | grep -v options | sed 's/^/  /' ;;
            dnf)    dnf repolist --enabled 2>/dev/null | sed 's/^/  /' ;;
        esac
        echo
        echo "--- Human users ---"
        awk -F: '$3>=1000 && $3<65534 {printf "  %-16s uid=%-6s shell=%s\n",$1,$3,$7}' /etc/passwd
        echo
        echo "==================================================================="
    } > "$rpt" 2>&1
    echo "$rpt"
}

menu_scan_system() {
    while true; do
        local c
        c=$(tui_menu "Scan System" "System scans & reports:" \
            full     "Full system scan (everything)" \
            save     "Run full scan and SAVE report to a file" \
            hardware "Hardware scan (CPU, memory, storage)" \
            software "Software inventory (installed tools)" \
            netsvc   "Running services & listening ports" \
            back     "Back") || return 0
        case "$c" in
            full)
                local rpt; rpt=$(scan_full_report)
                tui_text "System scan" "$rpt" ;;
            save)
                local rpt out; rpt=$(scan_full_report)
                out=$(tui_input "Save report" "Save scan report to:" "/root/systui-scan-$(date +%Y%m%d-%H%M).txt") || continue
                cp "$rpt" "$out" && tui_msg "Saved" "Report written to:\n$out" ;;
            hardware)
                {
                    echo "--- CPU ---"
                    lscpu 2>/dev/null | grep -E 'Model name|^CPU\(s\)|MHz|Architecture|Virtualization' \
                        || awk -F: '/model name/{print $2; exit}' /proc/cpuinfo
                    echo; echo "--- Memory ---"
                    free -h
                    echo; echo "--- Storage ---"
                    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS 2>/dev/null || lsblk
                    echo; df -hT -x tmpfs -x devtmpfs 2>/dev/null || df -h
                    echo; echo "--- PCI (if available) ---"
                    lspci 2>/dev/null | head -25
                } > ${SYSTUI_TMP}/scan 2>&1
                tui_text "Hardware scan" ${SYSTUI_TMP}/scan ;;
            software)
                {
                    echo "Software inventory ($(scan_pkg_count) packages via $PM):"
                    local line cmd name cat lastcat=""
                    while IFS='|' read -r cmd name cat; do
                        [ -z "$cmd" ] && continue
                        [ "$cat" != "$lastcat" ] && { echo; echo "[$cat]"; lastcat="$cat"; }
                        if command -v "$cmd" >/dev/null 2>&1; then
                            printf "  [x] %-20s %s\n" "$name" "$(command -v "$cmd")"
                        else
                            printf "  [ ] %-20s not installed\n" "$name"
                        fi
                    done <<< "$SW_INVENTORY"
                } > ${SYSTUI_TMP}/scan 2>&1
                tui_text "Software inventory" ${SYSTUI_TMP}/scan ;;
            netsvc)
                {
                    echo "--- Running services ($INIT) ---"
                    case "$INIT" in
                        systemd)  systemctl list-units --type=service --state=running --no-pager --no-legend | awk '{print "  "$1}' ;;
                        openrc)   rc-status -a 2>/dev/null | grep started | awk '{print "  "$1}' ;;
                        runit)    for s in /var/service/* /run/runit/service/*; do [ -d "$s" ] && echo "  $(basename "$s")"; done 2>/dev/null ;;
                        sysvinit) service --status-all 2>&1 | grep '+' | awk '{print "  "$NF}' ;;
                    esac
                    echo; echo "--- Listening ports ---"
                    ss -tulnH 2>/dev/null | awk '{printf "  %-6s %s\n",$1,$5}' | sort -u
                } > ${SYSTUI_TMP}/scan 2>&1
                tui_text "Services & ports" ${SYSTUI_TMP}/scan ;;
            back) return 0 ;;
        esac
    done
}

menu_scan_queries() {
    while true; do
        local c
        c=$(tui_menu "Package & file queries" "Inspect installed files & packages:" \
            largest  "Largest installed packages" \
            recent   "Recently installed/upgraded packages" \
            owns     "Which package owns a file?" \
            files    "List files installed by a package" \
            findfile "Find a file by name (filesystem search)" \
            orphans  "Orphaned / auto-removable packages" \
            back     "Back") || return 0
        case "$c" in
            largest)
                case "$PM" in
                    apt)    dpkg-query -W -f='${Installed-Size}\t${Package}\n' 2>/dev/null \
                            | sort -rn | head -30 \
                            | awk -F'\t' '{printf "%8.1f MiB  %s\n",$1/1024,$2}' ;;
                    pacman) LC_ALL=C pacman -Qi 2>/dev/null \
                            | awk -F': *' '/^Name/{n=$2} /^Installed Size/{print $2"\t"n}' \
                            | sort -hr | head -30 | awk -F'\t' '{printf "%12s  %s\n",$1,$2}' ;;
                    dnf)    rpm -qa --queryformat '%{SIZE}\t%{NAME}\n' 2>/dev/null \
                            | sort -rn | head -30 \
                            | awk -F'\t' '{printf "%8.1f MiB  %s\n",$1/1048576,$2}' ;;
                    apk)    echo "apk does not track per-package sizes conveniently."
                            echo "Approximate: largest directories under /usr:"
                            du -sh /usr/* 2>/dev/null | sort -hr | head -20 ;;
                esac > ${SYSTUI_TMP}/scan 2>&1
                tui_text "Largest packages" ${SYSTUI_TMP}/scan ;;
            recent)
                case "$PM" in
                    apt)    { zgrep -h " install \| upgrade " /var/log/dpkg.log* 2>/dev/null \
                              || grep -h " install \| upgrade " /var/log/dpkg.log 2>/dev/null; } | tail -40 ;;
                    pacman) grep -E 'installed|upgraded' /var/log/pacman.log 2>/dev/null | tail -40 ;;
                    dnf)    dnf history 2>/dev/null | head -30 ;;
                    apk)    echo "apk does not keep an install-history log by default." ;;
                esac > ${SYSTUI_TMP}/scan 2>&1
                tui_text "Recent package activity" ${SYSTUI_TMP}/scan ;;
            owns)
                local f; f=$(tui_input "File owner" "File path (e.g. /usr/bin/vim):" "") || continue
                [ -z "$f" ] && continue
                case "$PM" in
                    apt)    dpkg -S "$f" ;;
                    apk)    apk info --who-owns "$f" ;;
                    pacman) pacman -Qo "$f" ;;
                    dnf)    rpm -qf "$f" ;;
                esac > ${SYSTUI_TMP}/scan 2>&1
                tui_text "Owner of $f" ${SYSTUI_TMP}/scan ;;
            files)
                local p; p=$(tui_input "Package files" "Package name:" "") || continue
                [ -z "$p" ] && continue
                case "$PM" in
                    apt)    dpkg -L "$p" ;;
                    apk)    apk info -L "$p" ;;
                    pacman) pacman -Ql "$p" ;;
                    dnf)    rpm -ql "$p" ;;
                esac > ${SYSTUI_TMP}/scan 2>&1
                tui_text "Files in $p" ${SYSTUI_TMP}/scan ;;
            findfile)
                local n d
                n=$(tui_input "Find file" "Filename or glob (e.g. sshd_config, *.conf):" "") || continue
                [ -z "$n" ] && continue
                d=$(tui_input "Find file" "Search under directory:" "/etc") || continue
                find "$d" -xdev -name "$n" 2>/dev/null | head -200 > ${SYSTUI_TMP}/scan
                [ -s ${SYSTUI_TMP}/scan ] || echo "(no matches)" > ${SYSTUI_TMP}/scan
                tui_text "find $d -name $n" ${SYSTUI_TMP}/scan ;;
            orphans)
                case "$PM" in
                    apt)    apt-get autoremove --dry-run 2>/dev/null | grep -E '^Remv|^  ' ;;
                    pacman) pacman -Qtdq 2>/dev/null || echo "(none)" ;;
                    dnf)    dnf repoquery --unneeded 2>/dev/null ;;
                    apk)    echo "apk removes orphans automatically with 'apk del'." ;;
                esac > ${SYSTUI_TMP}/scan 2>&1
                [ -s ${SYSTUI_TMP}/scan ] || echo "(none)" > ${SYSTUI_TMP}/scan
                tui_text "Orphaned packages" ${SYSTUI_TMP}/scan ;;
            back) return 0 ;;
        esac
    done
}

menu_scanner() {
    while true; do
        local c
        c=$(tui_menu "Scanner" "Inspect this machine:" \
            scan    "Scan System (full, hardware, software, services)" \
            queries "Package & file queries (owners, sizes, orphans...)" \
            back    "Back") || return 0
        case "$c" in
            scan)    menu_scan_system ;;
            queries) menu_scan_queries ;;
            back)    return ;;
        esac
    done
}

# ---- Repository management (v2: space-select everywhere) --------------------

# Popular third-party repos, per PM. apt format:
#   tag|Description|key_url|keyfmt(asc=dearmor,bin=raw)|repo line ($K=keyring,$CODENAME,$ARCH,$ID)
APT_POPULAR="docker|Docker CE (containers)|https://download.docker.com/linux/\$ID/gpg|asc|deb [arch=\$ARCH signed-by=\$K] https://download.docker.com/linux/\$ID \$CODENAME stable
vscode|Visual Studio Code|https://packages.microsoft.com/keys/microsoft.asc|asc|deb [arch=amd64,arm64,armhf signed-by=\$K] https://packages.microsoft.com/repos/code stable main
chrome|Google Chrome|https://dl.google.com/linux/linux_signing_key.pub|asc|deb [arch=amd64 signed-by=\$K] https://dl.google.com/linux/chrome/deb/ stable main
mozilla|Mozilla (Firefox .deb, no snap)|https://packages.mozilla.org/apt/repo-signing-key.gpg|asc|deb [signed-by=\$K] https://packages.mozilla.org/apt mozilla main
postgres|PostgreSQL (PGDG)|https://www.postgresql.org/media/keys/ACCC4CF8.asc|asc|deb [signed-by=\$K] https://apt.postgresql.org/pub/repos/apt \$CODENAME-pgdg main
tailscale|Tailscale VPN|https://pkgs.tailscale.com/stable/\$ID/\$CODENAME.noarmor.gpg|bin|deb [signed-by=\$K] https://pkgs.tailscale.com/stable/\$ID \$CODENAME main
grafana|Grafana (monitoring)|https://apt.grafana.com/gpg.key|asc|deb [signed-by=\$K] https://apt.grafana.com stable main
hashicorp|HashiCorp (terraform, vault, nomad)|https://apt.releases.hashicorp.com/gpg|asc|deb [arch=\$ARCH signed-by=\$K] https://apt.releases.hashicorp.com \$CODENAME main
kubernetes|Kubernetes (kubectl, kubeadm, kubelet)|https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key|asc|deb [arch=\$ARCH signed-by=\$K] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /
github-cli|GitHub CLI (gh)|https://cli.github.com/packages/githubcli-archive-keyring.gpg|bin|deb [arch=\$ARCH signed-by=\$K] https://cli.github.com/packages stable main
brave|Brave Browser|https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg|bin|deb [arch=amd64 signed-by=\$K] https://brave-browser-apt-release.s3.brave.com/ stable main
sublime-text|Sublime Text editor|https://download.sublimetext.com/sublimehq-pub.gpg|asc|deb [arch=amd64 signed-by=\$K] https://download.sublimetext.com/ apt/stable/
signal|Signal Desktop messenger|https://updates.signal.org/desktop/apt/keys.asc|asc|deb [arch=amd64 signed-by=\$K] https://updates.signal.org/desktop/apt xenial main
spotify|Spotify music client|https://download.spotify.com/debian/pubkey_6224F9941A8AA6D1.gpg|bin|deb [arch=amd64 signed-by=\$K] https://repository.spotify.com stable non-free
influxdb|InfluxDB (time-series metrics)|https://repos.influxdata.com/influxdata-archive_compat.key|asc|deb [arch=\$ARCH signed-by=\$K] https://repos.influxdata.com/stable stable main
elastic|Elastic Stack (Elasticsearch, Kibana, Logstash)|https://artifacts.elastic.co/GPG-KEY-elasticsearch|asc|deb [arch=\$ARCH signed-by=\$K] https://artifacts.elastic.co/packages/8.x/apt stable main
cloudflared|Cloudflare (cloudflared, WARP)|https://pkg.cloudflare.com/cloudflare-main.gpg|bin|deb [arch=\$ARCH signed-by=\$K] https://pkg.cloudflare.com/cloudflared \$CODENAME main
virtualbox|Oracle VirtualBox|https://www.virtualbox.org/download/oracle_vbox_2016.asc|asc|deb [arch=amd64 signed-by=\$K] https://download.virtualbox.org/virtualbox/debian \$CODENAME contrib"

repo_add_apt_popular() { # <tag ...>
    # shellcheck disable=SC2034  # consumed via eval'd repo-line templates
    local ID CODENAME ARCH
    ID=$(. /etc/os-release; echo "$ID")
    CODENAME=$(. /etc/os-release; echo "$VERSION_CODENAME")
    ARCH=$(dpkg --print-architecture)
    : "$ID" "$CODENAME" "$ARCH"   # consumed via eval'd templates below
    mkdir -p /etc/apt/keyrings
    local t line tag desc keyurl fmt repoline K
    for t in "$@"; do
        line=$(grep -m1 "^$t|" <<<"$APT_POPULAR") || continue
        IFS='|' read -r tag desc keyurl fmt repoline <<<"$line"
        keyurl=$(safe_template_expand "$keyurl")
        K="/etc/apt/keyrings/systui-$tag.gpg"
        if [ "$fmt" = bin ]; then
            curl -fsSL "$keyurl" -o "$K" 2>>"$LOGFILE" || { warn "$desc: key download failed."; continue; }
        else
            curl -fsSL "$keyurl" 2>>"$LOGFILE" | gpg --dearmor --yes -o "$K" 2>>"$LOGFILE" \
                || { warn "$desc: key import failed."; continue; }
        fi
        repoline=$(safe_template_expand "$repoline")
        echo "$repoline" > "/etc/apt/sources.list.d/systui-$tag.list"
        log "repo: added $tag -> $repoline"
    done
    run_cmd "apt-get update (new repos)" apt-get update
    show_warnings
}


# ---- Official distribution repositories -------------------------------------
# Browse the distributions supported by Rootfs Builder and write official APT
# repositories to isolated files under /etc/apt/sources.list.d. Non-APT
# distributions remain visible in the catalogue but cannot be represented by
# an APT sources.list entry.
distro_repo_label() {
    case "$1" in
        debian) echo "Debian" ;; devuan) echo "Devuan" ;; ubuntu) echo "Ubuntu" ;;
        alpine) echo "Alpine Linux" ;; arch) echo "Arch Linux" ;; fedora) echo "Fedora" ;;
        kali) echo "Kali Linux" ;; opensuse) echo "openSUSE Leap" ;;
        tumbleweed) echo "openSUSE Tumbleweed" ;; gentoo) echo "Gentoo Linux" ;;
        void) echo "Void Linux" ;; *) echo "$1" ;;
    esac
}

distro_repo_release_menu() { # <distro>
    local distro="$1" arch candidates="" def="" r state tags=()
    arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
    if declare -F rootfs_release_candidates >/dev/null 2>&1; then
        candidates=$(rootfs_release_candidates "$distro" "$arch" | tail -n 20)
    fi
    case "$distro" in
        debian) def=trixie; [ -n "$candidates" ] || candidates=$'bookworm\ntrixie\nforky\nsid' ;;
        devuan) def=excalibur; [ -n "$candidates" ] || candidates=$'daedalus\nexcalibur\nfreia\nceres' ;;
        ubuntu) def=noble; [ -n "$candidates" ] || candidates=$'jammy\nnoble\nplucky\nquesting' ;;
        kali) def=kali-rolling; candidates=$'kali-rolling\nkali-last-snapshot' ;;
        *) return 1 ;;
    esac
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        state=off; [ "$r" = "$def" ] && state=on
        tags+=("$r" "$(distro_repo_label "$distro") $r" "$state")
    done <<<"$candidates"
    tags+=(custom "Enter a release manually" off)
    r=$(tui_radio "Distro Repos — Release" "SPACE selects a release; ENTER confirms:" "${tags[@]}") || return 1
    [ "$r" = custom ] && r=$(tui_input "Custom release" "Release/codename:" "$def")
    [ -n "$r" ] || return 1
    printf '%s\n' "$r"
}

distro_repo_key_option() { # <distro> -> apt option or empty
    local f
    case "$1" in
        debian) set -- /usr/share/keyrings/debian-archive-keyring.gpg ;;
        devuan) set -- /usr/share/keyrings/devuan-archive-keyring.gpg /usr/share/keyrings/devuan-keyring.gpg ;;
        ubuntu) set -- /usr/share/keyrings/ubuntu-archive-keyring.gpg ;;
        kali) set -- /usr/share/keyrings/kali-archive-keyring.gpg ;;
        *) return 0 ;;
    esac
    for f in "$@"; do
        [ -f "$f" ] && { printf '[signed-by=%s]' "$f"; return 0; }
    done
}

distro_repo_components() { # <distro> <release>
    local distro="$1" release="$2" args=() sel
    case "$distro" in
        debian|devuan|kali)
            args=(main "main — officially supported packages" on
                  contrib "contrib — free packages depending on non-free software" off
                  non-free "non-free — redistributable non-free software" off
                  non-free-firmware "non-free-firmware — device firmware" off) ;;
        ubuntu)
            args=(main "main — officially supported software" on
                  restricted "restricted — supported proprietary drivers" off
                  universe "universe — community-maintained software" off
                  multiverse "multiverse — restricted software" off) ;;
        *) return 1 ;;
    esac
    sel=$(tui_check "Distro Repos — Components" \
        "$(distro_repo_label "$distro") $release\nSPACE toggles components; ENTER confirms:" "${args[@]}") || return 1
    sel=${sel//\"/}
    [ -n "${sel// }" ] || return 1
    printf '%s\n' "$sel"
}

distro_repo_pockets() { # <distro> <release>
    local distro="$1" release="$2" sel
    case "$distro" in
        debian)
            sel=$(tui_check "Distro Repos — Suites" "SPACE toggles suites; ENTER confirms:" \
                base "$release" on
                updates "$release-updates" off
                security "$release-security" off
                backports "$release-backports" off) || return 1 ;;
        ubuntu)
            sel=$(tui_check "Distro Repos — Pockets" "SPACE toggles pockets; ENTER confirms:" \
                base "$release" on
                updates "$release-updates" on
                security "$release-security" on
                backports "$release-backports" off
                proposed "$release-proposed (development/testing)" off) || return 1 ;;
        devuan)
            sel=$(tui_check "Distro Repos — Suites" "SPACE toggles suites; ENTER confirms:" \
                base "$release" on \
                updates "$release-updates" on \
                security "$release-security" on) || return 1 ;;
        kali) sel=base ;;
        *) return 1 ;;
    esac
    sel=${sel//\"/}
    [ -n "${sel// }" ] || return 1
    printf '%s\n' "$sel"
}

distro_repo_write_apt() { # <distro> <release> <components> <pockets> <types>
    local distro="$1" release="$2" components="$3" pockets="$4" types="$5"
    local base security suite pocket type opt file label
    case "$distro" in
        debian)
            base="https://deb.debian.org/debian"
            security="https://security.debian.org/debian-security" ;;
        devuan) base="https://deb.devuan.org/merged" ;;
        ubuntu)
            case "$(dpkg --print-architecture 2>/dev/null)" in
                arm64|armhf|ppc64el|riscv64|s390x)
                    base="https://ports.ubuntu.com/ubuntu-ports"; security="$base" ;;
                *)
                    base="https://archive.ubuntu.com/ubuntu"; security="https://security.ubuntu.com/ubuntu" ;;
            esac ;;
        kali) base="https://http.kali.org/kali" ;;
        *) return 1 ;;
    esac
    opt=$(distro_repo_key_option "$distro")
    file="/etc/apt/sources.list.d/systui-distro-${distro}-${release}.list"
    mkdir -p /etc/apt/sources.list.d
    [ -f "$file" ] && cp "$file" "$file.bak.$(date +%s)"
    {
        echo "# Added by systui Distro Repos — $(distro_repo_label "$distro") $release"
        echo "# Official distribution repositories only."
        for pocket in $pockets; do
            case "$pocket" in
                base) suite="$release" ;;
                updates) suite="$release-updates" ;;
                security) suite="$release-security" ;;
                backports) suite="$release-backports" ;;
                proposed) suite="$release-proposed" ;;
                *) continue ;;
            esac
            for type in $types; do
                [ "$type" = deb ] || [ "$type" = deb-src ] || continue
                if { [ "$distro" = debian ] || [ "$distro" = ubuntu ]; } && [ "$pocket" = security ]; then
                    printf '%s %s %s %s %s\n' "$type" "$opt" "$security" "$suite" "$components"
                else
                    printf '%s %s %s %s %s\n' "$type" "$opt" "$base" "$suite" "$components"
                fi
            done
        done
    } | sed 's/^\(deb\(-src\)\?\)  /\1 /' > "$file"
    log "repo: wrote official $distro $release repositories to $file"
    printf '%s\n' "$file"
}

menu_distro_repos() {
    [ "$PM" = apt ] || {
        tui_msg "APT required" "Distro Repos writes APT source entries to /etc/apt/sources.list.d.\nThe current package manager is '$PM'."
        return 0
    }

    local host_id="unknown" host_name="Unknown distribution"
    if [ -r /etc/os-release ]; then
        host_id=$(. /etc/os-release; printf '%s' "${ID:-unknown}")
        host_name=$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-${NAME:-$host_id}}")
    elif [ -r /usr/lib/os-release ]; then
        host_id=$(. /usr/lib/os-release; printf '%s' "${ID:-unknown}")
        host_name=$(. /usr/lib/os-release; printf '%s' "${PRETTY_NAME:-${NAME:-$host_id}}")
    fi

    while true; do
        local selected distro release components pockets types file action
        local files=() added=0 failed=0

        selected=$(tui_check "Distro Repos" \
            "Host: $host_name\n\nSPACE toggles distributions; ENTER confirms.\nCross-distribution APT sources are allowed." \
            debian "Debian — APT repository" off \
            devuan "Devuan — APT repository" off \
            ubuntu "Ubuntu — APT repository" off \
            kali "Kali Linux — APT repository" off \
            alpine "Alpine Linux — browse native apk repositories" off \
            arch "Arch Linux — browse native pacman repositories" off \
            fedora "Fedora — browse native DNF repositories" off \
            opensuse "openSUSE Leap — browse native zypper repositories" off \
            tumbleweed "openSUSE Tumbleweed — browse native zypper repositories" off \
            gentoo "Gentoo — browse native Portage repositories" off \
            void "Void Linux — browse native XBPS repositories" off) || return 0
        selected=${selected//\"/}
        [ -n "${selected// }" ] || continue

        for distro in $selected; do
            case "$distro" in
                debian|devuan|ubuntu|kali)
                    if [ "$host_id" != "$distro" ]; then
                        tui_yesno "Cross-distribution repository" \
                            "Current system: $host_name ($host_id)\nSelected source: $(distro_repo_label "$distro")\n\nMixing distribution repositories can cause dependency conflicts or make the system unbootable. Continue and create an isolated sources.list.d file?" \
                            || continue
                    fi
                    ;;
                *)
                    tui_msg "Native repository format" \
                        "$(distro_repo_label "$distro") does not use APT. Its official repositories cannot be written as an APT sources.list.d entry.\n\nUse that distribution's native repository manager inside its rootfs."
                    continue
                    ;;
            esac

            release=$(distro_repo_release_menu "$distro") || continue
            components=$(distro_repo_components "$distro" "$release") || continue
            pockets=$(distro_repo_pockets "$distro" "$release") || continue
            types=$(tui_check "Distro Repos — Package types" "SPACE toggles; ENTER confirms:" \
                deb "Binary packages (deb)" on \
                deb-src "Source packages (deb-src)" off) || continue
            types=${types//\"/}
            [ -n "${types// }" ] || continue

            if file=$(distro_repo_write_apt "$distro" "$release" "$components" "$pockets" "$types"); then
                files+=("$file")
                added=$((added + 1))
            else
                warn "Could not write repositories for $distro $release."
                failed=$((failed + 1))
            fi
        done

        [ "$added" -gt 0 ] || {
            [ "$failed" -gt 0 ] && tui_msg "Repository errors" "No repository files were created. Check $LOGFILE."
            continue
        }

        local summary="Created $added repository file(s):"
        for file in "${files[@]}"; do summary="$summary\n$file"; done
        [ "$failed" -gt 0 ] && summary="$summary\n\nFailed: $failed (see $LOGFILE)"

        action=$(tui_radio "Distro Repos — Added" "$summary\n\nChoose the next action:" \
            refresh "Run apt-get update now" off \
            another "Add more distribution repositories" on \
            back "Return to Repositories" off) || return 0
        case "$action" in
            refresh) run_cmd "apt-get update" apt-get update ;;
            back) return 0 ;;
        esac
    done
}

# ---- APT sources.list.d file manager (apt only) -------------------------------
repo_sources_listd() {
    [ "$PM" != apt ] && { tui_msg "N/A" "sources.list.d management is APT-only."; return; }
    
    while true; do
        local c
        c=$(tui_menu "APT Sources" "Manage /etc/apt/sources.list and /etc/apt/sources.list.d/:" \
            mainview "View /etc/apt/sources.list" \
            mainedit "Edit /etc/apt/sources.list" \
            list     "List all sources.list.d files" \
            view     "View a file's contents" \
            add      "Create a new repository file" \
            edit     "Edit a file (add/modify lines)" \
            disable  "Disable a file (rename to .disabled)" \
            enable   "Enable a file (restore from .disabled)" \
            delete   "Delete a file" \
            back     "Back") || return 0
        
        case "$c" in
            mainview) touch /etc/apt/sources.list; cat /etc/apt/sources.list > ${SYSTUI_TMP}/listd; tui_text "/etc/apt/sources.list" ${SYSTUI_TMP}/listd ;;
            mainedit) touch /etc/apt/sources.list; cp /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%s)"; safe_edit /etc/apt/sources.list || true ;;
            list)
                {
                    echo "=== Files in /etc/apt/sources.list.d ==="
                    echo
                    local f
                    shopt -s nullglob
                    for f in /etc/apt/sources.list.d/*; do
                        local name size
                        name=$(basename "$f")
                        size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)
                        case "$f" in
                            *.disabled)  echo "❌ DISABLED: $name ($size bytes)" ;;
                            *)          echo "✓ ENABLED:  $name ($size bytes)" ;;
                        esac
                    done
                    shopt -u nullglob
                    echo
                    echo "=== Lines in /etc/apt/sources.list (main) ==="
                    grep -v '^\s*#' /etc/apt/sources.list 2>/dev/null | grep -v '^\s*$' \
                        || echo "(file is empty or commented out)"
                } > ${SYSTUI_TMP}/listd
                tui_text "sources.list.d inventory" ${SYSTUI_TMP}/listd ;;
            
            view)
                local files=() f args=()
                shopt -s nullglob
                for f in /etc/apt/sources.list.d/*; do
                    files+=("$f")
                    args+=("$f" "$(basename "$f")")
                done
                shopt -u nullglob
                [ ${#files[@]} -eq 0 ] && { tui_msg "None" "No files in sources.list.d"; continue; }
                local sel
                sel=$(tui_menu "View file" "Choose a file:" "${args[@]}") || continue
                cat "$sel" > ${SYSTUI_TMP}/listd
                tui_text "$(basename "$sel")" ${SYSTUI_TMP}/listd ;;
            
            add)
                local name url comps
                name=$(tui_input "New repo file" "Short name (e.g., docker):" "") || continue
                [ -z "$name" ] && continue
                valid_safe_name "$name" || { tui_msg "Invalid name" "Use letters, numbers, dots, underscores, or hyphens only."; continue; }
                [ -f "/etc/apt/sources.list.d/$name.list" ] && {
                    tui_msg "Exists" "File $name.list already exists."; continue
                }
                local choice
                choice=$(tui_radio "Source type" "Choose type (SPACE to select):" \
                    deb  "deb: Binary packages" on \
                    debsrc "deb-src: Source packages" off \
                    both "Both deb + deb-src" off \
                    signed "deb with GPG signing key path" off) || continue
                [ -z "$choice" ] && continue
                
                local url_desc comps_desc
                case "$choice" in
                    deb|debsrc)
                        url_desc="Repository URL (e.g., https://repo.example.com/deb)"
                        comps_desc="Components (e.g., main contrib non-free or main universe)"
                        ;;
                    both)
                        url_desc="Repository URL"
                        comps_desc="Components"
                        ;;
                    signed)
                        url_desc="Repository URL"
                        comps_desc="Components"
                        ;;
                esac
                
                url=$(tui_input "New repo" "$url_desc" "") || continue
                [ -z "$url" ] && continue
                comps=$(tui_input "New repo" "$comps_desc" "main") || comps=main
                
                local keypath=""
                [ "$choice" = "signed" ] && {
                    keypath=$(tui_input "GPG key" "Full path to key (e.g., /etc/apt/keyrings/repo.gpg):" "") || continue
                    [ -z "$keypath" ] && { tui_msg "Error" "Key path required for signed repos."; continue; }
                }
                
                {
                    case "$choice" in
                        deb)     echo "deb $url $comps" ;;
                        debsrc)  echo "deb-src $url $comps" ;;
                        both)    echo "deb $url $comps"; echo "deb-src $url $comps" ;;
                        signed)  echo "deb [signed-by=$keypath] $url $comps" ;;
                    esac
                } > "/etc/apt/sources.list.d/$name.list"
                
                tui_msg "Created" "File: /etc/apt/sources.list.d/$name.list\n\nRemember to:\n1. Import the signing key (if applicable)\n2. Run 'Refresh package indexes'"
                run_cmd "apt-get update" apt-get update ;;
            
            edit)
                local files=() f args=()
                shopt -s nullglob
                for f in /etc/apt/sources.list.d/*; do
                    [ "$f" != "*.disabled" ] && { files+=("$f"); args+=("$f" "$(basename "$f")"); }
                done
                shopt -u nullglob
                [ ${#files[@]} -eq 0 ] && { tui_msg "None" "No enabled files in sources.list.d"; continue; }
                local sel
                sel=$(tui_menu "Edit file" "Choose file:" "${args[@]}") || continue
                
                {
                    echo "=== CURRENT CONTENT: $(basename "$sel") ==="
                    cat "$sel"
                    echo
                    echo "=== HOW TO EDIT ==="
                    echo "1. Type SPACE to add a new line (format: deb [opts] URL release components)"
                    echo "2. Or manually edit the file in your preferred editor"
                    echo "3. After changes, this will auto-refresh apt"
                } > ${SYSTUI_TMP}/edit.hint
                tui_text "$(basename "$sel")" ${SYSTUI_TMP}/edit.hint
                
                local add_line
                add_line=$(tui_input "Add line" "Add a new repository line (leave empty to skip):" "") || continue
                if [ -n "$add_line" ]; then
                    echo "$add_line" >> "$sel"
                    tui_msg "Added" "Line appended to $(basename "$sel")"
                    run_cmd "apt-get update" apt-get update
                fi ;;
            
            disable)
                local files=() f args=()
                shopt -s nullglob
                for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
                    [ -f "$f" ] && { files+=("$f"); args+=("$f" "$(basename "$f")"); }
                done
                shopt -u nullglob
                [ ${#files[@]} -eq 0 ] && { tui_msg "None" "No enabled files."; continue; }
                local sel
                sel=$(tui_menu "Disable file" "Choose file:" "${args[@]}") || continue
                mv "$sel" "$sel.disabled"
                tui_msg "Disabled" "$(basename "$sel") → $(basename "$sel").disabled"
                run_cmd "apt-get update" apt-get update ;;
            
            enable)
                local files=() f args=()
                shopt -s nullglob
                for f in /etc/apt/sources.list.d/*.disabled; do
                    files+=("$f")
                    args+=("$f" "$(basename "$f")")
                done
                shopt -u nullglob
                [ ${#files[@]} -eq 0 ] && { tui_msg "None" "No disabled files."; continue; }
                local sel
                sel=$(tui_menu "Enable file" "Choose file:" "${args[@]}") || continue
                mv "$sel" "${sel%.disabled}"
                tui_msg "Enabled" "$(basename "${sel%.disabled}") restored"
                run_cmd "apt-get update" apt-get update ;;
            
            delete)
                local files=() f tags=()
                shopt -s nullglob
                for f in /etc/apt/sources.list.d/systui-*.list /etc/apt/sources.list.d/systui-*.disabled; do
                    files+=("$f")
                    tags+=("$f" "$(basename "$f")" off)
                done
                shopt -u nullglob
                [ ${#files[@]} -eq 0 ] && {
                    tui_msg "Protected" "Only systui-added repos can be deleted here (protection against accidents).\nFor others, edit manually or use 'Add' to create systui-prefixed repos."
                    continue
                }
                local sel
                sel=$(tui_check "Delete files" "Select files to DELETE (SPACE toggles, ENTER confirms):" "${tags[@]}") || continue
                sel=${sel//\"/}
                [ -z "${sel// }" ] && continue
                tui_yesno "Confirm" "Delete these repo files?\n\n$sel" || continue
                rm -f $sel
                tui_msg "Deleted" "Files removed and apt cache updated."
                run_cmd "apt-get update" apt-get update ;;
            
            back) return 0 ;;
        esac
    done
}

repo_popular() {
    case "$PM" in
        apt)
            local args=() line tag desc rest
            while IFS='|' read -r tag desc rest; do
                [ -z "$tag" ] && continue
                if [ -f "/etc/apt/sources.list.d/systui-$tag.list" ]; then
                    args+=("$tag" "$desc [added]" on)
                else
                    args+=("$tag" "$desc" off)
                fi
            done <<<"$APT_POPULAR"
            local sel
            sel=$(tui_check "Popular repositories (apt)" \
                "SPACE toggles, ENTER applies. Already-added repos are pre-checked;\nunchecking one here does NOT remove it (use Manage):" "${args[@]}") || return 0
            sel=${sel//\"/}
            local new="" t
            for t in $sel; do
                [ -f "/etc/apt/sources.list.d/systui-$t.list" ] || new="$new $t"
            done
            [ -z "${new// }" ] && { tui_msg "Nothing to do" "No new repositories selected."; return; }
            repo_add_apt_popular $new ;;
        dnf)
            local sel
            sel=$(tui_check "Popular repositories (dnf)" "SPACE toggles, ENTER applies:" \
                rpmfusion  "RPM Fusion free + nonfree" off \
                docker     "Docker CE" off \
                vscode     "Visual Studio Code" off \
                tailscale  "Tailscale VPN" off \
                kubernetes "Kubernetes (kubectl, kubeadm)" off \
                github-cli "GitHub CLI (gh)" off \
                grafana    "Grafana (monitoring)" off \
                hashicorp  "HashiCorp (terraform, vault, nomad)" off \
                brave      "Brave Browser" off \
                postgres   "PostgreSQL (PGDG)" off \
                influxdb   "InfluxDB (time-series metrics)" off \
                elastic    "Elastic Stack (Elasticsearch, Kibana)" off) || return 0
            sel=${sel//\"/}
            local t
            for t in $sel; do
                case "$t" in
                    rpmfusion)
                        run_cmd "RPM Fusion" bash -c \
                          "dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-\$(rpm -E %fedora).noarch.rpm \
                           https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-\$(rpm -E %fedora).noarch.rpm" ;;
                    docker)
                        run_cmd "Docker CE repo" dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo ;;
                    vscode)
                        rpm --import https://packages.microsoft.com/keys/microsoft.asc 2>>"$LOGFILE"
                        printf '[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc\n' \
                            > /etc/yum.repos.d/systui-vscode.repo ;;
                    tailscale)
                        run_cmd "Tailscale repo" dnf config-manager --add-repo https://pkgs.tailscale.com/stable/fedora/tailscale.repo ;;
                    kubernetes)
                        printf '[kubernetes]\nname=Kubernetes\nbaseurl=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/\nenabled=1\ngpgcheck=1\ngpgkey=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/repodata/repomd.xml.key\n' \
                            > /etc/yum.repos.d/systui-kubernetes.repo ;;
                    github-cli)
                        run_cmd "GitHub CLI repo" bash -c \
                            'dnf install -y dnf-plugins-core 2>/dev/null
                             dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo' ;;
                    grafana)
                        printf '[grafana]\nname=grafana\nbaseurl=https://rpm.grafana.com\nrepo_gpgcheck=1\nenabled=1\ngpgcheck=1\ngpgkey=https://rpm.grafana.com/gpg.key\n' \
                            > /etc/yum.repos.d/systui-grafana.repo ;;
                    hashicorp)
                        run_cmd "HashiCorp repo" bash -c \
                            'dnf install -y dnf-plugins-core 2>/dev/null
                             dnf config-manager --add-repo https://rpm.releases.hashicorp.com/fedora/hashicorp.repo' ;;
                    brave)
                        run_cmd "Brave Browser repo" bash -c \
                            'dnf install -y dnf-plugins-core 2>/dev/null
                             dnf config-manager --add-repo https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
                             rpm --import https://brave-browser-rpm-release.s3.brave.com/brave-core.asc' ;;
                    postgres)
                        run_cmd "PostgreSQL PGDG repo" bash -c \
                            'dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/F-$(rpm -E %fedora)-x86_64/pgdg-fedora-repo-latest.noarch.rpm" 2>/dev/null || \
                             dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm -E %rhel)-x86_64/pgdg-redhat-repo-latest.noarch.rpm"' ;;
                    influxdb)
                        printf '[influxdb]\nname=InfluxDB Repository\nbaseurl=https://repos.influxdata.com/rhel/$releasever/stable/$basearch/\nenabled=1\ngpgcheck=1\ngpgkey=https://repos.influxdata.com/influxdata-archive_compat.key\n' \
                            > /etc/yum.repos.d/systui-influxdb.repo ;;
                    elastic)
                        rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch 2>>"$LOGFILE"
                        printf '[elasticsearch-8.x]\nname=Elasticsearch 8.x packages\nbaseurl=https://artifacts.elastic.co/packages/8.x/yum\ngpgcheck=1\ngpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch\nenabled=1\nautorefresh=1\ntype=rpm-md\n' \
                            > /etc/yum.repos.d/systui-elastic.repo ;;
                esac
            done ;;
        pacman)
            local sel
            sel=$(tui_check "Popular repositories (pacman)" "SPACE toggles, ENTER applies:" \
                multilib    "multilib (32-bit libs: Steam, Wine)" off \
                chaotic     "Chaotic-AUR (prebuilt AUR packages)" off \
                blackarch   "BlackArch (security research tools)" off \
                cachyos     "CachyOS (performance-optimised packages)" off \
                endeavouros "EndeavourOS (EndeavourOS packages)" off) || return 0
            sel=${sel//\"/}
            local t
            for t in $sel; do
                case "$t" in
                    multilib)
                        grep -q '^\[multilib\]' /etc/pacman.conf \
                            || sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf ;;
                    chaotic)
                        run_cmd "Chaotic-AUR key + packages" bash -c \
                          "pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com && \
                           pacman-key --lsign-key 3056513887B78AEB && \
                           pacman -U --noconfirm \
                             'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
                             'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'"
                        grep -q '^\[chaotic-aur\]' /etc/pacman.conf || \
                            printf '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist\n' >> /etc/pacman.conf ;;
                    blackarch)
                        run_cmd "BlackArch repo" bash -c \
                            'curl -O https://blackarch.org/strap.sh
                             sha1sum strap.sh
                             chmod +x strap.sh && ./strap.sh
                             rm -f strap.sh' ;;
                    cachyos)
                        run_cmd "CachyOS repo" bash -c \
                            'pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
                             pacman-key --lsign-key F3B607488DB35A47
                             pacman -U --noconfirm \
                               https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-keyring-3-1-any.pkg.tar.zst \
                               https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-mirrorlist-18-1-any.pkg.tar.zst'
                        grep -q '^\[cachyos\]' /etc/pacman.conf || \
                            printf '\n[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n' >> /etc/pacman.conf ;;
                    endeavouros)
                        run_cmd "EndeavourOS repo" bash -c \
                            'pacman-key --recv-key 739B8C2E6EB7638D --keyserver keyserver.ubuntu.com
                             pacman-key --lsign-key 739B8C2E6EB7638D
                             pacman -U --noconfirm https://mirror.endeavouros.com/extra/endeavouros-keyring-1-1-any.pkg.tar.zst \
                               https://mirror.endeavouros.com/extra/endeavouros-mirrorlist-1.9-1-any.pkg.tar.zst'
                        grep -q '^\[endeavouros\]' /etc/pacman.conf || \
                            printf '\n[endeavouros]\nInclude = /etc/pacman.d/endeavouros-mirrorlist\n' >> /etc/pacman.conf ;;
                esac
            done
            [ -n "${sel// }" ] && run_cmd "pacman -Syy" pacman -Syy ;;
        zypper)
            local sel
            sel=$(tui_check "Popular repositories (zypper)" "SPACE toggles, ENTER applies:" \
                packman    "Packman (multimedia codecs, libdvdcss)" off \
                vscode     "Visual Studio Code" off \
                github-cli "GitHub CLI (gh)" off \
                docker     "Docker CE" off \
                tailscale  "Tailscale VPN" off \
                brave      "Brave Browser" off \
                kubernetes "Kubernetes (kubectl, kubeadm)" off \
                grafana    "Grafana (monitoring)" off \
                hashicorp  "HashiCorp (terraform, vault)" off \
                postgres   "PostgreSQL (PGDG)" off) || return 0
            sel=${sel//\"/}
            local t
            for t in $sel; do
                case "$t" in
                    packman)
                        run_cmd "Packman repo" bash -c \
                            '. /etc/os-release
                             case "$ID" in
                               *tumbleweed*|*slowroll*) REL=openSUSE_Tumbleweed ;;
                               *) REL="openSUSE_Leap_${VERSION_ID}" ;;
                             esac
                             zypper ar -cfp 90 "https://ftp.gwdg.de/pub/linux/misc/packman/suse/${REL}/" packman 2>/dev/null || true
                             zypper --gpg-auto-import-keys refresh packman' ;;
                    vscode)
                        run_cmd "VS Code repo" bash -c \
                            'rpm --import https://packages.microsoft.com/keys/microsoft.asc 2>/dev/null
                             zypper ar -f https://packages.microsoft.com/yumrepos/vscode vscode 2>/dev/null || zypper mr --refresh vscode' ;;
                    github-cli)
                        run_cmd "GitHub CLI repo" bash -c \
                            'zypper ar https://cli.github.com/packages/rpm/gh-cli.repo gh-cli 2>/dev/null || zypper mr --refresh gh-cli
                             zypper --gpg-auto-import-keys refresh gh-cli' ;;
                    docker)
                        run_cmd "Docker CE repo" bash -c \
                            '. /etc/os-release
                             case "$ID" in
                               opensuse-tumbleweed) REL=opensuse ;;
                               *) REL=sles ;;
                             esac
                             zypper ar "https://download.docker.com/linux/${REL}/docker-ce.repo" docker-ce 2>/dev/null || zypper mr --refresh docker-ce
                             zypper --gpg-auto-import-keys refresh docker-ce' ;;
                    tailscale)
                        run_cmd "Tailscale repo" bash -c \
                            'zypper ar https://pkgs.tailscale.com/stable/opensuse/tailscale.repo tailscale 2>/dev/null || zypper mr --refresh tailscale
                             zypper --gpg-auto-import-keys refresh tailscale' ;;
                    brave)
                        run_cmd "Brave Browser repo" bash -c \
                            'rpm --import https://brave-browser-rpm-release.s3.brave.com/brave-core.asc 2>/dev/null
                             zypper ar https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo brave-browser 2>/dev/null || zypper mr --refresh brave-browser' ;;
                    kubernetes)
                        run_cmd "Kubernetes repo" bash -c \
                            'zypper ar https://pkgs.k8s.io/core:/stable:/v1.32/rpm/ kubernetes 2>/dev/null || zypper mr --refresh kubernetes
                             zypper --gpg-auto-import-keys refresh kubernetes' ;;
                    grafana)
                        run_cmd "Grafana repo" bash -c \
                            'zypper ar https://rpm.grafana.com grafana 2>/dev/null || zypper mr --refresh grafana
                             zypper --gpg-auto-import-keys refresh grafana' ;;
                    hashicorp)
                        run_cmd "HashiCorp repo" bash -c \
                            'zypper ar https://rpm.releases.hashicorp.com/opensuse/hashicorp.repo hashicorp 2>/dev/null || zypper mr --refresh hashicorp
                             zypper --gpg-auto-import-keys refresh hashicorp' ;;
                    postgres)
                        run_cmd "PostgreSQL PGDG repo" bash -c \
                            '. /etc/os-release
                             zypper ar "https://download.postgresql.org/pub/repos/yum/reporpms/OpenSUSE-${VERSION_ID}-x86_64/pgdg-opensuse-repo-latest.noarch.rpm" postgres-pgdg 2>/dev/null || true' ;;
                esac
            done
            [ -n "${sel// }" ] && run_cmd "zypper refresh" zypper refresh ;;
        apk)
            local base rel sel
            base=$(awk -F'/alpine' '/alpine/{print $1"/alpine"; exit}' /etc/apk/repositories)
            rel=$(grep -o 'v[0-9.]*\|edge' /etc/apk/repositories | head -1)
            sel=$(tui_check "Popular repositories (apk)" "SPACE toggles, ENTER applies:" \
                community      "community ($rel)" "$(grep -q "$rel/community" /etc/apk/repositories && echo on || echo off)" \
                testing        "edge/testing (bleeding edge!)" "$(grep -q edge/testing /etc/apk/repositories && echo on || echo off)" \
                edge-main      "edge/main (newer packages than stable)" "$(grep -q edge/main /etc/apk/repositories && echo on || echo off)" \
                edge-community "edge/community (newer community packages)" "$(grep -q edge/community /etc/apk/repositories && echo on || echo off)") || return 0
            sel=${sel//\"/}
            case " $sel " in *" community "*)
                grep -q "$rel/community" /etc/apk/repositories || echo "$base/$rel/community" >> /etc/apk/repositories ;;
            esac
            case " $sel " in *" testing "*)
                grep -q edge/testing /etc/apk/repositories || { echo "$base/edge/testing" >> /etc/apk/repositories
                    warn "edge/testing on stable can break dependencies — prefer @testing pins."; } ;;
            esac
            case " $sel " in *" edge-main "*)
                grep -q edge/main /etc/apk/repositories || { echo "$base/edge/main" >> /etc/apk/repositories
                    warn "edge/main on stable may introduce incompatible package versions."; } ;;
            esac
            case " $sel " in *" edge-community "*)
                grep -q edge/community /etc/apk/repositories || { echo "$base/edge/community" >> /etc/apk/repositories
                    warn "edge/community on stable may introduce incompatible package versions."; } ;;
            esac
            show_warnings
            run_cmd "apk update" apk update ;;
    esac
}

# Space-select enable/disable of everything currently configured.
repo_manage() {
    case "$PM" in
        apt)
            local f args=() name state
            shopt -s nullglob
            for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources \
                     /etc/apt/sources.list.d/*.disabled; do
                name=$(basename "$f")
                case "$f" in
                    *.disabled) state=off ;;
                    *)          state=on ;;
                esac
                args+=("$f" "$name" "$state")
            done
            shopt -u nullglob
            [ ${#args[@]} -eq 0 ] && { tui_msg "None" "No source files in sources.list.d\n(main /etc/apt/sources.list is not managed here)."; return; }
            local sel
            sel=$(tui_check "Manage apt sources" \
                "Checked = ENABLED. SPACE toggles, ENTER applies.\nDisabling renames to *.disabled (apt then ignores it):" "${args[@]}") || return 0
            sel=" ${sel//\"/} "
            local changed=0
            for f in "${args[@]}"; do
                case "$f" in /etc/apt/*) ;; *) continue ;; esac   # skip labels/states
                case "$sel" in
                    *" $f "*)   # should be enabled
                        case "$f" in *.disabled)
                            mv "$f" "${f%.disabled}" && changed=1 ;;
                        esac ;;
                    *)          # should be disabled
                        case "$f" in *.disabled) ;; *)
                            mv "$f" "$f.disabled" && changed=1 ;;
                        esac ;;
                esac
            done
            [ $changed = 1 ] && run_cmd "apt-get update" apt-get update ;;
        apk)
            local repof=/etc/apk/repositories
            local args=() line disp state
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                case "$line" in
                    \#*) disp="${line#\#}"; state=off ;;
                    *)   disp="$line";      state=on ;;
                esac
                args+=("$disp" "" "$state")
            done < "$repof"
            [ ${#args[@]} -eq 0 ] && { tui_msg "Empty" "$repof is empty."; return; }
            local sel
            sel=$(tui_check "Manage apk repositories" \
                "Checked = ENABLED. SPACE toggles, ENTER rewrites $repof:" "${args[@]}") || return 0
            sel=" ${sel//\"/} "
            cp "$repof" "$repof.bak.$(date +%s)"
            {
                local i=0
                while [ $i -lt ${#args[@]} ]; do
                    disp="${args[$i]}"
                    case "$sel" in
                        *" $disp "*) echo "$disp" ;;
                        *)           echo "#$disp" ;;
                    esac
                    i=$((i+3))
                done
            } > "$repof"
            run_cmd "apk update" apk update ;;
        dnf)
            local args=() id state
            while read -r id state; do
                [ -z "$id" ] && continue
                [ "$state" = enabled ] && args+=("$id" "" on) || args+=("$id" "" off)
            done < <(dnf repolist --all 2>/dev/null | awk 'NR>1 {print $1, $NF}')
            [ ${#args[@]} -eq 0 ] && { tui_msg "None" "No repositories reported by dnf."; return; }
            local sel
            sel=$(tui_check "Manage dnf repositories" \
                "Checked = ENABLED. SPACE toggles, ENTER applies:" "${args[@]}") || return 0
            sel=" ${sel//\"/} "
            local i=0
            while [ $i -lt ${#args[@]} ]; do
                id="${args[$i]}"; state="${args[$((i+2))]}"
                case "$sel" in
                    *" $id "*) [ "$state" = off ] && dnf config-manager --set-enabled "$id" 2>>"$LOGFILE" ;;
                    *)         [ "$state" = on ]  && dnf config-manager --set-disabled "$id" 2>>"$LOGFILE" ;;
                esac
                i=$((i+3))
            done
            dnf repolist > ${SYSTUI_TMP}/repo 2>&1
            tui_text "Repositories now" ${SYSTUI_TMP}/repo ;;
        pacman)
            local args=() s
            for s in $(grep -oE '^\[[a-z0-9-]+\]' /etc/pacman.conf | tr -d '[]' | grep -v options); do
                args+=("$s" "" on)
            done
            for s in $(grep -oE '^#\[[a-z0-9-]+\]' /etc/pacman.conf | tr -d '#[]'); do
                args+=("$s" "(disabled)" off)
            done
            [ ${#args[@]} -eq 0 ] && { tui_msg "None" "No repo sections found."; return; }
            local sel
            sel=$(tui_check "Manage pacman repos" \
                "Checked = ENABLED. SPACE toggles, ENTER rewrites pacman.conf\n(comments/uncomments whole sections):" "${args[@]}") || return 0
            sel=" ${sel//\"/} "
            cp /etc/pacman.conf "/etc/pacman.conf.bak.$(date +%s)"
            local i=0 name
            while [ $i -lt ${#args[@]} ]; do
                name="${args[$i]}"
                case "$sel" in
                    *" $name "*)  # enable: strip leading # from section header + body
                        sed -i "/^#\[$name\]/,/^#*$\|^#*\[/{s/^#\(\[$name\]\)/\1/; s/^#\(Include\|Server\|SigLevel\)/\1/}" /etc/pacman.conf ;;
                    *)            # disable: comment header + body lines
                        sed -i "/^\[$name\]/,/^$\|^\[/{s/^\(\[$name\]\)/#\1/; s/^\(Include\|Server\|SigLevel\)/#\1/}" /etc/pacman.conf ;;
                esac
                i=$((i+3))
            done
            run_cmd "pacman -Syy" pacman -Syy ;;
    esac
}

keyring_host_arch() {
    local a
    a=$(uname -m 2>/dev/null || printf unknown)
    case "$a" in
        x86_64|amd64) printf '%s\n' x86_64 ;;
        aarch64|arm64) printf '%s\n' aarch64 ;;
        armv7l|armhf) printf '%s\n' armv7 ;;
        i386|i486|i586|i686) printf '%s\n' x86 ;;
        riscv64) printf '%s\n' riscv64 ;;
        ppc64le) printf '%s\n' ppc64le ;;
        *) printf '%s\n' "$a" ;;
    esac
}

keyring_fetch_latest() {
    # keyring_fetch_latest BASE_URL ERE
    # Prints an absolute URL for the lexicographically newest matching file.
    local base="$1" pattern="$2" page file
    page=$(curl -fsSL --retry 3 --connect-timeout 15 "$base") || return 1
    file=$(printf '%s\n' "$page" \
        | grep -Eo 'href="[^"]+"' \
        | cut -d'"' -f2 \
        | sed 's#^.*/##' \
        | grep -E "$pattern" \
        | sort -V \
        | tail -n 1)
    [ -n "$file" ] || return 1
    printf '%s/%s\n' "${base%/}" "$file"
}

keyring_repo_artifact() {
    # Prints: format|official repository URL
    local distro="$1" arch alpine_arch release base url
    arch=$(keyring_host_arch)
    case "$distro" in
        debian)
            base='https://deb.debian.org/debian/pool/main/d/debian-archive-keyring'
            url=$(keyring_fetch_latest "$base/" '^debian-archive-keyring_[^/]+_all\.deb$') || return 1
            printf 'deb|%s\n' "$url" ;;
        devuan)
            base='https://pkgmaster.devuan.org/devuan/pool/main/d/devuan-keyring'
            url=$(keyring_fetch_latest "$base/" '^devuan-keyring_[^/]+_all\.deb$') || return 1
            printf 'deb|%s\n' "$url" ;;
        ubuntu)
            base='https://archive.ubuntu.com/ubuntu/pool/main/u/ubuntu-keyring'
            url=$(keyring_fetch_latest "$base/" '^ubuntu-keyring_[^/]+_all\.deb$') || return 1
            printf 'deb|%s\n' "$url" ;;
        kali)
            printf 'gpg|https://archive.kali.org/archive-keyring.gpg\n' ;;
        alpine)
            case "$arch" in
                x86_64) alpine_arch=x86_64 ;;
                aarch64) alpine_arch=aarch64 ;;
                armv7) alpine_arch=armv7 ;;
                x86) alpine_arch=x86 ;;
                riscv64) alpine_arch=riscv64 ;;
                ppc64le) alpine_arch=ppc64le ;;
                *) return 1 ;;
            esac
            base="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/$alpine_arch"
            url=$(keyring_fetch_latest "$base/" '^alpine-keys-[^/]+\.apk$') || return 1
            printf 'tar|%s\n' "$url" ;;
        arch)
            # Arch Linux proper publishes x86_64 packages. Other architectures use
            # separate Arch Linux ARM repositories and are intentionally not mixed.
            [ "$arch" = x86_64 ] || return 1
            base='https://geo.mirror.pkgbuild.com/core/os/x86_64'
            url=$(keyring_fetch_latest "$base/" '^archlinux-keyring-[^/]+-any\.pkg\.tar\.(zst|xz)$') || return 1
            printf 'tar|%s\n' "$url" ;;
        fedora)
            # fedora-gpg-keys is a noarch package: the keys are identical for
            # every architecture, so always fetch from the x86_64 tree.
            # (aarch64/ppc64le live on fedora-secondary and riscv64 has no
            # dnf tree at all, so an arch-specific path would 404.)
            case "$arch" in
                x86_64|aarch64|armhf|ppc64le|riscv64) ;;
                *) return 1 ;;
            esac
            release=$(curl -fsSL 'https://dl.fedoraproject.org/pub/fedora/linux/releases/' \
                | grep -Eo 'href="[0-9]+/' | tr -dc '0-9\n' | sort -n | tail -n 1)
            [ -n "$release" ] || return 1
            base="https://dl.fedoraproject.org/pub/fedora/linux/releases/$release/Everything/x86_64/os/Packages/f"
            url=$(keyring_fetch_latest "$base/" '^fedora-gpg-keys-[^/]+\.noarch\.rpm$') || return 1
            printf 'rpm|%s\n' "$url" ;;
        opensuse)
            base='https://download.opensuse.org/tumbleweed/repo/oss/noarch'
            url=$(keyring_fetch_latest "$base/" '^openSUSE-build-key-[^/]+\.noarch\.rpm$') || return 1
            printf 'rpm|%s\n' "$url" ;;
        tumbleweed)
            base='https://download.opensuse.org/tumbleweed/repo/oss/noarch'
            url=$(keyring_fetch_latest "$base/" '^openSUSE-build-key-[^/]+\.noarch\.rpm$') || return 1
            printf 'rpm|%s\n' "$url" ;;
        gentoo)
            printf 'asc|https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64/openpgp-keys.asc\n' ;;
        void)
            case "$arch" in
                x86_64) base='https://repo-default.voidlinux.org/current' ;;
                aarch64) base='https://repo-default.voidlinux.org/current/aarch64' ;;
                armv7) base='https://repo-default.voidlinux.org/current/armv7l' ;;
                *) return 1 ;;
            esac
            url=$(keyring_fetch_latest "$base/" '^void-release-keys-[^/]+\.xbps$') || return 1
            printf 'tar|%s\n' "$url" ;;
        *) return 1 ;;
    esac
}

keyring_is_installed() {
    local distro="$1"
    case "$distro" in
        debian) [ -s /usr/share/keyrings/debian-archive-keyring.gpg ] ;;
        devuan) [ -s /usr/share/keyrings/devuan-archive-keyring.gpg ] || [ -s /usr/share/keyrings/devuan-keyring.gpg ] ;;
        ubuntu) [ -s /usr/share/keyrings/ubuntu-archive-keyring.gpg ] ;;
        kali) [ -s /usr/share/keyrings/kali-archive-keyring.gpg ] ;;
        *) find "/usr/share/keyrings/systui-$distro" -type f -size +0c 2>/dev/null | grep -q . ;;
    esac
}

keyring_extract_archive() {
    local fmt="$1" archive="$2" dest="$3"
    mkdir -p "$dest"
    case "$fmt" in
        deb)
            if command -v dpkg-deb >/dev/null 2>&1; then
                dpkg-deb -x "$archive" "$dest"
            elif command -v ar >/dev/null 2>&1; then
                local data
                data=$(ar t "$archive" | grep '^data\.tar' | head -n1) || return 1
                (cd "$dest" && ar p "$archive" "$data" | tar -xf -)
            else
                return 1
            fi ;;
        rpm)
            if command -v rpm2cpio >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
                (cd "$dest" && rpm2cpio "$archive" | cpio -idm --quiet)
            elif command -v bsdtar >/dev/null 2>&1; then
                bsdtar -xf "$archive" -C "$dest"
            else
                return 1
            fi ;;
        tar)
            if command -v bsdtar >/dev/null 2>&1; then
                bsdtar -xf "$archive" -C "$dest"
            else
                tar -xf "$archive" -C "$dest"
            fi ;;
        *) return 1 ;;
    esac
}

install_official_distro_keyring() {
    local distro="$1" spec fmt url tmp payload extract target count=0 manifest
    spec=$(keyring_repo_artifact "$distro") || {
        printf 'No compatible official repository artifact was found for %s on %s.\n' "$distro" "$(keyring_host_arch)" >&2
        return 1
    }
    fmt=${spec%%|*}
    url=${spec#*|}
    tmp=$(mktemp -d ${SYSTUI_TMP}/keyring.XXXXXX) || return 1
    payload="$tmp/${url##*/}"
    extract="$tmp/root"
    target="/usr/share/keyrings/systui-$distro"
    manifest="/usr/share/keyrings/systui-$distro.source"

    printf 'Downloading official %s keyring:\n  %s\n' "$distro" "$url"
    curl -fL --retry 3 --connect-timeout 20 --proto '=https' --tlsv1.2 "$url" -o "$payload" || {
        rm -rf "$tmp"; return 1;
    }

    mkdir -p /usr/share/keyrings
    case "$fmt" in
        gpg)
            install -m 0644 "$payload" "/usr/share/keyrings/${distro}-archive-keyring.gpg"
            count=1 ;;
        asc)
            mkdir -p "$target"
            if command -v gpg >/dev/null 2>&1; then
                gpg --batch --yes --dearmor -o "$target/archive-keyring.gpg" "$payload" || {
                    rm -rf "$tmp"; return 1;
                }
            else
                install -m 0644 "$payload" "$target/archive-keys.asc"
            fi
            count=1 ;;
        deb|rpm|tar)
            keyring_extract_archive "$fmt" "$payload" "$extract" || {
                printf 'Could not extract %s. Install dpkg-deb, bsdtar, or rpm2cpio/cpio as appropriate.\n' "$payload" >&2
                rm -rf "$tmp"; return 1;
            }
            # Debian-family packages already contain canonical destinations.
            if [ "$fmt" = deb ] && find "$extract/usr/share/keyrings" -type f -size +0c 2>/dev/null | grep -q .; then
                cp -a "$extract/usr/share/keyrings/." /usr/share/keyrings/
                count=$(find "$extract/usr/share/keyrings" -type f -size +0c | wc -l)
            else
                rm -rf "$target"
                mkdir -p "$target"
                while IFS= read -r f; do
                    local rel safe
                    rel=${f#"$extract"/}
                    safe=$(printf '%s' "$rel" | tr '/' '_')
                    install -m 0644 "$f" "$target/$safe"
                    count=$((count+1))
                done <<EOF
$(find "$extract" -type f \( -iname '*.gpg' -o -iname '*.asc' -o -iname '*.key' -o -path '*/etc/pki/rpm-gpg/*' -o -path '*/usr/share/distribution-gpg-keys/*' \) -size +0c 2>/dev/null)
EOF
            fi ;;
    esac

    if [ "$count" -le 0 ]; then
        printf 'The official artifact contained no recognizable signing-key files.\n' >&2
        rm -rf "$tmp"
        return 1
    fi

    {
        printf 'distribution=%s\n' "$distro"
        printf 'source=%s\n' "$url"
        printf 'downloaded=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if command -v sha256sum >/dev/null 2>&1; then
            printf 'sha256=%s\n' "$(sha256sum "$payload" | awk '{print $1}')"
        fi
    } > "$manifest"
    chmod 0644 "$manifest"
    rm -rf "$tmp"
    printf 'Installed %s signing-key file(s).\n' "$count"
}

apt_missing_keyrings_menu() {
    [ "$PM" = apt ] || return 0

    local args=() distro label state sel selected failed="" installed=""
    local distros="debian devuan ubuntu alpine arch fedora kali opensuse tumbleweed gentoo void"

    for distro in $distros; do
        case "$distro" in
            debian)     label="Debian" ;;
            devuan)     label="Devuan" ;;
            ubuntu)     label="Ubuntu" ;;
            alpine)     label="Alpine Linux" ;;
            arch)       label="Arch Linux" ;;
            fedora)     label="Fedora" ;;
            kali)       label="Kali Linux" ;;
            opensuse)   label="openSUSE" ;;
            tumbleweed) label="openSUSE Tumbleweed" ;;
            gentoo)     label="Gentoo Linux" ;;
            void)       label="Void Linux" ;;
        esac
        if keyring_is_installed "$distro"; then
            state=on
            args+=("$distro" "$label — installed (official repository download)" "$state")
        else
            args+=("$distro" "$label — download from official repository" off)
        fi
    done

    sel=$(tui_check "Rootfs Distribution Keyrings" \
        "SPACE selects distributions. ENTER downloads keyring artifacts directly from each distribution's official repository.\n\nAPT installation is not used. Existing selections are refreshed when selected:" \
        "${args[@]}") || return 0
    selected=${sel//\"/}
    [ -n "${selected// }" ] || return 0

    for distro in $selected; do
        if run_cmd "Downloading official $distro keyring" install_official_distro_keyring "$distro"; then
            installed="$installed $distro"
        else
            failed="$failed $distro"
        fi
    done

    [ -n "${installed// }" ] && tui_msg "Keyrings installed" \
        "Downloaded directly from official distribution repositories:$installed\n\nSource URL and SHA-256 metadata are stored beside each installed keyring."
    [ -n "${failed// }" ] && tui_msg "Keyring failures" \
        "Could not install:$failed\n\nReview the log for network, architecture, extraction-tool, or upstream repository errors."
}


# ---- Ubuntu PPA repository manager (APT only) -------------------------------
ppa_normalize() {
    local p="$1"
    p=${p#ppa:}
    case "$p" in
        https://launchpad.net/~*|http://launchpad.net/~*)
            p=${p#*launchpad.net/~}
            p=${p/\/+archive\/ubuntu\//\/}
            p=${p/\/+archive\//\/}
            ;;
    esac
    p=${p#/}; p=${p%/}
    printf 'ppa:%s\n' "$p"
}

menu_ppa_repos() {
    [ "$PM" = apt ] || { tui_msg "PPA repositories" "PPAs are supported only on Ubuntu-family APT systems."; return 0; }
    local host_id host_like
    host_id=$(os_id); host_like=$(awk -F= '$1=="ID_LIKE"{gsub(/\"/,"",$2); print $2}' /etc/os-release 2>/dev/null)
    case " $host_id $host_like " in *" ubuntu "*|*" linuxmint "*|*" pop "*|*" elementary "*) :;;
        *) tui_yesno "Compatibility warning" "Launchpad PPAs target Ubuntu releases. This system identifies as '$host_id'. Adding a PPA to Debian, Devuan, Kali, or another distribution can break dependency resolution. Continue anyway?" || return 0;;
    esac
    while true; do
        local c ppa line files sel f tags=()
        c=$(tui_menu "PPA Repositories" "Add, inspect, disable, enable, or remove Launchpad PPAs:" \
            add "Add a PPA (ppa:owner/archive)" \
            list "List configured PPAs" \
            disable "Disable selected PPA files" \
            enable "Enable selected disabled PPA files" \
            remove "Remove selected PPAs" \
            refresh "Refresh APT package indexes" \
            back "Back") || return 0
        case "$c" in
            add)
                ppa=$(tui_input "Add PPA" "PPA identifier (example: ppa:deadsnakes/ppa):" "ppa:") || continue
                [ "$ppa" != "ppa:" ] && [ -n "$ppa" ] || continue
                ppa=$(ppa_normalize "$ppa")
                case "$ppa" in ppa:*/*) :;; *) tui_msg "Invalid PPA" "Use ppa:owner/archive format."; continue;; esac
                command -v add-apt-repository >/dev/null 2>&1 || {
                    run_cmd "Installing add-apt-repository" apt-get install -y software-properties-common || continue
                }
                run_cmd "Adding $ppa" add-apt-repository -y "$ppa" || continue
                run_cmd "Refreshing APT indexes" apt-get update
                ;;
            list)
                { grep -rHEn '^[[:space:]]*deb .*ppa\.launchpad(content)?\.net|^[[:space:]]*URIs: .*ppa\.launchpad(content)?\.net' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || echo '(no PPAs configured)'; } > ${SYSTUI_TMP}/ppa
                tui_text "Configured PPAs" ${SYSTUI_TMP}/ppa ;;
            disable|enable|remove)
                tags=()
                if [ "$c" = enable ]; then files=$(find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*ppa*.disabled' -o -name '*launchpad*.disabled' \) 2>/dev/null | sort)
                else files=$(grep -rlE 'ppa\.launchpad(content)?\.net' /etc/apt/sources.list.d 2>/dev/null | sort); fi
                [ -n "$files" ] || { tui_msg "PPA repositories" "No matching PPA files found."; continue; }
                while IFS= read -r f; do [ -n "$f" ] && tags+=("$f" "$(basename "$f")" off); done <<< "$files"
                sel=$(tui_check "${c^} PPAs" "SPACE selects repository files:" "${tags[@]}") || continue
                sel=${sel//\"/}; [ -n "${sel// }" ] || continue
                [ "$c" = remove ] && tui_yesno "Remove PPAs" "Permanently delete the selected repository files?\n\n$sel" || [ "$c" != remove ] || continue
                for f in $sel; do case "$c" in disable) mv "$f" "$f.disabled";; enable) mv "$f" "${f%.disabled}";; remove) rm -f "$f";; esac; done
                run_cmd "Refreshing APT indexes" apt-get update ;;
            refresh) run_cmd "Refreshing APT indexes" apt-get update ;;
            back|"") return 0 ;;
        esac
    done
}

menu_repos() {
    while true; do
        local c
        c=$(tui_menu "Repositories  [manager: $PM]" "Repository management:" \
            view    "View configured repositories" \
            manage  "Manage sources (space-select enable/disable)" \
            listd   "Manage sources.list and sources.list.d" \
            distro  "Distro Repos (official distro repositories)" \
            popular "Add popular repositories (space-select)" \
            ppa     "Add/manage Ubuntu PPA repositories" \
            refresh "Refresh package indexes" \
            addrepo "Add a custom repository" \
            keys    "Signing keys and missing archive keyrings" \
            remove  "Delete a systui-added repository" \
            back    "Back") || return 0
        case "$c" in
            view)
                case "$PM" in
                    apt)    { grep -rHv '^\s*#' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -v '^\s*$'; } ;;
                    apk)    cat /etc/apk/repositories ;;
                    pacman) grep -A2 '^\[' /etc/pacman.conf | grep -v '^--' ;;
                    dnf)    dnf repolist --all ;;
                esac > ${SYSTUI_TMP}/repo 2>&1
                tui_text "Repositories" ${SYSTUI_TMP}/repo ;;
            manage)  repo_manage ;;
            listd)   repo_sources_listd ;;
            distro)  menu_distro_repos ;;
            popular) repo_popular ;;
            ppa)     menu_ppa_repos ;;
            refresh)
                case "$PM" in
                    apt)    run_cmd "apt-get update" apt-get update ;;
                    apk)    run_cmd "apk update" apk update ;;
                    pacman) run_cmd "pacman -Syy" pacman -Syy ;;
                    dnf)    run_cmd "dnf makecache" dnf makecache ;;
                esac ;;
            addrepo)
                case "$PM" in
                    apt)
                        local line name
                        line=$(tui_input "Add apt repo" "Full deb line, e.g.:\ndeb [signed-by=/etc/apt/keyrings/foo.gpg] https://repo.example.com stable main" "deb ") || continue
                        [ "$line" = "deb " ] && continue
                        name=$(tui_input "Add apt repo" "Short name for the .list file:" "custom") || continue
                        echo "$line" > "/etc/apt/sources.list.d/systui-$name.list"
                        tui_msg "Added" "Wrote /etc/apt/sources.list.d/systui-$name.list\nRemember to import its signing key, then refresh." ;;
                    apk)
                        local url
                        url=$(tui_input "Add apk repo" "Repository URL:" "") || continue
                        [ -z "$url" ] && continue
                        grep -qxF "$url" /etc/apk/repositories || echo "$url" >> /etc/apk/repositories
                        tui_msg "Added" "Appended to /etc/apk/repositories. Run refresh." ;;
                    pacman)
                        local name srv
                        name=$(tui_input "Add pacman repo" "Repo name (section header):" "") || continue
                        srv=$(tui_input "Add pacman repo" "Server URL (\$repo/\$arch vars allowed):" "") || continue
                        [ -z "$name" ] || [ -z "$srv" ] && continue
                        printf '\n[%s]\nServer = %s\n' "$name" "$srv" >> /etc/pacman.conf
                        tui_msg "Added" "Appended [$name] to /etc/pacman.conf.\nImport/trust its key, then refresh (-Syy)." ;;
                    dnf)
                        local url
                        url=$(tui_input "Add dnf repo" ".repo file URL or baseurl:" "") || continue
                        [ -z "$url" ] && continue
                        case "$url" in
                            *.repo) run_cmd "Adding repo file" bash -c "curl -fsSL '$url' -o /etc/yum.repos.d/systui-\$(basename '$url')" ;;
                            *)      run_cmd "dnf config-manager --add-repo" dnf config-manager --add-repo "$url" ;;
                        esac ;;
                esac ;;
            keys)
                case "$PM" in
                    apt)
                        local ka
                        ka=$(tui_menu "APT Keys" "Signing-key tools:" missing "Download distro keyrings from official repositories (SPACE-to-select)" import "Import key from URL" list "List installed keyrings" back "Back") || continue
                        case "$ka" in missing) apt_missing_keyrings_menu; continue;; list) find /etc/apt/keyrings /usr/share/keyrings -maxdepth 1 -type f 2>/dev/null | sort > ${SYSTUI_TMP}/keys; tui_text "APT keyrings" ${SYSTUI_TMP}/keys; continue;; back|"") continue;; esac
                        local url name
                        url=$(tui_input "apt key" "Key URL (.gpg or .asc):" "") || continue
                        [ -z "$url" ] && continue
                        name=$(tui_input "apt key" "Keyring filename (no extension):" "custom") || continue
                        mkdir -p /etc/apt/keyrings
                        run_cmd "Importing key -> /etc/apt/keyrings/$name.gpg" bash -c \
                          "curl -fsSL '$url' | gpg --dearmor --yes -o /etc/apt/keyrings/$name.gpg"
                        tui_msg "Key" "Reference it in the repo line with:\n  [signed-by=/etc/apt/keyrings/$name.gpg]" ;;
                    pacman)
                        local kid; kid=$(tui_input "pacman key" "Key ID or fingerprint:" "") || continue
                        [ -z "$kid" ] && continue
                        run_cmd "Importing pacman key $kid" bash -c \
                          "pacman-key --recv-keys '$kid' && pacman-key --lsign-key '$kid'" ;;
                    *)  tui_msg "N/A" "Key import helper covers apt and pacman.\napk uses /etc/apk/keys/; dnf imports keys per-repo (gpgkey=)." ;;
                esac ;;
            remove)
                local files f tags=()
                case "$PM" in
                    apt)  files=$(ls /etc/apt/sources.list.d/systui-*.list /etc/apt/sources.list.d/systui-*.list.disabled 2>/dev/null) ;;
                    dnf)  files=$(ls /etc/yum.repos.d/systui-*.repo 2>/dev/null) ;;
                    *)    tui_msg "Manual" "Use Manage to disable entries; deleting lines is manual\nfor $PM (single shared config file)."; continue ;;
                esac
                [ -z "$files" ] && { tui_msg "None" "No systui-added repos found."; continue; }
                for f in $files; do tags+=("$f" "$(basename "$f")" off); done
                local sel
                sel=$(tui_check "Delete repos" "SPACE selects files to DELETE, ENTER confirms:" "${tags[@]}") || continue
                sel=${sel//\"/}
                [ -z "${sel// }" ] && continue
                tui_yesno "Confirm" "Delete these repo files?\n\n$sel" || continue
                rm -f $sel
                [ "$PM" = apt ] && run_cmd "apt-get update" apt-get update ;;
            back) return 0 ;;
        esac
    done
}

# ---- Package catalogue: terminal-tool checklists ----------------------------
pkg_catalogue_cli() {
    while true; do
        local cat
        cat=$(tui_radio "Package Catalogue" "Category (SPACE to select, ENTER to confirm):" \
            core    "Core utilities (curl, git, tmux, rsync...)" on \
            dev     "Development (compilers, python, node...)" off \
            monitor "Monitoring & diagnostics (htop, ncdu, strace...)" off \
            net     "Network tools (nmap, tcpdump, dig...)" off \
            editors "Editors (nano, vim, neovim...)" off \
            shellx  "Shell extras (fzf, ripgrep, jq...)" off \
            back    "Back" off) || return 0
        [ "$cat" = back ] || [ -z "$cat" ] && return

        local sel=""
        case "$cat" in
            core) sel=$(tui_check "Core utilities" "SPACE toggles, ENTER installs:" \
                curl "Transfer tool $(st curl)" on \
                wget "Downloader $(st wget)" on \
                git "Version control $(st git)" on \
                tmux "Terminal multiplexer $(st tmux)" off \
                rsync "File sync $(st rsync)" off \
                unzip "Unzip archives $(st unzip)" off \
                zip "Create zip archives $(st zip)" off \
                tree "Directory trees $(st tree)" off \
                file "File type detection $(st file)" off \
                less "Pager $(st less)" off \
                man-db "Manual pages $(st man)" off \
                openssl "TLS toolkit $(st openssl)" off \
                gnupg "GnuPG $(st gpg)" off \
                ca-certificates "CA certificates" off) ;;
            dev) sel=$(tui_check "Development" "SPACE toggles, ENTER installs:" \
                build-essential "C/C++ toolchain (meta) $(st gcc)" on \
                gcc "GNU C compiler $(st gcc)" off \
                make "GNU make $(st make)" off \
                cmake "CMake $(st cmake)" off \
                pkg-config "pkg-config $(st pkg-config)" off \
                gdb "GNU debugger $(st gdb)" off \
                python3 "Python 3 $(st python3)" off \
                python3-pip "pip $(st pip3)" off \
                nodejs "Node.js $(st node)" off) ;;
            monitor) sel=$(tui_check "Monitoring" "SPACE toggles, ENTER installs:" \
                htop "Process viewer $(st htop)" on \
                iotop "I/O monitor $(st iotop)" off \
                ncdu "Disk usage browser $(st ncdu)" off \
                lsof "Open files $(st lsof)" off \
                strace "Syscall tracer $(st strace)" off \
                sysstat "sar/iostat suite $(st iostat)" off \
                fastfetch "System info banner $(st fastfetch)" off) ;;
            net) sel=$(tui_check "Network tools" "SPACE toggles, ENTER installs:" \
                iproute2 "ip / ss $(st ip)" on \
                net-tools "ifconfig / netstat $(st ifconfig)" off \
                nmap "Port scanner $(st nmap)" off \
                tcpdump "Packet capture $(st tcpdump)" off \
                mtr "traceroute + ping $(st mtr)" off \
                dnsutils "dig / nslookup $(st dig)" off \
                netcat-openbsd "netcat $(st nc)" off \
                ethtool "NIC settings $(st ethtool)" off \
                openssh-server "OpenSSH server $(st sshd)" off) ;;
            editors) sel=$(tui_check "Editors" "SPACE toggles, ENTER installs:" \
                nano "Nano $(st nano)" on \
                vim "Vim $(st vim)" off \
                neovim "Neovim $(st nvim)" off \
                micro "Micro $(st micro)" off \
                emacs "Emacs $(st emacs)" off) ;;
            shellx) sel=$(tui_check "Shell extras" "SPACE toggles, ENTER installs:" \
                bash-completion "Bash completion" on \
                fzf "Fuzzy finder $(st fzf)" off \
                ripgrep "rg — fast grep $(st rg)" off \
                fd-find "fd — fast find $(st fd)" off \
                jq "JSON processor $(st jq)" off \
                zsh "Zsh $(st zsh)" off \
                fish "Fish $(st fish)" off) ;;
        esac
        sel=${sel//\"/}
        [ -z "${sel// }" ] && continue
        local mapped; mapped=$(local_pkg_map $sel)
        show_warnings
        if [ -n "${mapped// }" ]; then local -a _pkgs=(); parse_package_input "$mapped" _pkgs && pm_install "${_pkgs[@]}"; fi
    done
}


# ---- Software catalogue (Discover-style) ------------------------------------
# Entries: "Debian-style key|Display name|Description". Package names are
# translated through local_pkg_map for Alpine, Arch and Fedora-family systems.

declare -A CAT_APPS=(
[internet]="firefox|Firefox|Mozilla web browser
chromium|Chromium|Open-source Chromium browser
thunderbird|Thunderbird|Email, calendar and RSS client
filezilla|FileZilla|FTP and SFTP client
transmission-gtk|Transmission|Lightweight BitTorrent client
qbittorrent|qBittorrent|Feature-rich BitTorrent client
remmina|Remmina|Remote desktop client
syncthing|Syncthing|Continuous peer-to-peer file synchronization
lynx|Lynx|Text-mode web browser
w3m|w3m|Text-mode web browser and pager"
[multimedia]="vlc|VLC|General-purpose media player
mpv|mpv|Minimal scriptable media player
ffmpeg|FFmpeg|Audio and video conversion toolkit
audacity|Audacity|Audio recording and editing
obs-studio|OBS Studio|Screen recording and streaming
kdenlive|Kdenlive|Non-linear video editor
handbrake|HandBrake|Video transcoder
yt-dlp|yt-dlp|Command-line media downloader
sox|SoX|Command-line audio processing"
[graphics]="gimp|GIMP|Raster image editor
inkscape|Inkscape|Vector graphics editor
krita|Krita|Digital painting
blender|Blender|3D modelling and rendering
darktable|darktable|RAW photo workflow
imagemagick|ImageMagick|Command-line image conversion and processing"
[office]="libreoffice|LibreOffice|Full office suite
okular|Okular|Universal document viewer
evince|Evince|Simple document viewer
calibre|Calibre|E-book library and conversion
xournalpp|Xournal++|Notes and PDF annotation
keepassxc|KeePassXC|Offline password manager
newsboat|Newsboat|Terminal RSS reader
calcurse|Calcurse|Terminal calendar and organizer
taskwarrior|Taskwarrior|Command-line task manager"
[development]="build-essential|Build toolchain|Compiler, linker and standard build tools
gcc|GCC|GNU C and C++ compiler
clang|Clang and LLVM|LLVM C and C++ compiler toolchain
cmake|CMake|Cross-platform build generator
meson|Meson|Fast modern build system
ninja-build|Ninja|Small high-speed build tool
make|GNU Make|Classic build automation
gdb|GDB|GNU debugger
lldb|LLDB|LLVM debugger
valgrind|Valgrind|Memory debugging and profiling
python3|Python 3|Python interpreter
python3-pip|pip|Python package installer
python3-venv|Python venv|Python virtual environments
nodejs|Node.js|JavaScript runtime
npm|npm|Node.js package manager
go|Go|Go compiler and tools
rust|Rust|Rust compiler toolchain
cargo|Cargo|Rust package and build manager
ruby|Ruby|Ruby language runtime
php-cli|PHP CLI|PHP command-line runtime
lua|Lua|Lightweight scripting language
java-default-jdk|Java JDK|Default Java development kit
sqlite3|SQLite|Embedded SQL database
postgresql|PostgreSQL|PostgreSQL database server
mariadb-server|MariaDB|MariaDB database server
redis-server|Redis|In-memory data store
geany|Geany|Lightweight graphical IDE
meld|Meld|Visual diff and merge
sqlitebrowser|DB Browser for SQLite|SQLite database GUI"
[terminal]="tmux|tmux|Terminal multiplexer
screen|GNU Screen|Terminal multiplexer
zellij|Zellij|Modern terminal workspace
fzf|fzf|Fuzzy finder
ripgrep|ripgrep|Fast recursive text search
fd-find|fd|Fast alternative to find
bat|bat|Syntax-highlighted cat replacement
jq|jq|JSON processor
yq|yq|YAML processor
zoxide|zoxide|Smarter directory navigation
broot|broot|Interactive directory navigator
ranger|Ranger|Console file manager
nnn|nnn|Fast terminal file manager
mc|Midnight Commander|Classic terminal file manager
lf|lf|Terminal file manager
eza|eza|Modern ls replacement
lazygit|Lazygit|Terminal Git interface
tig|tig|Terminal Git history browser"
[editors]="nano|Nano|Simple terminal editor
vim|Vim|Modal terminal editor
neovim|Neovim|Extensible Vim-based editor
micro|Micro|Modern terminal editor
emacs|Emacs|Extensible editor
helix|Helix|Modal post-modern editor"
[shells]="bash|Bash|GNU Bourne Again shell
bash-completion|Bash Completion|Shell completion definitions
zsh|Zsh|Interactive shell
fish|Fish|Friendly interactive shell
ksh|KornShell|Korn shell
mksh|MirBSD Korn Shell|Compact Korn shell
nushell|Nushell|Structured-data shell
starship|Starship|Cross-shell prompt
dash|dash|Debian Almquist shell
tcsh|tcsh|TENEX C shell
elvish|Elvish|Expressive modern shell
xonsh|xonsh|Python-powered shell
yash|yash|Yet another shell
pwsh|PowerShell|Microsoft PowerShell"
[network]="openssh-server|OpenSSH Server|Secure remote shell server
openssh-client|OpenSSH Client|SSH and SCP client tools
nmap|Nmap|Network scanner
tcpdump|tcpdump|Packet capture tool
wireshark|Wireshark|Network protocol analyzer
mtr|MTR|Combined ping and traceroute
traceroute|Traceroute|Trace network paths
dnsutils|DNS utilities|dig and nslookup
netcat-openbsd|Netcat|TCP and UDP utility
socat|socat|Bidirectional data relay
autossh|autossh|Automatically restart SSH tunnels
iperf3|iperf3|Network performance testing
rsync|rsync|Remote file synchronization
curl|curl|URL transfer tool
wget|wget|Network downloader"
[security]="gnupg|GnuPG|OpenPGP encryption and signing
openssl|OpenSSL|TLS and cryptography toolkit
fail2ban|Fail2ban|Block repeated authentication failures
clamav|ClamAV|Antivirus scanner
lynis|Lynis|Security auditing tool
aide|AIDE|File integrity monitor
john|John the Ripper|Password auditing tool
hashcat|Hashcat|Password recovery tool
ufw|UFW|Simple firewall frontend
nftables|nftables|Modern Linux packet filtering
sudo|sudo|Delegated privilege execution"
[monitoring]="htop|htop|Interactive process viewer
btop|btop|Resource monitor
glances|Glances|Cross-platform system monitor
iotop|iotop|Disk I/O monitor
iftop|iftop|Network bandwidth monitor
nethogs|NetHogs|Bandwidth usage by process
ncdu|ncdu|Interactive disk usage browser
duf|duf|Filesystem usage overview
du-dust|dust|Intuitive disk usage tool
lsof|lsof|List open files
strace|strace|System call tracer
ltrace|ltrace|Library call tracer
sysstat|sysstat|sar, iostat and performance tools
smartmontools|smartmontools|Disk health monitoring
fastfetch|Fastfetch|System information summary
stress-ng|stress-ng|System stress tester"
[servers]="nginx|Nginx|Web and reverse proxy server
apache2|Apache HTTP Server|General-purpose web server
lighttpd|Lighttpd|Lightweight web server
caddy|Caddy|Automatic HTTPS web server
samba|Samba|SMB file sharing
nfs-kernel-server|NFS Server|Network filesystem server
openssh-server|OpenSSH Server|Secure shell service
rsyslog|rsyslog|System logging daemon
chrony|Chrony|Clock synchronization
cron|Cron|Scheduled job daemon"
[containers]="docker.io|Docker|Container runtime and CLI
podman|Podman|Daemonless container engine
buildah|Buildah|OCI image builder
skopeo|Skopeo|Container image inspection and transfer
distrobox|Distrobox|Integrated container environments
lxc|LXC|System containers
qemu-system|QEMU|Machine emulator and virtualizer
virt-manager|virt-manager|Virtual machine manager"
[backup]="borgbackup|BorgBackup|Deduplicating backup program
restic|Restic|Fast encrypted backups
rclone|rclone|Cloud storage synchronization
duplicity|Duplicity|Encrypted incremental backups
rsnapshot|rsnapshot|Filesystem snapshot backups
syncthing|Syncthing|Peer-to-peer synchronization"
[files]="p7zip-full|7-Zip|7z archive support
zip|Zip|Create ZIP archives
unzip|Unzip|Extract ZIP archives
zstd|Zstandard|Fast compression
pigz|pigz|Parallel gzip
pbzip2|pbzip2|Parallel bzip2
xz-utils|XZ Utils|XZ compression tools
parted|Parted|Partition manipulation
gparted|GParted|Graphical partition editor
testdisk|TestDisk|Partition and file recovery
rsync|rsync|File synchronization
tree|tree|Directory tree display
file|file|File type identification"
[systemtools]="gparted|GParted|Partition editor
gnome-disk-utility|GNOME Disks|Disk management and benchmarking
bleachbit|BleachBit|Disk space cleaner
timeshift|Timeshift|System snapshots and restore
procps|procps|Process and system utilities
util-linux|util-linux|Core Linux system utilities
man-db|Manual pages|Manual page viewer
ca-certificates|CA certificates|Trusted certificate authorities"
[games]="supertuxkart|SuperTuxKart|Open-source kart racer
minetest|Luanti|Open voxel game engine
wesnoth|Battle for Wesnoth|Turn-based fantasy strategy"
)

CAT_ORDER="internet multimedia graphics office development terminal editors shells network security monitoring servers containers backup files systemtools games"
cat_title() {
    case "$1" in
        internet) echo "Internet & Web" ;; multimedia) echo "Multimedia" ;;
        graphics) echo "Graphics & Photography" ;; office) echo "Office & Productivity" ;;
        development) echo "Development & Databases" ;; terminal) echo "Terminal Productivity" ;;
        editors) echo "Editors" ;; shells) echo "Shells & Prompts" ;;
        network) echo "Networking" ;; security) echo "Security" ;;
        monitoring) echo "Monitoring & Diagnostics" ;; servers) echo "Servers & Services" ;;
        containers) echo "Containers & Virtualization" ;; backup) echo "Backup & Synchronization" ;;
        files) echo "Filesystems & Archives" ;; systemtools) echo "System Utilities" ;;
        games) echo "Games" ;; featured) echo "Featured" ;; *) echo "$1" ;;
    esac
}

FEATURED_APPS="curl git tmux neovim fzf ripgrep htop btop openssh-server rsync python3 build-essential"
declare -A CAT_COLLECTIONS=(
[ish]="bash bash-completion coreutils findutils grep sed gawk procps util-linux file less curl wget ca-certificates openssl openssh-client rsync nano vim tmux htop"
[developer]="git git-lfs build-essential gcc clang make cmake meson ninja-build pkg-config gdb python3 python3-pip python3-venv nodejs npm go rust cargo jq"
[terminal]="tmux fzf ripgrep fd-find bat jq zoxide broot ranger nnn mc lf lazygit tig fastfetch"
[server]="openssh-server sudo rsyslog chrony cron logrotate curl wget rsync bind9-dnsutils iproute2"
[network]="nmap tcpdump mtr traceroute dnsutils netcat-openbsd socat autossh iperf3 ethtool wireshark"
[security]="gnupg openssl fail2ban clamav lynis aide ufw nftables sudo"
[python]="python3 python3-pip python3-venv python3-dev build-essential git"
[rust]="rust cargo build-essential pkg-config git openssl"
[cpp]="build-essential gcc g++ clang make cmake meson ninja-build pkg-config gdb lldb valgrind git"
[web]="git nodejs npm python3 python3-pip nginx sqlite3 postgresql redis-server"
[backup]="borgbackup restic rclone duplicity rsnapshot rsync syncthing"
)

# apt-only fallbacks where package names vary between Debian-family releases.
declare -A APT_CANDIDATES=(
    [firefox]="firefox firefox-esr" [chromium]="chromium chromium-browser"
    [redis-server]="redis-server redis" [mariadb-server]="mariadb-server default-mysql-server"
    [qemu-system]="qemu-system qemu-system-x86" [java-default-jdk]="default-jdk openjdk-21-jdk openjdk-17-jdk"
)

is_pkg_installed() {
    case "$PM" in
        apt) dpkg -s "$1" >/dev/null 2>&1 ;;
        apk) apk info -e "$1" >/dev/null 2>&1 ;;
        pacman) pacman -Qi "$1" >/dev/null 2>&1 ;;
        dnf|yum|zypper) rpm -q "$1" >/dev/null 2>&1 ;;
        xbps) xbps-query "$1" >/dev/null 2>&1 ;;
        emerge) [ -n "$(portageq match / "$1" 2>/dev/null)" ] ;;
        *) return 1 ;;
    esac
}

app_native_name() {
    local key="$1"
    if [ "$PM" = apt ] && [ -n "${APT_CANDIDATES[$key]:-}" ]; then
        local c
        for c in ${APT_CANDIDATES[$key]}; do apt-cache show "$c" >/dev/null 2>&1 && { echo "$c"; return; }; done
    fi
    local m; m=$(local_pkg_map "$key")
    set -- $m
    echo "${1:-$key}"
}
app_status() { is_pkg_installed "$(app_native_name "$1")" && echo installed || echo available; }

catalogue_find_line() {
    local wanted="$1" cat
    for cat in $CAT_ORDER; do
        grep -m1 "^${wanted}|" <<< "${CAT_APPS[$cat]}" && return 0
    done
    return 1
}

pkg_show_info() {
    case "$PM" in
        apt) apt-cache show "$1" 2>&1 | head -80 ;; apk) apk info -a "$1" 2>&1 | head -80 ;;
        pacman) { pacman -Si "$1" 2>/dev/null || pacman -Qi "$1"; } 2>&1 | head -80 ;;
        dnf) dnf info "$1" 2>&1 | head -80 ;;
    esac
}

pkg_list_files() {
    case "$PM" in
        apt) dpkg -L "$1" ;; apk) apk info -L "$1" ;; pacman) pacman -Ql "$1" ;; dnf) rpm -ql "$1" ;;
    esac
}

pkg_reinstall() {
    case "$PM" in
        apt) run_cmd "Reinstall $1" apt-get install --reinstall -y "$1" ;;
        apk) run_cmd "Reinstall $1" apk fix --reinstall "$1" ;;
        pacman) run_cmd "Reinstall $1" pacman -S --noconfirm "$1" ;;
        dnf) run_cmd "Reinstall $1" dnf reinstall -y "$1" ;;
    esac
}

pkg_hold_toggle() {
    local p="$1"
    case "$PM" in
        apt) if apt-mark showhold | grep -qx "$p"; then run_cmd "Unhold $p" apt-mark unhold "$p"; else run_cmd "Hold $p" apt-mark hold "$p"; fi ;;
        apk) tui_msg "Package hold" "Use an exact version constraint in /etc/apk/world for apk." ;;
        pacman) tui_msg "Package hold" "Add $p to IgnorePkg in /etc/pacman.conf." ;;
        dnf) command -v dnf >/dev/null && run_cmd "Version-lock $p" dnf versionlock add "$p" ;;
    esac
}

app_page() {
    local key="$1" name="$2" desc="$3"
    while true; do
        local native stat c
        native=$(app_native_name "$key"); stat=$(app_status "$key")
        c=$(tui_menu "$name" "$desc

Package : $native ($PM)
Status  : $stat" \
            install "Install" remove "Remove" reinstall "Reinstall" \
            details "Package metadata" files "Installed files" hold "Hold / unhold version" \
            verify "Verify package integrity" back "Back") || return 0
        case "$c" in
            install)
                if [ "$stat" = installed ]; then
                    tui_msg "Installed" "$name is already installed."
                else
                    case "$key" in
                        docker.io|docker|docker-ce) menu_docker_install ;;
                        nodejs|node)               menu_node_install ;;
                        ripgrep)                   menu_ripgrep_install ;;
                        neovim)                    menu_neovim_install ;;
                        micro)                     menu_micro_install ;;
                        fzf)                       menu_fzf_install ;;
                        starship)                  menu_starship_install ;;
                        fish)                      menu_fish_install ;;
                        zsh)                       menu_zsh_install ;;
                        nushell|nu)                menu_nushell_install ;;
                        *)                         pm_install "$native" ;;
                    esac
                fi ;;
            remove) [ "$stat" = available ] && tui_msg "Not installed" "$name is not installed." || { tui_yesno "Remove" "Remove $name ($native)?" && pm_remove "$native"; } ;;
            reinstall) [ "$stat" = installed ] && pkg_reinstall "$native" || tui_msg "Not installed" "$name must be installed first." ;;
            details) pkg_show_info "$native" > ${SYSTUI_TMP}/pkg 2>&1; [ -s ${SYSTUI_TMP}/pkg ] || echo "No repository metadata found." > ${SYSTUI_TMP}/pkg; tui_text "$name — metadata" ${SYSTUI_TMP}/pkg ;;
            files) pkg_list_files "$native" > ${SYSTUI_TMP}/pkg 2>&1; [ -s ${SYSTUI_TMP}/pkg ] || echo "Package is not installed or no file list is available." > ${SYSTUI_TMP}/pkg; tui_text "$name — installed files" ${SYSTUI_TMP}/pkg ;;
            hold) pkg_hold_toggle "$native" ;;
            verify) case "$PM" in apt) dpkg -V "$native" ;; apk) apk audit "$native" ;; pacman) pacman -Qkk "$native" ;; dnf) rpm -V "$native" ;; esac > ${SYSTUI_TMP}/pkg 2>&1; [ -s ${SYSTUI_TMP}/pkg ] || echo "No integrity problems reported." > ${SYSTUI_TMP}/pkg; tui_text "$name — integrity" ${SYSTUI_TMP}/pkg ;;
            back) return 0 ;;
        esac
        show_warnings
    done
}

browse_category() {
    local cat="$1" data="" k line
    if [ -n "${2:-}" ]; then
        for k in $2; do line=$(catalogue_find_line "$k"); [ -n "$line" ] && data+="$line"$'\n'; done
    else data="${CAT_APPS[$cat]}"; fi
    while true; do
        # Checklist first: every entry in the category is selectable, checked
        # when already installed. Confirming applies the difference -- newly
        # checked entries are installed, entries unchecked from an installed
        # state are offered for removal.
        local args=() key name desc st installed="" picks
        while IFS='|' read -r key name desc; do
            [ -z "$key" ] && continue
            if [ "$(app_status "$key")" = installed ]; then
                st=on; installed="$installed $key"
            else
                st=off
            fi
            args+=("$key" "$name — $desc" "$st")
        done <<< "$data"
        [ ${#args[@]} -gt 0 ] || { tui_msg "Empty" "No software is listed in this category."; return 0; }
        args+=(show-details "» Show the details page for one item (does not apply changes)" off)

        picks=$(tui_check "$(cat_title "$cat")" \
"SPACE toggles. Checked entries are installed, entries you uncheck are offered for removal.
Checked items are already installed." "${args[@]}") || return 0
        picks=${picks//\"/}

        # The details escape hatch is handled on its own so a stray selection
        # cannot silently install something the user only wanted to read about.
        case " $picks " in
            *" show-details "*)
                local dargs=() sel
                while IFS='|' read -r key name desc; do
                    [ -z "$key" ] && continue
                    dargs+=("$key" "$name")
                done <<< "$data"
                sel=$(tui_menu_no_tags "Details" "Select an item to inspect:" "${dargs[@]}" __back "Back") || continue
                [ "$sel" = __back ] && continue
                line=$(grep -m1 "^$sel|" <<< "$data")
                [ -n "$line" ] && app_page "$sel" "$(cut -d'|' -f2 <<<"$line")" "$(cut -d'|' -f3- <<<"$line")"
                continue ;;
        esac

        # Install everything newly checked.
        local to_install="" to_remove="" n
        for k in $picks; do
            [ "$k" = show-details ] && continue
            case " $installed " in *" $k "*) ;; *)
                n=$(app_native_name "$k"); [ "$n" != SKIP ] && to_install="$to_install $n" ;;
            esac
        done
        # Offer removal for anything unchecked that is currently installed.
        for k in $installed; do
            case " $picks " in *" $k "*) ;; *)
                n=$(app_native_name "$k"); [ "$n" != SKIP ] && to_remove="$to_remove $n" ;;
            esac
        done

        if [ -z "${to_install// }" ] && [ -z "${to_remove// }" ]; then
            tui_msg "No changes" "The selection matches what is already installed."
            continue
        fi
        if [ -n "${to_install// }" ]; then
            local -a _pkgs=()
            if tui_yesno "Install" "Install $(wc -w <<< "$to_install") package(s)?\n\n$to_install"; then
                parse_package_input "$to_install" _pkgs && pm_install "${_pkgs[@]}"
            fi
        fi
        if [ -n "${to_remove// }" ]; then
            local -a _rpkgs=()
            if tui_yesno "Remove" "You unchecked $(wc -w <<< "$to_remove") installed package(s).\n\n$to_remove\n\nRemove them?"; then
                parse_package_input "$to_remove" _rpkgs && pm_remove "${_rpkgs[@]}"
            fi
        fi
        show_warnings
    done
}

catalogue_collections() {
    while true; do
        local c
        c=$(tui_menu "Software Collections" "Install curated package groups:" \
            ish "iSH-AOK essentials" developer "Developer workstation" terminal "Terminal power user" \
            server "Minimal server" network "Networking toolkit" security "Security toolkit" \
            python "Python development" rust "Rust development" cpp "C/C++ development" \
            web "Web development" backup "Backup toolkit" back "Back") || return 0
        [ "$c" = back ] && return
        local keys="${CAT_COLLECTIONS[$c]:-}" k n st
        [ -z "$keys" ] && continue
        # Space-to-select rather than an all-or-nothing prompt: collections mix
        # things the user already has with things they may not want.
        local cargs=() picks mapped=""
        for k in $keys; do
            n=$(app_native_name "$k"); [ "$n" = SKIP ] && continue
            is_pkg_installed "$n" && st=off || st=on
            cargs+=("$k" "$n$(is_pkg_installed "$n" && echo " [installed]")" "$st")
        done
        [ ${#cargs[@]} -gt 0 ] || { tui_msg "Empty" "No installable packages map to this collection on $PM."; continue; }
        picks=$(tui_check "$(cat_title "$c")" "SPACE toggles. Already-installed packages start unchecked:" "${cargs[@]}") || continue
        picks=${picks//\"/}
        for k in $picks; do n=$(app_native_name "$k"); [ "$n" != SKIP ] && mapped+=" $n"; done
        if [ -z "${mapped// }" ]; then tui_msg "No selection" "Nothing was selected."; continue; fi
        local -a _pkgs=()
        parse_package_input "$mapped" _pkgs && pm_install "${_pkgs[@]}"
        show_warnings
    done
}

catalogue_bulk_manage() {
    local c
    c=$(tui_menu "Bulk package actions" "Manage package sets:" export "Export installed package list" import "Install packages from a list" remove "Bulk remove packages" back "Back") || return 0
    case "$c" in
        export)
            local out
            out="${HOME}/systui-installed-${PM}-$(date +%Y%m%d-%H%M%S).txt"
            case "$PM" in apt) dpkg-query -W -f='${binary:Package}\n' ;; apk) apk info ;; pacman) pacman -Qq ;; dnf) rpm -qa --qf '%{NAME}\n' ;; esac | sort -u > "$out"
            tui_msg "Export complete" "Saved package list to:\n$out" ;;
        import)
            local f; f=$(tui_input "Import package list" "Path to text file (one package per line):" "") || return 0
            [ -f "$f" ] || { tui_msg "Error" "File not found: $f"; return; }
            local pkgs; pkgs=$(grep -Ev '^[[:space:]]*(#|$)' "$f" | tr '\n' ' ')
            if [ -n "$pkgs" ]; then local -a _pkgs=(); parse_package_input "$pkgs" _pkgs && pm_install "${_pkgs[@]}"; fi ;;
        remove)
            local p; p=$(tui_input "Bulk remove" "Packages to remove (space-separated):" "") || return 0
            if [ -n "$p" ] && tui_yesno "Confirm removal" "Remove these packages?\n\n$p"; then local -a _pkgs=(); parse_package_input "$p" _pkgs && pm_remove "${_pkgs[@]}"; fi ;;
    esac
}

catalogue_health() {
    while true; do
        local c
        c=$(tui_menu "Package Health" "Inspect and repair package state:" broken "Broken dependencies" orphans "Orphaned / unused packages" verify "Verify installed packages" clean "Clean caches and unused packages" back "Back") || return 0
        case "$c" in
            broken) case "$PM" in apt) dpkg --audit; apt-get check ;; apk) apk audit --system ;; pacman) pacman -Dk ;; dnf) dnf check ;; esac > ${SYSTUI_TMP}/pkg 2>&1; [ -s ${SYSTUI_TMP}/pkg ] || echo "No broken package state detected." > ${SYSTUI_TMP}/pkg; tui_text "Broken dependencies" ${SYSTUI_TMP}/pkg ;;
            orphans) case "$PM" in apt) apt-mark showauto | while read -r p; do apt-mark showmanual | grep -qx "$p" || echo "$p"; done ;; apk) apk info -W 2>/dev/null ;; pacman) pacman -Qtdq ;; dnf) dnf repoquery --unneeded ;; esac > ${SYSTUI_TMP}/pkg 2>&1; [ -s ${SYSTUI_TMP}/pkg ] || echo "No orphaned packages found." > ${SYSTUI_TMP}/pkg; tui_text "Orphaned packages" ${SYSTUI_TMP}/pkg ;;
            verify) case "$PM" in apt) dpkg -C ;; apk) apk audit --system ;; pacman) pacman -Qkk ;; dnf) rpm -Va ;; esac > ${SYSTUI_TMP}/pkg 2>&1; [ -s ${SYSTUI_TMP}/pkg ] || echo "No integrity problems reported." > ${SYSTUI_TMP}/pkg; tui_text "Package verification" ${SYSTUI_TMP}/pkg ;;
            clean) pm_clean ;;
            back) return 0 ;;
        esac
    done
}

catalogue_updates() {
    case "$PM" in
        apt) apt-get update >/dev/null 2>&1; apt list --upgradable 2>/dev/null | tail -n +2 ;;
        apk) apk update >/dev/null 2>&1; apk version -l '<' 2>/dev/null ;;
        # A bare `pacman -Sy` leaves the sync database newer than the installed
        # packages, which is the precondition for a partial upgrade the next
        # time anything is installed. checkupdates (pacman-contrib) syncs into
        # a temporary database instead; without it, report against the existing
        # database rather than desynchronising the system to produce a list.
        pacman)
            if command -v checkupdates >/dev/null 2>&1; then checkupdates 2>/dev/null
            else pacman -Qu 2>/dev/null
            fi ;;
        dnf|yum) dnf check-update 2>/dev/null | awk 'NF==3' ;;
        zypper) zypper --non-interactive list-updates 2>/dev/null | awk -F'|' 'NR>4 {print $3, $5}' ;;
        xbps) xbps-install -Sun 2>/dev/null ;;
    esac > ${SYSTUI_TMP}/pkg
    if [ -s ${SYSTUI_TMP}/pkg ]; then local n; n=$(wc -l < ${SYSTUI_TMP}/pkg); tui_text "Updates available ($n)" ${SYSTUI_TMP}/pkg; tui_yesno "Upgrade" "Install all $n updates now?" && pm_update; else tui_msg "Up to date" "No updates available."; fi
}

catalogue_installed() {
    { echo "Catalogue applications installed:"; echo; local cat key name desc; for cat in $CAT_ORDER; do while IFS='|' read -r key name desc; do [ -z "$key" ] && continue; is_pkg_installed "$(app_native_name "$key")" && printf "%-24s %s\n" "$name" "($(app_native_name "$key"))"; done <<< "${CAT_APPS[$cat]}"; done; } > ${SYSTUI_TMP}/pkg
    tui_text "Installed catalogue software" ${SYSTUI_TMP}/pkg
}

catalogue_search() {
    local t; t=$(tui_input "Search" "Search package repositories:" "") || return 0; [ -z "$t" ] && return
    pm_search "$t" 2>&1 | head -150 > ${SYSTUI_TMP}/pkg; [ -s ${SYSTUI_TMP}/pkg ] || echo "No results." > ${SYSTUI_TMP}/pkg
    tui_text "Search: $t" ${SYSTUI_TMP}/pkg
    tui_yesno "Install" "Install a package from these results?" || return 0
    local p; p=$(tui_input "Install" "Exact package name:" "") || return 0; [ -n "$p" ] && pm_install "$p"
}

pkg_catalogue() {
    while true; do
        local c args=() cat
        args=(featured "* Featured software" collections "Curated one-click collections")
        for cat in $CAT_ORDER; do args+=("$cat" "$(cat_title "$cat")"); done
        args+=(cli "Terminal-tool checklists" installed "Installed catalogue software" updates "Available updates" search "Search all repositories" bulk "Bulk actions and package lists" health "Package health and repair" back "Back")
        c=$(tui_menu "Software Catalogue  [$PM]" "Browse, install and manage software:" "${args[@]}") || return 0
        case "$c" in
            featured) browse_category featured "$FEATURED_APPS" ;; collections) catalogue_collections ;;
            cli) pkg_catalogue_cli ;; installed) catalogue_installed ;; updates) catalogue_updates ;;
            search) catalogue_search ;; bulk) catalogue_bulk_manage ;; health) catalogue_health ;; back) return 0 ;;
            *) browse_category "$c" ;;
        esac
    done
}


# ---- Service wrapper (init-agnostic) ---------------------------------------
svc() {  # svc <enable|disable|start|stop|restart|status> <service>
    local action="$1" s="$2"
    case "$INIT" in
        systemd)
            systemctl "$action" "$s" ;;
        openrc)
            case "$action" in
                enable)  rc-update add "$s" default ;;
                disable) rc-update del "$s" default ;;
                *)       rc-service "$s" "$action" ;;
            esac ;;
        runit)
            case "$action" in
                enable)  ln -sf "/etc/sv/$s" /var/service/ 2>/dev/null || ln -sf "/etc/runit/sv/$s" /run/runit/service/ ;;
                disable) rm -f "/var/service/$s" "/run/runit/service/$s" ;;
                start)   sv up "$s" ;;
                stop)    sv down "$s" ;;
                restart) sv restart "$s" ;;
                status)  sv status "$s" ;;
            esac ;;
        sysvinit)
            case "$action" in
                enable)  command -v update-rc.d >/dev/null && update-rc.d "$s" defaults || chkconfig "$s" on ;;
                disable) command -v update-rc.d >/dev/null && update-rc.d "$s" remove   || chkconfig "$s" off ;;
                *)       service "$s" "$action" ;;
            esac ;;
        *) tui_msg "Error" "Unknown init system — cannot manage services." ; return 1 ;;
    esac
}

# Package-manager hub. Keeps native and language/application package managers
# separate from repositories and the software catalogue.
pm_status() { command -v "$1" >/dev/null 2>&1 && printf '[installed]' || printf '[not installed]'; }

pm_edit_file() {
    local f="$1"
    mkdir -p "$(dirname "$f")"
    touch "$f"
    safe_edit "$f"
}

pm_show_command() {
    local title="$1"; shift
    "$@" > ${SYSTUI_TMP}/pkg 2>&1 || true
    tui_text "$title" ${SYSTUI_TMP}/pkg
}

pm_generic_health() {
    local cmd="$1" version_arg="${2:---version}"
    {
        echo "Executable: $(command -v "$cmd" 2>/dev/null || echo missing)"
        echo
        "$cmd" "$version_arg" 2>&1 || true
    } > ${SYSTUI_TMP}/pkg
    tui_text "$cmd health" ${SYSTUI_TMP}/pkg
}

menu_cfg_apt() {
    while true; do
        local c
        c=$(tui_menu "APT configuration" "Configure APT and dpkg:" \
            advanced "Advanced settings (SPACE to select)" \
            tune "Performance/download tuning" config "Edit apt.conf.d configuration" \
            policy "Show package policy" verify "Verify package database" \
            repair "Repair interrupted/broken packages" cache "Clean package caches" \
            history "Show dpkg transaction history" reset "Remove SysTUI tuning file" back "Back") || return 0
        case "$c" in
            advanced) pm_advanced_menu apt ;;
            tune) menu_cfg_native ;;
            config) pm_edit_file /etc/apt/apt.conf.d/90systui-custom ;;
            policy) pm_show_command "APT policy" apt-cache policy ;;
            verify) run_cmd "Verify dpkg database" dpkg --audit ;;
            repair) run_cmd "Repair APT/dpkg" bash -c 'dpkg --configure -a && apt-get -f install -y' ;;
            cache) run_cmd "Clean APT caches" bash -c 'apt-get clean && apt-get autoclean && apt-get autoremove -y' ;;
            history) { zgrep -hE '^(Start-Date|Commandline|Install:|Upgrade:|Remove:|End-Date)' /var/log/apt/history.log* 2>/dev/null | tail -250 || true; } > ${SYSTUI_TMP}/pkg; tui_text "APT history" ${SYSTUI_TMP}/pkg ;;
            reset) rm -f /etc/apt/apt.conf.d/90systui-tune /etc/apt/apt.conf.d/90systui-custom; tui_msg "Reset" "SysTUI APT configuration removed." ;;
            back|"") return 0 ;;
        esac
    done
}

menu_cfg_cli_manager() { # id command config install-package [install-fn]
    local id="$1" cmd="$2" cfg="$3" pkg="${4:-$2}" install_fn="${5:-}" c q
    if ! command -v "$cmd" >/dev/null 2>&1; then
        tui_yesno "$id" "$id is not installed. Install it now?" || return 0
        if [ -n "$install_fn" ] && declare -f "$install_fn" >/dev/null 2>&1; then
            "$install_fn" || return 0
        else
            pm_install "$pkg" || return 0
        fi
    fi
    while true; do
        c=$(tui_menu "$id configuration" "Manage $id:" \
            advanced "Advanced settings (SPACE to select)" \
            version "Version and executable" install "Install package/application" \
            update "Update installed packages" list "List installed packages" \
            cache "Clean or inspect cache" config "Edit configuration" \
            doctor "Diagnostics/health check" \
            setup "$([ "$id" = brew ] && echo 'Setup / reinstall / root config' || echo '')" \
            back "Back") || return 0
        case "$c" in
            advanced) pm_advanced_menu "$id" ;;
            version) pm_generic_health "$cmd" ;;
            setup)
                [ "$id" = brew ] && menu_brew_install
                ;;
            install)
                if [ "$id" = brew ]; then
                    menu_brew_pkgops
                else
                    q=$(tui_input "$id install" "Package/application name:" "") || continue
                    [ -z "$q" ] && continue
                    case "$id" in
                        pip) pip3 install --break-system-packages $q 2>/dev/null || pip3 install $q ;;
                        pipx) pipx install "$q" ;;
                        npm) npm install -g "$q" ;;
                        pnpm) pnpm add -g "$q" ;;
                        yarn) yarn global add "$q" ;;
                        cargo) cargo install "$q" ;;
                        gem) gem install "$q" ;;
                        composer) composer global require "$q" ;;
                        go) GOBIN="${GOBIN:-$HOME/go/bin}" go install "$q" ;;
                        nix) nix profile install "$q" ;;
                    esac
                fi ;;
            update)
                case "$id" in
                    pip) pip3 list --outdated; tui_msg "pip" "Use the install action with an exact package to upgrade safely." ;;
                    pipx) pipx upgrade-all ;;
                    npm) npm update -g ;;
                    pnpm) pnpm update -g ;;
                    yarn) yarn global upgrade ;;
                    cargo) command -v cargo-install-update >/dev/null && cargo install-update -a || tui_msg "Cargo" "Install cargo-update to enable bulk crate upgrades." ;;
                    gem) gem update ;;
                    composer) composer global update ;;
                    go) tui_msg "Go" "Go does not maintain a global upgrade database; reinstall modules with @latest." ;;
                    brew) brew_run_as "brew update && upgrade" update && brew_run_as "brew upgrade" upgrade ;;
                    nix) nix profile upgrade '.*' ;;
                esac ;;
            list)
                case "$id" in
                    pip) pip3 list ;;
                    pipx) pipx list ;;
                    npm) npm list -g --depth=0 ;;
                    pnpm) pnpm list -g --depth=0 ;;
                    yarn) yarn global list ;;
                    cargo) cargo install --list ;;
                    gem) gem list ;;
                    composer) composer global show ;;
                    go) find "${GOBIN:-$HOME/go/bin}" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null ;;
                    brew) { local _btu; _btu=$(brew_target_user); if [ -n "$_btu" ] && [ "$_btu" != root ] && [ "$(id -u)" -eq 0 ]; then sudo -u "$_btu" -H brew list --versions; else brew list --versions; fi; } ;;
                    nix) nix profile list ;;
                esac > ${SYSTUI_TMP}/pkg 2>&1; tui_text "$id installed" ${SYSTUI_TMP}/pkg ;;
            cache)
                case "$id" in
                    pip) pip3 cache info; tui_yesno "pip cache" "Purge pip cache?" && pip3 cache purge ;;
                    pipx) pipx reinstall-all ;;
                    npm) npm cache verify; tui_yesno "npm cache" "Clean npm cache forcibly?" && npm cache clean --force ;;
                    pnpm) pnpm store status; tui_yesno "pnpm store" "Prune unused store content?" && pnpm store prune ;;
                    yarn) yarn cache dir; tui_yesno "Yarn cache" "Clean Yarn cache?" && yarn cache clean ;;
                    cargo) du -sh "${CARGO_HOME:-$HOME/.cargo}" 2>/dev/null; tui_yesno "Cargo cache" "Remove registry cache (downloads only)?" && rm -rf "${CARGO_HOME:-$HOME/.cargo}/registry/cache" ;;
                    gem) gem cleanup ;;
                    composer) composer clear-cache ;;
                    go) go clean -cache -testcache; tui_msg "Go cache" "Build and test caches cleaned." ;;
                    brew) brew_run_as "brew cleanup" cleanup -s ;;
                    nix) nix store gc ;;
                esac ;;
            config)
                if [ "$id" = brew ]; then
                    menu_brew_config
                else
                    [ -n "$cfg" ] && pm_edit_file "$cfg" || tui_msg "$id" "No single configuration file is used by this manager."
                fi ;;
            doctor)
                case "$id" in
                    pip) pip3 check ;;
                    pipx) pipx environment ;;
                    npm) npm doctor ;;
                    pnpm) pnpm doctor 2>/dev/null || pnpm config list ;;
                    yarn) yarn config list ;;
                    cargo) cargo --version --verbose ;;
                    gem) gem environment ;;
                    composer) composer diagnose ;;
                    go) go env ;;
                    brew) { local _btu; _btu=$(brew_target_user); if [ -n "$_btu" ] && [ "$_btu" != root ] && [ "$(id -u)" -eq 0 ]; then sudo -u "$_btu" -H brew doctor; else brew doctor; fi; } ;;
                    nix) nix config show 2>/dev/null || nix show-config ;;
                esac > ${SYSTUI_TMP}/pkg 2>&1; tui_text "$id diagnostics" ${SYSTUI_TMP}/pkg ;;
            back|"") return 0 ;;
        esac
    done
}

menu_cfg_flatpak() {
    command -v flatpak >/dev/null 2>&1 || { tui_yesno "Flatpak" "Install Flatpak now?" || return; menu_flatpak_install; }
    while true; do
        local c q
        c=$(tui_menu "Flatpak configuration" "Manage Flatpak:" advanced "Advanced settings (SPACE to select)" remotes "Manage/list remotes" flathub "Add Flathub" permissions "Show application overrides" repair "Repair installation" unused "Remove unused runtimes" update "Update all" config "Edit global installation config" back "Back") || return
        case "$c" in
            advanced) pm_advanced_menu flatpak ;;
            remotes) pm_show_command "Flatpak remotes" flatpak remotes --show-details ;;
            flathub) flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo ;;
            permissions) pm_show_command "Flatpak overrides" flatpak override --show ;;
            repair) run_cmd "Flatpak repair" flatpak repair ;;
            unused) run_cmd "Remove unused Flatpak runtimes" flatpak uninstall --unused -y ;;
            update) run_cmd "Flatpak update" flatpak update -y ;;
            config) pm_edit_file /var/lib/flatpak/repo/config ;;
            back|"") return ;;
        esac
    done
}

menu_cfg_snap() {
    command -v snap >/dev/null 2>&1 || { tui_yesno "Snap" "Install snapd now?" || return; menu_snap_install; }
    while true; do
        local c v
        c=$(tui_menu "Snap configuration" "Manage snapd:" advanced "Advanced settings (SPACE to select)" changes "Recent changes" refresh "Refresh all snaps" schedule "Show refresh schedule" hold "Set refresh hold" snapshots "List snapshots" connections "List interfaces/connections" config "Show system configuration" back "Back") || return
        case "$c" in
            advanced) pm_advanced_menu snap ;;
            changes) pm_show_command "Snap changes" snap changes ;;
            refresh) snap refresh ;;
            schedule) pm_show_command "Snap refresh schedule" snap refresh --time ;;
            hold) v=$(tui_input "Refresh hold" "Hold duration/date (example: 24h or 2026-08-01T00:00:00Z):" "24h") || continue; snap set system refresh.hold="$v" ;;
            snapshots) pm_show_command "Snap snapshots" snap saved ;;
            connections) pm_show_command "Snap connections" snap connections ;;
            config) pm_show_command "Snap system config" snap get system ;;
            back|"") return ;;
        esac
    done
}

menu_cfg_native_full() {
    while true; do
        local c
        c=$(tui_menu "Native manager: $PM" "Configure and maintain the active native package manager:" advanced "Advanced settings (SPACE to select)" tune "Configuration and performance tuning" repos "Repository management" update "Refresh and upgrade" cache "Cache cleanup" verify "Database/package verification" history "Transaction history" edit "Edit primary configuration" back "Back") || return
        case "$c" in
            advanced) pm_advanced_menu "$PM" ;;
            tune) menu_cfg_native ;;
            repos) menu_repos ;;
            update) pm_update ;;
            cache) pm_clean ;;
            verify)
                case "$PM" in apt) dpkg --audit;; pacman) pacman -Dk;; dnf) dnf check;; yum) yum check;; zypper) zypper verify;; apk) apk audit --system;; xbps) xbps-pkgdb -a;; emerge) equery check '*' 2>/dev/null;; esac > ${SYSTUI_TMP}/pkg 2>&1; tui_text "$PM verification" ${SYSTUI_TMP}/pkg ;;
            history)
                case "$PM" in apt) zgrep -hE '^(Start-Date|Commandline|Install:|Upgrade:|Remove:)' /var/log/apt/history.log* 2>/dev/null;; pacman) tail -250 /var/log/pacman.log;; dnf|yum) "$PM" history;; zypper) tail -250 /var/log/zypp/history;; apk) echo 'apk does not record transaction history by default.';; xbps) tail -250 /var/log/socklog/xbps/current 2>/dev/null;; emerge) tail -250 /var/log/emerge.log;; esac > ${SYSTUI_TMP}/pkg 2>&1; tui_text "$PM history" ${SYSTUI_TMP}/pkg ;;
            edit)
                case "$PM" in apt) pm_edit_file /etc/apt/apt.conf.d/90systui-custom;; pacman) pm_edit_file /etc/pacman.conf;; dnf) pm_edit_file /etc/dnf/dnf.conf;; yum) pm_edit_file /etc/yum.conf;; zypper) pm_edit_file /etc/zypp/zypp.conf;; apk) pm_edit_file /etc/apk/repositories;; xbps) pm_edit_file /etc/xbps.d/00-repository-main.conf;; emerge) pm_edit_file /etc/portage/make.conf;; esac ;;
            back|"") return ;;
        esac
    done
}

###############################################################################
# ADVANCED PACKAGE-MANAGER CONFIGURATION
###############################################################################
#
# Every manager in the Package Managers list gets an "Advanced" entry backed by
# a space-to-select checklist. Native managers write real configuration files;
# language managers write their own rc/config files. Current state is read back
# and pre-checked so the checklist always reflects what is actually configured.

# Reads a key from a simple "key=value" style config, ignoring comments.
pm_adv_get() { # <file> <key> [separator]
    local f="$1" k="$2" sep="${3:-=}"
    [ -r "$f" ] || return 1
    grep -E "^[[:space:]]*${k}[[:space:]]*${sep}" "$f" 2>/dev/null | head -1 |
        sed -E "s|^[[:space:]]*${k}[[:space:]]*${sep}[[:space:]]*||; s|[[:space:]]*$||"
}

pm_adv_state() { # <condition-command...> -> on|off
    if "$@" >/dev/null 2>&1; then printf 'on'; else printf 'off'; fi
}

pm_adv_has() { # <selection> <tag>
    case " ${1//\"/} " in *" $2 "*) return 0 ;; esac
    return 1
}

# Writes a managed block into a config file, replacing any previous block.
pm_adv_write_block() { # <file> <marker> <content-on-stdin>
    local f="$1" marker="$2" tmp
    mkdir -p "$(dirname "$f")" || return 1
    [ -f "$f" ] || : > "$f"
    tmp=$(mktemp "${f}.systui.XXXXXX") || return 1
    awk -v m="$marker" '
        $0 == "# systui-" m " begin" { skip = 1 }
        skip && $0 == "# systui-" m " end" { skip = 0; next }
        !skip { print }
    ' "$f" > "$tmp"
    {
        printf '# systui-%s begin\n' "$marker"
        cat
        printf '# systui-%s end\n' "$marker"
    } >> "$tmp"
    cat "$tmp" > "$f"
    rm -f "$tmp"
}

pm_adv_apt() {
    local f=/etc/apt/apt.conf.d/90systui-advanced o n
    o=$(tui_check "APT — advanced" "Current state pre-checked. SPACE toggles, ENTER writes $f:" \
        norecommends  "Do not install recommended packages" "$(pm_adv_state grep -q 'Install-Recommends "false"' "$f")" \
        nosuggests    "Do not install suggested packages" "$(pm_adv_state grep -q 'Install-Suggests "false"' "$f")" \
        autoremove    "Automatically remove unused dependencies" "$(pm_adv_state grep -q 'AutomaticRemove "true"' "$f")" \
        keepdownloads "Keep downloaded .deb files after install" "$(pm_adv_state grep -q 'Keep-Downloaded-Packages "true"' "$f")" \
        noauthwarn    "Fail rather than warn on unauthenticated packages" "$(pm_adv_state grep -q 'AllowUnauthenticated "false"' "$f")" \
        parallel      "Enable parallel downloads" "$(pm_adv_state grep -q 'Queue-Mode' "$f")" \
        pipeline      "Use HTTP pipelining (faster on good links)" "$(pm_adv_state grep -q 'Pipeline-Depth' "$f")" \
        noproxycache  "Bypass proxy caches for index files" "$(pm_adv_state grep -q 'No-Cache "true"' "$f")" \
        ipv4          "Force IPv4 for downloads" "$(pm_adv_state grep -q 'ForceIPv4' "$f")" \
        timeout       "Shorter network timeout (30s)" "$(pm_adv_state grep -q 'Timeout "30"' "$f")" \
        retries       "Retry failed downloads three times" "$(pm_adv_state grep -q 'Retries "3"' "$f")" \
        languages     "Skip translation index downloads" "$(pm_adv_state grep -q 'Languages "none"' "$f")" \
        nopdiffs      "Disable pdiff index updates" "$(pm_adv_state grep -q 'PDiffs "false"' "$f")" \
        installsafe   "Never remove essential packages automatically" "$(pm_adv_state grep -q 'Protect-Essential' "$f")" \
        quiet         "Reduce output verbosity" "$(pm_adv_state grep -q 'quiet "1"' "$f")" \
        color         "Colourise APT output" "$(pm_adv_state grep -q 'Color "true"' "$f")") || return 0
    mkdir -p "$(dirname "$f")"
    {
        echo '// Generated by systui. Edits are replaced on the next run.'
        pm_adv_has "$o" norecommends  && echo 'APT::Install-Recommends "false";'
        pm_adv_has "$o" nosuggests    && echo 'APT::Install-Suggests "false";'
        pm_adv_has "$o" autoremove    && echo 'APT::Get::AutomaticRemove "true";'
        pm_adv_has "$o" keepdownloads && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";'
        pm_adv_has "$o" noauthwarn    && echo 'APT::Get::AllowUnauthenticated "false";'
        pm_adv_has "$o" parallel      && echo 'Acquire::Queue-Mode "host";'
        pm_adv_has "$o" pipeline      && echo 'Acquire::http::Pipeline-Depth "5";'
        pm_adv_has "$o" noproxycache  && echo 'Acquire::http::No-Cache "true";'
        pm_adv_has "$o" ipv4          && echo 'Acquire::ForceIPv4 "true";'
        pm_adv_has "$o" timeout       && echo 'Acquire::http::Timeout "30";'
        pm_adv_has "$o" retries       && echo 'Acquire::Retries "3";'
        pm_adv_has "$o" languages     && echo 'Acquire::Languages "none";'
        pm_adv_has "$o" nopdiffs      && echo 'Acquire::PDiffs "false";'
        pm_adv_has "$o" installsafe   && echo 'APT::Get::Protect-Essential "true";'
        pm_adv_has "$o" quiet         && echo 'quiet "1";'
        pm_adv_has "$o" color         && echo 'APT::Color "true";'
    } > "$f"
    if command -v apt-config >/dev/null 2>&1 && ! apt-config dump >/dev/null 2>&1; then
        rm -f "$f"
        tui_msg "Rejected" "APT rejected the generated configuration; it was removed."
        return 1
    fi
    tui_msg "Applied" "$f written and validated with apt-config.\n$(grep -c '^[A-Za-z]' "$f") directives active."
}

pm_adv_pacman() {
    local f=/etc/pacman.conf o n
    o=$(tui_check "pacman — advanced" "Current state pre-checked. SPACE toggles, ENTER applies to $f:" \
        color         "Colour output" "$(pm_adv_state grep -qE '^Color$' "$f")" \
        candy         "ILoveCandy progress bar" "$(pm_adv_state grep -qE '^ILoveCandy' "$f")" \
        verbose       "Verbose package lists" "$(pm_adv_state grep -qE '^VerbosePkgLists' "$f")" \
        checkspace    "Check available disk space before installing" "$(pm_adv_state grep -qE '^CheckSpace' "$f")" \
        parallel      "Parallel downloads" "$(pm_adv_state grep -qE '^ParallelDownloads' "$f")" \
        disabledl     "Disable the download timeout" "$(pm_adv_state grep -qE '^DisableDownloadTimeout' "$f")" \
        siglevel      "Require signatures for all packages" "$(pm_adv_state grep -qE '^SigLevel *= *Required' "$f")" \
        multilib      "Enable the multilib repository" "$(pm_adv_state grep -qE '^\[multilib\]' "$f")" \
        noupgrade     "Protect /etc/passwd and /etc/group from upgrades" "$(pm_adv_state grep -qE '^NoUpgrade' "$f")" \
        usesyslog     "Log operations to syslog" "$(pm_adv_state grep -qE '^UseSyslog' "$f")" \
        totaldl       "Show a single total download bar" "$(pm_adv_state grep -qE '^TotalDownload' "$f")" \
        cleanmethod   "Keep only the installed version in the cache" "$(pm_adv_state grep -qE '^CleanMethod' "$f")") || return 0
    cp -a "$f" "$f.systui.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

    pm_adv_toggle_line() { # <regex> <line> <enabled>
        if [ "$3" = 1 ]; then
            grep -qE "^$1" "$f" || sed -i "/^\[options\]/a $2" "$f"
            sed -i -E "s/^#($1.*)/\\1/" "$f"
        else
            sed -i -E "s/^($1.*)/#\\1/" "$f"
        fi
    }
    pm_adv_toggle_line 'Color'                  'Color'                  "$(pm_adv_has "$o" color && echo 1 || echo 0)"
    pm_adv_toggle_line 'ILoveCandy'             'ILoveCandy'             "$(pm_adv_has "$o" candy && echo 1 || echo 0)"
    pm_adv_toggle_line 'VerbosePkgLists'        'VerbosePkgLists'        "$(pm_adv_has "$o" verbose && echo 1 || echo 0)"
    pm_adv_toggle_line 'CheckSpace'             'CheckSpace'             "$(pm_adv_has "$o" checkspace && echo 1 || echo 0)"
    pm_adv_toggle_line 'DisableDownloadTimeout' 'DisableDownloadTimeout' "$(pm_adv_has "$o" disabledl && echo 1 || echo 0)"
    pm_adv_toggle_line 'UseSyslog'              'UseSyslog'              "$(pm_adv_has "$o" usesyslog && echo 1 || echo 0)"
    pm_adv_toggle_line 'TotalDownload'          'TotalDownload'          "$(pm_adv_has "$o" totaldl && echo 1 || echo 0)"
    unset -f pm_adv_toggle_line

    if pm_adv_has "$o" parallel; then
        n=$(tui_input "ParallelDownloads" "Simultaneous downloads:" "$(pm_adv_get "$f" ParallelDownloads || echo 5)") || n=5
        case "$n" in ''|*[!0-9]*) n=5 ;; esac
        if grep -qE '^#?ParallelDownloads' "$f"; then sed -i -E "s/^#?ParallelDownloads.*/ParallelDownloads = $n/" "$f"
        else sed -i "/^\[options\]/a ParallelDownloads = $n" "$f"; fi
    else
        sed -i -E 's/^ParallelDownloads/#ParallelDownloads/' "$f"
    fi
    if pm_adv_has "$o" cleanmethod; then
        grep -qE '^CleanMethod' "$f" || sed -i "/^\[options\]/a CleanMethod = KeepInstalled" "$f"
    else
        sed -i -E 's/^CleanMethod/#CleanMethod/' "$f"
    fi
    if pm_adv_has "$o" noupgrade; then
        grep -qE '^NoUpgrade' "$f" || sed -i "/^\[options\]/a NoUpgrade = etc/passwd etc/group etc/shadow" "$f"
    else
        sed -i -E 's/^NoUpgrade/#NoUpgrade/' "$f"
    fi
    if pm_adv_has "$o" multilib; then
        grep -qE '^\[multilib\]' "$f" || printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> "$f"
    fi
    tui_msg "Applied" "/etc/pacman.conf updated.\nA timestamped backup was written alongside it."
}

pm_adv_dnf() { # also serves yum
    local mgr="${1:-dnf}" f o n
    [ "$mgr" = yum ] && f=/etc/yum.conf || f=/etc/dnf/dnf.conf
    o=$(tui_check "$mgr — advanced" "Current state pre-checked. SPACE toggles, ENTER applies to $f:" \
        fastest    "Use the fastest mirror" "$(pm_adv_state grep -q '^fastestmirror=True' "$f")" \
        parallel   "Parallel downloads" "$(pm_adv_state grep -q '^max_parallel_downloads' "$f")" \
        weak       "Skip weak dependencies (leaner installs)" "$(pm_adv_state grep -q '^install_weak_deps=False' "$f")" \
        keepcache  "Keep downloaded packages" "$(pm_adv_state grep -q '^keepcache=True' "$f")" \
        deltarpm   "Use delta RPMs to save bandwidth" "$(pm_adv_state grep -q '^deltarpm=True' "$f")" \
        gpgcheck   "Require GPG signatures" "$(pm_adv_state grep -q '^gpgcheck=1' "$f")" \
        clean      "Clean requirements on remove" "$(pm_adv_state grep -q '^clean_requirements_on_remove=True' "$f")" \
        best       "Always install the best available version" "$(pm_adv_state grep -q '^best=True' "$f")" \
        skipbroken "Skip broken packages instead of failing" "$(pm_adv_state grep -q '^skip_if_unavailable=True' "$f")" \
        colour     "Colourise output" "$(pm_adv_state grep -q '^color=always' "$f")" \
        installonly "Keep only three kernels" "$(pm_adv_state grep -q '^installonly_limit=3' "$f")" \
        ipv4       "Force IPv4 for downloads" "$(pm_adv_state grep -q '^ip_resolve=4' "$f")" \
        timeout    "Shorter network timeout (30s)" "$(pm_adv_state grep -q '^timeout=30' "$f")" \
        retries    "Retry failed downloads three times" "$(pm_adv_state grep -q '^retries=3' "$f")") || return 0
    mkdir -p "$(dirname "$f")"; [ -f "$f" ] || printf '[main]\n' > "$f"
    cp -a "$f" "$f.systui.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    sed -i '/^fastestmirror=/d;/^max_parallel_downloads=/d;/^install_weak_deps=/d;/^keepcache=/d;/^deltarpm=/d;/^gpgcheck=/d;/^clean_requirements_on_remove=/d;/^best=/d;/^skip_if_unavailable=/d;/^color=/d;/^installonly_limit=/d;/^ip_resolve=/d;/^timeout=/d;/^retries=/d' "$f"
    grep -q '^\[main\]' "$f" || sed -i '1i [main]' "$f"
    {
        pm_adv_has "$o" fastest     && echo 'fastestmirror=True'
        pm_adv_has "$o" weak        && echo 'install_weak_deps=False'
        pm_adv_has "$o" keepcache   && echo 'keepcache=True'
        pm_adv_has "$o" deltarpm    && echo 'deltarpm=True'
        pm_adv_has "$o" gpgcheck    && echo 'gpgcheck=1'
        pm_adv_has "$o" clean       && echo 'clean_requirements_on_remove=True'
        pm_adv_has "$o" best        && echo 'best=True'
        pm_adv_has "$o" skipbroken  && echo 'skip_if_unavailable=True'
        pm_adv_has "$o" colour      && echo 'color=always'
        pm_adv_has "$o" installonly && echo 'installonly_limit=3'
        pm_adv_has "$o" ipv4        && echo 'ip_resolve=4'
        pm_adv_has "$o" timeout     && echo 'timeout=30'
        pm_adv_has "$o" retries     && echo 'retries=3'
    } >> "$f"
    if pm_adv_has "$o" parallel; then
        n=$(tui_input "Parallel downloads" "Simultaneous downloads:" "10") || n=10
        case "$n" in ''|*[!0-9]*) n=10 ;; esac
        echo "max_parallel_downloads=$n" >> "$f"
    fi
    tui_msg "Applied" "$f updated ($(grep -cE '^[a-z_]+=' "$f") settings).\nA timestamped backup was written alongside it."
}

pm_adv_zypper() {
    local f=/etc/zypp/zypp.conf g=/etc/zypp/zypper.conf o
    o=$(tui_check "zypper — advanced" "Current state pre-checked. SPACE toggles, ENTER applies:" \
        keeppackages "Keep downloaded packages" "$(pm_adv_state grep -q '^commit.downloadMode' "$f")" \
        norecommends "Do not install recommended packages" "$(pm_adv_state grep -q '^installRecommends *= *no' "$f")" \
        gpgcheck     "Require GPG signatures" "$(pm_adv_state grep -q '^gpgCheck *= *on' "$f")" \
        multiversion "Keep multiple kernel versions" "$(pm_adv_state grep -q '^multiversion' "$f")" \
        deltarpm     "Use delta RPMs" "$(pm_adv_state grep -q '^download.use_deltarpm *= *true' "$f")" \
        colour       "Colourise output" "$(pm_adv_state grep -q '^color' "$g")" \
        verify       "Verify the system after each transaction" "$(pm_adv_state grep -q '^solver.onlyRequires' "$f")" \
        nodocs       "Skip documentation files" "$(pm_adv_state grep -q '^rpm.install.excludedocs *= *yes' "$f")") || return 0
    mkdir -p /etc/zypp; [ -f "$f" ] || : > "$f"
    cp -a "$f" "$f.systui.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    sed -i '/^commit.downloadMode/d;/^installRecommends/d;/^gpgCheck/d;/^multiversion/d;/^download.use_deltarpm/d;/^solver.onlyRequires/d;/^rpm.install.excludedocs/d' "$f"
    {
        pm_adv_has "$o" keeppackages && echo 'commit.downloadMode = DownloadInAdvance'
        pm_adv_has "$o" norecommends && echo 'installRecommends = no'
        pm_adv_has "$o" gpgcheck     && echo 'gpgCheck = on'
        pm_adv_has "$o" multiversion && echo 'multiversion = provides:multiversion(kernel)'
        pm_adv_has "$o" deltarpm     && echo 'download.use_deltarpm = true'
        pm_adv_has "$o" verify       && echo 'solver.onlyRequires = true'
        pm_adv_has "$o" nodocs       && echo 'rpm.install.excludedocs = yes'
    } >> "$f"
    if pm_adv_has "$o" colour; then
        mkdir -p "$(dirname "$g")"; [ -f "$g" ] || : > "$g"
        grep -q '^\[color\]' "$g" || printf '[color]\nuseColors = always\n' >> "$g"
    fi
    tui_msg "Applied" "$f updated.\nA timestamped backup was written alongside it."
}

pm_adv_apk() {
    local f=/etc/apk/repositories c=/etc/apk/cache o
    o=$(tui_check "apk — advanced" "Current state pre-checked. SPACE toggles, ENTER applies:" \
        cache        "Enable the local package cache" "$(pm_adv_state test -L "$c")" \
        community    "Enable the community repository" "$(pm_adv_state grep -q '^[^#].*community' "$f")" \
        edgetesting  "Enable the edge/testing repository" "$(pm_adv_state grep -q '^[^#].*testing' "$f")" \
        progress     "Show download progress" "$(pm_adv_state test -f /etc/apk/progress)" \
        nointeractive "Never prompt during operations" "$(pm_adv_state test -f /etc/apk/no-interactive)" \
        purge        "Purge configuration when removing packages" "$(pm_adv_state test -f /etc/apk/purge)") || return 0
    if pm_adv_has "$o" cache; then
        mkdir -p /var/cache/apk
        [ -L "$c" ] || ln -sf /var/cache/apk "$c"
        command -v apk >/dev/null 2>&1 && apk cache sync >/dev/null 2>&1 || true
    else
        [ -L "$c" ] && rm -f "$c"
    fi
    cp -a "$f" "$f.systui.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    if pm_adv_has "$o" community; then sed -i 's|^#\(.*community.*\)$|\1|' "$f"; else sed -i 's|^\([^#].*community.*\)$|#\1|' "$f"; fi
    if pm_adv_has "$o" edgetesting; then sed -i 's|^#\(.*testing.*\)$|\1|' "$f"; else sed -i 's|^\([^#].*testing.*\)$|#\1|' "$f"; fi
    pm_adv_has "$o" progress      && : > /etc/apk/progress      || rm -f /etc/apk/progress
    pm_adv_has "$o" nointeractive && : > /etc/apk/no-interactive || rm -f /etc/apk/no-interactive
    pm_adv_has "$o" purge         && : > /etc/apk/purge          || rm -f /etc/apk/purge
    tui_msg "Applied" "apk configuration updated.\nRepositories:\n$(grep -c '^[^#]' "$f") enabled, $(grep -c '^#' "$f") commented out."
}

pm_adv_xbps() {
    local d=/etc/xbps.d f=/etc/xbps.d/00-systui.conf o
    o=$(tui_check "XBPS — advanced" "Current state pre-checked. SPACE toggles, ENTER writes $f:" \
        cachedir    "Use a dedicated cache directory" "$(pm_adv_state grep -q '^cachedir' "$f")" \
        syslog      "Log operations to syslog" "$(pm_adv_state grep -q '^syslog=true' "$f")" \
        keepconf    "Preserve modified configuration files" "$(pm_adv_state grep -q '^preserve' "$f")" \
        ignoresig   "Do not require repository signatures (not recommended)" "$(pm_adv_state grep -q '^repository.*--ignore' "$f")" \
        bestmatch   "Prefer the best version across repositories" "$(pm_adv_state grep -q '^bestmatching=true' "$f")" \
        nonfree     "Enable the nonfree repository" "$(pm_adv_state grep -q 'nonfree' "$f")") || return 0
    mkdir -p "$d"
    {
        echo '# Generated by systui. Edits are replaced on the next run.'
        pm_adv_has "$o" cachedir  && echo 'cachedir=/var/cache/xbps'
        pm_adv_has "$o" syslog    && echo 'syslog=true' || echo 'syslog=false'
        pm_adv_has "$o" keepconf  && echo 'preserve=/etc/*'
        pm_adv_has "$o" bestmatch && echo 'bestmatching=true'
        pm_adv_has "$o" nonfree   && echo 'repository=https://repo-default.voidlinux.org/current/nonfree'
    } > "$f"
    tui_msg "Applied" "$f written ($(grep -c '^[a-z]' "$f") settings)."
}

pm_adv_emerge() {
    local f=/etc/portage/make.conf o n
    o=$(tui_check "Portage — advanced" "Current state pre-checked. SPACE toggles, ENTER applies to $f:" \
        jobs       "Build several packages in parallel" "$(pm_adv_state grep -q '^MAKEOPTS' "$f")" \
        loadavg    "Limit parallelism by load average" "$(pm_adv_state grep -q 'load-average' "$f")" \
        ccache     "Enable ccache" "$(pm_adv_state grep -q 'ccache' "$f")" \
        buildpkg   "Keep binary packages after building" "$(pm_adv_state grep -q 'buildpkg' "$f")" \
        parallelfetch "Fetch sources in parallel with building" "$(pm_adv_state grep -q 'parallel-fetch' "$f")" \
        candy      "Colourful progress output" "$(pm_adv_state grep -q 'candy' "$f")" \
        quietbuild "Reduce build output" "$(pm_adv_state grep -q 'quiet-build' "$f")" \
        nodoc      "Skip documentation where possible" "$(pm_adv_state grep -q 'nodoc' "$f")" \
        march      "Optimise for the local CPU (-march=native)" "$(pm_adv_state grep -q 'march=native' "$f")") || return 0
    mkdir -p "$(dirname "$f")"; [ -f "$f" ] || : > "$f"
    cp -a "$f" "$f.systui.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    n=$(nproc 2>/dev/null || echo 2)
    {
        pm_adv_has "$o" jobs       && printf 'MAKEOPTS="-j%s"\n' "$n"
        pm_adv_has "$o" loadavg    && printf 'EMERGE_DEFAULT_OPTS="--load-average=%s --jobs=%s"\n' "$n" "$n"
        pm_adv_has "$o" ccache     && printf 'FEATURES="${FEATURES} ccache"\nCCACHE_SIZE="4G"\n'
        pm_adv_has "$o" buildpkg   && printf 'FEATURES="${FEATURES} buildpkg"\n'
        pm_adv_has "$o" parallelfetch && printf 'FEATURES="${FEATURES} parallel-fetch"\n'
        pm_adv_has "$o" candy      && printf 'FEATURES="${FEATURES} candy"\n'
        pm_adv_has "$o" quietbuild && printf 'FEATURES="${FEATURES} quiet-build"\n'
        pm_adv_has "$o" nodoc      && printf 'INSTALL_MASK="/usr/share/doc"\n'
        pm_adv_has "$o" march      && printf 'COMMON_FLAGS="-march=native -O2 -pipe"\nCFLAGS="${COMMON_FLAGS}"\nCXXFLAGS="${COMMON_FLAGS}"\n'
    } | pm_adv_write_block "$f" portage
    tui_msg "Applied" "$f updated inside a managed systui block.\nA timestamped backup was written alongside it."
}

# ---- Universal package managers ---------------------------------------------

pm_adv_flatpak() {
    local o cfg=/var/lib/flatpak/repo/config
    o=$(tui_check "Flatpak — advanced" "Current state pre-checked. SPACE toggles, ENTER applies:" \
        flathub      "Flathub remote enabled" "$(pm_adv_state flatpak remotes --columns=name)" \
        userinstall  "Prefer per-user installations" "$(pm_adv_state test -d "$HOME/.local/share/flatpak")" \
        nodeps       "Do not install related components automatically" off \
        parallel     "Allow parallel downloads" "$(pm_adv_state grep -q 'max-parallel' "$cfg")" \
        minfree      "Reserve free space before installing" "$(pm_adv_state grep -q 'min-free-space' "$cfg")" \
        nodocs       "Skip locale and documentation extras" "$(pm_adv_state flatpak config --get languages)" \
        autoprune    "Remove unused runtimes after each operation" off \
        gpgverify    "Require GPG verification of remotes" on) || return 0
    command -v flatpak >/dev/null 2>&1 || { tui_msg "Flatpak" "Flatpak is not installed."; return 1; }
    pm_adv_has "$o" flathub && run_cmd "Adding Flathub" flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    pm_adv_has "$o" minfree && flatpak config --set min-free-space-size 500MB >/dev/null 2>&1
    pm_adv_has "$o" nodocs  && flatpak config --set languages "en" >/dev/null 2>&1
    if pm_adv_has "$o" gpgverify; then
        flatpak remotes --columns=name,options 2>/dev/null | awk '$2 ~ /no-gpg-verify/ {print $1}' > "$SYSTUI_TMP/fp-nogpg"
        [ -s "$SYSTUI_TMP/fp-nogpg" ] && tui_text "Remotes without GPG verification" "$SYSTUI_TMP/fp-nogpg"
    fi
    pm_adv_has "$o" autoprune && run_cmd "Removing unused runtimes" flatpak uninstall --unused -y
    tui_msg "Applied" "Flatpak configuration updated.\nRemotes:\n$(flatpak remotes --columns=name 2>/dev/null | tr '\n' ' ')"
}

pm_adv_snap() {
    local o v
    command -v snap >/dev/null 2>&1 || { tui_msg "Snap" "snapd is not installed."; return 1; }
    o=$(tui_check "Snap — advanced" "Current state pre-checked. SPACE toggles, ENTER applies:" \
        holdrefresh "Hold automatic refreshes" "$(pm_adv_state sh -c 'snap get system refresh.hold 2>/dev/null | grep -q .')" \
        metered     "Do not refresh on metered connections" "$(pm_adv_state sh -c 'snap get system refresh.metered 2>/dev/null | grep -q hold')" \
        retain      "Keep only two revisions per snap" "$(pm_adv_state sh -c 'snap get system refresh.retain 2>/dev/null | grep -q 2')" \
        timer       "Restrict refreshes to a nightly window" "$(pm_adv_state sh -c 'snap get system refresh.timer 2>/dev/null | grep -q .')" \
        classic     "Allow classic confinement snaps" off \
        experimental "Enable experimental features" off) || return 0
    if pm_adv_has "$o" holdrefresh; then
        v=$(tui_input "Refresh hold" "Hold until (24h, 72h, or an RFC3339 timestamp):" "24h") || v=24h
        snap set system refresh.hold="$v" >/dev/null 2>&1
    else
        snap unset system refresh.hold >/dev/null 2>&1
    fi
    pm_adv_has "$o" metered && snap set system refresh.metered=hold >/dev/null 2>&1 || snap unset system refresh.metered >/dev/null 2>&1
    pm_adv_has "$o" retain  && snap set system refresh.retain=2 >/dev/null 2>&1 || snap unset system refresh.retain >/dev/null 2>&1
    pm_adv_has "$o" timer   && snap set system refresh.timer="02:00-04:00" >/dev/null 2>&1 || snap unset system refresh.timer >/dev/null 2>&1
    pm_adv_has "$o" experimental && snap set system experimental.parallel-instances=true >/dev/null 2>&1
    tui_msg "Applied" "snapd configuration updated.\n\n$(snap get system 2>/dev/null | head -12)"
}

pm_adv_nix() {
    local f o
    f="${HOME}/.config/nix/nix.conf"
    [ "$(id -u)" -eq 0 ] && f=/etc/nix/nix.conf
    o=$(tui_check "Nix — advanced" "Current state pre-checked. SPACE toggles, ENTER writes $f:" \
        flakes      "Enable flakes and the new nix command" "$(pm_adv_state grep -q 'experimental-features.*flakes' "$f")" \
        autooptimise "Automatically optimise the store" "$(pm_adv_state grep -q '^auto-optimise-store = true' "$f")" \
        keepoutputs "Keep build outputs for development shells" "$(pm_adv_state grep -q '^keep-outputs = true' "$f")" \
        keepderivations "Keep derivations" "$(pm_adv_state grep -q '^keep-derivations = true' "$f")" \
        substituters "Use the official binary cache" "$(pm_adv_state grep -q 'cache.nixos.org' "$f")" \
        maxjobs     "Build several derivations in parallel" "$(pm_adv_state grep -q '^max-jobs' "$f")" \
        sandbox     "Build in a sandbox" "$(pm_adv_state grep -q '^sandbox = true' "$f")" \
        warndirty   "Warn about dirty Git trees" "$(pm_adv_state grep -q '^warn-dirty = true' "$f")") || return 0
    mkdir -p "$(dirname "$f")"
    {
        pm_adv_has "$o" flakes          && echo 'experimental-features = nix-command flakes'
        pm_adv_has "$o" autooptimise    && echo 'auto-optimise-store = true'
        pm_adv_has "$o" keepoutputs     && echo 'keep-outputs = true'
        pm_adv_has "$o" keepderivations && echo 'keep-derivations = true'
        pm_adv_has "$o" substituters    && echo 'substituters = https://cache.nixos.org'
        pm_adv_has "$o" maxjobs         && printf 'max-jobs = %s\n' "$(nproc 2>/dev/null || echo 2)"
        pm_adv_has "$o" sandbox         && echo 'sandbox = true' || echo 'sandbox = false'
        pm_adv_has "$o" warndirty       && echo 'warn-dirty = true' || echo 'warn-dirty = false'
    } | pm_adv_write_block "$f" nix
    tui_msg "Applied" "$f updated inside a managed systui block."
}

pm_adv_brew() {
    local f msg o
    f=$(brew_root_compat_env_file)
    msg="Current state pre-checked. SPACE toggles, ENTER writes $f:"
    [ "$f" = /etc/systui/homebrew.env ] && msg="$msg\nApplies to the permanent root-compatibility wrapper."
    o=$(tui_check "Homebrew — advanced" "$msg" \
        noanalytics  "Disable analytics" "$(pm_adv_state grep -q '^HOMEBREW_NO_ANALYTICS=1' "$f")" \
        noautoupdate "Do not auto-update on every command" "$(pm_adv_state grep -q '^HOMEBREW_NO_AUTO_UPDATE=1' "$f")" \
        noinsecure   "Refuse insecure redirects" "$(pm_adv_state grep -q '^HOMEBREW_NO_INSECURE_REDIRECT=1' "$f")" \
        cask         "Require casks to be signed" "$(pm_adv_state grep -q '^HOMEBREW_CASK_OPTS' "$f")" \
        cleanup      "Clean up automatically after installs" "$(pm_adv_state grep -q '^HOMEBREW_INSTALL_CLEANUP=1' "$f")" \
        noenvhints   "Hide environment hints" "$(pm_adv_state grep -q '^HOMEBREW_NO_ENV_HINTS=1' "$f")" \
        bat          "Use bat for brew cat output" "$(pm_adv_state grep -q '^HOMEBREW_BAT=1' "$f")" \
        parallel     "Download in parallel" "$(pm_adv_state grep -q '^HOMEBREW_DOWNLOAD_CONCURRENCY' "$f")") || return 0
    mkdir -p "$(dirname "$f")"
    {
        pm_adv_has "$o" noanalytics  && echo 'HOMEBREW_NO_ANALYTICS=1'
        pm_adv_has "$o" noautoupdate && echo 'HOMEBREW_NO_AUTO_UPDATE=1'
        pm_adv_has "$o" noinsecure   && echo 'HOMEBREW_NO_INSECURE_REDIRECT=1'
        pm_adv_has "$o" cask         && echo 'HOMEBREW_CASK_OPTS=--require-sha'
        pm_adv_has "$o" cleanup      && echo 'HOMEBREW_INSTALL_CLEANUP=1'
        pm_adv_has "$o" noenvhints   && echo 'HOMEBREW_NO_ENV_HINTS=1'
        pm_adv_has "$o" bat          && echo 'HOMEBREW_BAT=1'
        pm_adv_has "$o" parallel     && echo 'HOMEBREW_DOWNLOAD_CONCURRENCY=auto'
    } | pm_adv_write_block "$f" brew
    tui_msg "Applied" "$f updated inside a managed systui block."
    tui_yesno "Root configuration" "Open Root configuration menu (bypass, shim, wrapper)?" && menu_brew_root_config || true
}

# ---- Language / ecosystem package managers ----------------------------------
#
# These share a shape: a registry or index URL, a cache policy, and a small set
# of global install flags. pm_adv_lang renders that shape for each of them.

pm_adv_lang() { # <id>
    local id="$1" f o reg marker
    case "$id" in
        pip)      f="${HOME}/.config/pip/pip.conf";              marker=pip ;;
        pipx)     f="${HOME}/.config/pipx/config";               marker=pipx ;;
        npm)      f="${HOME}/.npmrc";                            marker=npm ;;
        pnpm)     f="${HOME}/.config/pnpm/rc";                   marker=pnpm ;;
        yarn)     f="${HOME}/.yarnrc";                           marker=yarn ;;
        cargo)    f="${HOME}/.cargo/config.toml";                marker=cargo ;;
        gem)      f="${HOME}/.gemrc";                            marker=gem ;;
        composer) f="${HOME}/.config/composer/config.json";      marker=composer ;;
        go)       f="${HOME}/.config/go/env";                    marker=go ;;
        *) return 1 ;;
    esac

    case "$id" in
        pip)
            o=$(tui_check "pip — advanced" "Current state pre-checked. SPACE toggles, ENTER writes $f:" \
                nocache      "Disable the download cache" "$(pm_adv_state grep -q 'no-cache-dir *= *true' "$f")" \
                usermode     "Install to the user site by default" "$(pm_adv_state grep -q 'user *= *true' "$f")" \
                breaksystem  "Allow installs outside a virtualenv" "$(pm_adv_state grep -q 'break-system-packages *= *true' "$f")" \
                noversioncheck "Do not warn about pip updates" "$(pm_adv_state grep -q 'disable-pip-version-check *= *true' "$f")" \
                timeout      "Longer network timeout (60s)" "$(pm_adv_state grep -q 'timeout *= *60' "$f")" \
                retries      "Retry failed downloads five times" "$(pm_adv_state grep -q 'retries *= *5' "$f")" \
                prefer       "Prefer binary wheels over source builds" "$(pm_adv_state grep -q 'prefer-binary *= *true' "$f")" \
                mirror       "Use a custom index URL" "$(pm_adv_state grep -q 'index-url' "$f")" \
                trustedhost  "Mark the index host as trusted" "$(pm_adv_state grep -q 'trusted-host' "$f")" \
                quiet        "Reduce output verbosity" "$(pm_adv_state grep -q '^quiet' "$f")") || return 0
            mkdir -p "$(dirname "$f")"
            {
                echo '[global]'
                pm_adv_has "$o" nocache        && echo 'no-cache-dir = true'
                pm_adv_has "$o" usermode       && echo 'user = true'
                pm_adv_has "$o" breaksystem    && echo 'break-system-packages = true'
                pm_adv_has "$o" noversioncheck && echo 'disable-pip-version-check = true'
                pm_adv_has "$o" timeout        && echo 'timeout = 60'
                pm_adv_has "$o" retries        && echo 'retries = 5'
                pm_adv_has "$o" prefer         && echo 'prefer-binary = true'
                pm_adv_has "$o" quiet          && echo 'quiet = 1'
                if pm_adv_has "$o" mirror; then
                    reg=$(tui_input "Index URL" "PyPI-compatible index URL:" "https://pypi.org/simple") || reg="https://pypi.org/simple"
                    echo "index-url = $reg"
                    pm_adv_has "$o" trustedhost && printf 'trusted-host = %s\n' "$(printf '%s' "$reg" | sed -E 's|^https?://||; s|/.*$||')"
                fi
            } | pm_adv_write_block "$f" "$marker" ;;
        npm|pnpm|yarn)
            o=$(tui_check "$id — advanced" "Current state pre-checked. SPACE toggles, ENTER writes $f:" \
                registry     "Use a custom registry" "$(pm_adv_state grep -q 'registry' "$f")" \
                saveexact    "Save exact dependency versions" "$(pm_adv_state grep -q 'save-exact' "$f")" \
                audit        "Run a security audit on install" "$(pm_adv_state grep -q 'audit *= *true' "$f")" \
                fund         "Show funding messages" "$(pm_adv_state grep -q 'fund *= *true' "$f")" \
                progress     "Show a progress bar" "$(pm_adv_state grep -q 'progress *= *true' "$f")" \
                enginestrict "Enforce declared engine versions" "$(pm_adv_state grep -q 'engine-strict *= *true' "$f")" \
                prefixuser   "Install global packages under the home directory" "$(pm_adv_state grep -q 'prefix' "$f")" \
                nooptional   "Skip optional dependencies" "$(pm_adv_state grep -q 'omit *= *optional' "$f")" \
                loglevel     "Reduce log output" "$(pm_adv_state grep -q 'loglevel *= *warn' "$f")" \
                cachemax     "Limit cache lifetime to seven days" "$(pm_adv_state grep -q 'cache-max' "$f")") || return 0
            mkdir -p "$(dirname "$f")"
            {
                if pm_adv_has "$o" registry; then
                    reg=$(tui_input "Registry" "$id registry URL:" "https://registry.npmjs.org/") || reg="https://registry.npmjs.org/"
                    echo "registry=$reg"
                fi
                pm_adv_has "$o" saveexact    && echo 'save-exact=true'
                pm_adv_has "$o" audit        && echo 'audit=true' || echo 'audit=false'
                pm_adv_has "$o" fund         && echo 'fund=true'  || echo 'fund=false'
                pm_adv_has "$o" progress     && echo 'progress=true' || echo 'progress=false'
                pm_adv_has "$o" enginestrict && echo 'engine-strict=true'
                pm_adv_has "$o" prefixuser   && printf 'prefix=%s/.local\n' "$HOME"
                pm_adv_has "$o" nooptional   && echo 'omit=optional'
                pm_adv_has "$o" loglevel     && echo 'loglevel=warn'
                pm_adv_has "$o" cachemax     && echo 'cache-max=604800'
            } | pm_adv_write_block "$f" "$marker" ;;
        cargo)
            o=$(tui_check "Cargo — advanced" "Current state pre-checked. SPACE toggles, ENTER writes $f:" \
                sparse       "Use the sparse registry protocol (faster)" "$(pm_adv_state grep -q 'protocol *= *.sparse.' "$f")" \
                jobs         "Build with all available cores" "$(pm_adv_state grep -q '^jobs' "$f")" \
                incremental  "Enable incremental compilation" "$(pm_adv_state grep -q 'incremental *= *true' "$f")" \
                targetdir    "Use a shared target directory" "$(pm_adv_state grep -q 'target-dir' "$f")" \
                offline      "Prefer offline operation" "$(pm_adv_state grep -q 'offline *= *true' "$f")" \
                gitcli       "Use the system git binary for fetches" "$(pm_adv_state grep -q 'git-fetch-with-cli *= *true' "$f")" \
                strip        "Strip debug symbols from release builds" "$(pm_adv_state grep -q 'strip' "$f")" \
                colour       "Always colourise output" "$(pm_adv_state grep -q 'color *= *.always.' "$f")") || return 0
            mkdir -p "$(dirname "$f")"
            {
                pm_adv_has "$o" sparse && printf '[registries.crates-io]\nprotocol = "sparse"\n'
                # Both keys belong to [net]; the header has to be emitted when
                # either is selected, or a lone `offline` would be parsed as a
                # key of whichever table happened to precede it.
                if pm_adv_has "$o" gitcli || pm_adv_has "$o" offline; then
                    printf '[net]\n'
                    pm_adv_has "$o" gitcli  && printf 'git-fetch-with-cli = true\n'
                    pm_adv_has "$o" offline && printf 'offline = true\n'
                fi
                printf '[build]\n'
                pm_adv_has "$o" jobs        && printf 'jobs = %s\n' "$(nproc 2>/dev/null || echo 2)"
                pm_adv_has "$o" incremental && printf 'incremental = true\n'
                pm_adv_has "$o" targetdir   && printf 'target-dir = "%s/.cache/cargo-target"\n' "$HOME"
                pm_adv_has "$o" strip       && printf '[profile.release]\nstrip = true\n'
                pm_adv_has "$o" colour      && printf '[term]\ncolor = "always"\n'
            } | pm_adv_write_block "$f" "$marker" ;;
        gem)
            o=$(tui_check "RubyGems — advanced" "Current state pre-checked. SPACE toggles, ENTER writes $f:" \
                nodocs     "Do not install documentation" "$(pm_adv_state grep -q 'no-document' "$f")" \
                usermode   "Install gems to the user directory" "$(pm_adv_state grep -q 'user-install' "$f")" \
                source     "Use a custom gem source" "$(pm_adv_state grep -q ':sources:' "$f")" \
                concurrent "Download gems concurrently" "$(pm_adv_state grep -q 'concurrent_downloads' "$f")" \
                verbose    "Verbose output" "$(pm_adv_state grep -q ':verbose:' "$f")" \
                backtrace  "Show a backtrace on error" "$(pm_adv_state grep -q ':backtrace: true' "$f")") || return 0
            mkdir -p "$(dirname "$f")"
            {
                pm_adv_has "$o" nodocs     && echo 'gem: --no-document'
                pm_adv_has "$o" usermode   && echo 'gem: --user-install'
                pm_adv_has "$o" concurrent && echo ':concurrent_downloads: 8'
                pm_adv_has "$o" verbose    && echo ':verbose: true' || echo ':verbose: false'
                pm_adv_has "$o" backtrace  && echo ':backtrace: true'
                if pm_adv_has "$o" source; then
                    reg=$(tui_input "Gem source" "RubyGems source URL:" "https://rubygems.org") || reg="https://rubygems.org"
                    printf ':sources:\n- %s\n' "$reg"
                fi
            } | pm_adv_write_block "$f" "$marker" ;;
        go)
            o=$(tui_check "Go — advanced" "Current state pre-checked. SPACE toggles, ENTER writes $f:" \
                proxy      "Use the public module proxy" "$(pm_adv_state grep -q '^GOPROXY' "$f")" \
                sumdb      "Verify modules against the checksum database" "$(pm_adv_state grep -q '^GOSUMDB' "$f")" \
                private    "Mark internal module paths as private" "$(pm_adv_state grep -q '^GOPRIVATE' "$f")" \
                nocgo      "Disable cgo (fully static builds)" "$(pm_adv_state grep -q '^CGO_ENABLED=0' "$f")" \
                gobin      "Install binaries under ~/.local/bin" "$(pm_adv_state grep -q '^GOBIN' "$f")" \
                telemetry  "Disable telemetry" "$(pm_adv_state grep -q '^GOTELEMETRY=off' "$f")" \
                flags      "Trim file paths from binaries" "$(pm_adv_state grep -q '^GOFLAGS.*trimpath' "$f")") || return 0
            mkdir -p "$(dirname "$f")"
            {
                pm_adv_has "$o" proxy     && echo 'GOPROXY=https://proxy.golang.org,direct' || echo 'GOPROXY=direct'
                pm_adv_has "$o" sumdb     && echo 'GOSUMDB=sum.golang.org' || echo 'GOSUMDB=off'
                pm_adv_has "$o" nocgo     && echo 'CGO_ENABLED=0'
                pm_adv_has "$o" gobin     && printf 'GOBIN=%s/.local/bin\n' "$HOME"
                pm_adv_has "$o" telemetry && echo 'GOTELEMETRY=off'
                pm_adv_has "$o" flags     && echo 'GOFLAGS=-trimpath'
                if pm_adv_has "$o" private; then
                    reg=$(tui_input "GOPRIVATE" "Comma-separated module prefixes:" "") || reg=""
                    [ -n "$reg" ] && echo "GOPRIVATE=$reg"
                fi
            } | pm_adv_write_block "$f" "$marker" ;;
        composer|pipx)
            o=$(tui_check "$id — advanced" "Current state pre-checked. SPACE toggles, ENTER writes $f:" \
                nointeraction "Never prompt during operations" "$(pm_adv_state grep -q 'no-interaction' "$f")" \
                prefersource  "Prefer installing from source" "$(pm_adv_state grep -q 'prefer-source' "$f")" \
                nodev         "Skip development dependencies" "$(pm_adv_state grep -q 'no-dev' "$f")" \
                cachettl      "Limit cache lifetime" "$(pm_adv_state grep -q 'cache-files-ttl' "$f")" \
                optimise      "Optimise the autoloader/shims" "$(pm_adv_state grep -q 'optimize' "$f")" \
                globalbin     "Install binaries under ~/.local/bin" "$(pm_adv_state grep -q 'bin-dir' "$f")") || return 0
            mkdir -p "$(dirname "$f")"
            if [ "$id" = composer ]; then
                {
                    echo '{'
                    echo '  "config": {'
                    pm_adv_has "$o" prefersource && echo '    "preferred-install": "source",'
                    pm_adv_has "$o" cachettl     && echo '    "cache-files-ttl": 604800,'
                    pm_adv_has "$o" optimise     && echo '    "optimize-autoloader": true,'
                    pm_adv_has "$o" globalbin    && printf '    "bin-dir": "%s/.local/bin",\n' "$HOME"
                    echo '    "sort-packages": true'
                    echo '  }'
                    echo '}'
                } > "$f"
            else
                {
                    pm_adv_has "$o" nointeraction && echo 'PIPX_DEFAULT_PYTHON_ARGS=--no-input'
                    pm_adv_has "$o" globalbin     && printf 'PIPX_BIN_DIR=%s/.local/bin\n' "$HOME"
                    pm_adv_has "$o" optimise      && echo 'PIPX_HOME='"$HOME"'/.local/pipx'
                } | pm_adv_write_block "$f" "$marker"
            fi ;;
    esac
    tui_msg "Applied" "$f updated.\n$([ -s "$f" ] && grep -c . "$f" || echo 0) lines written."
}

# Dispatcher: every manager in the list resolves to one of the menus above.
pm_advanced_menu() { # <manager-id>
    case "$1" in
        apt|aptitude|aptfast|nala) pm_adv_apt ;;
        pacman|yay|paru)           pm_adv_pacman ;;
        dnf)                       pm_adv_dnf dnf ;;
        yum)                       pm_adv_dnf yum ;;
        zypper)                    pm_adv_zypper ;;
        apk)                       pm_adv_apk ;;
        xbps)                      pm_adv_xbps ;;
        emerge)                    pm_adv_emerge ;;
        flatpak)                   pm_adv_flatpak ;;
        snap)                      pm_adv_snap ;;
        nix)                       pm_adv_nix ;;
        brew)                      pm_adv_brew ;;
        pip|pipx|npm|pnpm|yarn|cargo|gem|composer|go) pm_adv_lang "$1" ;;
        native)                    pm_advanced_menu "$PM" ;;
        *) tui_msg "Advanced" "No advanced configuration is defined for $1." ; return 1 ;;
    esac
}

# ---- Per-manager install menus ----------------------------------------------
# Each function presents multiple installation methods for a specific manager.
# Called by menu_cfg_cli_manager when the manager binary is not found.

brew_root_compat_script() { printf '%s\n' "$SYSTUI_LIBDIR/share/homebrew/install-homebrew-root.sh"; }

brew_root_compat_env_file() {
    if [ -r /etc/systui/homebrew.env ] || [ -r /usr/local/lib/homebrew-root/libhomebrew_fakeuid.so ]; then
        printf '/etc/systui/homebrew.env\n'
    else
        printf '%s\n' "${HOME}/.config/homebrew/brew.env"
    fi
}

# Returns 1 when root bypass is permanently enabled (HOMEBREW_ALLOW_ROOT=1 in
# /etc/systui/homebrew.env), 0 otherwise.
brew_root_bypass_enabled() {
    grep -qs 'HOMEBREW_ALLOW_ROOT=1' /etc/systui/homebrew.env 2>/dev/null
}

# Write/remove the persistent root-bypass flag in /etc/systui/homebrew.env.
brew_set_root_bypass() { # <1|0>
    local flag="$1"
    mkdir -p /etc/systui
    local envf=/etc/systui/homebrew.env
    touch "$envf" 2>/dev/null || true
    if [ "$flag" = 1 ]; then
        grep -qs 'HOMEBREW_ALLOW_ROOT=' "$envf" \
            && sed -i 's/^HOMEBREW_ALLOW_ROOT=.*/HOMEBREW_ALLOW_ROOT=1/' "$envf" \
            || echo 'HOMEBREW_ALLOW_ROOT=1' >> "$envf"
    else
        sed -i '/^HOMEBREW_ALLOW_ROOT=/d' "$envf" 2>/dev/null || true
    fi
    chmod 0644 "$envf"
}

# Completely remove Homebrew: installation, configs, cache, root-compat layer.
_brew_complete_uninstall() {
    local buser; buser=$(brew_target_user)

    # Run official uninstall script as appropriate user
    if [ -n "$buser" ] && [ "$buser" != root ] && [ "$(id -u)" -eq 0 ]; then
        sudo -u "$buser" -H bash -c \
            'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"' 2>/dev/null || true
    else
        bash -c \
            'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"' 2>/dev/null || true
    fi
    
    # Remove all systui-managed configs
    rm -f /etc/systui/homebrew.env 2>/dev/null || true
    rm -f /etc/profile.d/homebrew.sh 2>/dev/null || true
    
    # Remove root-compat layer (shim, wrapper, etc.)
    rm -rf /usr/local/lib/homebrew-root 2>/dev/null || true
    
    # Remove user-specific cache/config. `~` must expand inside the target
    # user's shell (via -H), not the caller's -- otherwise this silently
    # deletes the wrong home directory's cache instead of $buser's.
    if [ -n "$buser" ] && [ "$buser" != root ]; then
        sudo -u "$buser" -H bash -c \
            'rm -rf ~/.cache/Homebrew ~/.config/Homebrew ~/.homebrew' 2>/dev/null || true
    fi
    
    # Remove root user cache/config if running as root
    if [ "$(id -u)" -eq 0 ]; then
        rm -rf /root/.cache/Homebrew 2>/dev/null || true
        rm -rf /root/.config/Homebrew 2>/dev/null || true
        rm -rf /root/.homebrew 2>/dev/null || true
    fi
    
    # Clean up any lingering symlinks or wrappers
    rm -f /usr/local/bin/brew 2>/dev/null || true
    rm -f /usr/bin/brew 2>/dev/null || true
    
    # Remove Homebrew path entries from common shell rc files
    local rcs=(/etc/profile.d/homebrew.sh ~/.bashrc ~/.bash_profile ~/.zshrc ~/.kshrc)
    for rc in "${rcs[@]}"; do
        [ -f "$rc" ] && sed -i '/homebrew/Id' "$rc" 2>/dev/null || true
    done
}

# Resolve the user brew should run as.
# When running as root and bypass is NOT enabled, brew runs under the first
# non-root account (falling back to $SUDO_USER, then the first UID-1000 account).
brew_target_user() {
    if [ "$(id -u)" -ne 0 ] || brew_root_bypass_enabled; then
        printf '%s\n' "$(id -un)"
        return 0
    fi
    local u="${SUDO_USER:-}"
    [ -z "$u" ] || [ "$u" = root ] && \
        u=$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd 2>/dev/null || true)
    [ -n "$u" ] || u=""
    printf '%s\n' "$u"
}

# Run a brew command as the appropriate user (or directly when bypass is on).
brew_run_as() { # <description> <brew-args...>
    local desc="$1"; shift
    local buser; buser=$(brew_target_user)
    if [ -z "$buser" ] || [ "$buser" = root ] || [ "$(id -u)" -ne 0 ]; then
        run_cmd "$desc" brew "$@"
    else
        run_cmd "$desc (as $buser)" sudo -u "$buser" -H brew "$@"
    fi
}

menu_brew_install() {
    local c script buser
    while true; do
        buser=$(brew_target_user)
        local shim_st; shim_st=$([ -f /usr/local/lib/homebrew-root/libhomebrew_fakeuid.so ] && echo "shim:OK" || echo "shim:none")
        local status_line
        status_line="Root bypass: $(brew_root_bypass_enabled && echo ENABLED || echo disabled) | $shim_st"
        [ -n "$buser" ] && status_line+=" | Target user: $buser" || status_line+=" | No non-root user found"

        c=$(tui_menu "Homebrew" "$status_line\n\nInstall / Manage:" \
            user       "Standard install — run as non-root user (recommended)" \
            rootcomp   "Root-compatibility layer — install with root permissions (any system)" \
            reinstall  "Force reinstall — uninstall then reinstall" \
            rootconfig "Root configuration — bypass, shim, wrapper, permissions" \
            pkgops     "Formula operations — install / reinstall / remove" \
            config     "Full configuration setup" \
            repair     "Repair / re-link existing Homebrew installation" \
            uninstall  "Uninstall Homebrew" \
            back       "Back") || return 0

        case "$c" in
            user)
                local install_user; install_user=$(brew_target_user)
                if [ -z "$install_user" ] || [ "$install_user" = root ]; then
                    tui_msg "Homebrew" "No non-root account found to install under.\nCreate a user account first or enable root bypass."
                    continue
                fi
                tui_msg "Homebrew install" "Installing Homebrew as '$install_user'.\nThis will download and run the official install script."
                run_cmd "Install Homebrew (as $install_user)" \
                    sudo -u "$install_user" -H bash -c \
                    'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
                ;;
            rootcomp)
                if [ "$(id -u)" -ne 0 ]; then
                    tui_msg "Homebrew" "Root privileges are required for the root-compat layer."
                    continue
                fi
                script=$(brew_root_compat_script)
                [ -r "$script" ] || { tui_msg "Homebrew" "Installer script not found:\n$script"; continue; }
                run_cmd "Install Homebrew (root-compatible)" bash "$script"
                ;;
            reinstall)
                local ri_method
                ri_method=$(tui_menu "Reinstall Homebrew" "Choose reinstall method:" \
                    user      "Standard (non-root user)" \
                    rootcomp  "Root-compatibility layer (requires root)" \
                    back      "Cancel") || continue
                [ "$ri_method" = back ] || [ -z "$ri_method" ] && continue
                tui_yesno "Reinstall Homebrew" "Uninstall existing Homebrew first, then reinstall fresh?\n\nAll installed formulae will be removed." || continue
                local ubuser; ubuser=$(brew_target_user)
                if [ -n "$ubuser" ] && [ "$ubuser" != root ] && [ "$(id -u)" -eq 0 ]; then
                    run_cmd "Uninstall Homebrew" sudo -u "$ubuser" -H bash -c \
                        'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"' || true
                else
                    run_cmd "Uninstall Homebrew" bash -c \
                        'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"' || true
                fi
                case "$ri_method" in
                    user)
                        local iu; iu=$(brew_target_user)
                        if [ -z "$iu" ] || [ "$iu" = root ]; then
                            tui_msg "Homebrew" "No non-root user found for reinstall."; continue
                        fi
                        run_cmd "Reinstall Homebrew (as $iu)" \
                            sudo -u "$iu" -H bash -c \
                            'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
                        ;;
                    rootcomp)
                        if [ "$(id -u)" -ne 0 ]; then
                            tui_msg "Homebrew" "Root required for root-compat reinstall."; continue
                        fi
                        script=$(brew_root_compat_script)
                        [ -r "$script" ] || { tui_msg "Homebrew" "Installer script not found:\n$script"; continue; }
                        run_cmd "Reinstall Homebrew (root-compatible)" bash "$script"
                        ;;
                esac
                ;;
            rootconfig) menu_brew_root_config ;;
            pkgops)     menu_brew_pkgops ;;
            config)     menu_brew_config ;;
            repair)
                brew_run_as "Homebrew repair" cleanup --prune=all
                brew_run_as "Homebrew relink" link --overwrite --force 2>/dev/null || true
                brew_run_as "Homebrew doctor" doctor
                ;;
            uninstall)
                tui_yesno "Uninstall Homebrew" "This will completely remove:\n• Homebrew installation\n• All formulae and packages\n• All configs and cache\n• Root-compat layer\n\nContinue?" || continue
                run_cmd "Completely uninstall Homebrew" _brew_complete_uninstall
                tui_msg "Homebrew uninstalled" "All Homebrew files, configs, cache, and root-compat layers have been removed."
                ;;
            back|"") return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Root reconfiguration helpers — each performs one atomic step so they can be
# called independently without re-running the full installer.
# ---------------------------------------------------------------------------

_brew_root_shim_dir()    { printf '%s' "/usr/local/lib/homebrew-root"; }
_brew_root_wrapper()     { printf '%s' "/usr/local/bin/brew"; }
_brew_root_profile()     { printf '%s' "/etc/profile.d/homebrew.sh"; }
_brew_root_prefix()      {
    local p; p=$(_brew_cfg_get /etc/systui/homebrew.env HOMEBREW_PREFIX)
    printf '%s' "${p:-/home/linuxbrew/.linuxbrew}"
}

_brew_root_rebuild_shim() {
    if [ "$(id -u)" -ne 0 ]; then tui_msg "Root required" "Rebuilding the shim requires root."; return 1; fi
    command -v gcc >/dev/null 2>&1 || { tui_msg "Missing tool" "gcc is required to compile the UID shim.\nInstall build-essential (apt) or equivalent."; return 1; }
    local sdir; sdir=$(_brew_root_shim_dir)
    local src="$sdir/fakeuid.c" lib="$sdir/libhomebrew_fakeuid.so"
    install -d -m 0755 -o root -g root "$sdir"
    cat > "$src" <<'EOF_C'
#define _GNU_SOURCE
#include <sys/types.h>
#include <unistd.h>
uid_t getuid(void)  { return (uid_t)1000; }
uid_t geteuid(void) { return (uid_t)1000; }
gid_t getgid(void)  { return (gid_t)1000; }
gid_t getegid(void) { return (gid_t)1000; }
int getresuid(uid_t *r,uid_t *e,uid_t *s){if(r)*r=1000;if(e)*e=1000;if(s)*s=1000;return 0;}
int getresgid(gid_t *r,gid_t *e,gid_t *s){if(r)*r=1000;if(e)*e=1000;if(s)*s=1000;return 0;}
EOF_C
    run_cmd "Compile UID shim" gcc -shared -fPIC -O2 -Wall -Wextra -o "$lib" "$src" || return 1
    chmod 0755 "$lib"
    tui_msg "Shim rebuilt" "UID shim written to:\n$lib"
}

_brew_root_reinstall_wrapper() {
    if [ "$(id -u)" -ne 0 ]; then tui_msg "Root required" "Reinstalling the wrapper requires root."; return 1; fi
    local prefix; prefix=$(_brew_root_prefix)
    local repo="$prefix/Homebrew"
    local real_brew="$repo/bin/brew"
    local wrapper; wrapper=$(_brew_root_wrapper)
    local shim="$(_brew_root_shim_dir)/libhomebrew_fakeuid.so"
    local envf=/etc/systui/homebrew.env
    cat > "$wrapper" <<WRAP
#!/usr/bin/env bash
set -e
export HOME="/root"
export USER="root"
export LOGNAME="root"
export HOMEBREW_PREFIX="$prefix"
export HOMEBREW_CELLAR="$prefix/Cellar"
export HOMEBREW_REPOSITORY="$repo"
export PATH="$prefix/bin:$prefix/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
[ -r "$envf" ] && . "$envf"
: "\${HOMEBREW_NO_ANALYTICS:=1}"
: "\${HOMEBREW_NO_ENV_HINTS:=1}"
: "\${HOMEBREW_NO_AUTO_UPDATE:=1}"
: "\${HOMEBREW_NO_INSTALL_CLEANUP:=1}"
export HOMEBREW_NO_ANALYTICS HOMEBREW_NO_ENV_HINTS HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_INSTALL_CLEANUP
export LD_PRELOAD="$shim\${LD_PRELOAD:+:\$LD_PRELOAD}"
exec "$real_brew" "\$@"
WRAP
    chmod 0755 "$wrapper"
    tui_msg "Wrapper reinstalled" "Root brew wrapper written to:\n$wrapper\nUsing prefix: $prefix"
}

_brew_root_fix_perms() {
    if [ "$(id -u)" -ne 0 ]; then tui_msg "Root required" "Fixing permissions requires root."; return 1; fi
    local prefix; prefix=$(_brew_root_prefix)
    [ -d "$prefix" ] || { tui_msg "Not found" "Homebrew prefix not found:\n$prefix\nInstall Homebrew first."; return 1; }
    run_cmd "Fix Homebrew prefix ownership" chown -R root:root "$prefix"
    run_cmd "Fix Homebrew prefix permissions" chmod -R u+rwX,go+rX "$prefix"
    tui_msg "Permissions fixed" "Ownership and permissions updated for:\n$prefix"
}

_brew_root_update_profile() {
    if [ "$(id -u)" -ne 0 ]; then tui_msg "Root required" "Updating the profile requires root."; return 1; fi
    local prefix; prefix=$(_brew_root_prefix)
    local prof; prof=$(_brew_root_profile)
    local envf=/etc/systui/homebrew.env
    mkdir -p /etc/profile.d
    cat > "$prof" <<PROF
export HOMEBREW_PREFIX="$prefix"
export HOMEBREW_CELLAR="$prefix/Cellar"
export HOMEBREW_REPOSITORY="$prefix/Homebrew"
export PATH="/usr/local/bin:$prefix/bin:$prefix/sbin:\$PATH"
export MANPATH="$prefix/share/man\${MANPATH+:\$MANPATH}"
export INFOPATH="$prefix/share/info\${INFOPATH+:\$INFOPATH}"
[ -r "$envf" ] && . "$envf"
PROF
    chmod 0644 "$prof"
    for _pf in /root/.bashrc /root/.profile; do
        touch "$_pf" 2>/dev/null || true
        grep -Fq '/etc/profile.d/homebrew.sh' "$_pf" 2>/dev/null || \
            printf '\n# Root-managed Homebrew\n[ -r /etc/profile.d/homebrew.sh ] && . /etc/profile.d/homebrew.sh\n' >> "$_pf"
    done
    tui_msg "Profile updated" "$prof written.\nPrefix: $prefix"
}

_brew_root_remove_layer() {
    if [ "$(id -u)" -ne 0 ]; then tui_msg "Root required" "Removing the root layer requires root."; return 1; fi
    tui_yesno "Remove root-compat layer" "This will:\n• Remove /usr/local/bin/brew wrapper\n• Remove the UID shim library\n• Remove /etc/profile.d/homebrew.sh\n• Remove /etc/systui/homebrew.env\n\nThe Homebrew installation itself is kept. Continue?" || return 0
    rm -f "$(_brew_root_wrapper)" 2>/dev/null || true
    rm -rf "$(_brew_root_shim_dir)" 2>/dev/null || true
    rm -f "$(_brew_root_profile)" 2>/dev/null || true
    rm -f /etc/systui/homebrew.env 2>/dev/null || true
    for _pf in /root/.bashrc /root/.profile; do
        [ -f "$_pf" ] && sed -i '/Root-managed Homebrew/d;/etc\/profile\.d\/homebrew\.sh/d' "$_pf" 2>/dev/null || true
    done
    tui_msg "Root layer removed" "All root-compat files have been removed.\nTo use brew again, log in as a non-root user or reinstall the compat layer."
}

menu_brew_root_config() {
    while true; do
        local shim_ok wrapper_ok bypass_state prefix
        shim_ok=$([ -f "$(_brew_root_shim_dir)/libhomebrew_fakeuid.so" ] && echo "✓ installed" || echo "✗ not found")
        wrapper_ok=$([ -x "$(_brew_root_wrapper)" ] && echo "✓ present" || echo "✗ not found")
        bypass_state=$(brew_root_bypass_enabled && echo "ENABLED" || echo "disabled")
        prefix=$(_brew_root_prefix)

        local c
        c=$(tui_menu "Brew Root Config" \
            "Root bypass: $bypass_state | Shim: $shim_ok | Wrapper: $wrapper_ok\nPrefix: $prefix\n\nRoot compatibility options:" \
            bypass    "$(brew_root_bypass_enabled && echo 'Disable' || echo 'Enable') permanent root bypass (HOMEBREW_ALLOW_ROOT)" \
            shim      "Rebuild UID shim  (libhomebrew_fakeuid.so)" \
            wrapper   "Reinstall root wrapper  (/usr/local/bin/brew)" \
            perms     "Fix prefix ownership and permissions" \
            profile   "Update /etc/profile.d/homebrew.sh" \
            full      "Full root-compat reinstall (re-run installer script)" \
            remove    "Remove root-compat layer" \
            back      "Back") || return 0

        case "$c" in
            bypass)
                if [ "$(id -u)" -ne 0 ]; then
                    tui_msg "Root bypass" "Changing the system-wide root bypass requires root."; continue
                fi
                if brew_root_bypass_enabled; then
                    tui_yesno "Disable root bypass" "Remove HOMEBREW_ALLOW_ROOT from /etc/systui/homebrew.env?" || continue
                    brew_set_root_bypass 0
                    tui_msg "Root bypass" "Root bypass disabled. brew runs under the non-root target user."
                else
                    tui_yesno "Enable root bypass" "Set HOMEBREW_ALLOW_ROOT=1 permanently?\n\nOnly enable this if the root-compat layer (shim + wrapper) is installed." || continue
                    brew_set_root_bypass 1
                    tui_msg "Root bypass" "Root bypass enabled. brew runs directly as root."
                fi
                ;;
            shim)    _brew_root_rebuild_shim ;;
            wrapper) _brew_root_reinstall_wrapper ;;
            perms)   _brew_root_fix_perms ;;
            profile) _brew_root_update_profile ;;
            full)
                if [ "$(id -u)" -ne 0 ]; then
                    tui_msg "Homebrew" "Full root-compat reinstall requires root."; continue
                fi
                script=$(brew_root_compat_script)
                [ -r "$script" ] || { tui_msg "Homebrew" "Installer script not found:\n$script"; continue; }
                run_cmd "Reinstall Homebrew root-compat layer" bash "$script"
                ;;
            remove) _brew_root_remove_layer ;;
            back|"") return 0 ;;
        esac
    done
}

# Formula-level package operations menu (install / reinstall / remove / autoremove).
menu_brew_pkgops() {
    while true; do
        local c
        c=$(tui_menu "Homebrew formula operations" "Manage installed formulae:" \
            install    "Install a formula or cask" \
            reinstall  "Reinstall a formula (keeps config, refreshes binary)" \
            remove     "Remove / uninstall a formula" \
            autoremove "Remove unused dependencies  (brew autoremove)" \
            leaves     "Show leaf formulae  (nothing depends on them)" \
            pin        "Pin a formula to its current version" \
            unpin      "Unpin a pinned formula" \
            back       "Back") || return 0

        local q
        case "$c" in
            install)
                q=$(tui_input "Install formula/cask" "Formula or cask name:" "") || continue
                [ -z "$q" ] && continue
                brew_run_as "brew install $q" install "$q"
                ;;
            reinstall)
                q=$(tui_input "Reinstall formula" "Formula name to reinstall:" "") || continue
                [ -z "$q" ] && continue
                brew_run_as "brew reinstall $q" reinstall "$q"
                ;;
            remove)
                q=$(tui_input "Remove formula" "Formula name to uninstall:" "") || continue
                [ -z "$q" ] && continue
                tui_yesno "Remove formula" "Uninstall '$q' and its dependencies that are no longer needed?" || continue
                brew_run_as "brew uninstall $q" uninstall "$q"
                ;;
            autoremove)
                brew_run_as "brew autoremove" autoremove
                ;;
            leaves)
                local tmpf="${SYSTUI_TMP}/brew_leaves_$$.txt"
                { brew_run_as "brew leaves" leaves 2>/dev/null || true; } > "$tmpf"
                tui_text "Homebrew leaf formulae" "$tmpf"
                rm -f "$tmpf"
                ;;
            pin)
                q=$(tui_input "Pin formula" "Formula name to pin at current version:" "") || continue
                [ -z "$q" ] && continue
                brew_run_as "brew pin $q" pin "$q"
                ;;
            unpin)
                q=$(tui_input "Unpin formula" "Formula name to unpin:" "") || continue
                [ -z "$q" ] && continue
                brew_run_as "brew unpin $q" unpin "$q"
                ;;
            back|"") return 0 ;;
        esac
    done
}

# Helper: write or remove a single key=value in a Homebrew env file.
# If value is empty the line is removed; otherwise it is upserted.
_brew_cfg_set() { # <envfile> <KEY> <value-or-empty>
    local envf="$1" key="$2" val="$3"
    mkdir -p "$(dirname "$envf")"
    touch "$envf" 2>/dev/null || true
    if [ -z "$val" ]; then
        sed -i "/^${key}=/d" "$envf" 2>/dev/null || true
    else
        if grep -qs "^${key}=" "$envf"; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$envf"
        else
            echo "${key}=${val}" >> "$envf"
        fi
    fi
}

# Helper: read current value for a key from the env file (empty string if unset).
_brew_cfg_get() { # <envfile> <KEY>
    grep "^${2}=" "$1" 2>/dev/null | cut -d= -f2- | tail -1
}

menu_brew_config() {
    local envf; envf=$(brew_root_compat_env_file)

    while true; do
        # Reload current values on every iteration so the menu reflects live state.
        local _a _au _eh _cl _nu _api _verb _dbg _mj _bd _ed _co _pfx _clr _tok

        _a=$(_brew_cfg_get "$envf" HOMEBREW_NO_ANALYTICS)
        _au=$(_brew_cfg_get "$envf" HOMEBREW_NO_AUTO_UPDATE)
        _eh=$(_brew_cfg_get "$envf" HOMEBREW_NO_ENV_HINTS)
        _cl=$(_brew_cfg_get "$envf" HOMEBREW_NO_INSTALL_CLEANUP)
        _nu=$(_brew_cfg_get "$envf" HOMEBREW_NO_INSTALL_UPGRADE)
        _api=$(_brew_cfg_get "$envf" HOMEBREW_INSTALL_FROM_API)
        _verb=$(_brew_cfg_get "$envf" HOMEBREW_VERBOSE)
        _dbg=$(_brew_cfg_get "$envf" HOMEBREW_DEBUG)
        _mj=$(_brew_cfg_get "$envf" HOMEBREW_MAKE_JOBS)
        _bd=$(_brew_cfg_get "$envf" HOMEBREW_BOTTLE_DOMAIN)
        _ed=$(_brew_cfg_get "$envf" HOMEBREW_EDITOR)
        _co=$(_brew_cfg_get "$envf" HOMEBREW_CASK_OPTS)
        _pfx=$(_brew_cfg_get "$envf" HOMEBREW_PREFIX)
        _clr=$(_brew_cfg_get "$envf" HOMEBREW_CELLAR)
        _tok=$(_brew_cfg_get "$envf" HOMEBREW_GITHUB_API_TOKEN)

        local c
        c=$(tui_menu "Homebrew Config" "Config file: $envf\n\nAll settings are persisted to the env file and loaded at brew launch." \
            toggles  "Feature toggles  (analytics, auto-update, cleanup…)" \
            makejobs "Parallel build jobs              [${_mj:-default}]" \
            editor   "Preferred editor  HOMEBREW_EDITOR  [${_ed:-unset}]" \
            token    "GitHub API token  ($([ -n "$_tok" ] && echo SET || echo unset))" \
            bottle   "Bottle mirror URL                [${_bd:-upstream}]" \
            caskopts "Cask install opts HOMEBREW_CASK_OPTS [${_co:-unset}]" \
            prefix   "Install prefix    HOMEBREW_PREFIX  [${_pfx:-default}]" \
            cellar   "Cellar path       HOMEBREW_CELLAR  [${_clr:-default}]" \
            viewfile "View / edit raw config file" \
            reset    "Reset — remove all systui-managed brew settings" \
            back     "Back") || return 0

        case "$c" in
            toggles)
                local sel
                sel=$(tui_check "Homebrew feature toggles" \
                    "SPACE toggles; ENTER saves. Active options have [*]:" \
                    analytics   "Disable analytics               (HOMEBREW_NO_ANALYTICS)"     "$([ "$_a"    = 1 ] && echo on || echo off)" \
                    autoupdate  "Disable auto-update on install  (HOMEBREW_NO_AUTO_UPDATE)"   "$([ "$_au"   = 1 ] && echo on || echo off)" \
                    envhints    "Disable environment hints       (HOMEBREW_NO_ENV_HINTS)"     "$([ "$_eh"   = 1 ] && echo on || echo off)" \
                    cleanup     "Disable auto-cleanup after ops  (HOMEBREW_NO_INSTALL_CLEANUP)" "$([ "$_cl" = 1 ] && echo on || echo off)" \
                    noupgrade   "Disable auto-upgrade on install (HOMEBREW_NO_INSTALL_UPGRADE)" "$([ "$_nu" = 1 ] && echo on || echo off)" \
                    fromapi     "Install from API — faster, no tap clone (HOMEBREW_INSTALL_FROM_API)" "$([ "$_api" = 1 ] && echo on || echo off)" \
                    verbose     "Verbose output                  (HOMEBREW_VERBOSE)"          "$([ "$_verb" = 1 ] && echo on || echo off)" \
                    debug       "Debug mode                      (HOMEBREW_DEBUG)"            "$([ "$_dbg"  = 1 ] && echo on || echo off)") || continue

                _brew_cfg_set "$envf" HOMEBREW_NO_ANALYTICS      "$(echo "$sel" | grep -q analytics  && echo 1 || echo '')"
                _brew_cfg_set "$envf" HOMEBREW_NO_AUTO_UPDATE    "$(echo "$sel" | grep -q autoupdate && echo 1 || echo '')"
                _brew_cfg_set "$envf" HOMEBREW_NO_ENV_HINTS      "$(echo "$sel" | grep -q envhints   && echo 1 || echo '')"
                _brew_cfg_set "$envf" HOMEBREW_NO_INSTALL_CLEANUP "$(echo "$sel" | grep -q cleanup   && echo 1 || echo '')"
                _brew_cfg_set "$envf" HOMEBREW_NO_INSTALL_UPGRADE "$(echo "$sel" | grep -q noupgrade && echo 1 || echo '')"
                _brew_cfg_set "$envf" HOMEBREW_INSTALL_FROM_API  "$(echo "$sel" | grep -q fromapi    && echo 1 || echo '')"
                _brew_cfg_set "$envf" HOMEBREW_VERBOSE           "$(echo "$sel" | grep -q verbose    && echo 1 || echo '')"
                _brew_cfg_set "$envf" HOMEBREW_DEBUG             "$(echo "$sel" | grep -q debug      && echo 1 || echo '')"
                tui_msg "Toggles saved" "Feature flags written to:\n$envf"
                ;;
            makejobs)
                local v; v=$(tui_input "Parallel build jobs" \
                    "Number of parallel jobs for make (blank = use nproc default):" \
                    "${_mj:-}") || continue
                _brew_cfg_set "$envf" HOMEBREW_MAKE_JOBS "$v"
                [ -n "$v" ] && tui_msg "Saved" "HOMEBREW_MAKE_JOBS=$v" || tui_msg "Cleared" "HOMEBREW_MAKE_JOBS removed (defaults to nproc)"
                ;;
            editor)
                local v; v=$(tui_input "HOMEBREW_EDITOR" \
                    "Editor command for 'brew edit' (e.g. nano, vim, code):" \
                    "${_ed:-}") || continue
                _brew_cfg_set "$envf" HOMEBREW_EDITOR "$v"
                [ -n "$v" ] && tui_msg "Saved" "HOMEBREW_EDITOR=$v" || tui_msg "Cleared" "HOMEBREW_EDITOR removed"
                ;;
            token)
                local v; v=$(tui_input "GitHub API token" \
                    "Personal Access Token for GitHub API (increases rate limits).\nLeave blank to clear." \
                    "") || continue
                _brew_cfg_set "$envf" HOMEBREW_GITHUB_API_TOKEN "$v"
                [ -n "$v" ] && tui_msg "Saved" "HOMEBREW_GITHUB_API_TOKEN set (value hidden)." || tui_msg "Cleared" "HOMEBREW_GITHUB_API_TOKEN removed."
                ;;
            bottle)
                local v; v=$(tui_input "Bottle mirror URL" \
                    "Custom bottle CDN/mirror (e.g. https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles).\nBlank = use upstream." \
                    "${_bd:-}") || continue
                _brew_cfg_set "$envf" HOMEBREW_BOTTLE_DOMAIN "$v"
                [ -n "$v" ] && tui_msg "Saved" "HOMEBREW_BOTTLE_DOMAIN=$v" || tui_msg "Cleared" "Using upstream bottle server."
                ;;
            caskopts)
                local v; v=$(tui_input "HOMEBREW_CASK_OPTS" \
                    "Options appended to every 'brew install --cask' (e.g. --no-quarantine --appdir=~/Applications):" \
                    "${_co:-}") || continue
                _brew_cfg_set "$envf" HOMEBREW_CASK_OPTS "$v"
                [ -n "$v" ] && tui_msg "Saved" "HOMEBREW_CASK_OPTS=$v" || tui_msg "Cleared" "HOMEBREW_CASK_OPTS removed."
                ;;
            prefix)
                local v; v=$(tui_input "HOMEBREW_PREFIX" \
                    "Install prefix path (e.g. /home/linuxbrew/.linuxbrew).\nBlank = default." \
                    "${_pfx:-}") || continue
                _brew_cfg_set "$envf" HOMEBREW_PREFIX "$v"
                [ -n "$v" ] && tui_msg "Saved" "HOMEBREW_PREFIX=$v" || tui_msg "Cleared" "Using default prefix."
                ;;
            cellar)
                local v; v=$(tui_input "HOMEBREW_CELLAR" \
                    "Cellar path (e.g. /home/linuxbrew/.linuxbrew/Cellar).\nBlank = default." \
                    "${_clr:-}") || continue
                _brew_cfg_set "$envf" HOMEBREW_CELLAR "$v"
                [ -n "$v" ] && tui_msg "Saved" "HOMEBREW_CELLAR=$v" || tui_msg "Cleared" "Using default cellar path."
                ;;
            viewfile)
                pm_edit_file "$envf"
                ;;
            reset)
                tui_yesno "Reset brew config" "Remove all Homebrew settings from:\n$envf\n\nThis only clears keys managed by systui. The file is kept." || continue
                for _k in HOMEBREW_NO_ANALYTICS HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_ENV_HINTS \
                           HOMEBREW_NO_INSTALL_CLEANUP HOMEBREW_NO_INSTALL_UPGRADE \
                           HOMEBREW_INSTALL_FROM_API HOMEBREW_VERBOSE HOMEBREW_DEBUG \
                           HOMEBREW_MAKE_JOBS HOMEBREW_BOTTLE_DOMAIN HOMEBREW_EDITOR \
                           HOMEBREW_CASK_OPTS HOMEBREW_PREFIX HOMEBREW_CELLAR \
                           HOMEBREW_GITHUB_API_TOKEN; do
                    _brew_cfg_set "$envf" "$_k" ""
                done
                tui_msg "Reset" "All managed Homebrew settings cleared from $envf"
                ;;
            back|"") return 0 ;;
        esac
    done
}

# Fetch an installer script to a temp file and run it, instead of piping
# curl straight into sh. A bare `curl ... | sh` executes whatever bytes
# arrive as they arrive: a dropped connection can silently truncate the
# script mid-statement, and there is nothing to inspect if it misbehaves.
# Downloading first lets us confirm the fetch actually succeeded and gives
# a file on disk that can be reviewed before (or after) it runs. This does
# not replace checksum verification -- these upstream installers don't all
# publish one -- but it removes the streaming-truncation failure mode and
# enforces HTTPS + TLS 1.2+ so a downgrade or plaintext response can't be
# fed to the shell.
_dl_run_installer() { # <description> <url> <shell> [installer-args...]
    local desc="$1" url="$2" shell="$3"; shift 3
    local tmp; tmp="$(mktemp "${SYSTUI_TMP:-/tmp}/installer.XXXXXX.sh")" || return 1
    run_cmd "$desc" bash -c '
        set -e
        curl --proto "=https" --tlsv1.2 -fsSL "$1" -o "$2"
        [ -s "$2" ] || { echo "download was empty" >&2; exit 1; }
        "$3" "$2" "${@:4}"
    ' _ "$url" "$tmp" "$shell" "$@"
    local rc=$?
    rm -f "$tmp"
    return $rc
}

menu_nix_install() {
    local c
    c=$(tui_menu "Install Nix" "Choose installation method:" \
        official    "Official multi-user install (nixos.org)" \
        determinate "Determinate Systems nix-installer (fast & robust)" \
        single      "Official single-user install" \
        pm          "Package manager (${PM} install nix)" \
        back        "Back") || return 0
    case "$c" in
        official)    _dl_run_installer "Install Nix (multi-user)" https://nixos.org/nix/install sh -- --daemon ;;
        determinate) _dl_run_installer "Install Nix (Determinate)" https://install.determinate.systems/nix sh -- install ;;
        single)      _dl_run_installer "Install Nix (single-user)" https://nixos.org/nix/install sh -- --no-daemon ;;
        pm)          pm_install nix ;;
        back|"")     return 0 ;;
    esac
}

menu_yay_install() {
    if ! command -v pacman >/dev/null 2>&1; then
        tui_msg "yay" "yay is an AUR helper and requires Arch Linux (pacman)."
        return 0
    fi
    local c
    c=$(tui_menu "Install yay" "Choose installation method:" \
        makepkg "git clone + makepkg (official AUR method)" \
        binary  "Download prebuilt binary from GitHub releases" \
        back    "Back") || return 0
    case "$c" in
        makepkg) run_cmd "Install yay" bash -c \
            'cd /tmp && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm && cd / && rm -rf /tmp/yay' ;;
        binary)  case "$(uname -m)" in
            x86_64|aarch64|arm64) run_cmd "Install yay (binary)" bash -c '
tag=$(curl -fsSL https://api.github.com/repos/Jguer/yay/releases/latest | sed -n "s/.*\"tag_name\":.*\"\([^\"]*\)\".*/\1/p")
arch=$(uname -m); [ "$arch" = x86_64 ] && arch=x86_64 || arch=aarch64
url="https://github.com/Jguer/yay/releases/download/${tag}/yay_${tag#v}_${arch}.tar.gz"
tmp=$(mktemp -d)
curl -fsSL "$url" | tar -xz -C "$tmp"
install -m 0755 "$(find "$tmp" -name yay -type f | head -1)" /usr/local/bin/yay
rm -rf "$tmp"' ;;
            *) tui_msg "yay" "yay publishes prebuilt binaries only for x86_64 and aarch64.\nOn $(uname -m), use the makepkg method instead." ;;
        esac ;;
        back|"") return 0 ;;
    esac
}

menu_paru_install() {
    if ! command -v pacman >/dev/null 2>&1; then
        tui_msg "paru" "paru is an AUR helper and requires Arch Linux (pacman)."
        return 0
    fi
    local c
    c=$(tui_menu "Install paru" "Choose installation method:" \
        makepkg "git clone + makepkg (official AUR method)" \
        cargo   "cargo install paru" \
        binary  "Download prebuilt binary from GitHub releases" \
        back    "Back") || return 0
    case "$c" in
        makepkg) run_cmd "Install paru" bash -c \
            'cd /tmp && git clone https://aur.archlinux.org/paru.git && cd paru && makepkg -si --noconfirm && cd / && rm -rf /tmp/paru' ;;
        cargo)   command -v cargo >/dev/null || { tui_msg "paru" "cargo is required. Install Rust/Cargo first."; return 0; }
                 run_cmd "Install paru (cargo)" cargo install paru ;;
        binary)  case "$(uname -m)" in
            x86_64|aarch64|arm64|armv7l|armv7) run_cmd "Install paru (binary)" bash -c '
tag=$(curl -fsSL https://api.github.com/repos/morganamilo/paru/releases/latest | sed -n "s/.*\"tag_name\":.*\"\([^\"]*\)\".*/\1/p")
arch=$(uname -m); case "$arch" in x86_64) arch=x86_64;; aarch64|arm64) arch=aarch64;; armv7l|armv7) arch=armv7h;; esac
url="https://github.com/morganamilo/paru/releases/download/${tag}/paru-${tag}-${arch}.tar.zst"
tmp=$(mktemp -d)
curl -fsSL "$url" | tar --zstd -x -C "$tmp" 2>/dev/null || curl -fsSL "$url" | tar -xI zstd -C "$tmp" 2>/dev/null
install -m 0755 "$(find "$tmp" -name paru -type f | head -1)" /usr/local/bin/paru
rm -rf "$tmp"' ;;
            *) tui_msg "paru" "paru publishes prebuilt binaries only for x86_64, aarch64 and armv7h.\nOn $(uname -m), use the makepkg or cargo method instead." ;;
        esac ;;
        back|"") return 0 ;;
    esac
}

menu_cargo_install() {
    local c
    c=$(tui_menu "Install Cargo/Rust" "Choose installation method:" \
        rustup "rustup (official, recommended) — installs rustup + cargo + rustc" \
        pm     "Package manager (${PM} install cargo rustc)" \
        snap   "Snap: snap install rustup --classic" \
        back   "Back") || return 0
    case "$c" in
        rustup) _dl_run_installer "Install Rust via rustup" https://sh.rustup.rs sh -- -y ;;
        pm)     pm_install cargo rustc ;;
        snap)   command -v snap >/dev/null || { tui_msg "snap" "snapd is not installed."; return 0; }
                run_cmd "Install rustup via snap" snap install rustup --classic ;;
        back|"") return 0 ;;
    esac
}

menu_npm_install() {
    local c
    c=$(tui_menu "Install Node.js/npm" "Choose installation method:" \
        nvm        "nvm — Node Version Manager (user-level, recommended)" \
        fnm        "fnm — Fast Node Manager (user-level)" \
        nodesource "NodeSource APT/RPM repo (system-wide LTS)" \
        pm         "Package manager (${PM} install nodejs npm)" \
        back       "Back") || return 0
    case "$c" in
        nvm)  _dl_run_installer "Install nvm" https://raw.githubusercontent.com/nvm-sh/nvm/HEAD/install.sh bash ;;
        fnm)  _dl_run_installer "Install fnm" https://fnm.vercel.app/install bash ;;
        nodesource)
            case "$PM" in
                apt) _dl_run_installer "Add NodeSource LTS (APT)" https://deb.nodesource.com/setup_lts.x bash ;;
                dnf|yum) _dl_run_installer "Add NodeSource LTS (RPM)" https://rpm.nodesource.com/setup_lts.x bash ;;
                *) tui_msg "NodeSource" "NodeSource setup scripts support APT and DNF/YUM only." ;;
            esac ;;
        pm) pm_install nodejs npm ;;
        back|"") return 0 ;;
    esac
}

menu_pnpm_install() {
    local c
    c=$(tui_menu "Install pnpm" "Choose installation method:" \
        script "Official install script (recommended)" \
        npm    "npm: npm install -g pnpm" \
        brew   "Homebrew: brew install pnpm" \
        pm     "Package manager (${PM} install pnpm)" \
        back   "Back") || return 0
    case "$c" in
        script) _dl_run_installer "Install pnpm" https://get.pnpm.io/install.sh sh ;;
        npm)    command -v npm >/dev/null || { tui_msg "pnpm" "npm is required. Install Node.js first."; return 0; }
                run_cmd "Install pnpm via npm" npm install -g pnpm ;;
        brew)   command -v brew >/dev/null || { tui_msg "pnpm" "Homebrew is not installed."; return 0; }
                run_cmd "Install pnpm via brew" brew install pnpm ;;
        pm)     pm_install pnpm ;;
        back|"") return 0 ;;
    esac
}

menu_yarn_install() {
    local c
    c=$(tui_menu "Install Yarn" "Choose installation method:" \
        corepack "corepack enable (Node.js ≥16, recommended)" \
        npm      "npm: npm install -g yarn" \
        brew     "Homebrew: brew install yarn" \
        pm       "Package manager (${PM} install yarn)" \
        back     "Back") || return 0
    case "$c" in
        corepack) command -v node >/dev/null || { tui_msg "Yarn" "Node.js is required. Install it first."; return 0; }
                  run_cmd "Enable Yarn via corepack" corepack enable ;;
        npm)      command -v npm >/dev/null || { tui_msg "Yarn" "npm is required. Install Node.js first."; return 0; }
                  run_cmd "Install Yarn via npm" npm install -g yarn ;;
        brew)     command -v brew >/dev/null || { tui_msg "Yarn" "Homebrew is not installed."; return 0; }
                  run_cmd "Install Yarn via brew" brew install yarn ;;
        pm)       pm_install yarn ;;
        back|"")  return 0 ;;
    esac
}

menu_gem_install() {
    local c
    c=$(tui_menu "Install Ruby/RubyGems" "Choose installation method:" \
        rbenv "rbenv — per-user Ruby version manager (recommended)" \
        rvm   "RVM — Ruby Version Manager" \
        asdf  "asdf ruby plugin" \
        pm    "Package manager (${PM} install ruby)" \
        back  "Back") || return 0
    case "$c" in
        rbenv) _dl_run_installer "Install rbenv + ruby-build" https://rbenv.org/install.sh bash ;;
        rvm)   _dl_run_installer "Install RVM" https://get.rvm.io bash -- stable --ruby ;;
        asdf)  command -v asdf >/dev/null || { tui_msg "asdf" "asdf is not installed."; return 0; }
               run_cmd "Install Ruby via asdf" bash -c 'asdf plugin add ruby && asdf install ruby latest && asdf global ruby latest' ;;
        pm)    pm_install ruby ;;
        back|"") return 0 ;;
    esac
}

menu_composer_install() {
    local c
    c=$(tui_menu "Install Composer" "Choose installation method:" \
        official "Official PHP installer (getcomposer.org)" \
        brew     "Homebrew: brew install composer" \
        pm       "Package manager (${PM} install composer)" \
        back     "Back") || return 0
    case "$c" in
        official)
            command -v php >/dev/null || { tui_msg "Composer" "PHP is required. Install it first."; return 0; }
            run_cmd "Install Composer" bash -c '
php -r "copy(\"https://getcomposer.org/installer\", \"/tmp/composer-setup.php\");"
HASH=$(curl -sS https://composer.github.io/installer.sig)
php -r "if (hash_file(\"sha384\", \"/tmp/composer-setup.php\") !== getenv(\"HASH\")) { echo \"Installer corrupt\\n\"; unlink(\"/tmp/composer-setup.php\"); exit(1); }" 2>&1
php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
rm -f /tmp/composer-setup.php' ;;
        brew)    command -v brew >/dev/null || { tui_msg "Composer" "Homebrew is not installed."; return 0; }
                 run_cmd "Install Composer via brew" brew install composer ;;
        pm)      pm_install composer ;;
        back|"") return 0 ;;
    esac
}

menu_go_install() {
    local c
    c=$(tui_menu "Install Go" "Choose installation method:" \
        official "Official tarball — latest stable from go.dev/dl" \
        snap     "Snap: snap install go --classic" \
        brew     "Homebrew: brew install go" \
        pm       "Package manager (${PM} install golang)" \
        back     "Back") || return 0
    case "$c" in
        official) run_cmd "Install Go (official tarball)" bash -c '
arch=$(uname -m); case "$arch" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; riscv64) arch=riscv64;; ppc64le) arch=ppc64le;; s390x) arch=s390x;; *) arch=386;; esac
ver=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
url="https://go.dev/dl/${ver}.linux-${arch}.tar.gz"
rm -rf /usr/local/go
curl -fsSL "$url" | tar -xz -C /usr/local
ln -sf /usr/local/go/bin/go /usr/local/bin/go
ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt' ;;
        snap)     command -v snap >/dev/null || { tui_msg "snap" "snapd is not installed."; return 0; }
                  run_cmd "Install Go via snap" snap install go --classic ;;
        brew)     command -v brew >/dev/null || { tui_msg "Go" "Homebrew is not installed."; return 0; }
                  run_cmd "Install Go via brew" brew install go ;;
        pm)       pm_install golang-go 2>/dev/null || pm_install go ;;
        back|"")  return 0 ;;
    esac
}

menu_pipx_install() {
    local c
    c=$(tui_menu "Install pipx" "Choose installation method:" \
        pip  "pip: pip3 install --user pipx" \
        brew "Homebrew: brew install pipx" \
        pm   "Package manager (${PM} install pipx)" \
        back "Back") || return 0
    case "$c" in
        pip)  command -v pip3 >/dev/null || { tui_msg "pipx" "pip3 is required. Install Python 3 first."; return 0; }
              run_cmd "Install pipx via pip" pip3 install --user pipx ;;
        brew) command -v brew >/dev/null || { tui_msg "pipx" "Homebrew is not installed."; return 0; }
              run_cmd "Install pipx via brew" brew install pipx ;;
        pm)   pm_install pipx ;;
        back|"") return 0 ;;
    esac
}

menu_pip_install() {
    local c
    c=$(tui_menu "Install pip" "Choose installation method:" \
        ensurepip "python3 -m ensurepip (bootstrap from stdlib)" \
        getpip    "get-pip.py — PyPA official bootstrap script" \
        pm        "Package manager (${PM} install python3-pip)" \
        back      "Back") || return 0
    case "$c" in
        ensurepip) command -v python3 >/dev/null || { tui_msg "pip" "Python 3 is required."; return 0; }
                   run_cmd "Bootstrap pip" python3 -m ensurepip --upgrade ;;
        getpip)    command -v python3 >/dev/null || { tui_msg "pip" "Python 3 is required."; return 0; }
                   run_cmd "Install pip via get-pip.py" bash -c \
                       'curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py && python3 /tmp/get-pip.py && rm -f /tmp/get-pip.py' ;;
        pm)        pm_install python3-pip 2>/dev/null || pm_install python-pip ;;
        back|"")   return 0 ;;
    esac
}

menu_flatpak_install() {
    local c
    c=$(tui_menu "Install Flatpak" "Choose installation method:" \
        pm      "Package manager (${PM} install flatpak) — recommended" \
        flathub "Install Flatpak + add Flathub remote" \
        back    "Back") || return 0
    case "$c" in
        pm)      pm_install flatpak ;;
        flathub) pm_install flatpak
                 command -v flatpak >/dev/null && \
                     run_cmd "Add Flathub remote" flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo ;;
        back|"") return 0 ;;
    esac
}

menu_snap_install() {
    local c
    c=$(tui_menu "Install snapd" "Choose installation method:" \
        pm     "Package manager (${PM} install snapd)" \
        enable "Install snapd + enable and start snapd service" \
        back   "Back") || return 0
    case "$c" in
        pm)     pm_install snapd ;;
        enable) pm_install snapd
                run_cmd "Enable snapd service" bash -c \
                    'systemctl enable --now snapd.service 2>/dev/null; ln -sf /var/lib/snapd/snap /snap 2>/dev/null || true' ;;
        back|"") return 0 ;;
    esac
}

menu_package_managers() {
    while true; do
        local c
        c=$(tui_menu "Package Managers" "Configure native, universal and language package managers:" \
            advanced "Advanced settings for the active manager ($PM) — SPACE to select" \
            native "Native manager ($PM): full configuration and maintenance" \
            apt "APT $(pm_status apt-get)" aptfast "apt-fast $(pm_status apt-fast)" nala "Nala $(pm_status nala)" aptitude "aptitude $(pm_status aptitude)" \
            pacman "pacman $(pm_status pacman)" yay "yay $(pm_status yay)" paru "paru $(pm_status paru)" \
            dnf "DNF $(pm_status dnf)" yum "YUM $(pm_status yum)" zypper "zypper $(pm_status zypper)" apk "apk $(pm_status apk)" xbps "XBPS $(pm_status xbps-install)" emerge "Portage/emerge $(pm_status emerge)" \
            flatpak "Flatpak $(pm_status flatpak)" snap "Snap $(pm_status snap)" nix "Nix $(pm_status nix)" brew "Homebrew/Linuxbrew $(pm_status brew)" \
            pip "pip $(pm_status pip3)" pipx "pipx $(pm_status pipx)" npm "npm $(pm_status npm)" pnpm "pnpm $(pm_status pnpm)" yarn "Yarn $(pm_status yarn)" \
            cargo "Cargo $(pm_status cargo)" gem "RubyGems $(pm_status gem)" composer "Composer $(pm_status composer)" go "Go modules/tools $(pm_status go)" back "Back") || return 0
        case "$c" in
            advanced) pm_advanced_menu "$PM" ;;
            native) menu_cfg_native_full ;;
            apt) command -v apt-get >/dev/null && menu_cfg_apt || tui_msg "APT" "APT is not installed." ;;
            aptfast) command -v apt-get >/dev/null && menu_cfg_aptfast || tui_msg "apt-fast" "apt-fast requires APT." ;;
            nala) command -v apt-get >/dev/null && menu_cfg_nala || tui_msg "Nala" "Nala requires APT." ;;
            aptitude) menu_cfg_cli_manager aptitude aptitude /etc/apt/apt.conf aptitude ;;
            pacman) command -v pacman >/dev/null && { PM_SAVE="$PM"; PM=pacman; menu_cfg_native_full; PM="$PM_SAVE"; } || tui_msg "pacman" "pacman is not installed." ;;
            dnf) command -v dnf >/dev/null && { PM_SAVE="$PM"; PM=dnf; menu_cfg_native_full; PM="$PM_SAVE"; } || tui_msg "DNF" "DNF is not installed." ;;
            yum) command -v yum >/dev/null && { PM_SAVE="$PM"; PM=yum; menu_cfg_native_full; PM="$PM_SAVE"; } || tui_msg "YUM" "YUM is not installed." ;;
            zypper) command -v zypper >/dev/null && { PM_SAVE="$PM"; PM=zypper; menu_cfg_native_full; PM="$PM_SAVE"; } || tui_msg "zypper" "zypper is not installed." ;;
            apk) command -v apk >/dev/null && { PM_SAVE="$PM"; PM=apk; menu_cfg_native_full; PM="$PM_SAVE"; } || tui_msg "apk" "apk is not installed." ;;
            xbps) command -v xbps-install >/dev/null && { PM_SAVE="$PM"; PM=xbps; menu_cfg_native_full; PM="$PM_SAVE"; } || tui_msg "XBPS" "XBPS is not installed." ;;
            emerge) command -v emerge >/dev/null && { PM_SAVE="$PM"; PM=emerge; menu_cfg_native_full; PM="$PM_SAVE"; } || tui_msg "Portage" "emerge is not installed." ;;
            yay)     menu_cfg_cli_manager yay  yay  "$HOME/.config/yay/config.json"   yay   menu_yay_install ;;
            paru)    menu_cfg_cli_manager paru paru "$HOME/.config/paru/paru.conf"    paru  menu_paru_install ;;
            flatpak) menu_cfg_flatpak ;;
            snap) menu_cfg_snap ;;
            nix) menu_cfg_cli_manager nix nix "$HOME/.config/nix/nix.conf" nix menu_nix_install ;;
            brew) menu_cfg_cli_manager brew brew "$HOME/.config/homebrew/brew.env" brew menu_brew_install ;;
            pip) menu_cfg_cli_manager pip pip3 "$HOME/.config/pip/pip.conf" python3-pip menu_pip_install ;;
            pipx) menu_cfg_cli_manager pipx pipx "$HOME/.config/pipx/config" pipx menu_pipx_install ;;
            npm) menu_cfg_cli_manager npm npm "$HOME/.npmrc" npm menu_npm_install ;;
            pnpm) menu_cfg_cli_manager pnpm pnpm "$HOME/.config/pnpm/rc" pnpm menu_pnpm_install ;;
            yarn) menu_cfg_cli_manager yarn yarn "$HOME/.yarnrc" yarn menu_yarn_install ;;
            cargo) menu_cfg_cli_manager cargo cargo "$HOME/.cargo/config.toml" cargo menu_cargo_install ;;
            gem) menu_cfg_cli_manager gem gem "$HOME/.gemrc" ruby menu_gem_install ;;
            composer) menu_cfg_cli_manager composer composer "$HOME/.config/composer/config.json" composer menu_composer_install ;;
            go) menu_cfg_cli_manager go go "$HOME/.config/go/env" golang menu_go_install ;;
            back|"") return 0 ;;
        esac
    done
}

# ---- 2.1 Packages ----------------------------------------------------------
menu_package_operations() {
    while true; do
        local c p t a
        c=$(tui_menu "Packages [$PM]" "Native package operations:" install "Install" remove "Remove" search "Search" info "Info" listinst "List installed" hold "Hold/unhold" update "Update/upgrade" clean "Clean" back "Back") || return 0
        case "$c" in
            install) p=$(tui_input "Install" "Packages:" "") || continue; if [ -n "$p" ]; then local -a _pkgs=(); parse_package_input "$p" _pkgs && pm_install "${_pkgs[@]}"; fi ;;
            remove) p=$(tui_input "Remove" "Packages:" "") || continue; if [ -n "$p" ]; then local -a _pkgs=(); parse_package_input "$p" _pkgs && pm_remove "${_pkgs[@]}"; fi ;;
            search) t=$(tui_input "Search" "Term:" "") || continue; [ -n "$t" ] || continue; pm_search "$t" > ${SYSTUI_TMP}/pkg 2>&1; tui_text "Search" ${SYSTUI_TMP}/pkg ;;
            info) p=$(tui_input "Info" "Package:" "") || continue; case "$PM" in apt) apt-cache show "$p";; apk) apk info -a "$p";; pacman) pacman -Si "$p" 2>/dev/null || pacman -Qi "$p";; dnf) dnf info "$p";; zypper) zypper info "$p";; emerge) emerge --search "$p";; esac > ${SYSTUI_TMP}/pkg 2>&1; tui_text "Info" ${SYSTUI_TMP}/pkg ;;
            listinst) case "$PM" in apt) dpkg-query -W;; apk) apk info -v;; pacman) pacman -Q;; dnf) dnf list installed;; zypper) zypper search -i;; emerge) qlist -Iv;; esac > ${SYSTUI_TMP}/pkg 2>&1; tui_text "Installed" ${SYSTUI_TMP}/pkg ;;
            hold) a=$(tui_radio "Hold" "Action:" hold "Hold" on unhold "Unhold" off) || continue; p=$(tui_input "Hold" "Package:" "") || continue; case "$PM" in apt) apt-mark "$a" "$p";; zypper) zypper "$([ "$a" = hold ] && echo addlock || echo removelock)" "$p";; dnf) pm_install 'dnf-command(versionlock)' 2>/dev/null; dnf versionlock "$([ "$a" = hold ] && echo add || echo delete)" "$p";; *) tui_msg "N/A" "Hold unavailable for $PM.";; esac ;;
            update) pm_update;; clean) pm_clean;; back|"") return 0;;
        esac
    done
}

menu_packages() {
    while true; do
        local c
        c=$(tui_menu_no_tags "Package Configuration [$PM]" "Select a section:" \
            packages "Install, remove, search and update packages" \
            catalogue "Browse the application catalogue" \
            repos "Repositories and keys" \
            managers "Package managers (native, Flatpak, Snap, language)" \
            advanced "Advanced package management" \
            back "Back") || return 0
        case "$c" in managers) menu_package_managers || true;; repos) menu_repos || true;; catalogue) pkg_catalogue || true;; packages) menu_package_operations || true;; advanced) menu_pkg_advanced || true;; back|"") return 0;; esac
    done
}

# ---- 2.2 Shells & plugins --------------------------------------------------

# Resolve a username to its home dir; empty output = not found.
user_home() { getent passwd "$1" | cut -d: -f6; }

# ---- Package manager configuration ------------------------------------------
aptfast_get() { grep -E "^$1=" /etc/apt-fast.conf 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"'; }
aptfast_set() { # key value
    touch /etc/apt-fast.conf
    if grep -qE "^#?$1=" /etc/apt-fast.conf; then
        sed -i -E "s|^#?$1=.*|$1=$2|" /etc/apt-fast.conf
    else
        echo "$1=$2" >> /etc/apt-fast.conf
    fi
}



# Fetch the current distribution's official mirror directory, benchmark mirrors
# against its active suite, and configure apt-fast with the fastest results.
aptfast_optimize_official_mirrors() {
    local os_id suite list_url probe_suffix tmp raw candidates results selected count
    os_id="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-debian}")"
    suite="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}")"
    [ -n "$suite" ] || suite="$(awk '$1=="deb" && $2 !~ /^\[/ {print $3; exit}' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null)"
    [ -n "$suite" ] || suite=stable

    case "$os_id" in
        devuan)
            list_url="https://pkgmaster.devuan.org/mirror_list.txt"
            probe_suffix="merged/dists/$suite/InRelease"
            ;;
        debian|raspbian)
            list_url="https://www.debian.org/mirror/list-full"
            probe_suffix="debian/dists/$suite/InRelease"
            ;;
        ubuntu|linuxmint|pop)
            list_url="https://launchpad.net/ubuntu/+archivemirrors"
            probe_suffix="ubuntu/dists/$suite/InRelease"
            ;;
        kali)
            list_url="https://http.kali.org/README.mirrorlist"
            probe_suffix="kali/dists/$suite/InRelease"
            ;;
        *)
            tui_msg "Official mirror analysis" "No official APT mirror-list parser is available for '$os_id'."
            return 0
            ;;
    esac

    count="$(tui_input "Fast mirror count" "How many fastest mirrors should apt-fast use?" "5")" || return 0
    case "$count" in ''|*[!0-9]*) count=5;; esac
    [ "$count" -ge 1 ] 2>/dev/null || count=1
    [ "$count" -le 20 ] 2>/dev/null || count=20

    tmp="$(mktemp -d ${SYSTUI_TMP}/aptfast.XXXXXX)" || return 1
    raw="$tmp/mirrors.raw"; candidates="$tmp/candidates"; results="$tmp/results"
    trap 'rm -rf "$tmp"' RETURN

    if ! curl -fsSL --connect-timeout 10 --max-time 30 "$list_url" -o "$raw"; then
        tui_msg "Mirror analysis failed" "Could not download the official mirror list:\n$list_url"
        return 0
    fi

    case "$os_id" in
        devuan)
            grep -Eo 'https?://[^[:space:]"<>]+' "$raw" | sed 's/[),;]$//' | sed 's#/*$##' | sort -u > "$candidates"
            ;;
        debian|raspbian)
            grep -Eo 'https?://[^"<> ]+' "$raw" | sed 's/&amp;/\&/g; s#/*$##' | grep -E '/debian$|/debian/' | sed 's#/debian.*#/debian#' | sort -u > "$candidates"
            ;;
        ubuntu|linuxmint|pop)
            grep -Eo 'https?://[^"<> ]+/ubuntu/?' "$raw" | sed 's#/*$##' | sort -u > "$candidates"
            ;;
        kali)
            grep -Eo 'https?://[^[:space:]"<>]+' "$raw" | sed 's/[),;]$//; s#/*$##' | sort -u > "$candidates"
            ;;
    esac

    # Keep the benchmark practical on iSH: test at most 60 official entries.
    sed -n '1,60p' "$candidates" > "$tmp/candidates.limited"
    : > "$results"
    local base probe metrics elapsed speed
    while IFS= read -r base; do
        [ -n "$base" ] || continue
        case "$os_id:$base" in
            devuan:*/merged) probe="$base/dists/$suite/InRelease" ;;
            devuan:*) probe="$base/$probe_suffix" ;;
            debian:*|raspbian:*)
                case "$base" in */debian) probe="$base/dists/$suite/InRelease";; *) probe="$base/$probe_suffix";; esac ;;
            ubuntu:*|linuxmint:*|pop:*)
                case "$base" in */ubuntu) probe="$base/dists/$suite/InRelease";; *) probe="$base/$probe_suffix";; esac ;;
            kali:*)
                case "$base" in */kali) probe="$base/dists/$suite/InRelease";; *) probe="$base/$probe_suffix";; esac ;;
        esac
        metrics="$(curl -LfsS --range 0-131071 --connect-timeout 3 --max-time 10 -o /dev/null -w '%{time_total} %{speed_download}' "$probe" 2>/dev/null)" || continue
        elapsed=${metrics%% *}; speed=${metrics##* }
        [ -n "$elapsed" ] && printf '%s\t%s\t%s\n' "$elapsed" "$speed" "$base" >> "$results"
    done < "$tmp/candidates.limited"

    if [ ! -s "$results" ]; then
        tui_msg "Mirror analysis failed" "No official mirrors responded successfully for suite '$suite'."
        return 0
    fi

    selected="$(sort -n -k1,1 -k2,2r "$results" | head -n "$count" | cut -f3)"
    local mirror_array="(" m
    while IFS= read -r m; do [ -n "$m" ] && mirror_array="$mirror_array '$m'"; done <<EOF
$selected
EOF
    mirror_array="$mirror_array )"
    aptfast_set MIRRORS "$mirror_array"

    printf 'Distribution: %s\nSuite: %s\nOfficial list: %s\n\nSelected mirrors:\n%s\n' \
        "$os_id" "$suite" "$list_url" "$selected" > "$tmp/summary"
    tui_text "apt-fast fastest official mirrors" "$tmp/summary"
}

menu_cfg_aptfast() {
    if ! command -v apt-fast >/dev/null; then
        tui_yesno "apt-fast" "apt-fast is not installed. Install it now?" || return 0
        run_cmd "Installing apt-fast" bash -c \
          "apt-get install -y aria2 curl && \
           curl -fsSL https://raw.githubusercontent.com/ilikenwf/apt-fast/master/apt-fast -o /usr/local/bin/apt-fast && \
           chmod +x /usr/local/bin/apt-fast && \
           curl -fsSL https://raw.githubusercontent.com/ilikenwf/apt-fast/master/apt-fast.conf -o /etc/apt-fast.conf"
    fi
    while true; do
        local c
        c=$(tui_menu "apt-fast configuration" \
"Current: connections=$(aptfast_get _MAXNUM), per-file splits=$(aptfast_get _SPLITCON),
confirm-before-download=$(aptfast_get DOWNLOADBEFORE)" \
            conns   "Max parallel connections (_MAXNUM)" \
            splits  "Connections per file (_SPLITCON)" \
            confirm "Ask before downloading (DOWNLOADBEFORE)" \
            analyze "Analyze official mirror list and select fastest" \
            mirrors "Set mirror list manually (MIRRORS)" \
            show    "Show /etc/apt-fast.conf" \
            back    "Back") || return 0
        case "$c" in
            conns)
                local v; v=$(tui_input "_MAXNUM" "Max parallel connections (current: $(aptfast_get _MAXNUM)):" "${_af:-16}") || continue
                [ -n "$v" ] && aptfast_set _MAXNUM "$v" ;;
            splits)
                local v; v=$(tui_input "_SPLITCON" "Connections per file (current: $(aptfast_get _SPLITCON)):" "8") || continue
                [ -n "$v" ] && aptfast_set _SPLITCON "$v" ;;
            confirm)
                local v cur; cur=$(aptfast_get DOWNLOADBEFORE)
                v=$(tui_radio "DOWNLOADBEFORE" "Ask before downloading? (current: ${cur:-unset})" \
                    true  "Yes — show size and confirm" "$( [ "$cur" = true ] && echo on || echo off)" \
                    false "No — just download" "$( [ "$cur" = true ] && echo off || echo on)") || continue
                [ -n "$v" ] && aptfast_set DOWNLOADBEFORE "$v" ;;
            analyze) aptfast_optimize_official_mirrors ;;
            mirrors)
                local v; v=$(tui_input "MIRRORS" "Comma-separated mirror URLs (blank keeps current):" "") || continue
                [ -n "$v" ] && aptfast_set MIRRORS "( '$v' )" ;;
            show) tui_text "/etc/apt-fast.conf" /etc/apt-fast.conf ;;
            back) return 0 ;;
        esac
    done
}

menu_cfg_nala() {
    if ! command -v nala >/dev/null; then
        tui_yesno "nala" "nala is not installed. Install it now?" || return 0
        pm_install nala
    fi
    while true; do
        local c
        c=$(tui_menu "nala configuration" "Modern apt frontend:" \
            fetch   "Rank & select the fastest mirrors" \
            history "Show transaction history" \
            show    "Show nala config" \
            back    "Back") || return 0
        case "$c" in
            fetch)
                local n; n=$(tui_input "nala fetch" "How many top mirrors to keep:" "3") || continue
                run_cmd "nala fetch (fastest $n mirrors)" nala fetch --auto --fetches "${n:-3}" -y ;;
            history)
                nala history > ${SYSTUI_TMP}/pkg 2>&1
                tui_text "nala history" ${SYSTUI_TMP}/pkg ;;
            show)
                { cat /etc/nala/nala.conf 2>/dev/null || echo "(no config file — defaults in use)"; } > ${SYSTUI_TMP}/pkg
                tui_text "nala config" ${SYSTUI_TMP}/pkg ;;
            back) return 0 ;;
        esac
    done
}

menu_cfg_native() {
    case "$PM" in
        pacman)
            local cur_par cur_col cur_candy cur_verb
            cur_par=$(grep -E '^ParallelDownloads' /etc/pacman.conf | grep -oE '[0-9]+' || echo "")
            grep -q '^Color$' /etc/pacman.conf && cur_col=on || cur_col=off
            grep -q '^ILoveCandy' /etc/pacman.conf && cur_candy=on || cur_candy=off
            grep -q '^VerbosePkgLists' /etc/pacman.conf && cur_verb=on || cur_verb=off
            local o
            o=$(tui_check "pacman.conf" "Current state pre-checked; SPACE toggles, ENTER applies:" \
                parallel "ParallelDownloads (currently: ${cur_par:-off})" "$( [ -n "$cur_par" ] && echo on || echo off)" \
                color    "Color output" "$cur_col" \
                candy    "ILoveCandy progress bar" "$cur_candy" \
                verbose  "VerbosePkgLists" "$cur_verb") || return 0
            o=" ${o//\"/} "
            # parallel
            case "$o" in
                *" parallel "*)
                    local n; n=$(tui_input "ParallelDownloads" "Simultaneous downloads:" "${cur_par:-5}") || return 0
                    if grep -qE '^#?ParallelDownloads' /etc/pacman.conf; then
                        sed -i -E "s/^#?ParallelDownloads.*/ParallelDownloads = ${n:-5}/" /etc/pacman.conf
                    else
                        sed -i "/^\[options\]/a ParallelDownloads = ${n:-5}" /etc/pacman.conf
                    fi ;;
                *)  sed -i -E 's/^ParallelDownloads/#ParallelDownloads/' /etc/pacman.conf ;;
            esac
            # simple toggles
            case "$o" in *" color "*)   sed -i 's/^#Color$/Color/' /etc/pacman.conf ;;
                          *)            sed -i 's/^Color$/#Color/' /etc/pacman.conf ;; esac
            case "$o" in *" candy "*)   grep -q '^ILoveCandy' /etc/pacman.conf || sed -i '/^\[options\]/a ILoveCandy' /etc/pacman.conf ;;
                          *)            sed -i '/^ILoveCandy/d' /etc/pacman.conf ;; esac
            case "$o" in *" verbose "*) sed -i 's/^#VerbosePkgLists$/VerbosePkgLists/' /etc/pacman.conf ;;
                          *)            sed -i 's/^VerbosePkgLists$/#VerbosePkgLists/' /etc/pacman.conf ;; esac
            tui_msg "Done" "/etc/pacman.conf updated to match your selection." ;;
        dnf)
            local cur_par cur_fast
            cur_par=$(grep -E '^max_parallel_downloads' /etc/dnf/dnf.conf 2>/dev/null | grep -oE '[0-9]+')
            grep -q '^fastestmirror=True' /etc/dnf/dnf.conf 2>/dev/null && cur_fast=on || cur_fast=off
            local o
            o=$(tui_check "dnf.conf" "Current state pre-checked:" \
                parallel "max_parallel_downloads (currently: ${cur_par:-unset})" "$( [ -n "$cur_par" ] && echo on || echo off)" \
                fastest  "fastestmirror" "$cur_fast" \
                weak     "Skip weak dependencies (leaner installs)" "$(grep -q '^install_weak_deps=False' /etc/dnf/dnf.conf 2>/dev/null && echo on || echo off)") || return 0
            o=" ${o//\"/} "
            sed -i '/^max_parallel_downloads/d;/^fastestmirror/d;/^install_weak_deps/d' /etc/dnf/dnf.conf
            case "$o" in *" parallel "*)
                local n; n=$(tui_input "Parallel" "Simultaneous downloads:" "${cur_par:-10}") || return 0
                echo "max_parallel_downloads=${n:-10}" >> /etc/dnf/dnf.conf ;;
            esac
            case "$o" in *" fastest "*) echo "fastestmirror=True" >> /etc/dnf/dnf.conf ;; esac
            case "$o" in *" weak "*)    echo "install_weak_deps=False" >> /etc/dnf/dnf.conf ;; esac
            tui_msg "Done" "/etc/dnf/dnf.conf updated." ;;
        apt)
            local f=/etc/apt/apt.conf.d/90systui-tune
            local o
            o=$(tui_check "apt tuning" "Current state pre-checked:" \
                langs   "Skip translation downloads" "$(grep -q 'Languages \"none\"' "$f" 2>/dev/null && echo on || echo off)" \
                retries "3 download retries" "$(grep -q 'Retries \"3\"' "$f" 2>/dev/null && echo on || echo off)" \
                phased  "Opt out of phased updates (get updates immediately)" "$(grep -q 'Always-Include-Phased' "$f" 2>/dev/null && echo on || echo off)") || return 0
            o=" ${o//\"/} "
            {
                case "$o" in *" langs "*)   echo 'Acquire::Languages "none";' ;; esac
                case "$o" in *" retries "*) echo 'Acquire::Retries "3";' ;; esac
                case "$o" in *" phased "*)  echo 'APT::Get::Always-Include-Phased-Updates "true";' ;; esac
            } > "$f"
            [ -s "$f" ] || rm -f "$f"
            tui_msg "Done" "apt tuning updated ($f)." ;;
        apk)
            tui_msg "apk" "apk has few knobs; the useful ones:\n  * Mirror choice — Repositories menu\n  * Package cache — run: setup-apkcache /var/cache/apk" ;;
    esac
}

# menu_pm_config() used to live here. It was unreachable — nothing in the menu
# tree called it — and every entry it offered duplicated Package Managers:
# "native" is menu_cfg_native_full > tune, and aptfast/nala are their own
# entries there with the same install-and-configure behaviour.

# ---- Shell -> plugin manager -> plugins hierarchy ---------------------------
# Popular plugin catalogues (curated from current GitHub ecosystems).

OMZ_BUILTIN_PLUGINS="git|git aliases & prompt info
sudo|ESC-ESC prepends sudo
z|frecency directory jumping
docker|docker completion
extract|universal extract command
history|history helpers
colored-man-pages|colored man pages
command-not-found|suggest packages for typos
kubectl|kubectl completion & aliases
npm|npm completion
tmux|tmux aliases & autostart"

# Order matters: oh-my-zsh sources plugins=() in the listed order, and the
# checklists below write selections back in catalogue order. Constraints:
#   * zsh-autocomplete wants to load first;
#   * fzf-tab must load before zsh-autosuggestions (and before highlighting);
#   * fast-syntax-highlighting / zsh-syntax-highlighting must load LAST.
OMZ_EXTERNAL_PLUGINS="zsh-autocomplete|marlonrichert/zsh-autocomplete|Real-time completion menus
zsh-completions|zsh-users/zsh-completions|Extra completion definitions
fzf-tab|Aloxaf/fzf-tab|fzf-powered tab completion
zsh-autosuggestions|zsh-users/zsh-autosuggestions|Fish-style inline suggestions
zsh-history-substring-search|zsh-users/zsh-history-substring-search|Type text, arrows search history
enhancd|b4b4r07/enhancd|Enhanced cd with frecency jump
zsh-abbr|olets/zsh-abbr|Fish-style auto-expanding abbreviations
alias-tips|djui/alias-tips|Remind you of aliases you defined
history-search-multi-word|zdharma-continuum/history-search-multi-word|Syntax-highlighted multi-word Ctrl-R
git-extra-commands|unixorn/git-extra-commands|Extra git helper commands
zsh-auto-notify|MichaelAquilina/zsh-auto-notify|Notify when long commands finish
command-execution-timer|olets/command-execution-timer|Show how long commands took
zsh-autoswitch-virtualenv|MichaelAquilina/zsh-autoswitch-virtualenv|Auto-switch Python virtualenvs
fast-syntax-highlighting|zdharma-continuum/fast-syntax-highlighting|Faster highlighting engine
zsh-syntax-highlighting|zsh-users/zsh-syntax-highlighting|Command colorization"

ZINIT_POPULAR="zsh-users/zsh-autosuggestions|Fish-style inline suggestions
zsh-users/zsh-syntax-highlighting|Command colorization
zsh-users/zsh-completions|Extra completion definitions
Aloxaf/fzf-tab|fzf-powered tab completion
zdharma-continuum/fast-syntax-highlighting|Faster highlighting engine
romkatv/powerlevel10k|Powerlevel10k prompt
b4b4r07/enhancd|Enhanced cd with frecency jump
olets/zsh-abbr|Fish-style auto-expanding abbreviations
djui/alias-tips|Remind you of aliases you defined
zdharma-continuum/history-search-multi-word|Syntax-highlighted multi-word Ctrl-R
MichaelAquilina/zsh-auto-notify|Notify when long commands finish
olets/command-execution-timer|Show how long commands took"

FISHER_POPULAR="IlanCosman/tide|Powerlevel10k-style async prompt
PatrickF1/fzf.fish|fzf keybindings (files, history, git)
jethrokuan/z|Frecency directory jumping
franciscolourenco/done|Notify when long jobs finish
jorgebucaran/autopair.fish|Auto-close brackets & quotes
meaningful-ooo/sponge|Scrub failed commands from history
nickeb96/puffer-fish|Text expansions (.. !! etc)"

TPM_POPULAR="tmux-plugins/tmux-sensible|Sane defaults everyone agrees on
tmux-plugins/tmux-resurrect|Save & restore sessions
tmux-plugins/tmux-continuum|Automatic session saving
tmux-plugins/tmux-yank|Copy to system clipboard
christoomey/vim-tmux-navigator|Seamless vim <-> tmux panes
catppuccin/tmux|Catppuccin status-bar theme
dracula/tmux|Dracula theme with widgets"

# Generic helper: manage a marked block of lines in a user rc file.
# write_marked_block <file> <marker-name> <<< "lines"
write_marked_block() {
    local rc="$1" mark="$2" content
    content=$(cat)
    touch "$rc"
    sed -i "/^# >>> systui $mark >>>/,/^# <<< systui $mark <<</d" "$rc"
    {
        echo "# >>> systui $mark >>>"
        printf '%s\n' "$content"
        echo "# <<< systui $mark <<<"
    } >> "$rc"
}

# ---- oh-my-zsh manager ----
menu_omz() { # <user> <home>
    local u="$1" home_dir="$2"
    local ozsh="$home_dir/.oh-my-zsh" rc="$home_dir/.zshrc"
    while true; do
        local c
        c=$(tui_menu "oh-my-zsh — $u" "Install & manage oh-my-zsh $(stp "$ozsh"):" \
            install "Install oh-my-zsh" \
            update  "Update oh-my-zsh" \
            theme   "Choose a theme (from installed set)" \
            p10k    "Install Powerlevel10k theme" \
            plugins "Manage plugins (built-in + popular GitHub, space-select)" \
            current "Show current configuration" \
            uninstall "Uninstall oh-my-zsh" \
            back    "Back") || return 0
        case "$c" in
            install)
                run_cmd "Installing oh-my-zsh for $u" su - "$u" -c \
                    'tmp_script=$(mktemp "${TMPDIR:-/tmp}/systui-omz.XXXXXX") || exit 1; trap '"'"'rm -f "$tmp_script"'"'"' EXIT; curl -fL --proto "=https" --tlsv1.2 https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o "$tmp_script" && chmod 700 "$tmp_script" && RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh "$tmp_script" --unattended' ;;
            uninstall)
                [ -d "$ozsh" ] || { tui_msg "Missing" "oh-my-zsh is not installed for $u."; continue; }
                tui_yesno "Uninstall oh-my-zsh" \
"Remove ~/.oh-my-zsh for $u (including custom plugins/themes)?

If the installer's backup (~/.zshrc.pre-oh-my-zsh) exists it will
be restored as .zshrc." || continue
                rm -rf "$ozsh"
                if [ -f "$home_dir/.zshrc.pre-oh-my-zsh" ]; then
                    mv "$home_dir/.zshrc.pre-oh-my-zsh" "$rc"
                    chown "$u" "$rc" 2>/dev/null
                    tui_msg "Removed" "oh-my-zsh deleted; pre-install .zshrc restored."
                else
                    sed -i -E 's|^(export ZSH=)|#\1|; s|^(ZSH_THEME=)|#\1|; s|^(source \$ZSH/oh-my-zsh.sh)|#\1|' "$rc" 2>/dev/null
                    tui_msg "Removed" "oh-my-zsh deleted; its .zshrc lines were commented out\n(no installer backup was found)."
                fi ;;
            update)
                [ -d "$ozsh" ] || { tui_msg "Missing" "oh-my-zsh is not installed for $u."; continue; }
                run_cmd "Updating oh-my-zsh" su - "$u" -c "cd ~/.oh-my-zsh && git pull --ff-only" ;;
            theme)
                [ -d "$ozsh/themes" ] || { tui_msg "Missing" "oh-my-zsh is not installed for $u."; continue; }
                local args=() t cur
                cur=$(grep -E '^ZSH_THEME=' "$rc" 2>/dev/null | sed 's/ZSH_THEME=//; s/"//g')
                for t in "$ozsh"/themes/*.zsh-theme "$ozsh"/custom/themes/*/; do
                    [ -e "$t" ] || continue
                    t=$(basename "$t" .zsh-theme); t=${t%/}
                    [ "$t" = "$cur" ] && args+=("$t" "(current)" on) || args+=("$t" "" off)
                done
                t=$(tui_radio "oh-my-zsh theme — $u" "SPACE to select (current pre-selected):" "${args[@]}") || continue
                [ -z "$t" ] && continue
                [ "$t" = powerlevel10k ] && t="powerlevel10k/powerlevel10k"
                sed -i -E "s|^ZSH_THEME=.*|ZSH_THEME=\"$t\"|" "$rc"
                tui_msg "Done" "ZSH_THEME=\"$t\" set in $rc" ;;
            p10k)
                [ -d "$ozsh" ] || { tui_msg "Missing" "Install oh-my-zsh first."; continue; }
                # Expand the destination here: inside `su - "$u" -c` the login
                # shell never reads .zshrc, so $ZSH_CUSTOM is unset there — the
                # old \${ZSH_CUSTOM:-...} literally created a directory named
                # "${ZSH_CUSTOM:-~/.oh-my-zsh/custom}" and the theme never
                # loaded. $home_dir/.oh-my-zsh/custom is OMZ's default.
                run_cmd "Installing Powerlevel10k" su - "$u" -c \
                    "git clone --depth 1 https://github.com/romkatv/powerlevel10k ${ZSH_CUSTOM:-$home_dir/.oh-my-zsh/custom}/themes/powerlevel10k 2>/dev/null || true"
                sed -i -E 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' "$rc"
                tui_msg "Done" "Powerlevel10k installed & set.\nFirst zsh start runs its configuration wizard." ;;
            plugins)
                [ -f "$rc" ] || { tui_msg "Missing" "No .zshrc for $u (install oh-my-zsh first)."; continue; }
                local current
                current=" $(omb_current "$rc" plugins) "
                local args=() tag desc repo state
                while IFS='|' read -r tag desc; do
                    [ -z "$tag" ] && continue
                    case "$current" in *" $tag "*) state=on ;; *) state=off ;; esac
                    args+=("$tag" "$desc" "$state")
                done <<<"$OMZ_BUILTIN_PLUGINS"
                while IFS='|' read -r tag repo desc; do
                    [ -z "$tag" ] && continue
                    case "$current" in *" $tag "*) state=on ;; *) state=off ;; esac
                    args+=("$tag" "* $desc (github: $repo)" "$state")
                done <<<"$OMZ_EXTERNAL_PLUGINS"
                local sel
                sel=$(tui_check "oh-my-zsh plugins — $u" \
                    "Enabled plugins pre-checked. SPACE toggles, ENTER applies.\n* = external, auto-cloned from GitHub when enabled:" "${args[@]}") || continue
                sel=${sel//\"/}
                # Clone any selected external plugin that isn't present yet.
                # oh-my-zsh sources custom/plugins/<tag>/<tag>.plugin.zsh, but
                # a few repos ship a differently-named loader (e.g. zsh-auto-
                # notify -> auto-notify.plugin.zsh, zsh-autoswitch-virtualenv
                # -> autoswitch_virtualenv.plugin.zsh); shim those so the
                # plugin actually loads instead of silently doing nothing.
                local t line dest srcf kept final hl rest
                for t in $sel; do
                    line=$(grep -m1 "^$t|" <<<"$OMZ_EXTERNAL_PLUGINS") || continue
                    repo=$(cut -d'|' -f2 <<<"$line")
                    [ -d "$ozsh/custom/plugins/$t" ] || \
                        su - "$u" -c "git clone --depth 1 https://github.com/$repo ~/.oh-my-zsh/custom/plugins/$t" \
                            >>"$LOGFILE" 2>&1 || warn "Clone failed: $repo"
                    dest="$ozsh/custom/plugins/$t"
                    srcf=$(zsh_plugin_file "$dest" 2>/dev/null || true)
                    if [ -n "$srcf" ] && [ "$srcf" != "$t.plugin.zsh" ]; then
                        printf 'source "${0:A:h}/%s"\n' "$srcf" > "$dest/$t.plugin.zsh"
                        chown "$u" "$dest/$t.plugin.zsh" 2>/dev/null || true
                    elif [ -z "$srcf" ]; then
                        warn "No loadable .zsh file found for $t — check its README."
                    fi
                done
                # Keep currently-enabled plugins that are not in the catalogues
                # (custom/user plugins) — rewriting only the selection would
                # silently drop them from plugins=().
                kept=""
                for t in $current; do
                    { echo "$OMZ_BUILTIN_PLUGINS"; echo "$OMZ_EXTERNAL_PLUGINS"; } | grep -q "^$t|" || kept="$kept $t"
                done
                final="$kept $sel"
                # Syntax highlighting must be sourced LAST (after fzf-tab and
                # autosuggestions) to highlight correctly.
                hl=""; rest=""
                for t in $final; do
                    case "$t" in
                        zsh-syntax-highlighting|fast-syntax-highlighting) hl="$hl $t" ;;
                        *) rest="$rest $t" ;;
                    esac
                done
                final="$rest$hl"
                omb_set_array "$rc" plugins $final \
                    && tui_msg "Done" "plugins=($final)\nwritten to $rc"
                show_warnings ;;
            current)
                {
                    echo "User    : $u"
                    echo "Install : $ozsh $( [ -d "$ozsh" ] && echo '(present)' || echo '(MISSING)')"
                    echo
                    grep -E '^(ZSH_THEME|plugins)=' "$rc" 2>/dev/null || echo "(no OMZ config in .zshrc)"
                    echo
                    echo "Custom plugins cloned:"
                    ls -1 "$ozsh/custom/plugins" 2>/dev/null | sed 's/^/  /'
                } > ${SYSTUI_TMP}/sh2
                tui_text "Current OMZ config — $u" ${SYSTUI_TMP}/sh2 ;;
            back) return 0 ;;
        esac
    done
}

# ---- zinit manager ----
menu_zinit() { # <user> <home>
    local u="$1" home_dir="$2"
    local rc="$home_dir/.zshrc"
    local zdir="$home_dir/.local/share/zinit"
    while true; do
        local c
        c=$(tui_menu "zinit — $u" "Lightweight zsh plugin manager $(stp "$zdir"):" \
            install "Install zinit" \
            plugins "Manage popular plugins (space-select)" \
            current "Show zinit lines in .zshrc" \
            uninstall "Uninstall zinit (and its plugin block)" \
            back    "Back") || return 0
        case "$c" in
            install)
                run_cmd "Installing zinit for $u" su - "$u" -c \
                    "mkdir -p ~/.local/share/zinit && { [ -d ~/.local/share/zinit/zinit.git ] || git clone --depth 1 https://github.com/zdharma-continuum/zinit.git ~/.local/share/zinit/zinit.git; }"
                grep -q "zinit.zsh" "$rc" 2>/dev/null || \
                    echo 'source "$HOME/.local/share/zinit/zinit.git/zinit.zsh"' >> "$rc"
                chown "$u" "$rc" 2>/dev/null ;;
            plugins)
                [ -d "$zdir" ] || { tui_msg "Missing" "Install zinit first."; continue; }
                local args=() repo desc state
                while IFS='|' read -r repo desc; do
                    [ -z "$repo" ] && continue
                    grep -q "zinit light $repo" "$rc" 2>/dev/null && state=on || state=off
                    args+=("$repo" "$desc" "$state")
                done <<<"$ZINIT_POPULAR"
                local sel
                sel=$(tui_check "zinit plugins — $u" \
                    "Currently loaded pre-checked. SPACE toggles, ENTER rewrites the\nsystui zinit block in .zshrc:" "${args[@]}") || continue
                sel=${sel//\"/}
                {
                    local r
                    for r in $sel; do echo "zinit light $r"; done
                } | write_marked_block "$rc" "zinit plugins"
                chown "$u" "$rc" 2>/dev/null
                tui_msg "Done" "zinit block updated in $rc\nPlugins download on next zsh start." ;;
            current)
                grep -n "zinit" "$rc" 2>/dev/null > ${SYSTUI_TMP}/sh2 || echo "(none)" > ${SYSTUI_TMP}/sh2
                tui_text "zinit lines — $u" ${SYSTUI_TMP}/sh2 ;;
            uninstall)
                [ -d "$zdir" ] || { tui_msg "Missing" "zinit is not installed for $u."; continue; }
                tui_yesno "Uninstall zinit" \
"Remove ~/.local/share/zinit (manager + all downloaded plugins)
and strip the zinit lines from .zshrc?" || continue
                rm -rf "$zdir"
                sed -i '/^# >>> systui zinit plugins >>>/,/^# <<< systui zinit plugins <<</d' "$rc" 2>/dev/null
                sed -i '\|source "\$HOME/.local/share/zinit/zinit.git/zinit.zsh"|d' "$rc" 2>/dev/null
                tui_msg "Removed" "zinit and its .zshrc lines removed for $u." ;;
            back) return 0 ;;
        esac
    done
}

# ---- bash-it manager ----
menu_bashit() { # <user> <home>
    local u="$1" home_dir="$2"
    local bi="$home_dir/.bash_it"
    while true; do
        local c
        c=$(tui_menu "Bash-it — $u" "Community bash framework $(stp "$bi"):" \
            install "Install Bash-it" \
            plugins "Enable/disable plugins (space-select from installed set)" \
            comps   "Enable/disable completions" \
            aliases "Enable/disable alias sets" \
            uninstall "Uninstall Bash-it" \
            back    "Back") || return 0
        case "$c" in
            install)
                run_cmd "Installing Bash-it for $u" su - "$u" -c \
                    "{ [ -d ~/.bash_it ] || git clone --depth 1 https://github.com/Bash-it/bash-it.git ~/.bash_it; } && ~/.bash_it/install.sh --silent" ;;
            plugins|comps|aliases)
                [ -d "$bi" ] || { tui_msg "Missing" "Install Bash-it first."; continue; }
                local kind dir suffix
                case "$c" in
                    plugins) kind="plugin";     dir="$bi/plugins";     suffix=".plugin.bash" ;;
                    comps)   kind="completion"; dir="$bi/completion";  suffix=".completion.bash" ;;
                    aliases) kind="alias";      dir="$bi/aliases";     suffix=".aliases.bash" ;;
                esac
                local args=() f name state
                for f in "$dir/available"/*"$suffix"; do
                    [ -e "$f" ] || continue
                    name=$(basename "$f" "$suffix")
                    if ls "$bi/enabled/"*"---$name$suffix" >/dev/null 2>&1 || \
                       ls "$bi/$(basename "$dir")/enabled/"*"---$name$suffix" >/dev/null 2>&1; then
                        state=on
                    else
                        state=off
                    fi
                    args+=("$name" "" "$state")
                done
                [ ${#args[@]} -eq 0 ] && { tui_msg "Empty" "Nothing found in $dir/available."; continue; }
                local sel
                sel=$(tui_check "Bash-it ${kind}s — $u" \
                    "Enabled items pre-checked. SPACE toggles, ENTER applies\n(via the bash-it CLI):" "${args[@]}") || continue
                sel=" ${sel//\"/} "
                local i=0 name state
                while [ $i -lt ${#args[@]} ]; do
                    name="${args[$i]}"; state="${args[$((i+2))]}"
                    case "$sel" in
                        *" $name "*)
                            if [ "$state" = off ]; then
                                run_cmd "Bash-it: enable $kind $name" su - "$u" -c                                     "bash -lc 'source ~/.bash_it/bash_it.sh >/dev/null 2>&1; bash-it enable $kind \"$name\"'"
                            fi
                            ;;
                        *)
                            if [ "$state" = on ]; then
                                run_cmd "Bash-it: disable $kind $name" su - "$u" -c                                     "bash -lc 'source ~/.bash_it/bash_it.sh >/dev/null 2>&1; bash-it disable $kind \"$name\"'"
                            fi
                            ;;
                    esac
                    i=$((i+3))
                done
                tui_msg "Done" "Bash-it ${kind}s updated for $u." ;;
            uninstall)
                [ -d "$bi" ] || { tui_msg "Missing" "Bash-it is not installed for $u."; continue; }
                tui_yesno "Uninstall Bash-it" \
"Run Bash-it's own uninstaller for $u?
(It restores the .bashrc backup made at install time,
then the ~/.bash_it directory is deleted.)" || continue
                su - "$u" -c "bash ~/.bash_it/uninstall.sh" >>"$LOGFILE" 2>&1 \
                    || warn "Bash-it uninstall.sh reported an error — check .bashrc manually."
                rm -rf "$bi"
                show_warnings
                tui_msg "Removed" "Bash-it uninstalled for $u." ;;
            back) return 0 ;;
        esac
    done
}

# ---- fisher manager ----
menu_fisher() { # <user> <home>
    local u="$1" home_dir="$2"
    while true; do
        local c
        c=$(tui_menu "fisher — $u" "Fish plugin manager:" \
            install "Install fisher (and fish if needed)" \
            plugins "Manage popular plugins (space-select)" \
            list    "List installed plugins" \
            update  "Update all plugins" \
            uninstall "Uninstall fisher (removes all its plugins)" \
            back    "Back") || return 0
        case "$c" in
            install)
                command -v fish >/dev/null || pm_install fish
                run_cmd "Installing fisher for $u" su - "$u" -c \
                    'tmp_fisher=$(mktemp "${TMPDIR:-/tmp}/systui-fisher.XXXXXX") || exit 1; trap '"'"'rm -f "$tmp_fisher"'"'"' EXIT; curl -fL --proto "=https" --tlsv1.2 https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish -o "$tmp_fisher" && fish -c "source $tmp_fisher; fisher install jorgebucaran/fisher"' ;;
            plugins)
                su - "$u" -c "fish -c 'type -q fisher'" 2>/dev/null || { tui_msg "Missing" "Install fisher first."; continue; }
                local installed args=() repo desc state
                installed=" $(su - "$u" -c "fish -c 'fisher list'" 2>/dev/null | tr '\n' ' ') "
                while IFS='|' read -r repo desc; do
                    [ -z "$repo" ] && continue
                    case "$installed" in *" $repo"*) state=on ;; *) state=off ;; esac
                    args+=("$repo" "$desc" "$state")
                done <<<"$FISHER_POPULAR"
                local sel
                sel=$(tui_check "fisher plugins — $u" \
                    "Installed plugins pre-checked. SPACE toggles, ENTER applies\n(installs new, removes unchecked):" "${args[@]}") || continue
                sel=" ${sel//\"/} "
                local i=0 state
                while [ $i -lt ${#args[@]} ]; do
                    repo="${args[$i]}"; state="${args[$((i+2))]}"
                    case "$sel" in
                        *" $repo "*)
                            if [ "$state" = off ]; then
                                run_cmd "fisher install $repo" su - "$u" -c "fish -c 'fisher install $repo'"
                            fi
                            ;;
                        *)
                            if [ "$state" = on ]; then
                                run_cmd "fisher remove $repo" su - "$u" -c "fish -c 'fisher remove $repo'"
                            fi
                            ;;
                    esac
                    i=$((i+3))
                done ;;
            list)
                su - "$u" -c "fish -c 'fisher list'" > ${SYSTUI_TMP}/sh2 2>&1 || echo "(fisher not installed)" > ${SYSTUI_TMP}/sh2
                tui_text "fisher plugins — $u" ${SYSTUI_TMP}/sh2 ;;
            update)
                run_cmd "fisher update" su - "$u" -c "fish -c 'fisher update'" ;;
            uninstall)
                su - "$u" -c "fish -c 'type -q fisher'" 2>/dev/null || { tui_msg "Missing" "fisher is not installed for $u."; continue; }
                tui_yesno "Uninstall fisher" \
"Remove ALL fisher-managed plugins AND fisher itself for $u?
(fisher cleans up the functions/completions/conf.d files it copied.)" || continue
                run_cmd "Removing all fisher plugins + fisher" su - "$u" -c \
                    "fish -c 'fisher list | fisher remove' " ;;
            back) return 0 ;;
        esac
    done
}

# ---- Nushell manager ----

# Core plugins (officially maintained, distributed with Nushell, install via cargo)
NU_PLUGINS_CORE="nu_plugin_polars|Polars DataFrames — fast columnar operations via the Polars library
nu_plugin_formats|Formats — EML, ICS, INI, plist and VCF file format support
nu_plugin_gstat|gstat — structured Git repository status as Nu data
nu_plugin_query|Query — SQL, XML, JSON, HTML selector and webpage metadata queries
nu_plugin_inc|inc — increment a value or semantic version number"

# Popular third-party plugins (curated from active GitHub repos / awesome-nu,
# biased toward current non-archived projects that install cleanly via cargo)
NU_PLUGINS_POPULAR="nu_plugin_highlight|Syntax highlighting for code snippets (cptpiepmatz)
nu_plugin_dns|DNS queries returned as structured Nu data (dead10ck)
nu_plugin_plot|Plot numeric lists and tables inline from Nu pipelines (Euphrasiologist)
nu_plugin_emoji|Emoji search and insertion (fdncred)
nu_plugin_file|Identify file types using libmagic — like the file(1) command (fdncred)
nu_plugin_json_path|JSONPath queries on JSON data (fdncred)
nu_plugin_parquet|Read/write Apache Parquet columnar files (fdncred)
nu_plugin_regex|Regex search with named capture groups as records (fdncred)
nu_plugin_semver|Parse and compare SemVer version strings (abusch)
nu_plugin_skim|skim (sk) fuzzy-finder integrated with Nu structured data (idanarye)
nu_plugin_compress|Compress/decompress via zstd, gzip, bzip2 and xz (yybit)
nu_plugin_dbus|Query and call D-Bus services from Nushell (devyn)
nu_plugin_bio|Bioinformatics helpers and sequence tooling (Euphrasiologist)
nu_plugin_clipboard|Read/write the system clipboard (FMotalleb)
nu_plugin_desktop_notifications|Send desktop notifications from Nu scripts (FMotalleb)
nu_plugin_port_extension|List active connections and scan ports (FMotalleb)
nu_plugin_image|Display PNG images inline in the terminal (FMotalleb)
nu_plugin_hashes|63 cryptographic hash functions as Nu commands (ArmoredPony)
nu_plugin_hmac|HMAC message authentication codes (fnuttens)
nu_plugin_net|Enumerate network interfaces as structured data (fennewald)
nu_plugin_mongo|Query MongoDB databases (WindSoilder)
nu_plugin_prometheus|Query Prometheus metrics as Nu tables (drbrain)
nu_plugin_tree|Tree views for structured data and filesystems (fdncred)
nu_plugin_units|Unit conversion helpers for structured numeric data (JosephTLyons)
nu_plugin_periodic_table|Periodic table lookups and element metadata (JosephTLyons)
nu_plugin_x509|Parse and inspect X.509 / TLS certificates (yybit)
nu_plugin_bson|BSON (Binary JSON) format encode/decode (Kissaki)
nu_plugin_hcl|HashiCorp Configuration Language (HCL) parser (Yethal)
nu_plugin_handlebars|Render Handlebars templates from Nu values (idanarye)
nu_plugin_vec|Vector math operations on Nu lists (PhotonBursted)
nu_plugin_ulid|Generate and parse ULID identifiers (lizclipse)
nu_plugin_ws|Stream WebSocket output as Nu structured data (alex-kattathra-johnson)"

nu_quote() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

nu_cmd() {
    printf 'nu -c %s' "$(nu_quote "$1")"
}

nu_run_as() { # user command
    local u="$1" cmd="$2"
    su - "$u" -c "$(nu_cmd "$cmd")"
}

# Return the cargo bin directory for a given user
nu_plugin_cargo_bin() {
    local u="$1"
    su - "$u" -c 'printf "%s" "${CARGO_HOME:-$HOME/.cargo}/bin"' 2>/dev/null
}

nu_plugin_display_name() {
    local name="$1"
    name=${name#nu_plugin_}
    name=${name#nu-plugin-}
    printf '%s\n' "${name//_/-}"
}

# Install a checklist of nu plugins via cargo and auto-register them
nu_plugin_install_from_list() { # title list-string user home
    local title="$1" list="$2" u="$3" home_dir="$4"
    local args=() crate desc label
    while IFS='|' read -r crate desc; do
        [ -z "$crate" ] && continue
        label=$(nu_plugin_display_name "$crate")
        args+=("$label" "$desc" off)
    done <<< "$list"
    [ ${#args[@]} -eq 0 ] && { tui_msg "Empty" "No plugins in this list."; return; }
    local sel chosen target_crate
    sel=$(tui_check "$title — $u" \
        "SPACE selects plugins to install via Cargo, ENTER confirms.\nRequires the Rust toolchain (cargo):" \
        "${args[@]}") || return 0
    sel=${sel//\"/}
    [ -z "${sel// }" ] && return
    command -v cargo >/dev/null 2>&1 || {
        tui_yesno "Cargo missing" "Cargo (Rust toolchain) is not installed. Install it now?" || return
        pm_install cargo rustc
        command -v cargo >/dev/null 2>&1 || { tui_msg "Error" "Cargo could not be installed."; return; }
    }
    local cargo_bin; cargo_bin=$(nu_plugin_cargo_bin "$u")
    for chosen in $sel; do
        target_crate=
        while IFS='|' read -r crate desc; do
            [ -z "$crate" ] && continue
            [ "$(nu_plugin_display_name "$crate")" = "$chosen" ] || continue
            target_crate="$crate"
            break
        done <<< "$list"
        [ -n "$target_crate" ] || { warn "Unknown Nu plugin selection: $chosen"; continue; }
        run_cmd "cargo install $target_crate" su - "$u" -c "cargo install '$target_crate' --locked 2>&1 || cargo install '$target_crate'"
        local bin="$cargo_bin/$target_crate"
        if su - "$u" -c "[ -x '$bin' ]" 2>/dev/null; then
            run_cmd "plugin add $chosen" nu_run_as "$u" "plugin add $(nu_quote "$bin")"
        else
            warn "Binary $bin not found after install — run 'plugin add <path>' manually in Nu."
        fi
    done
    show_warnings
    tui_msg "Done" "Selected plugins installed and registered.\nRestart Nu (or run 'plugin use <name>') to load them."
}

# Re-register all currently known plugin executables (needed after a Nu update)
nu_plugin_update_all() { # user
    local u="$1"
    local installed
    installed=$(nu_run_as "$u" \
        'plugin list | get filename | each { |f| $f } | str join (char newline)' 2>/dev/null) || {
        tui_msg "No plugins" "No plugins are registered for $u, or Nu is not installed."; return;
    }
    [ -z "$installed" ] && { tui_msg "No plugins" "No plugins are registered for $u."; return; }
    local p
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        [ -f "$p" ] || { warn "Plugin binary not found, skipping: $p"; continue; }
        run_cmd "Re-register $p" nu_run_as "$u" "plugin add $(nu_quote "$p")"
    done <<< "$installed"
    show_warnings
    tui_msg "Done" "All registered plugins re-added for $u.\nRestart Nu to reload updated signatures."
}

menu_nushell_plugins() { # <user> <home>
    local u="$1" home_dir="$2"
    while true; do
        local c plugin registry
        c=$(tui_menu "Nushell plugins — $u" "Manage the Nu plugin registry:" \
            core    "Install core plugins  (polars, formats, gstat, query, inc)" \
            popular "Install popular third-party plugins  (curated from awesome-nu)" \
            list    "List registered plugins" \
            update  "Re-register all plugins  (run this after updating Nu)" \
            add     "Register a plugin executable by path" \
            remove  "Remove a plugin from the registry" \
            back    "Back") || return 0
        case "$c" in
            core)    nu_plugin_install_from_list "Core Nushell plugins" "$NU_PLUGINS_CORE" "$u" "$home_dir" ;;
            popular) nu_plugin_install_from_list "Popular Nu plugins" "$NU_PLUGINS_POPULAR" "$u" "$home_dir" ;;
            list)
                registry="$SYSTUI_TMP/nu-plugins.txt"
                nu_run_as "$u" 'plugin list' >"$registry" 2>&1 \
                    || echo "(no plugins registered or Nu not installed)" > "$registry"
                tui_text "Nushell plugins — $u" "$registry" ;;
            update) nu_plugin_update_all "$u" ;;
            add)
                plugin=$(tui_input "Add Nu plugin" \
                    "Path to a plugin executable (for example: ~/.cargo/bin/nu_plugin_polars):" \
                    "$home_dir/.cargo/bin/nu_plugin_") || continue
                [ -n "$plugin" ] || continue
                run_cmd "Nu plugin add $plugin" nu_run_as "$u" "plugin add $(nu_quote "$plugin")" ;;
            remove)
                plugin=$(tui_input "Remove Nu plugin" \
                    "Plugin name or executable path to remove:" \
                    "polars") || continue
                [ -n "$plugin" ] || continue
                run_cmd "Nu plugin rm $plugin" nu_run_as "$u" "plugin rm --force $(nu_quote "$plugin")" ;;
            back) return 0 ;;
        esac
    done
}

nu_github_install() {
    local arch arch_str libc api url ver tmp bin
    arch=$(uname -m)
    case "$arch" in
        x86_64)        arch_str="x86_64" ;;
        aarch64|arm64) arch_str="aarch64" ;;
        armv7*)        arch_str="armv7" ;;
        riscv64)       arch_str="riscv64" ;;
        *) tui_msg "Unsupported architecture" "No official Nushell binary for: $arch"; return 1 ;;
    esac
    libc="gnu"
    command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl && libc="musl"
    command -v curl >/dev/null 2>&1 || pm_install curl
    command -v tar  >/dev/null 2>&1 || pm_install tar
    api=$(curl -fsSL https://api.github.com/repos/nushell/nushell/releases/latest) || {
        tui_msg "Download failed" "Could not query the latest Nushell GitHub release."; return 1;
    }
    ver=$(printf '%s\n' "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
    url=$(printf '%s\n' "$api" | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
        | grep -E "/${arch_str}-unknown-linux-${libc}\.tar\.gz$" | head -n1)
    [ -n "$url" ] || url=$(printf '%s\n' "$api" | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
        | grep -E "/${arch_str}-unknown-linux-(gnu|musl)\.tar\.gz$" | head -n1)
    [ -n "$url" ] || { tui_msg "No compatible asset" "No ${arch_str} Linux tar.gz found for Nushell ${ver}."; return 1; }
    tmp=$(mktemp -d) || return 1
    run_cmd "Download Nushell $ver" curl -fsSL "$url" -o "$tmp/nu.tar.gz" && \
    run_cmd "Extract Nushell $ver"  tar -xzf "$tmp/nu.tar.gz" -C "$tmp"
    bin=$(find "$tmp" -name "nu" -type f | head -n1)
    [ -n "$bin" ] || { tui_msg "Extraction failed" "nu binary not found in downloaded archive."; rm -rf "$tmp"; return 1; }
    run_cmd "Install Nushell $ver to /usr/local/bin" install -m 0755 "$bin" /usr/local/bin/nu
    rm -rf "$tmp"
    tui_msg "Nushell installed" "nu $ver → /usr/local/bin/nu"
}

menu_nushell_install() {
    local method
    local choices=(pm "Package manager (${PM:-pm} install nushell)")
    command -v brew  >/dev/null 2>&1 && choices+=(brew  "Homebrew (brew install nushell)")
    command -v cargo >/dev/null 2>&1 && choices+=(cargo "Cargo (cargo install nu --locked)")
    choices+=(github "GitHub release binary (auto-detect arch + libc)")
    case "$PM" in
        apt) choices+=(gemfury-apt "Gemfury APT repo (Debian/Ubuntu dedicated channel)") ;;
        dnf|yum) choices+=(gemfury-rpm "Gemfury YUM/DNF repo (Fedora/Rocky dedicated channel)") ;;
        apk) choices+=(gemfury-apk "Gemfury Alpine repo") ;;
    esac
    choices+=(back "Back")
    method=$(tui_menu "Install Nushell" "Choose an installation method:" "${choices[@]}") || return 0
    case "$method" in
        pm)
            case "$PM" in emerge) pm_install app-shells/nushell ;; *) pm_install nushell ;; esac ;;
        brew)
            run_cmd "Install Nushell via Homebrew" brew install nushell ;;
        cargo)
            run_cmd "Install Nushell via Cargo" cargo install nu --locked ;;
        github)
            nu_github_install ;;
        gemfury-apt)
            command -v gpg >/dev/null 2>&1 || pm_install gnupg
            run_cmd "Add Nushell Gemfury GPG key" bash -c \
                'wget -qO- https://apt.fury.io/nushell/gpg.key | gpg --dearmor -o /etc/apt/keyrings/fury-nushell.gpg'
            run_cmd "Add Nushell Gemfury APT source" bash -c \
                'echo "deb [signed-by=/etc/apt/keyrings/fury-nushell.gpg] https://apt.fury.io/nushell/ /" > /etc/apt/sources.list.d/fury-nushell.list'
            run_cmd "Update APT + install Nushell" bash -c 'apt-get update -qq && apt-get install -y nushell' ;;
        gemfury-rpm)
            run_cmd "Add Nushell Gemfury YUM/DNF repo" bash -c \
'cat > /etc/yum.repos.d/fury-nushell.repo <<EOF
[gemfury-nushell]
name=Gemfury Nushell Repo
baseurl=https://yum.fury.io/nushell/
enabled=1
gpgcheck=0
gpgkey=https://yum.fury.io/nushell/gpg.key
EOF'
            run_cmd "Install Nushell via DNF" dnf install -y nushell ;;
        gemfury-apk)
            run_cmd "Add Nushell Gemfury Alpine repo" bash -c \
                'echo "https://alpine.fury.io/nushell/" >> /etc/apk/repositories && apk update'
            run_cmd "Install Nushell via APK" apk add --allow-untrusted nushell ;;
        back) return 0 ;;
    esac
}

menu_nushell() { # <user> <home>
    local u="$1" home_dir="$2"
    while true; do
        local c
        c=$(tui_menu "Nushell — $u" "Install, configure and manage Nushell:" \
            install "Install/reinstall Nushell (choose method)" \
            config "Edit config.nu / env.nu / login.nu" \
            plugins "Manage Nushell plugins" \
            remove "Uninstall Nushell" \
            back "Back") || return 0
        case "$c" in
            install) menu_nushell_install ;;
            config) menu_shell_config ;;
            plugins) menu_nushell_plugins "$u" "$home_dir" ;;
            remove) case "$PM" in emerge) pm_remove app-shells/nushell ;; *) pm_remove nushell ;; esac ;;
            back) return 0 ;;
        esac
    done
}

# ---- tmux manager (configuration + TPM plugin management) ----

# Current value of a `set -g <key> <value>` option in a tmux.conf.
tmux_opt_get() { # <conf> <key>
    local conf="$1" key="$2" v
    v=$(grep -E "^set(-option)? +-g +${key}( +|$)" "$conf" 2>/dev/null | tail -1 | awk '{print $NF}')
    v=${v#\"}; v=${v%\"}
    printf '%s' "$v"
}

menu_tpm() { # <user> <home>
    local u="$1" home_dir="$2"
    local tpm="$home_dir/.tmux/plugins/tpm" conf="$home_dir/.tmux.conf"
    while true; do
        local c
        c=$(tui_menu "tmux plugins (TPM) — $u" "Tmux Plugin Manager $(stp "$tpm"):" \
            install "Install tmux + TPM" \
            plugins "Manage popular plugins (space-select)" \
            custom "Add a custom plugin (git URL)" \
            update "Update all installed plugins" \
            current "Show plugin lines in .tmux.conf" \
            uninstall "Uninstall TPM and all tmux plugins" \
            back    "Back") || return 0
        case "$c" in
            install)
                command -v tmux >/dev/null || pm_install tmux
                run_cmd "Installing TPM for $u" su - "$u" -c \
                    "{ [ -d ~/.tmux/plugins/tpm ] || git clone --depth 1 https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm; }"
                grep -q "run '~/.tmux/plugins/tpm/tpm'" "$conf" 2>/dev/null || {
                    echo "run '~/.tmux/plugins/tpm/tpm'" >> "$conf"
                    chown "$u" "$conf" 2>/dev/null
                }
                tui_msg "TPM" "Installed. Inside tmux, press prefix + I (capital i)\nto fetch plugins after enabling them." ;;
            plugins)
                [ -d "$tpm" ] || { tui_msg "Missing" "Install TPM first."; continue; }
                local args=() repo desc state
                while IFS='|' read -r repo desc; do
                    [ -z "$repo" ] && continue
                    grep -q "@plugin '$repo'" "$conf" 2>/dev/null && state=on || state=off
                    args+=("$repo" "$desc" "$state")
                done <<<"$TPM_POPULAR"
                local sel
                sel=$(tui_check "TPM plugins — $u" \
                    "Enabled pre-checked. SPACE toggles, ENTER rewrites the\nsystui block in .tmux.conf:" "${args[@]}") || continue
                sel=${sel//\"/}
                {
                    echo "set -g @plugin 'tmux-plugins/tpm'"
                    local r
                    for r in $sel; do echo "set -g @plugin '$r'"; done
                } | write_marked_block "$conf" "tmux plugins"
                # keep the tpm run line last
                grep -q "run '~/.tmux/plugins/tpm/tpm'" "$conf" || echo "run '~/.tmux/plugins/tpm/tpm'" >> "$conf"
                chown "$u" "$conf" 2>/dev/null
                tui_msg "Done" "Block updated. Inside tmux: prefix + I to install,\nprefix + alt + u to remove unlisted plugins." ;;
            custom)
                [ -d "$tpm" ] || { tui_msg "Missing" "Install TPM first."; continue; }
                local url name existing
                url=$(tui_input "Custom tmux plugin" "Repository (owner/repo or full git URL):" "https://github.com/") || continue
                case "$url" in
                    ""|https://github.com/) continue ;;
                    */*) case "$url" in https://*|http://*) ;; *) url="https://github.com/$url" ;; esac ;;
                esac
                name=$(basename "$url" .git)
                [ -n "$name" ] || continue
                if grep -q "@plugin '$name'" "$conf" 2>/dev/null; then
                    tui_msg "Already added" "'$name' is already in the plugin block of $conf."
                    continue
                fi
                existing=$(sed -n '/^# >>> systui tmux plugins >>>/,/^# <<< systui tmux plugins <<</p' "$conf" 2>/dev/null | grep "@plugin " || true)
                {
                    [ -n "$existing" ] && printf '%s\n' "$existing"
                    echo "set -g @plugin '$name'"
                } | write_marked_block "$conf" "tmux plugins"
                chown "$u" "$conf" 2>/dev/null
                tui_msg "Plugin added" "'$name' added to the plugin block.\nInside tmux press prefix + I to install it." ;;
            update)
                [ -x "$tpm/bin/update_plugins" ] || { tui_msg "Missing" "TPM is not installed (or update_plugins is missing)."; continue; }
                run_cmd "Updating all tmux plugins" su - "$u" -c "~/.tmux/plugins/tpm/bin/update_plugins all" ;;
            current)
                grep -n "@plugin\|tpm" "$conf" 2>/dev/null > ${SYSTUI_TMP}/sh2 || echo "(none)" > ${SYSTUI_TMP}/sh2
                tui_text ".tmux.conf plugin lines — $u" ${SYSTUI_TMP}/sh2 ;;
            uninstall)
                [ -d "$home_dir/.tmux/plugins" ] || { tui_msg "Missing" "TPM is not installed for $u."; continue; }
                tui_yesno "Uninstall TPM" \
"Delete ~/.tmux/plugins (TPM + every downloaded plugin) and
strip the systui plugin block and tpm run line from .tmux.conf?" || continue
                rm -rf "$home_dir/.tmux/plugins"
                sed -i '/^# >>> systui tmux plugins >>>/,/^# <<< systui tmux plugins <<</d' "$conf" 2>/dev/null
                sed -i "\|run '~/.tmux/plugins/tpm/tpm'|d" "$conf" 2>/dev/null
                tui_msg "Removed" "TPM and plugins removed. Reload tmux config\n(prefix + : source-file ~/.tmux.conf) or restart tmux." ;;
            back) return 0 ;;
        esac
    done
}

# Status-bar theme presets, written to the systui "tmux theme" block.
menu_tmux_theme() { # <user> <home> <conf>
    local u="$1" home_dir="$2" conf="$3"
    local t tpm="$home_dir/.tmux/plugins/tpm"
    t=$(tui_radio "tmux status theme — $u" "Status-bar theme (themes that need TPM also add the @plugin line):" \
        plain "Default — no custom styling" on \
        dark "Dark — minimal high-contrast" off \
        light "Light — light background" off \
        catppuccin "Catppuccin mocha (TPM plugin; needs prefix + I)" off \
        dracula "Dracula (TPM plugin; needs prefix + I)" off) || return 0
    case "$t" in
        plain)
            write_marked_block "$conf" "tmux theme" </dev/null
            tui_msg "Theme" "Custom styling removed from $conf." ;;
        dark)
            write_marked_block "$conf" "tmux theme" <<'EOF'
set -g status-style 'bg=colour234,fg=colour245'
set -g status-left '#[fg=colour232,bg=colour39] #S #[default]'
set -g status-right '#[fg=colour232,bg=colour39] %H:%M %d-%b #[default]'
set -g window-status-current-style 'fg=colour39,bold'
set -g pane-border-style 'fg=colour236'
set -g pane-active-border-style 'fg=colour39'
EOF
            tui_msg "Theme" "Dark theme written to $conf." ;;
        light)
            write_marked_block "$conf" "tmux theme" <<'EOF'
set -g status-style 'bg=colour252,fg=colour234'
set -g status-left '#[fg=colour255,bg=colour31] #S #[default]'
set -g status-right '#[fg=colour255,bg=colour31] %H:%M %d-%b #[default]'
set -g window-status-current-style 'fg=colour31,bold'
set -g pane-border-style 'fg=colour250'
set -g pane-active-border-style 'fg=colour31'
EOF
            tui_msg "Theme" "Light theme written to $conf." ;;
        catppuccin)
            [ -d "$tpm" ] || tui_msg "Note" "TPM is not installed — install it in the plugin menu\nand press prefix + I to fetch the theme."
            write_marked_block "$conf" "tmux theme" <<'EOF'
set -g @plugin 'catppuccin/tmux'
set -g @catppuccin_flavour 'mocha'
set -g @catppuccin_status_background 'default'
EOF
            tui_msg "Theme" "Catppuccin set. Inside tmux press prefix + I to install." ;;
        dracula)
            [ -d "$tpm" ] || tui_msg "Note" "TPM is not installed — install it in the plugin menu\nand press prefix + I to fetch the theme."
            write_marked_block "$conf" "tmux theme" <<'EOF'
set -g @plugin 'dracula/tmux'
set -g @dracula-show-powerline true
set -g @dracula-show-left-icon session
EOF
            tui_msg "Theme" "Dracula set. Inside tmux press prefix + I to install." ;;
    esac
    chown "$u" "$conf" 2>/dev/null
}

# Toggle common tmux options; checked = set to a sane value, unchecked = removed
# from the managed block (user's own lines are never touched).
menu_tmux_options() { # <user> <home> <conf>
    local u="$1" home_dir="$2" conf="$3"
    local o
    o=$(tui_check "tmux options — $u" "Current values pre-checked. SPACE toggles, ENTER applies\n(unchecking removes the option from the systui block):" \
        mouse "Mouse support (set -g mouse on)" "$([ "$(tmux_opt_get "$conf" mouse)" = on ] && echo on || echo off)" \
        vi "Vi keys in copy-mode & panes (mode-keys vi)" "$([ "$(tmux_opt_get "$conf" mode-keys)" = vi ] && echo on || echo off)" \
        base1 "Number windows & panes from 1" "$([ "$(tmux_opt_get "$conf" base-index)" = 1 ] && echo on || echo off)" \
        renum "Renumber windows after one closes" "$([ "$(tmux_opt_get "$conf" renumber-windows)" = on ] && echo on || echo off)" \
        hist "Scrollback history 10000 lines" "$([ "$(tmux_opt_get "$conf" history-limit)" = 10000 ] && echo on || echo off)" \
        esc "Escape time 10 ms (snappier alt-key)" "$([ "$(tmux_opt_get "$conf" escape-time)" = 10 ] && echo on || echo off)" \
        status "Status bar" "$([ "$(tmux_opt_get "$conf" status)" != off ] && echo on || echo off)" \
        term "tmux-256color default terminal" "$([ "$(tmux_opt_get "$conf" default-terminal)" = tmux-256color ] && echo on || echo off)" \
        clip "Clipboard integration (set-clipboard on)" "$([ "$(tmux_opt_get "$conf" set-clipboard)" = on ] && echo on || echo off)" \
        repeat "Repeat prefix key 500 ms" "$([ "$(tmux_opt_get "$conf" repeat-time)" = 500 ] && echo on || echo off)" \
        interval "Status refresh every 1 s" "$([ "$(tmux_opt_get "$conf" status-interval)" = 1 ] && echo on || echo off)") || return 0
    o=" ${o//\"/} "
    {
        case "$o" in *" mouse "*)    echo 'set -g mouse on' ;; esac
        case "$o" in *" vi "*)       echo 'set -g mode-keys vi' ;; esac
        case "$o" in *" base1 "*)    echo 'set -g base-index 1'; echo 'set -g pane-base-index 1' ;; esac
        case "$o" in *" renum "*)    echo 'set -g renumber-windows on' ;; esac
        case "$o" in *" hist "*)     echo 'set -g history-limit 10000' ;; esac
        case "$o" in *" esc "*)      echo 'set -g escape-time 10' ;; esac
        case "$o" in *" status "*)   echo 'set -g status on' ;; esac
        case "$o" in *" term "*)     echo 'set -g default-terminal "tmux-256color"' ;; esac
        case "$o" in *" clip "*)     echo 'set -g set-clipboard on' ;; esac
        case "$o" in *" repeat "*)   echo 'set -g repeat-time 500' ;; esac
        case "$o" in *" interval "*) echo 'set -g status-interval 1' ;; esac
    } | write_marked_block "$conf" "tmux options"
    chown "$u" "$conf" 2>/dev/null
    tui_msg "Done" "tmux options block updated in $conf.\nApply with: tmux source-file ~/.tmux.conf"
}

# Change the prefix key (default C-b).
menu_tmux_prefix() { # <user> <home> <conf>
    local u="$1" home_dir="$2" conf="$3"
    local cur p v
    cur=$(tmux_opt_get "$conf" prefix); [ -n "$cur" ] || cur=C-b
    p=$(tui_radio "tmux prefix — $u" "Current prefix: $cur\nSPACE selects, ENTER applies:" \
        C-b "Ctrl-b (default)" "$([ "$cur" = C-b ] && echo on || echo off)" \
        C-a "Ctrl-a (screen style)" "$([ "$cur" = C-a ] && echo on || echo off)" \
        C-Space "Ctrl-Space" "$([ "$cur" = C-Space ] && echo on || echo off)" \
        custom "Custom (type your own, e.g. F12 or M-a)" off) || return 0
    [ -z "$p" ] && return 0
    if [ "$p" = custom ]; then
        v=$(tui_input "Prefix" "tmux prefix key (e.g. C-x, F12, M-a):" "$cur") || return 0
        [ -n "$v" ] && p="$v" || return 0
    fi
    write_marked_block "$conf" "tmux prefix" <<EOF
unbind C-b
unbind C-a
unbind C-Space
set -g prefix $p
bind $p send-prefix
EOF
    chown "$u" "$conf" 2>/dev/null
    tui_msg "Prefix" "Prefix set to '$p'.\nApply with: tmux source-file ~/.tmux.conf"
}

# Top-level tmux menu: configuration + plugin management.
menu_tmux() { # <user> <home>
    local u="$1" home_dir="$2"
    local conf="$home_dir/.tmux.conf" tpm="$home_dir/.tmux/plugins/tpm"
    while true; do
        local c
        c=$(tui_menu "tmux — $u" "Terminal multiplexer $(st tmux) — configuration & plugins:" \
            install "Install tmux" \
            plugins "TPM plugin manager (install, popular, custom, update)" \
            theme "Status-bar theme" \
            config "Configure options (mouse, prefix, vi keys...)" \
            prefix "Change prefix key" \
            view "Show current .tmux.conf" \
            backup "Create timestamped backup" \
            reload "Reload config in running tmux" \
            remove "Remove tmux package" \
            back "Back") || return 0
        case "$c" in
            install)
                if command -v tmux >/dev/null 2>&1; then
                    tui_msg "tmux" "tmux is already installed: $(command -v tmux)"
                else
                    pm_install tmux
                fi ;;
            plugins) menu_tpm "$u" "$home_dir" ;;
            theme)   menu_tmux_theme "$u" "$home_dir" "$conf" ;;
            config)  menu_tmux_options "$u" "$home_dir" "$conf" ;;
            prefix)  menu_tmux_prefix "$u" "$home_dir" "$conf" ;;
            view)    [ -f "$conf" ] && tui_text "$conf" "$conf" || tui_msg "tmux" "$conf does not exist yet." ;;
            backup)
                [ -f "$conf" ] || { tui_msg "tmux" "Nothing to back up — $conf does not exist."; continue; }
                local bak="$conf.systui-$(date +%Y%m%d-%H%M%S).bak"
                cp -p "$conf" "$bak" && chown "$u" "$bak" 2>/dev/null
                tui_msg "Backup" "Saved to:\n$bak" ;;
            reload)
                if [ -n "${TMUX:-}" ] || [ -S "${TMPDIR:-/tmp}/tmux-$(id -u)/default" ]; then
                    run_cmd "Reloading tmux config" tmux source-file "$conf"
                else
                    tui_msg "tmux" "No running tmux server found.\nThe next tmux start reads $conf automatically."
                fi ;;
            remove)
                tui_yesno "Remove tmux" "Uninstall the tmux package for all users?" || continue
                pm_remove tmux ;;
            back|"") return 0 ;;
        esac
    done
}

# ---- ble.sh (bash line editor) ----
menu_blesh() { # <user> <home>
    local u="$1" home_dir="$2"
    local bdir="$home_dir/.local/share/blesh"
    while true; do
        local c
        c=$(tui_menu "ble.sh — $u" "Bash autosuggestions & syntax highlighting $(stp "$bdir"):" \
            install "Install ble.sh" \
            uninstall "Uninstall ble.sh" \
            back    "Back") || return 0
        case "$c" in
            install) install_blesh "$u" ;;
            uninstall)
                [ -d "$bdir" ] || { tui_msg "Missing" "ble.sh is not installed for $u."; continue; }
                tui_yesno "Uninstall ble.sh" "Delete ~/.local/share/blesh and remove\nits source line from .bashrc?" || continue
                rm -rf "$bdir"
                sed -i '\|blesh/ble.sh|d' "$home_dir/.bashrc" 2>/dev/null
                tui_msg "Removed" "ble.sh removed for $u." ;;
            back) return 0 ;;
        esac
    done
}

install_blesh() { # <user>
    local u="$1"
    run_cmd "Installing ble.sh for $u" su - "$u" -c \
        "mkdir -p ~/.local/share && curl -fsSL https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz -o ${SYSTUI_TMP}/ble.tar.xz && \
         tar -xJf ${SYSTUI_TMP}/ble.tar.xz -C ~/.local/share/ && rm -rf ~/.local/share/blesh && mv ~/.local/share/ble-nightly ~/.local/share/blesh && rm -f ${SYSTUI_TMP}/ble.tar.xz"
    local home_dir; home_dir=$(user_home "$u")
    grep -q 'blesh/ble.sh' "$home_dir/.bashrc" 2>/dev/null || {
        echo '[[ $- == *i* ]] && source ~/.local/share/blesh/ble.sh' >> "$home_dir/.bashrc"
        chown "$u" "$home_dir/.bashrc" 2>/dev/null
    }
    tui_msg "ble.sh" "Installed — bash now gets fish-style autosuggestions\nand syntax highlighting in new interactive shells."
}

# The shell -> plugin managers -> plugins hierarchy entry point.
menu_shell_hierarchy() {
    local u home_dir cur_shell sh_ m
    u=$(tui_input "User" "Manage shells for which user?" "${SUDO_USER:-root}") || return 0
    home_dir=$(user_home "$u"); [ -n "$home_dir" ] || { tui_msg "Error" "User not found."; return 0; }
    cur_shell=$(basename "$(getent passwd "$u" | cut -d: -f7)")
    while true; do
        sh_=$(tui_radio "Shell Managers — $u" "SPACE selects a shell:" bash "Bash $(st bash)" "$([ "$cur_shell" = bash ] && echo on || echo off)" zsh "Zsh $(st zsh)" "$([ "$cur_shell" = zsh ] && echo on || echo off)" fish "Fish $(st fish)" "$([ "$cur_shell" = fish ] && echo on || echo off)" nu "Nushell $(st nu)" "$([ "$cur_shell" = nu ] && echo on || echo off)" tmux "tmux" off more "More shells (dash, ksh, tcsh, elvish...)" off) || return 0
        case "$sh_" in
            bash) m=$(tui_menu "Bash Manager" "Install, remove or configure:" install "Install/reinstall Bash" uninstall "Uninstall Bash" omb "oh-my-bash" bashit "Bash-it" blesh "ble.sh" back "Back") || continue; case "$m" in install) pm_install bash;; uninstall) safe_remove_shell bash;; omb) menu_omb "$u" "$home_dir";; bashit) menu_bashit "$u" "$home_dir";; blesh) menu_blesh "$u" "$home_dir";; esac;;
            zsh) m=$(tui_menu "Zsh Manager" "Install, remove or configure:" install "Install/reinstall Zsh" uninstall "Uninstall Zsh" omz "oh-my-zsh" zinit "zinit" back "Back") || continue; case "$m" in install) menu_zsh_install;; uninstall) safe_remove_shell zsh;; omz) menu_omz "$u" "$home_dir";; zinit) menu_zinit "$u" "$home_dir";; esac;;
            fish) m=$(tui_menu "Fish Manager" "Install, remove or configure:" install "Install/reinstall Fish" uninstall "Uninstall Fish" fisher "Fisher" back "Back") || continue; case "$m" in install) menu_fish_install;; uninstall) safe_remove_shell fish;; fisher) menu_fisher "$u" "$home_dir";; esac;;
            nu) menu_nushell "$u" "$home_dir" ;;
            tmux) menu_tmux "$u" "$home_dir";;
            more) menu_more_shells "$u" "$home_dir" ;;
        esac
    done
}

# ---- Additional shells (dash, ksh, mksh, tcsh, elvish, xonsh, yash, pwsh) ----

# Map a shell name to its package name on the active package manager. Verified
# against repology (2026-08): plain names match on apt/apk/pacman/dnf/zypper/
# xbps; Debian renamed ksh to ksh93u+m; Gentoo keeps everything under
# app-shells/ (xonsh under dev-python/). Empty output = no native package.
shell_pkg() { # <shell>
    case "$1" in
        pwsh)
            case "$PM" in
                emerge) echo app-shells/pwsh-bin ;;
                *) echo powershell ;;
            esac
            return 0 ;;
    esac
    case "$PM" in
        emerge)
            case "$1" in
                dash) echo app-shells/dash ;; ksh) echo app-shells/ksh ;;
                mksh) echo app-shells/mksh ;; tcsh) echo app-shells/tcsh ;;
                elvish) echo app-shells/elvish ;; xonsh) echo dev-python/xonsh ;;
                yash) echo app-shells/yash ;;
                *) echo "$1" ;;
            esac ;;
        apt)
            case "$1" in ksh) echo ksh93u+m ;; *) echo "$1" ;; esac ;;
        *) echo "$1" ;;
    esac
}

# Uninstall a shell defensively: never remove the shell running systui, never
# remove a shell that is still some user's login shell, clean up /etc/shells.
safe_remove_shell() { # <shell>
    local sh="$1" bin users="" u
    bin=$(command -v "$sh" 2>/dev/null) || { tui_msg "Not installed" "$sh is not installed."; return 0; }
    [ "$sh" = "$(basename "${SHELL:-}")" ] && {
        tui_msg "Refusing" "$sh is the shell currently running systui (SHELL=$SHELL)."; return 0; }
    for u in $(awk -F: '{print $1}' /etc/passwd 2>/dev/null); do
        [ "$(basename "$(getent passwd "$u" 2>/dev/null | cut -d: -f7)")" = "$sh" ] && users="$users $u"
    done
    [ -n "$users" ] && {
        tui_msg "In use" "$sh is the login shell of:$users\nChange it first (Shells ▸ Set default shell)."; return 0; }
    tui_yesno "Uninstall $sh" "Remove $sh via ${PM:-pm}?" || return 0
    pm_remove "$(shell_pkg "$sh")"
    sed -i "\|^${bin}\$|d" /etc/shells 2>/dev/null || true
}

# Latest stable PowerShell from GitHub releases — the universal path, since
# Debian/Fedora/openSUSE do not ship powershell in their own repositories.
pwsh_github_install() {
    local arch arch_str api ver url tmp
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch_str="x64" ;;
        aarch64|arm64) arch_str="arm64" ;;
        *) tui_msg "Unsupported architecture" "No pre-built PowerShell binary for: $arch"; return 1 ;;
    esac
    command -v curl >/dev/null 2>&1 || pm_install curl
    command -v tar  >/dev/null 2>&1 || pm_install tar
    api=$(curl -fsSL https://api.github.com/repos/PowerShell/PowerShell/releases/latest) || {
        tui_msg "Download failed" "Could not query the latest PowerShell release."; return 1; }
    ver=$(printf '%s\n' "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
    url=$(printf '%s\n' "$api" | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
        | grep -E "/powershell-${ver#v}-linux-${arch_str}\.tar\.gz$" | head -n1)
    [ -n "$url" ] || { tui_msg "No asset" "No ${arch_str} tarball found for PowerShell ${ver}."; return 1; }
    tmp=$(mktemp -d) || return 1
    run_cmd "Download PowerShell $ver" curl -fsSL "$url" -o "$tmp/pwsh.tar.gz"
    run_cmd "Extract PowerShell $ver" tar -xzf "$tmp/pwsh.tar.gz" -C "$tmp"
    [ -x "$tmp/pwsh" ] || { tui_msg "Extraction failed" "pwsh binary not found in archive."; rm -rf "$tmp"; return 1; }
    run_cmd "Install PowerShell $ver to /opt/microsoft/powershell/7" \
        mkdir -p /opt/microsoft/powershell/7
    cp -a "$tmp"/. /opt/microsoft/powershell/7/ || { rm -rf "$tmp"; return 1; }
    chmod 0755 /opt/microsoft/powershell/7/pwsh
    ln -sf /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh
    rm -rf "$tmp"
    tui_msg "PowerShell installed" "pwsh $ver → /usr/local/bin/pwsh\n(Requires ICU + OpenSSL libraries at runtime.)"
}

# Parameterized install-method chooser for the additional shells.
menu_shell_install_any() { # <shell> <display>
    local sh="$1" disp="$2" method pkg choices=()
    pkg=$(shell_pkg "$sh")
    choices=(pm "Package manager (${PM:-pm} install ${pkg:-$sh})")
    case "$sh" in
        pwsh)  choices+=(github "GitHub release binary (latest stable, auto-detect arch)") ;;
        xonsh) choices+=(pip "pip (pip install xonsh — Python environment)") ;;
    esac
    command -v brew >/dev/null 2>&1 && choices+=(brew "Homebrew (brew install $sh)")
    choices+=(back "Back")
    method=$(tui_menu "Install $disp" "Choose an installation method:" "${choices[@]}") || return 0
    case "$method" in
        pm)
            if [ "$PM" = apt ] && [ "$sh" = ksh ]; then
                pm_install ksh93u+m || pm_install ksh || return 1
            elif [ -n "$pkg" ]; then
                pm_install "$pkg"
            else
                tui_msg "No package" "No native ${PM:-pm} package known for $disp."
            fi ;;
        pip)
            if command -v pipx >/dev/null 2>&1; then
                run_cmd "Install xonsh via pipx" pipx install xonsh
            else
                run_cmd "Install xonsh via pip" pip install --user --break-system-packages xonsh \
                    || run_cmd "Install xonsh via pip (classic)" pip install --user xonsh
            fi ;;
        github) pwsh_github_install ;;
        brew) run_cmd "Install $disp via Homebrew" brew install "$sh" ;;
        back) return 0 ;;
    esac
}

# Generic manager for a plain (non-framework) additional shell.
menu_plain_shell() { # <user> <home> <shell> <display> <blurb>
    local u="$1" home_dir="$2" sh="$3" disp="$4" blurb="$5"
    while true; do
        local c
        c=$(tui_menu "$disp — $u" "$blurb:" \
            install "Install/reinstall $disp (choose method)" \
            default "Set as the default login shell for $u" \
            uninstall "Uninstall $disp" \
            back    "Back") || return 0
        case "$c" in
            install) menu_shell_install_any "$sh" "$disp" ;;
            default) menu_set_default_shell ;;
            uninstall) safe_remove_shell "$sh" ;;
            back) return 0 ;;
        esac
    done
}

menu_more_shells() { # <user> <home>
    local u="$1" home_dir="$2"
    while true; do
        local c
        c=$(tui_menu "More shells — $u" "Additional shell options:" \
            dash   "dash — Debian Almquist shell (POSIX; /bin/sh on Debian)" \
            ksh    "ksh — KornShell 93u+m (AT&T)" \
            mksh   "mksh — MirBSD Korn shell (lightweight)" \
            tcsh   "tcsh — TENEX C shell (with csh)" \
            elvish "Elvish — modern expressive shell" \
            xonsh  "xonsh — Python-powered shell" \
            yash   "yash — yet another shell (POSIX, scriptable)" \
            pwsh   "PowerShell — Microsoft's shell (pwsh)" \
            back   "Back") || return 0
        case "$c" in
            dash)   menu_plain_shell "$u" "$home_dir" dash "dash" "Debian Almquist shell — fast, minimal POSIX sh" ;;
            ksh)    menu_plain_shell "$u" "$home_dir" ksh "KornShell" "KornShell 93u+m — ksh93 with modern fixes" ;;
            mksh)   menu_plain_shell "$u" "$home_dir" mksh "mksh" "MirBSD Korn shell — small, fast, portable" ;;
            tcsh)   menu_plain_shell "$u" "$home_dir" tcsh "tcsh" "TENEX C shell — interactive C-shell with completion" ;;
            elvish) menu_plain_shell "$u" "$home_dir" elvish "Elvish" "Expressive scripting + friendly interactive mode" ;;
            xonsh)  menu_plain_shell "$u" "$home_dir" xonsh "xonsh" "Python REPL + shell hybrid" ;;
            yash)   menu_plain_shell "$u" "$home_dir" yash "yash" "yet another shell — POSIX with advanced scripting" ;;
            pwsh)   menu_plain_shell "$u" "$home_dir" pwsh "PowerShell" "Cross-platform automation shell (.NET)" ;;
            back|"") return 0 ;;
        esac
    done
}

# ---- Vim plugin management (vim-plug + popular GitHub plugins) ---------------
VIM_POPULAR="tpope/vim-sensible|Sane defaults everyone agrees on
tpope/vim-fugitive|Git integration
tpope/vim-surround|Edit surrounding quotes/brackets
tpope/vim-commentary|Toggle comments with gc
preservim/nerdtree|File tree sidebar
junegunn/fzf.vim|Fuzzy file/buffer finding
vim-airline/vim-airline|Statusline
airblade/vim-gitgutter|Git diff signs in the gutter
morhetz/gruvbox|Gruvbox colorscheme
dense-analysis/ale|Async linting & fixing"

menu_vim_plugins() {
    local u home_dir
    u=$(tui_input "User" "Manage vim plugins for which user?" "${SUDO_USER:-root}") || return 0
    home_dir=$(user_home "$u")
    [ -z "$home_dir" ] && { tui_msg "Error" "User $u not found."; return; }
    local rc="$home_dir/.vimrc" plug="$home_dir/.vim/autoload/plug.vim"

    while true; do
        local c
        c=$(tui_menu "Vim plugins — $u" "vim-plug $(stp "$plug"):" \
            install "Install vim-plug plugin manager" \
            plugins "Manage popular plugins (space-select)" \
            sync    "Run :PlugInstall headlessly now" \
            current "Show the plugin block in .vimrc" \
            back    "Back") || return 0
        case "$c" in
            install)
                run_cmd "Installing vim-plug for $u" su - "$u" -c \
                    "curl -fLo ~/.vim/autoload/plug.vim --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim" ;;
            plugins)
                [ -f "$plug" ] || { tui_msg "Missing" "Install vim-plug first."; continue; }
                local args=() repo desc state
                while IFS='|' read -r repo desc; do
                    [ -z "$repo" ] && continue
                    grep -q "Plug '$repo'" "$rc" 2>/dev/null && state=on || state=off
                    args+=("$repo" "$desc" "$state")
                done <<<"$VIM_POPULAR"
                local sel
                sel=$(tui_check "Vim plugins — $u" \
                    "Enabled pre-checked. SPACE toggles, ENTER rewrites the\nsystui vim-plug block in .vimrc:" "${args[@]}") || continue
                sel=${sel//\"/}
                {
                    echo "call plug#begin('~/.vim/plugged')"
                    local r
                    for r in $sel; do echo "Plug '$r'"; done
                    echo "call plug#end()"
                    case " $sel " in *" morhetz/gruvbox "*)
                        echo "silent! colorscheme gruvbox" ;;
                    esac
                } | write_marked_block "$rc" "vim plugins"
                chown "$u" "$rc" 2>/dev/null
                tui_yesno "Install now?" "Plugin block written.\nRun :PlugInstall headlessly to download them now?" \
                    && run_cmd "vim :PlugInstall" su - "$u" -c \
                        "vim -es -u ~/.vimrc -i NONE -c 'PlugInstall --sync' -c 'qa' </dev/null || true" ;;
            sync)
                run_cmd "vim :PlugInstall" su - "$u" -c \
                    "vim -es -u ~/.vimrc -i NONE -c 'PlugInstall --sync' -c 'qa' </dev/null || true" ;;
            current)
                sed -n '/^# >>> systui vim plugins >>>/,/^# <<< systui vim plugins <<</p' "$rc" 2>/dev/null > ${SYSTUI_TMP}/ed
                [ -s ${SYSTUI_TMP}/ed ] || echo "(no systui plugin block yet)" > ${SYSTUI_TMP}/ed
                tui_text ".vimrc plugin block — $u" ${SYSTUI_TMP}/ed ;;
            back) return 0 ;;
        esac
    done
}

# ---- micro plugin management -------------------------------------------------
menu_micro_plugins() {
    command -v micro >/dev/null || { tui_msg "Missing" "micro is not installed (Editors -> Install)."; return; }
    local u; u=$(tui_input "User" "Manage micro plugins for which user?" "${SUDO_USER:-root}") || return 0
    user_home "$u" >/dev/null || { tui_msg "Error" "User $u not found."; return; }
    local sel
    sel=$(tui_check "micro plugins — $u" \
        "SPACE toggles, ENTER installs via micro's own plugin manager:" \
        fzf "Fuzzy file opening (needs fzf)" off \
        filemanager "File tree sidebar" off \
        editorconfig "EditorConfig support" off \
        lsp "Language Server Protocol client" off \
        aspell "Spell checking" off \
        jump "Jump to functions/definitions" off \
        detectindent "Auto-detect indentation" off) || return 0
    sel=${sel//\"/}
    [ -z "${sel// }" ] && return
    run_cmd "micro plugin install $sel" su - "$u" -c "micro -plugin install $sel"
}

# ---- oh-my-bash management --------------------------------------------------
# OMB config lives in the user's .bashrc as three arrays:
#   plugins=(...)  completions=(...)  aliases=(...)
# We manage them by scanning what the OMB install actually ships (so the
# checklists always match the installed version) and rewriting the array line.

# omb_current <bashrc> <array>  -> echoes currently enabled entries
omb_current() {
    grep -E "^${2}=\(" "$1" 2>/dev/null | head -1 | sed -E "s/^${2}=\(//; s/\).*$//"
}

# omb_set_array <bashrc> <array> <entries...>  -> rewrites the array line
omb_set_array() {
    local rc="$1" arr="$2"; shift 2
    if grep -qE "^${arr}=\(.*\)" "$rc"; then
        sed -i -E "s/^${arr}=\(.*\)/${arr}=($*)/" "$rc"
    elif grep -qE "^${arr}=\(" "$rc"; then
        # Array spans multiple lines — too risky to sed blindly.
        warn "${arr}=() spans multiple lines in $rc — edit it manually to: ${arr}=($*)"
        return 1
    else
        # Insert before the framework source line (this helper is used for
        # oh-my-bash AND oh-my-zsh) so the framework picks the array up;
        # append at the end of the file as a last resort.
        if grep -qE '^[[:space:]]*(source|\.) .*oh-my-(bash|zsh)\.sh' "$rc" 2>/dev/null; then
            sed -i -E "/^[[:space:]]*(source|\.) .*oh-my-(bash|zsh)\.sh/i ${arr}=($*)" "$rc"
        else
            printf '\n%s=(%s)\n' "$arr" "$*" >> "$rc"
        fi
    fi
}

# omb_pick_array <user> <home> <array> <dir> <strip-suffix> <title>
# Builds a checklist from the OMB install's directory contents, pre-checking
# whatever is currently enabled, then writes the selection back.
omb_pick_array() {
    local u="$1" home_dir="$2" arr="$3" dir="$4" strip="$5" title="$6"
    local rc="$home_dir/.bashrc"
    [ -d "$dir" ] || { tui_msg "Missing" "oh-my-bash is not installed for $u\n($dir not found)."; return; }
    local current
    current=" $(omb_current "$rc" "$arr") "
    local args=() e name state
    for e in "$dir"/*; do
        [ -e "$e" ] || continue
        name=$(basename "$e"); name=${name%$strip}
        case "$current" in *" $name "*) state=on ;; *) state=off ;; esac
        args+=("$name" "" "$state")
    done
    [ ${#args[@]} -eq 0 ] && { tui_msg "Empty" "Nothing found in $dir."; return; }
    local sel
    sel=$(tui_check "$title — $u" "SPACE toggles, ENTER applies.\nCurrently enabled items are pre-checked:" "${args[@]}") || return 0
    sel=${sel//\"/}
    omb_set_array "$rc" "$arr" $sel && tui_msg "Done" "$arr=($sel)\nwritten to $rc — takes effect in new shells."
    show_warnings
}

# Compatibility-focused Oh My Bash installer. It avoids the upstream installer,
# preserves the existing .bashrc, and validates the result before committing it.
omb_install_compatible() {
    local u="$1" home_dir="$2" mode="${3:-install}"
    local osh="$home_dir/.oh-my-bash" rc="$home_dir/.bashrc"
    local stamp backup
    stamp=$(date +%Y%m%d-%H%M%S)
    backup="$home_dir/.bashrc.systui-omb-$stamp.bak"

    command -v bash >/dev/null 2>&1 || { tui_msg "Missing" "Bash must be installed first."; return 1; }
    command -v git >/dev/null 2>&1 || pm_install git || return 1
    [ -f "$rc" ] || : > "$rc"
    cp -p "$rc" "$backup" || return 1
    chown "$u" "$backup" 2>/dev/null || true

    if [ -d "$osh/.git" ]; then
        if [ "$mode" = repair ]; then
            run_cmd "Repairing Oh My Bash" su - "$u" -c "git -C '$osh' reset --hard HEAD && git -C '$osh' clean -fd && git -C '$osh' pull --ff-only" || return 1
        else
            run_cmd "Updating Oh My Bash" su - "$u" -c "git -C '$osh' pull --ff-only" || true
        fi
    else
        [ ! -e "$osh" ] || mv "$osh" "$osh.pre-systui-$stamp"
        run_cmd "Installing Oh My Bash for $u" su - "$u" -c "git clone --depth 1 https://github.com/ohmybash/oh-my-bash.git '$osh'" || return 1
    fi

    python3 - "$rc" "$osh" <<'PYOMB'
from pathlib import Path
import re, sys
rc=Path(sys.argv[1]); osh=sys.argv[2]
text=rc.read_text(errors='replace') if rc.exists() else ''
text=re.sub(r'\n?# >>> systui oh-my-bash >>>.*?# <<< systui oh-my-bash <<<\n?', '\n', text, flags=re.S)
lines=[]
for line in text.splitlines():
    if re.match(r'^\s*(export\s+OSH=|OSH_THEME=|plugins=\(|completions=\(|aliases=\(|(?:source|\.)\s+.*oh-my-bash\.sh)', line) and not line.lstrip().startswith('#'):
        line='# disabled by systui: '+line
    lines.append(line)
block = '''# >>> systui oh-my-bash >>>
# Uses syntax supported by legacy and current Bash releases.
export OSH="__OSH__"
OSH_THEME="font"
plugins=(git bashmarks)
completions=(git ssh)
aliases=(general)
if [ -n "${BASH_VERSION-}" ] && [ -r "$OSH/oh-my-bash.sh" ]; then
    . "$OSH/oh-my-bash.sh"
fi
# <<< systui oh-my-bash <<<
'''.replace('__OSH__', osh)
rc.write_text('\n'.join(lines).rstrip()+'\n'+block)
PYOMB
    chown "$u" "$rc" 2>/dev/null || true

    if su - "$u" -c "HOME='$home_dir' bash --noprofile --rcfile '$rc' -i -c exit" >${SYSTUI_TMP}/omb-check.$$ 2>&1; then
        rm -f ${SYSTUI_TMP}/omb-check.$$
        tui_msg "Installed" "Oh My Bash is configured for $u.\n\nExisting config backup: $backup\nThe generated loader supports legacy and current Bash syntax."
        return 0
    fi

    local validation
    validation=$(tail -20 ${SYSTUI_TMP}/omb-check.$$ 2>/dev/null)
    rm -f ${SYSTUI_TMP}/omb-check.$$
    cp -p "$backup" "$rc"
    chown "$u" "$rc" 2>/dev/null || true
    tui_msg "Validation failed" "The previous .bashrc was restored.\n\n$validation"
    return 1
}

omb_remove_compatible_block() {
    python3 - "$1" <<'PYOMB'
from pathlib import Path
import re, sys
p=Path(sys.argv[1])
if p.exists():
    s=p.read_text(errors='replace')
    s=re.sub(r'\n?# >>> systui oh-my-bash >>>.*?# <<< systui oh-my-bash <<<\n?', '\n', s, flags=re.S)
    s=re.sub(r'^# disabled by systui: ', '', s, flags=re.M)
    p.write_text(s.lstrip('\n'))
PYOMB
}

menu_omb() { # menu_omb <user> <home_dir>
    local u="$1" home_dir="$2"
    local osh="$home_dir/.oh-my-bash"
    while true; do
        local c
        c=$(tui_menu "oh-my-bash — $u" "Install & manage oh-my-bash $(stp "$osh"):" \
            install "Install/reinstall (all supported Bash versions)" \
            repair  "Repair installation and rebuild safe config" \
            update  "Update oh-my-bash to the latest version" \
            theme   "Choose a theme" \
            plugins "Manage plugins (checklist from installed set)" \
            comps   "Manage completions" \
            aliases "Manage alias sets" \
            custom  "Install a third-party plugin (git URL)" \
            browse  "Browse available plugins & themes" \
            current "Show current configuration" \
            uninstall "Uninstall oh-my-bash" \
            back    "Back") || return 0
        case "$c" in
            install) omb_install_compatible "$u" "$home_dir" install ;;
            repair)  omb_install_compatible "$u" "$home_dir" repair ;;
            uninstall)
                [ -d "$osh" ] || { tui_msg "Missing" "oh-my-bash is not installed for $u."; continue; }
                tui_yesno "Uninstall oh-my-bash" \
"Remove ~/.oh-my-bash for $u?

If the installer's backup (~/.bashrc.omb-backup) exists it will be
restored; otherwise the OMB lines in .bashrc are commented out." || continue
                rm -rf "$osh"
                omb_remove_compatible_block "$home_dir/.bashrc"
                chown "$u" "$home_dir/.bashrc" 2>/dev/null || true
                tui_msg "Removed" "Oh My Bash was removed. Existing .bashrc content and timestamped backups were preserved." ;;
            update)
                [ -d "$osh" ] || { tui_msg "Missing" "oh-my-bash is not installed for $u."; continue; }
                run_cmd "Updating oh-my-bash" su - "$u" -c \
                    "cd ~/.oh-my-bash && git pull --ff-only" ;;
            theme)
                [ -d "$osh/themes" ] || { tui_msg "Missing" "oh-my-bash is not installed for $u."; continue; }
                # Build the theme list from what's actually installed.
                local args=() t cur
                cur=$(grep -E '^OSH_THEME=' "$home_dir/.bashrc" 2>/dev/null | sed 's/OSH_THEME=//; s/"//g')
                for t in "$osh"/themes/*/; do
                    t=$(basename "$t")
                    [ "$t" = "$cur" ] && args+=("$t" "(current)" on) || args+=("$t" "" off)
                done
                t=$(tui_radio "oh-my-bash theme — $u" "SPACE to select, ENTER to apply:" "${args[@]}") || continue
                [ -z "$t" ] && continue
                sed -i -E "s/^OSH_THEME=.*/OSH_THEME=\"$t\"/" "$home_dir/.bashrc"
                tui_msg "Done" "OSH_THEME=\"$t\" set in $home_dir/.bashrc" ;;
            plugins)
                omb_pick_array "$u" "$home_dir" plugins "$osh/plugins" "" "OMB plugins" ;;
            comps)
                omb_pick_array "$u" "$home_dir" completions "$osh/completions" ".completion.sh" "OMB completions" ;;
            aliases)
                omb_pick_array "$u" "$home_dir" aliases "$osh/aliases" ".aliases.sh" "OMB alias sets" ;;
            custom)
                [ -d "$osh" ] || { tui_msg "Missing" "oh-my-bash is not installed for $u."; continue; }
                local url name
                url=$(tui_input "Custom plugin" "Git URL of the plugin repository:" "https://github.com/") || continue
                [ "$url" = "https://github.com/" ] && continue
                name=$(tui_input "Custom plugin" "Plugin name (directory name):" "$(basename "$url" .git)") || continue
                [ -z "$name" ] && continue
                run_cmd "Cloning $name into OMB custom plugins" su - "$u" -c \
                    "git clone --depth 1 '$url' ~/.oh-my-bash/custom/plugins/'$name'"
                tui_yesno "Enable?" "Add '$name' to the plugins=() array now?" || continue
                local cur; cur=$(omb_current "$home_dir/.bashrc" plugins)
                case " $cur " in *" $name "*) ;; *) omb_set_array "$home_dir/.bashrc" plugins $cur "$name" ;; esac
                show_warnings
                tui_msg "Done" "Plugin '$name' installed and enabled." ;;
            browse)
                [ -d "$osh" ] || { tui_msg "Missing" "oh-my-bash is not installed for $u."; continue; }
                {
                    echo "=== Plugins ($osh/plugins) ==="
                    ls -1 "$osh/plugins" 2>/dev/null | column 2>/dev/null || ls -1 "$osh/plugins"
                    echo; echo "=== Custom plugins ==="
                    ls -1 "$osh/custom/plugins" 2>/dev/null
                    echo; echo "=== Completions ==="
                    ls -1 "$osh/completions" 2>/dev/null | sed 's/\.completion\.sh//' | column 2>/dev/null
                    echo; echo "=== Alias sets ==="
                    ls -1 "$osh/aliases" 2>/dev/null | sed 's/\.aliases\.sh//'
                    echo; echo "=== Themes ==="
                    ls -1 "$osh/themes" 2>/dev/null | column 2>/dev/null || ls -1 "$osh/themes"
                } > ${SYSTUI_TMP}/omb 2>&1
                tui_text "oh-my-bash inventory — $u" ${SYSTUI_TMP}/omb ;;
            current)
                {
                    echo "User    : $u"
                    echo "Install : $osh $( [ -d "$osh" ] && echo '(present)' || echo '(MISSING)')"
                    echo
                    grep -E '^(OSH_THEME|plugins|completions|aliases)=' "$home_dir/.bashrc" 2>/dev/null \
                        || echo "(no OMB configuration found in .bashrc)"
                } > ${SYSTUI_TMP}/omb
                tui_text "Current OMB config — $u" ${SYSTUI_TMP}/omb ;;
            back) return 0 ;;
        esac
    done
}



shell_plugin_target() {
    local u home_dir
    u=$(tui_input "Plugin user" "Configure shell plugins for which user?" "${SUDO_USER:-root}") || return 1
    home_dir=$(user_home "$u")
    [ -n "$home_dir" ] || { tui_msg "Error" "User '$u' was not found."; return 1; }
    printf '%s|%s\n' "$u" "$home_dir"
}

plugin_rc_file() {
    case "$1" in
        bash) printf '%s/.bashrc\n' "$2" ;;
        zsh)  printf '%s/.zshrc\n' "$2" ;;
        fish) printf '%s/.config/fish/config.fish\n' "$2" ;;
    esac
}

plugin_add_line() {
    local file="$1" line="$2" u="$3"
    mkdir -p "$(dirname "$file")"
    touch "$file"
    grep -Fqx "$line" "$file" 2>/dev/null || printf '\n%s\n' "$line" >> "$file"
    chown "$u" "$file" 2>/dev/null || true
}

plugin_remove_match() {
    local file="$1" pattern="$2"
    [ -f "$file" ] || return 0
    sed -i "\\|$pattern|d" "$file" 2>/dev/null || true
}

# Locate the distro-installed .zsh source file for a zsh plugin package.
# Layouts differ: Debian/Fedora use /usr/share/<name>/, Arch/Alpine use
# /usr/share/zsh/plugins/<name>/ — probe the known paths, then fall back to a
# shallow find. Empty output = not installed (or an unusual layout).
zsh_plugin_src_path() { # <plugin-name>
    local name="$1" p
    for p in \
        "/usr/share/$name/$name.zsh" \
        "/usr/share/$name/$name.plugin.zsh" \
        "/usr/share/zsh/plugins/$name/$name.plugin.zsh" \
        "/usr/share/zsh/plugins/$name/$name.zsh" \
        "/usr/share/zsh/$name/$name.zsh"; do
        [ -f "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    find /usr/share/zsh /usr/share -maxdepth 4 -type f \
        \( -name "$name.zsh" -o -name "$name.plugin.zsh" \) 2>/dev/null | head -1
}

plugin_choose_shells() {
    tui_check "Shell integration" "SPACE selects shells to configure:" \
        bash "Bash (~/.bashrc)" on \
        zsh  "Zsh (~/.zshrc)" on \
        fish "Fish (~/.config/fish/config.fish)" off
}

plugin_show_status() {
    local name="$1" command_name="$2" home_dir="$3" pattern="$4"
    {
        echo "Plugin : $name"
        echo "Binary : $(command -v "$command_name" 2>/dev/null || echo 'not installed')"
        echo
        for sh in bash zsh fish; do
            local rc; rc=$(plugin_rc_file "$sh" "$home_dir")
            printf '%-5s : %s\n' "$sh" "$rc"
            grep -n "$pattern" "$rc" 2>/dev/null || echo "        no integration found"
        done
    } > ${SYSTUI_TMP}/plugin-status
    tui_text "$name status" ${SYSTUI_TMP}/plugin-status
}

# ---- Per-package multi-method install helpers --------------------------------

# -- Starship --
menu_starship_install() {
    local method choices=()
    choices=(script "Official install script (starship.rs/install.sh)")
    command -v cargo >/dev/null 2>&1 && choices+=(cargo "Cargo (cargo install starship --locked)")
    command -v brew  >/dev/null 2>&1 && choices+=(brew  "Homebrew (brew install starship)")
    choices+=(pm "Package manager (${PM:-pm} install starship)" back "Back")
    method=$(tui_menu "Install Starship" "Choose an installation method:" "${choices[@]}") || return 0
    case "$method" in
        script)
            run_cmd "Install Starship via install.sh" bash -c \
                'tmp_script=$(mktemp "${TMPDIR:-/tmp}/systui-starship.XXXXXX") || exit 1
                 trap '"'"'rm -f "$tmp_script"'"'"' EXIT
                 curl -fL --proto "=https" --tlsv1.2 https://starship.rs/install.sh -o "$tmp_script" && chmod 700 "$tmp_script" && sh "$tmp_script" -y' ;;
        cargo) run_cmd "Install Starship via Cargo" cargo install starship --locked ;;
        brew)  run_cmd "Install Starship via Homebrew" brew install starship ;;
        pm)    pm_install starship ;;
        back) return 0 ;;
    esac
}

# -- Zsh --
menu_zsh_install() {
    local method choices=()
    choices=(pm "Package manager (${PM:-pm} install zsh)")
    command -v brew >/dev/null 2>&1 && choices+=(brew "Homebrew (brew install zsh)")
    choices+=(back "Back")
    method=$(tui_menu "Install Zsh" "Choose an installation method:" "${choices[@]}") || return 0
    case "$method" in
        pm)   pm_install zsh ;;
        brew) run_cmd "Install Zsh via Homebrew" brew install zsh ;;
        back) return 0 ;;
    esac
}

# -- Fish --
menu_fish_install() {
    local method choices=()
    choices=(pm "Package manager (${PM:-pm} install fish)")
    command -v brew >/dev/null 2>&1 && choices+=(brew "Homebrew (brew install fish)")
    case "$PM" in
        apt) choices+=(ppa "fish-shell PPA (ppa:fish-shell/release-4, Ubuntu/Debian)") ;;
    esac
    choices+=(back "Back")
    method=$(tui_menu "Install Fish" "Choose an installation method:" "${choices[@]}") || return 0
    case "$method" in
        pm)   pm_install fish ;;
        brew) run_cmd "Install Fish via Homebrew" brew install fish ;;
        ppa)
            command -v add-apt-repository >/dev/null 2>&1 || pm_install software-properties-common
            run_cmd "Add fish-shell PPA" add-apt-repository -y ppa:fish-shell/release-4
            run_cmd "apt-get update" apt-get update -qq
            run_cmd "Install Fish from PPA" apt-get install -y fish ;;
        back) return 0 ;;
    esac
}

# -- Neovim --
neovim_github_install() {
    local arch arch_str api url ver tmp bin
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch_str="x86_64" ;;
        aarch64|arm64) arch_str="aarch64" ;;
        *) tui_msg "Unsupported architecture" "No pre-built Neovim binary for: $arch"; return 1 ;;
    esac
    command -v curl >/dev/null 2>&1 || pm_install curl
    command -v tar  >/dev/null 2>&1 || pm_install tar
    api=$(curl -fsSL https://api.github.com/repos/neovim/neovim/releases/latest) || {
        tui_msg "Download failed" "Could not query the latest Neovim release."; return 1;
    }
    ver=$(printf '%s\n' "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
    url=$(printf '%s\n' "$api" | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
        | grep -E "/nvim-linux-${arch_str}\.tar\.gz$" | head -n1)
    [ -n "$url" ] || { tui_msg "No asset" "No ${arch_str} tarball found for Neovim ${ver}."; return 1; }
    tmp=$(mktemp -d) || return 1
    run_cmd "Download Neovim $ver" curl -fsSL "$url" -o "$tmp/nvim.tar.gz"
    run_cmd "Extract Neovim $ver" tar -xzf "$tmp/nvim.tar.gz" -C "$tmp"
    bin=$(find "$tmp" -name "nvim" -type f | head -n1)
    [ -n "$bin" ] || { tui_msg "Extraction failed" "nvim binary not found in archive."; rm -rf "$tmp"; return 1; }
    run_cmd "Install Neovim $ver to /usr/local/bin" install -m 0755 "$bin" /usr/local/bin/nvim
    rm -rf "$tmp"
    tui_msg "Neovim installed" "nvim $ver → /usr/local/bin/nvim"
}

menu_neovim_install() {
    local method choices=()
    choices=(pm "Package manager (${PM:-pm} install neovim)")
    choices+=(github "GitHub release binary (latest stable, auto-detect arch)")
    command -v brew >/dev/null 2>&1 && choices+=(brew "Homebrew (brew install neovim)")
    command -v snap >/dev/null 2>&1 && choices+=(snap "Snap (snap install nvim --classic)")
    case "$PM" in
        apt) choices+=(ppa "neovim-ppa/stable PPA (Ubuntu — more recent builds)") ;;
    esac
    choices+=(back "Back")
    method=$(tui_menu "Install Neovim" "Choose an installation method:" "${choices[@]}") || return 0
    case "$method" in
        pm)     pm_install neovim ;;
        github) neovim_github_install ;;
        brew)   run_cmd "Install Neovim via Homebrew" brew install neovim ;;
        snap)   run_cmd "Install Neovim via Snap" snap install nvim --classic ;;
        ppa)
            command -v add-apt-repository >/dev/null 2>&1 || pm_install software-properties-common
            run_cmd "Add neovim-ppa/stable" add-apt-repository -y ppa:neovim-ppa/stable
            run_cmd "apt-get update" apt-get update -qq
            run_cmd "Install Neovim from PPA" apt-get install -y neovim ;;
        back) return 0 ;;
    esac
}

# -- micro --
micro_github_install() {
    local arch arch_str api url ver tmp bin
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch_str="linux64" ;;
        aarch64|arm64) arch_str="linux-arm64" ;;
        armv7*)        arch_str="linux-arm" ;;
        *) tui_msg "Unsupported architecture" "No official micro binary for: $arch"; return 1 ;;
    esac
    command -v curl >/dev/null 2>&1 || pm_install curl
    command -v tar  >/dev/null 2>&1 || pm_install tar
    api=$(curl -fsSL https://api.github.com/repos/zyedidia/micro/releases/latest) || {
        tui_msg "Download failed" "Could not query the latest micro release."; return 1;
    }
    ver=$(printf '%s\n' "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
    url=$(printf '%s\n' "$api" | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
        | grep -E "/micro-[^/]*-${arch_str}\.tar\.gz$" | head -n1)
    [ -n "$url" ] || { tui_msg "No asset" "No ${arch_str} tar.gz found for micro ${ver}."; return 1; }
    tmp=$(mktemp -d) || return 1
    run_cmd "Download micro $ver" curl -fsSL "$url" -o "$tmp/micro.tar.gz"
    run_cmd "Extract micro $ver" tar -xzf "$tmp/micro.tar.gz" -C "$tmp"
    bin=$(find "$tmp" -name "micro" -type f | head -n1)
    [ -n "$bin" ] || { tui_msg "Extraction failed" "micro binary not found in archive."; rm -rf "$tmp"; return 1; }
    run_cmd "Install micro $ver to /usr/local/bin" install -m 0755 "$bin" /usr/local/bin/micro
    rm -rf "$tmp"
    tui_msg "micro installed" "micro $ver → /usr/local/bin/micro"
}

menu_micro_install() {
    local method choices=()
    choices=(pm     "Package manager (${PM:-pm} install micro)")
    choices+=(script "Official install script (getmic.ro)")
    choices+=(github "GitHub release binary (auto-detect arch)")
    command -v brew >/dev/null 2>&1 && choices+=(brew "Homebrew (brew install micro)")
    command -v snap >/dev/null 2>&1 && choices+=(snap "Snap (snap install micro --classic)")
    choices+=(back "Back")
    method=$(tui_menu "Install micro" "Choose an installation method:" "${choices[@]}") || return 0
    case "$method" in
        pm)     pm_install micro ;;
        script)
            command -v curl >/dev/null 2>&1 || pm_install curl
            run_cmd "Install micro via getmic.ro" bash -c \
                'tmp_dir=$(mktemp -d) && cd "$tmp_dir" && curl https://getmic.ro | bash && install -m 0755 micro /usr/local/bin/micro; rm -rf "$tmp_dir"' ;;
        github) micro_github_install ;;
        brew)   run_cmd "Install micro via Homebrew" brew install micro ;;
        snap)   run_cmd "Install micro via Snap" snap install micro --classic ;;
        back) return 0 ;;
    esac
}

# -- fzf --
fzf_github_install() {
    local arch arch_str api url ver tmp bin
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)  arch_str="linux_amd64" ;;
        aarch64|arm64) arch_str="linux_arm64" ;;
        armv7*)        arch_str="linux_armv7" ;;
        *) tui_msg "Unsupported architecture" "No official fzf binary for: $arch"; return 1 ;;
    esac
    command -v curl >/dev/null 2>&1 || pm_install curl
    command -v tar  >/dev/null 2>&1 || pm_install tar
    api=$(curl -fsSL https://api.github.com/repos/junegunn/fzf/releases/latest) || {
        tui_msg "Download failed" "Could not query the latest fzf release."; return 1;
    }
    ver=$(printf '%s\n' "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
    url=$(printf '%s\n' "$api" | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
        | grep -E "/fzf-[^/]*-${arch_str}\.tar\.gz$" | head -n1)
    [ -n "$url" ] || { tui_msg "No asset" "No ${arch_str} tar.gz found for fzf ${ver}."; return 1; }
    tmp=$(mktemp -d) || return 1
    run_cmd "Download fzf $ver" curl -fsSL "$url" -o "$tmp/fzf.tar.gz"
    run_cmd "Extract fzf $ver" tar -xzf "$tmp/fzf.tar.gz" -C "$tmp"
    [ -f "$tmp/fzf" ] || { tui_msg "Extraction failed" "fzf binary not found in archive."; rm -rf "$tmp"; return 1; }
    run_cmd "Install fzf $ver to /usr/local/bin" install -m 0755 "$tmp/fzf" /usr/local/bin/fzf
    rm -rf "$tmp"
    tui_msg "fzf installed" "fzf $ver → /usr/local/bin/fzf"
}

menu_fzf_install() {
    local method choices=()
    choices=(pm "Package manager (${PM:-pm} install fzf)")
    command -v git >/dev/null 2>&1 && choices+=(git "git clone ~/.fzf (official — installs shell key bindings)")
    choices+=(github "GitHub release binary (auto-detect arch)")
    command -v brew  >/dev/null 2>&1 && choices+=(brew  "Homebrew (brew install fzf)")
    command -v cargo >/dev/null 2>&1 && choices+=(cargo "Cargo (cargo install fzf)")
    choices+=(back "Back")
    method=$(tui_menu "Install fzf" "Choose an installation method:" "${choices[@]}") || return 0
    case "$method" in
        pm) pm_install fzf ;;
        git)
            local u; u=$(tui_input "User" "Install fzf git clone for which user?" "${SUDO_USER:-root}") || return 0
            run_cmd "Clone fzf for $u" su - "$u" -c \
                'git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf 2>/dev/null || (cd ~/.fzf && git pull)'
            run_cmd "Run fzf install for $u" su - "$u" -c '~/.fzf/install --all' ;;
        github) fzf_github_install ;;
        brew)   run_cmd "Install fzf via Homebrew" brew install fzf ;;
        cargo)  run_cmd "Install fzf via Cargo" cargo install fzf ;;
        back) return 0 ;;
    esac
}

# -- Docker --
menu_docker_install() {
    local method choices=()
    choices=(pm "Package manager (${PM:-pm} install docker.io)")
    choices+=(script "Docker convenience script (get.docker.com)")
    case "$PM" in
        apt)     choices+=(repo-apt "Docker CE APT repo (download.docker.com)") ;;
        dnf|yum) choices+=(repo-rpm "Docker CE YUM/DNF repo (download.docker.com)") ;;
    esac
    command -v brew >/dev/null 2>&1 && choices+=(brew "Homebrew Cask (brew install --cask docker)")
    choices+=(back "Back")
    method=$(tui_menu "Install Docker" "Choose an installation method:" "${choices[@]}") || return 0
    case "$method" in
        pm) pm_install docker.io ;;
        script)
            command -v curl >/dev/null 2>&1 || pm_install curl
            run_cmd "Install Docker via get.docker.com" bash -c \
                'tmp_script=$(mktemp "${TMPDIR:-/tmp}/systui-docker.XXXXXX") || exit 1
                 trap '"'"'rm -f "$tmp_script"'"'"' EXIT
                 curl -fsSL https://get.docker.com -o "$tmp_script" && chmod 700 "$tmp_script" && sh "$tmp_script"' ;;
        repo-apt)
            command -v curl >/dev/null 2>&1 || pm_install curl
            command -v gpg  >/dev/null 2>&1 || pm_install gnupg
            run_cmd "Add Docker GPG key" bash -c \
                'mkdir -p /etc/apt/keyrings
                 curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg" \
                   | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                 chmod a+r /etc/apt/keyrings/docker.gpg'
            run_cmd "Add Docker APT repo" bash -c \
                '. /etc/os-release
                 echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
                   https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
                   > /etc/apt/sources.list.d/docker.list'
            run_cmd "Update APT + install Docker CE" bash -c \
                'apt-get update -qq && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin' ;;
        repo-rpm)
            run_cmd "Add Docker CE YUM/DNF repo" dnf config-manager --add-repo \
                https://download.docker.com/linux/fedora/docker-ce.repo
            run_cmd "Install Docker CE via DNF" dnf install -y \
                docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ;;
        brew) run_cmd "Install Docker Desktop via Homebrew Cask" brew install --cask docker ;;
        back) return 0 ;;
    esac
}

# -- Node.js --
menu_node_install() {
    local method u choices=()
    choices=(pm "Package manager (${PM:-pm} install nodejs)")
    choices+=(nvm "nvm — Node Version Manager (installs latest LTS per-user)")
    choices+=(fnm "fnm — Fast Node Manager (Rust-based, per-user)")
    case "$PM" in
        apt) choices+=(nodesource "NodeSource APT repo — current LTS (deb.nodesource.com)") ;;
    esac
    command -v brew >/dev/null 2>&1 && choices+=(brew "Homebrew (brew install node)")
    choices+=(back "Back")
    method=$(tui_menu "Install Node.js" "Choose an installation method:" "${choices[@]}") || return 0
    case "$method" in
        pm) pm_install nodejs ;;
        nvm)
            u=$(tui_input "User" "Install nvm + LTS Node for which user?" "${SUDO_USER:-root}") || return 0
            run_cmd "Install nvm for $u" su - "$u" -c \
                'tmp_script=$(mktemp "${TMPDIR:-/tmp}/systui-nvm.XXXXXX") || exit 1
                 trap '"'"'rm -f "$tmp_script"'"'"' EXIT
                 curl -fsSL --proto "=https" --tlsv1.2 \
                   https://raw.githubusercontent.com/nvm-sh/nvm/HEAD/install.sh \
                   -o "$tmp_script" && bash "$tmp_script"'
            run_cmd "Install Node LTS via nvm for $u" su - "$u" -c \
                'export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
                 [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
                 nvm install --lts' ;;
        fnm)
            u=$(tui_input "User" "Install fnm + LTS Node for which user?" "${SUDO_USER:-root}") || return 0
            run_cmd "Install fnm for $u" su - "$u" -c \
                'tmp_script=$(mktemp "${TMPDIR:-/tmp}/systui-fnm.XXXXXX") || exit 1
                 trap '"'"'rm -f "$tmp_script"'"'"' EXIT
                 curl -fsSL https://fnm.vercel.app/install -o "$tmp_script" && bash "$tmp_script"'
            run_cmd "Install Node LTS via fnm for $u" su - "$u" -c \
                'export PATH="$HOME/.local/share/fnm:$PATH"
                 eval "$(fnm env --use-on-cd 2>/dev/null)"
                 fnm install --lts' ;;
        nodesource)
            command -v curl >/dev/null 2>&1 || pm_install curl
            run_cmd "Add NodeSource LTS APT repo" bash -c \
                'tmp_script=$(mktemp "${TMPDIR:-/tmp}/systui-nodesource.XXXXXX") || exit 1
                 trap '"'"'rm -f "$tmp_script"'"'"' EXIT
                 curl -fsSL https://deb.nodesource.com/setup_lts.x -o "$tmp_script" && bash "$tmp_script"'
            run_cmd "Install Node.js LTS from NodeSource" apt-get install -y nodejs ;;
        brew) run_cmd "Install Node.js via Homebrew" brew install node ;;
        back) return 0 ;;
    esac
}

# -- ripgrep --
rg_github_install() {
    local arch arch_str libc api url ver tmp bin
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)  arch_str="x86_64-unknown-linux" ;;
        aarch64|arm64) arch_str="aarch64-unknown-linux" ;;
        *) tui_msg "Unsupported architecture" "No official ripgrep binary for: $arch"; return 1 ;;
    esac
    libc="musl"
    command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl || libc="gnu"
    command -v curl >/dev/null 2>&1 || pm_install curl
    command -v tar  >/dev/null 2>&1 || pm_install tar
    api=$(curl -fsSL https://api.github.com/repos/BurntSushi/ripgrep/releases/latest) || {
        tui_msg "Download failed" "Could not query the latest ripgrep release."; return 1;
    }
    ver=$(printf '%s\n' "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
    url=$(printf '%s\n' "$api" | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
        | grep -E "/${arch_str}-${libc}\.tar\.gz$" | head -n1)
    [ -n "$url" ] || url=$(printf '%s\n' "$api" | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
        | grep -E "/${arch_str}-(gnu|musl)\.tar\.gz$" | head -n1)
    [ -n "$url" ] || { tui_msg "No asset" "No ${arch_str} tar.gz for ripgrep ${ver}."; return 1; }
    tmp=$(mktemp -d) || return 1
    run_cmd "Download ripgrep $ver" curl -fsSL "$url" -o "$tmp/rg.tar.gz"
    run_cmd "Extract ripgrep $ver" tar -xzf "$tmp/rg.tar.gz" -C "$tmp"
    bin=$(find "$tmp" -name "rg" -type f | head -n1)
    [ -n "$bin" ] || { tui_msg "Extraction failed" "rg binary not found in archive."; rm -rf "$tmp"; return 1; }
    run_cmd "Install ripgrep $ver to /usr/local/bin" install -m 0755 "$bin" /usr/local/bin/rg
    rm -rf "$tmp"
    tui_msg "ripgrep installed" "rg $ver → /usr/local/bin/rg"
}

menu_ripgrep_install() {
    local method choices=()
    choices=(pm "Package manager (${PM:-pm} install ripgrep)")
    choices+=(github "GitHub release binary (auto-detect arch + libc)")
    command -v cargo >/dev/null 2>&1 && choices+=(cargo "Cargo (cargo install ripgrep)")
    command -v brew  >/dev/null 2>&1 && choices+=(brew  "Homebrew (brew install ripgrep)")
    choices+=(back "Back")
    method=$(tui_menu "Install ripgrep" "Choose an installation method:" "${choices[@]}") || return 0
    case "$method" in
        pm)     pm_install ripgrep ;;
        github) rg_github_install ;;
        cargo)  run_cmd "Install ripgrep via Cargo" cargo install ripgrep ;;
        brew)   run_cmd "Install ripgrep via Homebrew" brew install ripgrep ;;
        back) return 0 ;;
    esac
}

menu_plugin_starship() {
    local u="$1" home_dir="$2" c shells sh rc preset
    while true; do
        c=$(tui_menu "Starship — $u" "Install and configure the cross-shell prompt:" \
            install "Install using the official starship.rs installer" \
            integrate "Enable Starship for selected shells" \
            preset "Apply a built-in Starship preset" \
            basic "Write a basic ~/.config/starship.toml" \
            edit "Edit ~/.config/starship.toml" \
            disable "Remove Starship initialization from selected shells" \
            status "Show installation and shell integration status" \
            back "Back") || return 0
        case "$c" in
            install) menu_starship_install ;;
            integrate)
                shells=$(plugin_choose_shells) || continue; shells=${shells//\"/}
                for sh in $shells; do
                    rc=$(plugin_rc_file "$sh" "$home_dir")
                    case "$sh" in
                        bash) plugin_add_line "$rc" 'eval "$(starship init bash)"' "$u" ;;
                        zsh) plugin_add_line "$rc" 'eval "$(starship init zsh)"' "$u" ;;
                        fish) plugin_add_line "$rc" 'starship init fish | source' "$u" ;;
                    esac
                done ;;
            preset)
                command -v starship >/dev/null || { tui_msg "Missing" "Install Starship first."; continue; }
                preset=$(tui_radio "Starship preset" "SPACE selects a preset:" \
                    plain-text-symbols "Plain text symbols" on \
                    bracketed-segments "Bracketed segments" off \
                    nerd-font-symbols "Nerd Font symbols" off \
                    pastel-powerline "Pastel Powerline" off \
                    no-empty-icons "No empty icons" off) || continue
                mkdir -p "$home_dir/.config"
                su - "$u" -c "starship preset '$preset' -o ~/.config/starship.toml" || tui_msg "Failed" "Unable to apply preset '$preset'." ;;
            basic)
                mkdir -p "$home_dir/.config"
                cat > "$home_dir/.config/starship.toml" <<'EOF'
add_newline = true
command_timeout = 1000

[character]
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"

[directory]
truncation_length = 4
truncate_to_repo = false

[git_status]
disabled = false
EOF
                chown -R "$u" "$home_dir/.config/starship.toml" 2>/dev/null || true ;;
            edit) mkdir -p "$home_dir/.config"; touch "$home_dir/.config/starship.toml"; safe_edit "$home_dir/.config/starship.toml" || true ;;
            disable)
                shells=$(plugin_choose_shells) || continue; shells=${shells//\"/}
                for sh in $shells; do rc=$(plugin_rc_file "$sh" "$home_dir"); plugin_remove_match "$rc" 'starship init'; done ;;
            status) plugin_show_status "Starship" starship "$home_dir" 'starship init' ;;
            back|"") return 0 ;;
        esac
    done
}

menu_plugin_fzf() {
    local u="$1" home_dir="$2" c shells sh rc opts
    while true; do
        c=$(tui_menu "fzf — $u" "Install and configure fuzzy finding:" \
            install "Install fzf" integrate "Enable key bindings and completion" \
            options "Set FZF_DEFAULT_OPTS" edit "Edit shell configuration" \
            disable "Remove fzf configuration" remove "Remove fzf package" \
            status "Show status" back "Back") || return 0
        case "$c" in
            install) menu_fzf_install ;;
            integrate)
                shells=$(plugin_choose_shells) || continue; shells=${shells//\"/}
                for sh in $shells; do rc=$(plugin_rc_file "$sh" "$home_dir"); case "$sh" in
                    bash) plugin_add_line "$rc" '[ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && source /usr/share/doc/fzf/examples/key-bindings.bash' "$u"; plugin_add_line "$rc" '[ -f /usr/share/bash-completion/completions/fzf ] && source /usr/share/bash-completion/completions/fzf' "$u" ;;
                    zsh) plugin_add_line "$rc" '[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ] && source /usr/share/doc/fzf/examples/key-bindings.zsh' "$u"; plugin_add_line "$rc" '[ -f /usr/share/doc/fzf/examples/completion.zsh ] && source /usr/share/doc/fzf/examples/completion.zsh' "$u" ;;
                    fish) plugin_add_line "$rc" 'fzf --fish | source' "$u" ;;
                esac; done ;;
            options) opts=$(tui_input "fzf options" "FZF_DEFAULT_OPTS:" "--height=40% --layout=reverse --border") || continue; plugin_add_line "$home_dir/.profile" "export FZF_DEFAULT_OPTS='$opts'" "$u" ;;
            edit) safe_edit "$home_dir/.profile" || true ;;
            disable) for rc in "$home_dir/.bashrc" "$home_dir/.zshrc" "$home_dir/.config/fish/config.fish" "$home_dir/.profile"; do plugin_remove_match "$rc" 'fzf'; plugin_remove_match "$rc" 'FZF_DEFAULT_OPTS'; done ;;
            remove) pm_remove fzf ;;
            status) plugin_show_status "fzf" fzf "$home_dir" 'fzf' ;;
            back|"") return 0 ;;
        esac
    done
}

menu_plugin_simple_init() { # title command package init-bash init-zsh init-fish user home [config]
    local title="$1" cmd="$2" pkg="$3" ib="$4" iz="$5" ifish="$6" u="$7" home_dir="$8" cfg="${9:-}"
    local c shells sh rc
    while true; do
        c=$(tui_menu "$title — $u" "Install and configure $title:" \
            install "Install $pkg" integrate "Enable for selected shells" \
            edit "Edit plugin configuration" disable "Remove shell integration" \
            remove "Remove package" status "Show status" back "Back") || return 0
        case "$c" in
            install) pm_install "$pkg" ;;
            integrate)
                shells=$(plugin_choose_shells) || continue; shells=${shells//\"/}
                for sh in $shells; do rc=$(plugin_rc_file "$sh" "$home_dir"); case "$sh" in
                    bash) [ -n "$ib" ] && plugin_add_line "$rc" "$ib" "$u";;
                    zsh)
                        # "@detect:<pkg>" resolves the distro-specific source
                        # path at integrate time (after the package exists).
                        if [ -n "$iz" ] && [ "${iz#@detect:}" != "$iz" ]; then
                            local _zp; _zp=$(zsh_plugin_src_path "${iz#@detect:}")
                            if [ -n "$_zp" ]; then
                                plugin_add_line "$rc" "source $_zp" "$u"
                            else
                                tui_msg "Not found" "Could not locate the .zsh file for '${iz#@detect:}'.\nFind it after install and source it manually."
                            fi
                        elif [ -n "$iz" ]; then
                            plugin_add_line "$rc" "$iz" "$u"
                        fi ;;
                    fish) [ -n "$ifish" ] && plugin_add_line "$rc" "$ifish" "$u";;
                esac; done ;;
            edit)
                [ -n "$cfg" ] || cfg="$home_dir/.profile"
                mkdir -p "$(dirname "$cfg")"; touch "$cfg"; chown "$u" "$cfg" 2>/dev/null || true
                safe_edit "$cfg" || true ;;
            disable) for rc in "$home_dir/.bashrc" "$home_dir/.zshrc" "$home_dir/.config/fish/config.fish"; do plugin_remove_match "$rc" "$cmd"; done ;;
            remove) pm_remove "$pkg" ;;
            status) plugin_show_status "$title" "$cmd" "$home_dir" "$cmd" ;;
            back|"") return 0 ;;
        esac
    done
}

menu_plugin_completions() {
    local u="$1" home_dir="$2" c sel
    while true; do
        c=$(tui_menu "Completions — $u" "Manage shell completion packages and settings:" \
            install "Install selected completion packages" \
            bashcfg "Configure Bash completion loading" \
            zshcfg "Configure Zsh completion system" \
            remove "Remove selected completion packages" status "Show status" back "Back") || return 0
        case "$c" in
            install) sel=$(tui_check "Completion packages" "SPACE selects:" bash-completion "Bash completion" on zsh-completions "Zsh completions" off) || continue; sel=${sel//\"/}; if [ -n "${sel// }" ]; then local -a _pkgs=(); parse_package_input "$sel" _pkgs && pm_install "${_pkgs[@]}"; fi ;;
            bashcfg) plugin_add_line "$home_dir/.bashrc" '[[ $- == *i* ]] && [ -r /usr/share/bash-completion/bash_completion ] && source /usr/share/bash-completion/bash_completion' "$u" ;;
            zshcfg) plugin_add_line "$home_dir/.zshrc" 'autoload -Uz compinit && compinit' "$u" ;;
            remove) sel=$(tui_check "Remove completions" "SPACE selects:" bash-completion "Bash completion" off zsh-completions "Zsh completions" off) || continue; sel=${sel//\"/}; if [ -n "${sel// }" ]; then local -a _pkgs=(); parse_package_input "$sel" _pkgs && pm_remove "${_pkgs[@]}"; fi ;;
            status) plugin_show_status "Completions" bash "$home_dir" 'compinit\|bash_completion' ;;
            back|"") return 0 ;;
        esac
    done
}



shell_github_catalog() { # tag|description|repo|shells|init
    cat <<'EOF'
ble-sh|Bash line editor, autosuggestions and highlighting|akinomyoga/ble.sh|bash|source ~/.local/share/ble-sh/ble.sh
bash-preexec|preexec/precmd hooks for Bash|rcaloras/bash-preexec|bash|source ~/.local/share/bash-preexec/bash-preexec.sh
bash-git-prompt|Fast Git-aware Bash prompt|magicmonty/bash-git-prompt|bash|source ~/.local/share/bash-git-prompt/gitprompt.sh
fzf-tab|Replace Zsh completion menu with fzf|Aloxaf/fzf-tab|zsh|source ~/.local/share/zsh-plugins/fzf-tab/fzf-tab.plugin.zsh
fast-syntax-highlighting|Feature-rich Zsh syntax highlighting|zdharma-continuum/fast-syntax-highlighting|zsh|source ~/.local/share/zsh-plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh
zsh-autocomplete|Real-time type-ahead completion|marlonrichert/zsh-autocomplete|zsh|source ~/.local/share/zsh-plugins/zsh-autocomplete/zsh-autocomplete.plugin.zsh
zsh-history-substring-search|History substring navigation|zsh-users/zsh-history-substring-search|zsh|source ~/.local/share/zsh-plugins/zsh-history-substring-search/zsh-history-substring-search.zsh
zsh-you-should-use|Remind users about configured aliases|MichaelAquilina/zsh-you-should-use|zsh|source ~/.local/share/zsh-plugins/zsh-you-should-use/you-should-use.plugin.zsh
fish-autopair|Automatic bracket and quote pairing|jorgebucaran/autopair.fish|fish|fisher install jorgebucaran/autopair.fish
fish-done|Desktop notifications for long commands|franciscolourenco/done|fish|fisher install franciscolourenco/done
fish-puffer|Text-expansion plugin for Fish|nickeb96/puffer-fish|fish|fisher install nickeb96/puffer-fish
fish-colored-man|Colored man pages for Fish|decors/fish-colored-man|fish|fisher install decors/fish-colored-man
EOF
}

menu_shell_github_plugins() {
    local u="$1" h="$2" chosen tag desc repo shells init dest rc
    local args=()
    while IFS='|' read -r tag desc repo shells init; do
        case "$shells" in
            bash) dest="$h/.local/share/${tag/bash-/bash-}" ;;
            zsh) dest="$h/.local/share/zsh-plugins/$tag" ;;
            fish) dest="$h/.config/fish/functions" ;;
        esac
        args+=("$tag" "$desc — $repo [$shells]" off)
    done < <(shell_github_catalog)
    chosen=$(tui_check "GitHub shell plugins — $u" "SPACE selects projects to install/update and integrate:" "${args[@]}") || return 0
    command -v git >/dev/null 2>&1 || pm_install git
    for tag in $chosen; do
        while IFS='|' read -r t desc repo shells init; do
            [ "$t" = "$tag" ] || continue
            case "$shells" in
                bash)
                    dest="$h/.local/share/$tag"
                    fm_as_user "$u" "mkdir -p ~/.local/share; if [ -d '$dest/.git' ]; then git -C '$dest' pull --ff-only; else rm -rf '$dest'; git clone --depth 1 https://github.com/$repo.git '$dest'; fi"
                    rc="$h/.bashrc"; plugin_add_line "$rc" "${init/#\~/$h}" "$u" ;;
                zsh)
                    dest="$h/.local/share/zsh-plugins/$tag"
                    fm_as_user "$u" "mkdir -p ~/.local/share/zsh-plugins; if [ -d '$dest/.git' ]; then git -C '$dest' pull --ff-only; else rm -rf '$dest'; git clone --depth 1 https://github.com/$repo.git '$dest'; fi"
                    rc="$h/.zshrc"; plugin_add_line "$rc" "${init/#\~/$h}" "$u" ;;
                fish)
                    command -v fish >/dev/null 2>&1 || pm_install fish
                    fm_as_user "$u" "fish -lc 'type -q fisher; or begin; set t (mktemp); curl -fL --proto =https --tlsv1.2 https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish -o \"\$t\"; source \"\$t\"; rm -f \"\$t\"; end; $init'" ;;
            esac
        done < <(shell_github_catalog)
    done
    tui_msg "Shell plugins" "Selected GitHub projects were installed or updated for $u."
}

# ---- awesome-zsh-plugins catalogue -------------------------------------------
#
# Curated subset of https://github.com/unixorn/awesome-zsh-plugins (Plugins
# section, fetched 2026-08). Format: tag|description|repo|category. Tags are
# used as clone directory names and in plugins=(), so they must be unique and
# valid directory names. Repos are owner/name pairs straight from the source
# list. Categories: nav hist git comp vi alias prompt lang misc.
AZP_CATALOG=$(cat <<'EOF'
enhancd|Enhanced cd with frecency jump|b4b4r07/enhancd|nav
zsh-z|Frecency directory jumping (native Zsh)|agkozak/zsh-z|nav
autojump|Learns directories; jump with j|wting/autojump|nav
zsh-abbr|Fish-style auto-expanding abbreviations|olets/zsh-abbr|nav
interactive-cd|Fish-like cd tab completion|changyuheng/zsh-interactive-cd|nav
favorite-directories|Jump to favorite directories|seletskiy/zsh-favorite-directories|nav
autoenv|Per-directory environment|zpm-zsh/autoenv|nav
fz|Fuzzy completion for z|changyuheng/fz|nav
history-search-multi-word|Multi-word Ctrl-R history search|zdharma-continuum/history-search-multi-word|hist
history-filter|Exclude patterns from history|MichaelAquilina/zsh-history-filter|hist
fzf-history-search|Ctrl-R with fzf|joshskidmore/zsh-fzf-history-search|hist
histdb|SQLite history + fzf|larkery/zsh-histdb|hist
extend-history|Record exit code per history entry|xav-b/zsh-extend-history|hist
directory-history|Per-directory history|tymm/zsh-directory-history|hist
zsh-history|Query history with SQL|b4b4r07/zsh-history|hist
zsh-hist|Edit history inline|marlonrichert/zsh-hist|hist
history-sync|Git-synced history across machines|vitobotta/zsh-history-sync|hist
passwordless-history|Keep secrets out of history|jgogstad/passwordless-history|hist
git-fuzzy|fzf-powered git interface|bigH/git-fuzzy|git
git-extra-commands|Extra git helper commands|unixorn/git-extra-commands|git
git-add-remote|Add upstream remote easily|caarlos0/git-add-remote|git
open-pr|Open pull requests from the CLI|caarlos0/zsh-open-pr|git
branch-manager|Manage git branches|elstgav/branch-manager|git
git-smart-commands|Smarter git commands|seletskiy/zsh-git-smart-commands|git
blackbox|GPG-encrypted secrets in git|StackExchange/blackbox|git
gitignore|Create .gitignore files|voronkovich/gitignore.plugin.zsh|git
git-worktree|Git worktree helpers|alexiszamanidis/zsh-git-worktree|git
cleanbranches|fzf-based branch cleanup|wu9o/ohmyzsh-cleanbranches|git
zsh-navigation-tools|htop-like tools + history browser|zdharma-continuum/zsh-navigation-tools|comp
abbrev-alias|Vim-style abbreviation expansion|momo-lab/zsh-abbrev-alias|comp
fuzzy-search-and-edit|Fuzzy-open files by name|seletskiy/zsh-fuzzy-search-and-edit|comp
zsh-fzy|fzy-based completions|aperezdc/zsh-fzy|comp
vi-motions|Extra vim motions/text objects|zsh-vi-more/vi-motions|vi
vi-increment|vim Ctrl-A/Ctrl-X increment|zsh-vi-more/vi-increment|vi
evil-registers|Use vim registers in ZLE|zsh-vi-more/evil-registers|vi
opp|Vim text-object-ish|hchbaw/opp.zsh|vi
vi-quote|Quote/unquote motions|zsh-vi-more/vi-quote|vi
alias-tips|Remind you of aliases|djui/alias-tips|alias
alias-finder|Show alias when you use a command|akash329d/zsh-alias-finder|alias
expand-ealias|Space expands ealiases|zigius/expand-ealias.plugin.zsh|alias
alias-expand-space|Expand aliases on space|spqw/zsh-alias-expand-space|alias
command-execution-timer|Show command duration|olets/command-execution-timer|prompt
auto-notify|Notify on long commands|MichaelAquilina/zsh-auto-notify|prompt
zsh-defer|Defer slow plugin init|romkatv/zsh-defer|prompt
zsh-no-ps2|Enter continues incomplete commands|romkatv/zsh-no-ps2|prompt
colorize|Colorize command output|zpm-zsh/colorize|prompt
prettyping|Prettier ping output|unixorn/prettyping|prompt
zhooks|Inspect zsh hook arrays/functions|agkozak/zhooks|prompt
zsh-window-title|Dynamic window titles|olets/zsh-window-title|prompt
zsh-titles|tmux/screen window titles|jreese/zsh-titles|prompt
asdf|asdf version-manager integration|kiurchv/asdf.plugin.zsh|lang
autoswitch-virtualenv|Auto python venv switching|MichaelAquilina/zsh-autoswitch-virtualenv|lang
zsh-eza|eza aliases + integration|zsh-contrib/zsh-eza|lang
fd-zsh|fd aliases|MohamedElashri/fd-zsh|lang
terraform|Terraform aliases/completions|ptavares/zsh-terraform|lang
kubectx-zshplugin|Install kubectx/kubens + integration|unixorn/kubectx-zshplugin|lang
zsh-kubectx|kubectx integration|ptavares/zsh-kubectx|lang
zsh-aws|aws-vault integration|zsh-contrib/zsh-aws|lang
containers|podman/docker aliases|redxtech/zsh-containers|lang
sdkman|sdkman installer + completions|ptavares/zsh-sdkman|lang
evalcache|Cache slow eval init|mroth/evalcache|lang
zsh-deno|deno aliases/settings|cowboyd/zsh-deno|lang
zsh-tmux|tmux integration|zsh-contrib/zsh-tmux|lang
undollar|Strip $ from pasted prompt|zpm-zsh/undollar|misc
emoji-cli|Emoji completion|b4b4r07/emoji-cli|misc
zsh-emojis|ASCII emoji variables|MichaelAquilina/zsh-emojis|misc
title|Set terminal window title|zpm-zsh/title|misc
docker-helpers|Docker helper scripts|unixorn/docker-helpers.zshplugin|misc
warhol|grc colorization|unixorn/warhol.plugin.zsh|misc
claude-shell|AI shell assistance (Claude)|myk-org/claude-shell|misc
zsh-expand|Expand aliases/spellings/globals|MenkeTechnologies/zsh-expand|misc
appup|start/stop/up/down for compose/Vagrant|Cloudstek/zsh-plugin-appup|misc
check-deps|Show how to install missing deps|zpm-zsh/check-deps|misc
clipboard|Cross-platform clipboard helper|zpm-zsh/clipboard|misc
almostontop|Clear output before next command|Valiev/almostontop|misc
EOF
)

# Best file to source for a plain-clone zsh plugin directory. Empty output
# means the layout is unusual and needs a manual look at the README.
zsh_plugin_file() { # <plugin-dir>
    local d="$1" name f cand=""
    [ -d "$d" ] || return 1
    name=$(basename "$d")
    [ -f "$d/$name.plugin.zsh" ] && { echo "$name.plugin.zsh"; return 0; }
    for f in "$d"/*.plugin.zsh; do
        [ -f "$f" ] && { basename "$f"; return 0; }
    done
    for f in "$d"/*.zsh; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
            *.plugin.zsh|*init*.zsh|*completion*.zsh|*compinit*|*alias*.zsh) continue ;;
        esac
        cand="$f"
    done
    [ -n "$cand" ] && { basename "$cand"; return 0; }
    return 1
}

azp_repo_for() { # <tag> -> owner/repo (empty if unknown)
    local line
    line=$(grep -m1 "^$1|" <<<"$AZP_CATALOG") || return 1
    cut -d'|' -f3 <<<"$line"
}

# Install/update selected AZP tags into the chosen setup.
# azp_apply <user> <home> <omz|zinit|plain> <tags...>
azp_apply() {
    local u="$1" h="$2" mgr="$3"; shift 3
    [ "$#" -gt 0 ] || return 0
    command -v git >/dev/null 2>&1 || pm_install git
    local rc="$h/.zshrc" tag repo dest srcf
    case "$mgr" in
        omz)
            local current add="" final
            current=" $(omb_current "$rc" plugins 2>/dev/null || true) "
            for tag in "$@"; do
                repo=$(azp_repo_for "$tag") || continue
                dest="$h/.oh-my-zsh/custom/plugins/$tag"
                fm_as_user "$u" "if [ -d '$dest/.git' ]; then git -C '$dest' pull --ff-only; else rm -rf '$dest'; git clone --depth 1 https://github.com/$repo.git '$dest'; fi"
                case "$current" in *" $tag "*) ;; *) add="$add $tag" ;; esac
            done
            if [ -n "$add" ]; then
                final="$current$add"
                if grep -qE '^plugins=\(' "$rc" 2>/dev/null; then
                    omb_set_array "$rc" plugins $final
                else
                    local tmp; tmp=$(mktemp)
                    { echo "plugins=($final)"; cat "$rc"; } > "$tmp" && mv "$tmp" "$rc" && chown "$u" "$rc" 2>/dev/null
                fi
            fi
            tui_msg "oh-my-zsh" "Selected plugins cloned into custom/plugins and\nappended to plugins=() in $rc" ;;
        zinit)
            {
                local l
                for tag in "$@"; do
                    repo=$(azp_repo_for "$tag") || continue
                    grep -q "zinit light $repo" "$rc" 2>/dev/null || echo "zinit light $repo"
                done
            } | write_marked_block "$rc" "azp zinit"
            chown "$u" "$rc" 2>/dev/null
            tui_msg "zinit" "zinit light lines written to $rc\nPlugins download on next zsh start." ;;
        plain)
            local lines="" first=1
            for tag in "$@"; do
                repo=$(azp_repo_for "$tag") || continue
                dest="$h/.local/share/zsh-plugins/$tag"
                fm_as_user "$u" "mkdir -p ~/.local/share/zsh-plugins; if [ -d '$dest/.git' ]; then git -C '$dest' pull --ff-only; else rm -rf '$dest'; git clone --depth 1 https://github.com/$repo.git '$dest'; fi"
                srcf=$(zsh_plugin_file "$dest") || { warn "No loadable .zsh file found for $tag — check its README."; continue; }
                if [ "$first" = 1 ]; then
                    lines="source ~/.local/share/zsh-plugins/$tag/$srcf"; first=0
                else
                    lines="$lines
source ~/.local/share/zsh-plugins/$tag/$srcf"
                fi
            done
            [ -n "$lines" ] && printf '%s\n' "$lines" | write_marked_block "$rc" "azp plugins" && chown "$u" "$rc" 2>/dev/null
            tui_msg "Plain zsh" "Plugins cloned to ~/.local/share/zsh-plugins and\nsourced from $rc (systui azp plugins block)." ;;
    esac
}

menu_azp_pick() { # <user> <home> <omz|zinit|plain> <category|all>
    local u="$1" h="$2" mgr="$3" cat="$4"
    local args=() tag desc repo catname state sel
    while IFS='|' read -r tag desc repo catname; do
        [ -z "$tag" ] && continue
        [ "$cat" != all ] && [ "$catname" != "$cat" ] && continue
        state=off
        case "$mgr" in
            omz)   [ -d "$h/.oh-my-zsh/custom/plugins/$tag" ] && state=on ;;
            zinit) grep -q "zinit light $repo" "$h/.zshrc" 2>/dev/null && state=on ;;
            plain) grep -Fq "zsh-plugins/$tag" "$h/.zshrc" 2>/dev/null && state=on ;;
        esac
        args+=("$tag" "$desc — $repo" "$state")
    done <<<"$AZP_CATALOG"
    [ ${#args[@]} -eq 0 ] && { tui_msg "Empty" "No plugins in this category."; return 0; }
    sel=$(tui_check "Zsh plugins — $mgr ($cat)" "Installed pre-checked. SPACE toggles, ENTER applies:" "${args[@]}") || return 0
    sel=${sel//\"/}
    [ -z "$sel" ] && return 0
    azp_apply "$u" "$h" "$mgr" $sel
}

menu_azp_category() { # <user> <home> <omz|zinit|plain>
    local u="$1" h="$2" mgr="$3" c
    while true; do
        c=$(tui_menu "Zsh plugins — awesome-zsh-plugins ($mgr)" "Curated from unixorn/awesome-zsh-plugins. Choose a category:" \
            nav "Navigation — cd, jumping, directories" \
            hist "History — search, filter, sync" \
            git "Git — helpers, PRs, worktrees" \
            comp "Completion — menus, abbreviations, fzf" \
            vi "Vi-mode — motions, text objects" \
            alias "Aliases — tips, expanders" \
            prompt "Prompt & widgets — timers, notify, titles" \
            lang "Languages & tooling — asdf, venv, k8s, cloud" \
            misc "Miscellaneous — clipboard, emoji, helpers" \
            all "All categories (space-select)" \
            back "Back") || return 0
        case "$c" in
            back|"") return 0 ;;
            *) menu_azp_pick "$u" "$h" "$mgr" "$c" ;;
        esac
    done
}

menu_azp() { # <user> <home>
    local u="$1" h="$2" mgr
    mgr=$(tui_radio "awesome-zsh-plugins — $u" "Install selected plugins into which setup?" \
        omz "oh-my-zsh — custom/plugins + plugins=()" on \
        zinit "zinit — zinit light lines in .zshrc" off \
        plain "Plain Zsh — ~/.local/share/zsh-plugins + source" off) || return 0
    [ -n "$mgr" ] || return 0
    case "$mgr" in
        omz) [ -d "$h/.oh-my-zsh" ] || { tui_msg "Missing" "Install oh-my-zsh first (Managers ▸ Zsh ▸ oh-my-zsh)."; return 0; } ;;
        zinit) [ -d "$h/.local/share/zinit" ] || { tui_msg "Missing" "Install zinit first (Managers ▸ Zsh ▸ zinit)."; return 0; } ;;
    esac
    menu_azp_category "$u" "$h" "$mgr"
}

menu_shell_plugins() {
    local target u home_dir c
    target=$(shell_plugin_target) || return 0
    u=${target%%|*}; home_dir=${target#*|}
    while true; do
        c=$(tui_menu "Shell Plugins — $u" "Install, configure, inspect or remove cross-shell enhancements:" \
            starship "Starship prompt — installer, presets and shell integration" \
            fzf "fzf — key bindings, completion and default options" \
            comp "Completions — packages and shell initialization" \
            zoxide "zoxide — shell initialization and configuration" \
            atuin "Atuin — history initialization and config" \
            direnv "direnv — shell hooks and direnvrc" \
            carapace "Carapace — multi-shell completion initialization" \
            syntax "Zsh syntax highlighting — source and style settings" \
            autosuggest "Zsh autosuggestions — source and style settings" \
            github "More GitHub plugins — Bash, Zsh and Fish catalogue" \
            azp "awesome-zsh-plugins catalogue — curated Zsh plugins (space-select)" \
            user "Change target user" back "Back") || return 0
        case "$c" in
            starship) menu_plugin_starship "$u" "$home_dir" ;;
            fzf) menu_plugin_fzf "$u" "$home_dir" ;;
            comp) menu_plugin_completions "$u" "$home_dir" ;;
            zoxide) menu_plugin_simple_init "zoxide" zoxide zoxide 'eval "$(zoxide init bash)"' 'eval "$(zoxide init zsh)"' 'zoxide init fish | source' "$u" "$home_dir" "$home_dir/.config/zoxide/config.toml" ;;
            atuin) menu_plugin_simple_init "Atuin" atuin atuin 'eval "$(atuin init bash)"' 'eval "$(atuin init zsh)"' 'atuin init fish | source' "$u" "$home_dir" "$home_dir/.config/atuin/config.toml" ;;
            direnv) menu_plugin_simple_init "direnv" direnv direnv 'eval "$(direnv hook bash)"' 'eval "$(direnv hook zsh)"' 'direnv hook fish | source' "$u" "$home_dir" "$home_dir/.config/direnv/direnvrc" ;;
            carapace) menu_plugin_simple_init "Carapace" carapace carapace 'source <(carapace _carapace bash)' 'source <(carapace _carapace zsh)' 'carapace _carapace fish | source' "$u" "$home_dir" "$home_dir/.config/carapace/bridges.yaml" ;;
            syntax) menu_plugin_simple_init "Zsh syntax highlighting" zsh-syntax-highlighting zsh-syntax-highlighting '' '@detect:zsh-syntax-highlighting' '' "$u" "$home_dir" "$home_dir/.zshrc" ;;
            github) menu_shell_github_plugins "$u" "$home_dir" ;;
            azp) menu_azp "$u" "$home_dir" ;;
            autosuggest) menu_plugin_simple_init "Zsh autosuggestions" zsh-autosuggestions zsh-autosuggestions '' '@detect:zsh-autosuggestions' '' "$u" "$home_dir" "$home_dir/.zshrc" ;;
            user) target=$(shell_plugin_target) || continue; u=${target%%|*}; home_dir=${target#*|} ;;
            back|"") return 0 ;;
        esac
    done
}

# ---- Shell configuration and alias management ------------------------------
shellcfg_target() {
    local target
    target=$(shell_plugin_target) || return 1
    printf '%s\n' "$target"
}

shellcfg_file_for() { # shellcfg_file_for <kind> <home>
    case "$1" in
        bash)    printf '%s/.bashrc\n' "$2" ;;
        zsh)     printf '%s/.zshrc\n' "$2" ;;
        fish)    printf '%s/.config/fish/config.fish\n' "$2" ;;
        nuconfig) printf '%s/.config/nushell/config.nu\n' "$2" ;;
        nuenv)    printf '%s/.config/nushell/env.nu\n' "$2" ;;
        nulogin)  printf '%s/.config/nushell/login.nu\n' "$2" ;;
        profile) printf '%s/.profile\n' "$2" ;;
        bash_profile) printf '%s/.bash_profile\n' "$2" ;;
        zprofile) printf '%s/.zprofile\n' "$2" ;;
        inputrc) printf '%s/.inputrc\n' "$2" ;;
    esac
}

shellcfg_choose_file() { # shellcfg_choose_file <home>
    local h="$1"
    tui_menu "Shell config file" "Select a populated configuration target:" \
        bash ".bashrc — Bash interactive config $( [ -f "$h/.bashrc" ] && echo '[exists]' )" \
        zsh ".zshrc — Zsh interactive config $( [ -f "$h/.zshrc" ] && echo '[exists]' )" \
        fish "config.fish — Fish config $( [ -f "$h/.config/fish/config.fish" ] && echo '[exists]' )" \
        nuconfig "config.nu — Nushell startup config $( [ -f "$h/.config/nushell/config.nu" ] && echo '[exists]' )" \
        nuenv "env.nu — Nushell environment config $( [ -f "$h/.config/nushell/env.nu" ] && echo '[exists]' )" \
        nulogin "login.nu — Nushell login-shell config $( [ -f "$h/.config/nushell/login.nu" ] && echo '[exists]' )" \
        profile ".profile — POSIX login environment $( [ -f "$h/.profile" ] && echo '[exists]' )" \
        bash_profile ".bash_profile — Bash login config $( [ -f "$h/.bash_profile" ] && echo '[exists]' )" \
        zprofile ".zprofile — Zsh login config $( [ -f "$h/.zprofile" ] && echo '[exists]' )" \
        inputrc ".inputrc — Readline key bindings $( [ -f "$h/.inputrc" ] && echo '[exists]' )" \
        back "Back"
}

shellcfg_backup() { # file user
    local f="$1" u="$2" stamp backup
    [ -f "$f" ] || { tui_msg "Backup" "Nothing to back up: $f"; return 0; }
    stamp=$(date +%Y%m%d-%H%M%S)
    backup="$f.systui-$stamp.bak"
    cp -a "$f" "$backup" && chown "$u" "$backup" 2>/dev/null || true
    tui_msg "Backup created" "$backup"
}

shellcfg_validate() { # kind file
    local k="$1" f="$2" out rc=0
    [ -f "$f" ] || { tui_msg "Validation" "$f does not exist."; return 0; }
    out=$(mktemp)
    case "$k" in
        bash|profile|bash_profile) bash -n "$f" >"$out" 2>&1 || rc=$? ;;
        zsh|zprofile) if command -v zsh >/dev/null 2>&1; then zsh -n "$f" >"$out" 2>&1 || rc=$?; else printf 'zsh is not installed; syntax check unavailable.\n' >"$out"; rc=2; fi ;;
        fish) if command -v fish >/dev/null 2>&1; then fish -n "$f" >"$out" 2>&1 || rc=$?; else printf 'fish is not installed; syntax check unavailable.\n' >"$out"; rc=2; fi ;;
        nuconfig|nuenv|nulogin) if command -v nu >/dev/null 2>&1; then nu -n -c "source $(nu_quote "$f")" >"$out" 2>&1 || rc=$?; else printf 'nu is not installed; syntax check unavailable.\n' >"$out"; rc=2; fi ;;
        inputrc) printf 'Readline files do not provide a standalone syntax checker.\n' >"$out" ;;
    esac
    if [ "$rc" -eq 0 ]; then tui_msg "Validation passed" "$f contains no detected syntax errors."
    else tui_text "Validation result — $f" "$out"; fi
    rm -f "$out"
}

shellcfg_write_managed() { # kind file user selections editor pager hist_size
    local k="$1" f="$2" u="$3" selections="$4" editor="$5" pager="$6" hsize="$7" tmp
    mkdir -p "$(dirname "$f")"; touch "$f"
    tmp=$(mktemp)
    awk '/^# >>> systui shell settings >>>$/{skip=1;next}/^# <<< systui shell settings <<<$/{skip=0;next}!skip{print}' "$f" > "$tmp"
    {
        cat "$tmp"
        printf '\n# >>> systui shell settings >>>\n'
        case "$k" in
            fish)
                case " $selections " in *" history "*) printf 'set -gx fish_history default\n' ;; esac
                case " $selections " in *" editor "*) printf 'set -gx EDITOR %s\nset -gx VISUAL %s\n' "$editor" "$editor" ;; esac
                case " $selections " in *" pager "*) printf 'set -gx PAGER %s\n' "$pager" ;; esac
                case " $selections " in *" color "*) printf 'set -gx CLICOLOR 1\n' ;; esac
                case " $selections " in *" vi "*) printf 'fish_vi_key_bindings\n' ;; esac
                case " $selections " in *" autocd "*) printf '# Fish changes to a directory when its path is entered.\n' ;; esac
                ;;
            nuconfig)
                case " $selections " in *" editor "*) printf '$env.config.buffer_editor = %s\n' "$(nu_quote "$editor")" ;; esac
                case " $selections " in *" pager "*) printf '$env.PAGER = %s\n' "$(nu_quote "$pager")" ;; esac
                case " $selections " in *" vi "*) printf '$env.config.edit_mode = "vi"\n' ;; esac
                ;;
            inputrc)
                case " $selections " in *" completion "*) printf 'set completion-ignore-case on\nset show-all-if-ambiguous on\n' ;; esac
                case " $selections " in *" vi "*) printf 'set editing-mode vi\n' ;; esac
                case " $selections " in *" color "*) printf 'set colored-stats on\nset visible-stats on\n' ;; esac
                ;;
            *)
                case " $selections " in *" history "*) printf 'export HISTSIZE=%s\nexport HISTFILESIZE=%s\n' "$hsize" "$((hsize * 2))"; [ "$k" = zsh ] && printf 'setopt APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS\n' || printf 'export HISTCONTROL=ignoreboth:erasedups\nshopt -s histappend 2>/dev/null || true\n' ;; esac
                case " $selections " in *" editor "*) printf 'export EDITOR=%q\nexport VISUAL=%q\n' "$editor" "$editor" ;; esac
                case " $selections " in *" pager "*) printf 'export PAGER=%q\n' "$pager" ;; esac
                case " $selections " in *" color "*) printf 'export CLICOLOR=1\nexport LS_COLORS="${LS_COLORS:-}"\n' ;; esac
                case " $selections " in *" completion "*) [ "$k" = zsh ] && printf 'autoload -Uz compinit && compinit\n' || printf '[[ $- == *i* ]] && [ -r /usr/share/bash-completion/bash_completion ] && source /usr/share/bash-completion/bash_completion\n' ;; esac
                case " $selections " in *" autocd "*) [ "$k" = zsh ] && printf 'setopt AUTO_CD\n' || printf 'shopt -s autocd 2>/dev/null || true\n' ;; esac
                case " $selections " in *" glob "*) [ "$k" = zsh ] && printf 'setopt EXTENDED_GLOB GLOB_DOTS\n' || printf 'shopt -s globstar dotglob 2>/dev/null || true\n' ;; esac
                case " $selections " in *" correction "*) [ "$k" = zsh ] && printf 'setopt CORRECT\n' ;; esac
                case " $selections " in *" vi "*) [ "$k" = zsh ] && printf 'bindkey -v\n' || printf 'set -o vi\n' ;; esac
                ;;
        esac
        printf '# <<< systui shell settings <<<\n'
    } > "$f"
    rm -f "$tmp"
    chown "$u" "$f" 2>/dev/null || true
}

shellcfg_populated_entries() { # kind file user
    local k="$1" f="$2" u="$3" selected editor pager hsize
    case "$k" in
        nuconfig)
            selected=$(tui_check "Shell settings" "SPACE selects entries to automatically populate in $(basename "$f"):" \
                editor "buffer_editor" on \
                pager "PAGER" off \
                vi "Vi editing mode" off) || return 0
            selected=${selected//\"/}
            editor=$(tui_input "Default editor" "Command for buffer_editor:" "${EDITOR:-nano}") || return 0
            pager=$(tui_input "Default pager" "Command for PAGER:" "less") || return 0
            shellcfg_backup "$f" "$u"
            shellcfg_write_managed "$k" "$f" "$u" "$selected" "$editor" "$pager" 10000
            shellcfg_validate "$k" "$f"
            ;;
        nuenv|nulogin)
            tui_msg "Nushell config" "Use Edit to work with $(basename "$f") directly.\nPopulate is only provided for config.nu."
            return 0 ;;
        *)
            selected=$(tui_check "Shell settings" "SPACE selects entries to automatically populate in $(basename "$f"):" \
                history "Persistent history, duplicate filtering and append mode" on \
                editor "EDITOR and VISUAL environment variables" on \
                pager "Default PAGER" off \
                color "Color-aware command environment" on \
                completion "Programmable/tab completion initialization" on \
                autocd "Change directory by entering a directory path" off \
                glob "Recursive and hidden-file globbing" off \
                correction "Command spelling correction (Zsh)" off \
                vi "Vi editing/key-binding mode" off) || return 0
            selected=${selected//\"/}
            editor=$(tui_input "Default editor" "Command for EDITOR and VISUAL:" "${EDITOR:-nano}") || return 0
            pager=$(tui_input "Default pager" "Command for PAGER:" "less") || return 0
            hsize=$(tui_input "History size" "Number of commands retained:" "10000") || return 0
            [[ "$hsize" =~ ^[0-9]+$ ]] || hsize=10000
            shellcfg_backup "$f" "$u"
            shellcfg_write_managed "$k" "$f" "$u" "$selected" "$editor" "$pager" "$hsize"
            shellcfg_validate "$k" "$f"
            ;;
    esac
}

menu_shell_config() {
    local target u home_dir k f c line
    target=$(shellcfg_target) || return 0; u=${target%%|*}; home_dir=${target#*|}
    while true; do
        k=$(shellcfg_choose_file "$home_dir") || return 0
        [ "$k" = back ] || [ -z "$k" ] && return 0
        f=$(shellcfg_file_for "$k" "$home_dir")
        while true; do
            c=$(tui_menu "Shell config — $(basename "$f")" "User: $u\nFile: $f" \
                populate "Populate common configuration entries" \
                add "Add a custom configuration line" \
                edit "Open in editor" \
                view "View current configuration" \
                validate "Validate syntax" \
                backup "Create timestamped backup" \
                reset "Remove only the systui-managed settings block" \
                file "Select another config file" user "Change target user" back "Back") || return 0
            case "$c" in
                populate) shellcfg_populated_entries "$k" "$f" "$u" ;;
                add) line=$(tui_input "Add entry" "Enter the exact configuration line:" "") || continue; [ -n "$line" ] && plugin_add_line "$f" "$line" "$u" ;;
                edit) mkdir -p "$(dirname "$f")"; touch "$f"; chown "$u" "$f" 2>/dev/null || true; safe_edit "$f" || true ;;
                view) [ -f "$f" ] && tui_text "$f" "$f" || tui_msg "Shell config" "$f does not exist yet." ;;
                validate) shellcfg_validate "$k" "$f" ;;
                backup) shellcfg_backup "$f" "$u" ;;
                reset) [ -f "$f" ] && sed -i '/^# >>> systui shell settings >>>$/,/^# <<< systui shell settings <<<$/{d}' "$f"; tui_msg "Done" "Removed the systui-managed settings block." ;;
                file) break ;;
                user) target=$(shellcfg_target) || continue; u=${target%%|*}; home_dir=${target#*|}; break ;;
                back|"") return 0 ;;
            esac
        done
    done
}

alias_file_for() { printf '%s/.config/systui/aliases.sh\n' "$1"; }

aliases_enable() { # user home
    local u="$1" h="$2" af rc
    af=$(alias_file_for "$h")
    mkdir -p "$(dirname "$af")"; touch "$af"; chown -R "$u" "$h/.config/systui" 2>/dev/null || true
    for rc in "$h/.bashrc" "$h/.zshrc" "$h/.profile"; do
        plugin_add_line "$rc" '[ -r "$HOME/.config/systui/aliases.sh" ] && . "$HOME/.config/systui/aliases.sh"' "$u"
    done
    mkdir -p "$h/.config/fish"; touch "$h/.config/fish/config.fish"
    plugin_add_line "$h/.config/fish/config.fish" 'test -r "$HOME/.config/systui/aliases.fish"; and source "$HOME/.config/systui/aliases.fish"' "$u"
}

alias_valid_name() { [[ "$1" =~ ^[A-Za-z_.][A-Za-z0-9_.-]*$ ]]; }

alias_set() { # file name command user
    local f="$1" n="$2" cmd="$3" u="$4" tmp escaped
    alias_valid_name "$n" || { tui_msg "Invalid alias" "Use letters, digits, underscore, dot or hyphen; do not begin with a digit."; return 1; }
    mkdir -p "$(dirname "$f")"; touch "$f"; tmp=$(mktemp)
    awk -v p="alias ${n}=" 'index($0,p)!=1{print}' "$f" > "$tmp" 2>/dev/null || true
    escaped=${cmd//\'/\'\\\'\'}
    printf "alias %s='%s'\n" "$n" "$escaped" >> "$tmp"
    mv "$tmp" "$f"; chown "$u" "$f" 2>/dev/null || true
}

alias_remove() { # file name
    local f="$1" n="$2" tmp
    [ -f "$f" ] || return 0; tmp=$(mktemp)
    awk -v p="alias ${n}=" 'index($0,p)!=1{print}' "$f" > "$tmp" || true
    cat "$tmp" > "$f"; rm -f "$tmp"
}

aliases_write_fish() { # shell aliases file -> fish aliases file user
    local sf="$1" ff="$2" u="$3"
    mkdir -p "$(dirname "$ff")"
    awk '
      /^alias [A-Za-z_][A-Za-z0-9_.-]*=/{
        line=$0; sub(/^alias /,"",line); name=line; sub(/=.*/,"",name);
        cmd=line; sub(/^[^=]*=/,"",cmd); gsub(/^\047|\047$/,"",cmd);
        gsub(/\047\\\047\047/,"\047",cmd);
        printf "alias %s %c%s%c\n", name, 39, cmd, 39
      }' "$sf" > "$ff"
    chown "$u" "$ff" 2>/dev/null || true
}

aliases_presets() { # file user
    local f="$1" u="$2" s item
    s=$(tui_check "Alias catalog" "SPACE selects aliases to install:" \
        ll "ll = ls -alF" on la "la = ls -A" off l "l = ls -CF" off \
        dotdot ".. = cd .." on dotdot2 "... = cd ../.." off \
        grep "grep = grep --color=auto" on dfh "dfh = df -h" off duh "duh = du -h" off \
        ports "ports = ss -tulpn" off myip "myip = hostname -I" off \
        update "update = distribution package update" off cls "cls = clear" off \
        mkdirp "mkdirp = mkdir -p" off path "path = print PATH one entry per line" off) || return 0
    s=${s//\"/}
    for item in $s; do
        case "$item" in
            ll) alias_set "$f" ll 'ls -alF' "$u";; la) alias_set "$f" la 'ls -A' "$u";; l) alias_set "$f" l 'ls -CF' "$u";;
            dotdot) alias_set "$f" .. 'cd ..' "$u";; dotdot2) alias_set "$f" ... 'cd ../..' "$u";;
            grep) alias_set "$f" grep 'grep --color=auto' "$u";; dfh) alias_set "$f" dfh 'df -h' "$u";; duh) alias_set "$f" duh 'du -h' "$u";;
            ports) alias_set "$f" ports 'ss -tulpn' "$u";; myip) alias_set "$f" myip 'hostname -I' "$u";; cls) alias_set "$f" cls 'clear' "$u";;
            mkdirp) alias_set "$f" mkdirp 'mkdir -p' "$u";; path) alias_set "$f" path 'printf "%s\\n" "${PATH//:/\\n}"' "$u";;
            update) case "$PM" in apt) alias_set "$f" update 'sudo apt update && sudo apt upgrade' "$u";; apk) alias_set "$f" update 'sudo apk update && sudo apk upgrade' "$u";; pacman) alias_set "$f" update 'sudo pacman -Syu' "$u";; dnf) alias_set "$f" update 'sudo dnf upgrade' "$u";; esac;;
        esac
    done
}

menu_aliases() {
    local target u home_dir f ff c n cmd src
    target=$(shellcfg_target) || return 0; u=${target%%|*}; home_dir=${target#*|}; f=$(alias_file_for "$home_dir"); ff="$home_dir/.config/systui/aliases.fish"
    aliases_enable "$u" "$home_dir"
    while true; do
        c=$(tui_menu "Alias manager" "User: $u\nAliases: $f" \
            presets "Install aliases from populated catalog" add "Add or replace an alias" remove "Remove an alias" \
            list "List managed aliases" edit "Edit aliases file directly" import "Import aliases from another file" \
            sync "Regenerate Fish-compatible aliases" enable "Enable alias file in shell configs" validate "Validate alias syntax" \
            user "Change target user" back "Back") || return 0
        case "$c" in
            presets) aliases_presets "$f" "$u"; aliases_write_fish "$f" "$ff" "$u" ;;
            add) n=$(tui_input "Alias name" "Name:" "ll") || continue; cmd=$(tui_input "Alias command" "Command executed by '$n':" "ls -alF") || continue; alias_set "$f" "$n" "$cmd" "$u" && aliases_write_fish "$f" "$ff" "$u" ;;
            remove) n=$(tui_input "Remove alias" "Alias name to remove:" "") || continue; [ -n "$n" ] && alias_remove "$f" "$n"; aliases_write_fish "$f" "$ff" "$u" ;;
            list) [ -s "$f" ] && tui_text "Managed aliases — $u" "$f" || tui_msg "Alias manager" "No managed aliases are defined." ;;
            edit) mkdir -p "$(dirname "$f")"; touch "$f"; safe_edit "$f" || true; chown "$u" "$f" 2>/dev/null || true; aliases_write_fish "$f" "$ff" "$u" ;;
            import) src=$(tui_input "Import aliases" "Path to a shell file containing alias lines:" "$home_dir/.bash_aliases") || continue; if [ -f "$src" ]; then grep '^alias [A-Za-z_.][A-Za-z0-9_.-]*=' "$src" >> "$f" || true; awk '!seen[$0]++' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; chown "$u" "$f" 2>/dev/null || true; aliases_write_fish "$f" "$ff" "$u"; else tui_msg "Import failed" "$src was not found."; fi ;;
            sync) aliases_write_fish "$f" "$ff" "$u"; tui_msg "Done" "Fish aliases regenerated at $ff" ;;
            enable) aliases_enable "$u" "$home_dir"; tui_msg "Done" "Managed aliases are sourced by Bash, Zsh, POSIX profile and Fish." ;;
            validate) if bash -n "$f" >${SYSTUI_TMP}/alias-check 2>&1; then tui_msg "Validation passed" "$f contains no Bash syntax errors."; else tui_text "Alias validation" ${SYSTUI_TMP}/alias-check; fi; rm -f ${SYSTUI_TMP}/alias-check ;;
            user) target=$(shellcfg_target) || continue; u=${target%%|*}; home_dir=${target#*|}; f=$(alias_file_for "$home_dir"); ff="$home_dir/.config/systui/aliases.fish"; aliases_enable "$u" "$home_dir" ;;
            back|"") return 0 ;;
        esac
    done
}


# ---- Unified key mapping configuration --------------------------------------
keymap_target_user() {
    local u h
    u=$(tui_input "Mapping user" "Configure mappings for which user?" "${SUDO_USER:-root}") || return 1
    h=$(user_home "$u"); [ -n "$h" ] || { tui_msg "Unknown user" "User '$u' was not found."; return 1; }
    printf '%s|%s\n' "$u" "$h"
}

keymap_append_block() { # file begin end line user
    local f="$1" begin="$2" end="$3" line="$4" u="$5"
    mkdir -p "$(dirname "$f")"; touch "$f"
    if ! grep -qF "$begin" "$f"; then printf '\n%s\n%s\n' "$begin" "$end" >> "$f"; fi
    sed -i "/$(printf '%s' "$end" | sed 's/[][\\.^$*+?{}|()]/\\&/g')/i\\$line" "$f"
    chown "$u":"$(id -gn "$u")" "$f" 2>/dev/null || true
}

menu_shell_mappings() {
    local target u h tool c key action f line
    target=$(keymap_target_user) || return 0; u=${target%%|*}; h=${target#*|}
    while true; do
        tool=$(tui_menu "Shell key mappings — $u" "Select a shell/input layer:" bash "Bash Readline (.inputrc)" zsh "Zsh ZLE (.zshrc)" fish "Fish bind commands (config.fish)" global "System Readline (/etc/inputrc)" back "Back") || return 0
        [ "$tool" = back ] && return 0
        c=$(tui_menu "$tool mappings" "Mapping actions:" presets "Install useful mapping presets" add "Add a custom mapping" edit "Edit mapping file" show "Show current mapping file" back "Back") || continue
        case "$tool" in bash) f="$h/.inputrc";; zsh) f="$h/.zshrc";; fish) f="$h/.config/fish/config.fish";; global) f=/etc/inputrc;; esac
        case "$c" in
            presets)
                case "$tool" in
                    bash|global) keymap_append_block "$f" '# systui-keymaps begin' '# systui-keymaps end' '"\\C-p": history-search-backward' "$u"; keymap_append_block "$f" '# systui-keymaps begin' '# systui-keymaps end' '"\\C-n": history-search-forward' "$u"; keymap_append_block "$f" '# systui-keymaps begin' '# systui-keymaps end' 'set completion-ignore-case on' "$u";;
                    zsh) keymap_append_block "$f" '# systui-keymaps begin' '# systui-keymaps end' "bindkey '^P' history-substring-search-up" "$u"; keymap_append_block "$f" '# systui-keymaps begin' '# systui-keymaps end' "bindkey '^N' history-substring-search-down" "$u"; keymap_append_block "$f" '# systui-keymaps begin' '# systui-keymaps end' "bindkey '^A' beginning-of-line" "$u";;
                    fish) keymap_append_block "$f" '# systui-keymaps begin' '# systui-keymaps end' 'bind \\cp up-or-search' "$u"; keymap_append_block "$f" '# systui-keymaps begin' '# systui-keymaps end' 'bind \\cn down-or-search' "$u"; keymap_append_block "$f" '# systui-keymaps begin' '# systui-keymaps end' 'bind \\cf forward-char' "$u";;
                esac; tui_msg "Mappings installed" "Useful mappings were added to $f.";;
            add)
                key=$(tui_input "Key sequence" "Key sequence (examples: \\C-g, ^G, \\cg):" "") || continue
                action=$(tui_input "Mapping action" "Command/widget/action:" "") || continue
                [ -n "$key" ] && [ -n "$action" ] || continue
                case "$tool" in bash|global) line="\"$key\": $action";; zsh) line="bindkey '$key' '$action'";; fish) line="bind $key $action";; esac
                keymap_append_block "$f" '# systui-keymaps begin' '# systui-keymaps end' "$line" "$u";;
            edit) mkdir -p "$(dirname "$f")"; touch "$f"; safe_edit "$f" || true;;
            show) [ -f "$f" ] && tui_text "$tool mappings" "$f" || tui_msg "Mappings" "$f does not exist.";;
        esac
    done
}

editor_mapping_file() { local e="$1" h="$2"; case "$e" in nano) echo "$h/.nanorc";; vim) echo "$h/.vimrc";; nvim) echo "$h/.config/nvim/init.lua";; micro) echo "$h/.config/micro/bindings.json";; emacs) echo "$h/.emacs.d/init.el";; helix) echo "$h/.config/helix/config.toml";; esac; }
menu_editor_mappings() {
    local target u h e c f key action line
    target=$(keymap_target_user) || return 0; u=${target%%|*}; h=${target#*|}
    while true; do
        e=$(tui_menu "Editor key mappings — $u" "Select editor:" nano "Nano" vim "Vim" nvim "Neovim" micro "Micro" emacs "Emacs" helix "Helix" back "Back") || return 0
        [ "$e" = back ] && return 0; f=$(editor_mapping_file "$e" "$h")
        c=$(tui_menu "$e mappings" "Mapping actions:" add "Add custom mapping" edit "Edit mapping file" show "Show mapping file" back "Back") || continue
        case "$c" in
            add)
                key=$(tui_input "Key" "Native key notation for $e:" "") || continue; action=$(tui_input "Action" "Native command/action for $e:" "") || continue
                [ -n "$key" ] && [ -n "$action" ] || continue
                case "$e" in nano) line="bind $key $action main";; vim) line="nnoremap $key $action";; nvim) line="vim.keymap.set('n', '$key', '$action', { silent = true })";; micro) line="  \"$key\": \"$action\"";; emacs) line="(global-set-key (kbd \"$key\") '$action)";; helix) line="$key = \"$action\"";; esac
                mkdir -p "$(dirname "$f")"; touch "$f"
                if [ "$e" = micro ]; then
                    if [ ! -s "$f" ]; then printf '{\n%s\n}\n' "$line" > "$f"; else sed -i '$d' "$f"; sed -i '$s/$/,/' "$f"; printf '%s\n}\n' "$line" >> "$f"; fi
                elif [ "$e" = helix ]; then grep -q '^\[keys.normal\]' "$f" || printf '\n[keys.normal]\n' >> "$f"; printf '%s\n' "$line" >> "$f"
                else printf '\n%s\n' "$line" >> "$f"; fi
                chown -R "$u":"$(id -gn "$u")" "$(dirname "$f")" 2>/dev/null || true;;
            edit) mkdir -p "$(dirname "$f")"; touch "$f"; safe_edit "$f" || true;;
            show) [ -f "$f" ] && tui_text "$e mappings" "$f" || tui_msg "Mappings" "$f does not exist.";;
        esac
    done
}

fm_mapping_file() { local fm="$1" h="$2"; case "$fm" in mc) echo "$h/.config/mc/mc.keymap";; lf) echo "$h/.config/lf/lfrc";; tere) echo "$h/.config/tere/keybindings.conf";; yazi) echo "$h/.config/yazi/keymap.toml";; ranger) echo "$h/.config/ranger/rc.conf";; nnn) echo "$h/.config/nnn/keybinds.conf";; vifm) echo "$h/.config/vifm/vifmrc";; broot) echo "$h/.config/broot/conf.hjson";; xplr) echo "$h/.config/xplr/init.lua";; esac; }
menu_file_manager_mappings() {
    local fm="$1" target u h f c key action line
    target=$(keymap_target_user) || return 0; u=${target%%|*}; h=${target#*|}; f=$(fm_mapping_file "$fm" "$h")
    while true; do
        c=$(tui_menu "$fm key mappings — $u" "Configure native key mappings:" add "Add custom mapping" edit "Edit mapping file" show "Show mapping file" reset "Remove systui custom mapping block" back "Back") || return 0
        case "$c" in
            add)
                key=$(tui_input "Key" "Native key notation for $fm:" "") || continue; action=$(tui_input "Action" "Native command/action for $fm:" "") || continue
                [ -n "$key" ] && [ -n "$action" ] || continue
                case "$fm" in lf|ranger|vifm) line="map $key $action";; yazi) line="[[manager.prepend_keymap]]\non = [ \"$key\" ]\nrun = \"$action\"\ndesc = \"systui custom mapping\"";; xplr) line="xplr.config.modes.builtin.default.key_bindings.on_key['$key'] = { help = 'custom', messages = { '$action' } }";; tere|nnn|broot) line="# $key -> $action";; esac
                mkdir -p "$(dirname "$f")"; touch "$f"; printf '\n# systui-custom-keymap begin\n%b\n# systui-custom-keymap end\n' "$line" >> "$f"; chown -R "$u":"$(id -gn "$u")" "$(dirname "$f")" 2>/dev/null || true
                [ "$fm" = tere ] || [ "$fm" = nnn ] || [ "$fm" = broot ] && tui_msg "Mapping note" "$fm does not expose a stable universal per-key config syntax in all packaged versions. The mapping was recorded in $f for manual adaptation.";;
            edit) mkdir -p "$(dirname "$f")"; touch "$f"; safe_edit "$f" || true;;
            show) [ -f "$f" ] && tui_text "$fm mappings" "$f" || tui_msg "Mappings" "$f does not exist.";;
            reset) [ -f "$f" ] && sed -i '/^# systui-custom-keymap begin$/,/^# systui-custom-keymap end$/d' "$f";;
            back|"") return 0;;
        esac
    done
}

menu_set_default_shell() {
    local u sh sh_path cur_shell args=() bin

    u=$(tui_input "Set default shell" "Change login shell for which user?" "${SUDO_USER:-root}") || return 0
    id "$u" >/dev/null 2>&1 || { tui_msg "Error" "User '$u' not found on this system."; return; }

    cur_shell=$(basename "$(getent passwd "$u" 2>/dev/null | cut -d: -f7)")

    # Build the radio list from every shell binary we know about, filtering to
    # only those actually present in PATH on this system.
    for sh in bash zsh fish nu ksh mksh dash tcsh csh elvish xonsh yash pwsh sh; do
        bin=$(command -v "$sh" 2>/dev/null) || continue
        local label="$sh  ($bin)"
        [ "$sh" = "$cur_shell" ] && label="$sh  ($bin)  ← current" \
                                 && args+=("$sh" "$label" on) \
                                 || args+=("$sh" "$label" off)
    done

    [ ${#args[@]} -eq 0 ] && { tui_msg "No shells" "No supported shells were found in PATH."; return; }

    sh=$(tui_radio "Set default shell — $u" \
        "Current shell: ${cur_shell:-unknown}\nSPACE selects the new default login shell for $u:" \
        "${args[@]}") || return 0
    [ -z "$sh" ] && return

    sh_path=$(command -v "$sh" 2>/dev/null)
    [ -n "$sh_path" ] || { tui_msg "Not found" "'$sh' is not available in PATH."; return; }

    # chsh requires the target shell to be listed in /etc/shells
    if ! grep -qxF "$sh_path" /etc/shells 2>/dev/null; then
        tui_yesno "Add to /etc/shells?" \
"$sh_path is not listed in /etc/shells.
chsh requires all valid login shells to appear there.
Add it now?" || return
        echo "$sh_path" >> /etc/shells
    fi

    if command -v chsh >/dev/null 2>&1; then
        run_cmd "Set login shell of $u to $sh" chsh -s "$sh_path" "$u"
    else
        run_cmd "Set login shell of $u to $sh" usermod -s "$sh_path" "$u"
    fi
}

menu_shells() {
    while true; do
        local c
        c=$(tui_menu "Shells & Plugins" "Shell environment:" \
            managers "Managers (install, remove and configure each shell)" \
            config "Shell config files (.bashrc, .zshrc, config.fish, config.nu and profiles)" \
            aliases "Alias manager (catalog, custom aliases, import and validation)" \
            mappings "Key mapping configuration (Bash, Zsh, Fish, Readline)" \
            plugins "Plugins (Starship, fzf, completions and more)" \
            tmux "tmux — configuration & plugin management" \
            readline "Readline/inputrc tuning" \
            default "Set default shell" advanced "Advanced shell settings" back "Back") || return 0
        case "$c" in
            managers) menu_shell_hierarchy ;;
            # "history" and "bashopts" used to be separate entries here: the
            # first only printed a message pointing at this menu item, and the
            # second called menu_shell_config too. Both are covered by
            # "Populate common configuration entries" inside it.
            config) menu_shell_config ;;
            aliases) menu_aliases ;;
            mappings) menu_shell_mappings ;;
            plugins) menu_shell_plugins ;;
            tmux)
                local _tu _th
                _tu=$(tui_input "tmux" "Manage tmux for which user?" "${SUDO_USER:-root}") || continue
                _th=$(user_home "$_tu"); [ -n "$_th" ] || { tui_msg "Error" "User '$_tu' was not found."; continue; }
                menu_tmux "$_tu" "$_th" ;;
            readline) safe_edit /etc/inputrc || true ;;
            default) menu_set_default_shell ;;
            advanced) menu_shell_advanced ;;
            back|"") return 0 ;;
        esac
    done
}

# ---- 2.3 Editors -----------------------------------------------------------
menu_editors() {
    while true; do
        local c
        c=$(tui_menu "Editors" "Text editors:" \
            install "Install editors (nano, vim, neovim...)" \
            nanocfg "Configure nano (line numbers, indent, tabs)" \
            vimcfg  "Configure vim (sane system-wide defaults)" \
            nvimcfg "Configure neovim (basic init.lua, per-user)" \
            microcfg "Configure micro (tabsize, colorscheme)" \
            mappings "Key mapping configuration for all supported editors" \
            default "Set system default \$EDITOR" \
            advanced "Advanced (vim-plug, syntax highlighting, alternatives)" \
            back    "Back") || return 0
        case "$c" in
            install)
                local s
                s=$(tui_check "Editors" "Install (SPACE toggles):" \
                    nano "Nano $(st nano)" off \
                    vim "Vim $(st vim)" off \
                    neovim "Neovim $(st nvim)" off \
                    micro "Micro $(st micro)" off \
                    emacs "Emacs $(st emacs)" off) || continue
                s=${s//\"/}
                [ -z "${s// }" ] && continue
                # Dispatch to dedicated install menus for neovim and micro
                local bulk_s="$s"
                case " $bulk_s " in *" neovim "*) menu_neovim_install; bulk_s="${bulk_s/neovim/}"; bulk_s="${bulk_s//  / }"; bulk_s="${bulk_s# }"; bulk_s="${bulk_s% }" ;; esac
                case " $bulk_s " in *" micro "*)  menu_micro_install;  bulk_s="${bulk_s/micro/}";  bulk_s="${bulk_s//  / }"; bulk_s="${bulk_s# }"; bulk_s="${bulk_s% }" ;; esac
                if [ -n "${bulk_s// }" ]; then
                    local mapped; mapped=$(local_pkg_map $bulk_s)
                    show_warnings
                    if [ -n "${mapped// }" ]; then local -a _pkgs=(); parse_package_input "$mapped" _pkgs && pm_install "${_pkgs[@]}"; fi
                fi ;;
            nanocfg)
                touch /etc/nanorc
                local opts
                nst() { grep -q "^set $1" /etc/nanorc && echo on || echo off; }
                opts=$(tui_check "nano config (/etc/nanorc)" \
                    "Current settings pre-checked. SPACE toggles, ENTER applies\n(unchecking REMOVES the setting):" \
                    linenumbers "Show line numbers" "$(nst linenumbers)" \
                    autoindent  "Auto-indent" "$(nst autoindent)" \
                    tabstospaces "Tabs insert spaces (width 4)" "$(nst tabstospaces)" \
                    softwrap    "Soft-wrap long lines" "$(nst softwrap)" \
                    mouse       "Mouse support" "$(nst mouse)" \
                    smarthome   "Smart Home key" "$(nst smarthome)") || continue
                opts=" ${opts//\"/} "
                local o
                for o in linenumbers autoindent tabstospaces softwrap mouse smarthome; do
                    case "$opts" in
                        *" $o "*)
                            grep -q "^set $o" /etc/nanorc || echo "set $o" >> /etc/nanorc
                            [ "$o" = tabstospaces ] && { grep -q '^set tabsize' /etc/nanorc || echo "set tabsize 4" >> /etc/nanorc; } ;;
                        *)
                            sed -i "/^set $o$/d" /etc/nanorc
                            [ "$o" = tabstospaces ] && sed -i '/^set tabsize/d' /etc/nanorc ;;
                    esac
                done
                tui_msg "Done" "/etc/nanorc now matches your selection." ;;
            vimcfg)
                local vf="/etc/vim/vimrc.local"
                [ -d /etc/vim ] || vf="/etc/vimrc.local"
                touch "$vf"
                local vsel
                vst() { grep -q "$1" "$vf" && echo on || echo off; }
                vsel=$(tui_check "vim config ($vf)" \
                    "Current settings pre-checked. SPACE toggles, ENTER rewrites the file:" \
                    syntax  "Syntax highlighting" "$(vst '^syntax on')" \
                    number  "Line numbers" "$(vst '^set number')" \
                    indent  "Auto-indent" "$(vst '^set autoindent')" \
                    tabs4   "4-space tabs (expandtab)" "$(vst 'tabstop=4')" \
                    search  "Highlight + incremental search" "$(vst hlsearch)" \
                    nomouse "Disable mouse capture" "$(vst '^set mouse=$')") || continue
                vsel=" ${vsel//\"/} "
                {
                    echo '" systui vim defaults (managed — re-run the menu to change)'
                    case "$vsel" in *" syntax "*)  echo "syntax on" ;; esac
                    case "$vsel" in *" number "*)  echo "set number" ;; esac
                    case "$vsel" in *" indent "*)  echo "set autoindent" ;; esac
                    case "$vsel" in *" tabs4 "*)   echo "set tabstop=4 shiftwidth=4 expandtab" ;; esac
                    case "$vsel" in *" search "*)  echo "set hlsearch incsearch" ;; esac
                    case "$vsel" in *" nomouse "*) echo "set mouse=" ;; esac
                } > "$vf"
                tui_msg "Done" "$vf rewritten to match your selection.\n(Debian sources vimrc.local automatically; elsewhere add\n'source $vf' to the system vimrc.)" ;;
            nvimcfg)
                local u home_dir
                u=$(tui_input "User" "Configure neovim for which user?" "${SUDO_USER:-root}") || continue
                home_dir=$(user_home "$u"); [ -z "$home_dir" ] && { tui_msg "Error" "User $u not found."; continue; }
                if [ -s "$home_dir/.config/nvim/init.lua" ] && \
                   ! grep -q "systui basic neovim config" "$home_dir/.config/nvim/init.lua"; then
                    tui_yesno "Existing config" "$u already has a hand-written init.lua.\nOverwrite it with the systui basic config?" || continue
                fi
                mkdir -p "$home_dir/.config/nvim"
                cat > "$home_dir/.config/nvim/init.lua" <<'EOF'
-- systui basic neovim config
vim.opt.number = true
vim.opt.relativenumber = false
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true
vim.opt.smartindent = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.termguicolors = true
vim.opt.mouse = ""
EOF
                chown -R "$u" "$home_dir/.config/nvim"
                tui_msg "Done" "Basic init.lua written for $u.\nFor a full setup, consider kickstart.nvim." ;;
            mappings) menu_editor_mappings ;;
            microcfg)
                local u home_dir ts
                u=$(tui_input "User" "Configure micro for which user?" "${SUDO_USER:-root}") || continue
                home_dir=$(user_home "$u"); [ -z "$home_dir" ] && { tui_msg "Error" "User $u not found."; continue; }
                local cur_ts
                cur_ts=$(grep -o '"tabsize": *[0-9]*' "$home_dir/.config/micro/settings.json" 2>/dev/null | grep -o '[0-9]*')
                ts=$(tui_input "micro" "Tab size (current: ${cur_ts:-unset}):" "${cur_ts:-4}") || continue
                mkdir -p "$home_dir/.config/micro"
                cat > "$home_dir/.config/micro/settings.json" <<EOF
{
    "tabsize": $ts,
    "tabstospaces": true,
    "autoindent": true,
    "colorscheme": "default"
}
EOF
                chown -R "$u" "$home_dir/.config/micro"
                tui_msg "Done" "micro settings written for $u." ;;
            default)
                local e cur_ed
                cur_ed=$(grep -m1 '^EDITOR=' /etc/profile.d/editor.sh 2>/dev/null | cut -d= -f2)
                [ -z "$cur_ed" ] && cur_ed="${EDITOR:-nano}"
                est() { [ "$1" = "$cur_ed" ] && echo on || echo off; }
                e=$(tui_radio "Default editor" "Current default ($cur_ed) pre-selected. SPACE to change:" \
                    nano "nano $(st nano)" "$(est nano)" \
                    vim "vim $(st vim)" "$(est vim)" \
                    nvim "neovim $(st nvim)" "$(est nvim)" \
                    micro "micro $(st micro)" "$(est micro)" \
                    emacs "emacs $(st emacs)" "$(est emacs)") || continue
                [ -z "$e" ] && continue
                printf 'EDITOR=%s\nVISUAL=%s\nexport EDITOR VISUAL\n' "$e" "$e" > /etc/profile.d/editor.sh
                command -v update-alternatives >/dev/null && \
                    update-alternatives --set editor "$(command -v $e)" 2>/dev/null
                tui_msg "Done" "Default editor set to $e (via /etc/profile.d/editor.sh).\nTakes effect on next login." ;;
            advanced) menu_editor_advanced ;;
            back) return 0 ;;
        esac
    done
}


menu_ssh_server() {
    local a v p f u key
    while true; do
        a=$(tui_menu "OpenSSH Server" "Installation, authentication, access and runtime management:" \
            install "Install, enable and start sshd" status "Service status and listening sockets" \
            harden "Apply validated hardening drop-in" port "Configure listen port/address" \
            auth "Authentication methods (password, keys, PAM)" rootlogin "Configure root login policy" \
            users "AllowUsers / DenyUsers access controls" keys "Manage authorized_keys for a user" \
            forwarding "X11, TCP and agent forwarding" keepalive "Client keepalive and idle timeout" \
            sftp "Configure internal-sftp subsystem" banners "Login banner and MOTD settings" \
            hostkeys "Generate/check SSH host keys" test "Validate configuration with sshd -t" \
            effective "View effective sshd configuration" logs "View recent SSH logs" \
            restart "Restart SSH service" back "Back") || return 0
        case "$a" in
            install) pm_install "$(local_pkg_map openssh-server)"; ssh-keygen -A 2>/dev/null || true; svc enable sshd 2>/dev/null || svc enable ssh; svc restart sshd 2>/dev/null || svc restart ssh ;;
            status) { svc status sshd 2>&1 || svc status ssh 2>&1; echo; ss -lntp 2>/dev/null | grep -E 'sshd|:22|:2222|:22000' || true; } > ${SYSTUI_TMP}/ssh; tui_text "SSH status" ${SYSTUI_TMP}/ssh ;;
            harden) mkdir -p /etc/ssh/sshd_config.d; cat > /etc/ssh/sshd_config.d/90-systui-hardening.conf <<'EOF'
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 30
PermitEmptyPasswords no
X11Forwarding no
AllowTcpForwarding local
ClientAliveInterval 300
ClientAliveCountMax 2
UseDNS no
EOF
                if sshd -t 2>${SYSTUI_TMP}/ssherr; then tui_msg "SSH" "Hardening drop-in installed and validated."; else rm -f /etc/ssh/sshd_config.d/90-systui-hardening.conf; tui_text "Validation failed; changes reverted" ${SYSTUI_TMP}/ssherr; fi ;;
            port) p=$(tui_input "SSH port" "Listen port (1-65535):" "22") || continue; case "$p" in ''|*[!0-9]*) tui_msg "Invalid" "Port must be numeric."; continue;; esac; [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { tui_msg "Invalid" "Port must be 1-65535."; continue; }; mkdir -p /etc/ssh/sshd_config.d; printf 'Port %s\n' "$p" > /etc/ssh/sshd_config.d/20-systui-listen.conf; sshd -t && tui_msg "SSH" "Port set to $p. Restart to apply." ;;
            auth) v=$(tui_check "SSH authentication" "SPACE selects enabled methods:" password "PasswordAuthentication" on pubkey "PubkeyAuthentication" on pam "UsePAM" on keyboard "KbdInteractiveAuthentication" off) || continue; mkdir -p /etc/ssh/sshd_config.d; { for f in password pubkey pam keyboard; do case " $v " in *" $f "*) x=yes;; *) x=no;; esac; case "$f" in password) echo "PasswordAuthentication $x";; pubkey) echo "PubkeyAuthentication $x";; pam) echo "UsePAM $x";; keyboard) echo "KbdInteractiveAuthentication $x";; esac; done; } > /etc/ssh/sshd_config.d/30-systui-auth.conf; sshd -t || rm -f /etc/ssh/sshd_config.d/30-systui-auth.conf ;;
            rootlogin) v=$(tui_radio "Root login" "Select policy:" no "Disable root SSH login" on prohibit-password "Allow root with keys only" off yes "Allow root with password" off forced-commands-only "Only forced commands" off) || continue; mkdir -p /etc/ssh/sshd_config.d; echo "PermitRootLogin $v" > /etc/ssh/sshd_config.d/31-systui-root.conf; sshd -t || rm -f /etc/ssh/sshd_config.d/31-systui-root.conf ;;
            users) v=$(tui_input "SSH access control" "AllowUsers list (blank removes managed rule):" "") || continue; mkdir -p /etc/ssh/sshd_config.d; [ -n "$v" ] && echo "AllowUsers $v" > /etc/ssh/sshd_config.d/40-systui-users.conf || rm -f /etc/ssh/sshd_config.d/40-systui-users.conf; sshd -t || rm -f /etc/ssh/sshd_config.d/40-systui-users.conf ;;
            keys) u=$(tui_input "SSH keys" "User:" "${SUDO_USER:-root}") || continue; h=$(user_home "$u"); [ -n "$h" ] || continue; mkdir -p "$h/.ssh"; touch "$h/.ssh/authorized_keys"; chmod 700 "$h/.ssh"; chmod 600 "$h/.ssh/authorized_keys"; chown -R "$u":"$(id -gn "$u")" "$h/.ssh"; safe_edit "$h/.ssh/authorized_keys" ;;
            forwarding) v=$(tui_check "SSH forwarding" "SPACE selects enabled forwarding:" x11 "X11Forwarding" off tcp "AllowTcpForwarding" on agent "AllowAgentForwarding" on gateway "GatewayPorts" off) || continue; mkdir -p /etc/ssh/sshd_config.d; { for f in x11 tcp agent gateway; do case " $v " in *" $f "*) x=yes;; *) x=no;; esac; case "$f" in x11) echo "X11Forwarding $x";; tcp) echo "AllowTcpForwarding $x";; agent) echo "AllowAgentForwarding $x";; gateway) echo "GatewayPorts $x";; esac; done; } > /etc/ssh/sshd_config.d/50-systui-forwarding.conf; sshd -t || rm -f /etc/ssh/sshd_config.d/50-systui-forwarding.conf ;;
            keepalive) p=$(tui_input "Keepalive" "ClientAliveInterval seconds:" "300") || continue; v=$(tui_input "Keepalive" "ClientAliveCountMax:" "2") || continue; valid_uint "$p" && valid_uint "$v" && [ "$p" -le 86400 ] && [ "$v" -le 100 ] || { tui_msg "Invalid" "Keepalive values must be non-negative integers in range."; continue; }; mkdir -p /etc/ssh/sshd_config.d; tmp="$SYSTUI_TMP/ssh-keepalive.conf"; printf 'ClientAliveInterval %s\nClientAliveCountMax %s\nTCPKeepAlive yes\n' "$p" "$v" > "$tmp"; atomic_install_file "$tmp" /etc/ssh/sshd_config.d/60-systui-keepalive.conf; sshd -t 2>"$SYSTUI_TMP/ssherr" || { rm -f /etc/ssh/sshd_config.d/60-systui-keepalive.conf; tui_text "SSH validation failed" "$SYSTUI_TMP/ssherr"; } ;;
            sftp) 
                mkdir -p /etc/ssh/sshd_config.d
                cat > /etc/ssh/sshd_config.d/70-systui-sftp.conf <<'SFTP_EOF'
# Internal SFTP subsystem configuration
Subsystem sftp internal-sftp -f AUTHPRIV -l INFO

# Optional: chroot SFTP users to their home directory
# Uncomment and adjust Match block below to enable
# Match User sftp-only
#   ChrootDirectory %h
#   AllowTcpForwarding no
#   AllowAgentForwarding no
#   PermitTTY no
#   X11Forwarding no
#   ForceCommand internal-sftp -f AUTHPRIV -l INFO
SFTP_EOF
                if sshd -t 2>${SYSTUI_TMP}/ssherr; then 
                    tui_msg "SFTP subsystem" "Internal SFTP configured successfully.\nEnable chroot: edit /etc/ssh/sshd_config.d/70-systui-sftp.conf"
                else 
                    rm -f /etc/ssh/sshd_config.d/70-systui-sftp.conf
                    tui_text "SFTP validation failed" ${SYSTUI_TMP}/ssherr
                fi
                ;;
            banners) f=$(tui_input "SSH banner" "Banner file (blank disables):" "/etc/issue.net") || continue; mkdir -p /etc/ssh/sshd_config.d; if [ -n "$f" ]; then case "$f" in /etc/*) ;; *) tui_msg "Invalid path" "SSH banners must be stored under /etc/."; continue;; esac; [ ! -L "$f" ] || { tui_msg "Invalid path" "Refusing to edit a symbolic link."; continue; }; touch "$f"; safe_edit "$f"; echo "Banner $f" > /etc/ssh/sshd_config.d/80-systui-banner.conf; else rm -f /etc/ssh/sshd_config.d/80-systui-banner.conf; fi ;;
            hostkeys) ssh-keygen -A; ls -l /etc/ssh/ssh_host_* > ${SYSTUI_TMP}/ssh 2>&1; tui_text "SSH host keys" ${SYSTUI_TMP}/ssh ;;
            test) sshd -t > ${SYSTUI_TMP}/ssh 2>&1 && echo "Configuration valid." > ${SYSTUI_TMP}/ssh; tui_text "sshd validation" ${SYSTUI_TMP}/ssh ;;
            effective) sshd -T 2>/dev/null | sort > ${SYSTUI_TMP}/ssh; tui_text "Effective sshd configuration" ${SYSTUI_TMP}/ssh ;;
            logs) { journalctl -u ssh -u sshd -n 150 --no-pager 2>/dev/null || tail -n 150 /var/log/auth.log 2>/dev/null || tail -n 150 /var/log/secure 2>/dev/null; } > ${SYSTUI_TMP}/ssh; tui_text "SSH logs" ${SYSTUI_TMP}/ssh ;;
            restart) sshd -t && { svc restart sshd 2>/dev/null || svc restart ssh; } ;;
            back) return 0 ;;
        esac
    done
}

# ---- 2.4 Network -----------------------------------------------------------
# Extracted from menu_network so the quick-task menu can call them directly
# instead of duplicating the logic or forcing a three-level walk.
sysconfig_set_hostname() {
    local h
    h=$(tui_input "Hostname" "New hostname:" "$(hostname)") || return 0
    [ -n "$h" ] || return 0
    valid_safe_name "$h" || { tui_msg "Invalid hostname" "Use letters, digits, dots, dashes and underscores only."; return 0; }
    if command -v hostnamectl >/dev/null; then hostnamectl set-hostname "$h"
    else echo "$h" > /etc/hostname && hostname "$h"; fi
    tui_msg "Hostname" "Hostname set to $h.\nCheck /etc/hosts for a matching 127.0.1.1 entry."
}

sysconfig_set_timezone() {
    local tz
    tz=$(tui_input "Timezone" "IANA timezone (e.g. Europe/London, America/New_York,\nsee /usr/share/zoneinfo):" \
        "$(cat /etc/timezone 2>/dev/null || readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || echo UTC)") || return 0
    [ -n "$tz" ] || return 0
    [ -f "/usr/share/zoneinfo/$tz" ] || { tui_msg "Error" "Unknown timezone: $tz"; return 0; }
    if command -v timedatectl >/dev/null; then timedatectl set-timezone "$tz"
    else ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime; echo "$tz" > /etc/timezone 2>/dev/null; fi
    tui_msg "Done" "Timezone set to $tz."
}

menu_network() {
    while true; do
        local c
        c=$(tui_menu "Network" "Network services & settings:" \
            ssh      "OpenSSH server $(st sshd)" \
            fail2ban "fail2ban brute-force protection $(st fail2ban-server)" \
            vnc      "VNC server (TigerVNC / x11vnc)" \
            firewall "Firewall (ufw) $(st ufw)" \
            dns      "Configure DNS resolvers" \
            staticip "Static IP configuration" \
            proxy    "System-wide HTTP(S) proxy" \
            time     "Timezone & NTP time sync" \
            hostname "Change system hostname" \
            hosts    "View /etc/hosts" \
            ports    "Show listening ports" \
            info     "Show network interfaces" \
            advanced "Advanced (IPv6, MTU, Wake-on-LAN, forwarding)" \
            back     "Back") || return 0
        case "$c" in
            ssh) menu_ssh_server ;;
            fail2ban)
                local a
                a=$(tui_menu "fail2ban" "Action:" \
                    install "Install & enable with sshd jail" \
                    status  "Show jail status" \
                    unban   "Unban an IP") || continue
                case "$a" in
                    install)
                        pm_install fail2ban
                        cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
                        svc enable fail2ban; svc restart fail2ban
                        tui_msg "Done" "fail2ban enabled with an sshd jail\n(5 failures in 10 min = 1 h ban)." ;;
                    status)
                        { fail2ban-client status; echo; fail2ban-client status sshd; } > ${SYSTUI_TMP}/net 2>&1
                        tui_text "fail2ban status" ${SYSTUI_TMP}/net ;;
                    unban)
                        local ip; ip=$(tui_input "Unban" "IP address to unban:" "") || continue
                        [ -n "$ip" ] && run_cmd "Unbanning $ip" fail2ban-client set sshd unbanip "$ip" ;;
                esac ;;
            vnc)
                local v
                v=$(tui_radio "VNC" "Which server? (SPACE to select)" \
                    tigervnc "TigerVNC (own X session) $(st vncserver)" on \
                    x11vnc   "x11vnc (mirror existing display) $(st x11vnc)" off) || continue
                case "$v" in
                    tigervnc)
                        case "$PM" in
                            apt) pm_install tigervnc-standalone-server ;;
                            *)   pm_install tigervnc ;;
                        esac
                        tui_msg "TigerVNC" "Set a password with 'vncpasswd' as the target user,\nthen start with 'vncserver :1'." ;;
                    x11vnc)
                        pm_install x11vnc
                        tui_msg "x11vnc" "Run as the desktop user:\n  x11vnc -display :0 -usepw" ;;
                esac ;;
            firewall)
                command -v ufw >/dev/null || pm_install ufw
                local f
                f=$(tui_menu "ufw" "Action:" \
                    enable "Enable (allow SSH first!)" \
                    disable "Disable" \
                    allow "Allow a port" \
                    deny  "Deny a port" \
                    delete "Delete a rule (by number)" \
                    status "Show status (numbered)") || continue
                case "$f" in
                    enable)  run_cmd "ufw enable" bash -c "ufw allow OpenSSH 2>/dev/null; ufw --force enable" ;;
                    disable) run_cmd "ufw disable" ufw disable ;;
                    allow)   local p; p=$(tui_input "Allow port" "Port (e.g. 8080/tcp):" "") && [ -n "$p" ] && run_cmd "ufw allow $p" ufw allow "$p" ;;
                    deny)    local p; p=$(tui_input "Deny port" "Port (e.g. 23/tcp):" "") && [ -n "$p" ] && run_cmd "ufw deny $p" ufw deny "$p" ;;
                    delete)  local n; n=$(tui_input "Delete rule" "Rule number (see status):" "") && [ -n "$n" ] && run_cmd "ufw delete $n" bash -c "yes | ufw delete $n" ;;
                    status)  ufw status numbered > ${SYSTUI_TMP}/net 2>&1; tui_text "ufw status" ${SYSTUI_TMP}/net ;;
                esac ;;
            dns)
                local d
                d=$(tui_radio "DNS" "Resolver set (SPACE to select):" \
                    cloudflare "1.1.1.1 / 1.0.0.1" on \
                    google     "8.8.8.8 / 8.8.4.4" off \
                    quad9      "9.9.9.9 / 149.112.112.112" off \
                    custom     "Enter manually" off) || continue
                local ns1 ns2
                case "$d" in
                    cloudflare) ns1=1.1.1.1; ns2=1.0.0.1 ;;
                    google)     ns1=8.8.8.8; ns2=8.8.4.4 ;;
                    quad9)      ns1=9.9.9.9; ns2=149.112.112.112 ;;
                    custom)
                        ns1=$(tui_input "DNS" "Primary resolver:" "") || continue
                        ns2=$(tui_input "DNS" "Secondary resolver (optional):" "") || continue ;;
                    *) continue ;;
                esac
                if [ "$INIT" = systemd ] && systemctl is-active -q systemd-resolved 2>/dev/null; then
                    mkdir -p /etc/systemd/resolved.conf.d
                    printf '[Resolve]\nDNS=%s %s\n' "$ns1" "$ns2" > /etc/systemd/resolved.conf.d/90-systui.conf
                    systemctl restart systemd-resolved
                    tui_msg "DNS" "systemd-resolved configured: $ns1 $ns2"
                else
                    if [ -L /etc/resolv.conf ]; then
                        warn "/etc/resolv.conf is a symlink (managed by another tool); changes may be overwritten."
                    fi
                    cp /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%s)" 2>/dev/null
                    { echo "nameserver $ns1"; [ -n "$ns2" ] && echo "nameserver $ns2"; } > /etc/resolv.conf
                    show_warnings
                    tui_msg "DNS" "/etc/resolv.conf updated: $ns1 $ns2\n(Backup saved. NetworkManager/dhcpcd may rewrite this file.)"
                fi ;;
            staticip)
                local iface addr gw
                iface=$(tui_input "Static IP 1/3" "Interface (see 'Show network interfaces'):" "eth0") || continue
                addr=$(tui_input "Static IP 2/3" "Address with CIDR (e.g. 192.168.1.50/24):" "") || continue
                gw=$(tui_input "Static IP 3/3" "Gateway:" "") || continue
                [ -z "$iface" ] || [ -z "$addr" ] && continue
                if [ "$INIT" = systemd ] && command -v networkctl >/dev/null; then
                    cat > "/etc/systemd/network/90-systui-$iface.network" <<EOF
[Match]
Name=$iface

[Network]
Address=$addr
Gateway=$gw
EOF
                    tui_msg "Static IP" "Written to /etc/systemd/network/90-systui-$iface.network\nApply with:\n  systemctl enable --now systemd-networkd && networkctl reload\n\nWARNING: don't enable systemd-networkd if NetworkManager\nmanages this interface — pick one."
                elif [ -d /etc/network ]; then
                    mkdir -p /etc/network/interfaces.d
                    cat > "/etc/network/interfaces.d/systui-$iface" <<EOF
auto $iface
iface $iface inet static
    address $addr
    gateway $gw
EOF
                    tui_msg "Static IP" "Written to /etc/network/interfaces.d/systui-$iface\nApply with: ifdown $iface; ifup $iface (or reboot)."
                else
                    tui_msg "N/A" "No supported network config system found\n(systemd-networkd or ifupdown)."
                fi ;;
            proxy)
                local a
                a=$(tui_radio "Proxy" "Action (SPACE to select):" \
                    set "Set system-wide proxy" on \
                    unset "Remove proxy configuration" off) || continue
                case "$a" in
                    set)
                        local px npx
                        px=$(tui_input "Proxy" "Proxy URL (e.g. http://proxy.lan:3128):" "") || continue
                        [ -z "$px" ] && continue
                        npx=$(tui_input "Proxy" "No-proxy list:" "localhost,127.0.0.1,.local") || continue
                        cat > /etc/profile.d/92-systui-proxy.sh <<EOF
# systui proxy settings
export http_proxy="$px" https_proxy="$px" ftp_proxy="$px"
export HTTP_PROXY="$px" HTTPS_PROXY="$px" FTP_PROXY="$px"
export no_proxy="$npx" NO_PROXY="$npx"
EOF
                        [ "$PM" = apt ] && printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$px" "$px" \
                            > /etc/apt/apt.conf.d/95systui-proxy
                        tui_msg "Done" "Proxy set (env for login shells; apt config too if applicable).\nTakes effect on next login." ;;
                    unset)
                        rm -f /etc/profile.d/92-systui-proxy.sh /etc/apt/apt.conf.d/95systui-proxy
                        tui_msg "Done" "Proxy configuration removed." ;;
                esac ;;
            time)
                local a
                a=$(tui_menu "Time" "Timezone & NTP:" \
                    tz  "Set timezone (current: $(cat /etc/timezone 2>/dev/null || readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||'))" \
                    ntp "Enable NTP time sync" \
                    show "Show current time status") || continue
                case "$a" in
                    tz) sysconfig_set_timezone ;;
                    ntp)
                        if command -v timedatectl >/dev/null; then
                            run_cmd "Enabling systemd NTP" timedatectl set-ntp true
                        else
                            pm_install chrony && { svc enable chronyd 2>/dev/null || svc enable chrony; svc start chronyd 2>/dev/null || svc start chrony; }
                        fi ;;
                    show)
                        { timedatectl 2>/dev/null || date; } > ${SYSTUI_TMP}/net
                        tui_text "Time status" ${SYSTUI_TMP}/net ;;
                esac ;;
            hostname) sysconfig_set_hostname ;;
            hosts)
                tui_text "/etc/hosts" /etc/hosts ;;
            ports)
                { ss -tulnp 2>/dev/null || netstat -tulnp; } > ${SYSTUI_TMP}/net 2>&1
                tui_text "Listening ports" ${SYSTUI_TMP}/net ;;
            info)
                ip addr > ${SYSTUI_TMP}/net 2>&1 || ifconfig -a > ${SYSTUI_TMP}/net 2>&1
                tui_text "Interfaces" ${SYSTUI_TMP}/net ;;
            advanced) menu_net_advanced ;;
            back) return 0 ;;
        esac
    done
}

# ---- 2.5 Services ----------------------------------------------------------
menu_services() {
    while true; do
        local c
        c=$(tui_menu "Services  [init: $INIT]" "Service management:" \
            list    "List services" \
            failed  "Show failed services" \
            enable  "Enable a service (start at boot)" \
            disable "Disable a service" \
            start   "Start a service now" \
            stop    "Stop a service now" \
            restart "Restart a service" \
            status  "Show a service's status" \
            logs    "Show a service's recent logs" \
            mask    "Mask/unmask a service (systemd)" \
            unit    "View a service's unit/init file" \
            create  "Create a simple service (systemd unit)" \
            analyze "Boot time analysis (systemd)" \
            initswap "Switch init system on THIS machine" \
            advanced "Advanced (overrides, limits, timers, boot target)" \
            back    "Back") || return 0
        case "$c" in
            back) return 0 ;;
            list)
                case "$INIT" in
                    systemd)  systemctl list-units --type=service --no-pager > ${SYSTUI_TMP}/svc ;;
                    openrc)   rc-status -a > ${SYSTUI_TMP}/svc ;;
                    runit)    ls -1 /var/service /run/runit/service 2>/dev/null > ${SYSTUI_TMP}/svc ;;
                    sysvinit) service --status-all > ${SYSTUI_TMP}/svc 2>&1 ;;
                esac
                tui_text "Services ($INIT)" ${SYSTUI_TMP}/svc ;;
            failed)
                case "$INIT" in
                    systemd)  systemctl --failed --no-pager > ${SYSTUI_TMP}/svc ;;
                    openrc)   rc-status -c > ${SYSTUI_TMP}/svc 2>&1 ;;
                    *)        echo "Failed-unit listing supported on systemd/OpenRC only." > ${SYSTUI_TMP}/svc ;;
                esac
                tui_text "Failed services" ${SYSTUI_TMP}/svc ;;
            logs)
                local s; s=$(tui_input "Logs" "Service name:" "") || continue
                [ -z "$s" ] && continue
                if [ "$INIT" = systemd ]; then
                    journalctl -u "$s" -n 100 --no-pager > ${SYSTUI_TMP}/svc 2>&1
                else
                    { tail -100 "/var/log/$s.log" 2>/dev/null || grep -h "$s" /var/log/messages /var/log/syslog 2>/dev/null | tail -100; } > ${SYSTUI_TMP}/svc
                    [ -s ${SYSTUI_TMP}/svc ] || echo "(no logs found for $s)" > ${SYSTUI_TMP}/svc
                fi
                tui_text "Logs: $s" ${SYSTUI_TMP}/svc ;;
            mask)
                [ "$INIT" != systemd ] && { tui_msg "N/A" "Masking is a systemd concept."; continue; }
                local s a
                a=$(tui_radio "Mask" "Action (SPACE to select):" \
                    mask "Mask (make unstartable)" on \
                    unmask "Unmask" off) || continue
                s=$(tui_input "Mask" "Service name:" "") || continue
                [ -n "$s" ] && run_cmd "systemctl $a $s" systemctl "$a" "$s" ;;
            unit)
                local s; s=$(tui_input "Unit file" "Service name:" "") || continue
                [ -z "$s" ] && continue
                case "$INIT" in
                    systemd)  systemctl cat "$s" > ${SYSTUI_TMP}/svc 2>&1 ;;
                    openrc)   cat "/etc/init.d/$s" > ${SYSTUI_TMP}/svc 2>&1 ;;
                    runit)    cat "/etc/sv/$s/run" "/etc/runit/sv/$s/run" > ${SYSTUI_TMP}/svc 2>&1 ;;
                    sysvinit) cat "/etc/init.d/$s" > ${SYSTUI_TMP}/svc 2>&1 ;;
                esac
                tui_text "Unit: $s" ${SYSTUI_TMP}/svc ;;
            create)
                [ "$INIT" != systemd ] && { tui_msg "N/A" "Unit generator is systemd-only.\nFor OpenRC/runit/sysvinit, write scripts manually."; continue; }
                local n d x u
                n=$(tui_input "New service 1/4" "Service name (no spaces):" "myapp") || continue
                # $n is interpolated into /etc/systemd/system/$n.service, so a
                # name containing a slash or ".." wrote outside the unit dir.
                valid_safe_name "$n" || { tui_msg "Invalid name" "Use letters, digits, dots, dashes and underscores only."; continue; }
                [ -e "/etc/systemd/system/$n.service" ] && { tui_yesno "Overwrite?" "/etc/systemd/system/$n.service already exists.\n\nReplace it?" || continue; }
                d=$(tui_input "New service 2/4" "Description:" "My application") || continue
                x=$(tui_input "New service 3/4" "ExecStart (absolute path + args):" "/usr/local/bin/myapp") || continue
                u=$(tui_input "New service 4/4" "Run as user:" "root") || continue
                cat > "/etc/systemd/system/$n.service" <<EOF
[Unit]
Description=$d
After=network.target

[Service]
Type=simple
User=$u
ExecStart=$x
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                tui_yesno "Enable now?" "Unit written to /etc/systemd/system/$n.service\nEnable and start it now?" \
                    && run_cmd "Enabling $n" systemctl enable --now "$n" ;;
            analyze)
                [ "$INIT" != systemd ] && { tui_msg "N/A" "systemd-analyze requires systemd."; continue; }
                { systemd-analyze; echo; systemd-analyze blame | head -25; } > ${SYSTUI_TMP}/svc 2>&1
                tui_text "Boot analysis" ${SYSTUI_TMP}/svc ;;
            initswap) initswap_current ;;
            advanced) menu_svc_advanced ;;
            *)
                local s; s=$(tui_input "Service" "Service name:" "") || continue
                [ -z "$s" ] && continue
                if [ "$c" = status ]; then
                    svc status "$s" > ${SYSTUI_TMP}/svc 2>&1; tui_text "Status: $s" ${SYSTUI_TMP}/svc
                else
                    run_cmd "$c $s ($INIT)" svc "$c" "$s"
                fi ;;
        esac
    done
}

# Swap the init system on the RUNNING machine (Debian family only — the only
# family where this is a supported package operation).
initswap_current() {
    if [ "$PM" != apt ]; then
        tui_msg "Not supported" \
"Init swapping via systui is only offered on the Debian family,
where init packages are designed to replace each other.

Alpine is OpenRC by design; official Arch is systemd-only;
converting them means changing distro, not a package swap."
        return
    fi
    local t
    t=$(tui_radio "Switch init  [current: $INIT]" \
        "Target init (SPACE to select). THIS IS A MAJOR CHANGE:" \
        systemd  "systemd (systemd-sysv)" off \
        sysvinit "SysVinit (sysvinit-core)" off \
        openrc   "OpenRC" off) || return 0
    [ -z "$t" ] && return
    tui_yesno "DANGER" \
"You are about to replace the init system with: $t

* Requires a REBOOT to take effect.
* Services may need re-enabling under the new init.
* A broken init = an unbootable system. Have recovery media ready.
* Do NOT do this on a machine you can't physically access.

Really proceed?" || return 0
    tui_yesno "Confirm again" "Second confirmation: swap init to $t on THIS machine?" || return 0
    case "$t" in
        systemd)  run_cmd "Installing systemd-sysv" apt-get install -y systemd-sysv ;;
        sysvinit) run_cmd "Installing sysvinit-core" apt-get install -y sysvinit-core sysvinit-utils ;;
        openrc)   run_cmd "Installing openrc" apt-get install -y openrc ;;
    esac && tui_msg "Reboot required" "Init packages installed.\nReview boot config, then reboot to switch to $t."
}

# ---- 2.6 Users -------------------------------------------------------------
menu_users() {
    while true; do
        local c
        c=$(tui_menu "Users" "User management:" \
            add     "Add a user" \
            del     "Delete a user" \
            passwd  "Change a user's password" \
            aging   "Password aging policy (per-user)" \
            expire  "Force password change at next login" \
            lock    "Lock an account" \
            unlock  "Unlock an account" \
            sudo    "Grant sudo (group)" \
            nopass  "Grant passwordless sudo (drop-in)" \
            sudoers "Manage systui sudoers drop-ins" \
            sshkey  "Add an SSH authorized key for a user" \
            groups  "Add user to extra groups" \
            whois   "Show a user's details (id, groups, shell)" \
            defaults "Defaults for NEW users (shell, skel)" \
            list    "List human users" \
            advanced "Advanced (system policy, sessions, login audit)" \
            back    "Back") || return 0
        case "$c" in
            add)
                local u p sh_
                u=$(tui_input "New user" "Username:" "") || continue; [ -z "$u" ] && continue
                sh_=$(tui_radio "Shell" "Login shell (SPACE to select):" \
                    /bin/bash "Bash" on /bin/sh "sh" off /bin/zsh "Zsh" off) || continue
                if command -v useradd >/dev/null; then
                    run_cmd "useradd $u" useradd -m -s "$sh_" "$u"
                else
                    run_cmd "adduser $u" adduser -D -s "$sh_" "$u"   # busybox
                fi
                p=$(tui_password "Password" "Password for $u (blank = locked):")
                [ -n "$p" ] && echo "$u:$p" | chpasswd ;;
            del)
                local u; u=$(tui_input "Delete user" "Username:" "") || continue; [ -z "$u" ] && continue
                tui_yesno "Confirm" "Delete user '$u' AND their home directory?" || continue
                run_cmd "Deleting $u" userdel -r "$u" ;;
            passwd)
                local u p
                u=$(tui_input "Password" "Username:" "${SUDO_USER:-root}") || continue
                p=$(tui_password "Password" "New password for $u:") || continue
                [ -n "$p" ] && echo "$u:$p" | chpasswd && tui_msg "Done" "Password updated for $u." ;;
            aging)
                command -v chage >/dev/null || { tui_msg "N/A" "chage not available (shadow suite missing)."; continue; }
                local u mx wn
                u=$(tui_input "Aging" "Username:" "") || continue; [ -z "$u" ] && continue
                mx=$(tui_input "Aging" "Max password age in days (-1 = never expires):" "-1") || continue
                wn=$(tui_input "Aging" "Warn this many days before expiry:" "7") || continue
                run_cmd "chage $u" chage -M "$mx" -W "$wn" "$u"
                chage -l "$u" > ${SYSTUI_TMP}/usr 2>&1
                tui_text "Aging policy: $u" ${SYSTUI_TMP}/usr ;;
            expire)
                local u; u=$(tui_input "Expire" "Force password change for user:" "") || continue
                [ -n "$u" ] && run_cmd "passwd -e $u" passwd -e "$u" ;;
            lock)
                local u; u=$(tui_input "Lock" "Account to lock:" "") || continue
                [ -n "$u" ] && run_cmd "usermod -L $u" usermod -L "$u" ;;
            unlock)
                local u; u=$(tui_input "Unlock" "Account to unlock:" "") || continue
                [ -n "$u" ] && run_cmd "usermod -U $u" usermod -U "$u" ;;
            sudo)
                local u g="sudo"
                getent group sudo >/dev/null || g="wheel"
                u=$(tui_input "Sudo" "Add which user to the '$g' group?" "") || continue
                [ -n "$u" ] && run_cmd "usermod -aG $g $u" usermod -aG "$g" "$u"
                [ "$g" = wheel ] && tui_msg "Note" "Ensure '%wheel ALL=(ALL:ALL) ALL' is uncommented in sudoers (visudo)." ;;
            nopass)
                local u; u=$(tui_input "NOPASSWD" "Username for passwordless sudo:" "") || continue
                [ -z "$u" ] && continue
                echo "$u ALL=(ALL:ALL) NOPASSWD: ALL" > "/etc/sudoers.d/90-systui-$u"
                chmod 0440 "/etc/sudoers.d/90-systui-$u"
                if visudo -cf "/etc/sudoers.d/90-systui-$u" >/dev/null 2>&1; then
                    tui_msg "Done" "Passwordless sudo granted to $u\n(/etc/sudoers.d/90-systui-$u)."
                else
                    rm -f "/etc/sudoers.d/90-systui-$u"
                    tui_msg "Error" "visudo validation failed — change reverted."
                fi ;;
            sudoers)
                local files f tags=()
                files=$(ls /etc/sudoers.d/90-systui-* 2>/dev/null)
                [ -z "$files" ] && { tui_msg "None" "No systui sudoers drop-ins found."; continue; }
                for f in $files; do tags+=("$f" "$(cat "$f")"); done
                f=$(tui_menu "sudoers drop-ins" "Select a drop-in to DELETE:" "${tags[@]}") || continue
                tui_yesno "Confirm" "Delete $f?\n\nContents:\n$(cat "$f")" && rm -f "$f" && tui_msg "Removed" "$f deleted." ;;
            sshkey)
                local u home_dir key
                u=$(tui_input "SSH key" "Username:" "${SUDO_USER:-root}") || continue
                home_dir=$(user_home "$u")
                [ -z "$home_dir" ] && { tui_msg "Error" "User $u not found."; continue; }
                key=$(tui_input "SSH key" "Paste the public key (ssh-ed25519/ssh-rsa ...):" "") || continue
                [ -z "$key" ] && continue
                mkdir -p "$home_dir/.ssh"
                echo "$key" >> "$home_dir/.ssh/authorized_keys"
                chmod 700 "$home_dir/.ssh"; chmod 600 "$home_dir/.ssh/authorized_keys"
                chown -R "$u" "$home_dir/.ssh"
                tui_msg "Done" "Key appended to $home_dir/.ssh/authorized_keys." ;;
            groups)
                local u g
                u=$(tui_input "Groups" "Username:" "") || continue
                g=$(tui_input "Groups" "Comma-separated groups (e.g. video,audio,docker):" "") || continue
                [ -n "$u" ] && [ -n "$g" ] && run_cmd "usermod -aG $g $u" usermod -aG "$g" "$u" ;;
            whois)
                local u; u=$(tui_input "User details" "Username:" "${SUDO_USER:-root}") || continue
                [ -z "$u" ] && continue
                { id "$u"; echo; getent passwd "$u"; echo
                  command -v chage >/dev/null && chage -l "$u" 2>/dev/null
                  echo; echo "Last logins:"; last -n 5 "$u" 2>/dev/null; } > ${SYSTUI_TMP}/usr 2>&1
                tui_text "Details: $u" ${SYSTUI_TMP}/usr ;;
            defaults)
                command -v useradd >/dev/null || { tui_msg "N/A" "useradd defaults not available (busybox adduser)."; continue; }
                local sh_
                sh_=$(tui_radio "New-user defaults" "Default shell for NEW users (SPACE to select):\nCurrent: $(useradd -D | grep SHELL)" \
                    /bin/bash "Bash" on /bin/sh "sh" off /bin/zsh "Zsh" off) || continue
                [ -n "$sh_" ] && run_cmd "useradd -D -s $sh_" useradd -D -s "$sh_"
                tui_msg "Note" "Files in /etc/skel are copied into every new user's home;\ndrop rc files there to pre-configure new accounts." ;;
            list)
                awk -F: '$3>=1000 && $3<65534 {printf "%-16s uid=%-6s %s\n",$1,$3,$7}' /etc/passwd > ${SYSTUI_TMP}/usr
                tui_text "Human users" ${SYSTUI_TMP}/usr ;;
            advanced) menu_user_advanced ;;
            back) return 0 ;;
        esac
    done
}

# ---- 2.7 Storage -----------------------------------------------------------
menu_storage() {
    while true; do
        local c
        c=$(tui_menu "Storage" "Storage & mounts:" \
            list    "List block devices & mounts" \
            mount   "Mount a device" \
            umount  "Unmount a device/path" \
            bind    "Create a bind mount" \
            fstab   "Add an fstab entry" \
            label   "Label a filesystem" \
            swap    "Create & enable a swapfile" \
            tmpfs   "Mount a tmpfs (RAM disk)" \
            format  "Format a partition (DESTRUCTIVE)" \
            reserve "Reserved blocks %% (ext filesystems)" \
            smart   "Disk health (SMART) $(st smartctl)" \
            usage   "Disk usage overview" \
            advanced "Advanced (LUKS, btrfs, benchmarks, noatime)" \
            back    "Back") || return 0
        case "$c" in
            list)
                { lsblk -o NAME,SIZE,FSTYPE,LABEL,TYPE,MOUNTPOINTS 2>/dev/null || lsblk; echo; findmnt -t nodevfs 2>/dev/null | head -40; } > ${SYSTUI_TMP}/stor
                tui_text "Block devices" ${SYSTUI_TMP}/stor ;;
            mount)
                local dev mp
                dev=$(tui_input "Mount" "Device (e.g. /dev/sdb1):" "") || continue
                mp=$(tui_input "Mount" "Mountpoint:" "/mnt/data") || continue
                [ -z "$dev" ] && continue
                mkdir -p "$mp"
                run_cmd "mount $dev -> $mp" mount "$dev" "$mp" ;;
            umount)
                local t; t=$(tui_input "Unmount" "Device or mountpoint:" "") || continue
                [ -n "$t" ] && run_cmd "umount $t" umount "$t" ;;
            bind)
                local src dst
                src=$(tui_input "Bind mount" "Source directory:" "") || continue
                dst=$(tui_input "Bind mount" "Target directory:" "") || continue
                [ -z "$src" ] || [ -z "$dst" ] && continue
                [ -d "$src" ] || { tui_msg "Error" "$src is not a directory."; continue; }
                mkdir -p "$dst"
                run_cmd "bind $src -> $dst" mount --bind "$src" "$dst" \
                    && tui_yesno "Persist?" "Add to fstab so it survives reboots?" \
                    && { grep -q " $dst .*bind" /etc/fstab || echo "$src $dst none bind 0 0" >> /etc/fstab; } ;;
            fstab)
                local dev mp fs opts uuid line
                dev=$(tui_input "fstab 1/4" "Device (e.g. /dev/sdb1):" "") || continue
                mp=$(tui_input "fstab 2/4" "Mountpoint:" "/mnt/data") || continue
                fs=$(tui_input "fstab 3/4" "Filesystem type:" "ext4") || continue
                opts=$(tui_input "fstab 4/4" "Mount options:" "defaults,nofail") || continue
                uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null)
                if [ -n "$uuid" ]; then line="UUID=$uuid $mp $fs $opts 0 2"
                else line="$dev $mp $fs $opts 0 2"; warn "No UUID found for $dev — using device path (less robust)."; fi
                cp /etc/fstab "/etc/fstab.bak.$(date +%s)"
                echo "$line" >> /etc/fstab
                mkdir -p "$mp"
                if mount -a 2>>"$LOGFILE"; then
                    tui_msg "fstab" "Added and mounted:\n$line\n\n(Backup: /etc/fstab.bak.*)"
                else
                    tui_msg "fstab WARNING" "mount -a reported an error — check /etc/fstab!\nA backup was saved as /etc/fstab.bak.*"
                fi
                show_warnings ;;
            label)
                local dev lbl fs
                dev=$(tui_input "Label" "Device (e.g. /dev/sdb1):" "") || continue
                [ -z "$dev" ] && continue
                fs=$(blkid -s TYPE -o value "$dev" 2>/dev/null)
                lbl=$(tui_input "Label" "New label (fs type detected: ${fs:-unknown}):" "") || continue
                [ -z "$lbl" ] && continue
                case "$fs" in
                    ext2|ext3|ext4) run_cmd "e2label $dev $lbl" e2label "$dev" "$lbl" ;;
                    xfs)            run_cmd "xfs_admin -L $lbl" xfs_admin -L "$lbl" "$dev" ;;
                    vfat)           run_cmd "fatlabel $dev $lbl" fatlabel "$dev" "$lbl" ;;
                    btrfs)          run_cmd "btrfs label" btrfs filesystem label "$dev" "$lbl" ;;
                    *)              tui_msg "N/A" "Labeling not supported for '$fs' here." ;;
                esac ;;
            swap)
                local sz f="/swapfile"
                sz=$(tui_input "Swapfile" "Size (e.g. 2G):" "2G") || continue
                run_cmd "Creating $f ($sz)" bash -c \
                  "fallocate -l $sz $f 2>/dev/null || dd if=/dev/zero of=$f bs=1M count=\$(( \$(numfmt --from=iec ${sz}) / 1048576 )); \
                   chmod 600 $f && mkswap $f && swapon $f"
                grep -q "^$f " /etc/fstab || echo "$f none swap sw 0 0" >> /etc/fstab
                tui_msg "Swap" "Swapfile active and added to fstab." ;;
            tmpfs)
                local mp sz
                mp=$(tui_input "tmpfs" "Mountpoint:" "/mnt/ramdisk") || continue
                sz=$(tui_input "tmpfs" "Size (e.g. 512M, 1G):" "512M") || continue
                mkdir -p "$mp"
                run_cmd "Mounting tmpfs at $mp" mount -t tmpfs -o "size=$sz" tmpfs "$mp" \
                    && tui_yesno "Persist?" "Add to fstab so it survives reboots?" \
                    && { grep -q " $mp tmpfs" /etc/fstab || echo "tmpfs $mp tmpfs size=$sz,mode=1777 0 0" >> /etc/fstab; } ;;
            format)
                local dev fs
                dev=$(tui_input "Format" "Partition to format (e.g. /dev/sdb1):" "") || continue
                [ -z "$dev" ] && continue
                if mount | grep -q "^$dev "; then
                    tui_msg "Refused" "$dev is currently mounted. Unmount it first."; continue
                fi
                fs=$(tui_radio "Filesystem" "Filesystem (SPACE to select):" \
                    ext4 "ext4 (general purpose)" on \
                    xfs  "XFS" off \
                    btrfs "Btrfs" off \
                    vfat "FAT32 (USB sticks, ESP)" off) || continue
                [ -z "$fs" ] && continue
                tui_yesno "DESTRUCTIVE" "This will ERASE ALL DATA on $dev\nand create a $fs filesystem.\n\nContinue?" || continue
                local typed
                typed=$(tui_input "Type to confirm" "Type the device path ($dev) to confirm:" "") || continue
                [ "$typed" != "$dev" ] && { tui_msg "Aborted" "Confirmation did not match."; continue; }
                case "$fs" in
                    ext4)  run_cmd "mkfs.ext4 $dev" mkfs.ext4 -F "$dev" ;;
                    xfs)   run_cmd "mkfs.xfs $dev" mkfs.xfs -f "$dev" ;;
                    btrfs) run_cmd "mkfs.btrfs $dev" mkfs.btrfs -f "$dev" ;;
                    vfat)  run_cmd "mkfs.vfat $dev" mkfs.vfat "$dev" ;;
                esac ;;
            reserve)
                local dev pct
                dev=$(tui_input "Reserved blocks" "ext2/3/4 device:" "") || continue
                [ -z "$dev" ] && continue
                pct=$(tui_input "Reserved blocks" "Reserved %% (default 5; 1 frees space on data disks):" "1") || continue
                run_cmd "tune2fs -m $pct $dev" tune2fs -m "$pct" "$dev" ;;
            smart)
                command -v smartctl >/dev/null || pm_install smartmontools
                local dev; dev=$(tui_input "SMART" "Disk (e.g. /dev/sda, /dev/nvme0):" "/dev/sda") || continue
                { smartctl -H "$dev"; echo; smartctl -A "$dev" | head -30; } > ${SYSTUI_TMP}/stor 2>&1
                tui_text "SMART: $dev" ${SYSTUI_TMP}/stor ;;
            usage)
                df -hT -x tmpfs -x devtmpfs > ${SYSTUI_TMP}/stor 2>/dev/null || df -h > ${SYSTUI_TMP}/stor
                tui_text "Disk usage" ${SYSTUI_TMP}/stor ;;
            advanced) menu_storage_advanced ;;
            back) return 0 ;;
        esac
    done
}

perf_ish_aok() {
    local opts h
    opts=$(tui_check "iSH-AOK tuning" "Compatibility and low-overhead options (SPACE toggles):" \
        proc "Ensure /proc is mounted" on sys "Mount /sys when supported" off devpts "Ensure /dev/pts is mounted" on \
        tmp "Clean stale temporary/cache files" on dns "Repair empty resolv.conf" off shell "Reduce shell history write overhead" off \
        apt "Reduce APT cache/list footprint" on logs "Trim oversized logs" on core "Disable core dumps" on \
        python "Disable Python bytecode writes globally" off git "Enable shallow/partial Git defaults" off \
        status "Generate iSH-AOK capability report" off) || return 0
    opts=${opts//\"/}
    case " $opts " in *" proc "*) mountpoint -q /proc 2>/dev/null || mount -t proc proc /proc 2>/dev/null || true ;; esac
    case " $opts " in *" sys "*) mountpoint -q /sys 2>/dev/null || mount -t sysfs sysfs /sys 2>/dev/null || true ;; esac
    case " $opts " in *" devpts "*) mkdir -p /dev/pts; mountpoint -q /dev/pts 2>/dev/null || mount -t devpts devpts /dev/pts 2>/dev/null || true ;; esac
    case " $opts " in *" tmp "*) find /tmp /var/tmp -mindepth 1 -mtime +3 -delete 2>/dev/null || true; rm -rf /root/.cache/thumbnails 2>/dev/null || true ;; esac
    case " $opts " in *" dns "*) [ -s /etc/resolv.conf ] || printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf ;; esac
    case " $opts " in *" shell "*) printf 'export HISTCONTROL=ignoreboth\nexport HISTSIZE=500\nexport HISTFILESIZE=1000\nexport PROMPT_COMMAND=${PROMPT_COMMAND:+$PROMPT_COMMAND;}history -a\n' > /etc/profile.d/90-systui-shell-performance.sh ;; esac
    case " $opts " in *" apt "*) mkdir -p /etc/apt/apt.conf.d; cat > /etc/apt/apt.conf.d/90-systui-ish-aok <<'EOF'
APT::Keep-Downloaded-Packages "false";
Acquire::Languages "none";
Binary::apt::APT::Keep-Downloaded-Packages "false";
EOF
        apt-get clean 2>/dev/null || true ;; esac
    case " $opts " in *" logs "*) find /var/log -type f -size +2M -exec sh -c ': > "$1"' _ {} \; 2>/dev/null || true ;; esac
    case " $opts " in *" core "*) printf '* soft core 0\n* hard core 0\n' > /etc/security/limits.d/91-systui-no-core.conf 2>/dev/null || true ;; esac
    case " $opts " in *" python "*) echo 'export PYTHONDONTWRITEBYTECODE=1' > /etc/profile.d/91-systui-python.sh ;; esac
    case " $opts " in *" git "*) git config --system fetch.prune true 2>/dev/null || true; git config --system fetch.writeCommitGraph false 2>/dev/null || true ;; esac
    case " $opts " in *" status "*) { uname -a; echo; cat /etc/os-release 2>/dev/null; echo; mount; echo; df -h; echo; free -h 2>/dev/null || true; echo; command -v ip >/dev/null && ip addr 2>&1 || true; } > ${SYSTUI_TMP}/ishaok; tui_text "iSH-AOK capability report" ${SYSTUI_TMP}/ishaok ;; esac
    tui_msg "Done" "Selected iSH-AOK tuning options were applied. Unsupported kernel features were skipped safely."
}

perf_tmpfs() {
    local size
    size=$(tui_input "tmpfs" "Size for /tmp tmpfs (for example 256M or 25%):" "256M") || return 0
    grep -qE '^[^#]+[[:space:]]+/tmp[[:space:]]+tmpfs' /etc/fstab 2>/dev/null || printf 'tmpfs /tmp tmpfs defaults,nosuid,nodev,size=%s 0 0\n' "$size" >> /etc/fstab
    tui_msg "Done" "/tmp tmpfs entry added to /etc/fstab."
}

perf_writeback() {
    local dirty bg
    dirty=$(tui_input "Writeback" "vm.dirty_ratio (percent of RAM):" "10") || return 0
    valid_uint "$dirty" || { tui_msg "Invalid value" "vm.dirty_ratio must be a whole number."; return 0; }
    bg=$(tui_input "Writeback" "vm.dirty_background_ratio (percent of RAM):" "5") || return 0
    valid_uint "$bg" || { tui_msg "Invalid value" "vm.dirty_background_ratio must be a whole number."; return 0; }
    # This file is the single owner of the dirty-writeback keys. The general
    # "sysctl tweaks" option no longer writes them, so the two options can no
    # longer silently override each other depending on filename order.
    cat > /etc/sysctl.d/92-systui-writeback.conf <<EOF
vm.dirty_ratio=$dirty
vm.dirty_background_ratio=$bg
vm.dirty_writeback_centisecs=1500
EOF
    sysctl --system >/dev/null 2>&1 || true
    tui_msg "Done" "VM writeback tuning persisted."
}

perf_dns_cache() {
    if command -v dnsmasq >/dev/null 2>&1; then :; else pm_install dnsmasq || return 0; fi
    mkdir -p /etc/dnsmasq.d; printf 'cache-size=2000\nneg-ttl=60\n' > /etc/dnsmasq.d/systui-cache.conf
    svc enable dnsmasq 2>/dev/null || true; svc restart dnsmasq 2>/dev/null || true
    tui_msg "Done" "Local DNS cache configured with dnsmasq."
}

# ---- 2.8 Performance -------------------------------------------------------
menu_performance() {
    while true; do
        local c
        c=$(tui_menu "Performance (advanced)" "Tuning options:" \
            ishaok     "iSH-AOK compatibility and low-overhead tuning" \
            cpu        "CPU tuning (SMT, turbo, watchdog, mitigations)" \
            memory     "Memory reclaim and cache pressure" \
            writeback  "Disk writeback ratios and interval" \
            tmpfs      "Configure /tmp as tmpfs" \
            dnscache   "Configure local DNS caching" \
            netperf    "Network stack tuning (fastopen, buffers...)" \
            oom        "OOM protection (earlyoom / systemd-oomd)" \
            tuned      "tuned profiles (throughput, latency, powersave)" \
            swappiness "Set vm.swappiness" \
            governor   "Set CPU frequency governor" \
            zram       "Enable zram compressed swap" \
            iosched    "Set I/O scheduler for a disk" \
            thp        "Transparent Hugepages mode" \
            limits     "Raise open-file limits (nofile)" \
            irqbalance "irqbalance (multi-core IRQ spread) $(st irqbalance)" \
            tlp        "TLP laptop power management $(st tlp)" \
            journald   "Cap systemd-journald disk usage" \
            trim       "Enable periodic SSD TRIM" \
            sysctl     "Apply common network/VM sysctl tweaks" \
            svctrim    "Disable a service (reduce boot load)" \
            back       "Back") || return 0
        case "$c" in
            ishaok)  perf_ish_aok ;;
            memory)
                # Previously wrote vm.swappiness here as well as in the
                # dedicated "swappiness" entry below. Because sysctl.d is
                # applied in filename order, 91-systui-memory.conf silently
                # overrode 90-systui-swappiness.conf on every boot. Each key
                # now has exactly one owning file.
                local cache
                cache=$(tui_input "Memory" "vm.vfs_cache_pressure (100 = kernel default,\nlower keeps inode/dentry caches longer):" "50") || continue
                valid_uint "$cache" || { tui_msg "Invalid value" "vm.vfs_cache_pressure must be a whole number."; continue; }
                printf 'vm.vfs_cache_pressure=%s\n' "$cache" > /etc/sysctl.d/91-systui-memory.conf
                sysctl --system >/dev/null 2>&1 || true
                tui_msg "Done" "vm.vfs_cache_pressure=$cache persisted.\n\nSet vm.swappiness from the dedicated Performance entry." ;;
            writeback) perf_writeback ;;
            tmpfs) perf_tmpfs ;;
            dnscache) perf_dns_cache ;;
            cpu)     menu_perf_cpu ;;
            netperf) perf_net_sysctls ;;
            oom)     perf_oom ;;
            tuned)   perf_tuned ;;
            swappiness)
                local v; v=$(tui_input "Swappiness" "vm.swappiness (0-200, default 60;\nlower = prefer RAM, 10 is common for desktops):" "10") || continue
                valid_uint "$v" && [ "$v" -le 200 ] || { tui_msg "Invalid value" "vm.swappiness must be a whole number from 0 to 200."; continue; }
                sysctl -w vm.swappiness="$v" >/dev/null
                echo "vm.swappiness=$v" > /etc/sysctl.d/90-systui-swappiness.conf
                tui_msg "Done" "vm.swappiness=$v (applied now and persisted)." ;;
            governor)
                local g
                g=$(tui_radio "CPU governor" "Governor (SPACE to select):" \
                    performance "Max clocks" off \
                    schedutil   "Scheduler-driven (modern default)" on \
                    powersave   "Lowest power" off) || continue
                [ -z "$g" ] && continue
                local cpu ok=0
                for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                    [ -w "$cpu" ] && echo "$g" > "$cpu" && ok=1
                done
                if [ $ok = 1 ]; then
                    tui_msg "Done" "Governor set to $g (not persistent across reboots;\ninstall cpupower/cpufrequtils for persistence)."
                else
                    tui_msg "N/A" "No writable cpufreq interface (VM or unsupported CPU?)."
                fi ;;
            zram)
                if [ "$INIT" = systemd ] && [ "$PM" = apt ]; then
                    pm_install systemd-zram-generator || pm_install zram-tools
                    tui_msg "zram" "Configure via /etc/systemd/zram-generator.conf or\n/etc/default/zramswap, then reboot."
                elif [ "$PM" = pacman ]; then
                    pm_install zram-generator
                    printf '[zram0]\nzram-size = ram / 2\n' > /etc/systemd/zram-generator.conf
                    tui_msg "zram" "zram-generator installed & configured (half of RAM).\nReboot or: systemctl daemon-reload && systemctl start systemd-zram-setup@zram0"
                elif [ "$PM" = apk ]; then
                    pm_install zram-init
                    svc enable zram-init; svc start zram-init
                else
                    tui_msg "zram" "No packaged zram helper detected for this setup."
                fi ;;
            iosched)
                local disk sched
                disk=$(tui_input "I/O scheduler" "Disk name (e.g. sda, nvme0n1):" "sda") || continue
                [ -r "/sys/block/$disk/queue/scheduler" ] || { tui_msg "Error" "/sys/block/$disk not found."; continue; }
                sched=$(tui_radio "Scheduler" "Current: $(cat /sys/block/$disk/queue/scheduler)\n\nNew scheduler (SPACE to select):" \
                    none        "none (NVMe default)" off \
                    mq-deadline "mq-deadline (SATA SSD)" on \
                    bfq         "bfq (HDDs / desktop fairness)" off \
                    kyber       "kyber (fast devices)" off) || continue
                [ -z "$sched" ] && continue
                if echo "$sched" > "/sys/block/$disk/queue/scheduler" 2>/dev/null; then
                    tui_yesno "Persist?" "Scheduler for $disk set to $sched (runtime).\nWrite a udev rule to persist across reboots?" && {
                        echo "ACTION==\"add|change\", KERNEL==\"$disk\", ATTR{queue/scheduler}=\"$sched\"" \
                            > /etc/udev/rules.d/60-systui-iosched.rules
                        tui_msg "Done" "udev rule written:\n/etc/udev/rules.d/60-systui-iosched.rules"
                    }
                else
                    tui_msg "Error" "Kernel rejected '$sched' for $disk\n(not built in, or wrong device class)."
                fi ;;
            thp)
                local m
                m=$(tui_radio "Transparent Hugepages" "Mode (SPACE to select):" \
                    always  "always (throughput workloads)" off \
                    madvise "madvise (default, safest)" on \
                    never   "never (databases often prefer this)" off) || continue
                [ -z "$m" ] && continue
                echo "$m" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null \
                    && tui_msg "Done" "THP set to $m (runtime only; persist via kernel\ncmdline transparent_hugepage=$m or an init script)." \
                    || tui_msg "Error" "Could not write THP setting." ;;
            limits)
                local n; n=$(tui_input "nofile" "Max open files per process (soft & hard):" "65535") || continue
                valid_uint "$n" || { tui_msg "Invalid value" "The open-file limit must be a whole number."; continue; }
                mkdir -p /etc/security/limits.d
                cat > /etc/security/limits.d/90-systui.conf <<EOF
* soft nofile $n
* hard nofile $n
root soft nofile $n
root hard nofile $n
EOF
                tui_msg "Done" "Limits written to /etc/security/limits.d/90-systui.conf\n(applies to new logins; systemd services use LimitNOFILE=)." ;;
            irqbalance)
                pm_install irqbalance && { svc enable irqbalance; svc start irqbalance; } \
                    && tui_msg "Done" "irqbalance installed and enabled." ;;
            tlp)
                [ "$PM" = apk ] && { tui_msg "N/A" "TLP is not packaged for Alpine."; continue; }
                pm_install tlp && { svc enable tlp; svc start tlp; } \
                    && tui_msg "Done" "TLP installed and enabled (laptop power savings).\nCheck status with: tlp-stat -s" ;;
            journald)
                [ "$INIT" != systemd ] && { tui_msg "N/A" "journald is systemd-only."; continue; }
                local sz; sz=$(tui_input "journald" "SystemMaxUse (e.g. 100M):" "100M") || continue
                mkdir -p /etc/systemd/journald.conf.d
                printf '[Journal]\nSystemMaxUse=%s\n' "$sz" > /etc/systemd/journald.conf.d/90-systui.conf
                systemctl restart systemd-journald
                tui_msg "Done" "journald capped at $sz." ;;
            trim)
                if [ "$INIT" = systemd ]; then
                    svc enable fstrim.timer && svc start fstrim.timer
                    tui_msg "Done" "fstrim.timer enabled (weekly TRIM)."
                else
                    ( crontab -l 2>/dev/null; echo "0 3 * * 0 /sbin/fstrim -av" ) | crontab -
                    tui_msg "Done" "Weekly fstrim cron job added (Sun 03:00)."
                fi ;;
            sysctl)
                # vm.vfs_cache_pressure and the dirty ratios used to be
                # written here too, clobbering the Memory and Writeback
                # entries. This option now only owns the queueing/congestion
                # keys that nothing else sets.
                tui_yesno "sysctl tweaks" \
"Apply these to /etc/sysctl.d/91-systui-perf.conf?

  net.core.default_qdisc = fq
  net.ipv4.tcp_congestion_control = bbr

(BBR needs kernel >= 4.9; ignored if unavailable.)

Cache pressure is set under Memory, and the dirty
ratios under Writeback, so they are not repeated here." || continue
                cat > /etc/sysctl.d/91-systui-perf.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
                sysctl --system >/dev/null 2>&1
                tui_msg "Done" "Tweaks written and applied where supported." ;;
            svctrim)
                local s; s=$(tui_input "Disable service" "Service to disable at boot:" "") || continue
                [ -n "$s" ] && run_cmd "Disabling $s" svc disable "$s" ;;
            back) return 0 ;;
        esac
    done
}


# ---- Advanced: Packages ------------------------------------------------------
menu_pkg_advanced() {
    while true; do
        local c
        c=$(tui_menu "Packages — Advanced  [$PM]" "Advanced package management:" \
            unattended "Automatic security updates (unattended-upgrades)" \
            pin        "Pin a package version/priority (apt preferences)" \
            autoclean  "Periodic cache autoclean (apt)" \
            back       "Back") || return 0
        case "$c" in
            unattended)
                [ "$PM" != apt ] && { tui_msg "N/A" "unattended-upgrades is Debian-family.\nArch: consider pacman hooks; Fedora: dnf-automatic."; continue; }
                pm_install unattended-upgrades
                cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
                tui_msg "Done" "Automatic security updates enabled.\nPolicy file: /etc/apt/apt.conf.d/50unattended-upgrades" ;;
            pin)
                [ "$PM" != apt ] && { tui_msg "N/A" "apt pinning is Debian-family only.\n(pacman: IgnorePkg via the Hold option; dnf: versionlock.)"; continue; }
                local p pr rel
                p=$(tui_input "Pin 1/3" "Package name (globs allowed, e.g. firefox*):" "") || continue
                [ -z "$p" ] && continue
                rel=$(tui_input "Pin 2/3" "Pin target (e.g. release a=bookworm-backports,\nor version 1.2.*):" "release a=stable") || continue
                pr=$(tui_input "Pin 3/3" "Priority (>1000 = force downgrade, 990 = prefer,\n100 = only if nothing else, -1 = never):" "990") || continue
                cat > "/etc/apt/preferences.d/systui-$(tr -cd 'a-zA-Z0-9' <<<"$p")" <<EOF
Package: $p
Pin: $rel
Pin-Priority: $pr
EOF
                run_cmd "apt policy $p" apt-cache policy "$p" ;;
            autoclean)
                [ "$PM" != apt ] && { tui_msg "N/A" "Periodic autoclean helper is apt-only."; continue; }
                local d; d=$(tui_input "Autoclean" "Autoclean interval in days:" "7") || continue
                grep -q AutocleanInterval /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null \
                    && sed -i "s/.*AutocleanInterval.*/APT::Periodic::AutocleanInterval \"$d\";/" /etc/apt/apt.conf.d/20auto-upgrades \
                    || echo "APT::Periodic::AutocleanInterval \"$d\";" >> /etc/apt/apt.conf.d/20auto-upgrades
                tui_msg "Done" "apt cache autocleans every $d days." ;;
            back) return 0 ;;
        esac
    done
}

# ---- Advanced: Shells --------------------------------------------------------
menu_shell_advanced() {
    while true; do
        local c
        c=$(tui_menu "Shells — Advanced" "Advanced shell environment:" \
            umask  "Default umask (new-file permissions)" \
            tmout  "Idle shell auto-logout (TMOUT)" \
            path   "Add directories to the system PATH" \
            ps1    "Bash prompt (PS1) presets — per user" \
            back   "Back") || return 0
        case "$c" in
            umask)
                local m
                m=$(tui_radio "umask" "Default umask (SPACE to select):" \
                    022 "022 — group/world readable (default)" on \
                    027 "027 — group readable, world none" off \
                    077 "077 — owner only (strict)" off) || continue
                [ -z "$m" ] && continue
                printf 'umask %s\n' "$m" > /etc/profile.d/90-systui-umask.sh
                tui_msg "Done" "umask $m set for login shells\n(/etc/profile.d/90-systui-umask.sh)." ;;
            tmout)
                local t
                t=$(tui_input "TMOUT" "Auto-logout idle shells after N seconds\n(0 or blank = disable):" "900") || continue
                if [ -z "$t" ] || [ "$t" = 0 ]; then
                    rm -f /etc/profile.d/90-systui-tmout.sh
                    tui_msg "Done" "Idle auto-logout disabled."
                else
                    printf 'TMOUT=%s\nreadonly TMOUT\nexport TMOUT\n' "$t" > /etc/profile.d/90-systui-tmout.sh
                    tui_msg "Done" "Interactive shells log out after ${t}s idle.\n(readonly so users can't unset it.)"
                fi ;;
            path)
                local p
                p=$(tui_input "PATH" "Directories to append to PATH (colon-separated):" "/usr/local/bin:\$HOME/.local/bin") || continue
                [ -z "$p" ] && continue
                printf 'export PATH="$PATH:%s"\n' "$p" > /etc/profile.d/90-systui-path.sh
                tui_msg "Done" "PATH extension written to /etc/profile.d/90-systui-path.sh" ;;
            ps1)
                local u home_dir pr ps1
                u=$(tui_input "User" "Set PS1 for which user?" "${SUDO_USER:-root}") || continue
                home_dir=$(user_home "$u"); [ -z "$home_dir" ] && { tui_msg "Error" "User $u not found."; continue; }
                [ -d "$home_dir/.oh-my-bash" ] && { tui_msg "Framework detected" "$u uses oh-my-bash — set a theme there instead,\nor the framework will override PS1."; continue; }
                pr=$(tui_radio "PS1 preset" "Prompt style (SPACE to select):" \
                    classic "user@host:dir\$ — plain" on \
                    color   "Same, with colors" off \
                    twoline "Two-line: full path above, \$ below" off \
                    minimal "Just '\$ '" off) || continue
                case "$pr" in
                    classic) ps1='\\u@\\h:\\w\\$ ' ;;
                    color)   ps1='\\[\\e[32m\\]\\u@\\h\\[\\e[0m\\]:\\[\\e[34m\\]\\w\\[\\e[0m\\]\\$ ' ;;
                    twoline) ps1='\\[\\e[90m\\]\\w\\[\\e[0m\\]\\n\\$ ' ;;
                    minimal) ps1='\\$ ' ;;
                    *) continue ;;
                esac
                sed -i '/^# >>> systui PS1 >>>/,/^# <<< systui PS1 <<</d' "$home_dir/.bashrc" 2>/dev/null
                {
                    echo "# >>> systui PS1 >>>"
                    echo "PS1='$ps1'"
                    echo "# <<< systui PS1 <<<"
                } >> "$home_dir/.bashrc"
                chown "$u" "$home_dir/.bashrc" 2>/dev/null
                tui_msg "Done" "PS1 preset '$pr' written to $home_dir/.bashrc" ;;
            back) return 0 ;;
        esac
    done
}

# ---- Advanced: Editors -------------------------------------------------------
menu_editor_advanced() {
    while true; do
        local c
        c=$(tui_menu "Editors — Advanced" "Advanced editor setup:" \
            vimplug "Vim plugins (vim-plug + popular GitHub plugins)" \
            microplug "micro plugins (official channel)" \
            nanosyn "Enable nano syntax highlighting (system-wide)" \
            alts    "Choose the 'editor' alternative (Debian-family)" \
            back    "Back") || return 0
        case "$c" in
            vimplug) menu_vim_plugins ;;
            microplug) menu_micro_plugins ;;
            nanosyn)
                local d=""
                [ -d /usr/share/nano ] && d="/usr/share/nano"
                [ -z "$d" ] && { tui_msg "N/A" "No /usr/share/nano syntax files found\n(install nano first)."; continue; }
                touch /etc/nanorc
                grep -q "include \"$d/\*.nanorc\"" /etc/nanorc || echo "include \"$d/*.nanorc\"" >> /etc/nanorc
                tui_msg "Done" "Syntax highlighting enabled for all shipped languages\n(include \"$d/*.nanorc\" in /etc/nanorc)." ;;
            alts)
                command -v update-alternatives >/dev/null || { tui_msg "N/A" "update-alternatives not available."; continue; }
                local alts a args=() cur
                alts=$(update-alternatives --list editor 2>/dev/null)
                [ -z "$alts" ] && { tui_msg "None" "No 'editor' alternatives registered."; continue; }
                cur=$(readlink -f /etc/alternatives/editor 2>/dev/null)
                for a in $alts; do
                    [ "$a" = "$cur" ] && args+=("$a" "(current)" on) || args+=("$a" "" off)
                done
                a=$(tui_radio "editor alternative" "SPACE to select, ENTER to apply:" "${args[@]}") || continue
                [ -n "$a" ] && run_cmd "update-alternatives --set editor $a" update-alternatives --set editor "$a" ;;
            back) return 0 ;;
        esac
    done
}

# ---- Advanced: Network -------------------------------------------------------
menu_net_advanced() {
    while true; do
        local c
        c=$(tui_menu "Network — Advanced" "Advanced network settings:" \
            ipv6    "Enable / disable IPv6" \
            mtu     "Set interface MTU" \
            wol     "Wake-on-LAN" \
            hostadd "Add an /etc/hosts entry" \
            fwdn    "IP forwarding (routing/NAT hosts)" \
            back    "Back") || return 0
        case "$c" in
            ipv6)
                local v
                v=$(tui_radio "IPv6" "State (SPACE to select):" \
                    enable  "Enabled (default)" on \
                    disable "Disabled (sysctl, persisted)" off) || continue
                case "$v" in
                    disable)
                        printf 'net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\n' \
                            > /etc/sysctl.d/92-systui-ipv6.conf
                        sysctl --system >/dev/null 2>&1
                        tui_msg "Done" "IPv6 disabled (persisted).\nNote: some software expects ::1 — re-enable if issues arise." ;;
                    enable)
                        rm -f /etc/sysctl.d/92-systui-ipv6.conf
                        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
                        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
                        tui_msg "Done" "IPv6 re-enabled." ;;
                esac ;;
            mtu)
                local iface m
                iface=$(tui_input "MTU" "Interface:" "eth0") || continue
                m=$(tui_input "MTU" "MTU (1500 standard, 9000 jumbo, 1400 for some VPNs):" "1500") || continue
                [ -z "$iface" ] || [ -z "$m" ] && continue
                run_cmd "ip link set $iface mtu $m" ip link set dev "$iface" mtu "$m"
                tui_msg "Note" "MTU set at runtime only. Persist it in your network\nconfig (systemd-networkd: MTUBytes=, ifupdown: mtu $m)." ;;
            wol)
                command -v ethtool >/dev/null || pm_install ethtool
                local iface
                iface=$(tui_input "Wake-on-LAN" "Interface:" "eth0") || continue
                [ -z "$iface" ] && continue
                run_cmd "Enabling WoL (magic packet) on $iface" ethtool -s "$iface" wol g
                if [ "$INIT" = systemd ]; then
                    cat > /etc/systemd/system/systui-wol@.service <<'EOF'
[Unit]
Description=Enable Wake-on-LAN on %i
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s %i wol g

[Install]
WantedBy=multi-user.target
EOF
                    systemctl daemon-reload
                    systemctl enable "systui-wol@$iface" 2>>"$LOGFILE"
                    tui_msg "Done" "WoL enabled now and at every boot\n(systui-wol@$iface.service)."
                else
                    tui_msg "Done" "WoL enabled at runtime. Add 'ethtool -s $iface wol g'\nto a boot script to persist."
                fi ;;
            hostadd)
                local ip name
                ip=$(tui_input "hosts entry" "IP address:" "") || continue
                name=$(tui_input "hosts entry" "Hostname(s), space-separated:" "") || continue
                [ -z "$ip" ] || [ -z "$name" ] && continue
                cp /etc/hosts "/etc/hosts.bak.$(date +%s)"
                printf '%s\t%s\n' "$ip" "$name" >> /etc/hosts
                tui_msg "Done" "Added: $ip  $name\n(Backup: /etc/hosts.bak.*)" ;;
            fwdn)
                local v
                v=$(tui_radio "IP forwarding" "State (SPACE to select):" \
                    off "Disabled (default for workstations)" on \
                    on  "Enabled (router/NAT/VPN hosts)" off) || continue
                case "$v" in
                    on)  printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' > /etc/sysctl.d/92-systui-forward.conf ;;
                    off) rm -f /etc/sysctl.d/92-systui-forward.conf
                         sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 ;;
                esac
                sysctl --system >/dev/null 2>&1
                tui_msg "Done" "IP forwarding: $v (persisted)." ;;
            back) return 0 ;;
        esac
    done
}

# ---- Advanced: Services (systemd-focused) ------------------------------------
menu_svc_advanced() {
    while true; do
        local c
        c=$(tui_menu "Services — Advanced" "Advanced service management:" \
            override "Restart policy override for a service" \
            limits   "Resource limits for a service (CPU/RAM)" \
            timers   "List systemd timers" \
            mktimer  "Create a scheduled task (timer + service)" \
            target   "Default boot target (console vs graphical)" \
            back     "Back") || return 0
        [ "$c" = back ] && return
        [ "$INIT" != systemd ] && { tui_msg "N/A" "These features are systemd-only.\n(OpenRC/runit/sysvinit: edit service files directly.)"; continue; }
        case "$c" in
            override)
                local s pol rs
                s=$(tui_input "Override" "Service name:" "") || continue; [ -z "$s" ] && continue
                pol=$(tui_radio "Restart policy" "Restart=$s (SPACE to select):" \
                    on-failure "on-failure (recommended)" on \
                    always     "always" off \
                    no         "no (never auto-restart)" off) || continue
                rs=$(tui_input "Override" "RestartSec (delay before restart, seconds):" "5") || continue
                mkdir -p "/etc/systemd/system/$s.service.d"
                printf '[Service]\nRestart=%s\nRestartSec=%s\n' "$pol" "$rs" \
                    > "/etc/systemd/system/$s.service.d/systui-restart.conf"
                systemctl daemon-reload
                tui_msg "Done" "Drop-in written:\n/etc/systemd/system/$s.service.d/systui-restart.conf\nRestart the service to apply." ;;
            limits)
                local s cq mm
                s=$(tui_input "Limits" "Service name:" "") || continue; [ -z "$s" ] && continue
                cq=$(tui_input "Limits" "CPUQuota %% (e.g. 50; blank = no CPU limit):" "") || continue
                mm=$(tui_input "Limits" "MemoryMax (e.g. 512M, 2G; blank = no RAM limit):" "") || continue
                [ -z "$cq" ] && [ -z "$mm" ] && continue
                mkdir -p "/etc/systemd/system/$s.service.d"
                {
                    echo "[Service]"
                    [ -n "$cq" ] && echo "CPUQuota=${cq}%"
                    [ -n "$mm" ] && echo "MemoryMax=$mm"
                } > "/etc/systemd/system/$s.service.d/systui-limits.conf"
                systemctl daemon-reload
                tui_msg "Done" "Limits drop-in written for $s.\nRestart the service to apply." ;;
            timers)
                systemctl list-timers --all --no-pager > ${SYSTUI_TMP}/svc 2>&1
                tui_text "systemd timers" ${SYSTUI_TMP}/svc ;;
            mktimer)
                local n cal x
                n=$(tui_input "Timer 1/3" "Task name (no spaces):" "mytask") || continue
                x=$(tui_input "Timer 2/3" "Command to run (absolute path):" "/usr/local/bin/mytask.sh") || continue
                cal=$(tui_input "Timer 3/3" "OnCalendar schedule, e.g.:\n  daily | weekly | *-*-* 03:00:00 | Mon *-*-* 09:00" "daily") || continue
                cat > "/etc/systemd/system/$n.service" <<EOF
[Unit]
Description=systui scheduled task: $n

[Service]
Type=oneshot
ExecStart=$x
EOF
                cat > "/etc/systemd/system/$n.timer" <<EOF
[Unit]
Description=Timer for $n

[Timer]
OnCalendar=$cal
Persistent=true

[Install]
WantedBy=timers.target
EOF
                systemctl daemon-reload
                run_cmd "Enabling $n.timer" systemctl enable --now "$n.timer"
                systemctl list-timers "$n.timer" --no-pager > ${SYSTUI_TMP}/svc 2>&1
                tui_text "Timer scheduled" ${SYSTUI_TMP}/svc ;;
            target)
                local t
                t=$(tui_radio "Default target" "Boot into (SPACE to select):\nCurrent: $(systemctl get-default 2>/dev/null)" \
                    multi-user.target "Console / server (no GUI)" off \
                    graphical.target  "Graphical desktop" off) || continue
                [ -n "$t" ] && run_cmd "systemctl set-default $t" systemctl set-default "$t" ;;
        esac
    done
}

# ---- Advanced: Users ---------------------------------------------------------
menu_user_advanced() {
    while true; do
        local c
        c=$(tui_menu "Users — Advanced" "Advanced user policy & auditing:" \
            policy   "System-wide password aging (login.defs)" \
            defumask "System-wide default UMASK (login.defs)" \
            sessions "Who is logged in now" \
            lastlog  "Recent logins (all users)" \
            back     "Back") || return 0
        case "$c" in
            policy)
                [ -f /etc/login.defs ] || { tui_msg "N/A" "/etc/login.defs not found."; continue; }
                local mx mn wa
                mx=$(tui_input "Policy 1/3" "PASS_MAX_DAYS (99999 = never expire):" "$(awk '/^PASS_MAX_DAYS/{print $2}' /etc/login.defs)") || continue
                mn=$(tui_input "Policy 2/3" "PASS_MIN_DAYS (min days between changes):" "$(awk '/^PASS_MIN_DAYS/{print $2}' /etc/login.defs)") || continue
                wa=$(tui_input "Policy 3/3" "PASS_WARN_AGE (warn days before expiry):" "$(awk '/^PASS_WARN_AGE/{print $2}' /etc/login.defs)") || continue
                cp /etc/login.defs "/etc/login.defs.bak.$(date +%s)"
                sed -i -E "s/^PASS_MAX_DAYS[[:space:]]+.*/PASS_MAX_DAYS\t$mx/;
                           s/^PASS_MIN_DAYS[[:space:]]+.*/PASS_MIN_DAYS\t$mn/;
                           s/^PASS_WARN_AGE[[:space:]]+.*/PASS_WARN_AGE\t$wa/" /etc/login.defs
                tui_msg "Done" "login.defs updated (applies to NEW accounts;\nuse the per-user Aging option for existing ones).\nBackup: /etc/login.defs.bak.*" ;;
            defumask)
                [ -f /etc/login.defs ] || { tui_msg "N/A" "/etc/login.defs not found."; continue; }
                local m
                m=$(tui_radio "UMASK" "Default UMASK in login.defs (SPACE to select):" \
                    022 "022 — group/world readable" on \
                    027 "027 — group readable only" off \
                    077 "077 — owner only" off) || continue
                [ -z "$m" ] && continue
                cp /etc/login.defs "/etc/login.defs.bak.$(date +%s)"
                sed -i -E "s/^UMASK[[:space:]]+.*/UMASK\t\t$m/" /etc/login.defs
                tui_msg "Done" "UMASK $m set in login.defs." ;;
            sessions)
                { w; echo; echo "--- loginctl ---"; loginctl list-sessions 2>/dev/null; } > ${SYSTUI_TMP}/usr 2>&1
                tui_text "Active sessions" ${SYSTUI_TMP}/usr ;;
            lastlog)
                { last -n 25 2>/dev/null; echo; lastlog 2>/dev/null | head -25; } > ${SYSTUI_TMP}/usr 2>&1
                tui_text "Recent logins" ${SYSTUI_TMP}/usr ;;
            back) return 0 ;;
        esac
    done
}

# ---- Advanced: Storage -------------------------------------------------------
menu_storage_advanced() {
    while true; do
        local c
        c=$(tui_menu "Storage — Advanced" "Advanced storage operations:" \
            luks     "Encrypt a partition with LUKS (DESTRUCTIVE)" \
            luksopen "Open / close a LUKS partition" \
            btrfs    "Btrfs subvolumes (list / create)" \
            noatime  "Add noatime to a mount (fewer writes)" \
            smarttst "Run a SMART self-test" \
            bench    "Quick disk benchmark (read + write)" \
            back     "Back") || return 0
        case "$c" in
            luks)
                command -v cryptsetup >/dev/null || pm_install cryptsetup
                local dev typed p1 p2
                dev=$(tui_input "LUKS" "Partition to ENCRYPT (e.g. /dev/sdb1):" "") || continue
                [ -z "$dev" ] && continue
                mount | grep -q "^$dev " && { tui_msg "Refused" "$dev is mounted. Unmount first."; continue; }
                tui_yesno "DESTRUCTIVE" "luksFormat will DESTROY ALL DATA on $dev.\nContinue?" || continue
                typed=$(tui_input "Type to confirm" "Type the device path ($dev) to confirm:" "") || continue
                [ "$typed" != "$dev" ] && { tui_msg "Aborted" "Confirmation did not match."; continue; }
                p1=$(tui_password "Passphrase" "LUKS passphrase:") || continue
                p2=$(tui_password "Passphrase" "Repeat passphrase:") || continue
                [ "$p1" != "$p2" ] && { tui_msg "Mismatch" "Passphrases differ — aborted."; continue; }
                [ -z "$p1" ] && { tui_msg "Empty" "Empty passphrase — aborted."; continue; }
                printf '%s' "$p1" | run_cmd "cryptsetup luksFormat $dev" \
                    cryptsetup luksFormat --batch-mode "$dev" -
                tui_msg "Next steps" "Encrypted. Now:\n  1) Open it (next menu option)\n  2) mkfs the mapper device (Storage -> Format)\n  3) Mount /dev/mapper/<name>" ;;
            luksopen)
                command -v cryptsetup >/dev/null || pm_install cryptsetup
                local a
                a=$(tui_radio "LUKS" "Action (SPACE to select):" \
                    open  "Open (unlock) a LUKS device" on \
                    close "Close (lock) a mapping" off) || continue
                case "$a" in
                    open)
                        local dev name p
                        dev=$(tui_input "Open" "LUKS device (e.g. /dev/sdb1):" "") || continue
                        name=$(tui_input "Open" "Mapper name:" "cryptdata") || continue
                        [ -z "$dev" ] || [ -z "$name" ] && continue
                        p=$(tui_password "Passphrase" "LUKS passphrase:") || continue
                        printf '%s' "$p" | cryptsetup open "$dev" "$name" - 2>>"$LOGFILE" \
                            && tui_msg "Open" "Unlocked as /dev/mapper/$name" \
                            || tui_msg "Failed" "Could not open $dev (wrong passphrase?)." ;;
                    close)
                        local name
                        name=$(tui_input "Close" "Mapper name:" "cryptdata") || continue
                        [ -n "$name" ] && run_cmd "cryptsetup close $name" cryptsetup close "$name" ;;
                esac ;;
            btrfs)
                local a
                a=$(tui_radio "Btrfs" "Action (SPACE to select):" \
                    list   "List subvolumes of a mountpoint" on \
                    create "Create a subvolume" off) || continue
                case "$a" in
                    list)
                        local mp; mp=$(tui_input "Btrfs" "Btrfs mountpoint:" "/") || continue
                        btrfs subvolume list "$mp" > ${SYSTUI_TMP}/stor 2>&1 \
                            || echo "Not a btrfs filesystem (or btrfs-progs missing)." > ${SYSTUI_TMP}/stor
                        tui_text "Subvolumes: $mp" ${SYSTUI_TMP}/stor ;;
                    create)
                        local pth; pth=$(tui_input "Btrfs" "New subvolume path (on a btrfs fs):" "") || continue
                        [ -n "$pth" ] && run_cmd "btrfs subvolume create $pth" btrfs subvolume create "$pth" ;;
                esac ;;
            noatime)
                local mp
                mp=$(tui_input "noatime" "Mountpoint whose fstab entry gets noatime:" "/") || continue
                [ -z "$mp" ] && continue
                grep -qE "[[:space:]]${mp}[[:space:]]" /etc/fstab || { tui_msg "Not found" "No fstab entry for $mp."; continue; }
                grep -E "[[:space:]]${mp}[[:space:]]" /etc/fstab | grep -q noatime \
                    && { tui_msg "Already set" "noatime already present for $mp."; continue; }
                cp /etc/fstab "/etc/fstab.bak.$(date +%s)"
                # Append noatime to the options (4th) field of that entry.
                awk -v mp="$mp" 'BEGIN{OFS="\t"} $2==mp {$4=$4",noatime"} {print}' /etc/fstab > /etc/fstab.new \
                    && mv /etc/fstab.new /etc/fstab
                mount -o remount "$mp" 2>>"$LOGFILE"
                grep -E "[[:space:]]${mp}[[:space:]]" /etc/fstab > ${SYSTUI_TMP}/stor
                tui_text "Updated entry" ${SYSTUI_TMP}/stor ;;
            smarttst)
                command -v smartctl >/dev/null || pm_install smartmontools
                local dev
                dev=$(tui_input "SMART test" "Disk (e.g. /dev/sda):" "/dev/sda") || continue
                run_cmd "Starting short self-test on $dev" smartctl -t short "$dev"
                tui_msg "Running" "Short test started (~2 min).\nCheck results later: Storage -> Disk health (SMART)." ;;
            bench)
                local dev out
                dev=$(tui_input "Benchmark" "Disk for READ test (e.g. /dev/sda; blank = skip):" "") || continue
                {
                    echo "=== systui quick disk benchmark — $(date '+%F %T') ==="
                    if [ -n "$dev" ] && [ -b "$dev" ]; then
                        echo; echo "--- Read ($dev) ---"
                        if command -v hdparm >/dev/null; then
                            hdparm -tT "$dev" 2>&1
                        else
                            dd if="$dev" of=/dev/null bs=1M count=512 iflag=direct 2>&1 | tail -1
                        fi
                    fi
                    echo; echo "--- Write (/tmp, 512 MiB, fdatasync) ---"
                    dd if=/dev/zero of=${SYSTUI_TMP}/bench bs=1M count=512 conv=fdatasync 2>&1 | tail -1
                    rm -f ${SYSTUI_TMP}/bench
                    echo; echo "Note: write test measures the /tmp filesystem;"
                    echo "results vary with caching, load, and disk type."
                } > ${SYSTUI_TMP}/stor 2>&1
                tui_text "Benchmark results" ${SYSTUI_TMP}/stor ;;
            back) return 0 ;;
        esac
    done
}

# ---- Performance: CPU tweaks -------------------------------------------------
menu_perf_cpu() {
    while true; do
        local c
        c=$(tui_menu "Performance — CPU" "CPU-level tuning:" \
            smt      "SMT / Hyper-Threading on-off" \
            turbo    "Turbo boost on-off" \
            watchdog "NMI watchdog (small overhead)" \
            autogrp  "Scheduler autogroup (desktop responsiveness)" \
            mitig    "View CPU vulnerability mitigations" \
            back     "Back") || return 0
        case "$c" in
            smt)
                [ -w /sys/devices/system/cpu/smt/control ] || { tui_msg "N/A" "SMT control interface not available."; continue; }
                local v
                v=$(tui_radio "SMT" "Current: $(cat /sys/devices/system/cpu/smt/control)\n\nState (SPACE to select):" \
                    on  "Enabled — max throughput" on \
                    off "Disabled — some latency/security workloads" off) || continue
                [ -z "$v" ] && continue
                echo "$v" > /sys/devices/system/cpu/smt/control \
                    && tui_msg "Done" "SMT: $v (runtime; persist via kernel cmdline\nnosmt or a boot script)." \
                    || tui_msg "Error" "Kernel refused the change." ;;
            turbo)
                local v
                v=$(tui_radio "Turbo boost" "State (SPACE to select):" \
                    on  "Enabled (default)" on \
                    off "Disabled — cooler, consistent clocks" off) || continue
                [ -z "$v" ] && continue
                # An "A && write-0 || write-1" chain wrote the OPPOSITE value
                # whenever the first write failed, so a rejected enable became
                # a disable. Pick the value first, then write it once.
                local turbo_val
                if [ -w /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
                    [ "$v" = on ] && turbo_val=0 || turbo_val=1
                    if echo "$turbo_val" > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null; then
                        tui_msg "Done" "Turbo: $v (intel_pstate, runtime only)."
                    else
                        tui_msg "Error" "Kernel refused the intel_pstate turbo change."
                    fi
                elif [ -w /sys/devices/system/cpu/cpufreq/boost ]; then
                    [ "$v" = on ] && turbo_val=1 || turbo_val=0
                    if echo "$turbo_val" > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null; then
                        tui_msg "Done" "Boost: $v (cpufreq, runtime only)."
                    else
                        tui_msg "Error" "Kernel refused the cpufreq boost change."
                    fi
                else
                    tui_msg "N/A" "No turbo/boost control interface found\n(VM or unsupported driver)."
                fi ;;
            watchdog)
                local v
                v=$(tui_radio "NMI watchdog" "State (SPACE to select):" \
                    on  "Enabled (default — detects hard lockups)" on \
                    off "Disabled — tiny power/perf gain" off) || continue
                case "$v" in
                    off) echo "kernel.nmi_watchdog = 0" > /etc/sysctl.d/93-systui-watchdog.conf ;;
                    on)  rm -f /etc/sysctl.d/93-systui-watchdog.conf
                         sysctl -w kernel.nmi_watchdog=1 >/dev/null 2>&1 ;;
                    *) continue ;;
                esac
                sysctl --system >/dev/null 2>&1
                tui_msg "Done" "NMI watchdog: $v (persisted)." ;;
            autogrp)
                local v
                v=$(tui_radio "Autogroup" "Scheduler autogroup (SPACE to select):" \
                    on  "Enabled — better desktop interactivity" on \
                    off "Disabled — some server workloads prefer this" off) || continue
                case "$v" in
                    on)  echo "kernel.sched_autogroup_enabled = 1" > /etc/sysctl.d/93-systui-autogroup.conf ;;
                    off) echo "kernel.sched_autogroup_enabled = 0" > /etc/sysctl.d/93-systui-autogroup.conf ;;
                    *) continue ;;
                esac
                sysctl --system >/dev/null 2>&1
                tui_msg "Done" "sched_autogroup: $v (persisted)." ;;
            mitig)
                grep -r . /sys/devices/system/cpu/vulnerabilities/ 2>/dev/null \
                    | sed 's|/sys/devices/system/cpu/vulnerabilities/||' > ${SYSTUI_TMP}/perf
                {
                    cat ${SYSTUI_TMP}/perf
                    echo
                    echo "Mitigations can be disabled with the kernel parameter"
                    echo "'mitigations=off' for extra performance, at a real"
                    echo "security cost. systui intentionally does not automate"
                    echo "that — edit your bootloader config manually if you"
                    echo "accept the risk."
                } > ${SYSTUI_TMP}/perf2 && mv ${SYSTUI_TMP}/perf2 ${SYSTUI_TMP}/perf
                tui_text "CPU vulnerabilities" ${SYSTUI_TMP}/perf ;;
            back) return 0 ;;
        esac
    done
}

# ---- Performance: network stack ---------------------------------------------
perf_net_sysctls() {
    local o
    o=$(tui_check "Network performance" "Apply (SPACE toggles) -> /etc/sysctl.d/94-systui-net.conf:" \
        fastopen "TCP Fast Open (client+server)" on \
        mtuprobe "TCP MTU probing (fixes PMTU blackholes)" on \
        bigbuf   "16 MiB socket buffer ceilings" on \
        backlog  "Larger accept/device backlogs" on) || return 0
    o=${o//\"/}
    [ -z "${o// }" ] && return
    {
        echo "# systui network performance tweaks"
        local x
        for x in $o; do
            case "$x" in
                fastopen) echo "net.ipv4.tcp_fastopen = 3" ;;
                mtuprobe) echo "net.ipv4.tcp_mtu_probing = 1" ;;
                bigbuf)   printf 'net.core.rmem_max = 16777216\nnet.core.wmem_max = 16777216\n' ;;
                backlog)  printf 'net.core.somaxconn = 1024\nnet.core.netdev_max_backlog = 5000\n' ;;
            esac
        done
    } > /etc/sysctl.d/94-systui-net.conf
    sysctl --system >/dev/null 2>&1
    tui_msg "Done" "Network tweaks written and applied.\n(BBR + fq are in the general sysctl option.)"
}

# ---- Performance: OOM protection --------------------------------------------
perf_oom() {
    local c
    c=$(tui_radio "OOM protection" "Low-memory responsiveness (SPACE to select):" \
        earlyoom "earlyoom — kills the worst offender before freeze" on \
        oomd     "systemd-oomd (systemd 247+)" off) || return 0
    case "$c" in
        earlyoom)
            pm_install earlyoom && { svc enable earlyoom; svc start earlyoom; } \
                && tui_msg "Done" "earlyoom active — acts when RAM+swap drop below 10%." ;;
        oomd)
            [ "$INIT" != systemd ] && { tui_msg "N/A" "systemd-oomd needs systemd."; return; }
            pm_install systemd-oomd 2>/dev/null
            systemctl enable --now systemd-oomd 2>>"$LOGFILE" \
                && tui_msg "Done" "systemd-oomd enabled." \
                || tui_msg "Error" "Could not enable systemd-oomd (needs cgroup v2 + swap)." ;;
    esac
}

# ---- Performance: tuned profiles --------------------------------------------
perf_tuned() {
    command -v tuned-adm >/dev/null || pm_install tuned
    command -v tuned-adm >/dev/null || { tui_msg "N/A" "tuned is not packaged for this distro."; return; }
    svc enable tuned 2>/dev/null; svc start tuned 2>/dev/null
    local p
    p=$(tui_radio "tuned profile" "Active: $(tuned-adm active 2>/dev/null | sed 's/.*: //')\n\nProfile (SPACE to select):" \
        balanced               "Balanced (default)" on \
        throughput-performance "Max throughput (servers)" off \
        latency-performance    "Low latency" off \
        powersave              "Power saving" off \
        virtual-guest          "VM guest" off \
        desktop                "Desktop responsiveness" off) || return 0
    [ -n "$p" ] && run_cmd "tuned-adm profile $p" tuned-adm profile "$p"
}


# ---- File managers -----------------------------------------------------------
fm_home() {
    local u="$1"
    getent passwd "$u" 2>/dev/null | cut -d: -f6
}

fm_target_user() {
    local def="${SUDO_USER:-root}" u
    u=$(tui_input "Target user" "Configure file manager for which user?" "$def") || return 1
    id "$u" >/dev/null 2>&1 || { tui_msg "Error" "User '$u' does not exist."; return 1; }
    printf '%s\n' "$u"
}

fm_as_user() { # fm_as_user <user> <command>
    local u="$1" cmd="$2"
    if [ "$u" = root ]; then bash -lc "$cmd"
    else su - "$u" -c "$cmd"
    fi
}

fm_pkg_for() { # fm_pkg_for <manager>
    case "$1:$PM" in
        mc:*) echo mc ;;
        lf:*) echo lf ;;
        tere:apt|tere:apk|tere:pacman|tere:dnf) echo tere ;;
        yazi:apt|yazi:apk|yazi:pacman|yazi:dnf) echo yazi ;;
        ranger:*) echo ranger ;;
        nnn:*) echo nnn ;;
        vifm:*) echo vifm ;;
        broot:*) echo broot ;;
        xplr:*) echo xplr ;;
    esac
}

fm_cargo_install() {
    local crate="$1" bin="${2:-$1}"
    command -v cargo >/dev/null 2>&1 || pm_install cargo rustc
    command -v cargo >/dev/null 2>&1 || { tui_msg "Error" "Cargo could not be installed."; return 1; }
    run_cmd "Install $crate with Cargo" cargo install --locked "$crate"
    command -v "$bin" >/dev/null 2>&1
}

fm_configure_tere_shells() { # fm_configure_tere_shells <user>
    local u="$1"
    fm_as_user "$u" "for rc in ~/.bashrc ~/.zshrc; do
        touch \"\$rc\"
        if ! grep -q '^# systui-tere-wrapper$' \"\$rc\" 2>/dev/null; then
            cat >> \"\$rc\" <<'EOF'

# systui-tere-wrapper
tere() {
    local result=\$(command tere \"\$@\")
    [ -n \"\$result\" ] && cd -- \"\$result\"
}
EOF
        fi
    done"
}

fm_install_tere() {
    local url="https://github.com/mgunyho/tere/releases/download/v1.6.0/tere-1.6.0-aarch64-unknown-linux-gnu.zip"
    local arch tmp u bin
    arch=$(uname -m 2>/dev/null || printf unknown)
    case "$arch" in
        aarch64|arm64) ;;
        *)
            tui_msg "Unsupported architecture" "This Tere release is for aarch64/arm64. Detected: $arch"
            return 1
            ;;
    esac

    command -v curl >/dev/null 2>&1 || pm_install curl
    command -v unzip >/dev/null 2>&1 || pm_install unzip
    command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1 || {
        tui_msg "Error" "curl and unzip are required to install Tere."
        return 1
    }

    tmp=$(mktemp -d) || return 1
    if ! curl -fL "$url" -o "$tmp/tere.zip" >>"$LOGFILE" 2>&1; then
        rm -rf "$tmp"
        tui_msg "Error" "Failed to download Tere v1.6.0. See $LOGFILE."
        return 1
    fi
    if ! unzip -q "$tmp/tere.zip" -d "$tmp/unpacked" >>"$LOGFILE" 2>&1; then
        rm -rf "$tmp"
        tui_msg "Error" "Failed to extract the Tere archive. See $LOGFILE."
        return 1
    fi

    bin=$(find "$tmp/unpacked" -type f -name tere -print -quit)
    [ -n "$bin" ] || {
        rm -rf "$tmp"
        tui_msg "Error" "The downloaded archive did not contain the tere binary."
        return 1
    }
    chmod +x "$bin"
    mkdir -p /usr/local/bin
    cp -f "$bin" /usr/local/bin/tere
    chmod 0755 /usr/local/bin/tere
    rm -rf "$tmp"

    u=$(fm_target_user) || return 0
    fm_configure_tere_shells "$u"
    tui_msg "Installed" "Tere v1.6.0 was installed to /usr/local/bin/tere and integrated with .bashrc and .zshrc for $u."
}

fm_yazi_install_dependencies() {
    tui_yesno "Yazi dependencies" "Install Yazi's recommended preview/search dependencies for this distribution?" || return 0
    case "$DISTRO" in
        arch|archlinux|manjaro|endeavouros)
            pm_install ffmpeg 7zip jq poppler fd ripgrep fzf zoxide resvg imagemagick || true
            ;;
        void)
            xbps-install -Sy yazi ffmpeg 7zip jq poppler fd ripgrep fzf zoxide resvg ImageMagick >>"$LOGFILE" 2>&1 || true
            ;;
        fedora|rhel|centos|rocky|almalinux|ultramarine)
            # The COPR package pulls recommended dependencies unless weak deps are disabled.
            ;;
        solus)
            eopkg install -y ffmpeg 7zip jq poppler fd ripgrep fzf zoxide resvg imagemagick >>"$LOGFILE" 2>&1 || true
            ;;
        *)
            # Package names differ substantially on Debian-family and other systems.
            # Install only portable names that are available in the active repositories.
            pm_install ffmpeg jq poppler-utils fd-find ripgrep fzf zoxide imagemagick 2>>"$LOGFILE" || true
            ;;
    esac
}

fm_yazi_install_binary() {
    local arch libc api url tmp archive bin_ya bin_yazi
    arch=$(uname -m 2>/dev/null || printf unknown)
    case "$arch" in
        x86_64|amd64) arch=x86_64 ;;
        aarch64|arm64) arch=aarch64 ;;
        *) tui_msg "Unsupported architecture" "No official Yazi Linux binary selector is configured for: $arch"; return 1 ;;
    esac
    if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then libc=musl; else libc=gnu; fi
    command -v curl >/dev/null 2>&1 || pm_install curl
    command -v unzip >/dev/null 2>&1 || pm_install unzip
    command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1 || {
        tui_msg "Missing tools" "curl and unzip are required for the official binary method."; return 1;
    }
    api=$(curl -fsSL https://api.github.com/repos/sxyazi/yazi/releases/latest) || {
        tui_msg "Download failed" "Could not query the latest official Yazi release."; return 1;
    }
    url=$(printf '%s\n' "$api" | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
        | grep -E "/yazi-${arch}-unknown-linux-${libc}\.zip$" | head -n1)
    [ -n "$url" ] || url=$(printf '%s\n' "$api" | sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' \
        | grep -E "/yazi-${arch}-unknown-linux-(gnu|musl)\.zip$" | head -n1)
    [ -n "$url" ] || { tui_msg "No compatible asset" "The latest release has no recognized $arch Linux ZIP asset."; return 1; }
    tmp=$(mktemp -d) || return 1
    archive="$tmp/yazi.zip"
    if ! curl -fL "$url" -o "$archive" >>"$LOGFILE" 2>&1 || ! unzip -q "$archive" -d "$tmp/unpacked" >>"$LOGFILE" 2>&1; then
        rm -rf "$tmp"; tui_msg "Install failed" "Could not download or extract the official Yazi binary."; return 1
    fi
    bin_yazi=$(find "$tmp/unpacked" -type f -name yazi -print -quit)
    bin_ya=$(find "$tmp/unpacked" -type f -name ya -print -quit)
    [ -n "$bin_yazi" ] && [ -n "$bin_ya" ] || { rm -rf "$tmp"; tui_msg "Invalid archive" "The release archive did not contain both yazi and ya."; return 1; }
    install -Dm755 "$bin_yazi" /usr/local/bin/yazi
    install -Dm755 "$bin_ya" /usr/local/bin/ya
    rm -rf "$tmp"
}

fm_yazi_install_cargo() {
    command -v cargo >/dev/null 2>&1 || pm_install cargo rustc
    command -v cargo >/dev/null 2>&1 || { tui_msg "Cargo unavailable" "Install a current Rust toolchain first."; return 1; }
    run_cmd "Install Yazi through yazi-build" cargo install --force yazi-build
}

fm_yazi_install_source() {
    local tmp
    command -v git >/dev/null 2>&1 || pm_install git
    command -v cargo >/dev/null 2>&1 || pm_install cargo rustc
    pm_install make gcc pkg-config 2>>"$LOGFILE" || true
    command -v git >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1 || {
        tui_msg "Build tools unavailable" "git and a current Cargo toolchain are required."; return 1;
    }
    tmp=$(mktemp -d) || return 1
    if ! git clone --depth 1 https://github.com/sxyazi/yazi.git "$tmp/yazi" >>"$LOGFILE" 2>&1 \
       || ! (cd "$tmp/yazi" && cargo build --release --locked) >>"$LOGFILE" 2>&1; then
        rm -rf "$tmp"; tui_msg "Build failed" "Yazi could not be built. See $LOGFILE."; return 1
    fi
    install -Dm755 "$tmp/yazi/target/release/yazi" /usr/local/bin/yazi
    install -Dm755 "$tmp/yazi/target/release/ya" /usr/local/bin/ya
    rm -rf "$tmp"
}

fm_yazi_install() {
    detect_distro
    local method distro_label="$DISTRO_PRETTY_NAME"
    case "$DISTRO" in
        arch|archlinux|manjaro|endeavouros)
            method=$(tui_radio "Install Yazi" "Detected: $distro_label\n\nChoose an installation method from Yazi's installation guide:" \
                native "pacman package (recommended for Arch-family systems)" on \
                binary "Latest official GitHub release binary" off \
                cargo "crates.io through yazi-build" off \
                source "Build latest source with Cargo" off) || return 0 ;;
        void)
            method=$(tui_radio "Install Yazi" "Detected: $distro_label\n\nChoose an installation method from Yazi's installation guide:" \
                native "XBPS package (recommended for Void Linux)" on \
                binary "Latest official GitHub release binary" off \
                cargo "crates.io through yazi-build" off \
                source "Build latest source with Cargo" off) || return 0 ;;
        fedora|rhel|centos|rocky|almalinux|ultramarine)
            method=$(tui_radio "Install Yazi" "Detected: $distro_label\n\nChoose an installation method from Yazi's installation guide:" \
                native "DNF COPR package (community-maintained method documented by Yazi)" on \
                binary "Latest official GitHub release binary" off \
                cargo "crates.io through yazi-build" off \
                source "Build latest source with Cargo" off) || return 0 ;;
        nixos)
            method=$(tui_radio "Install Yazi" "Detected: $distro_label\n\nChoose an installation method from Yazi's installation guide:" \
                native "Nix package" on \
                binary "Latest official GitHub release binary" off \
                cargo "crates.io through yazi-build" off \
                source "Build latest source with Cargo" off) || return 0 ;;
        solus)
            method=$(tui_radio "Install Yazi" "Detected: $distro_label\n\nChoose an installation method from Yazi's installation guide:" \
                native "eopkg package" on \
                binary "Latest official GitHub release binary" off \
                cargo "crates.io through yazi-build" off \
                source "Build latest source with Cargo" off) || return 0 ;;
        *)
            method=$(tui_radio "Install Yazi" "Detected: $distro_label\n\nYazi's guide does not list a native package for this distribution. Choose a documented portable method:" \
                binary "Latest official GitHub release binary (recommended)" on \
                cargo "crates.io through yazi-build" off \
                source "Build latest source with Cargo" off \
                snap "Snap package, when snapd is available" off) || return 0 ;;
    esac

    if ! {
    case "$method" in
        native)
            case "$DISTRO" in
                arch|archlinux|manjaro|endeavouros)
                    pacman -S --needed yazi ffmpeg 7zip jq poppler fd ripgrep fzf zoxide resvg imagemagick >>"$LOGFILE" 2>&1 ;;
                void)
                    xbps-install -Sy yazi ffmpeg 7zip jq poppler fd ripgrep fzf zoxide resvg ImageMagick >>"$LOGFILE" 2>&1 ;;
                fedora|rhel|centos|rocky|almalinux|ultramarine)
                    command -v dnf >/dev/null 2>&1 || { tui_msg "Unavailable" "dnf is required."; return 1; }
                    dnf -y install dnf-plugins-core >>"$LOGFILE" 2>&1 || true
                    dnf -y copr enable lihaohong/yazi >>"$LOGFILE" 2>&1 && dnf -y install yazi >>"$LOGFILE" 2>&1 ;;
                nixos) nix-env -iA nixos.yazi >>"$LOGFILE" 2>&1 ;;
                solus) eopkg install -y yazi ffmpeg 7zip jq poppler fd ripgrep fzf zoxide resvg imagemagick >>"$LOGFILE" 2>&1 ;;
            esac
            ;;
        binary) fm_yazi_install_binary && fm_yazi_install_dependencies ;;
        cargo) fm_yazi_install_cargo && fm_yazi_install_dependencies ;;
        source) fm_yazi_install_source && fm_yazi_install_dependencies ;;
        snap)
            command -v snap >/dev/null 2>&1 || { tui_msg "Snap unavailable" "Install and enable snapd first."; return 1; }
            snap install yazi --classic >>"$LOGFILE" 2>&1
            ;;
    esac
    }; then
        tui_msg "Install failed" "The selected Yazi installation method failed. Review $LOGFILE."
        return 1
    fi

    if command -v yazi >/dev/null 2>&1; then
        tui_msg "Installed" "Yazi is available at $(command -v yazi).\n\nVersion: $(yazi --version 2>/dev/null | head -n1)"
    else
        tui_msg "Install failed" "Yazi was not found in PATH after installation. Review $LOGFILE."
        return 1
    fi
}

fm_install() {
    local fm="$1" pkg
    if [ "$fm" = tere ]; then
        fm_install_tere
        return $?
    elif [ "$fm" = yazi ]; then
        fm_yazi_install
        return $?
    fi
    pkg=$(fm_pkg_for "$fm")
    pm_install "$pkg" >/dev/null 2>&1 || true
    command -v "$fm" >/dev/null 2>&1 && { tui_msg "Installed" "$fm is installed."; return 0; }
    case "$fm" in
        broot) fm_cargo_install broot ;;
        xplr)  fm_cargo_install xplr ;;
        *)     tui_msg "Unavailable" "$fm is not available from the active repositories. Enable the appropriate repository or install it manually." ;;
    esac
}

fm_remove() {
    local fm="$1" pkg
    pkg=$(fm_pkg_for "$fm")
    command -v "$pkg" >/dev/null 2>&1 && pm_remove "$pkg"
    [ -x /root/.cargo/bin/"$fm" ] && rm -f /root/.cargo/bin/"$fm"
    [ "$fm" = tere ] && rm -f /usr/local/bin/tere
    tui_msg "Removed" "Removal completed for $fm. User configuration was preserved."
}

fm_write_default_config() {
    local fm="$1" u h
    u=$(fm_target_user) || return 0
    h=$(fm_home "$u")
    [ -n "$h" ] || return 0
    case "$fm" in
        lf)
            fm_as_user "$u" "mkdir -p ~/.config/lf; cat > ~/.config/lf/lfrc <<'EOF'
set hidden true
set drawbox true
set icons true
set preview true
map q quit
map gh cd ~
map <enter> open
map / search
cmd open \${{
  case \$(file --mime-type -Lb \"\$f\") in
    text/*|application/json) \${EDITOR:-vi} \"\$f\" ;;
    *) xdg-open \"\$f\" >/dev/null 2>&1 & ;;
  esac
}}
EOF"
            ;;
        mc)
            fm_as_user "$u" "mkdir -p ~/.config/mc ~/.local/share/mc/skins; cat > ~/.config/mc/ini <<'EOF'
[Midnight-Commander]
skin=default
show_dot_files=1
confirm_delete=1
use_internal_edit=1
use_internal_view=1
auto_save_setup=1
editor_line_numbers=1
editor_syntax_highlighting=1
editor_fill_tabs_with_spaces=1
editor_return_does_auto_indent=1
editor_tab_spacing=4

[Layout]
menubar_visible=1
keybar_visible=1
message_visible=1
xterm_title=1
free_space=1
equal_split=1

[Panels]
show_mini_info=1
filetype_mode=1
mix_all_files=0
navigate_with_arrows=1
EOF"
            ;;
        tere)
            fm_configure_tere_shells "$u"
            ;;
        yazi)
            fm_as_user "$u" "mkdir -p ~/.config/yazi; cat > ~/.config/yazi/yazi.toml <<'EOF'
[manager]
show_hidden = true
sort_by = \"natural\"
sort_dir_first = true
linemode = \"size\"
[preview]
wrap = \"yes\"
EOF
cat > ~/.config/yazi/keymap.toml <<'EOF'
[[manager.prepend_keymap]]
on = [ \"g\", \"h\" ]
run = \"cd ~\"
desc = \"Go home\"
EOF"
            ;;
        ranger)
            fm_as_user "$u" "mkdir -p ~/.config/ranger; ranger --copy-config=all >/dev/null 2>&1 || true; sed -i 's/^set show_hidden false/set show_hidden true/' ~/.config/ranger/rc.conf 2>/dev/null || true"
            ;;
        nnn)
            fm_as_user "$u" "mkdir -p ~/.config/nnn; grep -q 'NNN_OPTS' ~/.profile 2>/dev/null || cat >> ~/.profile <<'EOF'
export NNN_OPTS='Hde'
export NNN_PLUG='f:finder;o:fzopen;p:preview-tui;d:diffs;t:nmount'
EOF"
            ;;
        vifm)
            fm_as_user "$u" "mkdir -p ~/.config/vifm; cat > ~/.config/vifm/vifmrc <<'EOF'
set vicmd=vim
set syscalls
set hidden
set wildmenu
set ignorecase
set smartcase
map gh :cd ~<cr>
EOF"
            ;;
        broot)
            fm_as_user "$u" "mkdir -p ~/.config/broot; broot --install >/dev/null 2>&1 || true"
            ;;
        xplr)
            fm_as_user "$u" "mkdir -p ~/.config/xplr; [ -f ~/.config/xplr/init.lua ] || cat > ~/.config/xplr/init.lua <<'EOF'
version = '0.21.9'
xplr.config.general.show_hidden = true
xplr.config.general.enable_mouse = true
EOF"
            ;;
    esac
    chown -R "$u":"$(id -gn "$u")" "$h/.config" 2>/dev/null || true
    tui_msg "Configured" "Default $fm configuration installed for $u."
}

fm_selection_has() { # fm_selection_has <selection-string> <tag>
    case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

fm_backup_config() { # fm_backup_config <path>
    local f="$1"
    [ -f "$f" ] || return 0
    cp -p "$f" "$f.systui.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
}

###############################################################################
# Midnight Commander
###############################################################################
#
# mc keeps its settings in an INI file with several sections, and rewrites that
# file itself on exit when auto_save_setup is on. Rather than sed individual
# keys (which mc would happily reorder or drop), systui regenerates the three
# sections it manages and preserves anything else the user had.

# The section a managed key belongs to. mc silently ignores keys placed in the
# wrong section, which makes a misfiled setting look like it simply had no
# effect, so this mapping is the important part.
mc_ini_section() { # <key>
    case "$1" in
        menubar_visible|keybar_visible|message_visible|xterm_title|free_space|\
        horizontal_split|equal_split|output_lines|command_prompt)
            printf 'Layout\n' ;;
        show_mini_info|kilobyte_si|mix_all_files|filetype_mode|permission_mode|\
        quick_search_mode|navigate_with_arrows|panel_scroll_pages)
            printf 'Panels\n' ;;
        *)  printf 'Midnight-Commander\n' ;;
    esac
}

# Read a key out of an existing ini regardless of which section it sits in.
mc_ini_get() { # <file> <key> <default>
    local v
    v=$(sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p" "$1" 2>/dev/null | head -n1)
    printf '%s\n' "${v:-$3}"
}

mc_state() { # <file> <key> <on-value>  -> on|off for a checklist
    [ "$(mc_ini_get "$1" "$2" "")" = "$3" ] && printf 'on\n' || printf 'off\n'
}

# Rewrite the managed keys, keeping every section and key systui does not own.
mc_ini_write() { # <file> <"key=value" ...>
    local f="$1"; shift
    local tmp pair key val section
    tmp=$(mktemp "${SYSTUI_TMP:-${TMPDIR:-/tmp}}/systui-mc.XXXXXX") || return 1

    # Strip the keys we are about to set, from wherever they currently live,
    # so a key that used to be misfiled does not shadow the new value.
    cp -f "$f" "$tmp" 2>/dev/null || : > "$tmp"
    for pair in "$@"; do
        key=${pair%%=*}
        sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/d" "$tmp"
    done

    for pair in "$@"; do
        key=${pair%%=*}; val=${pair#*=}
        section=$(mc_ini_section "$key")
        if grep -qF "[$section]" "$tmp"; then
            # Insert directly after the section header.
            sed -i "/^\[$section\]/a ${key}=${val}" "$tmp"
        else
            printf '\n[%s]\n%s=%s\n' "$section" "$key" "$val" >> "$tmp"
        fi
    done
    # Collapse the blank lines repeated inserts can leave behind.
    awk 'NF || prev { print } { prev = NF }' "$tmp" > "$f"
    rm -f "$tmp"
}

# Skins live in the user's data dir; list whatever is installed plus the ones
# mc ships with, so the picker reflects reality rather than a fixed list.
mc_available_skins() { # <home>
    local h="$1" d
    {
        printf '%s\n' default darkfar gotar julia762 modarcon16 modarin256 nicedark xoria256
        for d in "$h/.local/share/mc/skins" /usr/share/mc/skins /usr/local/share/mc/skins; do
            [ -d "$d" ] && find "$d" -maxdepth 1 -name '*.ini' -exec basename {} .ini \; 2>/dev/null
        done
    } | sort -u | grep -v '^$'
}

# Cloned skin repositories land in a subdirectory, but mc only reads *.ini
# sitting directly in ~/.local/share/mc/skins. Link them up so a skin installed
# through the plugin manager actually appears in mc's Appearance list.
mc_link_skins() { # <user> <home>
    local u="$1" h="$2" dir="$2/.local/share/mc/skins" ini name linked=0
    [ -d "$dir" ] || return 0
    while IFS= read -r ini; do
        [ -n "$ini" ] || continue
        name=$(basename "$ini")
        # Never clobber a real skin file that lives at the top level.
        [ -e "$dir/$name" ] && continue
        ln -sf "$ini" "$dir/$name" 2>/dev/null && linked=$((linked + 1))
    done < <(find "$dir" -mindepth 2 -name '*.ini' 2>/dev/null)
    [ "$linked" -gt 0 ] && log "mc: linked $linked skin file(s) into $dir"
    chown -h -R "$u":"$(id -gn "$u")" "$dir" 2>/dev/null || true
    return 0
}

mc_skin_menu() { # <user> <home> <ini>
    local u="$1" h="$2" f="$3" current skin
    local -a args=()
    mc_link_skins "$u" "$h"
    current=$(mc_ini_get "$f" skin default)
    while IFS= read -r skin; do
        [ -n "$skin" ] || continue
        args+=("$skin" "$skin" "$(_rootfs_radio_state "$current" "$skin")")
    done < <(mc_available_skins "$h")
    skin=$(tui_radio "Midnight Commander skin" \
        "Installed and built-in skins (SPACE selects).\nInstall more from the plugin manager:" "${args[@]}") || return 0
    [ -n "$skin" ] || return 0
    mc_ini_write "$f" "skin=$skin"
    chown -R "$u":"$(id -gn "$u")" "$h/.config/mc" 2>/dev/null || true
    tui_msg "Skin" "Skin set to '$skin' for $u.\n\nIf mc is running, restart it — it rewrites this file on exit."
}

fm_configure_mc_menu() {
    local u h f selected
    u=$(fm_target_user) || return 0
    h=$(fm_home "$u")
    [ -n "$h" ] || { tui_msg "Error" "Could not resolve a home directory for $u."; return 0; }
    f="$h/.config/mc/ini"
    mkdir -p "$h/.config/mc" "$h/.local/share/mc/skins"
    [ -f "$f" ] || : > "$f"

    while true; do
        local c
        c=$(tui_menu "Midnight Commander — $u" \
            "Configuration file: $f\nSkin: $(mc_ini_get "$f" skin default)" \
            general  "General behaviour (SPACE toggles)" \
            panels   "Panel display (SPACE toggles)" \
            layout   "Layout and screen furniture (SPACE toggles)" \
            editor   "Internal editor (mcedit) options" \
            skin     "Choose a skin" \
            shell    "Shell integration (cd-on-exit wrapper)" \
            view     "View the generated configuration" \
            back     "Back") || return 0
        case "$c" in
            general)
                selected=$(tui_check "mc — general" "Current state pre-checked:" \
                    show_dot_files "Show hidden files" "$(mc_state "$f" show_dot_files 1)" \
                    confirm_delete "Confirm before deleting" "$(mc_state "$f" confirm_delete 1)" \
                    confirm_exit "Confirm on exit" "$(mc_state "$f" confirm_exit 1)" \
                    use_internal_edit "Use the internal editor (mcedit)" "$(mc_state "$f" use_internal_edit 1)" \
                    use_internal_view "Use the internal viewer (mcview)" "$(mc_state "$f" use_internal_view 1)" \
                    auto_save_setup "Save settings automatically on exit" "$(mc_state "$f" auto_save_setup 1)" \
                    drop_menus "Drop menus on F9 without Enter" "$(mc_state "$f" drop_menus 1)" \
                    verbose "Verbose operations" "$(mc_state "$f" verbose 1)") || continue
                selected=" ${selected//\"/} "
                mc_ini_write "$f" \
                    "show_dot_files=$(fm_selection_has "$selected" show_dot_files && echo 1 || echo 0)" \
                    "confirm_delete=$(fm_selection_has "$selected" confirm_delete && echo 1 || echo 0)" \
                    "confirm_exit=$(fm_selection_has "$selected" confirm_exit && echo 1 || echo 0)" \
                    "use_internal_edit=$(fm_selection_has "$selected" use_internal_edit && echo 1 || echo 0)" \
                    "use_internal_view=$(fm_selection_has "$selected" use_internal_view && echo 1 || echo 0)" \
                    "auto_save_setup=$(fm_selection_has "$selected" auto_save_setup && echo 1 || echo 0)" \
                    "drop_menus=$(fm_selection_has "$selected" drop_menus && echo 1 || echo 0)" \
                    "verbose=$(fm_selection_has "$selected" verbose && echo 1 || echo 0)"
                tui_msg "Saved" "General options written to $f." ;;
            panels)
                selected=$(tui_check "mc — panels" "Current state pre-checked:" \
                    show_mini_info "Show the mini status line" "$(mc_state "$f" show_mini_info 1)" \
                    mix_all_files "Mix files and directories in listings" "$(mc_state "$f" mix_all_files 1)" \
                    filetype_mode "Colour filenames by type" "$(mc_state "$f" filetype_mode 1)" \
                    permission_mode "Highlight permissions" "$(mc_state "$f" permission_mode 1)" \
                    kilobyte_si "Use SI units (kB = 1000)" "$(mc_state "$f" kilobyte_si 1)" \
                    navigate_with_arrows "Navigate with plain arrow keys" "$(mc_state "$f" navigate_with_arrows 1)") || continue
                selected=" ${selected//\"/} "
                mc_ini_write "$f" \
                    "show_mini_info=$(fm_selection_has "$selected" show_mini_info && echo 1 || echo 0)" \
                    "mix_all_files=$(fm_selection_has "$selected" mix_all_files && echo 1 || echo 0)" \
                    "filetype_mode=$(fm_selection_has "$selected" filetype_mode && echo 1 || echo 0)" \
                    "permission_mode=$(fm_selection_has "$selected" permission_mode && echo 1 || echo 0)" \
                    "kilobyte_si=$(fm_selection_has "$selected" kilobyte_si && echo 1 || echo 0)" \
                    "navigate_with_arrows=$(fm_selection_has "$selected" navigate_with_arrows && echo 1 || echo 0)"
                tui_msg "Saved" "Panel options written to $f." ;;
            layout)
                selected=$(tui_check "mc — layout" "Current state pre-checked:" \
                    menubar_visible "Always show the menu bar" "$(mc_state "$f" menubar_visible 1)" \
                    keybar_visible "Show the F-key bar" "$(mc_state "$f" keybar_visible 1)" \
                    message_visible "Show the hint bar" "$(mc_state "$f" message_visible 1)" \
                    command_prompt "Show the command prompt" "$(mc_state "$f" command_prompt 1)" \
                    xterm_title "Update the terminal title" "$(mc_state "$f" xterm_title 1)" \
                    free_space "Show free space on the status line" "$(mc_state "$f" free_space 1)" \
                    equal_split "Split panels equally" "$(mc_state "$f" equal_split 1)") || continue
                selected=" ${selected//\"/} "
                mc_ini_write "$f" \
                    "menubar_visible=$(fm_selection_has "$selected" menubar_visible && echo 1 || echo 0)" \
                    "keybar_visible=$(fm_selection_has "$selected" keybar_visible && echo 1 || echo 0)" \
                    "message_visible=$(fm_selection_has "$selected" message_visible && echo 1 || echo 0)" \
                    "command_prompt=$(fm_selection_has "$selected" command_prompt && echo 1 || echo 0)" \
                    "xterm_title=$(fm_selection_has "$selected" xterm_title && echo 1 || echo 0)" \
                    "free_space=$(fm_selection_has "$selected" free_space && echo 1 || echo 0)" \
                    "equal_split=$(fm_selection_has "$selected" equal_split && echo 1 || echo 0)"
                tui_msg "Saved" "Layout options written to $f." ;;
            editor)
                local tabsize
                selected=$(tui_check "mcedit" "Internal editor options:" \
                    editor_line_numbers "Show line numbers" "$(mc_state "$f" editor_line_numbers 1)" \
                    editor_syntax_highlighting "Syntax highlighting" "$(mc_state "$f" editor_syntax_highlighting 1)" \
                    editor_fill_tabs_with_spaces "Insert spaces instead of tabs" "$(mc_state "$f" editor_fill_tabs_with_spaces 1)" \
                    editor_return_does_auto_indent "Auto-indent on Enter" "$(mc_state "$f" editor_return_does_auto_indent 1)" \
                    editor_visible_tabs "Show tab characters" "$(mc_state "$f" editor_visible_tabs 1)" \
                    editor_visible_spaces "Show trailing spaces" "$(mc_state "$f" editor_visible_spaces 1)" \
                    editor_backup_extension "Keep backups on save" "$(mc_state "$f" editor_backup_extension '~')") || continue
                selected=" ${selected//\"/} "
                tabsize=$(tui_input "mcedit" "Tab width (spaces):" "$(mc_ini_get "$f" editor_tab_spacing 4)") || continue
                valid_uint "$tabsize" || { tui_msg "Invalid value" "Tab width must be a whole number."; continue; }
                mc_ini_write "$f" \
                    "editor_line_numbers=$(fm_selection_has "$selected" editor_line_numbers && echo 1 || echo 0)" \
                    "editor_syntax_highlighting=$(fm_selection_has "$selected" editor_syntax_highlighting && echo 1 || echo 0)" \
                    "editor_fill_tabs_with_spaces=$(fm_selection_has "$selected" editor_fill_tabs_with_spaces && echo 1 || echo 0)" \
                    "editor_return_does_auto_indent=$(fm_selection_has "$selected" editor_return_does_auto_indent && echo 1 || echo 0)" \
                    "editor_visible_tabs=$(fm_selection_has "$selected" editor_visible_tabs && echo 1 || echo 0)" \
                    "editor_visible_spaces=$(fm_selection_has "$selected" editor_visible_spaces && echo 1 || echo 0)" \
                    "editor_backup_extension=$(fm_selection_has "$selected" editor_backup_extension && echo '~' || echo '')" \
                    "editor_tab_spacing=$tabsize"
                tui_msg "Saved" "Editor options written to $f." ;;
            skin) mc_skin_menu "$u" "$h" "$f" ;;
            shell)
                # mc cannot change the parent shell's directory itself; the
                # shipped wrapper writes the last directory to a temp file and
                # the shell function cd's to it.
                if tui_yesno "Shell integration" \
"Add an 'mcd' shell function for $u so leaving mc with F10
returns the shell to the directory you were browsing?

Uses mc's own --printwd mechanism." ; then
                    fm_as_user "$u" "for rc in ~/.bashrc ~/.zshrc; do
    [ -e \"\$rc\" ] || continue
    grep -q '^# systui-mc-wrapper\$' \"\$rc\" 2>/dev/null && continue
    cat >> \"\$rc\" <<'EOF'

# systui-mc-wrapper
mcd() {
    local wd
    wd=\$(mktemp -t mc-wd.XXXXXX) || return 1
    command mc --printwd \"\$wd\" \"\$@\"
    if [ -s \"\$wd\" ]; then
        local d; d=\$(cat \"\$wd\")
        [ -d \"\$d\" ] && cd -- \"\$d\"
    fi
    rm -f \"\$wd\"
}
EOF
done"
                    tui_msg "Done" "Added the 'mcd' function to $u's bashrc/zshrc.\n\nOpen a new shell and run: mcd"
                fi ;;
            view)
                if [ -s "$f" ]; then tui_text "mc configuration" "$f"
                else tui_msg "mc configuration" "$f is empty — nothing configured yet."; fi ;;
            back|"") return 0 ;;
        esac
        chown -R "$u":"$(id -gn "$u")" "$h/.config/mc" 2>/dev/null || true
    done
}

fm_configure_lf_menu() {
    local u h f selected ratios
    u=$(fm_target_user) || return 0; h=$(fm_home "$u"); f="$h/.config/lf/lfrc"
    selected=$(tui_check "lf configuration" "SPACE selects enabled settings. The generated configuration replaces lfrc after creating a timestamped backup:" \
        hidden      "Show hidden files" on \
        icons       "Display file icons" on \
        preview     "Enable file previews" on \
        drawbox     "Draw pane borders" on \
        dirfirst    "List directories before files" on \
        natural     "Natural filename sorting" on \
        sortsize    "Sort by size instead of name" off \
        sorttime    "Sort by modification time instead of name" off \
        ignorecase  "Case-insensitive sorting/search" off \
        smartcase   "Smart-case search (sensitive only with capitals)" on \
        reverse     "Reverse sort order" off \
        info        "Show size and time columns" on \
        dirpreviews "Preview directory contents" off \
        mouse       "Enable mouse support" off \
        number      "Show line/item numbers" off \
        relativenum "Use relative numbering" off \
        autoquit    "Quit when changing to a directory" off \
        incsearch   "Incremental search while typing" on \
        wrapscan    "Wrap around at the end of a search" on \
        globsearch  "Treat search patterns as globs" off \
        widepreview "Use a wider preview pane (1:2:3)" on \
        scrolloff   "Keep three lines of context when scrolling" on \
        period      "Refresh the directory listing every second" off \
        safeshell   "Use safer shell options for embedded commands" on \
        history     "Persist command history" on \
        saferemove  "Map d to trash-put when available" on \
        confirmdel  "Map D to delete with confirmation" on \
        homebind    "Map gh to the home directory" on \
        configbind  "Map gc to the config directory" on \
        rootbind    "Map gr to the filesystem root" off \
        mkdirbind   "Map a to create a directory" on \
        renamebind  "Map r/R to rename and bulk-rename" on \
        archivebind "Map ax/az to extract and compress" on \
        chmodbind   "Map ch to change permissions" off \
        fzfbind     "Map <c-f> to fzf jump when available" on \
        zoxidebind  "Map gz to zoxide query when available" off \
        editoropen  "Open text files with EDITOR" on \
        openwith    "Map o to choose an opener interactively" on) || return 0
    mkdir -p "$(dirname "$f")"; fm_backup_config "$f"
    ratios="1:2"; fm_selection_has "$selected" widepreview && ratios="1:2:3"
    {
        fm_selection_has "$selected" hidden && echo 'set hidden true' || echo 'set hidden false'
        fm_selection_has "$selected" icons && echo 'set icons true' || echo 'set icons false'
        fm_selection_has "$selected" preview && echo 'set preview true' || echo 'set preview false'
        fm_selection_has "$selected" drawbox && echo 'set drawbox true' || echo 'set drawbox false'
        fm_selection_has "$selected" dirfirst && echo 'set dirfirst true' || echo 'set dirfirst false'
        if fm_selection_has "$selected" sortsize; then echo 'set sortby size'
        elif fm_selection_has "$selected" sorttime; then echo 'set sortby time'
        elif fm_selection_has "$selected" natural; then echo 'set sortby natural'
        else echo 'set sortby name'; fi
        fm_selection_has "$selected" ignorecase && echo 'set ignorecase true' || echo 'set ignorecase false'
        fm_selection_has "$selected" smartcase && echo 'set smartcase true'
        fm_selection_has "$selected" reverse && echo 'set reverse true'
        fm_selection_has "$selected" info && echo 'set info size:time'
        fm_selection_has "$selected" dirpreviews && echo 'set dirpreviews true'
        fm_selection_has "$selected" mouse && echo 'set mouse true'
        fm_selection_has "$selected" number && echo 'set number true'
        fm_selection_has "$selected" relativenum && echo 'set relativenumber true'
        fm_selection_has "$selected" autoquit && echo 'set autoquit true'
        fm_selection_has "$selected" incsearch && echo 'set incsearch true'
        fm_selection_has "$selected" wrapscan && echo 'set wrapscan true'
        fm_selection_has "$selected" globsearch && echo 'set globsearch true'
        echo "set ratios $ratios"
        fm_selection_has "$selected" scrolloff && echo 'set scrolloff 3'
        fm_selection_has "$selected" period && echo 'set period 1'
        fm_selection_has "$selected" safeshell && { echo 'set shell sh'; echo 'set shellopts -eu'; }
        fm_selection_has "$selected" history && echo 'set history true' || echo 'set history false'
        echo 'map q quit'; echo 'map / search'; echo 'map <enter> open'
        fm_selection_has "$selected" homebind && echo 'map gh cd ~'
        fm_selection_has "$selected" configbind && echo 'map gc cd ~/.config'
        fm_selection_has "$selected" rootbind && echo 'map gr cd /'
        fm_selection_has "$selected" mkdirbind && cat <<'LFEOF'
cmd mkdir %{{
  printf "Directory name: "
  read -r name
  [ -n "$name" ] && mkdir -p -- "$name"
}}
map a mkdir
LFEOF
        fm_selection_has "$selected" renamebind && cat <<'LFEOF'
map r rename
cmd bulkrename %{{
  [ -z "$fx" ] && exit 0
  old_list=$(mktemp) || exit 1
  new_list=$(mktemp) || { rm -f "$old_list"; exit 1; }
  printf '%s\n' "$fx" > "$old_list"
  cp "$old_list" "$new_list"
  ${EDITOR:-vi} "$new_list"
  if [ "$(wc -l < "$old_list")" -ne "$(wc -l < "$new_list")" ]; then
    printf 'Line count changed; aborting bulk rename.\n' >&2
  else
    line=1
    while IFS= read -r old; do
      new=$(sed -n "${line}p" "$new_list")
      if [ -n "$new" ] && [ "$old" != "$new" ]; then mv -i -- "$old" "$new"; fi
      line=$((line + 1))
    done < "$old_list"
  fi
  rm -f "$old_list" "$new_list"
}}
map R bulkrename
LFEOF
        fm_selection_has "$selected" archivebind && cat <<'LFEOF'
cmd extract %{{
  case "$f" in
    *.tar.gz|*.tgz)  tar xzf "$f" ;;
    *.tar.bz2|*.tbz) tar xjf "$f" ;;
    *.tar.xz|*.txz)  tar xJf "$f" ;;
    *.tar.zst)       zstd -dc "$f" | tar xf - ;;
    *.tar)           tar xf "$f" ;;
    *.zip)           unzip -q "$f" ;;
    *.7z)            7z x "$f" ;;
    *.rar)           unrar x "$f" ;;
    *) printf 'Unsupported archive: %s\n' "$f" >&2 ;;
  esac
}}
map ax extract
cmd compress %{{
  printf "Archive name (without extension): "
  read -r name
  [ -n "$name" ] || exit 0
  tar czf "$name.tar.gz" -- $fx
}}
map az compress
LFEOF
        fm_selection_has "$selected" chmodbind && cat <<'LFEOF'
cmd chmodsel %{{
  printf "Mode (example 644): "
  read -r mode
  [ -n "$mode" ] && chmod -- "$mode" $fx
}}
map ch chmodsel
LFEOF
        fm_selection_has "$selected" fzfbind && cat <<'LFEOF'
cmd fzf_jump ${{
  command -v fzf >/dev/null 2>&1 || exit 0
  res=$(find . -mindepth 1 -maxdepth 4 2>/dev/null | fzf --reverse --header='Jump to')
  [ -z "$res" ] && exit 0
  if [ -d "$res" ]; then lf -remote "send $id cd \"$res\""; else lf -remote "send $id select \"$res\""; fi
}}
map <c-f> fzf_jump
LFEOF
        fm_selection_has "$selected" zoxidebind && cat <<'LFEOF'
cmd z ${{
  command -v zoxide >/dev/null 2>&1 || exit 0
  res=$(zoxide query "$1" 2>/dev/null) && lf -remote "send $id cd \"$res\""
}}
map gz push :z<space>
LFEOF
        fm_selection_has "$selected" saferemove && cat <<'LFEOF'
cmd trash %{{
  if command -v trash-put >/dev/null 2>&1; then trash-put $fx; else printf 'trash-put is not installed\n' >&2; fi
}}
map d trash
LFEOF
        fm_selection_has "$selected" confirmdel && cat <<'LFEOF'
cmd delete %{{
  printf "Permanently delete the selection? [y/N] "
  read -r ans
  case "$ans" in [yY]*) rm -rf -- $fx ;; esac
}}
map D delete
LFEOF
        fm_selection_has "$selected" editoropen && cat <<'LFEOF'
cmd open ${{
  case $(file --mime-type -Lb "$f") in
    text/*|application/json|application/xml) ${EDITOR:-vi} "$f" ;;
    *) xdg-open "$f" >/dev/null 2>&1 & ;;
  esac
}}
LFEOF
        fm_selection_has "$selected" openwith && cat <<'LFEOF'
cmd open_with %{{
  printf "Open with: "
  read -r prog
  [ -n "$prog" ] && $prog $fx
}}
map o open_with
LFEOF
    } > "$f"
    chown -R "$u":"$(id -gn "$u")" "$h/.config/lf" 2>/dev/null || true
    tui_msg "Configured" "lf configuration generated for $u ($(grep -c . "$f") lines)."
}

fm_configure_tere_menu() {
    local u h selected opts rc frag
    u=$(fm_target_user) || return 0; h=$(fm_home "$u")
    selected=$(tui_check "tere configuration" "SPACE selects shell-wrapper settings:" \
        mouse       "Enable mouse input" on \
        skipfirst   "Skip the first-run prompt" on \
        hidden      "Show hidden files" on \
        dirsfirst   "Sort directories first" on \
        gitignore   "Respect .gitignore files" off \
        caseignore  "Case-insensitive search" on \
        smartcase   "Smart-case search (overrides case-insensitive)" off \
        autocd      "Change directory on a unique match" off \
        filtersearch "Filter the listing instead of jumping" off \
        history     "Persist directory history" on \
        nocolor     "Disable colours (plain terminals)" off \
        bash        "Install wrapper in .bashrc" on \
        zsh         "Install wrapper in .zshrc" on \
        fish        "Install wrapper in fish config" off \
        aliasj      "Add tj alias for tere" off \
        aliascdi    "Add cdi alias for tere" off \
        ctrlt       "Bind Ctrl-T to tere in bash/zsh" off) || return 0
    opts=""
    fm_selection_has "$selected" mouse && opts="$opts --mouse=on" || opts="$opts --mouse=off"
    fm_selection_has "$selected" skipfirst && opts="$opts --skip-first-run-prompt"
    fm_selection_has "$selected" hidden && opts="$opts --show-hidden"
    fm_selection_has "$selected" dirsfirst && opts="$opts --folders-first"
    fm_selection_has "$selected" gitignore && opts="$opts --respect-gitignore"
    if fm_selection_has "$selected" smartcase; then opts="$opts --smart-case"
    elif fm_selection_has "$selected" caseignore; then opts="$opts --ignore-case"
    fi
    fm_selection_has "$selected" autocd && opts="$opts --autocd-timeout=200"
    fm_selection_has "$selected" filtersearch && opts="$opts --filter-search"
    fm_selection_has "$selected" nocolor && opts="$opts --no-colors"
    fm_selection_has "$selected" history && fm_as_user "$u" "mkdir -p ~/.local/share/tere" 2>/dev/null

    # The fragment is assembled here and copied into place, rather than being
    # interpolated through a double-quoted `fm_as_user` argument. The Ctrl-T
    # bindings contain both quote styles and backslash escapes, and nesting
    # them inside a quoted heredoc leaked the escapes into the user's rc file.
    frag="$SYSTUI_TMP/tere-frag"
    for rc in .bashrc .zshrc; do
        case "$rc" in
            .bashrc) fm_selection_has "$selected" bash || continue ;;
            .zshrc)  fm_selection_has "$selected" zsh  || continue ;;
        esac
        {
            printf '# systui-tere-config begin\n'
            printf 'tere() {\n'
            printf '    local result\n'
            printf '    result=$(command tere%s "$@")\n' "$opts"
            printf '    [ -n "$result" ] && cd -- "$result"\n'
            printf '}\n'
            fm_selection_has "$selected" aliasj   && printf "alias tj='tere'\n"
            fm_selection_has "$selected" aliascdi && printf "alias cdi='tere'\n"
            if fm_selection_has "$selected" ctrlt; then
                if [ "$rc" = .bashrc ]; then
                    printf 'bind -x %s"\\C-t": tere%s\n' "'" "'"
                else
                    printf 'tere-widget() { tere; zle reset-prompt; }\n'
                    printf 'zle -N tere-widget\n'
                    printf 'bindkey "^T" tere-widget\n'
                fi
            fi
            printf '# systui-tere-config end\n'
        } > "$frag"
        fm_as_user "$u" "touch ~/$rc; sed -i '/^# systui-tere-config begin\$/,/^# systui-tere-config end\$/d' ~/$rc"
        cat "$frag" >> "$h/$rc"
        chown "$u":"$(id -gn "$u")" "$h/$rc" 2>/dev/null || true
    done
    rm -f "$frag"

    if fm_selection_has "$selected" fish; then
        mkdir -p "$h/.config/fish/functions"
        {
            printf 'function tere\n'
            printf '    set --local result (command tere%s $argv)\n' "$opts"
            printf '    test -n "$result"; and cd -- "$result"\n'
            printf 'end\n'
        } > "$h/.config/fish/functions/tere.fish"
        fm_selection_has "$selected" aliasj   && printf 'function tj\n    tere $argv\nend\n'  > "$h/.config/fish/functions/tj.fish"
        fm_selection_has "$selected" aliascdi && printf 'function cdi\n    tere $argv\nend\n' > "$h/.config/fish/functions/cdi.fish"
        chown -R "$u":"$(id -gn "$u")" "$h/.config/fish" 2>/dev/null || true
    fi
    tui_msg "Configured" "tere shell integration installed for $u.\nOptions:$opts\n\nOpen a new shell to activate it."
}

fm_configure_yazi_menu() {
    local u h f k selected sortby linemode
    u=$(fm_target_user) || return 0; h=$(fm_home "$u"); f="$h/.config/yazi/yazi.toml"; k="$h/.config/yazi/keymap.toml"
    selected=$(tui_check "Yazi configuration" "SPACE selects enabled settings:" \
        hidden      "Show hidden files" on \
        dirfirst    "Sort directories first" on \
        natural     "Natural filename sorting" on \
        sortmtime   "Sort by modification time instead of name" off \
        sortsize    "Sort by size instead of name" off \
        reverse     "Reverse sort order" off \
        sensitive   "Case-sensitive sorting" off \
        size        "Display file size line mode" on \
        permissions "Display permissions line mode" off \
        mtime       "Display modification time line mode" off \
        symlink     "Show symlink targets" on \
        ratio       "Use a wider preview pane (1:3:4)" on \
        scrolloff   "Keep five lines of context when scrolling" on \
        wrap        "Wrap preview text" on \
        image       "Enable image previews" on \
        imagequality "Use high-quality image previews" off \
        maxwidth    "Limit preview images to 1920x1080" on \
        tabsize4    "Use four-space preview tabs" on \
        homebind    "Map g,h to home" on \
        configbind  "Map g,c to the config directory" on \
        rootbind    "Map g,r to the filesystem root" off \
        quitcd      "Map q to quit and change directory" off \
        shell       "Map ! to interactive shell" on \
        trash       "Use trash instead of permanent delete" on \
        confirmdel  "Ask before permanent delete" on \
        hiddentoggle "Map . to toggle hidden files" on \
        searchbind  "Map s/S to fd and ripgrep search" on \
        selectall   "Map <c-a> to select all" on \
        linemodebind "Map m to cycle line modes" off \
        editoropen  "Open text files with EDITOR" on) || return 0
    mkdir -p "$(dirname "$f")"; fm_backup_config "$f"; fm_backup_config "$k"
    sortby=name
    if fm_selection_has "$selected" sortmtime; then sortby=mtime
    elif fm_selection_has "$selected" sortsize; then sortby=size
    elif fm_selection_has "$selected" natural; then sortby=natural
    fi
    linemode=none
    fm_selection_has "$selected" size && linemode=size
    fm_selection_has "$selected" permissions && linemode=permissions
    fm_selection_has "$selected" mtime && linemode=mtime
    {
        echo '[mgr]'
        echo "show_hidden = $(fm_selection_has "$selected" hidden && echo true || echo false)"
        echo "show_symlink = $(fm_selection_has "$selected" symlink && echo true || echo false)"
        echo "sort_by = \"$sortby\""
        echo "sort_dir_first = $(fm_selection_has "$selected" dirfirst && echo true || echo false)"
        echo "sort_reverse = $(fm_selection_has "$selected" reverse && echo true || echo false)"
        echo "sort_sensitive = $(fm_selection_has "$selected" sensitive && echo true || echo false)"
        [ "$linemode" != none ] && echo "linemode = \"$linemode\""
        fm_selection_has "$selected" ratio && echo 'ratio = [1, 3, 4]' || echo 'ratio = [1, 4, 3]'
        fm_selection_has "$selected" scrolloff && echo 'scrolloff = 5'
        echo
        echo '[preview]'
        echo "wrap = \"$(fm_selection_has "$selected" wrap && echo yes || echo no)\""
        echo "tab_size = $(fm_selection_has "$selected" tabsize4 && echo 4 || echo 2)"
        echo "image_delay = $(fm_selection_has "$selected" image && echo 30 || echo 999999)"
        fm_selection_has "$selected" maxwidth && { echo 'max_width = 1920'; echo 'max_height = 1080'; }
        fm_selection_has "$selected" imagequality && echo 'image_quality = 90' || echo 'image_quality = 75'
        echo
        echo '[opener]'
        if fm_selection_has "$selected" editoropen; then
            echo 'edit = [{ run = '\''${EDITOR:-vi} "$@"'\'', block = true, for = "unix" }]'
        else
            echo 'edit = [{ run = '\''xdg-open "$@"'\'', orphan = true, for = "unix" }]'
        fi
        echo
        echo '[tasks]'
        echo "suppress_preload = $(fm_selection_has "$selected" image && echo false || echo true)"
    } > "$f"
    {
        fm_selection_has "$selected" homebind && cat <<'YEOF'
[[mgr.prepend_keymap]]
on = [ "g", "h" ]
run = "cd ~"
desc = "Go home"
YEOF
        fm_selection_has "$selected" configbind && cat <<'YEOF'

[[mgr.prepend_keymap]]
on = [ "g", "c" ]
run = "cd ~/.config"
desc = "Go to the config directory"
YEOF
        fm_selection_has "$selected" rootbind && cat <<'YEOF'

[[mgr.prepend_keymap]]
on = [ "g", "r" ]
run = "cd /"
desc = "Go to the filesystem root"
YEOF
        fm_selection_has "$selected" quitcd && cat <<'YEOF'

[[mgr.prepend_keymap]]
on = [ "q" ]
run = "quit --no-cwd-file"
desc = "Quit"
YEOF
        fm_selection_has "$selected" shell && cat <<'YEOF'

[[mgr.prepend_keymap]]
on = [ "!" ]
run = "shell --block --interactive"
desc = "Open shell"
YEOF
        fm_selection_has "$selected" hiddentoggle && cat <<'YEOF'

[[mgr.prepend_keymap]]
on = [ "." ]
run = "hidden toggle"
desc = "Toggle hidden files"
YEOF
        fm_selection_has "$selected" selectall && cat <<'YEOF'

[[mgr.prepend_keymap]]
on = [ "<C-a>" ]
run = "toggle_all --state=on"
desc = "Select all"
YEOF
        fm_selection_has "$selected" linemodebind && cat <<'YEOF'

[[mgr.prepend_keymap]]
on = [ "m", "s" ]
run = "linemode size"
desc = "Line mode: size"

[[mgr.prepend_keymap]]
on = [ "m", "p" ]
run = "linemode permissions"
desc = "Line mode: permissions"

[[mgr.prepend_keymap]]
on = [ "m", "m" ]
run = "linemode mtime"
desc = "Line mode: modification time"
YEOF
        fm_selection_has "$selected" searchbind && cat <<'YEOF'

[[mgr.prepend_keymap]]
on = [ "s" ]
run = "search fd"
desc = "Search files by name (fd)"

[[mgr.prepend_keymap]]
on = [ "S" ]
run = "search rg"
desc = "Search file contents (ripgrep)"
YEOF
        if fm_selection_has "$selected" trash; then
            cat <<'YEOF'

[[mgr.prepend_keymap]]
on = [ "d" ]
run = "remove"
desc = "Move to trash"
YEOF
        fi
        if fm_selection_has "$selected" confirmdel; then
            cat <<'YEOF'

[[mgr.prepend_keymap]]
on = [ "D" ]
run = "remove --permanently"
desc = "Delete permanently (asks first)"
YEOF
        fi
    } > "$k"
    chown -R "$u":"$(id -gn "$u")" "$h/.config/yazi" 2>/dev/null || true
    tui_msg "Configured" "Yazi configuration generated for $u.\nyazi.toml: $(grep -c . "$f") lines, keymap.toml: $(grep -c . "$k") lines."
}

fm_configure_ranger_menu() {
    local u h f selected previewmethod
    u=$(fm_target_user) || return 0; h=$(fm_home "$u"); f="$h/.config/ranger/rc.conf"
    selected=$(tui_check "Ranger configuration" "SPACE selects enabled settings:" \
        hidden       "Show hidden files" on \
        preview      "Preview files" on \
        previewdirs  "Preview directories" on \
        previewscript "Use the ranger preview script (scope.sh)" on \
        images       "Enable image previews" off \
        sixel        "Use sixel image preview method" off \
        kitty        "Use kitty image preview method" off \
        icons        "Display file icons when supported" on \
        mouse        "Enable mouse support" on \
        dirfirst     "Sort directories first" on \
        natural      "Natural sorting" on \
        caseignore   "Case-insensitive sorting" on \
        reverse      "Reverse sort order" off \
        confirm      "Confirm destructive operations" on \
        vcs          "Show VCS/Git information" on \
        vcsroot      "Show VCS information in the root directory only" off \
        freespace    "Display free disk space" on \
        tabs         "Show the tab bar when multiple tabs are open" on \
        lineNumbers  "Show relative line numbers" off \
        autosave     "Save copy/paste buffer between sessions" on \
        scrolloff    "Keep three lines of context when scrolling" on \
        titlebar     "Update the terminal title" on \
        hostname     "Show the hostname in the titlebar" off \
        flushinput   "Flush input before starting a command" on \
        homebind     "Map gh to home" on \
        configbind   "Map gc to the config directory" on \
        trash        "Map d to trash-put" on \
        fzfbind      "Map <c-f> to fzf select when available" on \
        bulkrename   "Map br to bulk rename" on \
        openwith     "Map ow to choose an opener" on) || return 0
    mkdir -p "$(dirname "$f")"; fm_backup_config "$f"
    previewmethod=ueberzug
    fm_selection_has "$selected" sixel && previewmethod=sixel
    fm_selection_has "$selected" kitty && previewmethod=kitty
    {
        echo "set show_hidden $(fm_selection_has "$selected" hidden && echo true || echo false)"
        echo "set preview_files $(fm_selection_has "$selected" preview && echo true || echo false)"
        echo "set preview_directories $(fm_selection_has "$selected" previewdirs && echo true || echo false)"
        echo "set use_preview_script $(fm_selection_has "$selected" previewscript && echo true || echo false)"
        echo "set preview_images $(fm_selection_has "$selected" images && echo true || echo false)"
        echo "set preview_images_method $previewmethod"
        echo "set draw_borders both"
        echo "set mouse_enabled $(fm_selection_has "$selected" mouse && echo true || echo false)"
        echo "set sort_directories_first $(fm_selection_has "$selected" dirfirst && echo true || echo false)"
        fm_selection_has "$selected" natural && echo 'set sort natural' || echo 'set sort basename'
        echo "set sort_case_insensitive $(fm_selection_has "$selected" caseignore && echo true || echo false)"
        echo "set sort_reverse $(fm_selection_has "$selected" reverse && echo true || echo false)"
        echo "set confirm_on_delete $(fm_selection_has "$selected" confirm && echo multiple || echo never)"
        echo "set vcs_aware $(fm_selection_has "$selected" vcs && echo true || echo false)"
        fm_selection_has "$selected" vcsroot && { echo 'set vcs_backend_git local'; } || echo 'set vcs_backend_git enabled'
        echo "set display_free_space $(fm_selection_has "$selected" freespace && echo true || echo false)"
        echo "set draw_progress_bar_in_status_bar true"
        fm_selection_has "$selected" tabs && echo 'set dirname_in_tabs true'
        fm_selection_has "$selected" lineNumbers && echo 'set line_numbers relative'
        echo "set save_copy_buffer $(fm_selection_has "$selected" autosave && echo true || echo false)"
        fm_selection_has "$selected" scrolloff && echo 'set scroll_offset 3'
        echo "set update_title $(fm_selection_has "$selected" titlebar && echo true || echo false)"
        echo "set hostname_in_titlebar $(fm_selection_has "$selected" hostname && echo true || echo false)"
        echo "set flushinput $(fm_selection_has "$selected" flushinput && echo true || echo false)"
        fm_selection_has "$selected" icons && echo 'default_linemode devicons'
        fm_selection_has "$selected" homebind && echo 'map gh cd ~'
        fm_selection_has "$selected" configbind && echo 'map gc cd ~/.config'
        fm_selection_has "$selected" trash && echo 'map d shell trash-put %s'
        fm_selection_has "$selected" bulkrename && echo 'map br bulkrename'
        fm_selection_has "$selected" openwith && echo 'map ow console open_with '
        fm_selection_has "$selected" fzfbind && cat <<'REOF'
map <C-f> fzf_select
REOF
    } > "$f"
    chown -R "$u":"$(id -gn "$u")" "$h/.config/ranger" 2>/dev/null || true
    tui_msg "Configured" "Ranger configuration generated for $u ($(grep -c . "$f") lines)."
}

fm_configure_nnn_menu() {
    local u selected opts plug colors
    u=$(fm_target_user) || return 0
    selected=$(tui_check "nnn configuration" "SPACE selects environment and plugin settings:" \
        hidden       "Show hidden files" on \
        detail       "Use detail mode" on \
        autoenter    "Open unique match automatically" off \
        dirsfirst    "List directories first" on \
        caseignore   "Case-insensitive matching" on \
        useeditor    "Open text files with EDITOR" on \
        nosort       "Disable sorting for very large directories" off \
        reverse      "Reverse sort order" off \
        timesort     "Sort by modification time" off \
        sizesort     "Sort by size" off \
        extsort      "Sort by extension" off \
        color        "Enable context colours" on \
        colorscheme  "Use a high-contrast colour scheme" off \
        icons        "Enable icons (requires an icon-enabled build)" off \
        trash        "Use trash-cli for deletion" on \
        selmode      "Persist selection across directories" off \
        cursor       "Remember the cursor position per directory" on \
        preview      "Enable preview-tui plugin binding" on \
        finder       "Enable finder/fzf plugin binding" on \
        fzopen       "Enable fzopen plugin binding" on \
        mount        "Enable mount plugin binding" on \
        diff         "Enable diff plugin binding" off \
        imgview      "Enable image viewer plugin binding" off \
        gitstatus    "Enable git status plugin binding" off \
        bookmarks    "Add common home/download bookmarks" on \
        extrabm      "Add project and temp bookmarks" off \
        fifo         "Enable the preview FIFO for preview-tui" on \
        cdexit       "Install nnn shell cd-on-quit wrapper" on) || return 0
    opts=""
    fm_selection_has "$selected" hidden && opts="${opts}H"
    fm_selection_has "$selected" detail && opts="${opts}d"
    fm_selection_has "$selected" autoenter && opts="${opts}a"
    fm_selection_has "$selected" dirsfirst && opts="${opts}e"
    fm_selection_has "$selected" caseignore && opts="${opts}i"
    fm_selection_has "$selected" useeditor && opts="${opts}c"
    fm_selection_has "$selected" nosort && opts="${opts}S"
    fm_selection_has "$selected" reverse && opts="${opts}r"
    fm_selection_has "$selected" timesort && opts="${opts}T"
    fm_selection_has "$selected" sizesort && opts="${opts}s"
    fm_selection_has "$selected" extsort && opts="${opts}E"
    fm_selection_has "$selected" selmode && opts="${opts}A"
    fm_selection_has "$selected" cursor && opts="${opts}P"
    plug=""
    fm_selection_has "$selected" finder && plug="${plug}f:finder;"
    fm_selection_has "$selected" fzopen && plug="${plug}o:fzopen;"
    fm_selection_has "$selected" preview && plug="${plug}p:preview-tui;"
    fm_selection_has "$selected" mount && plug="${plug}m:nmount;"
    fm_selection_has "$selected" diff && plug="${plug}d:diffs;"
    fm_selection_has "$selected" imgview && plug="${plug}v:imgview;"
    fm_selection_has "$selected" gitstatus && plug="${plug}g:gitstatus;"
    colors=2136; fm_selection_has "$selected" colorscheme && colors=4231
    fm_as_user "$u" "touch ~/.profile; sed -i '/^# systui-nnn-config begin\$/,/^# systui-nnn-config end\$/d' ~/.profile; cat >> ~/.profile <<'EOF'
# systui-nnn-config begin
export NNN_OPTS='$opts'
export NNN_PLUG='${plug%;}'
$(fm_selection_has "$selected" color && echo "export NNN_COLORS='$colors'" || true)
$(fm_selection_has "$selected" trash && echo "export NNN_TRASH=1" || true)
$(fm_selection_has "$selected" icons && echo "export NNN_ICONS=1" || true)
$(fm_selection_has "$selected" fifo && echo 'export NNN_FIFO=/tmp/nnn.fifo' || true)
$(fm_selection_has "$selected" bookmarks && fm_selection_has "$selected" extrabm && echo "export NNN_BMS='h:~;d:~/Downloads;c:~/.config;p:~/Projects;t:/tmp'" || { fm_selection_has "$selected" bookmarks && echo "export NNN_BMS='h:~;d:~/Downloads;c:~/.config'"; } || true)
$(fm_selection_has "$selected" cdexit && cat <<'EOW'
n() {
    if [ -n "\$NNNLVL" ] && [ "\${NNNLVL:-0}" -ge 1 ]; then printf 'nnn is already running\n'; return; fi
    export NNN_TMPFILE=\"\${XDG_CONFIG_HOME:-\$HOME/.config}/nnn/.lastd\"
    nnn \"\$@\"
    [ -f \"\$NNN_TMPFILE\" ] && . \"\$NNN_TMPFILE\" && rm -f \"\$NNN_TMPFILE\"
}
EOW
)
# systui-nnn-config end
EOF"
    tui_msg "Configured" "nnn environment configuration generated for $u.\nNNN_OPTS='$opts'\n\nRe-login or source ~/.profile."
}

fm_configure_vifm_menu() {
    local u h f selected cols
    u=$(fm_target_user) || return 0; h=$(fm_home "$u"); f="$h/.config/vifm/vifmrc"
    selected=$(tui_check "Vifm configuration" "SPACE selects enabled settings:" \
        hidden      "Show hidden files" on \
        ignorecase  "Case-insensitive matching" on \
        smartcase   "Case-sensitive matching when capitals appear" on \
        incsearch   "Incremental search" on \
        hlsearch    "Highlight search matches" on \
        wildmenu    "Enable command completion menu" on \
        wildstyle   "Use a popup completion menu" off \
        syscalls    "Use direct system calls where possible" on \
        mouse       "Enable mouse support" on \
        trash       "Use the Vifm trash directory" on \
        confirm     "Confirm file deletion" on \
        dirfirst    "Sort directories first" on \
        numbers     "Show relative line numbers" off \
        size        "Show the file size column" on \
        permissions "Show the permissions column" on \
        mtime       "Show the modification time column" off \
        preview     "Map w to toggle the preview pane" on \
        quickview   "Enable quick view on start" off \
        millerview  "Enable Miller columns" off \
        statusline  "Show a detailed status line" on \
        history     "Keep a larger history" on \
        undolevels  "Increase undo levels to 100" on \
        homebind    "Map gh to home" on \
        configbind  "Map gc to the config directory" on \
        editor      "Use EDITOR as vicmd" on \
        fzfbind     "Map <c-f> to fzf when available" off \
        trashbind   "Map DD to move to trash" on) || return 0
    mkdir -p "$(dirname "$f")"; fm_backup_config "$f"
    {
        fm_selection_has "$selected" editor && echo 'set vicmd=$EDITOR' || echo 'set vicmd=vi'
        fm_selection_has "$selected" hidden && echo 'set dotfiles' || echo 'set nodotfiles'
        fm_selection_has "$selected" ignorecase && echo 'set ignorecase' || echo 'set noignorecase'
        fm_selection_has "$selected" smartcase && echo 'set smartcase'
        fm_selection_has "$selected" incsearch && echo 'set incsearch'
        fm_selection_has "$selected" hlsearch && echo 'set hlsearch'
        fm_selection_has "$selected" wildmenu && echo 'set wildmenu'
        fm_selection_has "$selected" wildstyle && echo 'set wildstyle=popup'
        fm_selection_has "$selected" syscalls && echo 'set syscalls'
        fm_selection_has "$selected" mouse && echo 'set mouse=a' || echo 'set mouse='
        fm_selection_has "$selected" trash && echo 'set trash' || echo 'set notrash'
        fm_selection_has "$selected" confirm && echo 'set confirm=delete,permdelete' || echo 'set confirm='
        fm_selection_has "$selected" dirfirst && echo 'set sortnumbers'
        fm_selection_has "$selected" numbers && echo 'set number relativenumber'
        fm_selection_has "$selected" history && echo 'set history=100'
        fm_selection_has "$selected" undolevels && echo 'set undolevels=100'
        fm_selection_has "$selected" millerview && echo 'set milleroptions=lsize:1,csize:2,rsize:1' && echo 'set millerview'
        fm_selection_has "$selected" quickview && echo 'view'
        cols='name'
        fm_selection_has "$selected" permissions && cols="permissions:10,$cols"
        fm_selection_has "$selected" size && cols="$cols,size:7"
        fm_selection_has "$selected" mtime && cols="$cols,mtime:15"
        echo "set viewcolumns=-$cols"
        fm_selection_has "$selected" statusline && echo 'set statusline="  %t%= %A %10u:%-7g %15s %20d  "'
        fm_selection_has "$selected" preview && echo 'map w :view<cr>'
        fm_selection_has "$selected" homebind && echo 'map gh :cd ~<cr>'
        fm_selection_has "$selected" configbind && echo 'map gc :cd ~/.config<cr>'
        fm_selection_has "$selected" trashbind && echo 'map DD :delete<cr>'
        fm_selection_has "$selected" fzfbind && echo 'command! FZFlocate :set noquickview | :!find . -type f 2>/dev/null | fzf > /tmp/vifm-fzf %i'
    } > "$f"
    chown -R "$u":"$(id -gn "$u")" "$h/.config/vifm" 2>/dev/null || true
    tui_msg "Configured" "Vifm configuration generated for $u ($(grep -c . "$f") lines)."
}

fm_configure_broot_menu() {
    local u h f selected
    u=$(fm_target_user) || return 0; h=$(fm_home "$u"); f="$h/.config/broot/conf.hjson"
    selected=$(tui_check "Broot configuration" "SPACE selects enabled settings:" \
        hidden       "Show hidden files" on \
        gitignored   "Show git-ignored files" off \
        sizes        "Show file sizes" on \
        dates        "Show modification dates" off \
        permissions  "Show permissions" off \
        counts       "Show child counts for directories" off \
        gitstatus    "Show Git status" on \
        icons        "Show file icons" on \
        mouse        "Capture mouse input" on \
        quitroot     "Quit when the last state is cancelled" on \
        preview      "Enable the preview panel" on \
        syntax       "Enable syntax-highlighted previews" on \
        modal        "Enable modal (vim-like) mode" off \
        sortsize     "Sort by size by default" off \
        maxdepth     "Limit the default search depth" off \
        homeverb     "Add a home navigation verb" on \
        configverb   "Add a config-directory verb" on \
        trashverb    "Add a trash-put verb" on \
        editverb     "Add an edit-in-EDITOR verb" on \
        terminalverb "Add an open-terminal-here verb" off \
        gitdiffverb  "Add a git diff verb" off) || return 0
    mkdir -p "$(dirname "$f")"; fm_backup_config "$f"
    {
        echo '{'
        echo "  show_hidden: $(fm_selection_has "$selected" hidden && echo true || echo false)"
        echo "  show_gitignored: $(fm_selection_has "$selected" gitignored && echo true || echo false)"
        echo "  show_sizes: $(fm_selection_has "$selected" sizes && echo true || echo false)"
        echo "  show_dates: $(fm_selection_has "$selected" dates && echo true || echo false)"
        echo "  show_permissions: $(fm_selection_has "$selected" permissions && echo true || echo false)"
        echo "  show_counts: $(fm_selection_has "$selected" counts && echo true || echo false)"
        echo "  show_git_status: $(fm_selection_has "$selected" gitstatus && echo true || echo false)"
        echo "  icon_theme: $(fm_selection_has "$selected" icons && echo '"vscode"' || echo 'null')"
        echo "  capture_mouse: $(fm_selection_has "$selected" mouse && echo true || echo false)"
        echo "  quit_on_last_cancel: $(fm_selection_has "$selected" quitroot && echo true || echo false)"
        echo "  modal: $(fm_selection_has "$selected" modal && echo true || echo false)"
        echo "  syntax_theme: $(fm_selection_has "$selected" syntax && echo '"GithubDark"' || echo 'null')"
        fm_selection_has "$selected" sortsize && echo '  default_flags: "-s"'
        fm_selection_has "$selected" maxdepth && echo '  max_panels_count: 2'
        fm_selection_has "$selected" preview && echo '  show_selection_mark: true'
        echo '  verbs: ['
        fm_selection_has "$selected" homeverb    && echo '    { invocation: "home", key: "ctrl-h", execution: ":focus ~/" }'
        fm_selection_has "$selected" configverb  && echo '    { invocation: "conf", execution: ":focus ~/.config" }'
        fm_selection_has "$selected" trashverb   && echo '    { invocation: "trash", execution: "trash-put {file}", leave_broot: false }'
        fm_selection_has "$selected" editverb    && echo '    { invocation: "edit", key: "ctrl-e", execution: "$EDITOR {file}", leave_broot: false }'
        fm_selection_has "$selected" terminalverb && echo '    { invocation: "term", execution: "$SHELL", set_working_dir: true, leave_broot: false }'
        fm_selection_has "$selected" gitdiffverb && echo '    { invocation: "gd", execution: "git diff {file}", leave_broot: false }'
        echo '  ]'
        echo '}'
    } > "$f"
    chown -R "$u":"$(id -gn "$u")" "$h/.config/broot" 2>/dev/null || true
    tui_msg "Configured" "Broot configuration generated for $u ($(grep -c . "$f") lines)."
}

fm_configure_xplr_menu() {
    local u h f selected
    u=$(fm_target_user) || return 0; h=$(fm_home "$u"); f="$h/.config/xplr/init.lua"
    selected=$(tui_check "xplr configuration" "SPACE selects enabled settings:" \
        hidden      "Show hidden files" on \
        mouse       "Enable mouse support" on \
        dirfirst    "Sort directories first" on \
        natural     "Natural filename sorting" on \
        reverse     "Reverse sorting" off \
        caseignore  "Case-insensitive sorting" on \
        icons       "Enable icon support hooks" on \
        borders     "Draw panel borders" on \
        readonly    "Start in read-only mode" off \
        paginate    "Show the pagination indicator" on \
        selectionui "Show the selection panel" on \
        hidewarn    "Hide the startup warning banner" on \
        homebind    "Map g,h to home" on \
        configbind  "Map g,c to the config directory" on \
        rootbind    "Map g,r to the filesystem root" off \
        shellbind   "Map ! to interactive shell" on \
        quitbind    "Map q to quit" on \
        quitcdbind  "Map Q to quit and print the directory" off \
        trashbind   "Map d to trash-put" on \
        editbind    "Map e to open in EDITOR" on \
        copybind    "Map y,p to copy the path to the clipboard" off \
        mkdirbind   "Map m,d to create a directory" off) || return 0
    mkdir -p "$(dirname "$f")"; fm_backup_config "$f"
    {
        echo "version = '0.21.9'"
        echo
        echo "xplr.config.general.show_hidden = $(fm_selection_has "$selected" hidden && echo true || echo false)"
        echo "xplr.config.general.enable_mouse = $(fm_selection_has "$selected" mouse && echo true || echo false)"
        echo "xplr.config.general.read_only = $(fm_selection_has "$selected" readonly && echo true || echo false)"
        echo "xplr.config.general.enable_recover_mode = true"
        fm_selection_has "$selected" hidewarn && echo "xplr.config.general.disable_debug_error_mode = true"
        fm_selection_has "$selected" paginate || echo "xplr.config.general.paginated_ui = false"
        fm_selection_has "$selected" selectionui || echo "xplr.config.general.selection_ui = nil"
        fm_selection_has "$selected" borders && echo "xplr.config.general.panel_ui.default.borders = { 'Top', 'Right', 'Bottom', 'Left' }"
        echo
        echo "-- Sorters are applied in order."
        echo "xplr.config.general.initial_sorting = {"
        fm_selection_has "$selected" dirfirst && echo "  { sorter = 'ByIsDir', reverse = false },"
        if fm_selection_has "$selected" natural; then
            echo "  { sorter = 'ByIRelativePath', reverse = $(fm_selection_has "$selected" reverse && echo true || echo false) },"
        elif fm_selection_has "$selected" caseignore; then
            echo "  { sorter = 'ByIRelativePath', reverse = $(fm_selection_has "$selected" reverse && echo true || echo false) },"
        else
            echo "  { sorter = 'ByRelativePath', reverse = $(fm_selection_has "$selected" reverse && echo true || echo false) },"
        fi
        echo "}"
        echo
        echo "local key = xplr.config.modes.builtin.default.key_bindings.on_key"
        fm_selection_has "$selected" quitbind && echo "key.q = { help = 'quit', messages = { 'Quit' } }"
        fm_selection_has "$selected" quitcdbind && echo "key.Q = { help = 'quit and print', messages = { 'PrintPwdAndQuit' } }"
        fm_selection_has "$selected" shellbind && echo "key['!'] = { help = 'shell', messages = { { BashExec0 = [[\${SHELL:-sh}]] } } }"
        fm_selection_has "$selected" homebind && echo "key.g = { help = 'go to', messages = { 'PopMode', { SwitchModeCustom = 'go_to' } } }"
        fm_selection_has "$selected" editbind && echo "key.e = { help = 'edit', messages = { { BashExec0 = [[\${EDITOR:-vi} \"\$XPLR_FOCUS_PATH\"]] } } }"
        fm_selection_has "$selected" trashbind && echo "key.d = { help = 'trash', messages = { { BashExecSilently0 = [[trash-put \"\$XPLR_FOCUS_PATH\"]] }, 'ExplorePwdAsync' } }"
        fm_selection_has "$selected" copybind && echo "key.y = { help = 'copy path', messages = { { BashExecSilently0 = [[printf '%s' \"\$XPLR_FOCUS_PATH\" | (xclip -sel clip 2>/dev/null || wl-copy 2>/dev/null)]] } } }"
        fm_selection_has "$selected" mkdirbind && echo "key.m = { help = 'mkdir', messages = { { BashExec0 = [[printf 'Directory name: '; read -r d; [ -n \"\$d\" ] && mkdir -p -- \"\$d\"]] }, 'ExplorePwdAsync' } }"
        echo
        echo "xplr.config.modes.builtin.default.key_bindings.on_key['g'] = xplr.config.modes.builtin.default.key_bindings.on_key['g'] or nil"
        fm_selection_has "$selected" configbind && echo "-- g,c and g,r are provided by the go_to mode; see :help go_to"
        fm_selection_has "$selected" icons && echo "-- Install an icon plugin from the plugin manager to activate icon rendering."
    } > "$f"
    chown -R "$u":"$(id -gn "$u")" "$h/.config/xplr" 2>/dev/null || true
    tui_msg "Configured" "xplr configuration generated for $u ($(grep -c . "$f") lines)."
}

fm_configure_menu() {
    case "$1" in
        mc) fm_configure_mc_menu ;;
        lf) fm_configure_lf_menu ;;
        tere) fm_configure_tere_menu ;;
        yazi) fm_configure_yazi_menu ;;
        ranger) fm_configure_ranger_menu ;;
        nnn) fm_configure_nnn_menu ;;
        vifm) fm_configure_vifm_menu ;;
        broot) fm_configure_broot_menu ;;
        xplr) fm_configure_xplr_menu ;;
    esac
}

fm_edit_config() {
    local fm="$1" u h f
    u=$(fm_target_user) || return 0; h=$(fm_home "$u")
    case "$fm" in
        lf) f="$h/.config/lf/lfrc" ;;
        mc)   f="$h/.config/mc/ini" ;;
        tere) f="$h/.bashrc" ;;
        yazi) f="$h/.config/yazi/yazi.toml" ;;
        ranger) f="$h/.config/ranger/rc.conf" ;;
        nnn) f="$h/.profile" ;;
        vifm) f="$h/.config/vifm/vifmrc" ;;
        broot) f="$h/.config/broot/conf.hjson" ;;
        xplr) f="$h/.config/xplr/init.lua" ;;
    esac
    mkdir -p "$(dirname "$f")"; touch "$f"; chown "$u":"$(id -gn "$u")" "$f" 2>/dev/null || true
    safe_edit "$f"
}

fm_plugin_catalog() { # tag|description|repo|destination-relative
    case "$1" in
        mc)
            # mc has no plugin API in the lf/yazi sense. What the ecosystem
            # actually ships is skins (.ini colour schemes read from
            # ~/.local/share/mc/skins), plus extension and syntax files under
            # ~/.config/mc. These are the upstream repositories for those.
            cat <<'EOF'
mc-upstream|Official mc source: bundled skins, syntax and extfs helpers|MidnightCommander/mc|.local/share/mc/skins/mc-upstream
mc-retro-skins|Norton, Volkov and Far Commander skins|kybl/midnight-commander-skins|.local/share/mc/skins/retro
mc-solarized|Solarized skins for 256-colour and truecolour terminals|mstilkerich/mc-solarized-truecolor|.local/share/mc/skins/solarized
mashdark|MashDark — modern dark skin with separate border colours|notnout/mashdark|.local/share/mc/skins/mashdark
mc-skins-unobtec|Community skin collection|unobtec/mc-skins|.local/share/mc/skins/unobtec
mc-skins-fsmulski|Skin collection tuned for solarized terminals|fsmulski/mc-skins|.local/share/mc/skins/fsmulski
mc-skins-wang|Assorted community skins|wang95/mc-skins|.local/share/mc/skins/wang
EOF
            ;;
        lf)
            cat <<'EOF'
lf-sixel|Sixel image preview helper|horriblename/lf-sixel|.config/lf/plugins/lf-sixel
lf-gadgets|Preview and utility scripts|dylanaraps/lf|.config/lf/plugins/lf-upstream
lf-icons|Nerd Font icon configuration|gokcehan/lf|.config/lf/plugins/lf-icons-source
lf-preview|Preview scripts and cleaner integration|gokcehan/lf|.config/lf/plugins/preview
lfcd|Shell directory-change integration|gokcehan/lf|.config/lf/plugins/lfcd
EOF
            ;;
        tere)
            cat <<'EOF'
tere-fzf|fzf-oriented shell integration examples|mgunyho/tere|.config/tere/addons/tere-upstream
tere-zoxide|zoxide workflow integration examples|ajeetdsouza/zoxide|.config/tere/addons/zoxide
tere-starship|Prompt integration examples|starship/starship|.config/tere/addons/starship
EOF
            ;;
        yazi)
            cat <<'EOF'
full-border|Full border UI plugin|yazi-rs/plugins|.config/yazi/plugins/full-border.yazi
smart-enter|Context-aware Enter key|yazi-rs/plugins|.config/yazi/plugins/smart-enter.yazi
chmod|Interactive chmod plugin|yazi-rs/plugins|.config/yazi/plugins/chmod.yazi
max-preview|Maximize preview pane|yazi-rs/plugins|.config/yazi/plugins/max-preview.yazi
jump-to-char|Jump to item by character|yazi-rs/plugins|.config/yazi/plugins/jump-to-char.yazi
starship|Starship prompt integration|Rolv-Apneseth/starship.yazi|.config/yazi/plugins/starship.yazi
git|Git status and actions|yazi-rs/plugins|.config/yazi/plugins/git.yazi
mount|Mount removable filesystems|yazi-rs/plugins|.config/yazi/plugins/mount.yazi
ouch|Create files and directories|yazi-rs/plugins|.config/yazi/plugins/ouch.yazi
lazygit|Open repositories in lazygit|Lil-Dank/lazygit.yazi|.config/yazi/plugins/lazygit.yazi
EOF
            ;;
        ranger)
            cat <<'EOF'
ranger-devicons|Nerd Font file icons|alexanderjeurissen/ranger_devicons|.config/ranger/plugins/ranger_devicons
ranger-fzf|fzf integration commands|MuXiu1997/ranger-fzf-filter|.config/ranger/plugins/ranger-fzf-filter
ranger-zoxide|zoxide directory jumping|jchook/ranger-zoxide|.config/ranger/plugins/ranger-zoxide
ranger-archives|Archive extraction helpers|maximtrp/ranger-archives|.config/ranger/plugins/ranger-archives
ranger-git|Git status integration|ranger/ranger|.config/ranger/plugins/ranger-git
ranger-trash|Trash-cli integration|ranger/ranger|.config/ranger/plugins/ranger-trash
ranger-autojump|Directory jumping integration|ranger/ranger|.config/ranger/plugins/ranger-autojump
EOF
            ;;
        nnn)
            cat <<'EOF'
plugins|Official nnn plugin collection|jarun/nnn|.config/nnn/plugins-source
icons|Nerd Font icon support|jarun/nnn|.config/nnn/icons-source
preview-tui|Official preview-tui plugin assets|jarun/nnn|.config/nnn/preview-tui-source
fzopen|Official fzf opener plugin|jarun/nnn|.config/nnn/fzopen-source
autofifo|Official FIFO preview helper|jarun/nnn|.config/nnn/autofifo-source
EOF
            ;;
        vifm)
            cat <<'EOF'
vifm-colors|Official color schemes|vifm/vifm-colors|.config/vifm/colors
vifmimg|Image preview helper|thimc/vifmimg|.config/vifm/plugins/vifmimg
EOF
            ;;
        broot)
            cat <<'EOF'
broot-upstream|Official skins and verb examples|Canop/broot|.config/broot/addons/broot-upstream
EOF
            ;;
        xplr)
            cat <<'EOF'
zoxide|zoxide integration|sayanarijit/zoxide.xplr|.config/xplr/plugins/zoxide
fzf|fzf integration|sayanarijit/fzf.xplr|.config/xplr/plugins/fzf
icons|Nerd Font icons|sayanarijit/dua-cli.xplr|.config/xplr/plugins/dua-cli
trash-cli|Safe trash integration|sayanarijit/trash-cli.xplr|.config/xplr/plugins/trash-cli
map|Interactive directory map|sayanarijit/map.xplr|.config/xplr/plugins/map
dual-pane|Dual-pane layout|sayanarijit/dual-pane.xplr|.config/xplr/plugins/dual-pane
command-mode|Command palette workflows|sayanarijit/command-mode.xplr|.config/xplr/plugins/command-mode
EOF
            ;;
    esac
}

# ---- File-manager plugin registry -------------------------------------------
#
# Curated entries in fm_plugin_catalog remain the offline baseline. On top of
# that, each file manager may declare a community index that is fetched, parsed
# into TSV and cached, so the plugin menus reflect the live ecosystem rather
# than a list frozen at release time.
#
# TSV columns: tag <TAB> category <TAB> name <TAB> owner/repo <TAB> dest <TAB> description
FM_PLUGIN_REGISTRY_VERSION=1

fm_plugin_index_url() { # <fm> -> URL, or empty when no community index exists
    case "$1" in
        yazi)   printf '%s\n' "https://raw.githubusercontent.com/AnirudhG07/awesome-yazi/main/README.md" ;;
        ranger) printf '%s\n' "https://raw.githubusercontent.com/wiki/ranger/ranger/Plugins.md" ;;
        nnn)    printf '%s\n' "https://raw.githubusercontent.com/jarun/nnn/master/plugins/README.md" ;;
        *)      return 1 ;;
    esac
}

fm_plugin_cache_dir() {
    local dir
    if [ -n "${SYSTUI_FM_PLUGIN_CACHE:-}" ]; then dir="$SYSTUI_FM_PLUGIN_CACHE"
    elif [ "$(id -u)" -eq 0 ]; then dir=/var/cache/systui/fm-plugins
    else dir="${XDG_CACHE_HOME:-$HOME/.cache}/systui/fm-plugins"
    fi
    printf '%s\n' "$dir"
}

# Only owner/repo pairs are accepted, and only from github.com. A plugin entry
# is a clone target that later runs inside the user's file manager, so a
# malformed or hostile "repo" field must never reach git.
fm_plugin_valid_repo() { # <owner/repo>
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
}

# Destinations are confined to the file manager's own config directory.
fm_plugin_valid_dest() { # <fm> <dest-relative-to-home>
    case "$2" in
        ".config/$1/"*|".local/share/$1/"*)
            case "$2" in *..*) return 1 ;; esac
            return 0 ;;
    esac
    return 1
}

fm_plugin_fetch() { # <url> <destination>
    local url="$1" dst="$2" tmp="$2.tmp.$$"
    mkdir -p "$(dirname "$dst")" || return 1
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 2 --connect-timeout 15 --max-time 120 \
            --proto '=https' --tlsv1.2 "$url" -o "$tmp" >>"$LOGFILE" 2>&1
    elif command -v wget >/dev/null 2>&1; then
        wget -q --https-only --timeout=120 -O "$tmp" "$url" >>"$LOGFILE" 2>&1
    else
        return 1
    fi || { rm -f "$tmp"; return 1; }
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dst"
}

# awesome-yazi lists each plugin as
#   <a href="https://github.com/OWNER/REPO">name</a> - description.
# inside a <details><summary> block, grouped by "### Category" headings.
fm_plugin_parse_yazi() { # <README> <out.tsv>
    awk '
        function clean(x) {
            gsub(/<[^>]*>/, "", x); gsub(/\r/, "", x); gsub(/\t/, " ", x)
            gsub(/  +/, " ", x); sub(/^[ -]+/, "", x); sub(/ +$/, "", x)
            return x
        }
        /^###[[:space:]]/ { cat = clean(substr($0, 4)); next }
        /^##[[:space:]]/  { cat = clean(substr($0, 3)); next }
        /href="https:\/\/github\.com\// {
            line = $0
            if (match(line, /github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+/) == 0) next
            repo = substr(line, RSTART + 11, RLENGTH - 11)
            sub(/\.git$/, "", repo)
            # Take everything after the FIRST </a>. A greedy match would run
            # past the closing tag of any link nested inside the description
            # and leave only the trailing punctuation behind.
            rest = line
            p = index(rest, "</a>")
            if (p > 0) rest = substr(rest, p + 4)
            desc = clean(rest)
            sub(/^[[:space:]]*-[[:space:]]*/, "", desc)
            n = split(repo, parts, "/")
            name = parts[n]
            if (name == "" || repo !~ /\//) next
            if (seen[repo]++) next
            tag = name; gsub(/[^A-Za-z0-9._-]/, "-", tag)
            if (desc == "") desc = "No description available"
            printf "%s\t%s\t%s\t%s\t%s\t%s\n", tag, (cat == "" ? "Plugins" : cat), name, repo, ".config/yazi/plugins/" name, desc
        }
    ' "$1" > "$2"
}

# The ranger wiki lists plugins as
#   - [name](https://github.com/OWNER/REPO), description
fm_plugin_parse_ranger() { # <README> <out.tsv>
    awk '
        function clean(x) {
            gsub(/\[|\]/, "", x); gsub(/\([^)]*\)/, "", x); gsub(/`/, "", x)
            gsub(/\r/, "", x); gsub(/\t/, " ", x); gsub(/  +/, " ", x)
            sub(/^[ ,]+/, "", x); sub(/ +$/, "", x); return x
        }
        /^- \[/ {
            line = $0
            if (match(line, /github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+/) == 0) next
            repo = substr(line, RSTART + 11, RLENGTH - 11)
            sub(/\.git$/, "", repo)
            # Skip deep links to a file inside a repository.
            if (line ~ /github\.com\/[^)]*\/blob\//) next
            name = line; sub(/^- \[/, "", name); sub(/\].*$/, "", name)
            if (name == "") next
            if (seen[repo]++) next
            desc = line; sub(/^[^)]*\)[,]?[[:space:]]*/, "", desc); desc = clean(desc)
            tag = name; gsub(/[^A-Za-z0-9._-]/, "-", tag)
            if (desc == "") desc = "No description available"
            printf "%s\t%s\t%s\t%s\t%s\t%s\n", tag, "Plugins", name, repo, ".config/ranger/plugins/" tag, desc
        }
    ' "$1" > "$2"
}

# nnn ships its plugins in-tree, listed as a markdown table:
#   | [name](name) | description | lang | dependencies |
# They all live in jarun/nnn, so the repo column is constant and the tag
# identifies which script to link.
fm_plugin_parse_nnn() { # <README> <out.tsv>
    awk -F'|' '
        function clean(x) {
            # Keep the label of a markdown link rather than deleting the whole
            # construct: a dependency cell is often nothing but links, and
            # dropping them left the cell empty.
            while (match(x, /\[[^]]*\]\([^)]*\)/)) {
                lbl = substr(x, RSTART + 1, index(substr(x, RSTART), "]") - 2)
                x = substr(x, 1, RSTART - 1) lbl substr(x, RSTART + RLENGTH)
            }
            gsub(/<[^>]*>/, "", x)
            gsub(/`/, "", x); gsub(/\r/, "", x); gsub(/\t/, " ", x)
            gsub(/  +/, " ", x); sub(/^ +/, "", x); sub(/ +$/, "", x); return x
        }
        NF >= 4 && $2 ~ /^[[:space:]]*\[/ {
            name = $2; sub(/^[[:space:]]*\[/, "", name); sub(/\].*$/, "", name)
            if (name == "" || name ~ /[^A-Za-z0-9._-]/) next
            if (seen[name]++) next
            desc = clean($3); if (desc == "") desc = "No description available"
            deps = clean($5)
            # Dependency cells often hold markdown links; clean() strips the
            # label and leaves the bare separators behind.
            gsub(/^[\/, ]+|[\/, ]+$/, "", deps)
            gsub(/[\/,][[:space:]]*[\/,]/, ", ", deps)
            if (deps != "" && deps != "-") desc = desc " (needs: " deps ")"
            printf "%s\t%s\t%s\t%s\t%s\t%s\n", name, "Official plugins", name, "jarun/nnn", ".config/nnn/plugins/" name, desc
        }
    ' "$1" > "$2"
}

fm_plugin_parse() { # <fm> <README> <out.tsv>
    case "$1" in
        yazi)   fm_plugin_parse_yazi   "$2" "$3" ;;
        ranger) fm_plugin_parse_ranger "$2" "$3" ;;
        nnn)    fm_plugin_parse_nnn    "$2" "$3" ;;
        *) return 1 ;;
    esac
}

# A catalogue is only accepted if every row is well formed. A partially parsed
# index is worse than none: it would offer entries whose repo or destination
# were never validated.
fm_plugin_catalog_valid() { # <fm> <tsv>
    local fm="$1" tsv="$2" tag cat name repo dest desc rows=0
    [ -s "$tsv" ] || return 1
    while IFS=$'\t' read -r tag cat name repo dest desc; do
        [ -n "$tag" ] || continue
        fm_plugin_valid_repo "$repo" || return 1
        fm_plugin_valid_dest "$fm" "$dest" || return 1
        rows=$((rows + 1))
    done < "$tsv"
    [ "$rows" -gt 0 ]
}

fm_plugin_sync() { # <fm> -- refresh the cached catalogue from upstream
    local fm="$1" url dir readme tsv tmp
    url=$(fm_plugin_index_url "$fm") || {
        tui_msg "No index" "$fm has no community plugin index.\nThe built-in curated list is used instead."
        return 1
    }
    dir=$(fm_plugin_cache_dir); readme="$dir/$fm.md"; tsv="$dir/$fm.tsv"; tmp="$dir/$fm.tsv.new"
    mkdir -p "$dir" || { tui_msg "Cache" "Could not create the cache directory:\n$dir"; return 1; }
    if ! run_cmd "Fetching the $fm plugin index" fm_plugin_fetch "$url" "$readme"; then
        if [ -s "$tsv" ]; then
            tui_msg "Offline" "Could not reach the $fm plugin index.\nThe previously cached catalogue is still in use."
            return 0
        fi
        tui_msg "Unavailable" "Could not reach the $fm plugin index and no cache exists.\nThe built-in curated list is used instead."
        return 1
    fi
    fm_plugin_parse "$fm" "$readme" "$tmp" || { rm -f "$tmp"; tui_msg "Parse failed" "The $fm index could not be parsed."; return 1; }
    if ! fm_plugin_catalog_valid "$fm" "$tmp"; then
        rm -f "$tmp"
        tui_msg "Rejected" "The parsed $fm catalogue failed validation and was discarded.\nThe previous catalogue is unchanged."
        return 1
    fi
    mv -f "$tmp" "$tsv"
    printf '%s\n' "$FM_PLUGIN_REGISTRY_VERSION" > "$dir/$fm.version"
    tui_msg "Synchronised" "$(wc -l < "$tsv" | tr -d ' ') $fm plugins are now available."
}

# Merged view: curated entries first (they are known-good and work offline),
# then any fetched entries that are not already covered.
fm_plugin_registry() { # <fm>
    local fm="$1" dir tsv tag desc repo dest seen=""
    while IFS='|' read -r tag desc repo dest; do
        [ -n "$tag" ] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tag" "Curated" "$tag" "$repo" "$dest" "$desc"
        seen="$seen $dest"
    done < <(fm_plugin_catalog "$fm")
    dir=$(fm_plugin_cache_dir); tsv="$dir/$fm.tsv"
    [ -s "$tsv" ] || return 0
    while IFS=$'\t' read -r tag cat name repo dest desc; do
        [ -n "$tag" ] || continue
        # Deduplicate on the destination, not the repository. One repository
        # legitimately provides many plugins (yazi-rs/plugins) and one
        # repository can be the source of an entire in-tree set (jarun/nnn);
        # keying on repo collapsed 58 nnn plugins down to 1.
        case " $seen " in *" $dest "*) continue ;; esac
        seen="$seen $dest"
        fm_plugin_valid_repo "$repo" || continue
        fm_plugin_valid_dest "$fm" "$dest" || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tag" "$cat" "$name" "$repo" "$dest" "$desc"
    done < "$tsv"
}

fm_plugin_registry_count() { # <fm>
    fm_plugin_registry "$1" | grep -c . || true
}

# Space-to-select installation over the merged registry. Large catalogues are
# paged by category so a 150-entry checklist never has to be rendered at once.
fm_plugins_install() { # <fm> [category]
    local fm="$1" want_cat="${2:-}" u h
    u=$(fm_target_user) || return 0; h=$(fm_home "$u")
    local reg; reg="$SYSTUI_TMP/fmreg.$fm"
    fm_plugin_registry "$fm" > "$reg"
    [ -s "$reg" ] || { tui_msg "Plugins" "No add-ons are known for $fm."; return 0; }

    # Offer a category picker when the catalogue is large enough to warrant it.
    if [ -z "$want_cat" ]; then
        local cats cargs=() cat n total
        total=$(grep -c . "$reg")
        cats=$(awk -F'\t' '{print $2}' "$reg" | sort -u)
        if [ "$total" -gt 40 ] && [ "$(printf '%s\n' "$cats" | grep -c .)" -gt 1 ]; then
            while IFS= read -r cat; do
                [ -n "$cat" ] || continue
                n=$(awk -F'\t' -v c="$cat" '$2==c' "$reg" | grep -c .)
                cargs+=("$cat" "$cat ($n)")
            done <<< "$cats"
            cargs+=(__all "All categories ($total)" __back "Back")
            want_cat=$(tui_menu_no_tags "$fm add-ons" "$total add-ons available. Choose a category:" "${cargs[@]}") || return 0
            [ "$want_cat" = __back ] && return 0
            [ "$want_cat" = __all ] && want_cat=""
        fi
    fi

    local args=() tag cat name repo dest desc state shown=0
    while IFS=$'\t' read -r tag cat name repo dest desc; do
        [ -n "$tag" ] || continue
        [ -n "$want_cat" ] && [ "$cat" != "$want_cat" ] && continue
        fm_plugin_valid_repo "$repo" || continue
        fm_plugin_valid_dest "$fm" "$dest" || continue
        [ -d "$h/$dest" ] && state=on || state=off
        args+=("$tag" "$name — $desc" "$state")
        shown=$((shown + 1))
    done < "$reg"
    [ "$shown" -gt 0 ] || { tui_msg "Plugins" "No add-ons matched that category."; return 0; }

    local selected
    selected=$(tui_check "$fm add-ons${want_cat:+ — $want_cat}" \
        "SPACE toggles. Checked entries are installed or updated; existing repositories are pulled." \
        "${args[@]}") || return 0
    selected=${selected//\"/}
    [ -n "${selected// }" ] || { tui_msg "Plugins" "Nothing was selected."; return 0; }

    command -v git >/dev/null 2>&1 || pm_install git || return 1

    local item ok=0 failed=""
    for item in $selected; do
        while IFS=$'\t' read -r tag cat name repo dest desc; do
            [ "$tag" = "$item" ] || continue
            fm_plugin_valid_repo "$repo" || { warn "Refused plugin repository: $repo"; continue; }
            fm_plugin_valid_dest "$fm" "$dest" || { warn "Refused plugin destination: $dest"; continue; }
            if fm_as_user "$u" "mkdir -p \"\$(dirname ~/$dest)\"; if [ -d ~/$dest/.git ]; then git -C ~/$dest pull --ff-only; else rm -rf ~/$dest; git clone --depth 1 https://github.com/$repo.git ~/$dest; fi" >>"$LOGFILE" 2>&1; then
                ok=$((ok + 1))
            else
                failed="$failed $tag"
            fi
            break
        done < "$reg"
    done
    rm -f "$reg"
    if [ -n "$failed" ]; then
        tui_msg "Plugins" "Installed or updated $ok add-on(s) for $u.\n\nFailed:$failed\n\nSee $LOGFILE."
    else
        tui_msg "Plugins" "Installed or updated $ok add-on(s) for $u."
    fi
}

# Free-text search across the merged registry.
fm_plugins_search() { # <fm>
    local fm="$1" q reg hits
    q=$(tui_input "Search $fm add-ons" "Name or description:" "") || return 0
    [ -n "$q" ] || return 0
    reg="$SYSTUI_TMP/fmreg.$fm"; fm_plugin_registry "$fm" > "$reg"
    hits="$SYSTUI_TMP/fmhits.$fm"
    awk -F'\t' -v q="$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]')" '
        tolower($3) ~ q || tolower($6) ~ q || tolower($2) ~ q
    ' "$reg" > "$hits"
    if [ ! -s "$hits" ]; then
        tui_msg "No matches" "No $fm add-on matched \"$q\"."
        rm -f "$reg" "$hits"; return 0
    fi
    local u h args=() tag cat name repo dest desc state
    u=$(fm_target_user) || { rm -f "$reg" "$hits"; return 0; }
    h=$(fm_home "$u")
    while IFS=$'\t' read -r tag cat name repo dest desc; do
        [ -n "$tag" ] || continue
        [ -d "$h/$dest" ] && state=on || state=off
        args+=("$tag" "$name — $desc" "$state")
    done < "$hits"
    local selected item
    selected=$(tui_check "Search results — $q" "SPACE toggles entries to install:" "${args[@]}") || { rm -f "$reg" "$hits"; return 0; }
    selected=${selected//\"/}
    command -v git >/dev/null 2>&1 || pm_install git
    for item in $selected; do
        while IFS=$'\t' read -r tag cat name repo dest desc; do
            [ "$tag" = "$item" ] || continue
            fm_plugin_valid_repo "$repo" && fm_plugin_valid_dest "$fm" "$dest" || continue
            fm_as_user "$u" "mkdir -p \"\$(dirname ~/$dest)\"; if [ -d ~/$dest/.git ]; then git -C ~/$dest pull --ff-only; else rm -rf ~/$dest; git clone --depth 1 https://github.com/$repo.git ~/$dest; fi" >>"$LOGFILE" 2>&1 || warn "Failed to install $tag"
            break
        done < "$hits"
    done
    rm -f "$reg" "$hits"
    tui_msg "Plugins" "Selected add-ons were processed for $u."
}

# Read-only listing of everything the registry knows about.
fm_plugins_browse() { # <fm>
    local fm="$1" out="$SYSTUI_TMP/fmbrowse"
    fm_plugin_registry "$fm" | awk -F'\t' '
        { if ($2 != last) { printf "\n== %s ==\n", $2; last = $2 }
          printf "  %-32s %s\n", $3, $6 }
    ' > "$out"
    [ -s "$out" ] || printf '(no add-ons known)\n' > "$out"
    tui_text "$fm add-on catalogue" "$out"
}

fm_plugins_remove() { # <fm>
    local fm="$1" u h reg tag cat name repo dest desc selected item target
    u=$(fm_target_user) || return 0; h=$(fm_home "$u")
    reg="$SYSTUI_TMP/fmreg.$fm"; fm_plugin_registry "$fm" > "$reg"
    local args=()
    while IFS=$'\t' read -r tag cat name repo dest desc; do
        [ -n "$tag" ] || continue
        [ -d "$h/$dest" ] || continue
        args+=("$tag" "$name — $desc" off)
    done < "$reg"
    if [ ${#args[@]} -eq 0 ]; then
        rm -f "$reg"
        tui_msg "Plugins" "No managed $fm add-ons are installed for $u."
        return 0
    fi
    selected=$(tui_check "Remove $fm add-ons" "SPACE selects add-ons to remove:" "${args[@]}") || { rm -f "$reg"; return 0; }
    selected=${selected//\"/}
    local removed=0
    for item in $selected; do
        while IFS=$'\t' read -r tag cat name repo dest desc; do
            [ "$tag" = "$item" ] || continue
            # Re-validate at the point of deletion rather than trusting the
            # catalogue row: this is an rm -rf running as root.
            if ! fm_plugin_valid_dest "$fm" "$dest"; then
                warn "Refused unsafe plugin removal path: $dest"; break
            fi
            target="$h/$dest"
            case "$target" in
                "$h/.config/$fm/"*|"$h/.local/share/$fm/"*)
                    rm -rf -- "$target"; removed=$((removed + 1)) ;;
                *) warn "Refused unsafe plugin removal path: $target" ;;
            esac
            break
        done < "$reg"
    done
    rm -f "$reg"
    tui_msg "Plugins" "Removed $removed add-on(s). Configuration references may still need manual removal."
}

fm_plugins_custom() {
    local fm="$1" u h url name dest
    u=$(fm_target_user) || return 0; h=$(fm_home "$u")
    url=$(tui_input "Custom GitHub add-on" "Git repository URL:" "https://github.com/") || return 0
    [ "$url" != "https://github.com/" ] || return 0
    name=$(basename "$url" .git); dest="$h/.config/$fm/plugins/$name"
    command -v git >/dev/null 2>&1 || pm_install git
    fm_as_user "$u" "mkdir -p ~/.config/$fm/plugins; git clone --depth 1 '$url' ~/.config/$fm/plugins/'$name'" \
        && tui_msg "Installed" "$name installed at $dest"
}

menu_fm_plugins() {
    local fm="$1" c u h g count src
    while true; do
        count=$(fm_plugin_registry "$fm" | grep -c . || true)
        if fm_plugin_index_url "$fm" >/dev/null 2>&1; then
            src="community index available"
        else
            src="curated list only"
        fi
        c=$(tui_menu "$fm — Plugin Manager" \
            "$count add-ons known ($src).\nGitHub add-ons, themes, previewers and frameworks:" \
            install "Install/update add-ons (SPACE to select)" \
            search  "Search the add-on catalogue" \
            browse  "Browse the full catalogue" \
            sync    "Refresh the catalogue from upstream" \
            remove  "Remove managed add-ons" \
            custom  "Install custom Git repository" \
            update  "Update all managed Git repositories" \
            status  "Show installed managed add-ons" \
            back    "Back") || return 0
        case "$c" in
            install) fm_plugins_install "$fm" ;;
            search)  fm_plugins_search "$fm" ;;
            browse)  fm_plugins_browse "$fm" ;;
            sync)    fm_plugin_sync "$fm" ;;
            remove)  fm_plugins_remove "$fm" ;;
            custom)  fm_plugins_custom "$fm" ;;
            update)
                u=$(fm_target_user) || continue; h=$(fm_home "$u")
                find "$h/.config/$fm" "$h/.local/share/$fm" -type d -name .git -print0 2>/dev/null |
                    while IFS= read -r -d "" g; do fm_as_user "$u" "git -C '${g%/.git}' pull --ff-only"; done
                tui_msg "Updated" "Managed repositories were updated." ;;
            status)
                u=$(fm_target_user) || continue; h=$(fm_home "$u")
                find "$h/.config/$fm" "$h/.local/share/$fm" -type d -name .git 2>/dev/null |
                    sed 's#/.git$##' > "$SYSTUI_TMP/fmplugins"
                [ -s "$SYSTUI_TMP/fmplugins" ] || echo "(none)" > "$SYSTUI_TMP/fmplugins"
                tui_text "$fm managed add-ons" "$SYSTUI_TMP/fmplugins" ;;
            back|"") return 0 ;;
        esac
    done
}

menu_file_manager_one() {
    local fm="$1" label="$2" c install_label
    while true; do
        install_label="Install $label"
        [ "$fm" = yazi ] && install_label="Install Yazi — distribution-aware methods"
        c=$(tui_menu "$label  $(st "$fm")" "Install, remove and configure $label:" \
            install "$install_label" \
            remove  "Remove $label" \
            configure "Space-to-select configuration menu" \
            default   "Write recommended default configuration" \
            edit      "Edit configuration" \
            mappings  "Key mapping configuration" \
            plugins "Plugin/add-on manager (GitHub)" \
            launch  "Launch $label" \
            back    "Back") || return 0
        case "$c" in
            install) fm_install "$fm" ;;
            remove) fm_remove "$fm" ;;
            configure) fm_configure_menu "$fm" ;;
            default) fm_write_default_config "$fm" ;;
            edit) fm_edit_config "$fm" ;;
            mappings) menu_file_manager_mappings "$fm" ;;
            plugins) menu_fm_plugins "$fm" ;;
            launch) command -v "$fm" >/dev/null 2>&1 && "$fm" || tui_msg "Not installed" "Install $label first." ;;
            back) return 0 ;;
        esac
    done
}

menu_file_managers() {
    while true; do
        local c
        c=$(tui_menu "File Managers" "Terminal file managers and GitHub add-ons:" \
            mc     "Midnight Commander — dual-pane, skins & extensions $(st mc)" \
            lf     "lf — fast Go file manager $(st lf)" \
            tere   "tere — fast directory navigator $(st tere)" \
            yazi   "Yazi — async Rust file manager $(st yazi)" \
            ranger "Ranger — Vim-style Python file manager $(st ranger)" \
            nnn    "nnn — lightweight extensible file manager $(st nnn)" \
            vifm   "Vifm — dual-pane Vim-style manager $(st vifm)" \
            broot  "Broot — tree navigator and launcher $(st broot)" \
            xplr   "xplr — hackable Lua file explorer $(st xplr)" \
            back   "Back") || return 0
        case "$c" in
            mc) menu_file_manager_one mc "Midnight Commander" ;;
            lf) menu_file_manager_one lf "lf" ;;
            tere) menu_file_manager_one tere "tere" ;;
            yazi) menu_file_manager_one yazi "Yazi" ;;
            ranger) menu_file_manager_one ranger "Ranger" ;;
            nnn) menu_file_manager_one nnn "nnn" ;;
            vifm) menu_file_manager_one vifm "Vifm" ;;
            broot) menu_file_manager_one broot "Broot" ;;
            xplr) menu_file_manager_one xplr "xplr" ;;
            back) return 0 ;;
        esac
    done
}

# ---- Awesome Linux Software catalogue --------------------------------------
# Source: https://github.com/luong-komorebi/Awesome-Linux-Software
# The upstream list is intentionally synchronized at runtime so every listed
# application remains available without embedding a stale, hand-maintained copy.
AWESOME_LINUX_RAW_URL="https://raw.githubusercontent.com/luong-komorebi/Awesome-Linux-Software/master/README.md"
AWESOME_LINUX_CATALOG_VERSION=3

awesome_linux_cache_dir() {
    if [ "$(id -u)" -eq 0 ]; then
        printf '%s\n' "${SYSTUI_AWESOME_CACHE:-/var/cache/systui/awesome-linux}"
    else
        printf '%s\n' "${SYSTUI_AWESOME_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/systui/awesome-linux}"
    fi
}

awesome_linux_download() { # <destination>
    local dst tmp
    dst="$1"
    tmp="${dst}.tmp.$$"
    mkdir -p "$(dirname "$dst")" || return 1
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 15 --max-time 120 \
            --proto '=https' --tlsv1.2 "$AWESOME_LINUX_RAW_URL" -o "$tmp" >>"$LOGFILE" 2>&1
    elif command -v wget >/dev/null 2>&1; then
        wget -q --https-only --timeout=120 -O "$tmp" "$AWESOME_LINUX_RAW_URL" >>"$LOGFILE" 2>&1
    else
        tui_msg "Missing downloader" "Install curl or wget before synchronizing Awesome Linux."
        return 1
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dst"
}

awesome_linux_parse() { # <README> <catalog TSV>
    local src out tmp
    src="$1"
    out="$2"
    tmp="${out}.tmp.$$"
    # Output: id<TAB>category<TAB>name<TAB>homepage<TAB>source<TAB>description
    awk '
    function clean(x) {
        gsub(/\r/, "", x); gsub(/\t/, " ", x); gsub(/  +/, " ", x)
        sub(/^ +/, "", x); sub(/ +$/, "", x); return x
    }
    function stripmd(x) {
        gsub(/!\[[^]]*\]\([^)]*\)/, "", x)
        gsub(/\[[^]]*\]\[[^]]*\]/, "", x)
        gsub(/[*_`]/, "", x); return clean(x)
    }
    function slug(x, y) {
        y=tolower(x); gsub(/[^a-z0-9]+/, "-", y); gsub(/^-|-$/, "", y)
        if (y == "") y="item"; return y
    }
    function category_for(section, topic, detail, detail2, detail3, top, path) {
        # Rebuild the sprawling upstream headings into stable user-facing
        # groups while retaining every useful subcategory beneath them.
        if (section == "Applications") {
            top=topic
            if (topic == "Audio") top="Audio & Music"
            else if (topic == "Chat Clients") top="Communication"
            else if (topic == "Data Backup and Recovery") top="Backup & Recovery"
            else if (topic == "E-Book Utilities") top="E-Books & Reading"
            else if (topic == "Electronic") top="Electronics"
            else if (topic == "File Manager") top="File Management"
            else if (topic == "Games") top="Gaming & Emulation"
            else if (topic == "Graphics") top="Graphics, Design & Video"
            else if (topic == "Internet") top="Internet & Web"
            else if (topic == "Office") top="Office & Writing"
            else if (topic == "Proxy" || topic == "VPN") top="Network Privacy"
            else if (topic == "Sharing Files") top="Sharing & Remote Access"
            else if (topic == "Terminal") top="Terminal & CLI"
            else if (topic == "Text Editors") top="Editors & IDEs"
            else if (topic == "Utilities") top="System Utilities"
            else if (topic == "Video") top="Graphics, Design & Video"
            else if (topic == "Wiki Software") top="Knowledge & Wikis"
            else if (topic == "Others") top="Other Applications"
            if (top == "") top="Other Applications"
            path=top
            if (detail != "") path=path " / " detail
            if (detail2 != "") path=path " / " detail2
            if (detail3 != "") path=path " / " detail3
            return path
        }
        if (section == "Command Line Utilities") {
            path="Terminal & CLI"; if (topic != "") path=path " / " topic
            if (detail != "") path=path " / " detail
            if (detail2 != "") path=path " / " detail2
            if (detail3 != "") path=path " / " detail3
            return path
        }
        if (section == "Custom Linux Kernels") return "System / Custom Linux Kernels"
        if (section == "Desktop Environments") return "Desktop / Desktop Environments"
        if (section == "Display manager") {
            path="Desktop / Display Managers"; if (topic != "") path=path " / " topic
            return path
        }
        if (section == "Window Managers") {
            path="Desktop / Window Managers"; if (topic != "") path=path " / " topic
            return path
        }
        return ""
    }
    BEGIN { h2=""; h3=""; h4=""; h5=""; h6=""; n=0; software=0 }
    /^## /  {
        h2=stripmd(substr($0,4)); h3=""; h4=""; h5=""; h6=""
        software=(h2 == "Applications" || h2 == "Command Line Utilities" ||
                  h2 == "Custom Linux Kernels" || h2 == "Desktop Environments" ||
                  h2 == "Display manager" || h2 == "Window Managers")
        next
    }
    /^### / { h3=stripmd(substr($0,5)); h4=""; h5=""; h6=""; next }
    /^#### /{ h4=stripmd(substr($0,6)); h5=""; h6=""; next }
    /^##### /{ h5=stripmd(substr($0,7)); h6=""; next }
    /^###### /{ h6=stripmd(substr($0,8)); next }
    /^- / {
        if (!software) next
        line=substr($0,3)
        if (line !~ /\[[^]]+\]\(https?:\/\//) next
        desc=""; splitpos=index(line," - ")
        if (splitpos>0) { desc=substr(line,splitpos+3); left=substr(line,1,splitpos-1) } else left=line
        # Select the last normal markdown link as the homepage. Preserve a
        # linked source badge separately so GitHub installation remains usable.
        rest=left; name=""; url=""; source=""
        # Source badges use nested Markdown: [![label][icon]](source-url).
        if (match(left,/\]\]\(https?:\/\/[^)]+\)/)) {
            token=substr(left,RSTART,RLENGTH)
            source=substr(token,4,length(token)-4)
        }
        while (match(rest,/\[[^]]+\]\(https?:\/\/[^)]+\)/)) {
            token=substr(rest,RSTART,RLENGTH)
            closepos=index(token,"](")
            tname=substr(token,2,closepos-2)
            turl=substr(token,closepos+2,length(token)-closepos-2)
            if (tname ~ /^!/ || tname ~ /Open.Source|Non.Free|Freeware|oss icon|money icon|freeware icon/) {
                if (source=="") source=turl
            } else { name=tname; url=turl }
            rest=substr(rest,RSTART+RLENGTH)
        }
        name=stripmd(name); desc=stripmd(desc)
        if (name=="" || url=="") next
        cat=clean(category_for(h2,h3,h4,h5,h6)); if (cat=="") next
        n++; id=sprintf("a%05d-%s",n,slug(name))
        gsub(/\t/," ",desc); gsub(/\t/," ",cat)
        print id "\t" cat "\t" name "\t" url "\t" source "\t" desc
    }' "$src" > "$tmp" || { rm -f "$tmp"; return 1; }
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$out"
}

awesome_linux_generate_catalog_installers() { # <catalog.tsv>
    local catalog="$1" dir id category name url source desc github pkg script slug
    dir=$(awesome_linux_installer_dir) || return 1
    while IFS=$'\t' read -r id category name url source desc; do
        [ -n "$name" ] || continue
        slug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._+-]+/-/g; s/^-+|-+$//g')
        script="$dir/${slug}-install.sh"
        pkg=$(awesome_linux_pkg_guess "$name")
        github=$(awesome_linux_github_url "$url" "$source" 2>/dev/null || true)
        cat > "$script" <<EOF
#!/bin/sh
set -eu
NAME=$(printf %s "$name" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")
HOMEPAGE=$(printf %s "$url" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")
GITHUB=$(printf %s "$github" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")
PACKAGE=$(printf %s "$pkg" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")
SOURCE_ROOT=\${SYSTUI_SOURCE_DIR:-/opt/systui-sources}
SLUG='$slug'
DEST="\$SOURCE_ROOT/\$SLUG"

usage() {
  cat <<USAGE
Install \$NAME
Usage: \$0 [auto|native|flatpak|snap|github|show-guide|homepage]

  auto        Try native, Flatpak, Snap, then GitHub
  native      Install from the active distribution repository
  flatpak     Search Flathub and install the closest application match
  snap        Install the guessed Snap package
  github      Clone/update GitHub, inspect project guides, detect build system, install
  show-guide  Clone/update GitHub and print installation-guide commands
  homepage    Print the official project page
USAGE
}

as_root() { if [ "\$(id -u)" -eq 0 ]; then "\$@"; elif command -v sudo >/dev/null 2>&1; then sudo "\$@"; else echo "Root privileges required" >&2; return 1; fi; }
install_native() {
  if command -v apt-get >/dev/null 2>&1; then apt-cache show "\$PACKAGE" >/dev/null 2>&1 && as_root apt-get install -y --no-install-recommends "\$PACKAGE"
  elif command -v apk >/dev/null 2>&1; then apk search -e "\$PACKAGE" | grep -q . && as_root apk add "\$PACKAGE"
  elif command -v pacman >/dev/null 2>&1; then pacman -Si "\$PACKAGE" >/dev/null 2>&1 && as_root pacman -S --needed --noconfirm "\$PACKAGE"
  elif command -v dnf >/dev/null 2>&1; then dnf -q list available "\$PACKAGE" >/dev/null 2>&1 && as_root dnf install -y --setopt=install_weak_deps=False "\$PACKAGE"
  elif command -v zypper >/dev/null 2>&1; then as_root zypper --non-interactive install --no-recommends "\$PACKAGE"
  else return 1; fi
}
install_flatpak() {
  command -v flatpak >/dev/null 2>&1 || return 1
  ref=\$(flatpak remote-ls --app --columns=application,name 2>/dev/null | awk -F '\\t' -v n="\$NAME" 'BEGIN{IGNORECASE=1} index(\$2,n)||index(n,\$2){print \$1; exit}')
  [ -n "\$ref" ] || return 1
  flatpak install -y flathub "\$ref"
}
install_snap() { command -v snap >/dev/null 2>&1 && snap info "\$PACKAGE" >/dev/null 2>&1 && as_root snap install "\$PACKAGE"; }
# The URL comes from a community-maintained README, so it is shown in full and
# confirmed before anything is fetched or executed. Set SYSTUI_ASSUME_YES=1 to
# skip the prompt in an unattended run -- that is an explicit opt-in, not the
# default.
confirm_repo() {
  [ "\${SYSTUI_ASSUME_YES:-0}" = 1 ] && return 0
  [ -t 0 ] || { echo "Refusing to build \$NAME from source on a non-interactive stdin." >&2
                echo "Re-run interactively, or set SYSTUI_ASSUME_YES=1 to accept." >&2; return 1; }
  echo
  echo "About to clone and BUILD AS ROOT:"
  echo "    project    : \$NAME"
  echo "    repository : \$GITHUB"
  echo "    destination: \$DEST"
  echo
  echo "This runs the project's own build system, and its install.sh if it ships"
  echo "one, with root privileges. Review the repository before continuing."
  printf 'Type the word yes to proceed: '
  read -r _reply || return 1
  [ "\$_reply" = yes ] || { echo "Aborted." >&2; return 1; }
}
clone_source() {
  [ -n "\$GITHUB" ] || { echo "No GitHub repository is listed for \$NAME" >&2; return 1; }
  command -v git >/dev/null 2>&1 || { echo "git is required" >&2; return 1; }
  case "\$GITHUB" in
    https://github.com/*) : ;;
    *) echo "Refusing a non-GitHub repository URL: \$GITHUB" >&2; return 1 ;;
  esac
  confirm_repo || return 1
  mkdir -p "\$(dirname "\$DEST")"
  if [ -d "\$DEST/.git" ]; then git -C "\$DEST" pull --ff-only; else git clone --recursive "\$GITHUB" "\$DEST"; fi
  git -C "\$DEST" submodule update --init --recursive
}
show_guide() {
  SYSTUI_GUIDE_ONLY=1 clone_source
  guide=""
  for f in INSTALL.md INSTALL README.md README.rst README.txt README; do [ -s "\$DEST/\$f" ] && { guide="\$DEST/\$f"; break; }; done
  [ -n "\$guide" ] || guide=\$(find "\$DEST/docs" -maxdepth 2 -type f \( -iname '*install*.md' -o -iname '*build*.md' \) 2>/dev/null | head -n 1 || true)
  [ -n "\$guide" ] || { echo "No installation guide detected"; return 1; }
  echo "Guide: \$guide"
  awk 'BEGIN{IGNORECASE=1; active=0; fence=0} /^#{1,6}[[:space:]].*(install|build|compile|setup)/{active=1;next} active&&/^#{1,6}[[:space:]]/{active=0} active&&substr(\$0,1,3)==sprintf("%c%c%c",96,96,96){fence=!fence;next} active&&fence{print}' "\$guide"
}
install_github() {
  clone_source
  cd "\$DEST"
  show_guide > .systui-install-guide.txt 2>/dev/null || true
  if [ -x ./install.sh ]; then as_root ./install.sh
  elif [ -x ./autogen.sh ]; then ./autogen.sh && ./configure && make -j"\$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" && as_root make install
  elif [ -x ./configure ]; then ./configure && make -j"\$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" && as_root make install
  elif [ -f CMakeLists.txt ]; then cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j"\$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" && as_root cmake --install build
  elif [ -f meson.build ]; then meson setup build --buildtype=release && meson compile -C build && as_root meson install -C build
  elif [ -f Cargo.toml ]; then cargo install --path . --locked --root "\${HOME}/.local"
  elif [ -f pyproject.toml ] || [ -f setup.py ]; then python3 -m pip install --user .
  elif [ -f package.json ]; then npm ci 2>/dev/null || npm install; npm run build --if-present; npm install -g .
  elif [ -f go.mod ]; then go install ./...
  elif [ -f Makefile ] || [ -f makefile ]; then make -j"\$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" && as_root make install
  else echo "No supported automatic build system detected. Run '\$0 show-guide' and follow the project guide." >&2; return 2; fi
}
method=\${1:-auto}
case "\$method" in
  # install_github is deliberately NOT in this chain. It clones a third-party
  # repository and runs its build (and, where present, its own install.sh) as
  # root. That is a reasonable thing to ask for explicitly; it is not a
  # reasonable thing to fall through to because a distro package was missing.
  auto) install_native || install_flatpak || install_snap || {
          echo "\$NAME is not available as a native, Flatpak or Snap package." >&2
          echo "To build it from source, review the project first, then run:" >&2
          echo "    \$0 show-guide     # print the project's own install steps" >&2
          echo "    \$0 github         # clone and build as root (asks first)" >&2
          exit 3
        } ;;
  native) install_native ;;
  flatpak) install_flatpak ;;
  snap) install_snap ;;
  github) install_github ;;
  show-guide) show_guide ;;
  homepage) printf '%s\\n' "\$HOMEPAGE" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
EOF
        chmod 700 "$script"
    done < "$catalog"
}

awesome_linux_catalog_valid() { # <catalog.tsv>
    local catalog="$1"
    [ -s "$catalog" ] || return 1
    # Contribution/help/news links are documentation, never installable
    # projects. Reject any legacy cache that still contains such categories.
    awk -F '\t' '
        NF < 4 { bad=1 }
        tolower($2) ~ /(unsure how to contribute|guidelines to contribute|contributors|linux news|reddit|license)/ { bad=1 }
        END { exit bad ? 1 : 0 }
    ' "$catalog"
}

awesome_linux_sync() {
    local dir readme catalog count
    dir=$(awesome_linux_cache_dir); readme="$dir/README.md"; catalog="$dir/catalog.tsv"
    mkdir -p "$dir" || { tui_msg "Awesome Linux" "Unable to create cache directory:\n$dir"; return 1; }
    if ! awesome_linux_download "$readme"; then
        awesome_linux_catalog_valid "$catalog" && {
            tui_msg "Offline catalogue" "Refresh failed; keeping the existing valid cached catalogue."
            return 0
        }
        tui_msg "Download failed" "Could not retrieve the Awesome Linux Software README.\nCheck networking and $LOGFILE."
        return 1
    fi
    if ! awesome_linux_parse "$readme" "$catalog"; then
        tui_msg "Parse failed" "The downloaded README did not produce a usable catalogue."
        return 1
    fi
    awesome_linux_catalog_valid "$catalog" || {
        rm -f "$catalog"
        tui_msg "Parse failed" "The generated catalogue contained invalid non-software sections."
        return 1
    }
    count=$(wc -l < "$catalog" | tr -d ' ')
    # Project installers are generated lazily after a project is selected.
    # Bulk-generating one script per catalogue row made first launch needlessly
    # slow and created filename collisions for duplicate project names.
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$dir/last-sync"
    printf '%s\n' "$AWESOME_LINUX_CATALOG_VERSION" > "$dir/catalog-version"
    tui_msg "Awesome Linux synchronized" "$count projects imported from the upstream repository."
}

awesome_linux_catalog() {
    local dir catalog readme cached_version
    dir=$(awesome_linux_cache_dir); catalog="$dir/catalog.tsv"; readme="$dir/README.md"
    cached_version=$(cat "$dir/catalog-version" 2>/dev/null || true)

    # Reparse an existing README whenever the taxonomy changes. This removes
    # stale categories immediately without requiring a network refresh.
    if [ "$cached_version" != "$AWESOME_LINUX_CATALOG_VERSION" ] || ! awesome_linux_catalog_valid "$catalog"; then
        if [ -s "$readme" ] && awesome_linux_parse "$readme" "$catalog" && awesome_linux_catalog_valid "$catalog"; then
            printf '%s\n' "$AWESOME_LINUX_CATALOG_VERSION" > "$dir/catalog-version"
        else
            awesome_linux_sync || return 1
        fi
    fi
    printf '%s\n' "$catalog"
}

awesome_linux_pkg_guess() {
    local name="$1" guess
    guess=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9+.-]+/-/g; s/^-+|-+$//g')
    case "$guess" in
        visual-studio-code) guess=code ;; sublime-text) guess=sublime-text ;;
        gnome-terminal) guess=gnome-terminal ;; libre-office|libreoffice-*) guess=libreoffice ;;
        vlc-media-player) guess=vlc ;; mozilla-firefox) guess=firefox ;;
        chromium-browser) guess=chromium ;; neovim) guess=neovim ;;
        android-studio) guess=android-studio ;; docker-ce) guess=docker ;;
    esac
    printf '%s\n' "$guess"
}

awesome_linux_native_available() { # <package>
    local pkg="$1"
    case "$PM" in
        apt) apt-cache show -- "$pkg" >/dev/null 2>&1 ;;
        apk) apk search -e -- "$pkg" 2>/dev/null | grep -q . ;;
        pacman) pacman -Si -- "$pkg" >/dev/null 2>&1 ;;
        dnf|yum) "$PM" -q list available "$pkg" >/dev/null 2>&1 || rpm -q "$pkg" >/dev/null 2>&1 ;;
        zypper) zypper --non-interactive search -x "$pkg" 2>/dev/null | grep -q "$pkg" ;;
        xbps) xbps-query -Rs "^${pkg}-" 2>/dev/null | grep -q . ;;
        emerge) emerge --search-exact "$pkg" 2>/dev/null | grep -q . ;;
        *) return 1 ;;
    esac
}

awesome_linux_open_url() { # <url>
    local url="$1"
    if command -v xdg-open >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        (xdg-open "$url" >/dev/null 2>&1 &) || true
    else
        tui_msg "Project URL" "$url"
    fi
}

awesome_linux_flatpak_ref() { # <name>; print best matching app id
    local name="$1" q
    command -v flatpak >/dev/null 2>&1 || return 1
    q=$(flatpak remote-ls --app --columns=application,name 2>/dev/null | \
        awk -F '\t' -v n="$name" 'BEGIN{IGNORECASE=1} index($2,n)||index(n,$2){print $1; exit}')
    [ -n "$q" ] || return 1; printf '%s\n' "$q"
}

awesome_linux_snap_name() { # <name>
    local name="$1" guess
    command -v snap >/dev/null 2>&1 || return 1
    guess=$(awesome_linux_pkg_guess "$name")
    snap info "$guess" >/dev/null 2>&1 || return 1
    printf '%s\n' "$guess"
}

awesome_linux_github_url() { # <homepage> <source>
    local homepage="$1" source="$2"
    case "$source" in https://github.com/*) printf '%s\n' "${source%.git}"; return 0;; esac
    case "$homepage" in https://github.com/*) printf '%s\n' "${homepage%.git}"; return 0;; esac
    return 1
}

awesome_linux_source_dir() { # <name>
    local name="$1" slug
    slug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._+-]+/-/g; s/^-+|-+$//g')
    printf '%s\n' "${SYSTUI_SOURCE_DIR:-/opt/systui-sources}/$slug"
}

awesome_linux_github_clone() { # <name> <github-url>
    local name="$1" github="$2" dst
    command -v git >/dev/null 2>&1 || { tui_msg "Git unavailable" "Install git before using GitHub installation."; return 1; }
    dst=$(awesome_linux_source_dir "$name")
    mkdir -p "$(dirname "$dst")" || return 1
    if [ -d "$dst/.git" ]; then
        run_cmd "Updating GitHub source for $name" git -C "$dst" pull --ff-only
    elif [ -e "$dst" ]; then
        tui_msg "Destination exists" "$dst exists but is not a Git repository. Move or remove it first."
        return 1
    else
        run_cmd "Cloning $name from GitHub" git clone --depth 1 "$github" "$dst"
    fi
}

awesome_linux_installer_dir() {
    local dir
    dir="$(awesome_linux_cache_dir)/installers"
    mkdir -p "$dir" || return 1
    printf '%s\n' "$dir"
}

awesome_linux_installer_path() { # <name>
    local name="$1" slug dir
    slug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._+-]+/-/g; s/^-+|-+$//g')
    dir=$(awesome_linux_installer_dir) || return 1
    printf '%s/%s-install.sh\n' "$dir" "$slug"
}

awesome_linux_detect_guide() { # <repository-directory>
    local dst="$1" f
    for f in INSTALL.md INSTALL README.md README.rst README.txt README; do
        [ -s "$dst/$f" ] && { printf '%s\n' "$dst/$f"; return 0; }
    done
    find "$dst/docs" -maxdepth 2 -type f \( -iname '*install*.md' -o -iname '*build*.md' \) 2>/dev/null | head -n 1
}

awesome_linux_guide_excerpt() { # <guide>
    local guide="$1"
    [ -s "$guide" ] || return 0
    awk '
      BEGIN{IGNORECASE=1; active=0; fence=0; n=0}
      /^#{1,6}[[:space:]].*(install|build|compile|setup)/ {active=1; n=0; next}
      active && /^#{1,6}[[:space:]]/ {active=0}
      active && /^```/ {fence=!fence; next}
      active && fence && /(^|[[:space:]])(git|cmake|meson|make|ninja|cargo|python3?|pip3?|npm|pnpm|yarn|go|\.\/configure|\.\/install\.sh)([[:space:]]|$)/ {
          gsub(/^[[:space:]]*\$[[:space:]]*/, ""); print; if (++n >= 30) exit
      }
    ' "$guide"
}

awesome_linux_generate_github_installer() { # <name> <github-url>
    local name="$1" github="$2" dst script guide method deps="" build="" excerpt
    awesome_linux_github_clone "$name" "$github" || return 1
    dst=$(awesome_linux_source_dir "$name")
    script=$(awesome_linux_installer_path "$name") || return 1
    guide=$(awesome_linux_detect_guide "$dst" 2>/dev/null || true)

    if [ -x "$dst/install.sh" ]; then
        method="Project install.sh"; build='./install.sh'
    elif [ -x "$dst/autogen.sh" ]; then
        method="Autotools (autogen.sh)"; deps="autoconf automake libtool pkg-config make gcc g++"; build='./autogen.sh && ./configure && make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" && make install'
    elif [ -x "$dst/configure" ]; then
        method="Autotools (configure)"; deps="make gcc g++ pkg-config"; build='./configure && make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" && make install'
    elif [ -f "$dst/CMakeLists.txt" ]; then
        method="CMake"; deps="cmake make gcc g++ pkg-config"; build='cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" && cmake --install build'
    elif [ -f "$dst/meson.build" ]; then
        method="Meson"; deps="meson ninja-build gcc g++ pkg-config"; build='meson setup build --buildtype=release && meson compile -C build && meson install -C build'
    elif [ -f "$dst/Cargo.toml" ]; then
        method="Cargo"; deps="cargo rustc pkg-config"; build='cargo install --path . --locked --root /usr/local'
    elif [ -f "$dst/pyproject.toml" ] || [ -f "$dst/setup.py" ]; then
        method="Python package"; deps="python3 python3-pip python3-venv"; build='python3 -m pip install --break-system-packages . 2>/dev/null || python3 -m pip install .'
    elif [ -f "$dst/package.json" ]; then
        method="Node.js package"; deps="nodejs npm"; build='npm ci 2>/dev/null || npm install; npm run build --if-present; npm install -g .'
    elif [ -f "$dst/go.mod" ]; then
        method="Go module"; deps="golang-go"; build='go build ./... && go install ./...'
    elif [ -f "$dst/Makefile" ] || [ -f "$dst/makefile" ]; then
        method="Make"; deps="make gcc g++ pkg-config"; build='make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" && make install'
    else
        method="Documentation-guided/manual"
        build='echo "No supported automatic build system was detected." >&2; echo "Review the installation guide shown in this script." >&2; exit 2'
    fi
    excerpt=$(awesome_linux_guide_excerpt "$guide" 2>/dev/null || true)

    cat > "$script" <<EOF
#!/bin/sh
set -eu
# Generated by systui Awesome Linux for: $name
# Repository: $github
# Detected method: $method
# Documentation: ${guide:-not detected}
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
#
# Commands extracted from the project installation/build guide for review:
$(printf '%s\n' "$excerpt" | sed 's/^/#   /')

REPO=$(printf '%s' "$github" | sed 's/["\\]/\\&/g')
DEST=$(printf '%s' "$dst" | sed 's/["\\]/\\&/g')

install_dependencies() {
    [ -n "$deps" ] || return 0
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $deps
    elif command -v apk >/dev/null 2>&1; then
        apk_deps=\$(printf '%s\n' "$deps" | sed 's/ninja-build/ninja/g; s/golang-go/go/g; s/g++/build-base/g; s/gcc/build-base/g')
        apk add --no-cache \$apk_deps
    elif command -v pacman >/dev/null 2>&1; then
        pacman_deps=\$(printf '%s\n' "$deps" | sed 's/ninja-build/ninja/g; s/golang-go/go/g; s/g++//g')
        pacman -S --needed --noconfirm \$pacman_deps
    elif command -v dnf >/dev/null 2>&1; then
        dnf_deps=\$(printf '%s\n' "$deps" | sed 's/ninja-build/ninja-build/g; s/golang-go/golang/g')
        dnf install -y --setopt=install_weak_deps=False \$dnf_deps
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install --no-recommends $deps
    else
        echo "Install these build dependencies manually: $deps" >&2
    fi
}

command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
mkdir -p "\$(dirname "\$DEST")"
if [ -d "\$DEST/.git" ]; then
    git -C "\$DEST" pull --ff-only
elif [ -e "\$DEST" ]; then
    echo "Destination exists and is not a Git repository: \$DEST" >&2
    exit 1
else
    git clone --recursive "\$REPO" "\$DEST"
fi
git -C "\$DEST" submodule update --init --recursive
install_dependencies
cd "\$DEST"
$build
EOF
    chmod 700 "$script"
    tui_msg "Installer generated" "Project-specific installer created from repository documentation and detected build files:\n\n$script\n\nDetected method: $method"
    printf '%s\n' "$script"
}

awesome_linux_view_installer() { # <name>
    local script
    script=$(awesome_linux_installer_path "$1") || return 1
    [ -s "$script" ] || { tui_msg "Installer unavailable" "Generate the GitHub installer first."; return 1; }
    if command -v less >/dev/null 2>&1; then less "$script"
    elif command -v more >/dev/null 2>&1; then more "$script"
    else tui_textbox "Generated installer" "$script"; fi
}

awesome_linux_run_installer() { # <name> <github-url>
    local name="$1" github="$2" script
    script=$(awesome_linux_installer_path "$name") || return 1
    if [ ! -s "$script" ]; then
        awesome_linux_generate_github_installer "$name" "$github" >/dev/null || return 1
        script=$(awesome_linux_installer_path "$name") || return 1
    fi
    # Name the repository that is about to be built as root. The catalogue is
    # generated from a community-maintained README, so the user needs to see
    # the actual URL -- not just the path of the wrapper script -- before
    # agreeing to run a third-party build with root privileges.
    local typed
    tui_yesno "Build $name from source" \
"This clones a third-party repository and runs its build system as root,\nincluding the project's own install.sh if it ships one.\n\n  Repository: ${github:-<none listed>}\n  Installer : $script\n\nReview the repository and the generated script first.\nContinue?" || return 0
    typed=$(tui_input "Confirm build" "Type the word yes to build $name from ${github:-source}:" "") || return 0
    [ "$typed" = yes ] || { tui_msg "Aborted" "Confirmation did not match; nothing was run."; return 0; }
    run_cmd "Installing $name from its generated GitHub guide" env SYSTUI_ASSUME_YES=1 /bin/sh "$script" github
}

awesome_linux_github_build() { # compatibility wrapper
    awesome_linux_run_installer "$@"
}

awesome_linux_project_menu() { # TSV fields
    local id="$1" category="$2" name="$3" url="$4" source="$5" desc="$6"
    local c pkg flat snap status github
    pkg=$(awesome_linux_pkg_guess "$name")
    github=$(awesome_linux_github_url "$url" "$source" 2>/dev/null || true)
    while true; do
        status="not detected"
        case "$PM" in apt) dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' && status="native installed";;
            apk) apk info -e "$pkg" >/dev/null 2>&1 && status="native installed";;
            pacman) pacman -Q "$pkg" >/dev/null 2>&1 && status="native installed";;
            dnf|yum|zypper) rpm -q "$pkg" >/dev/null 2>&1 && status="native installed";;
            xbps) xbps-query "$pkg" >/dev/null 2>&1 && status="native installed";;
        esac
        c=$(tui_menu "$name  [$status]" "$category\n\n${desc:-No description available}" \
            install  "Install from available sources" \
            update   "Update managed installation" \
            remove   "Remove managed installation" \
            homepage "Open project page" \
            back     "Back") || return 0
        case "$c" in
            install)
                local methods=(native "Distribution repository: $pkg" flatpak "Flatpak / Flathub" snap "Snap Store") m
                [ -n "$github" ] && methods+=(github-generate "GitHub: generate project installer" github-view "GitHub: review generated installer" github-build "GitHub: run generated installer" github-clone "GitHub: clone or update source")
                methods+=(web "Official installation page" back "Back")
                m=$(tui_menu "Install $name" "Choose an installation source. Each method is verified before changes are made:" "${methods[@]}") || continue
                case "$m" in
                    native) awesome_linux_native_available "$pkg" && pm_install "$pkg" || tui_msg "Package unavailable" "'$pkg' was not found in the active $PM repositories." ;;
                    flatpak) flat=$(awesome_linux_flatpak_ref "$name") && run_cmd "Installing $flat" flatpak install -y flathub "$flat" || tui_msg "Flatpak unavailable" "No matching configured Flatpak application was found." ;;
                    snap) snap=$(awesome_linux_snap_name "$name") && run_cmd "Installing snap $snap" snap install "$snap" || tui_msg "Snap unavailable" "No exact Snap package match was found." ;;
                    github-generate) awesome_linux_generate_github_installer "$name" "$github" >/dev/null ;;
                    github-view) awesome_linux_view_installer "$name" ;;
                    github-clone) awesome_linux_github_clone "$name" "$github" ;;
                    github-build) awesome_linux_run_installer "$name" "$github" ;;
                    web) awesome_linux_open_url "$url" ;;
                esac ;;
            update)
                if case "$PM" in apt) dpkg-query -W "$pkg" >/dev/null 2>&1;; apk) apk info -e "$pkg" >/dev/null 2>&1;; pacman) pacman -Q "$pkg" >/dev/null 2>&1;; dnf|yum|zypper) rpm -q "$pkg" >/dev/null 2>&1;; xbps) xbps-query "$pkg" >/dev/null 2>&1;; *) false;; esac; then pm_install "$pkg"
                elif flat=$(awesome_linux_flatpak_ref "$name") && flatpak info "$flat" >/dev/null 2>&1; then run_cmd "Updating $flat" flatpak update -y "$flat"
                elif snap=$(awesome_linux_snap_name "$name") && snap list "$snap" >/dev/null 2>&1; then run_cmd "Refreshing $snap" snap refresh "$snap"
                elif [ -n "$github" ] && [ -d "$(awesome_linux_source_dir "$name")/.git" ]; then awesome_linux_github_clone "$name" "$github"
                else tui_msg "Not managed" "No installed package method was detected."; fi ;;
            remove)
                if case "$PM" in apt) dpkg-query -W "$pkg" >/dev/null 2>&1;; apk) apk info -e "$pkg" >/dev/null 2>&1;; pacman) pacman -Q "$pkg" >/dev/null 2>&1;; dnf|yum|zypper) rpm -q "$pkg" >/dev/null 2>&1;; xbps) xbps-query "$pkg" >/dev/null 2>&1;; *) false;; esac; then pm_remove "$pkg"
                elif flat=$(awesome_linux_flatpak_ref "$name") && flatpak info "$flat" >/dev/null 2>&1; then run_cmd "Removing $flat" flatpak uninstall -y "$flat"
                elif snap=$(awesome_linux_snap_name "$name") && snap list "$snap" >/dev/null 2>&1; then run_cmd "Removing $snap" snap remove "$snap"
                elif [ -d "$(awesome_linux_source_dir "$name")/.git" ]; then
                    tui_yesno "Remove source" "Delete cloned source directory?\n$(awesome_linux_source_dir "$name")" && { rm --one-file-system -rf -- /nonexistent-systui-probe 2>/dev/null \
                        && rm -rf --one-file-system -- "$(awesome_linux_source_dir "$name")" \
                        || rm -rf -- "$(awesome_linux_source_dir "$name")"; }
                else tui_msg "Not detected" "No managed installation of $name was detected."; fi ;;
            homepage) awesome_linux_open_url "$url" ;;
            back) return 0 ;;
        esac
    done
}

awesome_linux_browse_file() { # filtered TSV
    local file="$1" title="$2" page=0 per=35 total start end c line
    total=$(wc -l < "$file" | tr -d ' '); [ "$total" -gt 0 ] || { tui_msg "No results" "No matching projects were found."; return 0; }
    while true; do
        start=$((page*per+1)); end=$((start+per-1)); [ "$end" -gt "$total" ] && end=$total
        local args=() id category name url source desc
        while IFS=$'\t' read -r id category name url source desc; do
            [ -n "$id" ] && args+=("$id" "$name — ${desc:-No description available}")
        done < <(sed -n "${start},${end}p" "$file")
        [ "$end" -lt "$total" ] && args+=(__next "Next page")
        [ "$page" -gt 0 ] && args+=(__prev "Previous page")
        args+=(__back "Back")
        c=$(tui_menu_no_tags "$title" "Projects $start-$end of $total:" "${args[@]}") || return 0
        case "$c" in __next) page=$((page+1));; __prev) page=$((page-1));; __back) return 0;;
            *) line=$(awk -F '\t' -v id="$c" '$1==id{print; exit}' "$file"); [ -n "$line" ] || continue; IFS=$'\t' read -r id category name url source desc <<< "$line"; awesome_linux_project_menu "$id" "$category" "$name" "$url" "$source" "$desc";;
        esac
    done
}

awesome_linux_category_level() { # <catalog> <prefix> <title>
    local catalog="$1" prefix="${2:-}" title="${3:-Categories}"
    local map labels c tag label path filtered exact children
    local args=() n=0
    map=$(mktemp "${SYSTUI_TMP}/awesome-category-map.XXXXXX") || {
        tui_msg "Awesome Linux" "Unable to create the category menu."
        return 1
    }
    labels="${map}.labels"

    # Build only the immediate children beneath the requested category path.
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if [ -n "$prefix" ]; then
            case "$path" in "$prefix"|"$prefix / "*) ;; *) continue ;; esac
            path=${path#"$prefix"}
            path=${path# / }
        fi
        [ -n "$path" ] || continue
        label=${path%% / *}
        printf '%s\n' "$label"
    done < <(awk -F '\t' '{print $2}' "$catalog") | sort -fu > "$labels"
    while IFS= read -r label; do
        [ -n "$label" ] || continue
        n=$((n+1)); tag=$(printf 'c%04d' "$n")
        if [ -n "$prefix" ]; then path="$prefix / $label"; else path="$label"; fi
        exact=$(awk -F '\t' -v p="$path" '$2==p{n++} END{print n+0}' "$catalog")
        children=$(awk -F '\t' -v p="$path / " 'index($2,p)==1{n++} END{print n+0}' "$catalog")
        if [ "$children" -gt 0 ] && [ "$exact" -gt 0 ]; then
            args+=("$tag" "$label ($exact projects, subcategories)")
        elif [ "$children" -gt 0 ]; then
            args+=("$tag" "$label (subcategories)")
        else
            args+=("$tag" "$label ($exact projects)")
        fi
        printf '%s\t%s\t%s\t%s\n' "$tag" "$path" "$exact" "$children" >> "$map"
    done < "$labels"
    rm -f "$labels"

    # If the category itself contains entries, expose them separately.
    if [ -n "$prefix" ]; then
        exact=$(awk -F '\t' -v p="$prefix" '$2==p{n++} END{print n+0}' "$catalog")
        [ "$exact" -gt 0 ] && args=(__projects "Projects directly in this category ($exact)" "${args[@]}")
    fi
    args+=(__back "Back")

    while true; do
        c=$(tui_menu_no_tags "Awesome Linux — $title" "Select a category:" "${args[@]}") || {
            rm -f "$map" "$labels"
            return 0
        }
        case "$c" in
            __back)
                rm -f "$map" "$labels"
                return 0
                ;;
            __projects)
                filtered="${SYSTUI_TMP}/awesome-category-direct.tsv"
                awk -F '\t' -v p="$prefix" '$2==p' "$catalog" | sort -t $'\t' -k3,3f > "$filtered"
                awesome_linux_browse_file "$filtered" "$prefix" ;;
            *)
                path=$(awk -F '\t' -v t="$c" '$1==t{print $2; exit}' "$map")
                exact=$(awk -F '\t' -v t="$c" '$1==t{print $3; exit}' "$map")
                children=$(awk -F '\t' -v t="$c" '$1==t{print $4; exit}' "$map")
                [ -n "$path" ] || continue
                if [ "${children:-0}" -gt 0 ]; then
                    awesome_linux_category_level "$catalog" "$path" "${path##* / }"
                else
                    filtered="${SYSTUI_TMP}/awesome-category.tsv"
                    awk -F '\t' -v p="$path" '$2==p' "$catalog" | sort -t $'\t' -k3,3f > "$filtered"
                    awesome_linux_browse_file "$filtered" "$path"
                fi ;;
        esac
    done
}

awesome_linux_categories() {
    awesome_linux_category_level "$1" "" "Categories"
}

menu_awesome_linux() {
    local catalog c term filtered dir count synced
    while true; do
        catalog=$(awesome_linux_catalog) || return 0
        dir=$(awesome_linux_cache_dir)
        count=$(wc -l < "$catalog" | tr -d ' ')
        synced=$(cat "$dir/last-sync" 2>/dev/null || echo "unknown")
        c=$(tui_menu "Awesome Linux" "$count projects — last refresh: $synced" \
            categories "Browse by category" \
            search     "Search software" \
            refresh    "Refresh catalogue" \
            back       "Back") || return 0
        case "$c" in
            categories) awesome_linux_categories "$catalog" ;;
            search)
                term=$(tui_input "Search Awesome Linux" "Software name, category, or description:" "") || continue
                [ -n "$term" ] || continue
                filtered="${SYSTUI_TMP}/awesome-filter.tsv"
                awk -F '\t' -v q="$term" 'BEGIN{IGNORECASE=1} index($0,q){print}' "$catalog" | sort -t $'\t' -k3,3f > "$filtered"
                awesome_linux_browse_file "$filtered" "Search: $term" ;;
            refresh) awesome_linux_sync ;;
            back) return 0 ;;
        esac
    done
}

# ---- System configuration hub ----------------------------------------------

###############################################################################
# SYSTEM CONFIGURATION MENU
###############################################################################

# The section menus below are organised by subsystem, which is the right shape
# for browsing but a poor shape for the handful of things people actually come
# here to do — those sit two or three levels down. This menu is a flat front
# door to them; every entry calls the same function the section menu does, so
# there is one implementation of each action, not two.
menu_sysconfig_common() {
    while true; do
        local c
        c=$(tui_menu_no_tags "Common tasks" \
            "Frequently used settings, without walking the section menus:" \
            install   "Install or remove packages" \
            update    "Update and upgrade all packages" \
            hostname  "Set the system hostname ($(hostname))" \
            timezone  "Set the timezone ($(cat /etc/timezone 2>/dev/null || readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || echo unknown))" \
            user      "Add a user account" \
            shell     "Set the default login shell" \
            editor    "Install and configure editors" \
            ssh       "Configure the SSH server" \
            service   "Start, stop or enable a service" \
            scan      "Run a full system scan" \
            back      "Back") || return 0
        case "$c" in
            install)  menu_package_operations ;;
            update)   pm_update || tui_msg "Not supported" "No update command is defined for $PM." ;;
            hostname) sysconfig_set_hostname ;;
            timezone) sysconfig_set_timezone ;;
            user)     menu_users ;;
            shell)    menu_set_default_shell ;;
            editor)   menu_editors ;;
            ssh)      menu_ssh_server ;;
            service)  menu_services ;;
            scan)     menu_scan_system ;;
            back|"")  return 0 ;;
        esac
    done
}

menu_sysconfig() {
    while true; do
        local c
        c=$(tui_menu_no_tags "System Configuration" \
            "Detected: package manager = $PM, init = $INIT" \
            common      "Common tasks — packages, hostname, timezone, users, SSH" \
            packages    "Packages (catalogue, repositories, apt-fast...)" \
            shells      "Shells & plugins (frameworks, starship, history...)" \
            editors     "Editors (install + per-editor configuration)" \
            filemanagers "File managers (Midnight Commander, lf, Yazi, Ranger...)" \
            network     "Network (SSH, fail2ban, DNS, proxy, time...)" \
            services    "Services ($INIT, logs, unit creator, init swap)" \
            users       "Users (passwords, sudoers, aging, SSH keys...)" \
            storage     "Storage (mounts, labels, format, SMART...)" \
            performance "Advanced performance tuning" \
            scanner     "Scanner (system reports, package & file queries)" \
            back        "Back to main menu") || return 0
        case "$c" in
            common)      menu_sysconfig_common ;;
            packages)    menu_packages ;;
            shells)      menu_shells ;;
            editors)     menu_editors ;;
            filemanagers) menu_file_managers ;;
            network)     menu_network ;;
            services)    menu_services ;;
            users)       menu_users ;;
            storage)     menu_storage ;;
            performance) menu_performance ;;
            scanner)     menu_scanner ;;
            back)        return 0 ;;
        esac
    done
}

export -f menu_sysconfig
