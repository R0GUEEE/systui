#!/bin/bash
# All-shell configuration and plugin management.
#
# Before this module the shell managers stopped at bash/zsh/fish: config-file
# management knew ten files, validation knew four dialects, plugin integration
# wrote POSIX source lines into every shell (a syntax error in tcsh, nushell,
# xonsh and PowerShell) and aliases existed only as POSIX + Fish.
#
# These tests pin the all-shell behaviour: the registry, file resolution,
# per-dialect validation, per-dialect managed settings blocks, the plugin
# integration table and the alias dialects.
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$PROJECT_DIR/src/features/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-shellconfig-all-shells.sh"

# Minimal TUI/runtime stubs; the module only needs the names at source time.
tui_msg() { :; }
tui_yesno() { return 0; }
tui_input() { printf '%s\n' "${3:-}"; }
tui_menu() { return 1; }
tui_radio() { return 1; }
tui_check() { return 1; }
tui_text() { :; }
log() { :; }
warn() { :; }
note() { :; }
run_cmd() { shift; "$@"; }
safe_edit() { :; }
fm_as_user() { return 0; }
pm_install() { return 0; }
SYSTUI_TMP="$(mktemp -d)"
export SYSTUI_TMP
LOGFILE="$SYSTUI_TMP/test.log"
PM=apt
INIT=systemd
export LOGFILE PM INIT SYSTUI_TMP
TMP_HOME="$SYSTUI_TMP/home"
mkdir -p "$TMP_HOME"
trap 'rm -rf "$SYSTUI_TMP"' EXIT

. "$PROJECT_DIR/src/core/alias.sh"
# shellcheck source=../src/features/sysconfig.sh
. "$PROJECT_DIR/src/features/sysconfig.sh"
# shellcheck source=/dev/null
. "$MODULE"

pass=0
fail=0
check() {
    local desc="$1"; shift
    if "$@"; then printf 'ok: %s\n' "$desc"; pass=$((pass + 1))
    else printf 'not ok: %s\n' "$desc" >&2; fail=$((fail + 1)); fi
}
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
not_contains() { case "$1" in *"$2"*) return 1 ;; *) return 0 ;; esac; }

# --- registry ---------------------------------------------------------------
all_shell_ids=" $(systui_shell_ids | tr '\n' ' ') "
for id in bash zsh fish nu posix ksh tcsh elvish xonsh pwsh; do
    check "registry lists $id" contains "$all_shell_ids" " $id "
done
check "every shell has a label, binary, rc kind, kinds and validator" bash -c '
    . "$1"; . "$2"
    rc=0
    for id in $(systui_shell_ids); do
        [ -n "$(systui_shell_label "$id")" ] || { echo "no label: $id"; rc=1; }
        [ -n "$(systui_shell_bin "$id")" ] || { echo "no binary: $id"; rc=1; }
        [ -n "$(systui_shell_rc_kind "$id")" ] || { echo "no rc kind: $id"; rc=1; }
        [ -n "$(systui_shell_kinds "$id")" ] || { echo "no kinds: $id"; rc=1; }
        [ -n "$(systui_shell_validator "$id")" ] || { echo "no validator: $id"; rc=1; }
    done
    exit $rc' _ "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "the registry has no duplicate ids" bash -c '
    . "$1"; . "$2"
    [ "$(systui_shell_ids | sort -u | wc -l)" = "$(systui_shell_ids | wc -l)" ]' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE"

# --- config file resolution -------------------------------------------------
check "every kind of every shell resolves to an absolute path" bash -c '
    . "$1"; . "$2"
    id=""; rc=0
    for id in $(systui_shell_ids); do
        while IFS="|" read -r kind path; do
            [ -n "$kind" ] || continue
            case "$path" in "$3"/*) : ;; *) echo "bad path for $id/$kind: $path"; rc=1 ;; esac
        done <<< "$(shellcfg_files_for "$id" "$3")"
    done
    exit $rc' _ "$PROJECT_DIR/src/core/alias.sh" "$MODULE" "$TMP_HOME"
for kind in kshrc mkshrc tcshrc cshrc csh_login elvishrc xonshrc psprofile psprofile_host zshenv zlogin fish_confd bash_login; do
    check "shellcfg_file_for knows $kind" bash -c '
        . "$1"; . "$2"
        p=$(shellcfg_file_for "$3" "$4")
        [ -n "$p" ] && case "$p" in /*) exit 0 ;; esac
        echo "unresolved kind: $3"; exit 1' _ \
        "$PROJECT_DIR/src/core/alias.sh" "$MODULE" "$kind" "$TMP_HOME"
done
check "reverse lookup: kinds map back to their shell" bash -c '
    . "$1"; . "$2"
    for pair in kshrc:ksh tcshrc:tcsh elvishrc:elvish xonshrc:xonsh psprofile:pwsh nuconfig:nu fish:fish zshenv:zsh; do
        kind=${pair%%:*}; want=${pair#*:}
        got=$(systui_shell_of_kind "$kind")
        [ "$got" = "$want" ] || { echo "$kind -> $got (want $want)"; exit 1; }
    done' _ "$PROJECT_DIR/src/core/alias.sh" "$MODULE"

# --- plugin integration -----------------------------------------------------
check "POSIX-family shells load plugins with dot-sourcing" bash -c '
    . "$1"; . "$2"
    for sh in bash zsh posix ksh; do
        [ "$(plugin_source_line "$sh" /tmp/x)" = ". \"/tmp/x\"" ] || exit 1
    done' _ "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "fish, tcsh, nushell, elvish and xonsh use their own source syntax" bash -c '
    . "$1"; . "$2"
    for sh in fish tcsh nu elvish xonsh; do
        [ "$(plugin_source_line "$sh" /tmp/x)" = "source \"/tmp/x\"" ] || exit 1
    done' _ "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "PowerShell dot-sources its profile fragments" bash -c '
    . "$1"; . "$2"; [ "$(plugin_source_line pwsh /tmp/x.ps1)" = ". \"/tmp/x.ps1\"" ]' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "plugin_rc_file resolves for every shell" bash -c '
    . "$1"; . "$2"
    for id in $(systui_shell_ids); do
        rc=$(plugin_rc_file "$id" "$3")
        case "$rc" in "$3"/*) : ;; *) echo "$id -> $rc"; exit 1 ;; esac
    done' _ "$PROJECT_DIR/src/core/alias.sh" "$MODULE" "$TMP_HOME"
check "plugin_choose_shells offers every shell" bash -c '
    . "$1"; . "$2"
    out=" $(tui_check() { printf "%s\n" "$@"; }; plugin_choose_shells | tr "\n" " ") "
    for id in $(systui_shell_ids); do
        case "$out" in *" $id "*) : ;; *) echo "missing from chooser: $id"; exit 1 ;; esac
    done' _ "$PROJECT_DIR/src/core/alias.sh" "$MODULE"

# --- cross-shell tool integration table ------------------------------------
check "the init table covers every tool for several shells" bash -c '
    . "$1"; . "$2"
    for tool in starship zoxide atuin direnv carapace fzf; do
        n=$(systui_plugin_init_table | awk -F"|" -v t="$tool" "\$1==t" | wc -l)
        [ "$n" -ge 3 ] || { echo "$tool has only $n entries"; exit 1; }
        [ -n "$(plugin_init_tool_label "$tool")" ] || exit 1
    done' _ "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "starship has init lines for the exotic shells" bash -c '
    . "$1"; . "$2"
    for sh in bash zsh fish tcsh nu elvish xonsh pwsh; do
        [ -n "$(plugin_init_line starship "$sh")" ] || { echo "no starship line for $sh"; exit 1; }
    done' _ "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "POSIX sh is honestly reported as unsupported for starship" bash -c '
    . "$1"; . "$2"; [ -z "$(plugin_init_line starship posix)" ]' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "zoxide does have a POSIX integration" bash -c '
    . "$1"; . "$2"; contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
    contains "$(plugin_init_line zoxide posix)" "zoxide init posix"' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE"

# --- per-dialect managed settings blocks -----------------------------------
emit() { # <kind> <family>
    shellcfg_emit_settings "$1" "$2" "history editor pager color completion autocd glob vi" "nano" "less" "10000"
}
block_tcsh="$(emit tcshrc tcsh)"
block_elv="$(emit elvishrc elvish)"
block_xon="$(emit xonshrc python)"
block_ps="$(emit psprofile pwsh)"
block_ksh="$(emit kshrc ksh)"
block_posix="$(emit profile posix)"
block_bash="$(emit bash bash)"
block_zsh="$(emit zsh zsh)"
block_fish="$(emit fish fish)"
block_nu="$(emit nuconfig nu)"
block_irc="$(emit inputrc inputrc)"

check "tcsh gets set/setenv, never export" bash -c '
    block="$1"
    case "$block" in *"set history = 10000"*) : ;; *) echo "no history"; exit 1 ;; esac
    case "$block" in *"setenv EDITOR nano"*) : ;; *) echo "no setenv EDITOR"; exit 1 ;; esac
    case "$block" in *"set autolist"*) : ;; *) echo "no completion"; exit 1 ;; esac
    case "$block" in *"bindkey -v"*) : ;; *) echo "no vi mode"; exit 1 ;; esac
    case "$block" in *"export "*) echo "bash-ism in tcsh block"; exit 1 ;; esac' _ "$block_tcsh"
check "elvish gets set E: variables" bash -c '
    block="$1"
    case "$block" in *"set E:EDITOR = nano"*) : ;; *) exit 1 ;; esac
    case "$block" in *"set edit:history:max-entries = 10000"*) : ;; *) exit 1 ;; esac' _ "$block_elv"
check "xonsh gets Python assignments" bash -c '
    block="$1"
    case "$block" in *"\$EDITOR = \"nano\""*) : ;; *) exit 1 ;; esac
    case "$block" in *"\$XONSH_VI_MODE = True"*) : ;; *) exit 1 ;; esac
    case "$block" in *"export "*) exit 1 ;; esac' _ "$block_xon"
check "PowerShell gets \$env: and PSReadLine" bash -c '
    block="$1"
    case "$block" in *"\$env:EDITOR = \"nano\""*) : ;; *) exit 1 ;; esac
    case "$block" in *"Set-PSReadLineOption -EditMode Vi"*) : ;; *) exit 1 ;; esac
    case "$block" in *"\$MaximumHistoryCount = 10000"*) : ;; *) exit 1 ;; esac' _ "$block_ps"
check "ksh gets HISTSIZE and set -o, no bash shopt" bash -c '
    block="$1"
    case "$block" in *"HISTSIZE=10000"*) : ;; *) exit 1 ;; esac
    case "$block" in *"set -o vi"*) : ;; *) exit 1 ;; esac
    case "$block" in *"shopt"*) echo "bash-ism in ksh block"; exit 1 ;; esac' _ "$block_ksh"
check "POSIX .profile gets portable exports only" bash -c '
    block="$1"
    case "$block" in *"EDITOR=nano; export EDITOR"*) : ;; *) exit 1 ;; esac
    case "$block" in *"set -o vi"*) : ;; *) exit 1 ;; esac
    case "$block" in *"shopt"*) echo "bash-ism in POSIX block"; exit 1 ;; esac
    case "$block" in *"HISTSIZE"*) echo "dash has no HISTSIZE"; exit 1 ;; esac' _ "$block_posix"
check "bash keeps its shopt-based block" bash -c '
    case "$1" in *"shopt -s histappend"*) : ;; *) exit 1 ;; esac
    case "$1" in *"export EDITOR=nano"*) : ;; *) exit 1 ;; esac' _ "$block_bash"
check "zsh keeps setopt/bindkey" bash -c '
    case "$1" in *"setopt APPEND_HISTORY"*) : ;; *) exit 1 ;; esac
    case "$1" in *"bindkey -v"*) : ;; *) exit 1 ;; esac' _ "$block_zsh"
check "fish keeps set -gx" bash -c '
    case "$1" in *"set -gx EDITOR nano"*) : ;; *) exit 1 ;; esac
    case "$1" in *"fish_vi_key_bindings"*) : ;; *) exit 1 ;; esac' _ "$block_fish"
check "nushell keeps its config assignments" bash -c '
    case "$1" in *"\$env.config.buffer_editor"*) : ;; *) exit 1 ;; esac' _ "$block_nu"
check "inputrc keeps readline syntax" bash -c '
    case "$1" in *"set completion-ignore-case on"*) : ;; *) exit 1 ;; esac' _ "$block_irc"

check "the managed block is added once and preserves existing content" bash -c '
    . "$1"; . "$2"
    f="$3/tcshrc-test"
    printf "set prompt = \"%%m> \"\n" > "$f"
    shellcfg_write_managed tcshrc "$f" "$(id -un)" "history editor" nano less 10000
    shellcfg_write_managed tcshrc "$f" "$(id -un)" "history editor" nano less 10000
    body=$(<"$f")
    case "$body" in *"set prompt"*) : ;; *) echo "original content lost"; exit 1 ;; esac
    open=0; close=0
    while IFS= read -r line; do
        case "$line" in *"systui shell settings >>>"*) open=$((open + 1)) ;; esac
        case "$line" in *"systui shell settings <<<"*) close=$((close + 1)) ;; esac
    done < "$f"
    [ "$open" = 1 ] || { echo "block duplicated ($open)"; exit 1; }
    [ "$close" = 1 ] || { echo "end marker duplicated ($close)"; exit 1; }' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE" "$SYSTUI_TMP"

check "validation uses the owning shell's parser" bash -c '
    . "$1"; . "$2"
    body=$(declare -f shellcfg_validate _shellcfg_validate_pwsh _shellcfg_validate_via)
    for want in "bash -n" "sh -n" "ksh -n" "zsh -n" "fish -n" "tcsh -n" "ParseFile" "_shellcfg_validate_via"; do
        case "$body" in *"$want"*) : ;; *) echo "validator missing: $want"; exit 1 ;; esac
    done' _ "$PROJECT_DIR/src/core/alias.sh" "$MODULE"

# --- alias dialects ---------------------------------------------------------
cat > "$SYSTUI_TMP/aliases.sh" <<'EOF'
alias ll='ls -alF'
alias ..='cd ..'
alias gs='git status'
EOF
mkdir -p "$TMP_HOME"
user_home() { printf '%s\n' "$TMP_HOME"; }
aliases_write_dialects "$SYSTUI_TMP/aliases.sh" "$(id -un)"
d="$TMP_HOME/.config/systui"
check "tcsh alias dialect uses double quotes" bash -c '
    case "$(cat "$1/aliases.tcsh")" in *"alias ll \"ls -alF\""*) : ;; *) exit 1 ;; esac' _ "$d"
check "nushell alias dialect uses =" bash -c '
    case "$(cat "$1/aliases.nu")" in *"alias ll = ls -alF"*) : ;; *) exit 1 ;; esac' _ "$d"
check "xonsh alias dialect uses aliases[...]" bash -c '
    case "$(cat "$1/aliases.xsh")" in *"aliases['"'"'ll'"'"'] = '"'"'ls -alF'"'"'"*) : ;; *) exit 1 ;; esac' _ "$d"
check "elvish alias dialect declares a fn with e: prefix" bash -c '
    case "$(cat "$1/aliases.elv")" in *"fn ll {|@a| e:ls -alF \$@a }"*) : ;; *) exit 1 ;; esac' _ "$d"
check "PowerShell alias dialect declares a function" bash -c '
    case "$(cat "$1/aliases.ps1")" in *"function ll { ls -alF @args }"*) : ;; *) exit 1 ;; esac' _ "$d"
check "every dialect file is generated" bash -c '
    for f in aliases.tcsh aliases.nu aliases.xsh aliases.elv aliases.ps1; do
        [ -s "$1/$f" ] || { echo "missing $f"; exit 1; }
    done' _ "$d"
check "aliases_enable maps every shell to its own dialect file" bash -c '
    . "$1"; . "$2"
    body=$(declare -f aliases_enable)
    for want in aliases.fish aliases.tcsh aliases.nu aliases.xsh aliases.elv aliases.ps1; do
        case "$body" in *"$want"*) : ;; *) echo "aliases_enable does not wire $want"; exit 1 ;; esac
    done
    # and it must only touch shells that are actually installed
    case "$body" in *"systui_shell_installed"*) : ;; *) echo "no installed-shell guard"; exit 1 ;; esac' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE"

# --- plugin entry-file detection -------------------------------------------
for pair in "bash plug.sh" "elvish plug.elv" "xonsh plug.xsh" "pwsh plug.ps1" "nu plug.nu"; do
    sh="${pair%% *}"; fn="${pair#* }"
    dir="$SYSTUI_TMP/entry-$sh"; mkdir -p "$dir"; : > "$dir/$fn"
    check "entry-file detection for $sh" bash -c '
        . "$1"; . "$2"
        [ "$(systui_plugin_entry_file "$3" "$4")" = "$5" ]' _ \
        "$PROJECT_DIR/src/core/alias.sh" "$MODULE" "$sh" "$dir" "$fn"
done
check "an unrecognised layout yields a comment, not a broken source line" bash -c '
    . "$1"; . "$2"
    mkdir -p "$3/entry-none"
    line=$(systui_plugin_entry_line nu "$3/entry-none")
    case "$line" in \#*) exit 0 ;; *) echo "unexpected line: $line"; exit 1 ;; esac' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE" "$SYSTUI_TMP"

# --- menu wiring ------------------------------------------------------------
check "the plugins menu exposes the all-shell actions" bash -c '
    . "$1"; . "$2"
    body=$(declare -f menu_shell_plugins)
    for want in allshells custom menu_plugin_all_shells menu_plugin_custom_source; do
        case "$body" in *"$want"*) : ;; *) echo "missing: $want"; exit 1 ;; esac
    done' _ "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "the shell-config menu offers another file and another shell" bash -c '
    . "$1"; . "$2"
    body=$(declare -f menu_shell_config)
    case "$body" in *"Select another config file"*) : ;; *) exit 1 ;; esac
    case "$body" in *"shellcfg_choose_shell "*) : ;; *) exit 1 ;; esac' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "the module is registered in the load manifest" bash -c '
    want=$(basename "$1"); found=0
    while IFS= read -r line; do
        [ "$line" = "$want" ] && found=1
    done < "$2"
    [ "$found" = 1 ] || { echo "not in manifest: $want"; exit 1; }' _ "$MODULE" "$PROJECT_DIR/src/features/.load-order"
check "the ARG_MAX cleanup still loads last" bash -c '
    last=""
    while IFS= read -r line; do
        case "$line" in ""|"#"*|[[:space:]]*) continue ;; esac
        last="$line"
    done < "$1"
    case "$last" in *argmax-cleanup.sh) exit 0 ;; *) echo "last entry: $last"; exit 1 ;; esac' _ \
    "$PROJECT_DIR/src/features/.load-order"

printf '\nAll-shell config and plugin management: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
