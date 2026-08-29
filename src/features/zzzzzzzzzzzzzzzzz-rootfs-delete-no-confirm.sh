# shellcheck shell=bash
# Rootfs management: DELETE is intentionally immediate after menu selection.
# The rootfs has already been explicitly selected in the parent menu, so do
# not add a second yes/no or typed-name confirmation step.

if declare -F rootfs_manage >/dev/null 2>&1; then
    eval "$(declare -f rootfs_manage | awk '
        BEGIN { skip=0 }
        /[[:space:]]*delete\)/ {
            print
            print "                run_cmd \"Deleting $sel\" rootfs_rm_tree \"$sel\" ;;"
            skip=1
            next
        }
        skip && /[[:space:]]*back\)/ { skip=0 }
        !skip { print }
    ')"
fi
