#!/usr/bin/env bash
# Reconcile Steam Deck hibernation after SteamOS updates. No network access.
set -euo pipefail

STATE_DIR=/var/lib/steamdeck-hibernate
SETTINGS_FILE=$STATE_DIR/settings
SELF_PATH=$STATE_DIR/steamdeck-hibernate-apply.sh
SWAPFILE=/home/swapfile
GRUB_FILE=/etc/default/grub
GRUB_CFG=/boot/grub/grub.cfg
SLEEP_DROPIN=/etc/systemd/sleep.conf.d/zzz-steamdeck-hibernate.conf
LOGIND_DROPIN=/etc/systemd/system/systemd-logind.service.d/steamdeck-hibernate.conf
SUSPEND_DROPIN=/etc/systemd/system/systemd-suspend.service.d/steamdeck-hibernate.conf
SUSPEND_LINK=/etc/systemd/system/systemd-suspend.service
REAPPLY_SERVICE=/etc/systemd/system/steamdeck-hibernate-reapply.service
DRY_RUN=0
BOOT_MODE=0
CHECK_ONLY=0
DELAY=60min
SIZE_GIB=20
STH=1
SIZE_EXPLICIT=0
DELAY_OVERRIDE=
SIZE_OVERRIDE=
STH_OVERRIDE=
REBOOT_REQUIRED=0

info() { printf '[*] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
run() { if (( DRY_RUN )); then printf '[dry-run]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }

usage() {
  cat <<'USAGE'
Usage: sudo ./steamdeck-hibernate-apply.sh [options]
  --dry-run       Inspect and print changes; write nothing.
  --check         Read-only verification; nonzero if repair/reboot is needed.
  --delay TIME    Delay before hibernation, e.g. 60min, 2h (saved).
  --size GiB      Size for NEW swapfile (16..128); existing swap is never resized.
  --no-sth        Keep normal suspend (saved).
  --enable-sth    Redirect suspend to suspend-then-hibernate (default, saved).
  --boot          Internal boot reconciliation; never suspend or reboot.
  --help          Show help.
Keep steamdeck-boot-success.sh beside this file.
Existing swap must be at least 16 GiB. Changes to resume parameters require reboot.
USAGE
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes|-y) : ;;
      --check) CHECK_ONLY=1; DRY_RUN=1 ;;
      --boot) BOOT_MODE=1 ;;
      --delay) (( $# >= 2 )) || fail '--delay needs a value'; DELAY_OVERRIDE=$2; shift ;;
      --size) (( $# >= 2 )) || fail '--size needs a value'; SIZE_OVERRIDE=$2; SIZE_EXPLICIT=1; shift ;;
      --no-sth) STH_OVERRIDE=0 ;;
      --enable-sth) STH_OVERRIDE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) fail "Unknown argument: $1" ;;
    esac
    shift
  done
}

validate_settings() {
  [[ $DELAY =~ ^[1-9][0-9]*(s|min|h|d)$ ]] || fail "Invalid delay: $DELAY (use e.g. 60min or 2h)"
  if [[ ! $SIZE_GIB =~ ^[1-9][0-9]{1,2}$ ]] || (( SIZE_GIB < 16 || SIZE_GIB > 128 )); then fail 'Swap size must be 16..128 GiB'; fi
  [[ $STH == 0 || $STH == 1 ]] || fail 'Invalid saved STH setting'
}

load_settings() {
  if [[ -e $SETTINGS_FILE || -L $SETTINGS_FILE ]]; then
    [[ -f $SETTINGS_FILE && ! -L $SETTINGS_FILE ]] || fail "Unsafe settings file: $SETTINGS_FILE"
    local key val seen=' '
    while IFS='=' read -r key val || [[ -n $key ]]; do
      [[ -n $key ]] || continue
      [[ $seen != *" $key "* ]] || fail "Duplicate saved setting: $key"
      seen+="$key "
      case "$key" in
        delay) DELAY=$val ;;
        size_gib) SIZE_GIB=$val ;;
        sth) STH=$val ;;
        *) fail "Unknown saved setting: $key" ;;
      esac
    done < "$SETTINGS_FILE"
  fi
  [[ -z $DELAY_OVERRIDE ]] || DELAY=$DELAY_OVERRIDE
  [[ -z $SIZE_OVERRIDE ]] || SIZE_GIB=$SIZE_OVERRIDE
  [[ -z $STH_OVERRIDE ]] || STH=$STH_OVERRIDE
  validate_settings
}

# Atomic, content-aware replacement. Never follow a target symlink.
write_file() {
  local path=$1 mode=$2 content=$3 tmp backup
  [[ ! -L $path ]] || fail "Refusing to replace symlink: $path"
  if [[ -f $path ]] && cmp -s "$path" <(printf '%s\n' "$content"); then
    if [[ $(stat -c %u "$path") == 0 && $(stat -c %g "$path") == 0 && $(stat -c %a "$path") == "$mode" ]]; then return 0; fi
    info "Repair owner/mode of $path"
    if (( CHECK_ONLY )); then return 1; fi
    run chown 0:0 "$path"
    run chmod "$mode" "$path"
    return 0
  fi
  info "Update $path"
  if (( CHECK_ONLY )); then return 1; fi
  if (( DRY_RUN )); then return 0; fi
  mkdir -p "$(dirname "$path")"
  if [[ -e $path ]]; then
    backup="$STATE_DIR/backups/${path#/}"
    mkdir -p "$(dirname "$backup")"
    # Keep the original before the first change, rather than backing up our last output.
    [[ -e $backup ]] || cp -a -- "$path" "$backup"
  fi
  tmp=$(mktemp "$(dirname "$path")/.steamdeck-hibernate.XXXXXX")
  printf '%s\n' "$content" > "$tmp"
  chmod "$mode" "$tmp"
  chown 0:0 "$tmp"
  mv -f -- "$tmp" "$path"
}

assert_trusted_state() {
  local p owner perm
  for p in "$STATE_DIR" "$SETTINGS_FILE" "$SELF_PATH" "$STATE_DIR/steamdeck-boot-success.sh" "$STATE_DIR/fix-bluetooth-resume.sh"; do
    [[ -e $p || -L $p ]] || continue
    [[ ! -L $p ]] || fail "Refusing symlink in privileged state: $p"
    owner=$(stat -c %u "$p")
    perm=$(stat -c %a "$p")
    if [[ $owner != 0 ]] || (( (8#$perm & 0022) != 0 )); then fail "State must be root-owned, without group/other write: $p"; fi
  done
}

preflight() {
  [[ $EUID == 0 ]] || fail "Run with sudo: sudo $0"
  [[ $(uname -s) == Linux ]] || fail 'This script requires SteamOS Linux'
  local product os_id
  product=$(cat /sys/class/dmi/id/product_name)
  case "$product" in Jupiter|Galileo|'Steam Deck'|'Steam Deck OLED') ;; *) fail "Unsupported hardware: $product" ;; esac
  os_id=$(awk -F= '$1=="ID" {gsub(/"/,"",$2); print $2}' /etc/os-release)
  [[ $os_id == steamos ]] || fail "Unsupported operating system: $os_id"
  local tool
  for tool in findmnt filefrag getconf stat swapon mkswap dd df awk grep sed cmp mktemp install flock systemctl chown chmod mv cp blkid sysctl systemd-analyze; do
    command -v "$tool" >/dev/null || fail "Missing required tool: $tool"
  done
  [[ $(findmnt -n -o FSTYPE -T /home) == ext4 ]] || fail '/home must use ext4; BTRFS is unsupported by this script'
  [[ ! -L $SWAPFILE ]] || fail 'Refusing a symlink swapfile'
  [[ -f $GRUB_FILE && ! -L $GRUB_FILE ]] || fail "Missing or unsafe GRUB defaults: $GRUB_FILE"
  [[ -x /usr/lib/systemd/systemd-sleep ]] || fail 'systemd-sleep not found'
  if ! command -v update-grub >/dev/null && ! command -v grub-mkconfig >/dev/null; then fail 'update-grub or grub-mkconfig is required'; fi
  assert_trusted_state
  detect_grub_config
}

ensure_swap() {
  local bytes available min_bytes=$((16 * 1024 * 1024 * 1024))
  if [[ -e $SWAPFILE ]]; then
    [[ -f $SWAPFILE ]] || fail "Not a regular swapfile: $SWAPFILE"
    bytes=$(stat -c %s "$SWAPFILE")
    (( bytes >= min_bytes )) || fail 'Existing swap is smaller than 16 GiB. Resize it explicitly with CryoUtilities; no automatic destructive resize is performed.'
    if (( SIZE_EXPLICIT && bytes < SIZE_GIB * 1024 * 1024 * 1024 )); then
      fail 'Existing swap is smaller than --size. Resize it explicitly; this command never resizes existing swap.'
    fi
    info "Keeping existing swapfile ($((bytes / 1024 / 1024 / 1024)) GiB)"
    [[ $(blkid -p -s TYPE -o value "$SWAPFILE") == swap ]] || fail 'Existing /home/swapfile does not contain a recognized swap signature'
  else
    available=$(df -Pk /home | awk 'NR==2 {print $4}')
    (( available >= SIZE_GIB * 1024 * 1024 + 1024 * 1024 )) || fail "Not enough space for ${SIZE_GIB} GiB swap plus 1 GiB reserve"
    if (( DRY_RUN )); then
      info "Would create ${SIZE_GIB} GiB swap; resume parameters cannot be computed until it exists"
      fail 'Create the missing swapfile before a complete read-only preview (or run apply without --dry-run)'
    fi
    # noclobber prevents accidentally truncating a file created since the check.
    (set -o noclobber; umask 077; : > "$SWAPFILE") || fail 'Swapfile appeared concurrently'
    if ! dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SIZE_GIB * 1024)) conv=fsync status=progress; then
      rm -f -- "$SWAPFILE"; fail 'Creating swapfile failed'
    fi
    mkswap "$SWAPFILE" || fail 'mkswap failed; file retained for inspection'
  fi
  if [[ $(stat -c %a "$SWAPFILE") != 600 || $(stat -c %u "$SWAPFILE") != 0 || $(stat -c %g "$SWAPFILE") != 0 ]]; then
    if (( CHECK_ONLY )); then fail 'Swapfile owner/mode needs repair (root:root, 600)'; fi
    run chmod 600 "$SWAPFILE"
    run chown 0:0 "$SWAPFILE"
  fi
  if ! swapon --show=NAME --noheadings --raw | grep -Fxq "$SWAPFILE"; then
    if (( CHECK_ONLY )); then fail 'Swapfile is not active'; fi
    run swapon "$SWAPFILE"
  fi
}

ensure_fstab() {
  local content
  content=$(awk -v swap="$SWAPFILE" '
    /^[[:space:]]*#/ || NF==0 {print; next}
    $1==swap {if ($3!="swap") exit 42; found=1}
    {print}
    END {if (!found) print swap " none swap defaults 0 0"}
  ' /etc/fstab) || fail 'Conflicting swapfile entry in /etc/fstab'
  write_file /etc/fstab 644 "$content"
}

resume_values() {
  local page_size
  page_size=$(getconf PAGESIZE)
  [[ $page_size =~ ^[1-9][0-9]*$ ]] || fail 'Could not determine PAGE_SIZE'
  RESUME_UUID=$(findmnt -n -o UUID -T "$SWAPFILE")
  [[ $RESUME_UUID =~ ^[a-fA-F0-9-]+$ ]] || fail 'Invalid swap backing filesystem UUID'
  # Kernel resume_offset is in PAGE_SIZE units, not filesystem-block units.
  RESUME_OFFSET=$(LC_ALL=C filefrag -b "$page_size" -v "$SWAPFILE" | awk '
    $1=="0:" {
      if ($2!="0.." || $4 !~ /^[0-9]+\.\.$/ || $0 ~ /unwritten|delalloc|unknown_loc|inline/) exit 42
      split($4,a,"."); print a[1]; found=1
    }
    END {if (!found) exit 42}
  ') || fail 'Swap header extent is missing, sparse, unwritten, or cannot be resolved'
  [[ $RESUME_OFFSET =~ ^[1-9][0-9]*$ ]] || fail 'Unable to read first swap extent in PAGE_SIZE units'
}

# Conservative parser: do not evaluate shell syntax in /etc/default/grub.
render_grub() {
  awk -v uuid="$RESUME_UUID" -v offset="$RESUME_OFFSET" '
    BEGIN {found=0}
    /^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT[[:space:]]*=/ {
      if (++found > 1) exit 42
      line=$0
      if (line !~ /^GRUB_CMDLINE_LINUX_DEFAULT="[^"\\$`]*"[[:space:]]*$/) exit 42
      sub(/^GRUB_CMDLINE_LINUX_DEFAULT="/,"",line); sub(/"[[:space:]]*$/,"",line)
      n=split(line,args,/[[:space:]]+/); out=""
      for (i=1;i<=n;i++) if (args[i]!="" && args[i] !~ /^resume=/ && args[i] !~ /^resume_offset=/) out=out args[i] " "
      print "GRUB_CMDLINE_LINUX_DEFAULT=\"" out "resume=UUID=" uuid " resume_offset=" offset "\""
      next
    }
    {print}
    END {if (!found) print "GRUB_CMDLINE_LINUX_DEFAULT=\"resume=UUID=" uuid " resume_offset=" offset "\""}
  ' "$GRUB_FILE"
}

grub_linux_commands() {
  # SteamOS 10_linux emits "steamenv_boot linux ...". Normalize only this
  # known wrapper or a direct Linux command; never evaluate GRUB expressions.
  awk '
    {
      first=1
      if ($first=="steamenv_boot") first++
      if (($first!="linux" && $first!="linuxefi") || NF<=first) next
      if ($(first+1) ~ /^#/) next
      for (i=first;i<=NF;i++) {
        if ($i ~ /^#/) break
        printf "%s%s", (i==first ? "" : " "), $i
      }
      printf "\n"
    }
  ' "$1"
}

grub_has_linux() {
  grub_linux_commands "$1" | awk 'NF {found=1} END {exit !found}'
}

grub_has_resume() {
  # Match both exact tokens on the SAME generated Linux command, not comments
  # or a resume argument in some unrelated menu entry.
  grub_linux_commands "$GRUB_CFG" | awk -v uuid="$RESUME_UUID" -v offset="$RESUME_OFFSET" '
    {
      device=0; position=0; recovery=0
      for (i=2;i<=NF;i++) if ($i=="noresume" || $i=="single" || $i=="recovery" || $i=="systemd.unit=rescue.target") recovery=1
      if (recovery) next
      for (i=2;i<=NF;i++) {
        if ($i=="resume=UUID=" uuid || $i=="resume=/dev/disk/by-uuid/" uuid) device=1
        if ($i=="resume_offset=" offset) position=1
      }
      # Every Linux entry must agree; a stale default must not be masked by an old entry.
      found=1
      if (!device || !position) bad=1
    }
    END {exit (!found || bad)}
  '
}

supported_grub_configs() {
  # The first location is used by Valve steamos-customizations/update-grub.
  # /boot/grub/grub.cfg may be only a forwarding stub and is never selected
  # unless it contains actual Linux boot commands.
  printf '%s\n' /efi/EFI/steamos/grub.cfg /efi/EFI/SteamOS/grub.cfg /boot/efi/EFI/steamos/grub.cfg /boot/efi/EFI/SteamOS/grub.cfg /boot/grub/grub.cfg
}

detect_grub_config() {
  local help='' advertised='' candidate found='' count=0 allowed=0
  if command -v update-grub >/dev/null; then
    help=$(LC_ALL=C update-grub --help 2>/dev/null) || fail 'Cannot inspect update-grub output path with --help'
    advertised=$(printf '%s\n' "$help" | awk '
      /Run grub-mkconfig and place output at / {print $NF}
    ')
    if [[ -n $advertised ]]; then
      [[ $advertised != *$'\n'* ]] || fail 'update-grub advertises multiple configuration paths'
      while IFS= read -r candidate; do
        [[ $advertised != "$candidate" ]] || allowed=1
      done < <(supported_grub_configs)
      (( allowed )) || fail "Unsupported update-grub output path: $advertised"
      found=$advertised
    fi
  fi
  if [[ -z $found ]]; then
    while IFS= read -r candidate; do
      if [[ -f $candidate && ! -L $candidate ]] && grub_has_linux "$candidate"; then
        # FAT paths can differ only by case or mount aliases. Count each file once.
        if [[ -z $found || ! $candidate -ef $found ]]; then
          found=$candidate
          count=$((count + 1))
        fi
      fi
    done < <(supported_grub_configs)
    (( count == 1 )) || fail 'Cannot uniquely identify generated GRUB config (missing, forwarding-only, or ambiguous boot layout)'
  fi
  [[ -f $found && ! -L $found && -r $found ]] || fail "Generated GRUB configuration is missing or unsafe: $found"
  grub_has_linux "$found" || fail "GRUB configuration has no supported Linux boot command (linux/linuxefi or steamenv_boot linux/linuxefi): $found"
  if (( ! DRY_RUN )); then
    [[ -w $found && -w $(dirname "$found") ]] || fail "GRUB configuration is not writable: $found"
  fi
  GRUB_CFG=$found
  info "Using generated GRUB configuration: $GRUB_CFG"
}

configure_grub() {
  local content previous changed=0 cfg_backup='' defaults_mode cfg_mode
  # Resolve and validate output before making any change to defaults.
  detect_grub_config
  defaults_mode=$(stat -c %a "$GRUB_FILE")
  cfg_mode=$(stat -c %a "$GRUB_CFG")
  content=$(render_grub) || fail 'Ambiguous GRUB_CMDLINE_LINUX_DEFAULT syntax; refusing to rewrite it'
  if cmp -s "$GRUB_FILE" <(printf '%s\n' "$content"); then
    info 'GRUB resume defaults already correct'
  else
    previous=$(cat "$GRUB_FILE")
    changed=1
    write_file "$GRUB_FILE" "$defaults_mode" "$content"
  fi
  if (( changed )) || ! grub_has_resume; then
    if (( CHECK_ONLY )); then info 'Generated GRUB configuration needs repair'; return 1; fi
    if (( DRY_RUN )); then info "Would regenerate $GRUB_CFG"; return 0; fi
    cfg_backup=$(mktemp "$(dirname "$GRUB_CFG")/.grub.cfg.backup.XXXXXX")
    # Plain content copy works on the FAT EFI filesystem: Unix ownership/xattrs
    # cannot be preserved there with cp -a.
    cp -- "$GRUB_CFG" "$cfg_backup"
    local generated=0
    if command -v update-grub >/dev/null; then
      if update-grub; then generated=1; fi
    else
      if grub-mkconfig -o "$GRUB_CFG"; then generated=1; fi
    fi
    if (( ! generated )) || ! grub_has_resume; then
      cp -- "$cfg_backup" "$GRUB_CFG"
      chmod "$cfg_mode" "$GRUB_CFG"
      rm -f -- "$cfg_backup"
      [[ -z ${previous+x} ]] || write_file "$GRUB_FILE" "$defaults_mode" "$previous"
      fail 'GRUB generation failed or omitted resume parameters; previous defaults and grub.cfg restored. Inspect boot configuration before reboot.'
    fi
    rm -f -- "$cfg_backup"
  fi
}

runtime_resume_matches() {
  local args word uuid='' offset=''
  args=$(cat /proc/cmdline)
  for word in $args; do
    case "$word" in resume=UUID=*) uuid=${word#resume=UUID=} ;; resume=/dev/disk/by-uuid/*) uuid=${word##*/} ;; resume_offset=*) offset=${word#resume_offset=} ;; esac
  done
  [[ $uuid == "$RESUME_UUID" && $offset == "$RESUME_OFFSET" ]]
}

configure_swappiness() {
  write_file /etc/sysctl.d/zz-steamdeck-hibernate.conf 644 'vm.swappiness=1'
  if [[ $(sysctl -n vm.swappiness) != 1 ]]; then
    if (( CHECK_ONLY )); then fail 'Runtime vm.swappiness needs repair'; fi
    run sysctl -w vm.swappiness=1
  fi
}

configure_sleep() {
  write_file "$SLEEP_DROPIN" 644 "[Sleep]
AllowSuspend=yes
AllowHibernation=yes
AllowSuspendThenHibernate=yes
HibernateDelaySec=$DELAY
SuspendState=mem"
  write_file "$LOGIND_DROPIN" 644 '[Service]
Environment=SYSTEMD_BYPASS_HIBERNATION_MEMORY_CHECK=1'
  local service
  for service in systemd-hibernate.service systemd-suspend-then-hibernate.service; do
    write_file "/etc/systemd/system/$service.d/steamdeck-hibernate.conf" 644 '[Service]
Environment=SYSTEMD_BYPASS_HIBERNATION_MEMORY_CHECK=1'
    write_file "/etc/systemd/system/$service.d/steamdeck-resume-guard.conf" 644 "[Service]
ExecCondition=$SELF_PATH --resume-ready"
  done
}

# Read-only preflight. Optional filesystem prefix is only for fixture tests.
# Call before ensure_swap/configuration writes, and from resume_ready's subshell.
native_conflict_check() {
  local prefix=${1:-} metadata active_state
  prefix=${prefix%/}
  metadata="$prefix/home/.hibernation.metadata"
  if [[ -e $metadata || -L $metadata ]]; then
    printf '%s\n' \
      'SteamOS native temporary-hibernation metadata is still present.' \
      'Finish/resume the native hibernation session, or reboot normally and inspect:' \
      '  sudo /usr/lib/holo/hibernate-swap-helper.sh status' \
      'Resolve this native state before rerunning apply. Do not delete or swapoff an active swapfile.' >&2
    fail 'Refusing to replace resume settings while native hibernation metadata exists'
  fi
  [[ -r "$prefix/proc/swaps" ]] || fail 'Cannot inspect active swap before configuring hibernation'
  if awk 'NR > 1 && $1 == "/home/hibernation.swapfile" { found=1 } END { exit !found }' "$prefix/proc/swaps"; then
    fail 'Native /home/hibernation.swapfile is active; finish the native session or reboot before applying persistent hibernation'
  fi
  # A native create operation may not have written its metadata yet. On a live
  # system, refuse to race it. Fixture tests pass a prefix instead of probing
  # the host systemd instance.
  if [[ -z $prefix ]]; then
    active_state=$(systemctl show --property=ActiveState --value hibernate-prepare.service 2>/dev/null || true)
    case "$active_state" in
      activating|active|deactivating)
        fail 'SteamOS hibernate-prepare.service is running; retry after the native sleep operation has completed' ;;
    esac
  fi
}

# Narrow coexistence override: keep the native unit and its vendor contents,
# but skip its temporary-swap preparation while our persistent settings exist.
# write_file already implements atomic replacement, backups, --check/dry-run.
configure_native_hibernate() {
  write_file /etc/systemd/system/hibernate-prepare.service.d/steamdeck-hibernate.conf 644 '[Unit]
# Persistent /home/swapfile resume is owned by steamdeck-hibernate.
# Without this marker, SteamOS native temporary-swap preparation remains enabled.
ConditionPathExists=!/var/lib/steamdeck-hibernate/settings'
}

check_effective_sleep() {
  local effective key value expected
  effective=$(systemd-analyze cat-config systemd/sleep.conf) || fail 'Cannot inspect effective systemd sleep configuration'
  for key in AllowSuspend AllowHibernation AllowSuspendThenHibernate HibernateDelaySec; do
    value=$(printf '%s\n' "$effective" | awk -F= -v key="$key" '
      /^[[:space:]]*\[/ {in_sleep=($0 ~ /^[[:space:]]*\[Sleep\][[:space:]]*$/)}
      in_sleep && $0 !~ /^[[:space:]]*[#;]/ {
        k=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
        if (k==key) {v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); result=v}
      }
      END {print result}
    ')
    expected=yes
    [[ $key != HibernateDelaySec ]] || expected=$DELAY
    [[ $value == "$expected" ]] || fail "Effective $key=$value overrides expected $expected. Inspect: systemd-analyze cat-config systemd/sleep.conf"
  done
}

configure_sth() {
  if [[ -L $SUSPEND_LINK ]]; then
    [[ $(readlink "$SUSPEND_LINK") == /usr/lib/systemd/system/systemd-suspend-then-hibernate.service ]] || fail "Unrecognized suspend override: $SUSPEND_LINK"
    if (( CHECK_ONLY )); then info 'Legacy STH symlink needs migration'; return 1; fi
    run rm -- "$SUSPEND_LINK"
  elif [[ -e $SUSPEND_LINK ]]; then
    fail "Unmanaged suspend unit exists: $SUSPEND_LINK"
  fi
  if (( STH )) && runtime_resume_matches; then
    write_file "$SUSPEND_DROPIN" 644 "[Service]
ExecStart=
ExecStart=$SELF_PATH --sleep-request
Environment=SYSTEMD_BYPASS_HIBERNATION_MEMORY_CHECK=1"
  else
    if (( STH )); then REBOOT_REQUIRED=1; info 'Resume parameters are not active yet; STH will be enabled by reconciliation after reboot'; fi
    if [[ -e $SUSPEND_DROPIN ]]; then
      if (( CHECK_ONLY )); then return 1; fi
      run rm -- "$SUSPEND_DROPIN"
    fi
  fi
}

install_persistence() {
  write_file "$SETTINGS_FILE" 600 "delay=$DELAY
size_gib=$SIZE_GIB
sth=$STH"
  if ! cmp -s "${BASH_SOURCE[0]}" "$SELF_PATH"; then
    if (( CHECK_ONLY )); then info 'Installed script needs update'; return 1; fi
    run install -m 755 "${BASH_SOURCE[0]}" "$SELF_PATH"
    run chown 0:0 "$SELF_PATH"
  elif [[ $(stat -c %a "$SELF_PATH") != 755 || $(stat -c %u "$SELF_PATH") != 0 || $(stat -c %g "$SELF_PATH") != 0 ]]; then
    if (( CHECK_ONLY )); then fail 'Installed script owner/mode needs repair'; fi
    run chown 0:0 "$SELF_PATH"
    run chmod 755 "$SELF_PATH"
  fi
  write_file "$REAPPLY_SERVICE" 644 "[Unit]
Description=Reconcile Steam Deck hibernation settings
After=local-fs.target systemd-sysctl.service
Before=suspend.target hibernate.target suspend-then-hibernate.target
RequiresMountsFor=/home /boot /efi /esp

[Service]
Type=oneshot
ExecStart=$SELF_PATH --boot

[Install]
WantedBy=multi-user.target"
  if ! systemctl is-enabled --quiet steamdeck-hibernate-reapply.service; then
    if (( CHECK_ONLY )); then info 'Reconciliation service is disabled'; return 1; fi
    run systemctl enable steamdeck-hibernate-reapply.service
  fi
}

boot_helper_source() {
  printf '%s/steamdeck-boot-success.sh\n' "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
}

apply_boot_fix() {
  local helper service
  helper=$(boot_helper_source)
  [[ -f $helper && ! -L $helper ]] || fail "Keep steamdeck-boot-success.sh beside this script"
  write_file "$STATE_DIR/steamdeck-boot-success.sh" 755 "$(cat "$helper")"
  for service in systemd-hibernate.service systemd-suspend-then-hibernate.service systemd-suspend.service; do
    write_file "/etc/systemd/system/$service.d/steamdeck-boot-success.conf" 644 "[Service]
ExecStartPost=$STATE_DIR/steamdeck-boot-success.sh --resume"
  done
}

configure_bluetooth() {
  # OLED QCA recovery is read-only unless an active Bluetooth service has no
  # working controller. Do not make the Deck discoverable as a health check.
  # shellcheck disable=SC2016 # Literal content for the installed helper.
  write_file "$STATE_DIR/fix-bluetooth-resume.sh" 755 '#!/bin/bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin
qca=/sys/bus/serial/drivers/hci_uart_qca
[[ -e "$qca/serial0-0" ]] || exit 0
systemctl is-active --quiet bluetooth.service || exit 0
command -v bluetoothctl >/dev/null || exit 0
timeout 5 bluetoothctl show >/dev/null 2>&1 && exit 0
printf "%s\n" "steamdeck-hibernate: recovering QCA Bluetooth controller" >&2
if printf "%s" serial0-0 > "$qca/unbind"; then
  sleep 1
  printf "%s" serial0-0 > "$qca/bind" || printf "%s\n" "Bluetooth rebind failed; inspect journal" >&2
fi
exit 0'
  local service
  for service in systemd-hibernate.service systemd-suspend-then-hibernate.service systemd-suspend.service; do
    write_file "/etc/systemd/system/$service.d/steamdeck-bluetooth.conf" 644 "[Service]
ExecStartPost=$STATE_DIR/fix-bluetooth-resume.sh"
  done
  # The v2 unit invokes a helper with the same name. Retire only our old unit,
  # preserving unrelated units with the same generic name.
  if [[ -f /etc/systemd/system/fix-bluetooth-resume.service ]] &&
     grep -Fq "ExecStart=$STATE_DIR/fix-bluetooth-resume.sh" /etc/systemd/system/fix-bluetooth-resume.service; then
    if (( CHECK_ONLY )); then fail 'Legacy Bluetooth service needs migration'; fi
    run systemctl disable fix-bluetooth-resume.service
    run rm -- /etc/systemd/system/fix-bluetooth-resume.service
  fi
}

resume_ready() {
  # Called on EVERY sleep, even if an update has removed or broken the boot
  # reconciliation unit. A stale redirect falls back to ordinary suspend.
  [[ $EUID == 0 && -f $SETTINGS_FILE ]] || return 1
  assert_trusted_state
  load_settings
  native_conflict_check ""
  [[ -f $SWAPFILE && ! -L $SWAPFILE ]] || return 1
  [[ $(stat -c %s "$SWAPFILE") -ge $((16 * 1024 * 1024 * 1024)) ]] || return 1
  [[ $(blkid -p -s TYPE -o value "$SWAPFILE") == swap ]] || return 1
  swapon --show=NAME --noheadings --raw | grep -Fxq "$SWAPFILE" || return 1
  [[ -f $SLEEP_DROPIN ]] || return 1
  grep -Fxq 'AllowHibernation=yes' "$SLEEP_DROPIN" || return 1
  resume_values
  check_effective_sleep
  runtime_resume_matches
}

sleep_request() {
  if (resume_ready && [[ $STH == 1 ]]); then
    exec /usr/lib/systemd/systemd-sleep suspend-then-hibernate
  fi
  printf '%s\n' 'steamdeck-hibernate: resume prerequisites changed; using ordinary suspend' >&2
  exec /usr/lib/systemd/systemd-sleep suspend
}

main() {
  PATH=/usr/sbin:/usr/bin:/sbin:/bin
  export PATH
  case "${1:-}" in
    --resume-ready) resume_ready; return ;;
    --sleep-request) sleep_request; return ;;
  esac
  parse_args "$@"
  preflight
  load_settings
  native_conflict_check ""
  local boot_helper
  boot_helper=$(boot_helper_source)
  [[ -f $boot_helper && ! -L $boot_helper ]] || fail 'Missing companion steamdeck-boot-success.sh'
  # Verify the installed SteamOS bootconf API BEFORE touching system files.
  bash "$boot_helper" --dry-run
  if (( ! DRY_RUN )); then
    mkdir -p "$STATE_DIR"
    chmod 755 "$STATE_DIR"
    exec 9>"$STATE_DIR/apply.lock"
    flock -n 9 || fail 'Another hibernation apply is running'
  fi
  ensure_swap
  resume_values
  configure_grub
  ensure_fstab
  configure_sleep
  configure_native_hibernate
  configure_swappiness
  apply_boot_fix
  configure_bluetooth
  configure_sth
  install_persistence
  run systemctl daemon-reload
  if (( ! DRY_RUN || CHECK_ONLY )); then check_effective_sleep; fi
  if (( CHECK_ONLY )); then
    bash "$boot_helper" --check
  elif (( ! DRY_RUN && ! BOOT_MODE )); then
    # The running system has completed all reconciliation checks. Clear its
    # demotion now as well as after resume, so the required reboot is safe.
    "$STATE_DIR/steamdeck-boot-success.sh" --mark-success
  fi
  if ! runtime_resume_matches; then REBOOT_REQUIRED=1; fi
  if (( CHECK_ONLY && REBOOT_REQUIRED )); then fail 'Reboot required: running kernel resume arguments differ'; fi
  if (( DRY_RUN )); then info 'Read-only inspection complete'
  elif (( REBOOT_REQUIRED )); then info 'Settings applied. Reboot required: sudo reboot (no automatic reboot).'
  else info 'Hibernation settings reconciled. Physical hibernate/resume still requires verification on the Deck.'; fi
  info 'BIOS settings (Quick Boot / UMA) require manual inspection; this script does not alter firmware.'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
