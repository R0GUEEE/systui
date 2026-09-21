# shellcheck shell=bash
###############################################################################
# ALL-SHELL CONFIG AND PLUGIN MANAGEMENT
#
# The shell managers used to know three interactive shells (bash, zsh, fish)
# plus a handful of nushell files: config-file management, validation, plugin
# integration and aliases all stopped there, even though systui installs and
# manages dash/mksh, ksh, tcsh, elvish, xonsh and PowerShell too.
#
# This module gives every shell systui knows a first-class entry:
#
#   * one registry (systui_shell_registry) describing each shell's config files,
#     its plugin/rc target and its syntax checker, so file resolution,
#     validation and plugin integration cannot drift apart;
#   * config-file management for every file of every shell, validated with that
#     shell's own parser where one exists;
#   * managed settings blocks written in each shell's own syntax (tcsh `setenv`,
#     elvish `set E:...`, xonsh `$VAR`, PowerShell `$env:VAR`), instead of the
#     bash/POSIX lines every shell used to receive;
#   * plugin integration for every shell: the right "load this file" line per
#     shell dialect, a status view across all of them, and a table of init lines
#     for the cross-shell tools (starship, zoxide, atuin, direnv, carapace, fzf)
#     so one action can wire up every installed shell;
#   * alias files generated for each alias dialect (POSIX, fish, tcsh, nushell,
#     xonsh, elvish, PowerShell) and sourced from every shell's rc file.
#
# Loaded last so its definitions win; the originals are kept under private names
# where their behaviour is still wanted.
###############################################################################

# Standalone safety: this module wraps existing functions with
# systui_alias_function, so it must be able to pull the helper in itself when it
# is sourced without core/common.sh (tests, reduced builds).
if ! declare -F systui_alias_function >/dev/null 2>&1; then
    _systui_alias_mod="${SYSTUI_LIBDIR:-$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)}/src/core/alias.sh"
    # shellcheck disable=SC1090
    [ -r "$_systui_alias_mod" ] && . "$_systui_alias_mod"
    unset _systui_alias_mod
fi

# --- registry ---------------------------------------------------------------
# id|label|binary|plugin-rc kind|all config kinds|validator family
#
# The data is a printf rather than a `cat` heredoc and the lookups read a cache
# built once: a menu that asks for a label, binary and kind per shell would
# otherwise fork awk/cut dozens of times per keystroke, which is very visible on
# the emulated hosts this tool targets.
systui_shell_registry() {
    printf '%s\n' \
        'bash|Bash|bash|bash|bash bash_profile bash_login profile bash_logout inputrc|bash' \
        'zsh|Zsh|zsh|zsh|zsh zprofile zshenv zlogin zlogout inputrc|zsh' \
        'fish|Fish|fish|fish|fish fish_confd|fish' \
        'nu|Nushell|nu|nuconfig|nuconfig nuenv nulogin|nu' \
        'posix|POSIX sh (dash, ash, yash)|sh|profile|profile|posix' \
        'ksh|Korn shell (ksh, mksh)|ksh|kshrc|kshrc mkshrc profile|ksh' \
        'tcsh|tcsh / csh|tcsh|tcshrc|tcshrc cshrc csh_login csh_logout|tcsh' \
        'elvish|Elvish|elvish|elvishrc|elvishrc|elvish' \
        'xonsh|Xonsh|xonsh|xonshrc|xonshrc|python' \
        'pwsh|PowerShell|pwsh|psprofile|psprofile psprofile_host|pwsh'
}

declare -A SYSTUI_SHELL_LABEL=() SYSTUI_SHELL_BINARY=() SYSTUI_SHELL_RCKIND=() \
             SYSTUI_SHELL_KINDS=() SYSTUI_SHELL_FAMILY=()
SYSTUI_SHELL_IDS=""
SYSTUI_SHELL_CACHE_LOADED=0

_systui_shell_load() {
    [ "$SYSTUI_SHELL_CACHE_LOADED" = 1 ] && return 0
    local id label bin rckind kinds family
    while IFS='|' read -r id label bin rckind kinds family; do
        [ -n "$id" ] || continue
        SYSTUI_SHELL_IDS="$SYSTUI_SHELL_IDS $id"
        SYSTUI_SHELL_LABEL[$id]="$label"
        SYSTUI_SHELL_BINARY[$id]="$bin"
        SYSTUI_SHELL_RCKIND[$id]="$rckind"
        SYSTUI_SHELL_KINDS[$id]="$kinds"
        SYSTUI_SHELL_FAMILY[$id]="$family"
    done <<< "$(systui_shell_registry)"
    SYSTUI_SHELL_CACHE_LOADED=1
    return 0
}

# The registry order is meaningful (it is the order the menus present), so it is
# kept in a string rather than being recovered by sorting.
systui_shell_ids() { _systui_shell_load; printf '%s\n' ${SYSTUI_SHELL_IDS# }; }

systui_shell_field() { # <id> <field-number> (1 id, 2 label, 3 bin, 4 rc, 5 kinds, 6 family)
    _systui_shell_load
    case "$2" in
        1) [ -n "${SYSTUI_SHELL_LABEL[$1]+x}" ] && printf '%s\n' "$1" ;;
        2) printf '%s\n' "${SYSTUI_SHELL_LABEL[$1]:-}" ;;
        3) printf '%s\n' "${SYSTUI_SHELL_BINARY[$1]:-}" ;;
        4) printf '%s\n' "${SYSTUI_SHELL_RCKIND[$1]:-}" ;;
        5) printf '%s\n' "${SYSTUI_SHELL_KINDS[$1]:-}" ;;
        6) printf '%s\n' "${SYSTUI_SHELL_FAMILY[$1]:-}" ;;
    esac
}

systui_shell_label() { # <id>
    local v
    v=$(systui_shell_field "$1" 2)
    [ -n "$v" ] || v="$1"
    printf '%s\n' "$v"
}

systui_shell_bin() { # <id> -> the command that proves the shell is installed
    local v
    v=$(systui_shell_field "$1" 3)
    [ -n "$v" ] || v="$1"
    printf '%s\n' "$v"
}

systui_shell_rc_kind() { # <id> -> kind of the file plugins are integrated into
    systui_shell_field "$1" 4
}

systui_shell_kinds() { # <id> -> every config kind belonging to that shell
    systui_shell_field "$1" 5
}

systui_shell_validator() { # <id> -> validator family
    systui_shell_field "$1" 6
}

systui_shell_of_kind() { # <kind> -> shell id (empty when unknown)
    _systui_shell_load
    local id kind
    for id in $(systui_shell_ids); do
        for kind in ${SYSTUI_SHELL_KINDS[$id]}; do
            [ "$kind" = "$1" ] && { printf '%s\n' "$id"; return 0; }
        done
    done
    return 1
}

systui_shell_installed() { # <id>
    local bin
    bin=$(systui_shell_bin "$1")
    command -v "$bin" >/dev/null 2>&1
}

systui_shells_installed() { # every shell whose binary is present, in registry order
    _systui_shell_load
    local id
    for id in $(systui_shell_ids); do
        command -v "${SYSTUI_SHELL_BINARY[$id]}" >/dev/null 2>&1 && printf '%s\n' "$id"
    done
}

# shell_rc_for <shell> <home>: the file a plugin/alias integration belongs in.
# Kept as a thin wrapper so existing callers keep working.
shell_rc_for() {
    local id="$1" home="$2" kind
    kind=$(systui_shell_rc_kind "$id")
    [ -n "$kind" ] || kind="$id"
    shellcfg_file_for "$kind" "$home"
}

# --- source (plugin/alias) line syntax --------------------------------------
# plugin_source_line <shell> <absolute-path>
# Every shell loads another file in its own dialect; a POSIX `. file` line is a
# syntax error in tcsh, nushell, xonsh and PowerShell, which is why plugin
# integration used to stop at bash/zsh/fish.
plugin_source_line() { # <shell> <path>
    case "$1" in
        bash|zsh|posix|ksh) printf '. "%s"\n' "$2" ;;
        fish|tcsh|nu|elvish|xonsh) printf 'source "%s"\n' "$2" ;;
        pwsh) printf '. "%s"\n' "$2" ;;
        *) printf '. "%s"\n' "$2" ;;
    esac
}

# plugin_detect_line <shell> <command-or-name>: the "is this loaded" probe used
# by the status view, in each shell's syntax.
plugin_detect_line() { # <shell> <name>
    case "$1" in
        fish)   [ -n "$2" ] && printf 'type -q %s\n' "$2" ;;
        tcsh)   [ -n "$2" ] && printf 'which %s\n' "$2" ;;
        xonsh)  [ -n "$2" ] && printf 'which("%s")\n' "$2" ;;
        pwsh)   [ -n "$2" ] && printf 'Get-Command %s\n' "$2" ;;
        nu)     [ -n "$2" ] && printf 'which %s\n' "$2" ;;
        *)      [ -n "$2" ] && printf 'command -v %s\n' "$2" ;;
    esac
}

# --- config files -----------------------------------------------------------
# shellcfg_file_for <kind> <home> -- every shell kind, not just the original ten.
shellcfg_file_for() {
    case "$1" in
        bash)           printf '%s/.bashrc\n' "$2" ;;
        bash_profile)   printf '%s/.bash_profile\n' "$2" ;;
        bash_login)     printf '%s/.bash_login\n' "$2" ;;
        bash_logout)    printf '%s/.bash_logout\n' "$2" ;;
        zsh)            printf '%s/.zshrc\n' "$2" ;;
        zprofile)       printf '%s/.zprofile\n' "$2" ;;
        zshenv)         printf '%s/.zshenv\n' "$2" ;;
        zlogin)         printf '%s/.zlogin\n' "$2" ;;
        zlogout)        printf '%s/.zlogout\n' "$2" ;;
        fish)           printf '%s/.config/fish/config.fish\n' "$2" ;;
        fish_confd)     printf '%s/.config/fish/conf.d/systui.fish\n' "$2" ;;
        nuconfig)       printf '%s/.config/nushell/config.nu\n' "$2" ;;
        nuenv)          printf '%s/.config/nushell/env.nu\n' "$2" ;;
        nulogin)        printf '%s/.config/nushell/login.nu\n' "$2" ;;
        profile)        printf '%s/.profile\n' "$2" ;;
        kshrc)          printf '%s/.kshrc\n' "$2" ;;
        mkshrc)         printf '%s/.mkshrc\n' "$2" ;;
        tcshrc)         printf '%s/.tcshrc\n' "$2" ;;
        cshrc)          printf '%s/.cshrc\n' "$2" ;;
        csh_login)      printf '%s/.login\n' "$2" ;;
        csh_logout)     printf '%s/.logout\n' "$2" ;;
        elvishrc)       printf '%s/.config/elvish/rc.elv\n' "$2" ;;
        xonshrc)        printf '%s/.config/xonsh/rc.xsh\n' "$2" ;;
        psprofile)      printf '%s/.config/powershell/profile.ps1\n' "$2" ;;
        psprofile_host) printf '%s/.config/powershell/Microsoft.PowerShell_profile.ps1\n' "$2" ;;
        inputrc)        printf '%s/.inputrc\n' "$2" ;;
    esac
}

# shellcfg_files_for <shell> <home>: kind<TAB>path for every file of one shell.
shellcfg_files_for() {
    local id="$1" home="$2" kind
    for kind in $(systui_shell_kinds "$id"); do
        [ "$kind" = inputrc ] && continue
        printf '%s|%s\n' "$kind" "$(shellcfg_file_for "$kind" "$home")"
    done
}

# _shellcfg_kind_family <kind> -> validator family of the owning shell.
_shellcfg_kind_family() {
    local id
    id=$(systui_shell_of_kind "$1" 2>/dev/null || true)
    [ -n "$id" ] || { printf '%s\n' "$1"; return 0; }
    systui_shell_validator "$id"
}

# --- validation -------------------------------------------------------------
# shellcfg_validate <kind> <file>: always use the parser of the shell that will
# actually read the file.
shellcfg_validate() {
    local k="$1" f="$2" out rc=0 family
    [ -f "$f" ] || { tui_msg "Validation" "$f does not exist."; return 0; }
    out=$(mktemp)
    if [ "$k" = inputrc ]; then
        printf 'Readline files do not provide a standalone syntax checker.\n' > "$out"
    else
        family=$(_shellcfg_kind_family "$k")
        case "$family" in
            bash)  bash -n "$f" >"$out" 2>&1 || rc=$? ;;
            posix) sh -n "$f" >"$out" 2>&1 || rc=$? ;;
            ksh)   _shellcfg_validate_via ksh "$f" "$out" ksh -n || rc=$? ;;
            zsh)   _shellcfg_validate_via zsh "$f" "$out" zsh -n || rc=$? ;;
            fish)  _shellcfg_validate_via fish "$f" "$out" fish -n || rc=$? ;;
            tcsh)  _shellcfg_validate_via tcsh "$f" "$out" tcsh -n || rc=$? ;;
            nu)    _shellcfg_validate_via nu "$f" "$out" nu -n -c "source $(nu_quote "$f")" || rc=$? ;;
            pwsh)  _shellcfg_validate_pwsh "$f" "$out" || rc=$? ;;
            elvish)
                printf 'Elvish has no standalone syntax checker; review %s with elvish -i or by hand.\n' "$f" > "$out" ;;
            python)
                printf 'Xonsh rc files are Python-like but not valid Python; no standalone syntax checker is available.\n' > "$out" ;;
            *)     printf 'No syntax checker is known for %s.\n' "$k" > "$out" ;;
        esac
    fi
    if [ "$rc" -eq 0 ]; then tui_msg "Validation passed" "$f contains no detected syntax errors."
    else tui_text "Validation result — $f" "$out"; fi
    rm -f "$out"
}

# _shellcfg_validate_via <binary> <file> <outfile> <cmd...>: run the check when
# the shell is installed, otherwise leave a note (never a false failure).
_shellcfg_validate_via() {
    local bin="$1" f="$2" out="$3"; shift 3
    if command -v "$bin" >/dev/null 2>&1; then
        "$@" >"$out" 2>&1 || return $?
        return 0
    fi
    printf '%s is not installed; syntax check unavailable.\n' "$bin" > "$out"
    return 2
}

# _shellcfg_validate_pwsh <file> <outfile>: PowerShell parses its own files, so
# the AST parser gives a real syntax check instead of a "cannot validate" note.
_shellcfg_validate_pwsh() { # <file> <outfile>
    local f="$1" out="$2" script
    if ! command -v pwsh >/dev/null 2>&1; then
        printf 'pwsh is not installed; syntax check unavailable.\n' > "$out"
        return 2
    fi
    script='$errors = $null; [void][System.Management.Automation.Language.Parser]::ParseFile('"'"'__FILE__'"'"', [ref]$null, [ref]$errors); if ($errors) { $errors | ForEach-Object { $_.Message }; exit 1 }'
    script=${script//__FILE__/$1}
    pwsh -NoProfile -NonInteractive -Command "$script" >"$out" 2>&1
}

# --- choosers ---------------------------------------------------------------
# Two levels (shell, then file) instead of the previous flat list of ten files:
# every shell now contributes its own files, and the shell is named explicitly so
# a user with five shells installed can tell .profile from .kshrc apart.
shellcfg_choose_shell() { # <home> -> shell id
    local home="$1" id label state args=()
    for id in $(systui_shell_ids); do
        label=$(systui_shell_label "$id")
        if systui_shell_installed "$id"; then state="installed"; else state="not installed"; fi
        args+=("$id" "$label — $(systui_shell_rc_kind "$id"), $state" off)
    done
    args+=(back "Back")
    tui_menu "Shell configuration" "Which shell do you want to configure?" "${args[@]}"
}

shellcfg_choose_shell_file() { # <shell> <home> -> kind
    local id="$1" home="$2" kind path mark args=()
    for kind in $(systui_shell_kinds "$id"); do
        path=$(shellcfg_file_for "$kind" "$home")
        if [ -f "$path" ]; then mark=" [exists]"; else mark=""; fi
        args+=("$kind" "$(basename "$path") — $(dirname "$path")$mark")
    done
    args+=(back "Back")
    tui_menu "$(systui_shell_label "$id") — configuration file" "Choose the target file:" "${args[@]}"
}

# Compatibility entry point: shell then file, returning the kind.
shellcfg_choose_file() { # <home> -> kind
    local home="$1" id
    id=$(shellcfg_choose_shell "$home") || return 1
    [ -n "$id" ] || return 1
    [ "$id" = back ] && { printf 'back\n'; return 0; }
    shellcfg_choose_shell_file "$id" "$home"
}

# --- managed settings blocks -------------------------------------------------
# shellcfg_emit_settings <kind> <family> <selections> <editor> <pager> <histsize>
# One block per shell dialect. The old writer emitted bash/POSIX lines for every
# shell, so a tcsh user got `export EDITOR=...` (a tcsh syntax error) and a
# PowerShell user got nothing usable at all.
shellcfg_emit_settings() {
    local k="$1" fam="$2" sel=" $3 " editor="$4" pager="$5" hsize="$6"
    case "$k" in
        inputrc)
            case "$sel" in *" completion "*) printf 'set completion-ignore-case on\nset show-all-if-ambiguous on\n' ;; esac
            case "$sel" in *" vi "*) printf 'set editing-mode vi\n' ;; esac
            case "$sel" in *" color "*) printf 'set colored-stats on\nset visible-stats on\n' ;; esac
            return 0 ;;
        profile)
            # POSIX sh keeps no configurable history; everything else is portable.
            case "$sel" in *" editor "*) printf 'EDITOR=%s; export EDITOR\nVISUAL=%s; export VISUAL\n' "$editor" "$editor" ;; esac
            case "$sel" in *" pager "*) printf 'PAGER=%s; export PAGER\n' "$pager" ;; esac
            case "$sel" in *" color "*) printf 'CLICOLOR=1; export CLICOLOR\n' ;; esac
            case "$sel" in *" vi "*) printf 'set -o vi\n' ;; esac
            case "$sel" in *" history "*) printf '# POSIX sh (dash/ash) has no history-size variable.\n' ;; esac
            return 0 ;;
    esac
    case "$fam" in
        fish)
            case "$sel" in *" history "*) printf 'set -gx fish_history default\n' ;; esac
            case "$sel" in *" editor "*) printf 'set -gx EDITOR %s\nset -gx VISUAL %s\n' "$editor" "$editor" ;; esac
            case "$sel" in *" pager "*) printf 'set -gx PAGER %s\n' "$pager" ;; esac
            case "$sel" in *" color "*) printf 'set -gx CLICOLOR 1\n' ;; esac
            case "$sel" in *" vi "*) printf 'fish_vi_key_bindings\n' ;; esac
            case "$sel" in *" completion "*) printf '# Fish completion is on by default (fish_complete_path).\n' ;; esac
            case "$sel" in *" autocd "*) printf '# Fish changes directory when a bare directory path is entered.\n' ;; esac
            ;;
        nu)
            case "$sel" in *" editor "*) printf '$env.config.buffer_editor = %s\n' "$(nu_quote "$editor")" ;; esac
            case "$sel" in *" pager "*) printf '$env.PAGER = %s\n' "$(nu_quote "$pager")" ;; esac
            case "$sel" in *" vi "*) printf '$env.config.edit_mode = "vi"\n' ;; esac
            case "$sel" in *" history "*) printf '$env.config.history.file_format = "sqlite"\n$env.config.history.max_size = %s\n' "${hsize:-10000}" ;; esac
            ;;
        tcsh)
            case "$sel" in *" history "*) printf 'set history = %s\nset savehist = (%s merge)\n' "${hsize:-10000}" "${hsize:-10000}" ;; esac
            case "$sel" in *" editor "*) printf 'setenv EDITOR %s\nsetenv VISUAL %s\n' "$editor" "$editor" ;; esac
            case "$sel" in *" pager "*) printf 'setenv PAGER %s\n' "$pager" ;; esac
            case "$sel" in *" color "*) printf 'set color\nsetenv CLICOLOR 1\n' ;; esac
            case "$sel" in *" completion "*) printf 'set autolist\nset autoexpand\n' ;; esac
            case "$sel" in *" autocd "*) printf 'set autocd\n' ;; esac
            case "$sel" in *" glob "*) printf 'set globdot\n' ;; esac
            case "$sel" in *" vi "*) printf 'bindkey -v\n' ;; esac
            ;;
        elvish)
            case "$sel" in *" history "*) printf 'set edit:history:max-entries = %s\n' "${hsize:-10000}" ;; esac
            case "$sel" in *" editor "*) printf 'set E:EDITOR = %s\nset E:VISUAL = %s\n' "$editor" "$editor" ;; esac
            case "$sel" in *" pager "*) printf 'set E:PAGER = %s\n' "$pager" ;; esac
            case "$sel" in *" color "*) printf 'set E:CLICOLOR = 1\n' ;; esac
            case "$sel" in *" completion "*) printf 'set edit:completion:arg-completer = $edit:completion:arg-completer\n' ;; esac
            case "$sel" in *" vi "*) printf '# Elvish key binding mode is set via edit:key-binding-mode in the editor module.\n' ;; esac
            ;;
        python)
            case "$sel" in *" history "*) printf '$XONSH_HISTORY_SIZE = (%s, "commands")\n' "${hsize:-10000}" ;; esac
            case "$sel" in *" editor "*) printf '$EDITOR = "%s"\n$VISUAL = "%s"\n' "$editor" "$editor" ;; esac
            case "$sel" in *" pager "*) printf '$PAGER = "%s"\n' "$pager" ;; esac
            case "$sel" in *" color "*) printf '$XONSH_COLOR_STYLE = "default"\n' ;; esac
            case "$sel" in *" completion "*) printf '$XONSH_COMPLETE_WHILE_TYPING = True\n' ;; esac
            case "$sel" in *" autocd "*) printf '$XONSH_AUTOCD = True\n' ;; esac
            case "$sel" in *" vi "*) printf '$XONSH_VI_MODE = True\n' ;; esac
            ;;
        pwsh)
            case "$sel" in *" history "*) printf '$MaximumHistoryCount = %s\n' "${hsize:-10000}" ;; esac
            case "$sel" in *" editor "*) printf '$env:EDITOR = "%s"\n$env:VISUAL = "%s"\n' "$editor" "$editor" ;; esac
            case "$sel" in *" pager "*) printf '$env:PAGER = "%s"\n' "$pager" ;; esac
            case "$sel" in *" color "*) printf '$PSStyle.OutputRendering = "Ansi"\n' ;; esac
            case "$sel" in *" completion "*) printf 'Set-PSReadLineOption -ShowToolTips:$true\n' ;; esac
            case "$sel" in *" autocd "*) printf '# PowerShell has no autocd; use Set-Location or the zoxide integration.\n' ;; esac
            case "$sel" in *" vi "*) printf 'Set-PSReadLineOption -EditMode Vi\n' ;; esac
            ;;
        ksh)
            case "$sel" in *" history "*) printf 'HISTSIZE=%s\nHISTFILE=~/.ksh_history\nexport HISTSIZE HISTFILE\nset -o emacs\n' "${hsize:-10000}" ;; esac
            case "$sel" in *" editor "*) printf 'EDITOR=%s; export EDITOR\nVISUAL=%s; export VISUAL\n' "$editor" "$editor" ;; esac
            case "$sel" in *" pager "*) printf 'PAGER=%s; export PAGER\n' "$pager" ;; esac
            case "$sel" in *" color "*) printf 'CLICOLOR=1; export CLICOLOR\n' ;; esac
            case "$sel" in *" vi "*) printf 'set -o vi\n' ;; esac
            ;;
        zsh)
            case "$sel" in *" history "*) printf 'HISTSIZE=%s\nSAVEHIST=%s\nHISTFILE=~/.zsh_history\nsetopt APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS\n' "${hsize:-10000}" "${hsize:-10000}" ;; esac
            case "$sel" in *" editor "*) printf 'export EDITOR=%q\nexport VISUAL=%q\n' "$editor" "$editor" ;; esac
            case "$sel" in *" pager "*) printf 'export PAGER=%q\n' "$pager" ;; esac
            case "$sel" in *" color "*) printf 'export CLICOLOR=1\n' ;; esac
            case "$sel" in *" completion "*) printf 'autoload -Uz compinit && compinit\n' ;; esac
            case "$sel" in *" autocd "*) printf 'setopt AUTO_CD\n' ;; esac
            case "$sel" in *" glob "*) printf 'setopt EXTENDED_GLOB GLOB_DOTS\n' ;; esac
            case "$sel" in *" correction "*) printf 'setopt CORRECT\n' ;; esac
            case "$sel" in *" vi "*) printf 'bindkey -v\n' ;; esac
            ;;
        *)
            case "$sel" in *" history "*) printf 'export HISTSIZE=%s\nexport HISTFILESIZE=%s\nexport HISTCONTROL=ignoreboth:erasedups\nshopt -s histappend 2>/dev/null || true\n' "${hsize:-10000}" "$((${hsize:-10000} * 2))" ;; esac
            case "$sel" in *" editor "*) printf 'export EDITOR=%q\nexport VISUAL=%q\n' "$editor" "$editor" ;; esac
            case "$sel" in *" pager "*) printf 'export PAGER=%q\n' "$pager" ;; esac
            case "$sel" in *" color "*) printf 'export CLICOLOR=1\nexport LS_COLORS="${LS_COLORS:-}"\n' ;; esac
            case "$sel" in *" completion "*) printf '[[ $- == *i* ]] && [ -r /usr/share/bash-completion/bash_completion ] && source /usr/share/bash-completion/bash_completion\n' ;; esac
            case "$sel" in *" autocd "*) printf 'shopt -s autocd 2>/dev/null || true\n' ;; esac
            case "$sel" in *" glob "*) printf 'shopt -s globstar dotglob 2>/dev/null || true\n' ;; esac
            case "$sel" in *" vi "*) printf 'set -o vi\n' ;; esac
            ;;
    esac
}

shellcfg_write_managed() { # kind file user selections editor pager histsize
    local k="$1" f="$2" u="$3" selections="$4" editor="$5" pager="$6" hsize="$7" tmp fam
    mkdir -p "$(dirname "$f")"; touch "$f"
    fam=$(_shellcfg_kind_family "$k")
    tmp=$(mktemp)
    awk '/^# >>> systui shell settings >>>$/{skip=1;next}/^# <<< systui shell settings <<<$/{skip=0;next}!skip{print}' "$f" > "$tmp"
    {
        cat "$tmp"
        printf '\n# >>> systui shell settings >>>\n'
        shellcfg_emit_settings "$k" "$fam" "$selections" "$editor" "$pager" "$hsize"
        printf '# <<< systui shell settings <<<\n'
    } > "$f"
    rm -f "$tmp"
    chown "$u" "$f" 2>/dev/null || true
}

shellcfg_populated_entries() { # kind file user
    local k="$1" f="$2" u="$3" selected editor pager hsize
    case "$k" in
        inputrc)
            selected=$(tui_check "Readline settings" "SPACE selects entries for $(basename "$f"):" \
                completion "Case-insensitive completion" on \
                vi "Vi editing mode" off \
                color "Colored file listing" off) || return 0
            selected=${selected//\"/}
            shellcfg_backup "$f" "$u"
            shellcfg_write_managed "$k" "$f" "$u" "$selected" "" "" ""
            return 0 ;;
        nuconfig)
            selected=$(tui_check "Shell settings" "SPACE selects entries to automatically populate in $(basename "$f"):" \
                editor "buffer_editor" on \
                pager "PAGER" off \
                history "History file size" on \
                vi "Vi editing mode" off) || return 0
            selected=${selected//\"/}
            editor=$(tui_input "Default editor" "Command for buffer_editor:" "${EDITOR:-nano}") || return 0
            pager=$(tui_input "Default pager" "Command for PAGER:" "less") || return 0
            hsize=$(tui_input "History size" "Number of commands retained:" "10000") || return 0
            [[ "$hsize" =~ ^[0-9]+$ ]] || hsize=10000
            shellcfg_backup "$f" "$u"
            shellcfg_write_managed "$k" "$f" "$u" "$selected" "$editor" "$pager" "$hsize"
            shellcfg_validate "$k" "$f"
            ;;
        nuenv|nulogin)
            tui_msg "Nushell config" "Use Edit to work with $(basename "$f") directly.\nPopulate is only provided for config.nu."
            return 0 ;;
        *)
            selected=$(tui_check "Shell settings" "SPACE selects entries to automatically populate in $(basename "$f") ($(systui_shell_label "$(_shellcfg_kind_shell "$k")")):" \
                history "Persistent history, duplicate filtering and append mode" on \
                editor "EDITOR and VISUAL environment variables" on \
                pager "Default PAGER" off \
                color "Color-aware command environment" on \
                completion "Programmable/tab completion initialization" on \
                autocd "Change directory by entering a directory path" off \
                glob "Recursive and hidden-file globbing" off \
                correction "Command spelling correction (Zsh)" off \
                vi "Vi editing / key-binding mode" off) || return 0
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

_shellcfg_kind_shell() { # <kind> -> owning shell id (fallback: the kind itself)
    local id
    id=$(systui_shell_of_kind "$1" 2>/dev/null || true)
    [ -n "$id" ] || id="$1"
    printf '%s\n' "$id"
}

# --- config menu ------------------------------------------------------------
# The per-file action loop is shared: the global menu (pick a shell, then a file)
# and the per-shell menu both use it. Return codes: 0 = choose another file,
# 1 = back out, 2 = the user was retargeted.
_shellcfg_file_actions() { # <kind> <file> <user>
    local k="$1" f="$2" u="$3" c line
    while true; do
        c=$(tui_menu "Shell config — $(basename "$f")" \
            "User: $u\nShell: $(systui_shell_label "$(_shellcfg_kind_shell "$k")")\nFile: $f" \
            populate "Populate common configuration entries" \
            add "Add a custom configuration line" \
            edit "Open in editor" \
            view "View current configuration" \
            validate "Validate syntax" \
            backup "Create timestamped backup" \
            reset "Remove only the systui-managed settings block" \
            file "Select another config file" user "Change target user" back "Back") || return 1
        case "$c" in
            populate) shellcfg_populated_entries "$k" "$f" "$u" ;;
            add) line=$(tui_input "Add entry" "Enter the exact configuration line:" "") || continue; [ -n "$line" ] && plugin_add_line "$f" "$line" "$u" ;;
            edit) mkdir -p "$(dirname "$f")"; touch "$f"; chown "$u" "$f" 2>/dev/null || true; safe_edit "$f" || true ;;
            view) [ -f "$f" ] && tui_text "$f" "$f" || tui_msg "Shell config" "$f does not exist yet." ;;
            validate) shellcfg_validate "$k" "$f" ;;
            backup) shellcfg_backup "$f" "$u" ;;
            reset) [ -f "$f" ] && sed -i '/^# >>> systui shell settings >>>$/,/^# <<< systui shell settings <<<$/{d}' "$f"; tui_msg "Done" "Removed the systui-managed settings block." ;;
            file) return 0 ;;
            user) return 2 ;;
            back|"") return 1 ;;
        esac
    done
}

menu_shell_config() {
    local target u home_dir id k f rc
    target=$(shellcfg_target) || return 0; u=${target%%|*}; home_dir=${target#*|}
    while true; do
        id=$(shellcfg_choose_shell "$home_dir") || return 0
        [ -z "$id" ] || [ "$id" = back ] && return 0
        while true; do
            k=$(shellcfg_choose_shell_file "$id" "$home_dir") || break
            [ -z "$k" ] || [ "$k" = back ] && break
            f=$(shellcfg_file_for "$k" "$home_dir")
            rc=0
            _shellcfg_file_actions "$k" "$f" "$u" || rc=$?
            if [ "$rc" = 2 ]; then
                target=$(shellcfg_target) || return 0
                u=${target%%|*}; home_dir=${target#*|}
                break
            fi
            [ "$rc" = 1 ] && return 0
        done
    done
}

# --- plugin integration -----------------------------------------------------
# Plugin configuration used to be bash/zsh/fish only: plugin_rc_file knew three
# shells, plugin_choose_shells offered three checkboxes, plugin_show_status
# looped over three names, and every init line was written as if the user's
# shell were POSIX. All of it now comes from the registry.
plugin_rc_file() { # <shell> <home>
    local rc
    rc=$(shell_rc_for "$1" "$2")
    [ -n "$rc" ] || rc="$2/.profile"
    printf '%s\n' "$rc"
}

plugin_choose_shells() {
    local id args=() state
    for id in $(systui_shell_ids); do
        if systui_shell_installed "$id"; then state=on; else state=off; fi
        args+=("$id" "$(systui_shell_label "$id") — $(systui_shell_rc_kind "$id") rc file" "$state")
    done
    tui_check "Shell integration" "SPACE selects the shells to configure:" "${args[@]}"
}

plugin_show_status() { # <name> <command> <home> <pattern>
    local name="$1" command_name="$2" home_dir="$3" pattern="$4" id rc
    {
        echo "Plugin : $name"
        echo "Binary : $(command -v "$command_name" 2>/dev/null || echo 'not installed')"
        echo
        for id in $(systui_shell_ids); do
            rc=$(plugin_rc_file "$id" "$home_dir")
            printf '%-8s : %s\n' "$id" "$rc"
            if [ -f "$rc" ] && grep -n "$pattern" "$rc" >/dev/null 2>&1; then
                grep -n "$pattern" "$rc" 2>/dev/null | head -3 | sed 's/^/           /'
            elif [ -f "$rc" ]; then
                echo "           no integration found"
            else
                echo "           (no config file yet)"
            fi
        done
    } > "${SYSTUI_TMP}/plugin-status"
    tui_text "$name status" "${SYSTUI_TMP}/plugin-status"
}

# Integration (init) lines for the cross-shell tools, one row per shell:
# tool|shell|line. Only documented combinations appear here, so the menu can say
# honestly that a shell has no integration line for a tool.
systui_plugin_init_table() {
    cat <<'EOF'
starship|bash|eval "$(starship init bash)"
starship|zsh|eval "$(starship init zsh)"
starship|fish|starship init fish | source
starship|tcsh|eval "`starship init tcsh`"
starship|nu|mkdir ($nu.data-dir | path join "vendor/autoload"); starship init nu | save -f ($nu.data-dir | path join "vendor/autoload/starship.nu")
starship|elvish|eval (starship init elvish | slurp)
starship|xonsh|execx($(starship init xonsh))
starship|pwsh|Invoke-Expression (&starship init powershell)
zoxide|bash|eval "$(zoxide init bash)"
zoxide|zsh|eval "$(zoxide init zsh)"
zoxide|posix|eval "$(zoxide init posix --hook prompt)"
zoxide|fish|zoxide init fish | source
zoxide|tcsh|eval "`zoxide init tcsh`"
zoxide|nu|zoxide init nushell | save -f ~/.zoxide.nu; source ~/.zoxide.nu
zoxide|elvish|eval (zoxide init elvish | slurp)
zoxide|xonsh|execx($(zoxide init xonsh), 'exec', __xonsh__.ctx, filename='zoxide')
zoxide|pwsh|Invoke-Expression (& { (zoxide init powershell | Out-String) })
atuin|bash|eval "$(atuin init bash)"
atuin|zsh|eval "$(atuin init zsh)"
atuin|fish|atuin init fish | source
atuin|nu|mkdir ($nu.data-dir | path join "vendor/autoload"); atuin init nu | save -f ($nu.data-dir | path join "vendor/autoload/atuin.nu")
atuin|xonsh|execx($(atuin init xonsh), 'exec', __xonsh__.ctx, filename='atuin')
atuin|pwsh|Invoke-Expression (&atuin init powershell)
direnv|bash|eval "$(direnv hook bash)"
direnv|zsh|eval "$(direnv hook zsh)"
direnv|fish|direnv hook fish | source
direnv|tcsh|eval "`direnv hook tcsh`"
direnv|elvish|eval (direnv hook elvish)
direnv|pwsh|Invoke-Expression "$(direnv hook pwsh)"
carapace|bash|eval "$(carapace _carapace bash)"
carapace|zsh|eval "$(carapace _carapace zsh)"
carapace|fish|carapace _carapace fish | source
carapace|elvish|eval (carapace _carapace elvish | slurp)
carapace|xonsh|execx($(carapace _carapace xonsh))
carapace|pwsh|Invoke-Expression (&carapace _carapace powershell | Out-String)
fzf|bash|eval "$(fzf --bash)"
fzf|zsh|eval "$(fzf --zsh)"
fzf|fish|fzf --fish | source
fzf|nu|fzf --nushell | save -f ~/.fzf.nu; source ~/.fzf.nu
EOF
}

# plugin_init_line <tool> <shell> -> the line, empty when the tool has no
# integration for that shell.
plugin_init_line() {
    systui_plugin_init_table | awk -F'|' -v t="$1" -v s="$2" '$1==t && $2==s {print $3; exit}'
}

# plugin_init_tools -> every tool in the table, in order, without repeats.
plugin_init_tools() {
    systui_plugin_init_table | cut -d'|' -f1 | awk '!seen[$0]++'
}

plugin_init_tool_label() { # <tool>
    case "$1" in
        starship) echo "Starship prompt" ;;
        zoxide)   echo "zoxide — smarter cd" ;;
        atuin)    echo "Atuin — shell history sync" ;;
        direnv)   echo "direnv — per-directory environments" ;;
        carapace) echo "Carapace — multi-shell completion" ;;
        fzf)      echo "fzf — fuzzy finder key bindings" ;;
        *)        echo "$1" ;;
    esac
}

# menu_plugin_all_shells <user> <home>: write one tool's integration line into
# every selected shell — the piece that used to exist only for bash/zsh/fish.
menu_plugin_all_shells() {
    local u="$1" h="$2" tool args=() id sh line rc done_list="" missing="" state
    while IFS= read -r tool; do
        args+=("$tool" "$(plugin_init_tool_label "$tool")" off)
    done <<< "$(plugin_init_tools)"
    args+=(back "Back")
    tool=$(tui_menu "All-shell integration" "Write the integration line for which tool?" "${args[@]}") || return 0
    if [ -z "$tool" ] || [ "$tool" = back ]; then return 0; fi

    args=()
    for id in $(systui_shell_ids); do
        line=$(plugin_init_line "$tool" "$id")
        if [ -z "$line" ]; then
            missing="$missing $id"
            continue
        fi
        state=off
        command -v "$(systui_shell_bin "$id")" >/dev/null 2>&1 && state=on
        args+=("$id" "$(systui_shell_label "$id") — $(plugin_rc_file "$id" "$h")" "$state")
    done
    [ "${#args[@]}" -gt 0 ] || { tui_msg "$(plugin_init_tool_label "$tool")" "No shell in the registry has an integration line for this tool."; return 0; }
    # shellcheck disable=SC2086
    sel=$(tui_check "$(plugin_init_tool_label "$tool")" "SPACE selects the shells to configure (installed shells are pre-selected):" "${args[@]}") || return 0
    sel=${sel//\"/}
    [ -n "$sel" ] || return 0
    for sh in $sel; do
        line=$(plugin_init_line "$tool" "$sh")
        [ -n "$line" ] || continue
        rc=$(plugin_rc_file "$sh" "$h")
        plugin_add_line "$rc" "$line" "$u"
        done_list="$done_list $sh"
    done
    [ -n "$missing" ] && note "no integration line available for:$missing"
    tui_msg "$(plugin_init_tool_label "$tool")" "Integration written for:$done_list\n\nFiles were updated in $h."
}

# menu_plugin_custom_source <user> <home>: integrate *any* file or repository
# into any shell — the escape hatch for shells without a plugin ecosystem
# (tcsh, ksh, POSIX sh) and for projects that are not in the catalogue.
menu_plugin_custom_source() {
    local u="$1" h="$2" shells src sh rc dest line
    shells=$(plugin_choose_shells) || return 0
    shells=${shells//\"/}
    [ -n "$shells" ] || return 0
    src=$(tui_input "Plugin source" "Path, or a GitHub owner/repo to clone:" "$h/.config/systui/plugins") || return 0
    [ -n "$src" ] || return 0
    case "$src" in
        /*|.*) : ;;                      # a path on this host
        */*)                             # owner/repo on GitHub
            dest="$h/.local/share/shell-plugins/$(basename "$src")"
            command -v git >/dev/null 2>&1 || pm_install git
            fm_as_user "$u" "mkdir -p ~/.local/share/shell-plugins; if [ -d '$dest/.git' ]; then git -C '$dest' pull --ff-only; else git clone --depth 1 --recurse-submodules https://github.com/$src.git '$dest'; fi"
            src="$dest" ;;
    esac
    for sh in $shells; do
        rc=$(plugin_rc_file "$sh" "$h")
        if [ -d "$src" ]; then
            line=$(systui_plugin_entry_line "$sh" "$src")
        else
            line=$(plugin_source_line "$sh" "$src")
        fi
        [ -n "$line" ] || continue
        plugin_add_line "$rc" "$line" "$u"
    done
    tui_msg "Custom plugin" "Source line written for:$shells\n\nSource: $src"
}

# menu_shell_github_plugins: the catalogue is now shell-agnostic. Rows keep the
# bash/zsh/fish special cases (ble.sh needs building, Fish plugins use fisher),
# and any other shell in the `shells` column is cloned into a per-shell directory
# and integrated with that shell's own source syntax.
menu_shell_github_plugins() {
    local u="$1" h="$2" chosen tag desc repo shells init dest rc line sh args=()
    while IFS='|' read -r tag desc repo shells init; do
        [ -z "$tag" ] && continue
        args+=("$tag" "$desc — $repo [$shells]" off)
    done <<< "$(shell_github_catalog)"
    chosen=$(tui_check "GitHub shell plugins — $u" "SPACE selects projects to install/update and integrate:" "${args[@]}") || return 0
    chosen=${chosen//\"/}
    [ -n "$chosen" ] || return 0
    command -v git >/dev/null 2>&1 || pm_install git
    for tag in $chosen; do
        while IFS='|' read -r t desc repo shells init; do
            [ "$t" = "$tag" ] || continue
            for sh in ${shells//,/ }; do
                case "$sh" in
                    bash)
                        dest="$h/.local/share/$tag"
                        fm_as_user "$u" "mkdir -p ~/.local/share; if [ -d '$dest/.git' ]; then git -C '$dest' pull --ff-only; else rm -rf '$dest'; git clone --depth 1 --recurse-submodules https://github.com/$repo.git '$dest'; fi"
                        # ble.sh ships only a Makefile (no pre-built ble.sh), so
                        # build it before sourcing; it also needs GNU awk.
                        if [ "$tag" = ble-sh ]; then
                            command -v make >/dev/null 2>&1 || pm_install make
                            command -v gawk >/dev/null 2>&1 || pm_install gawk
                            fm_as_user "$u" "make -C '$dest'"
                        fi
                        rc="$h/.bashrc"; plugin_add_line "$rc" "${init//\~/$h}" "$u" ;;
                    zsh)
                        dest="$h/.local/share/zsh-plugins/$tag"
                        fm_as_user "$u" "mkdir -p ~/.local/share/zsh-plugins; if [ -d '$dest/.git' ]; then git -C '$dest' pull --ff-only; else rm -rf '$dest'; git clone --depth 1 --recurse-submodules https://github.com/$repo.git '$dest'; fi"
                        rc="$h/.zshrc"; plugin_add_line "$rc" "${init//\~/$h}" "$u" ;;
                    fish)
                        command -v fish >/dev/null 2>&1 || pm_install fish
                        fm_as_user "$u" "fish -lc 'type -q fisher; or begin; set t (mktemp); curl -fL --proto =https --tlsv1.2 https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish -o \"\$t\"; source \"\$t\"; rm -f \"\$t\"; end; $init'" ;;
                    *)
                        # Any other shell: clone into a per-shell directory and
                        # integrate with that shell's own source syntax.
                        dest="$h/.local/share/shell-plugins/$tag"
                        fm_as_user "$u" "mkdir -p ~/.local/share/shell-plugins; if [ -d '$dest/.git' ]; then git -C '$dest' pull --ff-only; else rm -rf '$dest'; git clone --depth 1 --recurse-submodules https://github.com/$repo.git '$dest'; fi"
                        line=$(systui_plugin_entry_line "$sh" "$dest")
                        plugin_add_line "$(plugin_rc_file "$sh" "$h")" "$line" "$u" ;;
                esac
            done
        done <<< "$(shell_github_catalog)"
    done
    tui_msg "Shell plugins" "Selected GitHub projects were installed or updated for $u."
}

# --- plugins menu -----------------------------------------------------------
# Same menu as before, plus the two all-shell actions: a tool's init line written
# for every shell, and a custom source line for shells without a plugin
# ecosystem. The individual plugin entries below still call the shared
# menu_plugin_* helpers.
menu_shell_plugins() {
    local target u home_dir c
    target=$(shell_plugin_target) || return 0
    u=${target%%|*}; home_dir=${target#*|}
    while true; do
        c=$(tui_menu "Shell Plugins — $u" "Install, configure, inspect or remove cross-shell enhancements:" \
            allshells "All-shell integration — write a tool's init line for every shell" \
            custom "Custom plugin source — integrate a file or GitHub project into any shell" \
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
            allshells) menu_plugin_all_shells "$u" "$home_dir" ;;
            custom) menu_plugin_custom_source "$u" "$home_dir" ;;
            starship) menu_plugin_starship "$u" "$home_dir" ;;
            fzf) menu_plugin_fzf "$u" "$home_dir" ;;
            comp) menu_plugin_completions "$u" "$home_dir" ;;
            zoxide) menu_plugin_simple_init "zoxide" zoxide zoxide 'eval "$(zoxide init bash)"' 'eval "$(zoxide init zsh)"' 'zoxide init fish | source' "$u" "$home_dir" "$home_dir/.config/zoxide/config.toml" ;;
            atuin) menu_plugin_simple_init "Atuin" atuin atuin 'eval "$(atuin init bash)"' 'eval "$(atuin init zsh)"' 'atuin init fish | source' "$u" "$home_dir" "$home_dir/.config/atuin/config.toml" ;;
            direnv) menu_plugin_simple_init "direnv" direnv direnv 'eval "$(direnv hook bash)"' 'eval "$(direnv hook zsh)"' 'direnv hook fish | source' "$u" "$home_dir" "$home_dir/.config/direnv/direnvrc" ;;
            carapace) menu_plugin_simple_init "Carapace" carapace carapace 'eval "$(carapace _carapace bash)"' 'eval "$(carapace _carapace zsh)"' 'carapace _carapace fish | source' "$u" "$home_dir" "$home_dir/.config/carapace/bridges.yaml" ;;
            syntax) menu_plugin_simple_init "Zsh syntax highlighting" zsh-syntax-highlighting zsh-syntax-highlighting '' '@detect:zsh-syntax-highlighting' '' "$u" "$home_dir" "$home_dir/.zshrc" ;;
            github) menu_shell_github_plugins "$u" "$home_dir" ;;
            azp) menu_azp "$u" "$home_dir" ;;
            autosuggest) menu_plugin_simple_init "Zsh autosuggestions" zsh-autosuggestions zsh-autosuggestions '' '@detect:zsh-autosuggestions' '' "$u" "$home_dir" "$home_dir/.zshrc" ;;
            user) target=$(shell_plugin_target) || continue; u=${target%%|*}; home_dir=${target#*|} ;;
            back|"") return 0 ;;
        esac
    done
}

# --- alias dialects ---------------------------------------------------------
# The alias manager keeps one POSIX master file; every other shell needs its own
# dialect (`alias x 'cmd'` in tcsh, `alias x = cmd` in nushell, `aliases['x']` in
# xonsh, `fn x {|@a| e:cmd $@a }` in elvish, `function x { cmd @args }` in
# PowerShell). All of them are regenerated from the master on every change.
ALIAS_DIR_NAME=".config/systui"

aliases_dialect_file() { # <home> <dialect>
    printf '%s/%s/aliases.%s\n' "$1" "$ALIAS_DIR_NAME" "$2"
}

alias_pairs() { # <posix-alias-file> -> "name<TAB>command"
    awk '
      /^alias [A-Za-z_][A-Za-z0-9_.-]*=/{
        line=$0; sub(/^alias /,"",line);
        name=line; sub(/=.*/,"",name);
        cmd=line; sub(/^[^=]*=/,"",cmd);
        gsub(/^\047|\047$/,"",cmd);
        gsub(/\047\\\047\047/,"\047",cmd);
        printf "%s\t%s\n", name, cmd
      }' "$1"
}

# aliases_write_dialects <posix-alias-file> <user>
aliases_write_dialects() {
    local src="$1" u="$2" h tmp n
    [ -f "$src" ] || return 0
    h=$(user_home "$u"); [ -n "$h" ] || return 0
    mkdir -p "$h/$ALIAS_DIR_NAME" 2>/dev/null || true

    # tcsh / csh: alias name "command" (double quotes, shell metacharacters escaped)
    tmp=$(mktemp)
    {
        printf '# Generated by systui from aliases.sh -- do not edit.\n'
        alias_pairs "$src" | while IFS=$'\t' read -r n cmd; do
            esc=$(printf '%s' "$cmd" | sed 's/[\\"`$!]/\\&/g')
            printf 'alias %s "%s"\n' "$n" "$esc"
        done
    } > "$tmp" && mv "$tmp" "$h/$ALIAS_DIR_NAME/aliases.tcsh"

    # nushell: alias name = command  (the right-hand side must stay a bare command)
    tmp=$(mktemp)
    {
        printf '# Generated by systui from aliases.sh -- do not edit.\n'
        printf '# Nushell aliases take a command, not a string: commands with pipes,\n'
        printf '# quoting or redirection need a manual `def`.\n'
        alias_pairs "$src" | while IFS=$'\t' read -r n cmd; do
            printf 'alias %s = %s\n' "$n" "$cmd"
        done
    } > "$tmp" && mv "$tmp" "$h/$ALIAS_DIR_NAME/aliases.nu"

    # xonsh: aliases['name'] = 'command'
    tmp=$(mktemp)
    {
        printf '# Generated by systui from aliases.sh -- do not edit.\n'
        alias_pairs "$src" | while IFS=$'\t' read -r n cmd; do
            esc=${cmd//\'/\\\'}
            printf "aliases['%s'] = '%s'\n" "$n" "$esc"
        done
    } > "$tmp" && mv "$tmp" "$h/$ALIAS_DIR_NAME/aliases.xsh"

    # elvish: fn name {|@a| e:command $@a }  (external commands need the e: prefix)
    tmp=$(mktemp)
    {
        printf '# Generated by systui from aliases.sh -- do not edit.\n'
        alias_pairs "$src" | awk -F'\t' '
          {
            n=$1; cmd=$2
            split(cmd, parts, " ")
            prog=parts[1]
            rest=substr(cmd, length(prog)+1)
            if (prog !~ /^\//) prog="e:" prog
            printf "fn %s {|@a| %s%s $@a }\n", n, prog, rest
          }'
    } > "$tmp" && mv "$tmp" "$h/$ALIAS_DIR_NAME/aliases.elv"

    # PowerShell: function name { command @args }
    tmp=$(mktemp)
    {
        printf '# Generated by systui from aliases.sh -- do not edit.\n'
        alias_pairs "$src" | while IFS=$'\t' read -r n cmd; do
            esc=${cmd//\$/"\`\$"}
            printf 'function %s { %s @args }\n' "$n" "$esc"
        done
    } > "$tmp" && mv "$tmp" "$h/$ALIAS_DIR_NAME/aliases.ps1"

    chown -R "$u" "$h/$ALIAS_DIR_NAME" 2>/dev/null || true
}

# Keep the existing Fish generator, then regenerate every other dialect from the
# same master file so no menu action can leave them out of sync.
systui_alias_function aliases_write_fish _systui_base_aliases_write_fish
aliases_write_fish() { # <posix-alias-file> <fish-alias-file> <user>
    _systui_base_aliases_write_fish "$@" || return $?
    aliases_write_dialects "$1" "$3"
}

# aliases_enable <user> <home>: source the alias file that fits each shell.
systui_alias_function aliases_enable _systui_base_aliases_enable
aliases_enable() { # <user> <home>
    local u="$1" h="$2" af id file line
    _systui_base_aliases_enable "$@" || true
    af=$(alias_file_for "$h")
    [ -f "$af" ] || { : > "$af"; chown "$u" "$af" 2>/dev/null || true; }
    aliases_write_dialects "$af" "$u"
    for id in $(systui_shell_ids); do
        case "$id" in
            bash|zsh|posix|ksh) file="$af" ;;                     # POSIX master
            fish) file="$h/$ALIAS_DIR_NAME/aliases.fish" ;;
            tcsh) file="$h/$ALIAS_DIR_NAME/aliases.tcsh" ;;
            nu)   file="$h/$ALIAS_DIR_NAME/aliases.nu" ;;
            xonsh) file="$h/$ALIAS_DIR_NAME/aliases.xsh" ;;
            elvish) file="$h/$ALIAS_DIR_NAME/aliases.elv" ;;
            pwsh) file="$h/$ALIAS_DIR_NAME/aliases.ps1" ;;
            *) continue ;;
        esac
        # Only touch shells that are actually installed: creating a config tree
        # for a shell the user does not have is noise, not configuration.
        systui_shell_installed "$id" || continue
        line=$(plugin_source_line "$id" "$file")
        [ -n "$line" ] || continue
        plugin_add_line "$(plugin_rc_file "$id" "$h")" "$line" "$u"
    done
}

# --- plugin entry files -----------------------------------------------------
# systui_plugin_entry_file <shell> <dir>: the file inside a cloned project that
# the shell should actually load (empty when the layout is not recognised).
systui_plugin_entry_file() { # <shell> <dir>
    local sh="$1" d="$2" base f
    [ -d "$d" ] || return 1
    base=$(basename "$d")
    case "$sh" in
        zsh)
            zsh_plugin_file "$d" 2>/dev/null || true
            return 0 ;;
    esac
    case "$sh" in
        bash|posix|ksh)
            for f in "$d/$base.sh" "$d"/*.sh; do
                [ -f "$f" ] && { basename "$f"; return 0; }
            done ;;
        elvish)
            for f in "$d/$base.elv" "$d"/*.elv; do
                [ -f "$f" ] && { basename "$f"; return 0; }
            done ;;
        xonsh)
            for f in "$d/$base.xsh" "$d"/*.xsh; do
                [ -f "$f" ] && { basename "$f"; return 0; }
            done ;;
        pwsh)
            for f in "$d/$base.ps1" "$d"/*.ps1 "$d"/*.psd1; do
                [ -f "$f" ] && { basename "$f"; return 0; }
            done ;;
        nu)
            for f in "$d/$base.nu" "$d"/*.nu; do
                [ -f "$f" ] && { basename "$f"; return 0; }
            done ;;
    esac
    return 1
}

# systui_plugin_entry_line <shell> <dir> -> the source line for a cloned project
# (or an explanatory comment when the entry point cannot be determined).
systui_plugin_entry_line() { # <shell> <dir>
    local sh="$1" d="$2" f
    f=$(systui_plugin_entry_file "$sh" "$d" 2>/dev/null || true)
    if [ -n "$f" ]; then
        plugin_source_line "$sh" "$d/$f"
        return 0
    fi
    case "$sh" in
        tcsh|ksh|posix) printf '# %s: load the project manually (no conventional entry point)\n' "$d" ;;
        *)              printf '# %s: no conventional entry point found; see its README\n' "$d" ;;
    esac
}

export -f systui_shell_registry systui_shell_ids systui_shell_field \
    systui_shell_label systui_shell_bin systui_shell_rc_kind systui_shell_kinds \
    systui_shell_validator systui_shell_of_kind systui_shell_installed \
    systui_shells_installed shell_rc_for plugin_source_line plugin_detect_line \
    shellcfg_file_for shellcfg_files_for shellcfg_validate shellcfg_choose_shell \
    shellcfg_choose_shell_file shellcfg_choose_file shellcfg_emit_settings \
    shellcfg_write_managed shellcfg_populated_entries menu_shell_config \
    plugin_rc_file plugin_choose_shells plugin_show_status systui_plugin_init_table \
    plugin_init_line plugin_init_tools plugin_init_tool_label menu_plugin_all_shells \
    menu_plugin_custom_source menu_shell_github_plugins menu_shell_plugins \
    aliases_dialect_file \
    alias_pairs aliases_write_dialects aliases_write_fish aliases_enable \
    systui_plugin_entry_file systui_plugin_entry_line

# --- per-shell managers -----------------------------------------------------
# Every shell systui knows gets the same manager surface — install/reinstall,
# uninstall, default login shell, configuration files, plugins and the alias
# dialect — instead of only bash/zsh/fish/nushell having one and the rest living
# behind a separate "More shells" install-only list.

# The concrete binaries a registry entry stands for. Entries that cover a family
# (POSIX sh, Korn shell, C shell) can be installed as any of their members.
systui_shell_entry_bins() { # <shell>
    case "$1" in
        posix) printf 'dash yash ash\n' ;;
        ksh)   printf 'ksh mksh\n' ;;
        tcsh)  printf 'tcsh csh\n' ;;
        *)     systui_shell_bin "$1" ;;
    esac
}

systui_shell_for_bin() { # <binary> -> registry id
    case "$1" in
        dash|ash|yash|sh) printf 'posix\n' ;;
        ksh|mksh|pdksh)   printf 'ksh\n' ;;
        tcsh|csh)         printf 'tcsh\n' ;;
        nu)               printf 'nu\n' ;;
        pwsh|powershell)  printf 'pwsh\n' ;;
        bash|zsh|fish|elvish|xonsh) printf '%s\n' "$1" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

systui_shell_bin_label() { # <binary>
    case "$1" in
        dash)  printf 'dash — Debian Almquist shell (fast, minimal POSIX sh)\n' ;;
        ash)   printf 'ash — BusyBox/POSIX shell\n' ;;
        yash)  printf 'yash — yet another shell (POSIX, advanced scripting)\n' ;;
        ksh)   printf 'KornShell 93u+m (AT&T ksh93 with modern fixes)\n' ;;
        mksh)  printf 'mksh — MirBSD Korn shell (small, fast, portable)\n' ;;
        csh)   printf 'csh — classic C shell\n' ;;
        tcsh)  printf 'tcsh — TENEX C shell (completion, history)\n' ;;
        nu)    printf 'Nushell — structured-data shell\n' ;;
        pwsh)  printf 'PowerShell — cross-platform automation shell (.NET)\n' ;;
        *)     printf '%s\n' "$(systui_shell_label "$(systui_shell_for_bin "$1")")" ;;
    esac
}

# systui_shell_state_note <shell> <user>: what the menu says about a shell.
systui_shell_state_note() {
    local id="$1" u="$2" bins b found="" cur cur_flag=""
    cur=$(getent passwd "$u" 2>/dev/null | cut -d: -f7)
    [ -n "$cur" ] && cur=$(basename "$cur")
    for b in $(systui_shell_entry_bins "$id"); do
        if command -v "$b" >/dev/null 2>&1; then found="$found $b"; fi
        if [ -n "$cur" ] && [ "$b" = "$cur" ]; then cur_flag=", current login shell"; fi
    done
    if [ -n "$found" ]; then printf 'installed:%s%s' "$found" "$cur_flag"
    else printf 'not installed%s' "$cur_flag"; fi
}

systui_shell_install_action() { # <shell> <user> <home>
    local id="$1" bins b n choice args=()
    bins=$(systui_shell_entry_bins "$id")
    n=0
    for b in $bins; do n=$((n + 1)); done
    if [ "$n" -gt 1 ]; then
        for b in $bins; do args+=("$b" "$(systui_shell_bin_label "$b")" off); done
        args+=(back "Back")
        choice=$(tui_menu "Install $(systui_shell_label "$id")" "Which shell from this family?" "${args[@]}") || return 0
        if [ -z "$choice" ] || [ "$choice" = back ]; then return 0; fi
        b="$choice"
    else
        b="$bins"
    fi
    case "$id" in
        bash) pm_install bash ;;
        zsh)  menu_zsh_install ;;
        fish) menu_fish_install ;;
        nu)   menu_nushell_install ;;
        *)    menu_shell_install_any "$b" "$(systui_shell_bin_label "$b")" ;;
    esac
}

# The frameworks/plugin managers that exist for a given shell. Shells without an
# ecosystem get an explanation instead of an empty menu.
systui_shell_framework_menu() { # <shell> <user> <home>
    local id="$1" u="$2" h="$3" c
    case "$id" in
        bash) c=$(tui_menu "Bash frameworks — $u" "Plugin frameworks for Bash:" \
                  omb "oh-my-bash (framework, themes, plugins)" \
                  bashit "Bash-it (framework with plugins and aliases)" \
                  blesh "ble.sh (line editor: autosuggestions, highlighting)" \
                  back "Back") || return 0
              case "$c" in omb) menu_omb "$u" "$h" ;; bashit) menu_bashit "$u" "$h" ;; blesh) menu_blesh "$u" "$h" ;; esac ;;
        zsh)  c=$(tui_menu "Zsh frameworks — $u" "Plugin frameworks for Zsh:" \
                  omz "oh-my-zsh (framework)" \
                  zinit "zinit (plugin manager)" \
                  azp "awesome-zsh-plugins catalogue (space-select)" \
                  back "Back") || return 0
              case "$c" in omz) menu_omz "$u" "$h" ;; zinit) menu_zinit "$u" "$h" ;; azp) menu_azp "$u" "$h" ;; esac ;;
        fish) c=$(tui_menu "Fish plugins — $u" "Plugin manager for Fish:" \
                  fisher "Fisher (install/update/remove Fish plugins)" \
                  back "Back") || return 0
              case "$c" in fisher) menu_fisher "$u" "$h" ;; esac ;;
        nu)   c=$(tui_menu "Nushell plugins — $u" "Nushell:" \
                  plugins "Manage nushell plugins (nu_plugin_*)" \
                  install "Install/reinstall Nushell" \
                  back "Back") || return 0
              case "$c" in plugins) menu_nushell_plugins ;; install) menu_nushell_install ;; esac ;;
        *)
            tui_msg "$(systui_shell_label "$id") plugins" \
                "$(systui_shell_label "$id") has no plugin framework of its own.\n\nUse the integration lines in the plugins menu (Starship, zoxide, fzf and\nfriends all support it) or a custom plugin source." ;;
    esac
}

# systui_shell_plugins_write_all <shell> <user> <home>: every tool in the init
# table that supports this shell.
systui_shell_plugins_write_all() {
    local id="$1" u="$2" h="$3" tool line rc written="" absent=""
    rc=$(plugin_rc_file "$id" "$h")
    while IFS= read -r tool; do
        line=$(plugin_init_line "$tool" "$id")
        if [ -n "$line" ]; then
            plugin_add_line "$rc" "$line" "$u"
            written="$written $tool"
        else
            absent="$absent $tool"
        fi
    done <<< "$(plugin_init_tools)"
    [ -n "$absent" ] && note "no integration line for:$absent"
    tui_msg "$(systui_shell_label "$id") plugins" "Integration lines written to $rc${written:+ for:}$written${absent:+

(not available for this shell:$absent)}"
}

systui_shell_plugins_menu() { # <shell> <user> <home>
    local id="$1" u="$2" h="$3" rc c tool args=() line sel status_file
    rc=$(plugin_rc_file "$id" "$h")
    while true; do
        c=$(tui_menu "$(systui_shell_label "$id") plugins — $u" "Integration file: $rc" \
            all "Write the integration line for every available tool" \
            one "Write one tool's integration line" \
            custom "Add a custom plugin/rc source line" \
            status "Show what is configured in $rc" \
            view "View the integration file" \
            framework "Plugin framework / manager for this shell" \
            back "Back") || return 0
        case "$c" in
            all) systui_shell_plugins_write_all "$id" "$u" "$h" ;;
            one)
                args=()
                while IFS= read -r tool; do
                    line=$(plugin_init_line "$tool" "$id")
                    [ -n "$line" ] || continue
                    args+=("$tool" "$(plugin_init_tool_label "$tool")" off)
                done <<< "$(plugin_init_tools)"
                if [ "${#args[@]}" -eq 0 ]; then
                    tui_msg "No tools" "No cross-shell tool has an integration line for $(systui_shell_label "$id")."
                    continue
                fi
                args+=(back "Back")
                tool=$(tui_menu "Integration line" "Which tool?" "${args[@]}") || continue
                if [ -z "$tool" ] || [ "$tool" = back ]; then continue; fi
                line=$(plugin_init_line "$tool" "$id")
                [ -n "$line" ] && plugin_add_line "$rc" "$line" "$u"
                tui_msg "$(plugin_init_tool_label "$tool")" "Written to $rc:\n$line" ;;
            custom)
                sel=$(tui_input "Custom plugin source" "Path to a file or directory to load in $(systui_shell_label "$id"):" "") || continue
                if [ -n "$sel" ]; then
                    if [ -d "$sel" ]; then
                        line=$(systui_plugin_entry_line "$id" "$sel")
                    else
                        line=$(plugin_source_line "$id" "$sel")
                    fi
                    plugin_add_line "$rc" "$line" "$u"
                    tui_msg "Custom plugin" "Written to $rc:\n$line"
                fi ;;
            status)
                status_file="${SYSTUI_TMP}/shell-plugin-status.$$"
                {
                    echo "Shell : $(systui_shell_label "$id")"
                    echo "File  : $rc"
                    echo
                    if [ -f "$rc" ]; then
                        printf 'Lines matching a known tool:\n'
                        while IFS= read -r tool; do
                            line=$(plugin_init_line "$tool" "$id")
                            [ -n "$line" ] || continue
                            grep -nF "$line" "$rc" 2>/dev/null | sed 's/^/  /'
                        done <<< "$(plugin_init_tools)"
                        printf '\nCustom source lines:\n'
                        grep -n '^\. \|^source ' "$rc" 2>/dev/null | sed 's/^/  /'
                    else
                        echo "(no integration file yet)"
                    fi
                } > "$status_file"
                tui_text "$(systui_shell_label "$id") plugin status" "$status_file"
                rm -f "$status_file" ;;
            view) if [ -f "$rc" ]; then tui_text "$rc" "$rc"; else tui_msg "Integration file" "$rc does not exist yet."; fi ;;
            framework) systui_shell_framework_menu "$id" "$u" "$h" ;;
            back|"") return 0 ;;
        esac
    done
}

systui_shell_alias_action() { # <shell> <user> <home>
    local id="$1" u="$2" h="$3" af f line
    af=$(alias_file_for "$h")
    mkdir -p "$(dirname "$af")" 2>/dev/null || true
    [ -f "$af" ] || { : > "$af"; chown "$u" "$af" 2>/dev/null || true; }
    aliases_write_dialects "$af" "$u"
    case "$id" in
        bash|zsh|posix|ksh) f="$af" ;;
        fish)   f=$(aliases_dialect_file "$h" fish) ;;
        tcsh)   f=$(aliases_dialect_file "$h" tcsh) ;;
        nu)     f=$(aliases_dialect_file "$h" nu) ;;
        xonsh)  f=$(aliases_dialect_file "$h" xonsh) ;;
        elvish) f=$(aliases_dialect_file "$h" elvish) ;;
        pwsh)   f=$(aliases_dialect_file "$h" ps1) ;;
        *)      f="$af" ;;
    esac
    if systui_shell_installed "$id"; then
        line=$(plugin_source_line "$id" "$f")
        plugin_add_line "$(plugin_rc_file "$id" "$h")" "$line" "$u"
        tui_msg "$(systui_shell_label "$id") aliases" "Regenerated from the managed alias list and sourced from\n$(plugin_rc_file "$id" "$h"):\n$f"
    else
        tui_msg "$(systui_shell_label "$id") aliases" "$(systui_shell_label "$id") is not installed; the dialect file was\nwritten to $f and will be sourced once the shell is installed."
    fi
}

systui_shell_manager_menu() { # <shell> <user> <home>
    local id="$1" u="$2" h="$3" c rc bins
    bins=$(systui_shell_entry_bins "$id")
    rc=$(plugin_rc_file "$id" "$h")
    while true; do
        c=$(tui_menu "$(systui_shell_label "$id") — $u" "Binaries: $bins\nIntegration file: $rc\n$(systui_shell_state_note "$id" "$u")" \
            config "Configuration files (populate, edit, validate, back up)" \
            plugins "Plugins (integration lines, custom sources, status)" \
            aliases "Alias dialect for this shell" \
            view "View the integration file" \
            install "Install/reinstall $(systui_shell_label "$id")" \
            default "Set as the default login shell" \
            uninstall "Uninstall $(systui_shell_label "$id")" \
            framework "Plugin framework / manager for this shell" \
            advanced "Advanced shell settings (umask, TMOUT, PATH, PS1)" \
            back "Back") || return 0
        case "$c" in
            config) menu_shell_config_for "$id" "$u" "$h" ;;
            plugins) systui_shell_plugins_menu "$id" "$u" "$h" ;;
            aliases) systui_shell_alias_action "$id" "$u" "$h" ;;
            view) if [ -f "$rc" ]; then tui_text "$rc" "$rc"; else tui_msg "Integration file" "$rc does not exist yet."; fi ;;
            install) systui_shell_install_action "$id" "$u" "$h" ;;
            default) menu_set_default_shell ;;
            uninstall)
                if [ "$id" = posix ] || [ "$id" = ksh ] || [ "$id" = tcsh ]; then
                    local b choice args=()
                    for b in $bins; do args+=("$b" "$(systui_shell_bin_label "$b")" off); done
                    args+=(back "Back")
                    choice=$(tui_menu "Uninstall $(systui_shell_label "$id")" "Which one?" "${args[@]}") || continue
                    if [ -z "$choice" ] || [ "$choice" = back ]; then continue; fi
                    safe_remove_shell "$choice"
                else
                    safe_remove_shell "$(systui_shell_bin "$id")"
                fi ;;
            framework) systui_shell_framework_menu "$id" "$u" "$h" ;;
            advanced) menu_shell_advanced ;;
            back|"") return 0 ;;
        esac
    done
}

# Configuration menu scoped to one shell (also used by the shell list below).
menu_shell_config_for() { # <shell> <user> <home>
    local id="$1" u="$2" h="$3" k f rc
    while true; do
        k=$(shellcfg_choose_shell_file "$id" "$h") || return 0
        if [ -z "$k" ] || [ "$k" = back ]; then return 0; fi
        f=$(shellcfg_file_for "$k" "$h")
        rc=0
        _shellcfg_file_actions "$k" "$f" "$u" || rc=$?
        # 2 (change user) has no meaning here: the manager menu owns the user.
        [ "$rc" = 0 ] || return 0
    done
}

# The shell list: every shell systui manages, in one menu, with the same manager
# behind each entry. The old front door listed bash/zsh/fish/nushell plus tmux and
# hid dash/ksh/mksh/tcsh/elvish/xonsh/yash/pwsh behind a separate install-only
# "More shells" entry.
systui_shell_managers_menu() {
    local u h c id label args=()
    u=$(tui_input "Shell Managers" "Manage shells for which user?" "${SUDO_USER:-root}") || return 0
    h=$(user_home "$u")
    [ -n "$h" ] || { tui_msg "Error" "User '$u' was not found."; return 0; }
    while true; do
        args=()
        for id in $(systui_shell_ids); do
            label=$(systui_shell_label "$id")
            args+=("$id" "$label — $(systui_shell_state_note "$id" "$u")" off)
        done
        args+=(tmux "tmux — install/update, plugins, config and sessions" off)
        if declare -F menu_shell_runtime_commands >/dev/null 2>&1; then
            args+=(runtime "Shell runtime configuration (launch command / boot command)" off)
        fi
        if declare -F menu_shell_init_login >/dev/null 2>&1; then
            args+=(login "Login shells, /etc/shells and the /bin/sh provider" off)
        fi
        if declare -F systui_shell_init_services_menu >/dev/null 2>&1; then
            args+=(initmgr "Init & services manager" off)
        fi
        args+=(advanced "Advanced shell settings (umask, TMOUT, PATH, PS1)" off)
        args+=(back "Back")
        c=$(tui_menu "Shells — $u" "Install, remove or configure any shell. Current init: ${INIT:-unknown}" "${args[@]}") || return 0
        case "$c" in
            ''|back) return 0 ;;
            tmux) menu_tmux "$u" "$h" ;;
            runtime) menu_shell_runtime_commands ;;
            login) menu_shell_init_login ;;
            initmgr) systui_shell_init_services_menu ;;
            advanced) menu_shell_advanced ;;
            *) systui_shell_manager_menu "$c" "$u" "$h" ;;
        esac
    done
}

# The runtime hierarchy dispatches through these names, so pointing them at the
# all-shell list is what puts every shell in the main menu.
_systui_base_menu_shell_hierarchy_logininit() { systui_shell_managers_menu "$@"; }
_systui_base_menu_shell_hierarchy_runtime() { systui_shell_managers_menu "$@"; }
_systui_shell_hierarchy_before_tmux_final() { systui_shell_managers_menu "$@"; }

# menu_plain_shell was the install-only manager for the additional shells; keep
# it as an entry point but give it the full manager surface.
menu_plain_shell() { # <user> <home> <shell> <display> <blurb>
    local id
    id=$(systui_shell_for_bin "$3")
    systui_shell_manager_menu "$id" "$1" "$2"
}

export -f systui_shell_entry_bins systui_shell_for_bin systui_shell_bin_label \
    systui_shell_state_note systui_shell_install_action systui_shell_framework_menu \
    systui_shell_plugins_write_all systui_shell_plugins_menu systui_shell_alias_action \
    systui_shell_manager_menu menu_shell_config_for systui_shell_managers_menu \
    _systui_base_menu_shell_hierarchy_logininit _systui_base_menu_shell_hierarchy_runtime \
    _systui_shell_hierarchy_before_tmux_final menu_plain_shell _shellcfg_file_actions
