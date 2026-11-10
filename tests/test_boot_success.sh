#!/bin/bash
# No root, hardware, systemd, EFI or installed SteamOS tools required.
set -euo pipefail
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$PROJECT/steamdeck-boot-success.sh"
FIXTURE=$(mktemp -d)
trap 'rm -rf -- "$FIXTURE"' EXIT
export MOCK_STATE="$FIXTURE"
cat > "$FIXTURE/bootconf" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_STATE/calls"
[[ "${MOCK_FAIL:-}" != all ]] || exit 1
if [[ "$1" == this-image ]]; then cat "$MOCK_STATE/image"; exit; fi
[[ "$1" == --image && "$3" == config && "$4" == --no-create ]] || exit 91
image=$2
shift 4
while (( $# )); do
    case "$1" in
        --get)
            [[ "${MOCK_FAIL:-}" != read ]] || exit 2
            if [[ "${MOCK_FAIL:-}" == malformed && "$2" == boot-attempts ]]; then
                printf 'boot-attempts: 6\nboot-attempts: 7\n'
            else
                printf '%s: %s\n' "$2" "$(cat "$MOCK_STATE/$image.$2")"
            fi
            shift 2 ;;
        --set)
            [[ "${MOCK_FAIL:-}" != write ]] || exit 3
            if [[ "${MOCK_FAIL:-}" != readback ]]; then
                printf '%s\n' "$3" > "$MOCK_STATE/$image.$2"
            fi
            if [[ "${MOCK_FAIL:-}" == race ]]; then
                printf '20990101000000\n' > "$MOCK_STATE/$image.boot-requested-at"
            fi
            shift 3 ;;
        *) exit 92 ;;
    esac
done
MOCK
chmod +x "$FIXTURE/bootconf"
boot_success_find_tool() { printf '%s\n' "$FIXTURE/bootconf"; }
reset_state() {
    export MOCK_FAIL=''
    printf 'B\n' > "$FIXTURE/image"
    : > "$FIXTURE/calls"
    local image
    for image in A B; do
        printf '16\n' > "$FIXTURE/$image.boot-attempts"
        printf '0\n' > "$FIXTURE/$image.image-invalid"
        printf '20260620191300\n' > "$FIXTURE/$image.boot-requested-at"
        printf '1\n' > "$FIXTURE/$image.boot-other"
    done
}
assert_value() { [[ "$(cat "$FIXTURE/$1")" == "$2" ]] || { printf 'FAIL: %s expected %s\n' "$1" "$2" >&2; exit 1; }; }
expect_failure() { if "$@" >/dev/null 2>&1; then printf 'FAIL: expected failure: %s\n' "$*" >&2; exit 1; fi; }
assert_no_write() { if grep -q -- --set "$FIXTURE/calls"; then printf 'FAIL: unexpected write\n' >&2; exit 1; fi; }

reset_state
expect_failure boot_success_run --check
assert_no_write
boot_success_run >/dev/null
assert_value B.boot-attempts 0
assert_value A.boot-attempts 16
assert_value B.boot-requested-at 20260620191300
assert_value B.boot-other 1
boot_success_run --check >/dev/null
before=$(wc -l < "$FIXTURE/calls")
boot_success_run >/dev/null
if tail -n "+$((before + 1))" "$FIXTURE/calls" | grep -q -- --set; then
    printf 'FAIL: repeated invocation wrote healthy bootconf\n' >&2; exit 1
fi

# Slot identity follows this-image, including after a SteamOS A/B update.
reset_state
printf 'A\n' > "$FIXTURE/image"
boot_success_run --resume >/dev/null
assert_value A.boot-attempts 0
assert_value B.boot-attempts 16

# Model the loader adding one failure for each hibernation boot. Successful
# resume must reset every cycle, including beyond both failsafe thresholds.
# shellcheck disable=SC2034 # Repeat the same counter lifecycle twelve times.
for cycle in {1..12}; do
    printf '1\n' > "$FIXTURE/A.boot-attempts"
    boot_success_run --resume >/dev/null
    assert_value A.boot-attempts 0
done
assert_value B.boot-attempts 16

reset_state
printf '1\n' > "$FIXTURE/B.image-invalid"
boot_success_run >/dev/null 2>&1
assert_value B.image-invalid 1
expect_failure boot_success_run --check
boot_success_run --resume >/dev/null
assert_value B.image-invalid 0
assert_value A.boot-attempts 16
assert_value B.boot-other 1
assert_value B.boot-requested-at 20260620191300

reset_state
printf '1\n' > "$FIXTURE/B.image-invalid"
boot_success_run --mark-success >/dev/null
assert_value B.boot-attempts 0
assert_value B.image-invalid 0
assert_value A.boot-attempts 16
assert_value B.boot-other 1
assert_value B.boot-requested-at 20260620191300

reset_state
boot_success_run --dry-run --resume >/dev/null
assert_value B.boot-attempts 16
assert_no_write

for failure in all read write malformed readback race; do
    reset_state
    export MOCK_FAIL=$failure
    expect_failure boot_success_run --resume
done

for name in '' 'B/../A' 'A B' $'A\nB' '-A'; do
    reset_state
    printf '%s\n' "$name" > "$FIXTURE/image"
    expect_failure boot_success_run
    assert_no_write
done
reset_state
printf '2\n' > "$FIXTURE/B.image-invalid"
expect_failure boot_success_run
assert_no_write
reset_state
expect_failure boot_success_run --unknown
expect_failure boot_success_run --check --resume
expect_failure boot_success_run --check --mark-success
expect_failure boot_success_run --check --dry-run
assert_no_write
boot_success_find_tool() { return 1; }
expect_failure boot_success_run
printf 'PASS: boot-success helper (read-only checks, correct image, resume demotion repair, idempotency, dry-run, failure/readback/race guards).\n'
