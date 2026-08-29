#!/bin/bash
# Tests for:
#   - additional shell options (dash/ksh/mksh/tcsh/elvish/xonsh/yash/pwsh)
#     in Shells & Plugins, incl. shell_pkg mapping and safe_remove_shell
#   - awesome-zsh-plugins catalogue integration (AZP_CATALOG, menu_azp,
#     azp_apply for oh-my-zsh / zinit / plain .zshrc)
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Minimal TUI/runtime stubs; the feature file only needs the function names at
# source time. run_cmd actually executes so installs are observable.
tui_msg() { :; }
tui_yesno() { return 0; }
tui_input() { printf '%s\n' "${3:-}"; }
tui_menu() { return 1; }
tui_radio() { return 1; }
tui_check() { return 1; }
tui_text() { :; }
run_cmd() { shift; "$@"; }
log() { :; }
warn() { :; }
export SYSTUI_TMP="$(mktemp -d)"
trap 'rm -rf "$SYSTUI_TMP"' EXIT
LOGFILE="$SYSTUI_TMP/test.log"
PM=apt
INIT=systemd
export LOGFILE PM INIT SYSTUI_TMP

# Fake git: clones create the destination with a loadable .plugin.zsh so the
# plain-install path can auto-detect a source file. Every invocation is logged
# so tests can assert exact clone flags (e.g. --recurse-submodules).
fake_bin="$SYSTUI_TMP/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/git" <<'GIT'
#!/bin/sh
echo "$*" >> "$GIT_ARGLOG"
# git clone --depth 1 <url> <dest>   |   git -C <dir> pull --ff-only
if [ "$1" = clone ]; then
    last=
    for a in "$@"; do last="$a"; done
    mkdir -p "$last"
    echo 'echo plugin loaded' > "$last/test.plugin.zsh"
fi
exit 0
GIT
chmod +x "$fake_bin/git"
export GIT_ARGLOG="$SYSTUI_TMP/git-args.log"
export PATH="$fake_bin:$PATH"

# shellcheck source=../src/features/sysconfig.sh
source "$PROJECT_DIR/src/features/sysconfig.sh"

# Test override: the real fm_as_user uses `bash -lc` (login shell), which
# resets PATH from /etc/profile and would bypass the fake git. Keep the test
# hermetic by running the command in a plain shell with the test PATH intact.
fm_as_user() {
    local u="$1" cmd="$2"
    bash -c "$cmd"
}

failures=0
checks=0
check() {
    local desc="$1"; shift
    checks=$((checks + 1))
    if "$@"; then
        printf 'ok %d - %s\n' "$checks" "$desc"
    else
        printf 'not ok %d - %s\n' "$checks" "$desc"
        failures=$((failures + 1))
    fi
}
contains() { grep -Fq -- "$2" "$1"; }
not_contains() { ! grep -Fq -- "$2" "$1"; }
function_exists() { declare -F "$1" >/dev/null; }
# check_fails <description> <cmd...>: asserts the command exits non-zero.
check_fails() {
    local desc="$1"; shift
    checks=$((checks + 1))
    if "$@" >/dev/null 2>&1; then
        printf 'not ok %d - %s (expected failure, got success)\n' "$checks" "$desc"
        failures=$((failures + 1))
    else
        printf 'ok %d - %s\n' "$checks" "$desc"
    fi
}

# ---- 1. Additional shell options --------------------------------------------

check "more-shells menu exists" function_exists menu_more_shells
check "generic plain-shell manager exists" function_exists menu_plain_shell
check "parameterized shell installer exists" function_exists menu_shell_install_any
check "safe_remove_shell is now defined" function_exists safe_remove_shell
check "pwsh GitHub release installer exists" function_exists pwsh_github_install
check "shell_pkg helper exists" function_exists shell_pkg

check "shell_pkg maps Gentoo xonsh" test "$(PM=emerge shell_pkg xonsh)" = "dev-python/xonsh"
check "shell_pkg maps Gentoo dash" test "$(PM=emerge shell_pkg dash)" = "app-shells/dash"
check "shell_pkg maps Gentoo pwsh" test "$(PM=emerge shell_pkg pwsh)" = "app-shells/pwsh-bin"
check "shell_pkg maps apt ksh to ksh93u+m" test "$(PM=apt shell_pkg ksh)" = "ksh93u+m"
check "shell_pkg passes through Alpine elvish" test "$(PM=apk shell_pkg elvish)" = "elvish"
check "shell_pkg passes through Fedora yash" test "$(PM=dnf shell_pkg yash)" = "yash"

check "shell managers radio offers more shells" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" 'more "More shells (dash, ksh, tcsh, elvish...)'
check "shell managers dispatches more-shells menu" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "more) menu_more_shells"
check "more-shells menu lists dash" contains "$PROJECT_DIR/src/features/sysconfig.sh" 'dash   "dash — Debian Almquist shell'
check "more-shells menu lists pwsh" contains "$PROJECT_DIR/src/features/sysconfig.sh" 'pwsh   "PowerShell — Microsoft'
check "default-shell radio includes elvish" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "for sh in bash zsh fish nu ksh mksh dash tcsh csh elvish xonsh yash pwsh sh; do"
check "shell inventory lists pwsh" contains "$PROJECT_DIR/src/features/sysconfig.sh" "pwsh|PowerShell|Shells"
check "shells catalogue includes elvish" contains "$PROJECT_DIR/src/features/sysconfig.sh" "elvish|Elvish|Expressive modern shell"

# safe_remove_shell refuses to remove the shell that is running systui.
check "safe_remove_shell refuses the running shell" bash -c \
    'source "$1"; tui_msg() { :; }; SHELL=/bin/bash safe_remove_shell bash' _ "$PROJECT_DIR/src/features/sysconfig.sh"
check "safe_remove_shell is a no-op for missing shells" bash -c \
    'source "$1"; tui_msg() { :; }; safe_remove_shell definitely-not-a-real-shell-xyz' _ \
    "$PROJECT_DIR/src/features/sysconfig.sh"

# ---- 2. awesome-zsh-plugins catalogue ---------------------------------------

check "azp browser menu exists" function_exists menu_azp
check "azp category menu exists" function_exists menu_azp_category
check "azp picker exists" function_exists menu_azp_pick
check "azp apply exists" function_exists azp_apply
check "azp repo lookup exists" function_exists azp_repo_for
check "plugin file detector exists" function_exists zsh_plugin_file
check "shell plugins menu offers azp catalogue" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" 'azp "awesome-zsh-plugins catalogue'
check "shell plugins menu dispatches azp" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "azp) menu_azp"

# Catalogue shape: 4 fields per line, unique tags, valid owner/repo, known categories.
check "AZP_CATALOG has at least 50 entries" test "$(grep -c '^[^ ]' <<<"$AZP_CATALOG")" -ge 50
check "AZP_CATALOG lines all have 4 fields" bash -c '
    source "$1"
    bad=$(awk -F"|" "NF != 4 {print NR\": \"\$0}" <<<"$AZP_CATALOG")
    [ -z "$bad" ]' _ "$PROJECT_DIR/src/features/sysconfig.sh"
check "AZP_CATALOG tags are unique" bash -c '
    source "$1"
    dup=$(cut -d"|" -f1 <<<"$AZP_CATALOG" | sort | uniq -d)
    [ -z "$dup" ]' _ "$PROJECT_DIR/src/features/sysconfig.sh"
check "AZP_CATALOG repos are valid owner/repo" bash -c '
    source "$1"
    bad=$(cut -d"|" -f3 <<<"$AZP_CATALOG" | grep -Ev "^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
    [ -z "$bad" ]' _ "$PROJECT_DIR/src/features/sysconfig.sh"
check "AZP_CATALOG categories are known" bash -c '
    source "$1"
    bad=$(cut -d"|" -f4 <<<"$AZP_CATALOG" | grep -Ev "^(nav|hist|git|comp|vi|alias|prompt|lang|misc)$")
    [ -z "$bad" ]' _ "$PROJECT_DIR/src/features/sysconfig.sh"
check "azp_repo_for resolves a tag" test "$(azp_repo_for git-fuzzy)" = "bigH/git-fuzzy"
check_fails "azp_repo_for fails for unknown tag" bash -c 'source "$1"; azp_repo_for nope >/dev/null 2>&1' _ \
    "$PROJECT_DIR/src/features/sysconfig.sh"

# zsh-abbr is kept (submodule clones make it load-safe); autojump was dropped
# because the repo has no loadable .zsh for the plain installer.
check "zsh-abbr stays in catalogue" bash -c \
    'source "$1"; grep -Fq "olets/zsh-abbr" <<<"$AZP_CATALOG"' _ "$PROJECT_DIR/src/features/sysconfig.sh"
check "autojump removed from catalogue (no loadable .zsh)" bash -c \
    'source "$1"; ! grep -Fq "wting/autojump" <<<"$AZP_CATALOG"' _ "$PROJECT_DIR/src/features/sysconfig.sh"
check "azp clones use --recurse-submodules (zsh-abbr hang fix)" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "git clone --depth 1 --recurse-submodules"
check "omz external clones use --recurse-submodules" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "git clone --depth 1 --recurse-submodules https://github.com/\$repo ~/.oh-my-zsh/custom/plugins/\$t"
check "omz plugin install warms compinit dump" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" 'zsh -f -c "autoload -Uz compinit && compinit"'
check "azp omz install warms compinit dump" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "autoload -Uz compinit && compinit"

# Existing plugin catalogues were enriched from awesome-zsh-plugins too.
check "OMZ external plugins include enhancd" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "enhancd|b4b4r07/enhancd|Enhanced cd"
check "ZINIT popular includes history-search-multi-word" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" "zdharma-continuum/history-search-multi-word"

# zsh_plugin_file auto-detection.
pd="$SYSTUI_TMP/plg-zsh-z"; mkdir -p "$pd"
echo x > "$pd/zsh-z.plugin.zsh"
check "plugin file prefers name.plugin.zsh" test "$(zsh_plugin_file "$pd")" = "zsh-z.plugin.zsh"
pd2="$SYSTUI_TMP/plg-other"; mkdir -p "$pd2"
echo x > "$pd2/random.plugin.zsh"
check "plugin file falls back to *.plugin.zsh" test "$(zsh_plugin_file "$pd2")" = "random.plugin.zsh"
pd3="$SYSTUI_TMP/plg-plain"; mkdir -p "$pd3"
echo x > "$pd3/main.zsh"
check "plugin file falls back to plain .zsh" test "$(zsh_plugin_file "$pd3")" = "main.zsh"
pd4="$SYSTUI_TMP/plg-empty"; mkdir -p "$pd4"
check_fails "plugin file fails on empty dir" bash -c 'source "$1"; zsh_plugin_file "$2" >/dev/null 2>&1' _ \
    "$PROJECT_DIR/src/features/sysconfig.sh" "$pd4"

# ---- 3. azp_apply end-to-end (fake git, real write paths) --------------------

home="$SYSTUI_TMP/home"; mkdir -p "$home"

# oh-my-zsh target: clone into custom/plugins + append to plugins=()
oz="$home/.oh-my-zsh"; mkdir -p "$oz/custom/plugins"
printf 'plugins=(git)\n' > "$home/.zshrc"
azp_apply root "$home" omz git-fuzzy
check "omz: plugin cloned into custom/plugins" test -f "$oz/custom/plugins/git-fuzzy/test.plugin.zsh"
check "omz: plugins=() extended" contains "$home/.zshrc" "plugins=(git git-fuzzy)"
check "omz: clone used --recurse-submodules" contains "$GIT_ARGLOG" "--recurse-submodules"

# zinit target: zinit light lines in a marked block
rm -f "$home/.zshrc"
azp_apply root "$home" zinit enhancd history-sync
check "zinit: light line written" contains "$home/.zshrc" "zinit light b4b4r07/enhancd"
check "zinit: second light line written" contains "$home/.zshrc" "zinit light vitobotta/zsh-history-sync"
check "zinit: marked block opened" contains "$home/.zshrc" "# >>> systui azp zinit >>>"
check "zinit: marked block closed" contains "$home/.zshrc" "# <<< systui azp zinit <<<"

# plain target: clone into ~/.local/share/zsh-plugins + source lines
rm -f "$home/.zshrc"
azp_apply root "$home" plain zsh-z alias-tips
check "plain: plugin cloned into zsh-plugins" test -f "$home/.local/share/zsh-plugins/zsh-z/test.plugin.zsh"
check "plain: source line for zsh-z" contains "$home/.zshrc" "source ~/.local/share/zsh-plugins/zsh-z/test.plugin.zsh"
check "plain: source line for alias-tips" contains "$home/.zshrc" "source ~/.local/share/zsh-plugins/alias-tips/test.plugin.zsh"
check "plain: marked block present" contains "$home/.zshrc" "# >>> systui azp plugins >>>"

# Re-running must not duplicate the plugins=() additions.
azp_apply root "$home" omz git-fuzzy
check "omz: re-run does not duplicate" test "$(grep -c 'git-fuzzy' "$home/.zshrc")" -eq 1

# ---- summary ----------------------------------------------------------------
printf '\n%d checks, %d failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
