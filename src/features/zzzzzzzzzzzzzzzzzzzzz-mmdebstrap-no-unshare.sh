# shellcheck shell=bash
# mmdebstrap may invoke unshare even when running as root to probe mount
# capability. On iSH-AOK and other kernels without namespace support this
# fails with ENOSYS ("Function not implemented"). Force root mode and skip
# mmdebstrap's can-mount namespace probe when Systui already knows unshare is
# unavailable.

if type -P mmdebstrap >/dev/null 2>&1; then
    _systui_mmdebstrap_bin="$(type -P mmdebstrap)"

    mmdebstrap() {
        local -a args=("$@") out=()
        local i arg next skip_next=0 have_mode=0 have_canmount_skip=0

        if [ "${SYSTUI_UNSHARE_SUPPORTED:-1}" = 1 ]; then
            "$_systui_mmdebstrap_bin" "${args[@]}"
            return $?
        fi

        for ((i=0; i<${#args[@]}; i++)); do
            arg="${args[i]}"

            case "$arg" in
                --mode=*)
                    have_mode=1
                    if [ "$arg" = "--mode=unshare" ] || [ "$arg" = "--mode=auto" ]; then
                        out+=("--mode=root")
                    else
                        out+=("$arg")
                    fi
                    ;;
                --mode)
                    have_mode=1
                    next="${args[i+1]:-}"
                    if [ "$next" = "unshare" ] || [ "$next" = "auto" ]; then
                        out+=("--mode" "root")
                    else
                        out+=("--mode" "$next")
                    fi
                    i=$((i+1))
                    ;;
                --skip=*)
                    case ",${arg#--skip=}," in
                        *,check/canmount,*) have_canmount_skip=1 ;;
                    esac
                    out+=("$arg")
                    ;;
                *) out+=("$arg") ;;
            esac
        done

        [ "$have_mode" -eq 1 ] || out=("--mode=root" "${out[@]}")
        [ "$have_canmount_skip" -eq 1 ] || out=("--skip=check/canmount" "${out[@]}")

        if declare -F log >/dev/null 2>&1; then
            log "mmdebstrap: unshare unsupported; forcing --mode=root --skip=check/canmount"
        fi

        "$_systui_mmdebstrap_bin" "${out[@]}"
    }
fi
