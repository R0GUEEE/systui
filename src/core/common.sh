#!/bin/bash
###############################################################################
# systui — Common Utilities & Package Management
###############################################################################

###############################################################################
# PACKAGE MAPPING (Debian → Alpine / Arch / Fedora)
###############################################################################

declare -gA PKG_MAP=(
    # base / shells / editors
    [bash]="bash bash bash bash"
    [zsh]="zsh zsh zsh zsh"
    [fish]="fish fish fish fish-shell"
    [ksh]="ksh ksh ksh ksh"
    [mksh]="mksh mksh mksh mksh"
    [tcsh]="tcsh tcsh tcsh tcsh"
    [nano]="nano nano nano nano"
    [vim]="vim vim vim-enhanced vim"
    [neovim]="neovim neovim neovim neovim"
    [emacs]="emacs emacs emacs emacs"
    [ed]="ed ed ed ed"
    [curl]="curl curl curl curl"
    [wget]="wget wget wget wget"
    [git]="git git git git"
    [git-lfs]="SKIP git-lfs git-lfs SKIP"
    [rsync]="rsync rsync rsync rsync"
    [tmux]="tmux tmux tmux tmux"
    [screen]="screen screen screen screen"
    [tree]="tree tree tree tree"
    [file]="file file file file"
    [less]="less less less less"
    [more]="more more more more"
    [jq]="jq jq jq jq"
    [yq]="yq yq yq yq"
    [fzf]="fzf fzf fzf fzf"
    [ripgrep]="ripgrep ripgrep ripgrep ripgrep"
    [fd-find]="fd fd fd-find fd"
    [ag]="the-silver-searcher the-silver-searcher the_silver_searcher the_silver_searcher"
    [ack]="ack ack ack ack"
    [bat]="bat bat bat-extras bat"
    [exa]="exa exa exa exa"
    [lsd]="lsd lsd lsd lsd"
    [delta]="delta delta git-delta delta"
    [openssl]="openssl openssl openssl openssl"
    [gnupg]="gnupg gnupg gnupg2 gnupg"
    [ca-certificates]="ca-certificates ca-certificates ca-certificates ca-certificates"
    [bash-completion]="bash-completion bash-completion bash-completion bash-completion"
    [man-pages]="man-pages man-pages man-pages man-pages"
    [man-db]="man man man man"
    
    # development
    [build-essential]="build-base base-devel gcc base-devel"
    [gcc]="gcc gcc gcc gcc"
    [g++]="g++ g++ gcc-c++ gcc-g++"
    [make]="make make make make"
    [cmake]="cmake cmake cmake cmake"
    [autoconf]="autoconf autoconf autoconf autoconf"
    [automake]="automake automake automake automake"
    [libtool]="libtool libtool libtool libtool"
    [pkg-config]="pkgconf pkgconf pkgconf-pkg-config pkgconf"
    [gdb]="gdb gdb gdb gdb"
    [lldb]="lldb lldb lldb lldb"
    [valgrind]="valgrind valgrind valgrind valgrind"
    [python3]="python3 python python3 python3"
    [python3-pip]="py3-pip python-pip python3-pip python3-pip"
    [python3-venv]="SKIP python python3 python3"
    [python3-dev]="python3-dev python-dev python3-devel python3-dev"
    [nodejs]="nodejs nodejs nodejs nodejs"
    [npm]="npm npm npm npm"
    [yarn]="yarn yarn yarn yarn"
    [rust]="SKIP rust rustup rustup"
    [cargo]="SKIP rust rustup rustup"
    [go]="go go golang golang"
    [perl]="perl perl perl perl"
    [perl-dev]="perl-dev perl perl-CPAN perl-dev"
    [lua]="lua lua lua lua"
    [ruby]="ruby ruby ruby ruby"
    [ruby-dev]="ruby-dev ruby ruby-devel ruby-dev"
    [php]="php php php php"
    [php-cli]="php php php php"
    [java-default-jdk]="openjdk openjdk openjdk-latest-jdk java-latest-openjdk"
    [openjdk-11-jdk]="openjdk11 openjdk11 java-11-openjdk java-11-openjdk"
    [clang]="clang clang clang llvm"
    [clang-format]="clang-extra-tools clang-tools clang-tools-extra clang-tools-extra"
    [uncrustify]="uncrustify uncrustify uncrustify uncrustify"
    [git-flow]="gitflow git-flow git-flow git-flow"
    [mercurial]="mercurial mercurial mercurial mercurial"
    [svn]="subversion subversion subversion subversion"
    [meson]="meson meson meson meson"
    [ninja-build]="ninja ninja ninja ninja"
    [scons]="scons scons scons scons"
    [bazel]="bazel bazel bazel bazel"
    
    # version control & code tools
    [gitk]="gitk gitk gitk gitk"
    [git-gui]="git-gui git-gui git-gui git-gui"
    [tig]="tig tig tig tig"
    [lazygit]="SKIP lazygit lazygit lazygit"
    [hub]="hub hub hub hub"
    [gh]="SKIP gh github-cli github-cli"
    
    # monitoring / diagnostics / performance
    [htop]="htop htop htop htop"
    [atop]="atop atop atop atop"
    [iotop]="iotop iotop iotop iotop"
    [iotop-c]="SKIP iotop iotop iotop"
    [ncdu]="ncdu ncdu ncdu ncdu"
    [du-dust]="SKIP dust dust dust"
    [duf]="duf duf duf duf"
    [lsof]="lsof lsof lsof lsof"
    [strace]="strace strace strace strace"
    [ltrace]="ltrace ltrace ltrace ltrace"
    [fastfetch]="fastfetch fastfetch fastfetch fastfetch"
    [neofetch]="neofetch neofetch neofetch neofetch"
    [sysstat]="sysstat sysstat sysstat sysstat"
    [procps]="procps procps procps-ng procps-ng"
    [cgroup-tools]="cgroup-lite cgroup-tools libcgroup libcgroup"
    [stress]="stress stress stress stress"
    [stress-ng]="SKIP stress-ng stress-ng stress-ng"
    [sysbench]="sysbench sysbench sysbench sysbench"
    
    # network
    [openssh-server]="openssh openssh openssh-server openssh"
    [openssh-client]="openssh-client openssh-client openssh openssh"
    [iproute2]="iproute2 iproute2 iproute iproute2"
    [iproute]="iproute2 iproute2 iproute iproute2"
    [net-tools]="net-tools net-tools net-tools net-tools"
    [nmap]="nmap nmap nmap nmap"
    [tcpdump]="tcpdump tcpdump tcpdump tcpdump"
    [mtr]="mtr mtr mtr mtr"
    [dnsutils]="bind-tools bind bind-utils bind-utils"
    [netcat-openbsd]="netcat-openbsd openbsd-netcat nmap-ncat openbsd-netcat"
    [socat]="socat socat socat socat"
    [ncat]="nmap nmap nmap-ncat nmap-ncat"
    [telnet]="telnet telnet telnet telnet"
    [iperf3]="iperf3 iperf3 iperf3 iperf3"
    [iputils-ping]="iputils iputils iputils iputils"
    [iputils-tracepath]="iputils iputils iputils iputils"
    [whois]="whois whois whois whois"
    [dig]="bind-tools bind bind-utils bind-utils"
    [host]="bind-tools bind bind-utils bind-utils"
    [nslookup]="bind-tools bind bind-utils bind-utils"
    [arping]="arping arping arping arping"
    [arp-scan]="SKIP SKIP SKIP SKIP"
    [ethtool]="ethtool ethtool ethtool ethtool"
    [bridge-utils]="bridge-utils bridge-utils bridge-utils bridge-utils"
    [wireguard]="wireguard-tools wireguard-tools wireguard-tools wireguard-tools"
    [openvpn]="openvpn openvpn openvpn openvpn"
    [openconnect]="openconnect openconnect openconnect openconnect"
    
    # compression / archiving
    [zip]="zip zip zip zip"
    [unzip]="unzip unzip unzip unzip"
    [gzip]="gzip gzip gzip gzip"
    [bzip2]="bzip2 bzip2 bzip2 bzip2"
    [xz-utils]="xz xz xz xz"
    [zstd]="zstd zstd zstd zstd"
    [p7zip-full]="p7zip p7zip p7zip p7zip"
    [rar]="rar rar rar rar"
    [unrar]="unrar unrar unrar unrar"
    [lha]="lha lha lha lha"
    [arj]="SKIP SKIP SKIP SKIP"
    [tar]="tar tar tar tar"
    [cpio]="cpio cpio cpio cpio"
    [pax]="paxutils paxutils paxutils paxutils"
    [pigz]="pigz pigz pigz pigz"
    [pxz]="SKIP SKIP SKIP SKIP"
    [pbzip2]="pbzip2 pbzip2 pbzip2 pbzip2"
    
    # data processing / text manipulation
    [sed]="sed sed sed sed"
    [awk]="gawk gawk gawk gawk"
    [gawk]="gawk gawk gawk gawk"
    [mawk]="mawk mawk mawk mawk"
    [grep]="grep grep grep grep"
    [egrep]="grep grep grep grep"
    [fgrep]="grep grep grep grep"
    [sort]="coreutils coreutils coreutils coreutils"
    [uniq]="coreutils coreutils coreutils coreutils"
    [comm]="coreutils coreutils coreutils coreutils"
    [join]="coreutils coreutils coreutils coreutils"
    [cut]="coreutils coreutils coreutils coreutils"
    [paste]="coreutils coreutils coreutils coreutils"
    [tr]="coreutils coreutils coreutils coreutils"
    [wc]="coreutils coreutils coreutils coreutils"
    [head]="coreutils coreutils coreutils coreutils"
    [tail]="coreutils coreutils coreutils coreutils"
    [od]="coreutils coreutils coreutils coreutils"
    [hexdump]="bsdmainutils bsdmainutils util-linux util-linux"
    [xxd]="vim vim vim-minimal vim"
    [strings]="binutils binutils binutils binutils"
    [diff]="diffutils diffutils diffutils diffutils"
    [diff3]="diffutils diffutils diffutils diffutils"
    [patch]="patch patch patch patch"
    [meld]="meld meld meld meld"
    [vimdiff]="vim vim vim-minimal vim"
    [diffstat]="diffstat diffstat diffstat diffstat"
    [patchutils]="patchutils patchutils patchutils patchutils"
    [dos2unix]="dos2unix dos2unix dos2unix dos2unix"
    [unix2dos]="dos2unix dos2unix dos2unix dos2unix"
    
    # database
    [sqlite3]="sqlite sqlite sqlite sqlite"
    [postgresql-client]="postgresql-client postgresql postgresql-libs postgresql"
    [mysql-client]="mysql-client mysql-community mysql-client mariadb-client"
    [mongodb-org-shell]="SKIP SKIP SKIP SKIP"
    [redis-tools]="redis redis redis redis"
    
    # security / cryptography
    [ssh-import-id]="SKIP SKIP SKIP SKIP"
    [fail2ban]="fail2ban fail2ban fail2ban fail2ban"
    [aide]="aide aide aide aide"
    [rkhunter]="rkhunter rkhunter rkhunter rkhunter"
    [lynis]="lynis lynis lynis lynis"
    [john]="john john-the-ripper john john-the-ripper"
    [hashcat]="hashcat hashcat hashcat hashcat"
    [hydra]="hydra hydra hydra hydra"
    [nikto]="nikto nikto nikto nikto"
    [sqlmap]="sqlmap sqlmap sqlmap sqlmap"
    [aircrack-ng]="aircrack-ng aircrack-ng aircrack-ng aircrack-ng"
    [wireshark]="wireshark wireshark wireshark wireshark"
    [tshark]="wireshark wireshark wireshark wireshark"
    [mitmproxy]="mitmproxy mitmproxy mitmproxy mitmproxy"
    [burpsuite]="SKIP SKIP SKIP SKIP"
    [metasploit]="metasploit-framework SKIP metasploit-framework metasploit-framework"
    
    # containers / virtualization
    [docker.io]="docker docker docker docker"
    [docker-compose]="docker-compose docker-compose docker-compose docker-compose"
    [podman]="podman podman podman podman"
    [podman-compose]="podman-compose podman-compose podman-compose podman-compose"
    [containerd]="containerd containerd containerd containerd"
    [cri-o]="cri-o cri-o cri-o cri-o"
    [skopeo]="skopeo skopeo skopeo skopeo"
    [buildah]="buildah buildah buildah buildah"
    [runc]="runc runc runc runc"
    [kubernetes]="SKIP SKIP SKIP SKIP"
    [kubectl]="SKIP kubectl kubectl kubectl"
    [helm]="SKIP SKIP SKIP SKIP"
    [kops]="SKIP SKIP SKIP SKIP"
    [minikube]="SKIP SKIP SKIP SKIP"
    [qemu]="qemu qemu qemu qemu"
    [libvirt]="libvirt libvirt libvirt libvirt"
    [virt-manager]="virt-manager virt-manager virt-manager virt-manager"
    [vagrant]="vagrant SKIP vagrant vagrant"
    [virtualbox]="virtualbox SKIP virtualbox virtualbox"
    
    # backup / sync / storage
    [rclone]="rclone rclone rclone rclone"
    [duplicacy]="SKIP SKIP SKIP SKIP"
    [restic]="SKIP restic restic restic"
    [backuppc]="backuppc SKIP backuppc backuppc"
    [bacula]="bacula bacula bacula bacula"
    [amanda]="amanda SKIP amanda SKIP"
    [lvm2]="lvm2 lvm2 lvm2 lvm2"
    [mdadm]="mdadm mdadm mdadm mdadm"
    [cryptsetup]="cryptsetup cryptsetup cryptsetup cryptsetup"
    [dmsetup]="device-mapper device-mapper device-mapper device-mapper"
    [btrfs-progs]="btrfs-progs btrfs-progs btrfs-progs btrfs-progs"
    [zfsutils-linux]="zfs SKIP zfs zfs"
    
    # cloud / infrastructure
    [awscli]="SKIP SKIP awscli awscli"
    [aws-cli]="SKIP SKIP awscli awscli"
    [azure-cli]="SKIP SKIP SKIP SKIP"
    [gcloud]="SKIP SKIP SKIP SKIP"
    [terraform]="SKIP terraform terraform terraform"
    [ansible]="ansible ansible ansible ansible"
    [salt-common]="salt salt salt salt"
    [puppet]="puppet puppet puppet puppet"
    [chef]="chef chef chef chef"
    
    # logging / monitoring / observability
    [logrotate]="logrotate logrotate logrotate logrotate"
    [rsyslog]="rsyslog rsyslog rsyslog rsyslog"
    [syslog-ng]="syslog-ng syslog-ng syslog-ng syslog-ng"
    [fluentd]="SKIP SKIP SKIP SKIP"
    [vector]="SKIP SKIP SKIP SKIP"
    [prometheus]="SKIP SKIP SKIP SKIP"
    [grafana]="SKIP SKIP SKIP SKIP"
    [telegraf]="SKIP SKIP SKIP SKIP"
    [collectd]="collectd collectd collectd collectd"
    [monit]="monit monit monit monit"
    [nagios]="nagios nagios nagios nagios"
    [zabbix-agent]="zabbix-agent SKIP zabbix-agent zabbix-agent"
    
    # system administration
    [sudo]="sudo sudo sudo sudo"
    [sudo-ldap]="sudo sudo sudo sudo"
    [cron]="SKIP cronie cronie cronie"
    [cronie]="cronie cronie cronie cronie"
    [at]="at at at at"
    [locales]="SKIP glibc-locales glibc-langpack-en glibc-locales"
    [adduser]="SKIP SKIP SKIP SKIP"
    [deluser]="SKIP SKIP SKIP SKIP"
    [sysvinit-core]="SKIP SKIP SKIP SKIP"
    [sysvinit-utils]="sysvinit-utils sysvinit-utils sysvinit-utils sysvinit-utils"
    [openrc]="openrc openrc SKIP SKIP"
    [runit]="runit runit runit runit"
    [systemd]="systemd systemd systemd systemd"
    [systemd-container]="SKIP systemd systemd systemd"
    [systemd-journal-remote]="systemd systemd systemd systemd"
    [udev]="udev udev udev udev"
    [eudev]="eudev eudev eudev SKIP"
    [initramfs-tools]="mkinitfs mkinitcpio mkinitrd dracut"
    [boot-repair]="SKIP SKIP SKIP SKIP"
    [grub-pc]="grub grub grub grub"
    [grub-efi]="grub grub grub grub"
    [grub2]="grub grub grub grub"
    [os-prober]="os-prober os-prober os-prober os-prober"
    [memtest86+]="memtest86plus memtest86plus memtest86plus memtest86plus"
    [most]="most SKIP most most"
    [acpi]="acpi acpi acpi acpi"
    [acpid]="acpid acpid acpid acpid"
    [cpufrequtils]="cpufreq-utils cpufreq-utils kernel-tools cpupower"
    [thermald]="thermald SKIP thermald thermald"
    [powertop]="powertop powertop powertop powertop"
    [laptop-mode-tools]="laptop-mode-tools laptop-mode-tools laptop-mode-tools SKIP"
    [tlp]="tlp tlp tlp tlp"
    
    # locale / internationalization
    [language-pack-en]="SKIP glibc-locales glibc-langpack-en glibc-locales"
    [language-pack-de]="SKIP glibc-locales glibc-langpack-de glibc-locales"
    [language-pack-fr]="SKIP glibc-locales glibc-langpack-fr glibc-locales"
    [language-pack-ja]="SKIP glibc-locales glibc-langpack-ja glibc-locales"
    [language-pack-zh]="SKIP glibc-locales glibc-langpack-zh glibc-locales"
    [translation-update]="SKIP SKIP SKIP SKIP"
    [unicode-data]="unicode-data unicode-data unicode-data unicode-data"
    
    # miscellaneous utilities
    [cowsay]="cowsay cowsay cowsay cowsay"
    [figlet]="figlet figlet figlet figlet"
    [fortune]="fortune-mod fortune-mod fortune-mod fortune-mod"
    [lolcat]="SKIP lolcat SKIP lolcat"
    [sl]="sl sl sl sl"
    [asciinema]="asciinema asciinema asciinema asciinema"
    [expect]="expect expect expect expect"
    [whiptail]="newt newt newt newt"
    [dialog]="dialog dialog dialog dialog"
    [zenity]="zenity zenity zenity zenity"
    [kdialog]="kdialog kdialog kdialog kdialog"
)

map_packages() {
    # map_packages <family: alpine|arch|fedora|void> <pkgs...>
    # Maps Debian package names to distro-specific names
    local family="$1"; shift
    local col
    case "$family" in
        alpine) col=1 ;;
        arch)   col=2 ;;
        fedora) col=3 ;;
        void)   col=4 ;;
        *)      echo "$*"; return ;;
    esac
    
    local out=() p entry mapped
    for p in "$@"; do
        entry="${PKG_MAP[$p]:-}"
        if [ -z "$entry" ]; then
            out+=("$p")  # unknown: pass through
            continue
        fi
        mapped=$(awk -v c="$col" '{print $c}' <<<" $entry")
        if [ "$mapped" = "SKIP" ]; then
            warn "Package '$p' has no clean $family equivalent — skipped."
        else
            out+=("$mapped")
        fi
    done
    echo "${out[*]}"
}

###############################################################################
# PACKAGE MANAGER OPERATIONS
###############################################################################
#
# pm_install / pm_remove / pm_update are defined in src/features/sysconfig.sh.
#
# They used to be defined here as well. Because features are sourced after
# core, the sysconfig.sh definitions won in the main shell -- but this file
# also exported package-manager helpers into child shells, so every child shell
# (fm_as_user's `bash -lc`, `su - "$u" -c`, ...) inherited *these* weaker
# copies instead: no validate_packages, no `--` argument terminator, only
# apt/apk/pacman/dnf handled, and `pacman -Sy` for installs, which is the
# partial-upgrade pattern that breaks Arch systems.
#
# Keeping one definition removes the divergence.

###############################################################################
# UTILITY FUNCTIONS
###############################################################################

# Check if a command exists
cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Get a yes/no value from user
ask_yesno() {
    local prompt="$1" default="${2:-n}"
    local answer
    case "$default" in
        y|yes) prompt+=" [Y/n] " ;;
        n|no)  prompt+=" [y/N] " ;;
        *)     prompt+=" [y/n] " ;;
    esac
    local attempt=0
    while [ "$attempt" -lt 10 ]; do
        attempt=$((attempt + 1))
        # A failed read means EOF/non-interactive stdin. Recursing here spun
        # forever; fall back to the caller's stated default instead.
        if ! read -rp "$prompt" answer; then
            case "$default" in y|yes) return 0 ;; *) return 1 ;; esac
        fi
        case "$answer" in
            [yY]*) return 0 ;;
            [nN]*) return 1 ;;
            "")    case "$default" in y|yes) return 0 ;; n|no) return 1 ;; esac ;;
        esac
    done
    case "$default" in y|yes) return 0 ;; *) return 1 ;; esac
}

# Check if running in a terminal
is_terminal() {
    [ -t 0 ]
}

# map_packages is deliberately NOT exported: it reads PKG_MAP, and bash cannot
# export associative arrays. A child shell would see an empty map and pass
# every package name through unmapped, silently producing wrong package names
# on Alpine/Arch/Fedora/Void. Call it from the main shell only.
export -f cmd_exists ask_yesno is_terminal
