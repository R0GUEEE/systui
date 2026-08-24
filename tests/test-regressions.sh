#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf -- "$tmpdir"' EXIT

failures=0
checks=0
check() {
    local description="$1"
    shift
    checks=$((checks + 1))
    if "$@"; then
        printf 'ok %d - %s\n' "$checks" "$description"
    else
        printf 'not ok %d - %s\n' "$checks" "$description"
        failures=$((failures + 1))
    fi
}

contains() { grep -Fq -- "$2" "$1"; }
not_contains() { ! grep -Fq -- "$2" "$1"; }
function_exists() { declare -F "$1" >/dev/null; }

# A caller-provided SYSTUI_TMP must never be treated as an owned directory.
sentinel="$tmpdir/do-not-delete"
mkdir -p "$sentinel"
SYSTUI_TMP="$sentinel" TMPDIR="$tmpdir" bash -c '
    . "$1"
    [ "$SYSTUI_TMP" != "$2" ]
    [ -f "$SYSTUI_TMP/.systui-owned" ]
' _ "$PROJECT_DIR/src/core/config.sh" "$sentinel"
check "pre-existing SYSTUI_TMP is not deleted" test -d "$sentinel"

SYSTUI_TMP="$tmpdir/runtime"
mkdir -p "$SYSTUI_TMP"
LOGFILE="$tmpdir/test.log"
PM=apt
INIT=systemd
export SYSTUI_TMP LOGFILE PM INIT

# shellcheck source=../src/features/rootfs.sh
source "$PROJECT_DIR/src/features/rootfs.sh"
# shellcheck source=../src/features/sysconfig.sh
source "$PROJECT_DIR/src/features/sysconfig.sh"
# shellcheck source=../src/features/health.sh
source "$PROJECT_DIR/src/features/health.sh"

check "advanced shell menu target exists" function_exists menu_shell_advanced
check "nushell manager target exists" function_exists menu_nushell
check "set default shell function exists" function_exists menu_set_default_shell
check "set default shell includes nushell (nu)" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "nu ksh mksh"
check "set default shell checks etc-shells" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "grep -qxF"
check "set default shell offers to add missing shell to etc-shells" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "Add to /etc/shells"
check "set default shell falls back to usermod" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "usermod -s"
check "default action in menu_shells calls new function" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "default) menu_set_default_shell"
check "obsolete advanced shell target is absent" not_contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "menu_shells_advanced"
check "all password prompts use the defined widget" not_contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "tui_pass "
check "nushell is exposed in shell config choices" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "config.nu — Nushell startup config"
check "nushell plugin manager is exposed" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "Nushell plugins —"
check "nushell plugin core catalogue defined" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "NU_PLUGINS_CORE="
check "nushell plugin popular catalogue defined" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "NU_PLUGINS_POPULAR="
check "nushell core plugins include polars" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "nu_plugin_polars|Polars"
check "nushell core plugins include gstat" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "nu_plugin_gstat|gstat"
check "nushell core plugins include query" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "nu_plugin_query|Query"
check "nushell core plugins include formats" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "nu_plugin_formats|Formats"
check "nushell popular plugins include highlight" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "nu_plugin_highlight|"
check "nushell popular plugins include dns" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "nu_plugin_dns|"
check "nushell popular plugins include plot" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "nu_plugin_plot|"
check "nushell popular plugins include dbus" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "nu_plugin_dbus|"
check "nushell popular plugins include tree" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "nu_plugin_tree|"
check "nushell popular plugins include units" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "nu_plugin_units|"
check "nushell popular plugins include skim" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "nu_plugin_skim|"
check "nushell plugin install helper exists" function_exists nu_plugin_install_from_list
check "nushell plugin update-all helper exists" function_exists nu_plugin_update_all
check "nushell plugin cargo bin helper exists" function_exists nu_plugin_cargo_bin
check "nushell plugin display-name helper exists" function_exists nu_plugin_display_name
check "nushell plugin labels strip the nu_plugin prefix" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" 'name=${name#nu_plugin_}'
check "nushell plugin labels replace underscores with dashes" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" '${name//_/-}'
check "nushell plugin menu has core action" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" 'core    "Install core plugins'
check "nushell plugin menu has popular action" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" 'popular "Install popular third-party plugins'
check "nushell plugin menu has update action" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" 'update  "Re-register all plugins'
check "nushell multi-method install menu exists" function_exists menu_nushell_install
check "nushell github binary install helper exists" function_exists nu_github_install
check "nushell github install targets nushell releases api" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "api.github.com/repos/nushell/nushell/releases/latest"
check "nushell homebrew install method present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "brew install nushell"
check "nushell cargo install method present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "cargo install nu --locked"
check "nushell gemfury apt method present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "apt.fury.io/nushell"

# ---- Per-package multi-method install helpers --------------------------------
check "starship install menu exists" function_exists menu_starship_install
check "starship install.sh method present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "starship.rs/install.sh"
check "starship cargo method present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "cargo install starship --locked"

check "zsh install menu exists" function_exists menu_zsh_install

check "fish install menu exists" function_exists menu_fish_install
check "fish PPA method present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "ppa:fish-shell/release-4"

check "neovim install menu exists" function_exists menu_neovim_install
check "neovim github install helper exists" function_exists neovim_github_install
check "neovim github targets neovim releases api" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "api.github.com/repos/neovim/neovim/releases/latest"
check "neovim PPA method present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "ppa:neovim-ppa/stable"

check "micro install menu exists" function_exists menu_micro_install
check "micro github install helper exists" function_exists micro_github_install
check "micro github targets zyedidia/micro releases api" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "api.github.com/repos/zyedidia/micro/releases/latest"
check "micro getmicro script method present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "getmic.ro"

check "fzf install menu exists" function_exists menu_fzf_install
check "fzf github install helper exists" function_exists fzf_github_install
check "fzf github targets junegunn/fzf releases api" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "api.github.com/repos/junegunn/fzf/releases/latest"
check "fzf git-clone method present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "github.com/junegunn/fzf.git"

check "docker install menu exists" function_exists menu_docker_install
check "docker convenience script method present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "get.docker.com"
check "docker CE APT repo method present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "download.docker.com/linux"

check "node install menu exists" function_exists menu_node_install
check "node nvm method present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "nvm-sh/nvm"
check "node fnm method present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "fnm.vercel.app/install"
check "node nodesource method present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "deb.nodesource.com/setup_lts.x"

check "ripgrep install menu exists" function_exists menu_ripgrep_install
check "ripgrep github install helper exists" function_exists rg_github_install
check "ripgrep github targets BurntSushi/ripgrep releases api" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "api.github.com/repos/BurntSushi/ripgrep/releases/latest"

check "app_page dispatches to per-package install menus" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "menu_docker_install"
check "starship menu wired into plugin_starship" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "install) menu_starship_install"
check "fzf menu wired into plugin_fzf" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "install) menu_fzf_install"
check "fish menu wired into shell hierarchy" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "install) menu_fish_install"
check "zsh menu wired into shell hierarchy" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "install) menu_zsh_install"

# Exercise the rootfs package helper without entering a real chroot.
root_target="$tmpdir/rootfs"
mkdir -p "$root_target/tmp" "$root_target/usr/sbin"
unset target || true
rootfs_chroot_exec_args() {
    [ "$1" = "$root_target" ] && [ -f "$1/tmp/systui-install-packages.sh" ]
}
check "rootfs recovery script is created inside its target" \
    rootfs_install_deb_packages "$root_target" "curl"
check "rootfs helper does not write its script to host /tmp" \
    test ! -e /tmp/systui-install-packages.sh

# The mirror probe must use each candidate argument, not a dynamically scoped
# value left by its caller.
mirror=https://bad.invalid/ubuntu
log() { :; }
curl() {
    case " $* " in
        *" https://archive.ubuntu.com/ubuntu/dists/noble/InRelease "*) return 0 ;;
        *) return 1 ;;
    esac
}
selected=$(rootfs_select_ubuntu_mirror "$mirror" amd64 noble)
check "Ubuntu mirror fallback probes the actual candidate" \
    test "$selected" = "https://archive.ubuntu.com/ubuntu"
check "Kali has only its dedicated systemd init branch" not_contains \
    "$PROJECT_DIR/src/features/rootfs.sh" "debian|ubuntu|kali)"
unset -f curl

# --- Rootfs input validation (added during the rootfs audit) ----------------
check "mirror validator accepts plain http(s) URLs" \
    bash -c '. "$1/src/features/rootfs.sh" 2>/dev/null; rootfs_valid_mirror "https://deb.debian.org/debian" && rootfs_valid_mirror "http://dl-cdn.alpinelinux.org/alpine"' _ "$PROJECT_DIR"
check "mirror validator rejects quotes and backticks" \
    bash -c '. "$1/src/features/rootfs.sh" 2>/dev/null; ! rootfs_valid_mirror "https://evil.example/a\"b" && ! rootfs_valid_mirror "https://evil.example/a\`b"' _ "$PROJECT_DIR"
check "mirror validator rejects whitespace and shell metacharacters" \
    bash -c '. "$1/src/features/rootfs.sh" 2>/dev/null; ! rootfs_valid_mirror "https://evil.example/a b" && ! rootfs_valid_mirror "https://evil.example/a;rm -rf /"' _ "$PROJECT_DIR"
check "release validator accepts sane release names" \
    bash -c '. "$1/src/features/rootfs.sh" 2>/dev/null; rootfs_valid_release "noble" && rootfs_valid_release "v3.20" && rootfs_valid_release "sid-slim"' _ "$PROJECT_DIR"
check "release validator rejects path or shell characters" \
    bash -c '. "$1/src/features/rootfs.sh" 2>/dev/null; ! rootfs_valid_release "../../etc" && ! rootfs_valid_release "edge main"' _ "$PROJECT_DIR"
check "service validator accepts systemd/openrc unit names" \
    bash -c '. "$1/src/features/rootfs.sh" 2>/dev/null; rootfs_valid_service "nginx" && rootfs_valid_service "sshd@.service" && rootfs_valid_service "mysql-default"' _ "$PROJECT_DIR"
check "service validator rejects shell metacharacters" \
    bash -c '. "$1/src/features/rootfs.sh" 2>/dev/null; ! rootfs_valid_service "a;rm -rf /" && ! rootfs_valid_service "\$(touch /pwned)"' _ "$PROJECT_DIR"
check "port validator accepts valid ports only" \
    bash -c '. "$1/src/features/rootfs.sh" 2>/dev/null; rootfs_valid_port 22 && ! rootfs_valid_port 0 && ! rootfs_valid_port 65536 && ! rootfs_valid_port "2x"' _ "$PROJECT_DIR"
check "locale validator rejects path or shell characters" \
    bash -c '. "$1/src/features/rootfs.sh" 2>/dev/null; rootfs_valid_locale "en_US.UTF-8" && ! rootfs_valid_locale "../../x" && ! rootfs_valid_locale "a b"' _ "$PROJECT_DIR"
globdir="$tmpdir/globtest"
mkdir -p "$globdir"
touch "$globdir/a.c" "$globdir/b.c" "$globdir/x"
# rootfs.sh is a leaf module; when tested standalone it has no warn().
warn() { :; }
# Pre-fix, "*.c" would be expanded against the cwd into "a.c b.c" and the
# whole list would pass validation. Post-fix the glob is treated literally,
# fails the package-name check, and sanitize rejects the input outright.
if (cd "$globdir" && rootfs_sanitize_packages "a.c *.c" >/dev/null 2>&1); then
    check "package sanitizer treats globs literally instead of expanding them" false
else
    check "package sanitizer treats globs literally instead of expanding them" true
fi
if rootfs_sanitize_packages "curl;rm -rf /" >/dev/null 2>&1; then
    check "package sanitizer rejects unsafe names" false
else
    check "package sanitizer rejects unsafe names" true
fi
check "alpine host arch maps from uname instead of defaulting to target" contains \
    "$PROJECT_DIR/src/features/rootfs.sh" "host_apk_arch=\"x86_64\""
check "apk key seeding no longer uses the BusyBox-unsafe wildcard fetch" not_contains \
    "$PROJECT_DIR/src/features/rootfs.sh" "wget -q -P /etc/apk/keys"
check "build_alpine fails loudly on unknown host arch" contains \
    "$PROJECT_DIR/src/features/rootfs.sh" "Unknown host architecture"

# Rootfs bootstrap tools menu checks
check "menu_rootfs_bootstrap_tools function exists" function_exists menu_rootfs_bootstrap_tools
check "bootstrap tools menu wired into menu_rootfs" contains \
    "$PROJECT_DIR/src/features/rootfs.sh" "bootstrap)  menu_rootfs_bootstrap_tools"
check "bootstrap tools menu uses tui_menu with per-tool submenu" contains \
    "$PROJECT_DIR/src/features/rootfs.sh" "tui_menu \"Rootfs Bootstrap Tools\""
check "bootstrap tools menu includes debootstrap" contains \
    "$PROJECT_DIR/src/features/rootfs.sh" "debootstrap"
check "bootstrap tools menu includes mmdebstrap" contains \
    "$PROJECT_DIR/src/features/rootfs.sh" "mmdebstrap"
check "bootstrap tools menu includes pacstrap" contains \
    "$PROJECT_DIR/src/features/rootfs.sh" "arch-install-scripts"
check "bootstrap tools menu includes proot" contains \
    "$PROJECT_DIR/src/features/rootfs.sh" "proot"
check "bootstrap tools menu includes qemu-user-static" contains \
    "$PROJECT_DIR/src/features/rootfs.sh" "qemu-user-static"
check "bootstrap tools menu maps packages via _bs_pkg" contains \
    "$PROJECT_DIR/src/features/rootfs.sh" "_bs_pkg"
check "rootfs init selector includes runit option" contains \
    "$PROJECT_DIR/src/features/rootfs.sh" "runit    \"runit\" off"
check "rootfs init selector includes custom init path" contains \
    "$PROJECT_DIR/src/features/rootfs.sh" "Other/custom init (manual package list)"
check "rootfs init selector prompts for custom init packages" contains \
    "$PROJECT_DIR/src/features/rootfs.sh" "Custom init packages"

# Generated catalogue installers must be complete and syntactically valid.
SYSTUI_AWESOME_CACHE="$tmpdir/awesome"
export SYSTUI_AWESOME_CACHE
mkdir -p "$SYSTUI_AWESOME_CACHE"
catalog="$SYSTUI_AWESOME_CACHE/catalog.tsv"
printf 'a00001\tDevelopment\tExample App\thttps://example.com\thttps://github.com/example/app\tExample\n' > "$catalog"
generate_log="$tmpdir/generate.log"
awesome_linux_generate_catalog_installers "$catalog" >"$generate_log" 2>&1
installer="$SYSTUI_AWESOME_CACHE/installers/example-app-install.sh"
check "catalogue installer generation has no expansion error" not_contains "$generate_log" "bad substitution"
check "catalogue installer includes its command dispatcher" contains "$installer" 'method=${1:-auto}'
check "catalogue installer passes POSIX shell syntax" sh -n "$installer"

# Project-specific GitHub installers must defer translated dependency variables
# until the generated script runs on the target distribution.
fake_source="$tmpdir/fake-github-source"
mkdir -p "$fake_source"
: > "$fake_source/CMakeLists.txt"
awesome_linux_github_clone() { return 0; }
awesome_linux_source_dir() { printf '%s\n' "$fake_source"; }
tui_msg() { return 0; }
github_installer=$(awesome_linux_generate_github_installer \
    "GitHub Example" "https://github.com/example/app")
check "GitHub installer preserves APK dependency expansion" contains \
    "$github_installer" 'apk add --no-cache $apk_deps'
check "GitHub installer preserves Pacman dependency expansion" contains \
    "$github_installer" 'pacman -S --needed --noconfirm $pacman_deps'
check "GitHub installer preserves DNF dependency expansion" contains \
    "$github_installer" 'dnf install -y --setopt=install_weak_deps=False $dnf_deps'
check "GitHub installer passes POSIX shell syntax" sh -n "$github_installer"

# Healthy package/service commands may print routine status text but should
# still produce the explicit clean markers used by the dashboard.
dpkg() { return 0; }
apt-get() { printf 'Reading package lists...\nBuilding dependency tree...\n'; return 0; }
systemctl() { return 0; }
package_report=$(health_tmp test-packages)
service_report=$(health_tmp test-services)
health_package_issues "$package_report"
health_service_issues "$service_report"
check "healthy APT state is reported as clean" contains "$package_report" "No package integrity problems detected."
check "healthy systemd state is reported as clean" contains "$service_report" "No failed or crashed services detected."
case "$(health_tmp private)" in "$SYSTUI_TMP"/*) private_ok=1 ;; *) private_ok=0 ;; esac
check "health reports stay in the private workspace" test "$private_ok" -eq 1

# ---- Per-manager install menus ---------------------------------------------
check "menu_brew_install exists"        function_exists menu_brew_install
check "menu_nix_install exists"         function_exists menu_nix_install
check "menu_yay_install exists"         function_exists menu_yay_install
check "menu_paru_install exists"        function_exists menu_paru_install
check "menu_cargo_install exists"       function_exists menu_cargo_install
check "menu_npm_install exists"         function_exists menu_npm_install
check "menu_pnpm_install exists"        function_exists menu_pnpm_install
check "menu_yarn_install exists"        function_exists menu_yarn_install
check "menu_gem_install exists"         function_exists menu_gem_install
check "menu_composer_install exists"    function_exists menu_composer_install
check "menu_go_install exists"          function_exists menu_go_install
check "menu_pipx_install exists"        function_exists menu_pipx_install
check "menu_pip_install exists"         function_exists menu_pip_install
check "menu_flatpak_install exists"     function_exists menu_flatpak_install
check "menu_snap_install exists"        function_exists menu_snap_install
# Root-compatible Homebrew installer tests
check "menu_brew_install exists"               function_exists menu_brew_install
check "brew root installer helper exists"      function_exists brew_root_compat_script
check "brew root env helper exists"            function_exists brew_root_compat_env_file
check "brew root installer moved to share/"    test -f "$PROJECT_DIR/share/homebrew/install-homebrew-root.sh"
check "brew sysconfig uses shared installer path" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" 'share/homebrew/install-homebrew-root.sh'
check "brew root install checks root UID"      contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "Root privileges are required"
check "brew installer defines LD_PRELOAD shim" contains \
    "$PROJECT_DIR/share/homebrew/install-homebrew-root.sh" "libhomebrew_fakeuid.so"
check "brew installer defines linuxbrew prefix" contains \
    "$PROJECT_DIR/share/homebrew/install-homebrew-root.sh" "/home/linuxbrew/.linuxbrew"
check "brew installer defines permanent env dir" contains \
    "$PROJECT_DIR/share/homebrew/install-homebrew-root.sh" 'readonly ROOT_ENV_DIR="/etc/systui"'
check "brew installer defines permanent env file variable" contains \
    "$PROJECT_DIR/share/homebrew/install-homebrew-root.sh" 'readonly ROOT_ENV_FILE="${ROOT_ENV_DIR}/homebrew.env"'
check "brew advanced config targets permanent env file when active" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "/etc/systui/homebrew.env"
check "brew installer is no longer embedded in sysconfig" not_contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "Root-managed Homebrew installer for Debian arm64 on iSH-AOK."
check "brew pm install option removed" not_contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" 'Package manager (${PM} install brew)'
check "nix determinate installer URL present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "install.determinate.systems/nix"
check "nix official multi-user install present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "nixos.org/nix/install"
check "yay AUR git clone present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "aur.archlinux.org/yay.git"
check "paru AUR git clone present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "aur.archlinux.org/paru.git"
check "cargo rustup install script present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "sh.rustup.rs"
check "npm nvm install script present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "nvm-sh/nvm"
check "npm fnm install script present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "fnm.vercel.app/install"
check "npm nodesource APT setup present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "deb.nodesource.com"
check "pnpm official install script present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "get.pnpm.io/install.sh"
check "yarn corepack enable present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "corepack enable"
check "gem rbenv install present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "rbenv.org/install.sh"
check "gem rvm install present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "get.rvm.io"
check "composer official installer present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "getcomposer.org/installer"
check "go official tarball URL present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "go.dev/dl"
check "pip get-pip.py URL present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "bootstrap.pypa.io/get-pip.py"
check "pip ensurepip method present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "ensurepip --upgrade"
check "pipx pip install method present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "pip3 install --user pipx"
check "flatpak Flathub remote add present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "dl.flathub.org/repo/flathub.flatpakrepo"
check "snap enable service method present" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "snapd.service"

# menu_cfg_cli_manager accepts 5th install-fn argument
check "menu_cfg_cli_manager install_fn param" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" 'install_fn='
check "menu_cfg_cli_manager calls install_fn" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" '"$install_fn"'

# Wiring: install functions passed into menu_package_managers dispatch
check "brew wired with menu_brew_install" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "menu_brew_install"
check "nix wired with menu_nix_install" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "menu_nix_install"
check "cargo wired with menu_cargo_install" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "menu_cargo_install"
check "npm wired with menu_npm_install" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "menu_npm_install"
check "yay wired with menu_yay_install" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "menu_yay_install"
check "paru wired with menu_paru_install" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "menu_paru_install"
check "flatpak guard uses menu_flatpak_install" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "menu_flatpak_install"
check "snap guard uses menu_snap_install" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "menu_snap_install"

# ---- Popular repositories expansions --------------------------------------
# APT_POPULAR new entries
check "APT_POPULAR has kubernetes repo"      contains "$PROJECT_DIR/src/features/sysconfig.sh" "pkgs.k8s.io/core:/stable:/v1.32/deb"
check "APT_POPULAR has github-cli repo"      contains "$PROJECT_DIR/src/features/sysconfig.sh" "cli.github.com/packages/githubcli-archive-keyring.gpg"
check "APT_POPULAR has brave repo"           contains "$PROJECT_DIR/src/features/sysconfig.sh" "brave-browser-apt-release.s3.brave.com"
check "APT_POPULAR has sublime-text repo"    contains "$PROJECT_DIR/src/features/sysconfig.sh" "download.sublimetext.com"
check "APT_POPULAR has signal repo"          contains "$PROJECT_DIR/src/features/sysconfig.sh" "updates.signal.org/desktop/apt"
check "APT_POPULAR has spotify repo"         contains "$PROJECT_DIR/src/features/sysconfig.sh" "repository.spotify.com"
check "APT_POPULAR has influxdb repo"        contains "$PROJECT_DIR/src/features/sysconfig.sh" "repos.influxdata.com/stable"
check "APT_POPULAR has elastic repo"         contains "$PROJECT_DIR/src/features/sysconfig.sh" "artifacts.elastic.co/packages/8.x/apt"
check "APT_POPULAR has cloudflared repo"     contains "$PROJECT_DIR/src/features/sysconfig.sh" "pkg.cloudflare.com/cloudflared"
check "APT_POPULAR has virtualbox repo"      contains "$PROJECT_DIR/src/features/sysconfig.sh" "download.virtualbox.org/virtualbox/debian"

# DNF new entries
check "DNF popular has kubernetes"           contains "$PROJECT_DIR/src/features/sysconfig.sh" "pkgs.k8s.io/core:/stable:/v1.32/rpm"
check "DNF popular has github-cli"           contains "$PROJECT_DIR/src/features/sysconfig.sh" "cli.github.com/packages/rpm/gh-cli.repo"
check "DNF popular has grafana"              contains "$PROJECT_DIR/src/features/sysconfig.sh" "rpm.grafana.com"
check "DNF popular has hashicorp"            contains "$PROJECT_DIR/src/features/sysconfig.sh" "rpm.releases.hashicorp.com"
check "DNF popular has brave"                contains "$PROJECT_DIR/src/features/sysconfig.sh" "brave-browser-rpm-release.s3.brave.com"
check "DNF popular has influxdb"             contains "$PROJECT_DIR/src/features/sysconfig.sh" "repos.influxdata.com/rhel"
check "DNF popular has elastic"              contains "$PROJECT_DIR/src/features/sysconfig.sh" "artifacts.elastic.co/packages/8.x/yum"
check "DNF popular has postgres"             contains "$PROJECT_DIR/src/features/sysconfig.sh" "download.postgresql.org/pub/repos/yum"

# Pacman new entries
check "Pacman popular has blackarch"         contains "$PROJECT_DIR/src/features/sysconfig.sh" "blackarch.org/strap.sh"
check "Pacman popular has cachyos"           contains "$PROJECT_DIR/src/features/sysconfig.sh" "mirror.cachyos.org"
check "Pacman popular has endeavouros"       contains "$PROJECT_DIR/src/features/sysconfig.sh" "mirror.endeavouros.com"

# zypper case added
check "zypper popular repos case exists"     contains "$PROJECT_DIR/src/features/sysconfig.sh" "zypper)"
check "zypper packman repo present"          contains "$PROJECT_DIR/src/features/sysconfig.sh" "ftp.gwdg.de/pub/linux/misc/packman"
check "zypper kubernetes repo present"       contains "$PROJECT_DIR/src/features/sysconfig.sh" "pkgs.k8s.io/core:/stable:/v1.32/rpm"
check "zypper grafana repo present"          contains "$PROJECT_DIR/src/features/sysconfig.sh" "rpm.grafana.com"

# APK edge repos
check "APK edge-main option present"         contains "$PROJECT_DIR/src/features/sysconfig.sh" "edge-main"
check "APK edge-community option present"    contains "$PROJECT_DIR/src/features/sysconfig.sh" "edge-community"

###############################################################################
# System Configuration menu — redundancy and conflict fixes
###############################################################################
SYSCFG="$PROJECT_DIR/src/features/sysconfig.sh"

rootfs_has_no_dunder_tags() { ! grep -q '__[a-z]' "$PROJECT_DIR/src/features/rootfs.sh"; }
lacks()      { ! grep -Fq -- "$2" "$1"; }
equals_out() { [ "$1" = "$2" ]; }
occurs()  { [ "$(grep -Fc -- "$2" "$1")" = "$3" ]; }
# A sysctl key must be written by exactly one systui file, or sysctl.d's
# filename ordering silently reverts whichever menu entry ran first. Collect
# the keys each sysctl.d file actually receives: either assigned on the same
# line as the redirection (printf/echo) or inside the heredoc that follows.
sysctl_owners_of() { # <key> -> one owning filename per line
    awk -v key="$1" '
        {
            line = $0
            if (match(line, /\/etc\/sysctl\.d\/[0-9A-Za-z._-]+\.conf/)) {
                target = substr(line, RSTART, RLENGTH)
                if (index(line, key "=") || index(line, key " =")) print target
                if (index(line, "<<")) { heredoc = 1; next }
                next
            }
            if (heredoc) {
                if (line ~ /^[[:space:]]*EOF[[:space:]]*$/) { heredoc = 0; next }
                if (index(line, key "=") || index(line, key " =")) print target
            }
        }
    ' "$SYSCFG" | sort -u
}
sysctl_key_has_one_owner() {
    [ "$(sysctl_owners_of "$1" | wc -l)" -le 1 ]
}

# The Scanner feature was defined but unreachable from any menu.
check "Scanner is reachable from System Configuration" contains "$SYSCFG" 'scanner)     menu_scanner'
check "Scanner has a System Configuration entry"       contains "$SYSCFG" 'scanner     "Scanner'

# menu_pm_config duplicated Package Managers and was never called.
check "dead menu_pm_config is gone"                    lacks "$SYSCFG" 'menu_pm_config() {'
check "live native tuning menu is retained"            contains "$SYSCFG" 'menu_cfg_native_full() {'

# menu_shells had three entries resolving to menu_shell_config.
check "duplicate bashopts shell entry is gone"         lacks "$SYSCFG" 'bashopts "Bash options"'
check "placeholder history shell entry is gone"        lacks "$SYSCFG" 'history "History settings"'
check "shell config entry is retained"                 contains "$SYSCFG" 'config) menu_shell_config ;;'

# Overlapping sysctl writes: each key needs exactly one owning file.
check "vm.swappiness has a single owner"               sysctl_key_has_one_owner vm.swappiness
check "vm.vfs_cache_pressure has a single owner"       sysctl_key_has_one_owner vm.vfs_cache_pressure
check "vm.dirty_ratio has a single owner"              sysctl_key_has_one_owner vm.dirty_ratio
check "vm.dirty_background_ratio has a single owner"    sysctl_key_has_one_owner vm.dirty_background_ratio
check "writeback owns the dirty ratios"                equals_out \
    "$(sysctl_owners_of vm.dirty_ratio)" /etc/sysctl.d/92-systui-writeback.conf
check "the dedicated entry owns vm.swappiness"         equals_out \
    "$(sysctl_owners_of vm.swappiness)" /etc/sysctl.d/90-systui-swappiness.conf

# Input written into sysctl/limits/unit paths is validated.
check "swappiness input is range-checked"              contains "$SYSCFG" 'valid_uint "$v" && [ "$v" -le 200 ]'
check "cache pressure input is validated"              contains "$SYSCFG" 'valid_uint "$cache"'
check "nofile limit is validated"                      contains "$SYSCFG" 'valid_uint "$n" ||'
check "systemd unit name is validated before use as a path" \
    contains "$SYSCFG" 'valid_safe_name "$n" ||'

# `A && echo 0 > f || echo 1 > f` wrote the opposite value on write failure.
check "turbo toggle no longer uses an inverting and-or chain" \
    lacks "$SYSCFG" '|| echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo'
check "turbo toggle picks the value before writing" contains "$SYSCFG" 'turbo_val'

###############################################################################
# Rootfs builder — silent-failure fixes
###############################################################################
ROOTFS="$PROJECT_DIR/src/features/rootfs.sh"
check "piped tar fallbacks run under pipefail"  occurs "$ROOTFS" 'set -o pipefail; tar -C' 2
check "xz archives are guarded like zst"        contains "$ROOTFS" 'rootfs_archive_missing_tool'
check "unknown archive format is rejected"      contains "$ROOTFS" 'Unsupported archive format'
check "profile.d is created before writing"     contains "$ROOTFS" 'mkdir -p "$target/etc/profile.d"'
check "runit service dir is created"            contains "$ROOTFS" 'mkdir -p "$target/etc/runit/runsvdir/default"'
check "backend config menu cannot loop forever" contains "$ROOTFS" 'Backends without tool options'
check "release menu always preselects an entry" contains "$ROOTFS" 'have_default'

# --- Chroot workbench wiring ------------------------------------------------
check "workbench is on the Rootfs menu"      contains "$ROOTFS" 'workbench  "Chroot workbench'
check "workbench menu entry is dispatched"   contains "$ROOTFS" 'workbench)  menu_rootfs_workbench'
check "workbench can pack any rootfs"        contains "$ROOTFS" 'rootfs_wb_pack() {'
check "workbench can unpack a tarball"       contains "$ROOTFS" 'rootfs_wb_unpack() {'
check "packing refuses a mounted tree"       contains "$ROOTFS" 'Archiving now would capture'
check "mount discovery reads /proc/mounts"   contains "$ROOTFS" '/proc/mounts'
check "detach handles busy mounts lazily"    contains "$ROOTFS" 'umount -l "$mp"'
check "tar_create accepts exclude options"   contains "$ROOTFS" '[extra tar args...]'

# --- Midnight Commander ------------------------------------------------------
check "mc is on the File Managers menu"      contains "$SYSCFG" 'mc     "Midnight Commander'
check "mc menu entry is dispatched"          contains "$SYSCFG" 'mc) menu_file_manager_one mc'
check "mc maps to the mc package"            contains "$SYSCFG" 'mc:*) echo mc ;;'
check "mc has a configuration menu"          contains "$SYSCFG" 'fm_configure_mc_menu() {'
check "mc config menu is wired in"           contains "$SYSCFG" 'mc) fm_configure_mc_menu ;;'
check "mc edits the right config file"       contains "$SYSCFG" 'mc)   f="$h/.config/mc/ini"'
check "mc has a keymap file mapping"         contains "$SYSCFG" 'mc) echo "$h/.config/mc/mc.keymap"'
check "mc has a default configuration"       contains "$SYSCFG" '[Midnight-Commander]'
check "mc has a skin/extension catalogue"    contains "$SYSCFG" 'mc-retro-skins|Norton, Volkov'
check "mc skins come from real upstreams"    contains "$SYSCFG" 'MidnightCommander/mc'
check "cloned mc skins are linked into place" contains "$SYSCFG" 'mc_link_skins() {'
check "mc ini keys are routed by section"    contains "$SYSCFG" 'mc_ini_section() {'
# mc silently ignores keys in the wrong section, so the routing matters.
check "layout keys route to [Layout]"        contains "$SYSCFG" 'menubar_visible|keybar_visible'
check "panel keys route to [Panels]"         contains "$SYSCFG" 'show_mini_info|kilobyte_si'

# --- Additional bootstrap tools ---------------------------------------------
check "rinse is a supported backend"         contains "$ROOTFS" 'build_rinse() {'
check "alpine-chroot-install is supported"   contains "$ROOTFS" 'build_alpine_chroot_install() {'
check "bdebstrap has a build branch"         contains "$ROOTFS" 'backend" = bdebstrap'
check "bdebstrap requires mmdebstrap"        contains "$ROOTFS" 'bdebstrap drives mmdebstrap'
check "rinse rejects unsupported arches"     contains "$ROOTFS" 'rinse only bootstraps i386 and amd64'
check "alpine-chroot-install is native only" contains "$ROOTFS" 'builds a chroot for the HOST architecture'

# --- Distro managers ---------------------------------------------------------
check "distro managers are on the Rootfs menu" contains "$ROOTFS" 'distros    "Distro managers'
check "distro manager menu is dispatched"      contains "$ROOTFS" 'distros)    menu_rootfs_distro_managers'
check "proot-distro is offered"                contains "$ROOTFS" 'proot-distro|proot-distro'
check "chroot-distro is offered"               contains "$ROOTFS" 'chroot-distro|chroot-distro'
# proot-distro refuses uid 0; systui runs as root, so it must drop privileges.
check "proot-distro is dropped from root"      contains "$ROOTFS" 'refuses to run as uid 0'
check "managers hand trees to the workbench"   contains "$ROOTFS" 'rootfs_wb_menu_for "$d"'
check "workbench menu is reusable"             contains "$ROOTFS" 'rootfs_wb_menu_for() {'

# --- Distro managers: installers, parsing, configuration --------------------
check "managers can be installed"            contains "$ROOTFS" 'rootfs_dm_install() {'
check "upstream installers exist"            contains "$ROOTFS" 'rootfs_dm_install_upstream() {'
check "managers can be uninstalled"          contains "$ROOTFS" 'rootfs_dm_remove() {'
check "distro lists are parsed per tool"     contains "$ROOTFS" 'rootfs_dm_parse_distros() {'
check "rootfs location is configurable"      contains "$ROOTFS" 'rootfs_dm_config_menu() {'
check "rootfs location override is stored"   contains "$ROOTFS" 'dm_store_$1'
check "run-as user is configurable"          contains "$ROOTFS" 'dm_user_$tag'
check "toolbx is offered"                    contains "$ROOTFS" 'toolbx|toolbox'
check "schroot is offered"                   contains "$ROOTFS" 'schroot|schroot'
check "udocker is offered"                   contains "$ROOTFS" 'udocker|udocker'
check "machinectl is offered"                contains "$ROOTFS" 'machinectl|machinectl'
check "chroot-distro downloads before install" contains "$ROOTFS" 'Download $d" download'
check "chroot-distro deletes rather than removes" contains "$ROOTFS" 'Delete $d via $tag" delete'

# --- Menu tag cleanup --------------------------------------------------------
# Internal "__" tags were visible because tui_menu prints the tag column.
check "no double-underscore tags remain in rootfs" rootfs_has_no_dunder_tags
check "workbench picker hides internal tags"  contains "$ROOTFS" 'tui_menu_no_tags "Chroot workbench"'
check "bind menu hides internal tags"         contains "$ROOTFS" 'tui_menu_no_tags "Bind mounts"'
check "rootfs manage hides internal tags"     contains "$ROOTFS" 'tui_menu_no_tags "Rootfs in $base"'

# --- System configuration workflow ------------------------------------------
check "common tasks front door exists"        contains "$SYSCFG" 'menu_sysconfig_common() {'
check "common tasks are reachable"            contains "$SYSCFG" 'common)      menu_sysconfig_common'
check "hostname helper is shared"             contains "$SYSCFG" 'sysconfig_set_hostname() {'
check "timezone helper is shared"             contains "$SYSCFG" 'sysconfig_set_timezone() {'
# The section menu must call the same helper, not a second copy of the logic.
check "network menu reuses the hostname helper" contains "$SYSCFG" 'hostname) sysconfig_set_hostname ;;'
check "network menu reuses the timezone helper" contains "$SYSCFG" 'tz) sysconfig_set_timezone ;;'
check "package menu leads with common actions"  contains "$SYSCFG" 'packages "Install, remove, search and update packages"'

printf '1..%d\n' "$checks"
[ "$failures" -eq 0 ]
