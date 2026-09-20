# shellcheck shell=bash
###############################################################################
# ROOTFS SHELL DIAGNOSIS AND REPAIR
#
# The Workbench used to say "…has no executable /bin/sh" and stop: it never
# said whether the entry was missing, dangling, or simply stripped of its
# execute bit, and the test behind it resolved an absolute in-rootfs symlink
# against the HOST root ("/bin/sh -> /usr/bin/dash" is a healthy tree, but the
# host has no /usr/bin/dash), so healthy rootfs trees were reported as broken —
# and, because the same expression gates the incomplete-bootstrap predicate,
# could even be sent to the bootstrap recovery.
#
# Everything here inspects and edits the tree from the host: no binary from the
# rootfs is ever executed.
###############################################################################

# Machine-readable state; always succeeds so callers can read the record.
rootfs_wb_shell_state() { # <target> -> status|path|detail
    if declare -F rootfs_tree_shell_state >/dev/null 2>&1; then
        rootfs_tree_shell_state "${1:-}"
        return $?
    fi
    [ -x "$1/bin/sh" ] && { printf 'ok|/bin/sh|\n'; return 0; }
    printf 'missing|/bin/sh|\n'
    return 1
}

rootfs_wb_shell_usable() { # <target>
    if declare -F rootfs_tree_shell_usable >/dev/null 2>&1; then
        rootfs_tree_shell_usable "${1:-}"
        return $?
    fi
    [ -x "${1:-}/bin/sh" ]
}

# Human explanation of the current state.
rootfs_wb_shell_explain() { # <target> -> multi-line text (no dialog)
    local t="$1" state status path detail
    state=$(rootfs_wb_shell_state "$t") || true
    IFS='|' read -r status path detail <<< "$state"

    case "$status" in
        ok)
            printf 'The shell entry is usable.\n\n  /bin/sh resolves to %s and is executable.\n' "$path"
            ;;
        missing)
            printf 'This rootfs has no usable /bin/sh entry.\n\n  %s\n\nA shell binary IS present, so Systui can point /bin/sh at it without\ninstalling anything.\n' "$detail"
            ;;
        dangling)
            printf 'The /bin/sh entry is a broken link.\n\n  %s\n\nThe link target does not exist inside this rootfs. Systui can re-point it at\na shell that is actually present, or at an installed shell if none is.\n' "$detail"
            ;;
        noexec)
            printf 'The /bin/sh entry is present but not executable.\n\n  %s\n\nTrees that were copied or unpacked without preserving permissions (for\nexample through a file manager instead of tar) lose their execute bits.\nSystui can restore them; it never runs anything from the tree.\n' "$detail"
            ;;
        notfile)
            printf 'The /bin/sh entry does not point at a regular file.\n\n  %s\n\nSystui can re-point it at a shell that is present in this rootfs.\n' "$detail"
            ;;
        loop)
            printf 'The /bin/sh symlink chain does not terminate.\n\n  %s\n\nSystui can replace the entry with a direct link to an installed shell.\n' "$detail"
            ;;
        *)
            printf 'This rootfs has no usable /bin/sh and no shell binary in it.\n\n  %s\n\nThat means the tree is incomplete or was not unpacked correctly. Repair the\nrootfs base (Continue/recover interrupted rootfs generation) or unpack the\narchive again, then retry.\n' "$detail"
            ;;
    esac
}

rootfs_wb_shell_report() { # <target>
    tui_msg "Rootfs shell: $(basename "$1")" "$(rootfs_wb_shell_explain "$1")"
}

# Restore execute bits on files that are unambiguously executables but lost the
# mode bits. Prints how many files were repaired.
rootfs_wb_shell_restore_modes() { # <target> -> count
    local t="${1%/}" d f magic n=0
    log "rootfs: scanning $t for executables that lost their mode bits"

    for d in bin usr/bin sbin usr/sbin usr/local/bin; do
        [ -d "$t/$d" ] || continue
        for f in "$t/$d"/*; do
            [ -f "$f" ] || continue
            [ -L "$f" ] && continue
            if declare -F rootfs_tree_exec_ok >/dev/null 2>&1; then
                rootfs_tree_exec_ok "$f" && continue
            else
                [ -x "$f" ] && continue
            fi
            magic=""
            IFS= read -r -N 4 magic < "$f" 2>/dev/null || true
            case "$magic" in
                $'\177ELF'*|'#!'*)
                    if chmod +x -- "$f" 2>/dev/null; then
                        n=$((n + 1))
                    fi ;;
            esac
        done
    done
    printf '%s\n' "$n"
}

# Repair the tree so that /bin/sh resolves to an executable shell.
rootfs_wb_shell_repair() { # <target>
    local t="${1%/}" cand link real_bin fixed=0 status="" path="" own_entry=""

    [ -d "$t" ] || return 1
    IFS='|' read -r status path _ <<< "$(rootfs_wb_shell_state "$t" || true)"
    # A shell whose entry merely lost its execute bit still points at the only
    # shell in the tree; it must not be re-linked to itself.
    if [ "$status" = noexec ] && [ -n "$path" ]; then
        own_entry="$path"
    fi

    # 1. /bin must resolve to a directory inside the tree. A usrmerge tree whose
    #    /bin link was dropped by the unpacker gets it back.
    if ! declare -F rootfs_tree_path_is_dir >/dev/null 2>&1 || \
       ! rootfs_tree_path_is_dir "$t" /bin; then
        if [ -d "$t/usr/bin" ]; then
            if [ -L "$t/bin" ] || [ -f "$t/bin" ]; then
                rm -f -- "$t/bin" 2>/dev/null || true
            fi
            if [ ! -e "$t/bin" ] && [ ! -L "$t/bin" ]; then
                ln -s usr/bin "$t/bin" || return 1
                log "rootfs: created the /bin -> usr/bin link in $t"
                fixed=1
            fi
        elif [ ! -d "$t/bin" ]; then
            mkdir -p "$t/bin" || return 1
            fixed=1
        fi
    fi

    # 2. Find a shell binary inside the tree.
    cand=""
    if declare -F rootfs_tree_shell_candidate >/dev/null 2>&1; then
        cand=$(rootfs_tree_shell_candidate "$t") || cand=""
    else
        for cand in bin/dash usr/bin/dash bin/bash usr/bin/bash bin/busybox usr/bin/busybox; do
            [ -f "$t/$cand" ] && break
            cand=""
        done
    fi
    if [ -z "$cand" ] && [ -n "$own_entry" ]; then
        cand="$own_entry"
    fi
    [ -n "$cand" ] || return 1
    cand=${cand#/}

    # 3. Make sure it can actually be executed, restoring lost modes first.
    if declare -F rootfs_tree_exec_ok >/dev/null 2>&1; then
        if ! rootfs_tree_exec_ok "$t$cand"; then
            fixed=$(rootfs_wb_shell_restore_modes "$t")
            rootfs_tree_exec_ok "$t$cand" || chmod +x -- "$t$cand" 2>/dev/null || true
            if [ "$fixed" -gt 0 ]; then
                log "rootfs: restored execute bits on $fixed file(s) in $t"
            fi
        fi
    elif [ ! -x "$t$cand" ]; then
        chmod +x -- "$t$cand" 2>/dev/null || true
    fi

    # 3b. If the entry already is that shell, only the mode bits were missing.
    if [ "/$cand" = "$own_entry" ]; then
        if rootfs_wb_shell_usable "$t"; then
            log "rootfs: restored the execute bit on $own_entry in $t"
            return 0
        fi
        return 1
    fi

    # 4. Point /bin/sh at it. The link is relative and computed against the real
    #    location of /bin, so it stays correct for usrmerge trees.
    real_bin="/bin"
    if declare -F rootfs_resolve_in_tree >/dev/null 2>&1; then
        real_bin=$(rootfs_resolve_in_tree "$t" /bin) || real_bin="/bin"
        link=$(rootfs_relative_link "$real_bin" "/$cand")
    else
        link="$cand"
    fi
    [ -n "$link" ] || return 1

    rm -f -- "$t/bin/sh" 2>/dev/null || true
    if [ -L "$t/bin/sh" ] || [ -e "$t/bin/sh" ]; then
        # A directory or an undeletable entry: do not pretend this worked.
        return 1
    fi
    ln -s -- "$link" "$t/bin/sh" || return 1
    log "rootfs: /bin/sh -> $link in $t (shell: /$cand)"

    rootfs_wb_shell_usable "$t"
}

# Diagnose, then offer the repair. Returns 0 when the tree ends up with a
# usable /bin/sh (or already had one).
rootfs_wb_shell_check_prompt() { # <target>
    local t="$1" state status path
    rootfs_wb_shell_usable "$t" && return 0

    rootfs_wb_shell_report "$t"

    state=$(rootfs_wb_shell_state "$t") || true
    IFS='|' read -r status _path _detail <<< "$state"
    case "$status" in
        noshell)
            # Nothing to point at: repairing would mean installing a shell,
            # which is a rootfs rebuild, not a link fix.
            return 1 ;;
    esac

    if ! tui_yesno "Repair the rootfs shell" \
"Attempt to repair the /bin/sh entry in:

$t

Systui only edits files in this rootfs; nothing from it is executed."; then
        return 1
    fi

    if rootfs_wb_shell_repair "$t"; then
        state=$(rootfs_wb_shell_state "$t") || true
        IFS='|' read -r _s path _d <<< "$state"
        tui_msg "Rootfs shell repaired" \
"The rootfs now has a usable shell entry.

  /bin/sh resolves to $path

Enter, run and package operations will work again. Re-run the readiness scan to
confirm the remaining requirements."
        return 0
    fi

    tui_msg "Shell repair did not complete" \
"Systui could not give this rootfs a usable /bin/sh.

$(rootfs_wb_shell_explain "$t")

The rootfs was left as it was found apart from any /bin link and execute bits
that were restored. See $LOGFILE for details."
    return 1
}

###############################################################################
# READINESS REPAIR INTEGRATION
###############################################################################
# A failed /bin/sh check is exactly the kind of thing the readiness repair
# selector should offer to fix.

if declare -F rootfs_wb_ish_repair_choices >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_wb_ish_repair_choices_shell >/dev/null 2>&1; then
    eval "$(declare -f rootfs_wb_ish_repair_choices | sed '1s/^rootfs_wb_ish_repair_choices[[:space:]]*()/_systui_base_rootfs_wb_ish_repair_choices_shell ()/')"
fi

rootfs_wb_ish_repair_choices() { # <target>
    local t="$1" state status detail
    _systui_base_rootfs_wb_ish_repair_choices_shell "$t"
    if rootfs_wb_shell_usable "$t"; then
        return 0
    fi
    state=$(rootfs_wb_shell_state "$t") || true
    IFS='|' read -r status _path detail <<< "$state"
    [ -n "$status" ] || status="missing"
    [ -n "$detail" ] || detail="/bin/sh is not usable"
    printf 'shell|[FAIL] /bin/sh — %s|on\n' "${detail%% (*}"
}

if declare -F rootfs_wb_ish_apply_repair >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_wb_ish_apply_repair_shell >/dev/null 2>&1; then
    eval "$(declare -f rootfs_wb_ish_apply_repair | sed '1s/^rootfs_wb_ish_apply_repair[[:space:]]*()/_systui_base_rootfs_wb_ish_apply_repair_shell ()/')"
fi

rootfs_wb_ish_apply_repair() { # <target> <tag>
    case "$2" in
        shell) rootfs_wb_shell_repair "$1" ;;
        *) _systui_base_rootfs_wb_ish_apply_repair_shell "$@" ;;
    esac
}

export -f rootfs_wb_shell_state rootfs_wb_shell_usable rootfs_wb_shell_explain \
    rootfs_wb_shell_report rootfs_wb_shell_restore_modes rootfs_wb_shell_repair \
    rootfs_wb_shell_check_prompt rootfs_wb_ish_repair_choices rootfs_wb_ish_apply_repair
