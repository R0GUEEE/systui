#!/bin/bash
# niubash (niu) shell integration.
#
# niubash is a Windows-native, Bash-compatible shell; its rc file is Bash syntax
# and its plugin framework, oh-my-niu / oh-my-winuxsh, is a bundle root. These
# tests pin the parts of that integration that must not drift: the registry
# entry, the rc files, the validator, the alias dialect, the plugin catalogue
# parsers and the managed .niubashrc blocks.
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$PROJECT_DIR/src/features/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-shellconfig-all-shells.sh"

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
mkdir -p "$SYSTUI_TMP/state"
export SYSTUI_NIU_PLUGIN_CACHE="$SYSTUI_TMP/state/niu-cache"
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

# --- registry ---------------------------------------------------------------
check "niu is in the shell registry" contains " $(systui_shell_ids | tr '\n' ' ') " " niu "
check "the registry describes niu" bash -c '
    . "$1"; . "$2"
    [ "$(systui_shell_label niu)" = "Niu (niubash)" ] || { echo "label: $(systui_shell_label niu)"; exit 1; }
    [ "$(systui_shell_bin niu)" = "niu" ]             || { echo "bin: $(systui_shell_bin niu)"; exit 1; }
    [ "$(systui_shell_rc_kind niu)" = "niubashrc" ]   || { echo "rc kind: $(systui_shell_rc_kind niu)"; exit 1; }
    [ "$(systui_shell_validator niu)" = "niu" ]       || { echo "validator"; exit 1; }
    case "$(systui_shell_kinds niu)" in
        *niubashrc*) : ;; *) echo "kinds: $(systui_shell_kinds niu)"; exit 1 ;;
    esac
    [ "$(systui_shell_of_kind niubashrc)" = niu ]     || { echo "reverse lookup"; exit 1; }
    [ "$(systui_shell_for_bin niu)" = niu ]           || { echo "bin lookup"; exit 1; }
    [ "$(systui_shell_entry_bins niu)" = niu ]        || { echo "entry bins"; exit 1; }' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "niu config files resolve to the niubash rc files" bash -c '
    . "$1"; . "$2"
    h="$3"
    [ "$(shellcfg_file_for niubashrc "$h")" = "$h/.niubashrc" ] || exit 1
    [ "$(shellcfg_file_for winshrc "$h")" = "$h/.winshrc" ]     || exit 1
    [ "$(plugin_rc_file niu "$h")" = "$h/.niubashrc" ]          || exit 1' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE" "$TMP_HOME"
check "niubashrc validates in the niu family (Bash syntax)" bash -c '
    . "$1"; . "$2"
    [ "$(_shellcfg_kind_family niubashrc)" = niu ] || exit 1
    [ "$(_shellcfg_kind_family winshrc)" = niu ]   || exit 1' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "niu loads files with the Bash source syntax" bash -c '
    . "$1"; . "$2"
    [ "$(plugin_source_line niu /tmp/x.sh)" = ". \"/tmp/x.sh\"" ] || exit 1' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "the managed settings block uses niubash syntax" bash -c '
    . "$1"; . "$2"
    out=$(shellcfg_emit_settings niubashrc niu " history editor color completion " nano less 5000)
    case "$out" in *"NIU_HISTORY_MODE=shared"*) : ;; *) echo "no NIU_HISTORY_MODE"; exit 1 ;; esac
    case "$out" in *"export EDITOR=nano"*) : ;; *) echo "no EDITOR export"; exit 1 ;; esac
    case "$out" in *"export CLICOLOR=1"*) : ;; *) echo "no color setting"; exit 1 ;; esac
    # a Windows host has no /usr/share/bash-completion
    case "$out" in *bash_completion*) echo "bash-completion path leaked in"; exit 1 ;; esac' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "niu uses the POSIX alias master" bash -c '
    . "$1"; . "$2"
    body=$(declare -f aliases_enable systui_shell_alias_action)
    body=${body// /}
    case "$body" in *"bash|zsh|posix|ksh|niu)"*) : ;; *) echo "niu missing from the alias dialect cases"; exit 1 ;; esac' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "the init table carries the Bash lines for niu" bash -c '
    . "$1"; . "$2"
    for tool in starship zoxide direnv fzf; do
        line=$(plugin_init_line "$tool" niu)
        [ -n "$line" ] || { echo "no niu line for $tool"; exit 1; }
        case "$line" in *bash*) : ;; *) echo "$tool: not the Bash form: $line"; exit 1 ;; esac
    done' _ "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "the install action routes niu to its installer" bash -c '
    . "$1"; . "$2"
    body=$(declare -f systui_shell_install_action)
    case "$body" in *menu_niubash_install*) : ;; *) echo "install action does not reach the niu installer"; exit 1 ;; esac' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "the framework menu offers oh-my-niu" bash -c '
    . "$1"; . "$2"
    body=$(declare -f systui_shell_framework_menu)
    case "$body" in *menu_oh_my_niu*) : ;; *) echo "framework menu does not reach oh-my-niu"; exit 1 ;; esac
    case "$body" in *"oh-my-niu"*) : ;; *) echo "framework menu does not name oh-my-niu"; exit 1 ;; esac' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "the cross-shell GitHub catalogue lists oh-my-niu for niu" bash -c '
    . "$1"; . "$2"; . "$3"
    row=$(shell_github_catalog | grep -F "oh-my-niu|" | head -n1)
    [ -n "$row" ] || { echo "no oh-my-niu row"; exit 1; }
    case "$row" in *"|niu|"*) : ;; *) echo "row is not tagged for niu: $row"; exit 1 ;; esac
    case "$row" in *"unixwin/oh-my-winuxsh"*) : ;; *) echo "row does not name the framework repo"; exit 1 ;; esac' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE" "$PROJECT_DIR/src/features/sysconfig.sh"

# --- plugin entry files -----------------------------------------------------
niu_dir="$SYSTUI_TMP/niu-plugin"
mkdir -p "$niu_dir"
printf 'entry = "git.plugin.niu"\n' > "$niu_dir/plugin.toml"
: > "$niu_dir/git.plugin.niu"
check "a niu plugin is located through its plugin.toml" bash -c '
    . "$1"; . "$2"
    [ "$(systui_plugin_entry_file niu "$3")" = "git.plugin.niu" ] || exit 1' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE" "$niu_dir"
check "a niu plugin is located without plugin.toml too" bash -c '
    . "$1"; . "$2"
    d="$3"
    mkdir -p "$d/loose"
    : > "$d/loose/loose.plugin.niu"
    [ "$(systui_plugin_entry_file niu "$d/loose")" = "loose.plugin.niu" ] || exit 1
    line=$(systui_plugin_entry_line niu "$d/loose")
    case "$line" in *"loose.plugin.niu"*) : ;; *) echo "entry line: $line"; exit 1 ;; esac' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE" "$niu_dir"

# --- catalogue parsers ------------------------------------------------------
cat > "$SYSTUI_TMP/index.toml" <<'EOF'
schema = "niubash:plugin-index@0.1.0"
bundle = "oh-my-niu"

[[packs]]
name = "git"
version = "2.0.0"
kind = "source"
category = "devtools"
summary = "Git aliases, completions, and prompt segments."
default = true
permissions = ["shell:source", "process:run:git"]

[[packs]]
name = "winuxcmd-core"
version = "2.0.0"
kind = "builtin"
category = "devtools"
summary = "Static completions for WinuxCmd core command links."
required_binaries = []
EOF
cat > "$SYSTUI_TMP/tree.json" <<'EOF'
{
  "sha": "abc",
  "tree": [
    {"path": "plugins", "type": "tree"},
    {"path": "plugins/git/plugin.toml", "type": "blob"},
    {"path": "plugins/theme-minimal/plugin.toml", "type": "blob"},
    {"path": "plugins/broken/readme.md", "type": "blob"},
    {"path": "lib/hooks.niu", "type": "blob"}
  ]
}
EOF
printf 'git\ntheme-minimal\nloose-plugin\n' > "$SYSTUI_TMP/names"

check "index.toml packs parse into name|kind|category|summary rows" bash -c '
    . "$1"; . "$2"
    out=$(niu_plugin_packs_tsv "$3")
    n=$(printf "%s\n" "$out" | wc -l | tr -d " ")
    [ "$n" = 2 ] || { echo "expected 2 packs, got $n"; exit 1; }
    case "$out" in *"git|source|devtools|Git aliases"*) : ;; *) echo "git row: $out"; exit 1 ;; esac
    case "$out" in *"winuxcmd-core|builtin|devtools|Static completions"*) : ;; *) echo "winuxcmd row missing"; exit 1 ;; esac' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE" "$SYSTUI_TMP/index.toml"
check "a git tree listing yields the plugin names" bash -c '
    . "$1"; . "$2"
    out=$(niu_plugin_tree_names "$3")
    [ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = 2 ] || { echo "names: $out"; exit 1; }
    case "$out" in *"git"*) : ;; *) echo "git missing"; exit 1 ;; esac
    case "$out" in *"theme-minimal"*) : ;; *) echo "theme missing"; exit 1 ;; esac
    case "$out" in *"lib/"*|*"broken"*) echo "junk kept: $out"; exit 1 ;; esac' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE" "$SYSTUI_TMP/tree.json"
check "the join keeps the index summary and derives the rest" bash -c '
    . "$1"; . "$2"
    niu_plugin_packs_tsv "$3" > "$4/packs"
    out=$(niu_plugin_join "$4/names" "$4/packs")
    case "$out" in *"git|source|devtools|Git aliases"*) : ;; *) echo "git row: $out"; exit 1 ;; esac
    # a theme has no index entry: derived category, no invented summary
    case "$out" in *"theme-minimal|source|themes|"*) : ;; *) echo "theme row: $out"; exit 1 ;; esac
    # an unknown plugin name keeps its own category
    case "$out" in *"loose-plugin|source|plugins|"*) : ;; *) echo "unknown row: $out"; exit 1 ;; esac' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE" "$SYSTUI_TMP/index.toml" "$SYSTUI_TMP"

check "the offline pack list is well-formed and covers the bundle" bash -c '
    . "$1"; . "$2"
    rc=0
    while IFS="|" read -r name kind grp sum; do
        [ -n "$name" ] || continue
        [ -n "$kind" ] || { echo "no kind for $name"; rc=1; }
        [ -n "$grp" ]  || { echo "no category for $name"; rc=1; }
        [ -n "$sum" ]  || { echo "no summary for $name"; rc=1; }
    done <<< "$(niu_plugin_builtin)"
    out=$(niu_plugin_builtin)
    case "$out" in *"git|"*) : ;; *) echo "git missing from the offline list"; rc=1 ;; esac
    case "$out" in *zoxide*) : ;; *) echo "zoxide missing from the offline list"; rc=1 ;; esac
    exit $rc' _ "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "an installed bundle feeds the catalogue when nothing is cached" bash -c '
    . "$1"; . "$2"
    h="$3"
    d="$h/.niubash/oh-my-niu/plugins/dirmarks"
    mkdir -p "$d"
    printf "name = \"dirmarks\"\nkind = \"source\"\nsummary = \"Bookmark directories.\"\n" > "$d/plugin.toml"
    out=$(niu_plugin_catalog "$h")
    case "$out" in *"dirmarks|source|plugins|Bookmark directories."*) : ;; *) echo "bundle rows: $out"; exit 1 ;; esac' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE" "$TMP_HOME"
check "a cached index wins over the bundle fallback" bash -c '
    . "$1"; . "$2"
    h="$3"
    mkdir -p "$SYSTUI_NIU_PLUGIN_CACHE"
    printf "%s\n" "cached-only|source|plugins|From the GitHub index." > "$(niu_plugin_tsv_file)"
    out=$(niu_plugin_catalog "$h")
    case "$out" in *"cached-only|"*) : ;; *) echo "cache not used: $out"; exit 1 ;; esac
    case "$out" in *dirmarks*) echo "bundle leaked into a cached catalogue"; exit 1 ;; esac
    rm -f "$(niu_plugin_tsv_file)"' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE" "$TMP_HOME"

# --- managed .niubashrc blocks ---------------------------------------------
check "the plugin and loader blocks round-trip through .niubashrc" bash -c '
    . "$1"; . "$2"
    h="$3"
    niu_write_plugins "$h" "$(id -un)" "prompt-core git docker" minimal
    niu_write_loader "$h" "$(id -un)" "$h/.niubash/oh-my-niu" >/dev/null
    rc="$h/.niubashrc"
    [ -f "$rc" ] || { echo "no rc file"; exit 1; }
    [ "$(niu_current_plugins "$h")" = "prompt-core git docker" ] || { echo "plugins: $(niu_current_plugins "$h")"; exit 1; }
    [ "$(niu_current_theme "$h")" = minimal ]                   || { echo "theme"; exit 1; }
    case "$(cat "$rc")" in *"NIU_THEME_PLUGIN=theme-minimal"*) : ;; *) echo "no theme plugin"; exit 1 ;; esac
    case "$(cat "$rc")" in *"oh-my-niu.niu"*) : ;; *) echo "no loader line"; exit 1 ;; esac
    case "$(niu_loader_state "$h")" in *"managed block"*) : ;; *) echo "loader state: $(niu_loader_state "$h")"; exit 1 ;; esac
    # a second write replaces the block instead of stacking a new one
    niu_write_plugins "$h" "$(id -un)" "prompt-core" ""
    [ "$(grep -cF ">>> systui niu plugins >>>" "$rc")" = 1 ] || { echo "block duplicated"; exit 1; }
    [ "$(niu_current_plugins "$h")" = prompt-core ]           || { echo "second write: $(niu_current_plugins "$h")"; exit 1; }
    [ -z "$(niu_current_theme "$h")" ]                        || { echo "theme survived an empty theme"; exit 1; }
    # user content around the block is untouched
    printf "alias ll=%s\n" "\x27ls -la\x27" >> "$rc"
    niu_write_plugins "$h" "$(id -un)" "git" ""
    case "$(cat "$rc")" in *"alias ll="*) : ;; *) echo "user line lost"; exit 1 ;; esac' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE" "$TMP_HOME"

check "the niu menus exist and read their own metadata" bash -c '
    . "$1"; . "$2"
    for fn in menu_niubash_install menu_oh_my_niu menu_niu_plugins_select \
              menu_niu_theme_select niu_show_status niu_bundle_install \
              niu_install_release niu_plugin_sync; do
        declare -F "$fn" >/dev/null || { echo "missing function: $fn"; exit 1; }
    done
    body=$(declare -f menu_oh_my_niu)
    for want in "niu_bundle_repo" "menu_niu_plugins_select" "niu_plugin_sync"; do
        case "$body" in *"$want"*) : ;; *) echo "oh-my-niu menu lacks: $want"; exit 1 ;; esac
    done
    body=$(declare -f niu_bundle_install)
    for want in "oh-my-niu-" "sha256" "unzip"; do
        case "$body" in *"$want"*) : ;; *) echo "bundle install lacks: $want"; exit 1 ;; esac
    done' _ "$PROJECT_DIR/src/core/alias.sh" "$MODULE"
check "the niubash repository defaults match the upstream project" bash -c '
    . "$1"; . "$2"
    [ "$(niu_shell_repo)" = unixwin/niubash ]     || exit 1
    [ "$(niu_bundle_repo)" = unixwin/oh-my-winuxsh ] || exit 1
    SYSTUI_NIU_REPO=me/fork
    [ "$(niu_shell_repo)" = me/fork ] || exit 1' _ \
    "$PROJECT_DIR/src/core/alias.sh" "$MODULE"

printf "\nniubash shell integration: %d passed, %d failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
