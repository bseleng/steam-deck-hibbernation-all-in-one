#!/bin/bash
# SteamOS stores failed attempts in bootconf, not in GRUB's grubenv.
# Call with --resume from a successful sleep service's ExecStartPost, or with
# --mark-success after the installer has validated the running SteamOS system.
# This helper deliberately preserves boot-requested-at, boot-other and every
# other image: an OS update may already have selected a different image.

boot_success_error() { printf 'steamdeck-boot-success: %s\n' "$*" >&2; }

boot_success_find_tool() {
    command -v steamos-bootconf 2>/dev/null || command -v holo-bootconf 2>/dev/null
}

boot_success_value() {
    local tool=$1 image=$2 key=$3 output
    output=$("$tool" --image "$image" config --no-create --get "$key") || return 1
    # Accept exactly one numeric key/value line; never evaluate bootconf data.
    if [[ "$output" =~ ^${key}:[[:blank:]]*([0-9]+)[[:blank:]]*$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        boot_success_error "Malformed or unsupported $key for image $image."
        return 1
    fi
}

boot_success_run() {
    local check=0 resumed=0 dry_run=0 arg
    for arg in "$@"; do
        case "$arg" in
            --check) check=1 ;;
            --resume|--mark-success) resumed=1 ;;
            --dry-run) dry_run=1 ;;
            *) boot_success_error "Unknown option: $arg"; return 2 ;;
        esac
    done
    if (( check && (resumed || dry_run) )); then
        boot_success_error '--check cannot be combined with --resume, --mark-success or --dry-run.'
        return 2
    fi

    local tool image attempts invalid requested other after
    tool=$(boot_success_find_tool) || {
        boot_success_error 'Neither steamos-bootconf nor holo-bootconf is available.'
        return 1
    }
    image=$("$tool" this-image) || {
        boot_success_error 'Cannot identify the running SteamOS image.'
        return 1
    }
    if [[ ! "$image" =~ ^[[:alnum:]]+$ || ${#image} -gt 64 ]]; then
        boot_success_error 'Running image name is empty or invalid; refusing to write.'
        return 1
    fi
    attempts=$(boot_success_value "$tool" "$image" boot-attempts) || return 1
    invalid=$(boot_success_value "$tool" "$image" image-invalid) || return 1
    requested=$(boot_success_value "$tool" "$image" boot-requested-at) || return 1
    other=$(boot_success_value "$tool" "$image" boot-other) || return 1
    if [[ ! "$invalid" =~ ^[01]$ || ! "$other" =~ ^[01]$ ]]; then
        boot_success_error 'Invalid boolean bootconf value; refusing to write.'
        return 1
    fi
    printf 'SteamOS image %s: boot-attempts=%s image-invalid=%s\n' "$image" "$attempts" "$invalid"

    if (( check )); then
        [[ "$attempts" == 0 && "$invalid" == 0 ]]
        return $?
    fi
    if [[ "$invalid" == 1 ]] && (( ! resumed )); then
        boot_success_error 'image-invalid is preserved: only a confirmed successful resume or validated running system may clear it. Boot selection may still prefer another image.'
    fi
    local -a changes=()
    [[ "$attempts" == 0 ]] || changes+=(--set boot-attempts 0)
    if [[ "$invalid" == 1 ]] && (( resumed )); then
        changes+=(--set image-invalid 0)
    fi
    if (( ${#changes[@]} == 0 )); then
        return 0
    fi
    if (( dry_run )); then
        printf 'Would update running image %s:' "$image"
        printf ' %s' "${changes[@]}"
        printf '\n'
        return 0
    fi
    # --no-create prevents accidentally synthesizing an unknown image config.
    "$tool" --image "$image" config --no-create "${changes[@]}" || {
        boot_success_error "Failed to update image $image."
        return 1
    }
    after=$(boot_success_value "$tool" "$image" boot-attempts) || return 1
    if [[ "$after" != 0 ]]; then
        boot_success_error 'boot-attempts did not read back as zero.'
        return 1
    fi
    after=$(boot_success_value "$tool" "$image" image-invalid) || return 1
    if (( resumed )); then
        [[ "$after" == 0 ]] || { boot_success_error 'image-invalid did not clear.'; return 1; }
    else
        [[ "$after" == "$invalid" ]] || { boot_success_error 'image-invalid unexpectedly changed.'; return 1; }
    fi
    after=$(boot_success_value "$tool" "$image" boot-requested-at) || return 1
    [[ "$after" == "$requested" ]] || { boot_success_error 'Boot priority changed concurrently; inspect bootconf before hibernating again.'; return 1; }
    after=$(boot_success_value "$tool" "$image" boot-other) || return 1
    [[ "$after" == "$other" ]] || { boot_success_error 'Boot selection changed concurrently; inspect bootconf before hibernating again.'; return 1; }
    printf 'SteamOS image %s: boot-attempts reset and verified.\n' "$image"
}

boot_success_main() {
    # Fixed lookup path for execution by root/systemd; no user PATH programs.
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    LC_ALL=C
    export PATH LC_ALL
    case "${1:-}" in
        --help|-h)
            printf 'Usage: %s [--check | --resume | --mark-success] [--dry-run]\n' "$0"
            printf 'Default: clear failed attempts on the running image only.\n'
            printf '%s\n' '--resume: additionally clear image-invalid after a successful resume.'
            printf '%s\n' '--mark-success: clear image-invalid after validating the running system (installer use).'
            printf '%s\n' '--check: read-only; succeeds when attempts=0 and image-invalid=0.'
            return 0 ;;
    esac
    local readonly=0 arg
    for arg in "$@"; do
        [[ "$arg" != --check && "$arg" != --dry-run ]] || readonly=1
    done
    if (( ! readonly && EUID != 0 )); then
        boot_success_error 'Run this helper as root, or use --check/--dry-run.'
        return 1
    fi
    boot_success_run "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
    boot_success_main "$@"
fi
