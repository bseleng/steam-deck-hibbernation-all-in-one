#!/usr/bin/env bash
# Isolated tests only: no root access or host system writes.
# Sourced implementation functions are intentionally overridden later; fixtures
# contain literal shell syntax and mock functions are also called indirectly.
# shellcheck disable=SC2016,SC2218,SC2317
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
source "$PROJECT/steamdeck-hibernate-apply.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STATE_DIR=$TMP/state
SETTINGS_FILE=$STATE_DIR/settings
mkdir -p "$STATE_DIR"
GRUB_FILE=$TMP/grub
GRUB_CFG=$TMP/grub.cfg
RESUME_UUID=12345678-abcd-1234-5678-123456789abc
RESUME_OFFSET=12345
passed=0
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }
reject() { if ("$@") >/dev/null 2>&1; then echo "Unexpected success: $*" >&2; exit 1; fi; }

printf 'delay=90min\nsize_gib=24\nsth=0\n' > "$SETTINGS_FILE"
load_settings
[[ $DELAY == 90min && $SIZE_GIB == 24 && $STH == 0 ]]
pass 'saved delay, size and STH load without evaluation'
printf 'delay=$(touch bad)\n' > "$SETTINGS_FILE"
reject load_settings
[[ ! -e bad ]]
pass 'shell code in settings is rejected without execution'
printf 'delay=60min\ndelay=2h\n' > "$SETTINGS_FILE"
reject load_settings
pass 'duplicate saved settings rejected'
printf 'delay=90min\nsize_gib=24\nsth=0\n' > "$SETTINGS_FILE"
DELAY_OVERRIDE=2h; STH_OVERRIDE=1
load_settings
[[ $DELAY == 2h && $STH == 1 && $SIZE_GIB == 24 ]]
pass 'explicit options override persisted values'
DELAY=0min
reject validate_settings
pass 'invalid delay rejected'

printf '%s\n' 'GRUB_TIMEOUT=3' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet resume=UUID=old splash resume_offset=4 foo=bar"' > "$GRUB_FILE"
result=$(render_grub)
[[ $result == *'quiet splash foo=bar resume=UUID=12345678-abcd-1234-5678-123456789abc resume_offset=12345'* ]]
[[ $result != *'UUID=old'* ]]
pass 'GRUB replacement preserves unrelated args and replaces UUID syntax'
printf '%s\n' "$result" > "$GRUB_FILE"
[[ $(render_grub) == "$result" ]]
pass 'GRUB rendering is idempotent'
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet $UNTRUSTED"' > "$GRUB_FILE"
reject render_grub
pass 'GRUB shell expansion rejected'
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' 'GRUB_CMDLINE_LINUX_DEFAULT="other"' > "$GRUB_FILE"
reject render_grub
pass 'duplicate GRUB assignment rejected'
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' > "$GRUB_FILE"
DRY_RUN=1
before=$(cat "$GRUB_FILE")
write_file "$GRUB_FILE" 644 'new content'
[[ $(cat "$GRUB_FILE") == "$before" && ! -d "$STATE_DIR/backups" ]]
pass 'dry-run does not write config or backup'
ln -s "$GRUB_FILE" "$TMP/link"
reject write_file "$TMP/link" 644 'new content'
pass 'atomic config writer refuses target symlinks'
CHECK_ONLY=1
reject write_file "$GRUB_FILE" 644 'new content'
pass 'check mode returns failure for drift'
CHECK_ONLY=0
runtime_resume_matches() { return 1; }
SUSPEND_DROPIN=$TMP/suspend.conf
SUSPEND_LINK=$TMP/suspend.service
STH=1
configure_sth
[[ $REBOOT_REQUIRED == 1 && ! -e $SUSPEND_DROPIN ]]
pass 'STH is deferred when running kernel lacks matching resume arguments'
ln -s /custom/unmanaged "$SUSPEND_LINK"
reject configure_sth
pass 'unmanaged suspend override refused'
rm "$SUSPEND_LINK"

# First extent must contain the logical header and use PAGE_SIZE units.
getconf() { printf '4096\n'; }
findmnt() { printf '%s\n' "$RESUME_UUID"; }
filefrag() { [[ $1 == -b && $2 == 4096 && $3 == -v ]]; printf ' 0: 0.. 1023: 12345.. 13368: 1024: last,eof\n'; }
resume_values
[[ $RESUME_OFFSET == 12345 ]]
pass 'resume offset requests PAGE_SIZE and resolves logical page zero'
filefrag() { printf ' 0: 4.. 1023: 12345.. 13368: 1024: last,eof\n'; }
reject resume_values
pass 'sparse swap header rejected'
filefrag() { printf ' 0: 0.. 1023: 12345.. 13368: 1024: unwritten,last,eof\n'; }
reject resume_values
pass 'unwritten swap extent rejected'
RESUME_OFFSET=12345
printf '%s\n' 'linux /vmlinuz resume=UUID=12345678-abcd-1234-5678-123456789abc' 'linux /old resume_offset=12345' > "$GRUB_CFG"
reject grub_has_resume
pass 'generated resume tokens must be on the same Linux boot line'
printf '%s\n' 'linux /vmlinuz resume=UUID=12345678-abcd-1234-5678-123456789abc resume_offset=12345' > "$GRUB_CFG"
grub_has_resume
pass 'generated exact resume token pair accepted'

# Detect the real generated config, ignoring forwarding stubs.
CANDIDATES="$TMP/efi-grub.cfg
$TMP/boot-grub.cfg"
supported_grub_configs() { printf '%s\n' "$CANDIDATES"; }
update-grub() { if [[ ${1:-} == --help ]]; then printf 'Usage: update-grub\n'; return 0; fi; return 17; }
printf '%s\n' 'linux /vmlinuz quiet' > "$TMP/efi-grub.cfg"
printf '%s\n' 'configfile /EFI/SteamOS/grub.cfg' > "$TMP/boot-grub.cfg"
detect_grub_config
[[ $GRUB_CFG == "$TMP/efi-grub.cfg" ]]
pass 'detects generated EFI config and ignores /boot forwarding stub'
printf '%s\n' 'linux /vmlinuz quiet' > "$TMP/boot-grub.cfg"
reject detect_grub_config
pass 'ambiguous generated configs rejected'
update-grub() { if [[ ${1:-} == --help ]]; then printf 'Run grub-mkconfig and place output at %s\n' "$TMP/efi-grub.cfg"; return 0; fi; return 17; }
detect_grub_config
[[ $GRUB_CFG == "$TMP/efi-grub.cfg" ]]
pass 'advertised update-grub output takes precedence over another real config'
update-grub() { printf 'Run grub-mkconfig and place output at /unsupported/grub.cfg\n'; }
reject detect_grub_config
pass 'unsupported advertised output path rejected'

# Simulate a failed generator: both configs and original modes must be restored.
DRY_RUN=0
printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' > "$GRUB_FILE"
before=$(cat "$GRUB_FILE")
printf '%s\n' 'linux /vmlinuz original=configuration' > "$TMP/efi-grub.cfg"
chmod 600 "$GRUB_FILE" "$TMP/efi-grub.cfg"
write_file() { printf '%s\n' "$3" > "$1"; chmod "$2" "$1"; }
# Portable GNU-stat subset for these isolated tests on macOS and Linux.
stat() { python3 - "$3" <<'PY_STAT'
import os, stat, sys
print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])
PY_STAT
}
update-grub() {
  if [[ ${1:-} == --help ]]; then printf 'Run grub-mkconfig and place output at %s\n' "$TMP/efi-grub.cfg"; return 0; fi
  printf 'called\n' > "$TMP/generator-called"
  printf 'truncated\n' > "$GRUB_CFG"
  chmod 644 "$GRUB_CFG"
  return 17
}
reject configure_grub
[[ -f $TMP/generator-called ]]
[[ $(cat "$GRUB_FILE") == "$before" && $(cat "$GRUB_CFG") == 'linux /vmlinuz original=configuration' ]]
[[ $(stat -c %a "$GRUB_FILE") == 600 && $(stat -c %a "$GRUB_CFG") == 600 ]]
pass 'failed GRUB regeneration restores both configs and original modes'
printf 'Passed %s isolated checks\n' "$passed"
