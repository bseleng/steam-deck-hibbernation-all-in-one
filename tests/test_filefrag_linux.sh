#!/usr/bin/env bash
# Exercise the actual e2fsprogs CLI against a small temporary ordinary file.
# No swap activation, root access, mounts, boot configuration or systemd calls.
set -euo pipefail
[[ $(uname -s) == Linux ]] || { echo 'This filefrag regression requires Linux.' >&2; exit 2; }
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
source "$PROJECT/steamdeck-hibernate-apply.sh"
command -v filefrag >/dev/null || { echo 'Install e2fsprogs to run this test.' >&2; exit 2; }
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
SWAPFILE="$TMP/filefrag fixture"
dd if=/dev/zero of="$SWAPFILE" bs=1M count=8 conv=fsync status=none
# The production parser uses the REAL filefrag and getconf. Only filesystem UUID
# discovery is replaced because Docker overlay filesystems do not expose UUIDs.
findmnt() { printf '12345678-abcd-1234-5678-123456789abc\n'; }
resume_values
page_size=$(getconf PAGESIZE)
# Independent unit check: request byte units, then compare the byte location
# with the production result in PAGE_SIZE units. A bare -b would select 1024
# and fail this check even if the CLI returned success after a warning.
byte_output=$(LC_ALL=C filefrag -b1 -v "$SWAPFILE" 2>"$TMP/stderr")
[[ ! -s "$TMP/stderr" ]] || { cat "$TMP/stderr" >&2; exit 1; }
byte_offset=$(printf '%s\n' "$byte_output" | awk '$1=="0:" {sub(/\.\..*/, "", $4); print $4; exit}')
[[ $byte_offset =~ ^[1-9][0-9]*$ ]] || { echo 'Cannot resolve physical byte location of fixture' >&2; exit 1; }
(( RESUME_OFFSET * page_size == byte_offset )) || {
  echo "Incorrect offset units: $RESUME_OFFSET * $page_size != $byte_offset" >&2; exit 1;
}
printf 'PASS: real filefrag %s-byte PAGE_SIZE argument and independent byte-offset cross-check.\n' "$page_size"
