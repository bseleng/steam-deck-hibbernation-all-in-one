#!/usr/bin/env bash
# Destructive ONLY to a disposable container filesystem. Never run on a Deck.
set -euo pipefail
[[ ${STEAMDECK_TEST_CONTAINER:-} == 1 && -f /.dockerenv ]] || {
  echo 'Run only in a disposable Docker container; see README.' >&2; exit 2;
}
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
export PROJECT
mkdir -p /etc/default /boot/grub /efi/EFI/steamos /home /tmp/deck-test /etc/sysctl.d
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' > /etc/default/grub
printf 'steamenv_boot   linux /vmlinuz quiet\n' > /efi/EFI/steamos/grub.cfg
printf 'configfile /EFI/steamos/grub.cfg\n' > /boot/grub/grub.cfg
printf '# original fstab\n' > /etc/fstab
truncate -s 16G /home/swapfile
printf '100\n' > /tmp/deck-test/swappiness
printf 'B\n' > /tmp/deck-test/image
for image in A B; do
  printf '16\n' > "/tmp/deck-test/$image.boot-attempts"
  printf '1\n' > "/tmp/deck-test/$image.image-invalid"
  printf '20260620191300\n' > "/tmp/deck-test/$image.boot-requested-at"
  printf '0\n' > "/tmp/deck-test/$image.boot-other"
done
cat > /usr/bin/steamos-bootconf <<'MOCK'
#!/bin/bash
set -euo pipefail
if [[ $1 == this-image ]]; then cat /tmp/deck-test/image; exit; fi
[[ $1 == --image && $3 == config && $4 == --no-create ]] || exit 90
image=$2
shift 4
while (( $# )); do
  case "$1" in
    --get) printf '%s: %s\n' "$2" "$(cat "/tmp/deck-test/$image.$2")"; shift 2 ;;
    --set) printf '%s\n' "$3" > "/tmp/deck-test/$image.$2"; shift 3 ;;
    *) exit 91 ;;
  esac
done
MOCK
chmod 755 /usr/bin/steamos-bootconf
cat > /tmp/deck-test/run <<'RUN'
#!/bin/bash
set -euo pipefail
source "$PROJECT/steamdeck-hibernate-apply.sh"
# Only hardware/OS probing and system commands are replaced. The entire actual
# main apply sequence, file writes, settings, copies and failures remain real.
preflight() { assert_trusted_state; }
findmnt() { printf '12345678-abcd-1234-5678-123456789abc\n'; }
filefrag() { [[ $# == 3 && $1 == -b4096 && $2 == -v && $3 == /home/swapfile ]] || return 64; printf ' 0: 0.. 1023: 12345.. 13368: 1024: last,eof\n'; }
blkid() { printf 'swap\n'; }
swapon() {
  if [[ ${1:-} == --show=NAME ]]; then
    [[ ! -f /tmp/deck-test/active ]] || printf '/home/swapfile\n'
  else touch /tmp/deck-test/active; fi
}
sysctl() {
  if [[ $1 == -n ]]; then cat /tmp/deck-test/swappiness
  else printf '1\n' > /tmp/deck-test/swappiness; fi
}
systemctl() {
  case "$1" in
    is-enabled) [[ -f /tmp/deck-test/enabled ]] ;;
    enable) touch /tmp/deck-test/enabled ;;
    daemon-reload) [[ ! -f /tmp/deck-test/fail-reload ]] ;;
    *) return 0 ;;
  esac
}
systemd-analyze() {
  cat /etc/systemd/sleep.conf.d/zzz-steamdeck-hibernate.conf
  [[ ! -f /tmp/deck-test/override-sleep ]] || printf '[Sleep]\nAllowHibernation=no\n'
}
update-grub() {
  if [[ ${1:-} == --help ]]; then
    printf 'Run grub-mkconfig and place output at /efi/EFI/steamos/grub.cfg\n'; return
  fi
  if [[ -f /tmp/deck-test/fail-grub ]]; then
    printf 'truncated\n' > /efi/EFI/steamos/grub.cfg; return 17
  fi
  printf 'steamenv_boot   linux /vmlinuz quiet resume=UUID=%s resume_offset=%s\n' "$RESUME_UUID" "$RESUME_OFFSET" > /efi/EFI/steamos/grub.cfg
}
runtime_resume_matches() { [[ -f /tmp/deck-test/runtime-ready ]]; }
main "$@"
RUN
chmod +x /tmp/deck-test/run
run_apply() { /tmp/deck-test/run "$@" > /tmp/deck-test/output 2>&1 || { cat /tmp/deck-test/output; return 1; }; }
reject_apply() {
  # Actual separate shell process preserves errexit behavior in production.
  set +e
  /tmp/deck-test/run "$@" > /tmp/deck-test/output 2>&1
  result=$?
  set -e
  (( result != 0 )) || { cat /tmp/deck-test/output; echo 'Expected nonzero exit' >&2; exit 1; }
}
snapshot() {
  find /etc/default /etc/systemd /etc/sysctl.d /var/lib/steamdeck-hibernate /boot/grub /efi -type f ! -name apply.lock -exec sha256sum {} + | sort
  stat -c '%s:%a:%u:%g' /home/swapfile
  cat /etc/fstab
}
# First run migrates the old redirect, repairs existing counter + demotion,
# preserves swap and defers automatic hibernate until the kernel is ready.
mkdir -p /etc/systemd/system
ln -s /usr/lib/systemd/system/systemd-suspend-then-hibernate.service /etc/systemd/system/systemd-suspend.service
run_apply --delay 90min
[[ $(stat -c %s /home/swapfile) == 17179869184 ]]
[[ ! -e /etc/systemd/system/systemd-suspend.service ]]
[[ ! -e /etc/systemd/system/systemd-suspend.service.d/steamdeck-hibernate.conf ]]
[[ $(cat /tmp/deck-test/B.boot-attempts) == 0 && $(cat /tmp/deck-test/B.image-invalid) == 0 ]]
[[ $(cat /tmp/deck-test/A.boot-attempts) == 16 && $(cat /tmp/deck-test/A.image-invalid) == 1 ]]
grep -Fxq 'delay=90min' /var/lib/steamdeck-hibernate/settings
printf 'ok - full first apply, legacy migration, swap preserved, current-image repair\n'
# Model reboot into the new kernel; saved preferences automatically apply.
touch /tmp/deck-test/runtime-ready
run_apply --boot
grep -Fq -- '--sleep-request' /etc/systemd/system/systemd-suspend.service.d/steamdeck-hibernate.conf
run_apply --check
snapshot > /tmp/deck-test/before
run_apply
snapshot > /tmp/deck-test/after
cmp /tmp/deck-test/before /tmp/deck-test/after
printf 'ok - boot activation, read-only check and content-idempotent repeated apply\n'
# SteamOS update removes managed /etc files but retains persistent state.
rm /etc/systemd/sleep.conf.d/zzz-steamdeck-hibernate.conf
rm /etc/systemd/system/systemd-hibernate.service.d/steamdeck-boot-success.conf
rm /etc/systemd/system/systemd-suspend.service.d/steamdeck-hibernate.conf
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet updated_os=1"\n' > /etc/default/grub
run_apply
grep -Fxq 'HibernateDelaySec=90min' /etc/systemd/sleep.conf.d/zzz-steamdeck-hibernate.conf
grep -q updated_os=1 /etc/default/grub
[[ -f /etc/systemd/system/systemd-hibernate.service.d/steamdeck-boot-success.conf ]]
printf 'ok - simulated SteamOS update restores settings and services\n'
# A stale current boot entry cannot be hidden by a correct older entry.
printf 'steamenv_boot linux /vmlinuz quiet\nsteamenv_boot linux /old resume=UUID=12345678-abcd-1234-5678-123456789abc resume_offset=12345\n' > /efi/EFI/steamos/grub.cfg
reject_apply --check
run_apply
# Dry run from healthy state and drift state changes zero configuration bytes.
snapshot > /tmp/deck-test/before
run_apply --dry-run --delay 2h
snapshot > /tmp/deck-test/after
cmp /tmp/deck-test/before /tmp/deck-test/after
rm /tmp/deck-test/active
reject_apply --check
run_apply
printf 'ok - stale default detection, dry-run purity, inactive swap check\n'
snapshot > /tmp/deck-test/before
touch /home/.hibernation.metadata
reject_apply
snapshot > /tmp/deck-test/after
cmp /tmp/deck-test/before /tmp/deck-test/after
rm /home/.hibernation.metadata
grep -Fxq 'ConditionPathExists=!/var/lib/steamdeck-hibernate/settings' /etc/systemd/system/hibernate-prepare.service.d/steamdeck-hibernate.conf
printf 'ok - native temporary-swap conflict blocks writes and coexistence drop-in installed\n'
# An overriding effective sleep setting must fail visibly, including check.
touch /tmp/deck-test/override-sleep
reject_apply --check
reject_apply
rm /tmp/deck-test/override-sleep
run_apply
# Every redirected sleep checks actual readiness even if boot repair failed.
/tmp/deck-test/run --resume-ready
rm /tmp/deck-test/runtime-ready
reject_apply --resume-ready
touch /tmp/deck-test/runtime-ready
printf 'ok - effective sleep overrides rejected and per-sleep readiness guarded\n'
# Whole process must stop at failed generation/reload, with no success message.
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet changed=1"\n' > /etc/default/grub
cp /etc/default/grub /tmp/deck-test/grub-before
cp /efi/EFI/steamos/grub.cfg /tmp/deck-test/cfg-before
touch /tmp/deck-test/fail-grub
reject_apply
cmp /etc/default/grub /tmp/deck-test/grub-before
cmp /efi/EFI/steamos/grub.cfg /tmp/deck-test/cfg-before
rm /tmp/deck-test/fail-grub
touch /tmp/deck-test/fail-reload
reject_apply
if grep -q 'Hibernation settings reconciled' /tmp/deck-test/output; then echo 'False success after failure' >&2; exit 1; fi
rm /tmp/deck-test/fail-reload
run_apply --no-sth
[[ ! -e /etc/systemd/system/systemd-suspend.service.d/steamdeck-hibernate.conf ]]
run_apply --boot
[[ ! -e /etc/systemd/system/systemd-suspend.service.d/steamdeck-hibernate.conf ]]
printf 'ok - subprocess failure propagation, GRUB rollback, no-STH preference retained\n'
# The configured delay must be visible to the user after apply AND --check.
run_apply --delay 15min
grep -Fq 'HibernateDelaySec=15min (saved; effective sleep configuration verified)' /tmp/deck-test/output
run_apply --check
grep -Fq 'HibernateDelaySec=15min (saved value matches effective sleep configuration)' /tmp/deck-test/output
run_apply --dry-run --delay 2h
grep -Fq 'Requested HibernateDelaySec=2h (dry-run; not applied)' /tmp/deck-test/output
grep -Fxq 'delay=15min' /var/lib/steamdeck-hibernate/settings
grep -Fxq 'HibernateDelaySec=15min' /etc/systemd/sleep.conf.d/zzz-steamdeck-hibernate.conf
printf 'ok - apply/check display verified delay; dry-run displays intent and preserves saved delay\n'
printf 'PASS: Linux full reconciliation integration\n'
