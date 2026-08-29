#!/bin/bash
# Tests for:
#   - the tmux configuration menu (menu_tmux + helpers) in Shells & Plugins
#   - oh-my-zsh plugin-management fixes: preserved custom plugins, loader
#     shims, load-order (syntax highlighting last), p10k clone destination,
#     and omb_set_array insertion before the oh-my-zsh source line.
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Minimal TUI/runtime stubs; defaults make menus exit immediately.
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
show_warnings() { :; }
export SYSTUI_TMP="$(mktemp -d)"
trap 'rm -rf "$SYSTUI_TMP"' EXIT
LOGFILE="$SYSTUI_TMP/test.log"
PM=apt
INIT=systemd
export LOGFILE PM INIT SYSTUI_TMP

# Fake git: clones create the destination with a loadable .plugin.zsh.
fake_bin="$SYSTUI_TMP/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/git" <<'GIT'
#!/bin/sh
if [ "$1" = clone ]; then
    last=
    for a in "$@"; do last="$a"; done
    mkdir -p "$last"
    echo 'echo plugin loaded' > "$last/test.plugin.zsh"
fi
exit 0
GIT
chmod +x "$fake_bin/git"
export PATH="$fake_bin:$PATH"

# Shadow real su so `su - <u> -c "<cmd>"` runs in the test shell with the
# fake git on PATH (a real su login shell would reset PATH and hit the network).
# HOME is set to the fake home by the tests that need `~` expansion.
su() {
    local cmd="" a
    while [ "$#" -gt 0 ]; do
        a="$1"; shift
        if [ "$a" = "-c" ] && [ "$#" -gt 0 ]; then cmd="$1"; break; fi
    done
    [ -n "$cmd" ] && bash -c "$cmd"
}

# Ownership changes are outside this suite's scope. The production menu runs
# as root, while this hermetic test intentionally runs without privileges.
chown() { :; }

# shellcheck source=../src/features/sysconfig.sh
source "$PROJECT_DIR/src/features/sysconfig.sh"

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

home="$SYSTUI_TMP/home"; mkdir -p "$home"
conf="$home/.tmux.conf"

# ---- 1. tmux menu wiring ----------------------------------------------------

check "tmux manager menu exists" function_exists menu_tmux
check "tmux options menu exists" function_exists menu_tmux_options
check "tmux theme menu exists" function_exists menu_tmux_theme
check "tmux prefix menu exists" function_exists menu_tmux_prefix
check "tmux option reader exists" function_exists tmux_opt_get
check "shells menu offers tmux entry" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" 'tmux "tmux — configuration & plugin management"'
check "shells menu dispatches menu_tmux" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" 'menu_tmux "$_tu" "$_th"'
check "shell hierarchy dispatches menu_tmux" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" 'tmux) menu_tmux "$u" "$home_dir"'
check "TPM menu offers custom plugin" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" 'custom "Add a custom plugin (git URL)"'
check "TPM menu offers plugin update" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" 'update "Update all installed plugins"'

# ---- 2. tmux_opt_get --------------------------------------------------------

printf 'set -g mouse on\nset -g default-terminal "tmux-256color"\nset -g prefix C-a\n' > "$conf"
check "tmux_opt_get reads a value" test "$(tmux_opt_get "$conf" mouse)" = on
check "tmux_opt_get strips quotes" test "$(tmux_opt_get "$conf" default-terminal)" = tmux-256color
check "tmux_opt_get reads prefix" test "$(tmux_opt_get "$conf" prefix)" = C-a
check "tmux_opt_get empty for unset" test -z "$(tmux_opt_get "$conf" renumber-windows)"

# ---- 3. menu_tmux_options / theme / prefix ----------------------------------

rm -f "$conf"
tui_check() { printf 'mouse vi status\n'; }
menu_tmux_options root "$home" "$conf"
check "options: mouse written" contains "$conf" 'set -g mouse on'
check "options: vi written" contains "$conf" 'set -g mode-keys vi'
check "options: managed block present" contains "$conf" '# >>> systui tmux options >>>'
check "options: unselected option not written" not_contains "$conf" 'default-terminal'

rm -f "$conf"
tui_radio() { printf 'dark\n'; }
menu_tmux_theme root "$home" "$conf"
check "theme: dark status-style written" contains "$conf" "set -g status-style 'bg=colour234,fg=colour245'"
check "theme: managed block present" contains "$conf" '# >>> systui tmux theme >>>'

rm -f "$conf"
tui_radio() { printf 'C-a\n'; }
menu_tmux_prefix root "$home" "$conf"
check "prefix: set -g prefix C-a" contains "$conf" 'set -g prefix C-a'
check "prefix: send-prefix binding" contains "$conf" 'bind C-a send-prefix'
check "prefix: old C-b unbound" contains "$conf" 'unbind C-b'

# ---- 4. oh-my-zsh fixes -----------------------------------------------------

check "p10k clone target uses resolved path" contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" 'powerlevel10k ${ZSH_CUSTOM:-$home_dir/.oh-my-zsh/custom}/themes/powerlevel10k'
check "p10k no longer embeds a literal backslash-dollar" not_contains \
    "$PROJECT_DIR/src/features/sysconfig.sh" 'powerlevel10k \\\${ZSH_CUSTOM'

# Catalogue load order: fzf-tab before autosuggestions, highlighting last.
check "catalogue: fzf-tab before autosuggestions before highlighting" bash -c '
    source "$1"
    f=$(printf "%s\n" "$OMZ_EXTERNAL_PLUGINS" | grep -n "^fzf-tab|" | cut -d: -f1)
    a=$(printf "%s\n" "$OMZ_EXTERNAL_PLUGINS" | grep -n "^zsh-autosuggestions|" | cut -d: -f1)
    s=$(printf "%s\n" "$OMZ_EXTERNAL_PLUGINS" | grep -n "^zsh-syntax-highlighting|" | cut -d: -f1)
    [ "$f" -lt "$a" ] && [ "$a" -lt "$s" ]' _ "$PROJECT_DIR/src/features/sysconfig.sh"

# omb_set_array inserts before the oh-my-zsh source line when plugins=() is
# missing (previously only matched oh-my-bash, silently doing nothing).
omb_rc="$SYSTUI_TMP/omb-zshrc"
printf 'export ZSH=$HOME/.oh-my-zsh\nsource $ZSH/oh-my-zsh.sh\n' > "$omb_rc"
omb_set_array "$omb_rc" plugins git zsh-autosuggestions
check "omb_set_array inserts before OMZ source" bash -c '
    n=$(grep -n "plugins=(git zsh-autosuggestions)" "$1" | cut -d: -f1)
    m=$(grep -n "source \$ZSH/oh-my-zsh.sh" "$1" | cut -d: -f1)
    [ -n "$n" ] && [ -n "$m" ] && [ "$n" -lt "$m" ]' _ "$omb_rc"

# ---- 5. menu_omz plugins end-to-end: keep custom plugins + shim + order -----

oz="$home/.oh-my-zsh"; mkdir -p "$oz/custom/plugins"
printf 'export ZSH=%s\nplugins=(git my-custom)\nsource $ZSH/oh-my-zsh.sh\n' "$oz" > "$home/.zshrc"

# Drive the menu: first selection "plugins", then "back" to exit the loop.
# The `~` in the clone commands must expand to the fake home.
tui_menu() {
    if [ -f "$SYSTUI_TMP/menu-once" ]; then rm -f "$SYSTUI_TMP/menu-once"; printf 'back\n'; else : > "$SYSTUI_TMP/menu-once"; printf 'plugins\n'; fi
}
# Select builtin git + external zsh-autosuggestions + zsh-syntax-highlighting
# + zsh-auto-notify (whose real repo ships a differently-named loader).
tui_check() { printf 'git zsh-autosuggestions zsh-syntax-highlighting zsh-auto-notify\n'; }
HOME="$home" menu_omz root "$home"

check "omz: custom plugin preserved in plugins=()" contains "$home/.zshrc" "plugins=(my-custom git zsh-autosuggestions zsh-auto-notify zsh-syntax-highlighting)"
check "omz: syntax highlighting is last" bash -c '
    line=$(grep -E "^plugins=\(" "$1")
    [[ "$line" == *"zsh-syntax-highlighting)" ]]' _ "$home/.zshrc"
check "omz: external plugins cloned" test -d "$oz/custom/plugins/zsh-auto-notify"
check "omz: loader shim created for zsh-auto-notify" test -f "$oz/custom/plugins/zsh-auto-notify/zsh-auto-notify.plugin.zsh"
check "omz: shim sources the real loader" contains "$oz/custom/plugins/zsh-auto-notify/zsh-auto-notify.plugin.zsh" 'source "${0:A:h}/test.plugin.zsh"'

# ---- summary ----------------------------------------------------------------
printf '\n%d checks, %d failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
