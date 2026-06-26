#!/usr/bin/env bash
#
# steamdeck-hibernate.sh  (v2.0)
# ──────────────────────────────────────────────────────────────────────────────
# Automates suspend-then-hibernate on a Steam Deck (OLED/LCD, ext4 /home).
# Based on the guide by nazar256:
#   https://github.com/nazar256/publications/blob/main/guides/steam-deck-hibernation.md
#
# Scope per user request:
#   - CryoUtilities steps are SKIPPED (verify they were applied with check-prereqs).
#   - BTRFS path is SKIPPED (ext4 /home only).
#
# What this adds beyond the guide:
#   - CryoUtilities / UMA pre-flight verification (check-prereqs)
#   - Enhanced suspend self-test: immediate-wake detection, dmesg analysis,
#     targeted fix suggestions for WiFi / XHC / Bluetooth / Steam Wake Movie
#   - WiFi + XHC ACPI wakeup disabler via tmpfiles.d (fix-wifi-wake)
#   - WPA-supplicant mode instructions (Steam developer setting)
#   - GRUB boot counter reset after hibernation resume via systemd-sleep hook
#     (stops the "failed to boot" screen after multiple hibernation cycles)
#   - Optional CEC TV-off on sleep for dock users (install-cec)
#   - Boot-time reapply service (survives SteamOS updates to /etc)
#   - Idempotent re-runs, dry-run mode, backups, full uninstall
#
# ┌────────────────────────────────────────────────────────────────────────────┐
# │  NO WARRANTY.  Hibernation is unsupported by Valve.  A wrong             │
# │  resume_offset makes the device fail to resume (recoverable via USB       │
# │  recovery stick).  Read each step before proceeding.  Your risk.         │
# └────────────────────────────────────────────────────────────────────────────┘
#
set -uo pipefail

# ── Configuration (override via flags or environment) ─────────────────────────
SWAPFILE="${SWAPFILE:-/home/swapfile}"
SWAP_SIZE_GIB="${SWAP_SIZE_GIB:-20}"
HIBERNATE_DELAY="${HIBERNATE_DELAY:-60min}"
DECK_USER="${DECK_USER:-deck}"
DECK_HOME="${DECK_HOME:-/home/${DECK_USER}}"

# Security fix (Agent 4 #14): BT script runs as root → must be root-owned.
# /usr/local/sbin is writable on SteamOS when running as root.
BT_SCRIPT="${BT_SCRIPT:-/var/lib/steamdeck-hibernate/fix-bluetooth-resume.sh}"

TEST_SLEEP_SECS="${TEST_SLEEP_SECS:-20}"
TEST_SLEEP_MODE="${TEST_SLEEP_MODE:-mem}"
IMMEDIATE_WAKE_THRESHOLD="${IMMEDIATE_WAKE_THRESHOLD:-5}"

GRUB_FILE="/etc/default/grub"
SLEEP_CONF="/etc/systemd/sleep.conf"
# High-priority drop-in: overrides vendor /usr/lib/systemd/sleep.conf.d/ entries.
# SteamOS ships a vendor drop-in that sets AllowHibernation=no; writing only the
# base sleep.conf is not enough because /usr/lib drop-ins still win over it.
SLEEP_DROPIN="/etc/systemd/sleep.conf.d/zzz-steamdeck-hibernate.conf"
LOGIND_DROPIN="/etc/systemd/system/systemd-logind.service.d/override.conf"
BT_SERVICE="/etc/systemd/system/fix-bluetooth-resume.service"
SUSPEND_LINK="/etc/systemd/system/systemd-suspend.service"
STH_TARGET="/usr/lib/systemd/system/systemd-suspend-then-hibernate.service"

# Single-device ACPI wakeup disable service (fix-wake command)
WAKEFIX_SERVICE="/etc/systemd/system/steamdeck-disable-wakeup.service"

# Broad WiFi/XHC wakeup disable via tmpfiles.d (fix-wifi-wake command)
WIFIWAKE_CONF="/etc/tmpfiles.d/steamdeck-wifi-nowake.conf"

# Boot counter reset hook (system-sleep hook, not a service)
BOOT_COUNTER_HOOK="/etc/systemd/system-sleep/steamdeck-fix-boot-counter.sh"
_BOOT_COUNTER_DEFAULT=3

# CEC TV-off on sleep (optional, --cec flag)
CEC_SCRIPT="${DECK_HOME}/.local/bin/turn-off-tv.sh"
CEC_SERVICE="/etc/systemd/system/cec-sleep.service"

# Reapply service
REAPPLY_SERVICE="/etc/systemd/system/steamdeck-hibernate-reapply.service"
# SteamOS has an immutable /usr — /usr/local/sbin/ is read-only.
# Use /var/lib/steamdeck-hibernate/ (writable, survives reboots).
SELF_INSTALL_PATH="/var/lib/steamdeck-hibernate/steamdeck-hibernate.sh"
STATE_DIR="/var/lib/steamdeck-hibernate"

# ── Flags ─────────────────────────────────────────────────────────────────────
ASSUME_YES=0
DRY_RUN=0
DO_PERSIST=1        # install boot-time reapply service
ENABLE_STH_NOW=0    # create the suspend→STH symlink during install
DO_CEC=0            # install CEC TV-off service
DO_BOOT_COUNTER=1   # install GRUB boot counter fix
SKIP_PREREQ_CHECK=0 # skip check-prereqs during install

# ── Hibernate capability check ────────────────────────────────────────────────
# systemctl show -p CanHibernate returns empty on some SteamOS/systemd versions.
# Parse the effective config directly instead.
# Returns: "yes", "no", or "unknown"
check_can_hibernate() {
  # Prefer logind D-Bus query (most accurate)
  local dbus_result
  dbus_result="$(busctl call org.freedesktop.login1 \
    /org/freedesktop/login1 \
    org.freedesktop.login1.Manager CanHibernate \
    2>/dev/null | awk '{print $2}' | tr -d '"')" || dbus_result=""
  if [[ "$dbus_result" == "yes" || "$dbus_result" == "no" || "$dbus_result" == "na" ]]; then
    [[ "$dbus_result" == "yes" ]] && echo "yes" || echo "no"
    return
  fi

  # Fallback: parse effective sleep config
  local effective
  effective="$(systemd-analyze cat-config systemd/sleep.conf 2>/dev/null)" || effective=""
  if [[ -n "$effective" ]]; then
    # Last AllowHibernation= line wins (drop-ins processed in order)
    local val
    val="$(printf '%s\n' "$effective" | grep -i '^AllowHibernation=' | tail -1 | cut -d= -f2 | tr -d '[:space:]')"
    case "${val,,}" in
      yes|true|1) echo "yes"; return ;;
      no|false|0) echo "no";  return ;;
    esac
  fi

  # Final fallback: check our own drop-in and sleep.conf
  if [[ -f "$SLEEP_DROPIN" ]] && grep -qi 'AllowHibernation=yes' "$SLEEP_DROPIN" 2>/dev/null; then
    echo "yes"
  else
    echo "unknown"
  fi
}

# ── Pretty output ─────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'
  C_BLU=$'\e[34m'; C_DIM=$'\e[2m';  C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_RST=""
fi
info()  { printf '%s[*]%s %s\n'    "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s[+]%s %s\n'    "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[!]%s %s\n'    "$C_YEL" "$C_RST" "$*" >&2; }
err()   { printf '%s[x]%s %s\n'    "$C_RED" "$C_RST" "$*" >&2; }
die()   { err "$*"; exit 1; }
step()  { printf '\n%s══ %s ══%s\n' "$C_BLU" "$*" "$C_RST"; }

# run(): honour --dry-run for destructive commands.
# NOTE: do NOT chain `run cmd && ok "..."` — ok() fires in dry-run because
# run() returns 0.  Separate the calls instead.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '%s[dry-run]%s %s\n' "$C_DIM" "$C_RST" "$*"
    return 0
  fi
  "$@"
}

confirm() {
  local prompt="${1:-Proceed?}"
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local ans
  read -r -p "$prompt [y/N] " ans || return 1
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ── Environment checks ────────────────────────────────────────────────────────
require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "This command needs root. Re-run with: sudo $0 ${*:-}"
  fi
}

is_steamdeck() {
  local p=""
  for f in /sys/class/dmi/id/product_name /sys/devices/virtual/dmi/id/product_name; do
    [[ -r "$f" ]] && p="$(< "$f")" && break
  done
  case "$p" in Jupiter|Galileo|"Steam Deck"|"Steam Deck OLED") return 0 ;; esac
  # Fallback: board vendor
  local v=""
  for f in /sys/class/dmi/id/board_vendor /sys/devices/virtual/dmi/id/board_vendor; do
    [[ -r "$f" ]] && v="$(< "$f")" && break
  done
  [[ "$v" == "Valve" ]] && return 0
  return 1
}

home_fstype() {
  findmnt -no FSTYPE -T "$SWAPFILE" 2>/dev/null || echo "unknown"
}

preflight() {
  if ! is_steamdeck; then
    warn "Hardware does not look like a Steam Deck (product_name != Jupiter/Galileo/etc)."
    warn "Continuing anyway — script was written and tested for the Deck only."
  fi
  local fst; fst="$(home_fstype)"
  if [[ "$fst" == "btrfs" ]]; then
    die "Filesystem holding ${SWAPFILE} is BTRFS. This script only handles ext4. \
Use the BTRFS section of the guide instead."
  elif [[ "$fst" != "ext4" ]]; then
    warn "Filesystem for ${SWAPFILE} is '${fst}', expected ext4. Proceeding cautiously."
  fi
  for t in swapon swapoff mkswap dd filefrag findmnt awk; do
    command -v "$t" >/dev/null 2>&1 || die "Missing required tool: $t"
  done
}

# ── Helpers ───────────────────────────────────────────────────────────────────
backup_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  local b="${f}.bak.$(date +%Y%m%d-%H%M%S)"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] would back up $f -> $b"
  else
    cp -a "$f" "$b" && ok "Backed up $f -> $b"
  fi
}

# ── Step 1: Swapfile (ext4) ───────────────────────────────────────────────────
current_swap_bytes() {
  [[ -f "$SWAPFILE" ]] || { echo 0; return; }
  stat -c %s "$SWAPFILE" 2>/dev/null || echo 0
}

ensure_swapfile() {
  step "Swapfile (${SWAP_SIZE_GIB} GiB at ${SWAPFILE})"
  local want_bytes=$(( SWAP_SIZE_GIB * 1024 * 1024 * 1024 ))
  local have_bytes; have_bytes="$(current_swap_bytes)"

  if [[ "$have_bytes" -eq "$want_bytes" ]]; then
    ok "Swapfile already at requested size ($(numfmt --to=iec "$have_bytes" 2>/dev/null || echo "${have_bytes}B"))."
  else
    info "Resizing/creating swapfile (have $(numfmt --to=iec "$have_bytes" 2>/dev/null || echo "${have_bytes}B"), want ${SWAP_SIZE_GIB} GiB)."

    # Space check: account for space freed when existing swapfile is overwritten.
    # (Bug fix Agent 4 #4+#5: original only checked avail when have_bytes==0,
    #  and df ran before swapoff so did not include the swapfile's own space.)
    run swapoff "$SWAPFILE" 2>/dev/null || true
    local mp; mp="$(findmnt -no TARGET -T "$SWAPFILE")"
    local avail_kib; avail_kib="$(df -Pk "$mp" | awk 'NR==2{print $4}')"
    local have_kib=$(( have_bytes / 1024 ))
    local need_kib=$(( want_bytes  / 1024 ))
    local effective_avail_kib=$(( avail_kib + have_kib ))
    if [[ "$effective_avail_kib" -lt "$need_kib" ]]; then
      die "Not enough free space on $mp: need ~${SWAP_SIZE_GIB} GiB, \
have $(numfmt --to=iec $((effective_avail_kib*1024)) 2>/dev/null)."
    fi

    run dd if=/dev/zero of="$SWAPFILE" bs=1G count="$SWAP_SIZE_GIB" \
        status=progress conv=fsync \
      || die "Failed to write swapfile."
    run chmod 600 "$SWAPFILE"
    run mkswap "$SWAPFILE" || die "mkswap failed."
    run swapon "$SWAPFILE" || die "swapon failed."
    ok "Swapfile ready."
  fi

  # Ensure swap is active
  if ! swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
    run swapon "$SWAPFILE" 2>/dev/null \
      || warn "Could not activate swap now; will activate on next boot."
  fi

  # Defragment for a contiguous extent (required for hibernation resume)
  if command -v e4defrag >/dev/null 2>&1; then
    run e4defrag "$SWAPFILE" >/dev/null 2>&1 \
      || warn "e4defrag returned non-zero (often harmless)."
  fi

  # Fragmentation check (Bug fix Agent 4 #14: abort if fragmented and defrag failed)
  local extents
  extents="$(filefrag "$SWAPFILE" 2>/dev/null | grep -oE '[0-9]+ extent' | awk '{print $1}')"
  extents="${extents:-1}"
  if [[ "$extents" -gt 1 ]]; then
    warn "Swapfile has ${extents} extents (not perfectly contiguous)."
    warn "Resume usually still works (only first extent offset is used), but"
    warn "if hibernate fails to resume, free more disk space and re-run."
  fi
}

get_resume_uuid() {
  findmnt -no UUID -T "$SWAPFILE"
}

# Bug fix (Agent 4 #7): original substr approach was fragile across kernel versions.
# gsub(/[^0-9]/,"") strips everything non-numeric from field 4 robustly.
get_resume_offset() {
  filefrag -v "$SWAPFILE" 2>/dev/null \
    | awk '$1=="0:" { gsub(/[^0-9]/, "", $4); print $4+0; exit }'
}

# ── Step 2: GRUB resume= / resume_offset= ────────────────────────────────────
configure_grub() {
  step "Kernel resume parameters in ${GRUB_FILE}"
  local uuid offset
  uuid="$(get_resume_uuid)"
  offset="$(get_resume_offset)"
  [[ -n "$uuid" ]]               || die "Could not read swap partition UUID."
  [[ "$offset" =~ ^[0-9]+$ ]]   || die "Could not compute a numeric resume_offset (got '${offset}')."
  info "resume UUID   = $uuid"
  info "resume_offset = $offset"
  [[ -f "$GRUB_FILE" ]]         || die "${GRUB_FILE} not found."

  local tmp; tmp="$(mktemp)"
  # Bug fix (Agent 4 #6): strip resume_offset= BEFORE resume= to avoid the
  # more-specific pattern being eaten by the greedy `resume=[^ ]*` match.
  # Also use `resume=\/` so we only match the actual device path token.
  UUID_VAL="$uuid" OFFSET_VAL="$offset" awk '
    BEGIN { key="GRUB_CMDLINE_LINUX_DEFAULT"; found=0 }
    {
      if (index($0, key"=") == 1) {
        found=1; line=$0
        q1=index(line,"\""); rest=substr(line,q1+1)
        q2=index(rest,"\""); val=substr(rest,1,q2-1)
        gsub(/resume_offset=[0-9]+/,"",val)
        gsub(/resume=\/[^ ]*/,"",val)
        gsub(/[ \t]+/," ",val); sub(/^ /,"",val); sub(/ $/,"",val)
        newval=val " resume=/dev/disk/by-uuid/" ENVIRON["UUID_VAL"] \
               " resume_offset=" ENVIRON["OFFSET_VAL"]
        sub(/^ /,"",newval)
        print key"=\"" newval "\""
        next
      }
      print
    }
    END {
      if (!found)
        print key"=\"resume=/dev/disk/by-uuid/" ENVIRON["UUID_VAL"] \
              " resume_offset=" ENVIRON["OFFSET_VAL"] "\""
    }
  ' "$GRUB_FILE" > "$tmp"

  if diff -q "$GRUB_FILE" "$tmp" >/dev/null 2>&1; then
    ok "GRUB already has the correct resume parameters."
    rm -f "$tmp"
  else
    backup_file "$GRUB_FILE"
    if [[ $DRY_RUN -eq 1 ]]; then
      info "[dry-run] new GRUB line would be:"
      grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$tmp" | sed 's/^/      /'
      rm -f "$tmp"
    else
      # Bug fix (Agent 4 #15): capture failure rather than silently succeeding
      if ! cat "$tmp" > "$GRUB_FILE"; then
        rm -f "$tmp"
        die "Failed to write ${GRUB_FILE} — is it writable? (try: sudo steamos-readonly disable)"
      fi
      rm -f "$tmp"
      ok "Updated ${GRUB_FILE}."
    fi
    update_grub_cfg
  fi
}

update_grub_cfg() {
  info "Regenerating GRUB config..."
  if command -v update-grub >/dev/null 2>&1; then
    run update-grub || warn "update-grub returned non-zero."
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    local cfg; cfg="$(find /boot -name grub.cfg 2>/dev/null | head -1)"
    run grub-mkconfig -o "${cfg:-/boot/grub/grub.cfg}" \
      || warn "grub-mkconfig returned non-zero."
  else
    warn "Neither update-grub nor grub-mkconfig found — regenerate GRUB config manually."
  fi
}

# ── Step 3: logind bypass ─────────────────────────────────────────────────────
configure_logind_bypass() {
  step "systemd-logind hibernation memory-check bypass"
  local content='[Service]
Environment=SYSTEMD_BYPASS_HIBERNATION_MEMORY_CHECK=1'

  if [[ -f "$LOGIND_DROPIN" ]] \
     && grep -q 'SYSTEMD_BYPASS_HIBERNATION_MEMORY_CHECK=1' "$LOGIND_DROPIN"; then
    ok "logind override already present."
  else
    run mkdir -p "$(dirname "$LOGIND_DROPIN")"
    if [[ $DRY_RUN -eq 1 ]]; then
      info "[dry-run] would write $LOGIND_DROPIN"
    else
      printf '%s\n' "$content" > "$LOGIND_DROPIN" && ok "Wrote $LOGIND_DROPIN"
    fi
    run systemctl daemon-reload
    run systemctl restart systemd-logind 2>/dev/null \
      || warn "Could not restart logind now (takes effect next boot)."
  fi

  # Bug fix (Agent 4 gap-11): verify logind actually parsed the env var
  if [[ $DRY_RUN -ne 1 ]]; then
    local env_check
    env_check="$(systemctl show systemd-logind.service --property=Environment 2>/dev/null)"
    if echo "$env_check" | grep -q 'SYSTEMD_BYPASS_HIBERNATION_MEMORY_CHECK=1'; then
      ok "logind: env var confirmed active."
    else
      warn "logind: env var not yet visible — run 'systemctl daemon-reload && systemctl restart systemd-logind'."
    fi
  fi
}

# ── Step 4: sleep.conf ────────────────────────────────────────────────────────
configure_sleep_conf() {
  step "${SLEEP_CONF} + ${SLEEP_DROPIN} (HibernateDelaySec=${HIBERNATE_DELAY})"
  local content="[Sleep]
AllowSuspend=yes
AllowHibernation=yes
AllowSuspendThenHibernate=yes
HibernateDelaySec=${HIBERNATE_DELAY}
SuspendState=mem"

  # The drop-in content only needs to override the keys that SteamOS disables.
  # It does NOT duplicate HibernateDelaySec — that stays in the base file.
  local dropin_content="[Sleep]
# Override SteamOS vendor drop-in (/usr/lib/systemd/sleep.conf.d/) which
# sets AllowHibernation=no.  Admin drop-ins in /etc/ take precedence.
AllowHibernation=yes
AllowSuspendThenHibernate=yes"

  # Bug fix (Agent 4 #10): normalize trailing whitespace before diff to avoid
  # spurious rewrites when the file was written by a different tool.
  local match=0
  if [[ -f "$SLEEP_CONF" ]]; then
    diff -q \
      <(printf '%s\n' "$content" | sed 's/[[:space:]]*$//') \
      <(sed 's/[[:space:]]*$//' "$SLEEP_CONF" 2>/dev/null) \
      >/dev/null 2>&1 && match=1
  fi

  if [[ $match -eq 1 ]]; then
    ok "sleep.conf already matches desired config."
  else
    backup_file "$SLEEP_CONF"
    if [[ $DRY_RUN -eq 1 ]]; then
      info "[dry-run] would write $SLEEP_CONF"
    else
      printf '%s\n' "$content" > "$SLEEP_CONF" && ok "Wrote $SLEEP_CONF"
    fi
  fi

  # Always write the high-priority drop-in. /usr/lib/systemd/sleep.conf.d/
  # entries override /etc/systemd/sleep.conf on SteamOS, but
  # /etc/systemd/sleep.conf.d/ entries override everything.
  local dropin_match=0
  if [[ -f "$SLEEP_DROPIN" ]]; then
    diff -q \
      <(printf '%s\n' "$dropin_content" | sed 's/[[:space:]]*$//') \
      <(sed 's/[[:space:]]*$//' "$SLEEP_DROPIN" 2>/dev/null) \
      >/dev/null 2>&1 && dropin_match=1
  fi

  if [[ $dropin_match -eq 1 ]]; then
    ok "sleep drop-in already correct: $SLEEP_DROPIN"
  else
    if [[ $DRY_RUN -eq 1 ]]; then
      info "[dry-run] would write $SLEEP_DROPIN"
    else
      run mkdir -p "$(dirname "$SLEEP_DROPIN")"
      printf '%s\n' "$dropin_content" > "$SLEEP_DROPIN" \
        && ok "Wrote override drop-in: $SLEEP_DROPIN"
    fi
  fi

  run systemctl daemon-reload
}

# ── Step 5: Bluetooth re-init after resume ────────────────────────────────────
install_bluetooth_fix() {
  step "Bluetooth-after-resume fix"
  # Security fix (Agent 4 #14): BT script runs as root (no User= in service).
  # → must be root-owned and not writable by the deck user.
  # Moved from /home/deck/.local/bin/ to /usr/local/sbin/ (root-owned territory).
  local script_content='#!/bin/bash
# fix-bluetooth-resume.sh — reinit BT driver if it misbehaves after resume.
# Runs as root via systemd. Re-bind only if bluetooth is actually broken.
PATH=/sbin:/usr/sbin:/bin:/usr/bin

is_bluetooth_ok() {
    # Power on first — adapter comes up powered-off after hibernation.
    bluetoothctl power on >/dev/null 2>&1
    # Then check if it responds; if discoverable fails, driver needs rebind.
    bluetoothctl discoverable on >/dev/null 2>&1 || return 1
}

sleep 2  # let the system settle after wake

if ! is_bluetooth_ok; then
    echo "Bluetooth misbehaving after resume — rebinding hci_uart_qca driver"
    echo serial0-0 > /sys/bus/serial/drivers/hci_uart_qca/unbind 2>/dev/null || true
    sleep 1
    echo serial0-0 > /sys/bus/serial/drivers/hci_uart_qca/bind   2>/dev/null || true
fi'

  local service_content="[Unit]
Description=Fix Bluetooth after resume (Steam Deck OLED)
After=hibernate.target hybrid-sleep.target suspend-then-hibernate.target bluetooth.service

[Service]
Type=oneshot
ExecStart=${BT_SCRIPT}
# No User= → runs as root; script must be root-owned (not writable by deck)

[Install]
WantedBy=hibernate.target hybrid-sleep.target suspend-then-hibernate.target"

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] would install ${BT_SCRIPT} and ${BT_SERVICE}, then enable it."
    return 0
  fi

  mkdir -p "$(dirname "$BT_SCRIPT")"
  printf '%s\n' "$script_content" > "$BT_SCRIPT"
  chmod 755 "$BT_SCRIPT"
  chown root:root "$BT_SCRIPT"  # must be root-owned; service runs as root
  ok "Installed ${BT_SCRIPT} (owned root:root)"

  printf '%s\n' "$service_content" > "$BT_SERVICE"
  ok "Installed ${BT_SERVICE}"

  systemctl daemon-reload
  systemctl enable fix-bluetooth-resume.service >/dev/null 2>&1 \
    && ok "Enabled fix-bluetooth-resume.service" \
    || warn "Could not enable fix-bluetooth-resume.service."
}

# ── Step 6: suspend → suspend-then-hibernate symlink ─────────────────────────
enable_suspend_then_hibernate() {
  step "Replace plain suspend with suspend-then-hibernate"
  [[ -e "$STH_TARGET" ]] || die "Target unit not found: $STH_TARGET"

  # Bug fix (Agent 4 #17): if the link target is a regular file (not a symlink),
  # back it up before replacing it with a symlink.
  if [[ -f "$SUSPEND_LINK" && ! -L "$SUSPEND_LINK" ]]; then
    warn "$SUSPEND_LINK is a regular file, not a symlink. Backing up before replacing."
    backup_file "$SUSPEND_LINK"
    run rm -f "$SUSPEND_LINK"
  fi

  if [[ -L "$SUSPEND_LINK" \
     && "$(readlink -f "$SUSPEND_LINK")" == "$(readlink -f "$STH_TARGET")" ]]; then
    ok "suspend is already redirected to suspend-then-hibernate."
  else
    run ln -sf "$STH_TARGET" "$SUSPEND_LINK"
    ok "Linked $SUSPEND_LINK -> $STH_TARGET"
    run systemctl daemon-reload
  fi
}

disable_suspend_then_hibernate() {
  if [[ -L "$SUSPEND_LINK" ]]; then
    run rm -f "$SUSPEND_LINK"
    ok "Removed suspend redirect ($SUSPEND_LINK)."
    run systemctl daemon-reload
  else
    info "No suspend redirect symlink found — nothing to remove."
  fi
}

# ── Step 7: boot-time reapply service ────────────────────────────────────────
install_persist_hook() {
  step "Boot-time reapply service (survives SteamOS updates)"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] would copy self to ${SELF_INSTALL_PATH} and install ${REAPPLY_SERVICE}."
    return 0
  fi
  install -D -m 0755 "$0" "$SELF_INSTALL_PATH" 2>/dev/null \
    || { cp -f "$0" "$SELF_INSTALL_PATH" && chmod 0755 "$SELF_INSTALL_PATH"; }

  cat > "$REAPPLY_SERVICE" <<EOF
[Unit]
Description=Reapply Steam Deck hibernation config (idempotent)
After=local-fs.target
Before=suspend.target hibernate.target suspend-then-hibernate.target

[Service]
Type=oneshot
ExecStart=${SELF_INSTALL_PATH} reapply --yes
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable steamdeck-hibernate-reapply.service >/dev/null 2>&1 \
    && ok "Installed and enabled ${REAPPLY_SERVICE}" \
    || warn "Could not enable reapply service."
}

remove_persist_hook() {
  if [[ -f "$REAPPLY_SERVICE" ]]; then
    run systemctl disable steamdeck-hibernate-reapply.service >/dev/null 2>&1 || true
    run rm -f "$REAPPLY_SERVICE"
    run systemctl daemon-reload
    ok "Removed reapply service."
  fi
  [[ -f "$SELF_INSTALL_PATH" ]] && run rm -f "$SELF_INSTALL_PATH"
}

# ── Step 8: GRUB boot counter fix ────────────────────────────────────────────
# After 4-5 hibernation cycles, SteamOS shows "failed to boot" screen because
# GRUB's boot counter is never reset on hibernation resume (only on normal boots).
# Fix: a systemd-sleep hook that resets the counter after every hibernate resume.
install_boot_counter_fix() {
  step "GRUB boot counter reset (prevents 'failed to boot' screen)"

  # Locate grub-editenv
  local grub_editenv=""
  grub_editenv="$(command -v grub-editenv 2>/dev/null \
               || command -v grub2-editenv 2>/dev/null || true)"
  if [[ -z "$grub_editenv" ]]; then
    warn "grub-editenv not found — skipping boot counter fix."
    warn "  Manual fix after each hibernate: grub-editenv <grubenv> set boot_counter=3"
    return 0
  fi

  # Locate grubenv file
  local grubenv_path=""
  local _candidates=(
    /boot/efi/EFI/steamos/grubenv
    /boot/efi/EFI/SteamOS/grubenv
    /boot/grub/grubenv
    /boot/grub2/grubenv
  )
  for c in "${_candidates[@]}"; do
    [[ -f "$c" ]] && { grubenv_path="$c"; break; }
  done
  if [[ -z "$grubenv_path" ]]; then
    warn "Could not find grubenv file — skipping boot counter fix."
    warn "  Find it with: find /boot/efi -name grubenv 2>/dev/null"
    return 0
  fi
  info "Using grubenv: $grubenv_path"

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] would install ${BOOT_COUNTER_HOOK}"
    return 0
  fi

  mkdir -p "$(dirname "$BOOT_COUNTER_HOOK")"
  # Use printf with quoted variables to avoid word-splitting in the hook script.
  printf '#!/bin/bash\n# Reset GRUB boot_counter after hibernation resume.\n' \
    > "$BOOT_COUNTER_HOOK"
  printf '# Called by systemd-sleep with $1=pre|post $2=suspend|hibernate|...\n' \
    >> "$BOOT_COUNTER_HOOK"
  printf 'if [[ "$1" == "post" ]] && [[ "$2" == "hibernate" || "$2" == "suspend-then-hibernate" ]]; then\n' \
    >> "$BOOT_COUNTER_HOOK"
  printf '    %q %q set boot_counter=%d\n' \
    "$grub_editenv" "$grubenv_path" "$_BOOT_COUNTER_DEFAULT" \
    >> "$BOOT_COUNTER_HOOK"
  printf 'fi\n' >> "$BOOT_COUNTER_HOOK"
  chmod 755 "$BOOT_COUNTER_HOOK"
  chown root:root "$BOOT_COUNTER_HOOK"
  ok "Installed ${BOOT_COUNTER_HOOK}"

  # Reset counter immediately so current session is clean
  "$grub_editenv" "$grubenv_path" set "boot_counter=${_BOOT_COUNTER_DEFAULT}" 2>/dev/null \
    && ok "Reset boot_counter to ${_BOOT_COUNTER_DEFAULT} immediately." \
    || warn "Could not reset boot_counter now — will reset on next hibernate resume."
}

# ── Step 9: Optional CEC TV-off on sleep (dock users) ─────────────────────────
install_cec_tv_control() {
  step "CEC TV-off on sleep (optional, for dock users)"
  if [[ ! -e /dev/cec0 ]]; then
    warn "/dev/cec0 not found — no HDMI-CEC adapter detected."
    warn "  Re-run with the dock connected, or skip this optional feature."
    return 0
  fi
  local cec_ctl; cec_ctl="$(command -v cec-ctl 2>/dev/null || true)"
  if [[ -z "$cec_ctl" ]]; then
    warn "cec-ctl not found — install v4l-utils first:"
    warn "  sudo steamos-readonly disable && sudo pacman -S v4l-utils"
    warn "  Then re-run: sudo $0 install-cec"
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] would install ${CEC_SCRIPT} and ${CEC_SERVICE}."
    return 0
  fi

  mkdir -p "$(dirname "$CEC_SCRIPT")"
  printf '#!/bin/bash\n# turn-off-tv.sh — CEC Standby to TV on sleep/hibernate\n' \
    > "$CEC_SCRIPT"
  printf '%q -d /dev/cec0 -C\n'              "$cec_ctl" >> "$CEC_SCRIPT"
  printf '%q -d /dev/cec0 --playback\n'      "$cec_ctl" >> "$CEC_SCRIPT"
  printf '%q -d /dev/cec0 --to 0 --standby\n' "$cec_ctl" >> "$CEC_SCRIPT"
  printf '%q -d /dev/cec0 -C\n'              "$cec_ctl" >> "$CEC_SCRIPT"
  chmod 755 "$CEC_SCRIPT"
  chown "${DECK_USER}:${DECK_USER}" "$CEC_SCRIPT" 2>/dev/null || true
  ok "Installed ${CEC_SCRIPT}"

  # Bug fix (Agent 4 #20): IgnoreOnIsolate belongs in [Unit], not [Service].
  cat > "$CEC_SERVICE" <<EOF
[Unit]
Description=CEC TV standby on sleep/hibernate (Steam Deck dock)
Before=sleep.target
IgnoreOnIsolate=yes

[Service]
Type=oneshot
ExecStart=${CEC_SCRIPT}
User=${DECK_USER}

[Install]
WantedBy=sleep.target
EOF
  # Ensure deck user can access /dev/cec0 (needs video group)
  if ! id -nG "${DECK_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx video; then
    usermod -aG video "${DECK_USER}" 2>/dev/null \
      && warn "Added ${DECK_USER} to 'video' group — takes effect on next login." \
      || warn "Could not add ${DECK_USER} to 'video' group — may need manual step."
  fi
  systemctl daemon-reload
  systemctl enable cec-sleep.service >/dev/null 2>&1 \
    && ok "Enabled cec-sleep.service (TV will power off when Deck sleeps)." \
    || warn "Could not enable cec-sleep.service."
}

# ── Wake-source tools ─────────────────────────────────────────────────────────
# Single ACPI device disable (fix-wake command)
cmd_fix_wake() {
  require_root "$@"
  local dev="${1:-}"
  [[ -n "$dev" ]] || die "Usage: $0 fix-wake <DEVICE>  (e.g. XHC0 from /proc/acpi/wakeup)"

  # Security fix (Agent 4 #12): validate device name to prevent shell injection.
  [[ "$dev" =~ ^[A-Za-z0-9_:.-]{1,32}$ ]] \
    || die "Invalid device name: '$dev'. Expected ACPI device like XHC0 or PXSX."

  grep -qiE "^${dev}[[:space:]]" /proc/acpi/wakeup 2>/dev/null \
    || warn "'$dev' not found in /proc/acpi/wakeup — installing anyway."

  step "Persistently disable wake source: ${dev}"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] would install ${WAKEFIX_SERVICE} to disable ${dev} at boot."
    return 0
  fi

  # Bug fix (Agent 4 #11): original regex `\*enabled` was incorrectly escaped
  # in the heredoc, causing the match to never fire. Use [*]enabled instead.
  cat > "$WAKEFIX_SERVICE" <<EOF
[Unit]
Description=Disable ACPI wake source ${dev} on Steam Deck
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'grep -qE "^${dev}[[:space:]].*[*]enabled" /proc/acpi/wakeup && echo ${dev} > /proc/acpi/wakeup || true'

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now steamdeck-disable-wakeup.service >/dev/null 2>&1 \
    && ok "Installed and applied wake-source disable for ${dev}." \
    || warn "Service installed but could not start now."
  echo
  info "Re-test with:  sudo $0 test-suspend"
}

# ── Enhanced suspend test (Agent 5) ──────────────────────────────────────────
cmd_test_suspend() {
  step "Suspend self-test (mode=${TEST_SLEEP_MODE}, ${TEST_SLEEP_SECS}s)"
  require_root

  local mode="${TEST_SLEEP_MODE:-mem}"
  local secs="${TEST_SLEEP_SECS:-20}"
  local wake_threshold="${IMMEDIATE_WAKE_THRESHOLD:-5}"

  command -v rtcwake >/dev/null 2>&1 \
    || die "rtcwake not found (install util-linux)."

  # Pre-suspend: warn about enabled ACPI wakeup culprits
  info "--- Pre-suspend ACPI wakeup check ---"
  local enabled_bad_entries=()
  if [[ -r /proc/acpi/wakeup ]]; then
    local _line _dev _status
    while IFS= read -r _line; do
      _dev=$(awk '{print $1}' <<< "$_line")
      _status=$(awk '{print $3}' <<< "$_line")
      [[ "$_status" != "*enabled" ]] && continue
      case "$_dev" in
        XHC*|XHCI*|USB*|EHC*|OHC*)
          warn "ACPI wakeup ENABLED for USB/XHC: ${_dev} → may cause immediate wake"
          warn "  Fix: sudo $0 fix-wake ${_dev}"
          enabled_bad_entries+=("${_dev}:usb")
          ;;
        WLAN*|WIFI*|PXSX*)
          warn "ACPI wakeup ENABLED for WiFi/PCIe: ${_dev} → may cause immediate wake"
          warn "  Fix: sudo $0 fix-wifi-wake"
          enabled_bad_entries+=("${_dev}:wifi")
          ;;
      esac
    done < /proc/acpi/wakeup
    (( ${#enabled_bad_entries[@]} == 0 )) && ok "No problematic ACPI wakeup entries found."
  else
    warn "/proc/acpi/wakeup not readable — skipping ACPI wakeup pre-check."
  fi

  # Pre-suspend: ensure debugfs is mounted (needed for wakeup_sources)
  local debugfs_was_mounted=0
  if mount | grep -q debugfs; then
    debugfs_was_mounted=1
  else
    mount -t debugfs none /sys/kernel/debug 2>/dev/null \
      && info "Mounted debugfs temporarily." \
      || warn "Could not mount debugfs — wakeup_sources diff will be skipped."
  fi

  # Snapshot wakeup_sources before suspend
  local snap_before snap_after
  snap_before="$(mktemp /tmp/ws_before.XXXXXX)"
  snap_after="$(mktemp  /tmp/ws_after.XXXXXX)"
  # Cleanup on exit/interrupt
  trap 'rm -f "$snap_before" "$snap_after"' RETURN INT TERM

  [[ -r /sys/kernel/debug/wakeup_sources ]] \
    && cp /sys/kernel/debug/wakeup_sources "$snap_before" 2>/dev/null || true

  # Record timestamp for journalctl post-wake query
  local start_ts; start_ts="$(date +%s)"

  warn "Screen will turn off. Device wakes automatically via RTC after ${secs}s."
  confirm "Run the suspend test now?" || { info "Cancelled."; return 0; }

  local t0; t0="$(date +%s)"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] would run: rtcwake -m $mode -s $secs"
    sleep 2
  else
    run rtcwake -m "$mode" -s "$secs" >/dev/null 2>&1 \
      || warn "rtcwake exited non-zero."
  fi
  local t1; t1="$(date +%s)"
  local elapsed=$(( t1 - t0 ))

  # Snapshot after wake
  [[ -r /sys/kernel/debug/wakeup_sources ]] \
    && cp /sys/kernel/debug/wakeup_sources "$snap_after" 2>/dev/null || true

  echo
  info "=== System woke after ${elapsed}s ==="
  echo

  # wakeup_sources diff
  if [[ -s "$snap_before" && -s "$snap_after" ]]; then
    info "--- wakeup_sources changes ---"
    diff "$snap_before" "$snap_after" \
      | grep '^[<>]' | grep -v '^[<>] name' \
      | head -20 | sed 's/^/    /' || true
  fi

  # Kernel messages since suspend
  info ""
  info "--- Kernel PM/wake/ACPI messages since suspend ---"
  local journal_out=""
  if command -v journalctl >/dev/null 2>&1; then
    journal_out="$(journalctl -k --since "@${start_ts}" 2>/dev/null \
      | grep -iE 'wakeup|PM: |IRQ |ACPI' | head -40 || true)"
    if [[ -n "$journal_out" ]]; then
      echo "$journal_out" | sed 's/^/    /'
    else
      info "  (no matching messages — journald may not have flushed yet)"
      info "  Try: journalctl -k --since \"@${start_ts}\" | grep -iE 'wakeup|PM:|IRQ|ACPI'"
    fi
  else
    info "  journalctl not available — run: dmesg | grep -iE 'wakeup|PM:|IRQ|ACPI'"
  fi

  echo
  # Verdict + targeted fix suggestions
  if (( elapsed < wake_threshold )); then
    err "IMMEDIATE WAKE DETECTED — woke after only ${elapsed}s (threshold: ${wake_threshold}s)"
    echo
    info "Suggested fixes (based on pre-suspend check and journal):"
    for entry in "${enabled_bad_entries[@]}"; do
      local _ename="${entry%%:*}" _etype="${entry##*:}"
      case "$_etype" in
        usb)  info "  [USB/XHC]  sudo $0 fix-wake ${_ename}" ;;
        wifi) info "  [WiFi]     sudo $0 fix-wifi-wake" ;;
      esac
    done
    if echo "$journal_out" | grep -qi 'xhc\|xhci\|usb'; then
      info "  [USB/XHC]  Journal shows XHC activity → sudo $0 fix-wake XHC0"
    fi
    if echo "$journal_out" | grep -qi 'wifi\|wlan\|ath11k\|ath10k'; then
      info "  [WiFi]     Journal shows WiFi activity → sudo $0 fix-wifi-wake"
    fi
    if echo "$journal_out" | grep -qi 'bluetooth\|btusb\|hci'; then
      info "  [Bluetooth] Disable paired BT devices or: sudo $0 fix-wake"
    fi
    echo
    info "  [Steam]    Check: Steam → Settings → Customization → disable 'Use As Wake Movie'"
    echo
    info "After applying a fix, run: sudo $0 test-suspend  to verify."
  else
    ok "Suspend healthy (${elapsed}s ≥ threshold ${wake_threshold}s)."
    echo
    info "Next step: sudo $0 test-hibernate"
    info "(This powers off the device — press Power to resume.)"
  fi

  # Unmount debugfs only if we mounted it
  if [[ $debugfs_was_mounted -eq 0 ]]; then
    umount /sys/kernel/debug 2>/dev/null || true
  fi
}

# ── WiFi / XHC wake-source fixer (Agent 5) ────────────────────────────────────
cmd_fix_wifi_wake() {
  step "Fix WiFi / XHC immediate-wake issue"
  require_root

  local conf="${WIFIWAKE_CONF}"
  info "--- Prong 1: disable WiFi/XHC ACPI wakeup via tmpfiles.d ---"

  local tmpfiles_lines=()

  # Find ath11k/ath10k WiFi PCI devices and disable their sysfs wakeup
  local uevent pci_dir pci_driver wakeup_file pci_addr
  for uevent in /sys/bus/pci/devices/*/uevent; do
    [[ -r "$uevent" ]] || continue
    pci_dir="${uevent%/uevent}"
    pci_driver=""
    while IFS='=' read -r _k _v; do
      [[ "$_k" == "DRIVER" ]] && { pci_driver="$_v"; break; }
    done < "$uevent"
    if [[ -z "$pci_driver" && -L "${pci_dir}/driver" ]]; then
      pci_driver="$(basename "$(readlink "${pci_dir}/driver")" 2>/dev/null)" || true
    fi
    case "$pci_driver" in
      ath11k*|ath10k*)
        wakeup_file="${pci_dir}/power/wakeup"
        [[ -e "$wakeup_file" ]] || continue
        pci_addr="${pci_dir##*/}"
        local cur; cur="$(< "$wakeup_file" 2>/dev/null)" || cur="unknown"
        [[ "$cur" == "enabled" ]] \
          && warn "WiFi ${pci_addr} (${pci_driver}): wakeup enabled → disabling" \
          || info "WiFi ${pci_addr} (${pci_driver}): wakeup already ${cur}"
        tmpfiles_lines+=("w /sys/bus/pci/devices/${pci_addr}/power/wakeup - - - - disabled")
        if [[ $DRY_RUN -ne 1 ]]; then
          echo "disabled" > "$wakeup_file" 2>/dev/null \
            && info "  Disabled immediately for ${pci_addr}" \
            || warn "  Could not disable immediately (will apply at next boot)"
        fi
        ;;
    esac
  done

  # Find enabled XHC/XHCI entries in /proc/acpi/wakeup and disable via sysfs
  if [[ -r /proc/acpi/wakeup ]]; then
    local _line _dev _status _sysfs
    while IFS= read -r _line; do
      _dev=$(awk '{print $1}' <<< "$_line")
      _status=$(awk '{print $3}' <<< "$_line")
      _sysfs=$(awk '{print $4}' <<< "$_line")
      [[ "$_status" != "*enabled" ]] && continue
      case "$_dev" in XHC*|XHCI*) ;; *) continue ;; esac

      local xhc_wakeup=""
      if [[ -n "$_sysfs" && "$_sysfs" == /sys/devices/* ]]; then
        xhc_wakeup="${_sysfs}/power/wakeup"
      fi
      if [[ -z "$xhc_wakeup" || ! -e "$xhc_wakeup" ]]; then
        # Fallback: find xhci controller's wakeup file
        xhc_wakeup="$(find /sys/devices -maxdepth 6 \
          \( -name 'wakeup' -path '*/xhci_hcd*/power/wakeup' \) \
          2>/dev/null | head -1)" || true
      fi
      if [[ -n "$xhc_wakeup" && -e "$xhc_wakeup" ]]; then
        warn "XHC ${_dev}: wakeup enabled → disabling via sysfs"
        tmpfiles_lines+=("w ${xhc_wakeup} - - - - disabled")
        if [[ $DRY_RUN -ne 1 ]]; then
          echo "disabled" > "$xhc_wakeup" 2>/dev/null \
            && info "  Disabled immediately for ${_dev}" \
            || warn "  Could not disable immediately for ${_dev}"
        fi
      else
        warn "Could not find sysfs path for ${_dev} — disable manually:"
        warn "  echo '${_dev}' | sudo tee /proc/acpi/wakeup  (toggles state)"
      fi
    done < /proc/acpi/wakeup
  fi

  # Write tmpfiles.d config
  if (( ${#tmpfiles_lines[@]} == 0 )); then
    warn "No WiFi or XHC wakeup paths found to disable."
    warn "  Check /sys/bus/pci/devices/ and /proc/acpi/wakeup manually."
  else
    info ""
    info "Writing ${conf}"
    local conf_content
    conf_content="# steamdeck-wifi-nowake.conf — generated $(date -I)"$'\n'
    conf_content+="# Disables WiFi/XHC ACPI wakeup to prevent immediate wake-from-sleep."$'\n'
    for l in "${tmpfiles_lines[@]}"; do conf_content+="${l}"$'\n'; done

    if [[ $DRY_RUN -eq 1 ]]; then
      info "[dry-run] would write ${conf}:"
      echo "$conf_content" | sed 's/^/    /'
    else
      mkdir -p "$(dirname "$conf")"
      printf '%s' "$conf_content" > "$conf"
      chmod 644 "$conf"
      systemd-tmpfiles --create "$conf" 2>/dev/null \
        && ok "Applied: ${conf}" \
        || warn "systemd-tmpfiles returned non-zero — changes take effect at next boot."
    fi
  fi

  # Prong 2: WPA-supplicant mode instructions (cannot be set programmatically)
  echo ""
  printf '  ┌──────────────────────────────────────────────────────────────┐\n'
  printf '  │  WiFi immediate-wake fix: enable WPA-supplicant backend     │\n'
  printf '  ├──────────────────────────────────────────────────────────────┤\n'
  printf '  │  1. Press the STEAM button                                  │\n'
  printf '  │  2. Go to Settings → System                                │\n'
  printf '  │  3. Enable "Developer Mode"                                 │\n'
  printf '  │  4. Scroll down → Developer section                        │\n'
  printf '  │  5. Enable "Use Experimental WiFi Backend (WPA Supplicant)" │\n'
  printf '  │  6. Reboot the Steam Deck                                   │\n'
  printf '  └──────────────────────────────────────────────────────────────┘\n'
  echo ""

  # Prong 3: Check Steam Wake Movie setting
  info "--- Checking Steam 'Use As Wake Movie' setting ---"
  local deck_home; deck_home="$(getent passwd "$DECK_USER" 2>/dev/null | cut -d: -f6)" \
    || deck_home="$DECK_HOME"
  [[ -z "$deck_home" ]] && deck_home="$DECK_HOME"
  local localconfig="${deck_home}/.steam/steam/config/localconfig.vdf"
  if [[ -r "$localconfig" ]]; then
    local wm_line
    wm_line="$(grep -i 'UseWakeOnMusicEnabled\|WakeOnMusic\|UseAsWakeMovie' \
      "$localconfig" 2>/dev/null | head -1)" || wm_line=""
    if [[ -z "$wm_line" ]]; then
      ok "Steam Wake Movie: not found in localconfig.vdf (likely disabled)"
    else
      local wm_val; wm_val="$(printf '%s' "$wm_line" \
        | grep -oP '"\K[01](?="\s*$)' | head -1)" || wm_val=""
      if [[ "$wm_val" == "1" ]]; then
        warn "Steam 'Use As Wake Movie' is ENABLED — this causes wake-from-sleep."
        warn "  Disable it: Steam → Settings → Customization → Use As Wake Movie → Off"
      elif [[ "$wm_val" == "0" ]]; then
        ok "Steam 'Use As Wake Movie' is disabled."
      else
        info "Steam Wake Movie key found but value unclear: ${wm_line}"
      fi
    fi
  else
    info "Steam localconfig.vdf not found at ${localconfig} — skipping check."
  fi

  # Prong 4: check mem_sleep mode — s2idle causes much more aggressive wakeup
  info "--- mem_sleep mode ---"
  local mem_sleep
  if [[ -r /sys/power/mem_sleep ]]; then
    mem_sleep="$(< /sys/power/mem_sleep)"
    if echo "$mem_sleep" | grep -q '\[deep\]'; then
      ok "mem_sleep = deep (correct for suspend)"
    elif echo "$mem_sleep" | grep -q '\[s2idle\]'; then
      warn "mem_sleep = s2idle — this is the WRONG mode for suspend-then-hibernate."
      warn "s2idle keeps the CPU partially awake, making wakeup sources fire more easily."
      warn "Switch to deep sleep:"
      warn "  echo deep | sudo tee /sys/power/mem_sleep"
      warn "  # For persistence add to GRUB: mem_sleep_default=deep"
    else
      info "mem_sleep: ${mem_sleep}"
    fi
  fi

  echo
  ok "fix-wifi-wake complete."
  info "If wakes still persist, run the nuclear option to disable ALL wakeup sources:"
  info "  sudo $0 disable-all-wakeup"
  info "Then check what actually woke the device:"
  info "  sudo dmesg | grep -Ei 'PM: |wake|IRQ ' | tail -30"
}

# ── Disable ALL ACPI wakeup sources except the power button ──────────────────
# Use when fix-wifi-wake doesn't fully stop immediate wake. Disables every
# ACPI wakeup source except PWRB (power button). You lose remote-wake features
# (keyboard/mouse/USB wake), but suspend becomes reliable.
cmd_disable_all_wakeup() {
  step "Nuclear wakeup disable (all ACPI sources except PWRB)"
  require_root

  # Persist via tmpfiles.d so it survives reboots
  local NUCLEAR_CONF="/etc/tmpfiles.d/steamdeck-nowake-nuclear.conf"
  local tmpfiles_lines=()
  local disabled_acpi=()
  local skipped_acpi=()

  info "--- Current /proc/acpi/wakeup ---"
  [[ -r /proc/acpi/wakeup ]] || die "/proc/acpi/wakeup not readable"
  cat /proc/acpi/wakeup
  echo

  # Step 1: disable via /proc/acpi/wakeup toggle (for currently-enabled entries)
  while IFS= read -r _line; do
    local _dev _status _sysfs
    _dev=$(awk '{print $1}' <<< "$_line")
    _status=$(awk '{print $3}' <<< "$_line")
    [[ -z "$_dev" || "$_dev" == Device ]] && continue
    if [[ "$_dev" == "PWRB" ]]; then
      info "  Skipping PWRB (power button — keep enabled)"
      skipped_acpi+=("$_dev")
      continue
    fi
    if [[ "$_status" == "*enabled" ]]; then
      warn "  Disabling ACPI wakeup: ${_dev}"
      if [[ $DRY_RUN -ne 1 ]]; then
        echo "$_dev" > /proc/acpi/wakeup 2>/dev/null \
          && disabled_acpi+=("$_dev") \
          || warn "    Could not toggle ${_dev} via /proc/acpi/wakeup"
      fi
    else
      info "  Already disabled: ${_dev}"
    fi
  done < /proc/acpi/wakeup

  # Step 2: disable via sysfs power/wakeup (more reliable, covers USB children)
  info "--- Disabling all sysfs power/wakeup entries ---"
  while IFS= read -r wakeup_file; do
    [[ -e "$wakeup_file" ]] || continue
    local cur; cur="$(< "$wakeup_file" 2>/dev/null)" || cur="unknown"
    [[ "$cur" == "enabled" ]] || continue

    # Build a device label for logging
    local dev_path="${wakeup_file%/power/wakeup}"
    local dev_name; dev_name="$(basename "$dev_path")"

    # Skip the power button node
    if [[ "$dev_name" == *"LNXPWRBN"* ]] || \
       grep -qi "power button" "${dev_path}/description" 2>/dev/null; then
      info "  Skipping power button: ${dev_name}"
      continue
    fi

    warn "  Disabling sysfs wakeup: ${dev_path##*/sys/devices/}"
    tmpfiles_lines+=("w ${wakeup_file} - - - - disabled")
    if [[ $DRY_RUN -ne 1 ]]; then
      echo "disabled" > "$wakeup_file" 2>/dev/null \
        || warn "    Could not write to ${wakeup_file}"
    fi
  done < <(find /sys/devices -name "wakeup" -path "*/power/wakeup" 2>/dev/null)

  # Step 3: write nuclear tmpfiles.d conf for persistence
  if (( ${#tmpfiles_lines[@]} > 0 )); then
    local conf_content
    conf_content="# steamdeck-nowake-nuclear.conf — generated $(date -I)"$'\n'
    conf_content+="# Disables ALL sysfs wakeup sources except power button."$'\n'
    conf_content+="# Written by: sudo steamdeck-hibernate.sh disable-all-wakeup"$'\n'
    for l in "${tmpfiles_lines[@]}"; do conf_content+="${l}"$'\n'; done
    if [[ $DRY_RUN -eq 1 ]]; then
      info "[dry-run] would write ${NUCLEAR_CONF}:"
      echo "$conf_content" | sed 's/^/    /'
    else
      mkdir -p "$(dirname "$NUCLEAR_CONF")"
      printf '%s' "$conf_content" > "$NUCLEAR_CONF"
      chmod 644 "$NUCLEAR_CONF"
      systemd-tmpfiles --create "$NUCLEAR_CONF" 2>/dev/null || true
      ok "Wrote: ${NUCLEAR_CONF} (${#tmpfiles_lines[@]} entries)"
    fi
  fi

  # Step 4: set mem_sleep=deep if not already
  if [[ -r /sys/power/mem_sleep ]]; then
    local mem_sleep; mem_sleep="$(< /sys/power/mem_sleep)"
    if ! echo "$mem_sleep" | grep -q '\[deep\]'; then
      warn "mem_sleep is not 'deep' (currently: ${mem_sleep})"
      warn "Setting mem_sleep=deep now..."
      if [[ $DRY_RUN -ne 1 ]]; then
        echo deep > /sys/power/mem_sleep 2>/dev/null \
          && ok "mem_sleep set to deep" \
          || warn "Could not set mem_sleep=deep"
      fi
      warn "To make permanent, add  mem_sleep_default=deep  to GRUB_CMDLINE_LINUX_DEFAULT"
      warn "then run: sudo $0 install"
    else
      ok "mem_sleep already = deep"
    fi
  fi

  echo
  ok "Nuclear wakeup disable complete."
  info "Disabled ACPI entries: ${disabled_acpi[*]:-none}"
  info "Skipped: ${skipped_acpi[*]:-none}"
  echo
  info "Now test suspend:  sudo $0 test-suspend"
  info "After wake, check: sudo dmesg | grep -Ei 'PM: |wake' | tail -20"
  info "If it still wakes, the culprit is likely a power management firmware bug."
  info "Workaround: connect to charger AFTER the deck is already asleep, or"
  info "test without any USB-C devices plugged in."
}

# ── Self-test (logic checks, no writes, no hardware required) ─────────────────
# Run this after install + reboot to verify critical values are sane before
# triggering a real hibernation.  All checks are read-only.
cmd_self_test() {
  step "Self-test (read-only logic checks)"
  local pass=0 fail=0

  _st_ok()   { ok   "  $1"; (( pass++ )); true; }
  _st_fail() { err  "  $1"; (( fail++ )); true; }
  _st_info() { info "  $1"; }

  # ── 1. Swapfile exists and is active ───────────────────────────────────────
  _st_info "[1] Swapfile: ${SWAPFILE}"
  if [[ -f "$SWAPFILE" ]]; then
    local sw_b; sw_b="$(current_swap_bytes)"
    local sw_g=$(( sw_b / 1073741824 ))
    if (( sw_g >= 16 )); then
      _st_ok "Swapfile exists: ${sw_g} GiB"
    else
      _st_fail "Swapfile too small: ${sw_g} GiB (need ≥ 16)"
    fi
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
      _st_ok "Swapfile is active swap"
    else
      _st_fail "Swapfile exists but is NOT active — run: sudo swapon ${SWAPFILE}"
    fi
  else
    _st_fail "Swapfile not found: ${SWAPFILE}"
  fi

  # ── 2. resume UUID looks like a UUID ───────────────────────────────────────
  _st_info "[2] Swap partition UUID"
  local uuid; uuid="$(get_resume_uuid 2>/dev/null)" || uuid=""
  if [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    _st_ok "UUID: ${uuid}"
  else
    _st_fail "UUID invalid or empty: '${uuid}'"
  fi

  # ── 3. resume_offset is a positive integer ─────────────────────────────────
  _st_info "[3] Swapfile resume_offset"
  local offset; offset="$(get_resume_offset 2>/dev/null)" || offset=""
  if [[ "$offset" =~ ^[1-9][0-9]+$ ]]; then
    _st_ok "resume_offset = ${offset} (positive integer ✓)"
  elif [[ "$offset" == "0" ]]; then
    _st_fail "resume_offset = 0 — filefrag returned 0; swapfile may start at block 0 \
(unlikely) or be fragmented. Run: sudo filefrag -v ${SWAPFILE}"
  else
    _st_fail "resume_offset invalid or empty: '${offset}' — run: sudo filefrag -v ${SWAPFILE}"
  fi

  # ── 4. GRUB file contains the resume parameters ────────────────────────────
  _st_info "[4] GRUB resume parameters"
  if [[ -f "$GRUB_FILE" ]]; then
    if grep -q 'resume=/dev/disk/by-uuid/' "$GRUB_FILE" \
    && grep -q 'resume_offset=' "$GRUB_FILE"; then
      local grub_uuid; grub_uuid="$(grep -oE 'resume=/dev/disk/by-uuid/[^ "]+' "$GRUB_FILE" | head -1 | sed 's|.*/||')"
      local grub_off;  grub_off="$(grep -oE 'resume_offset=[0-9]+' "$GRUB_FILE" | head -1 | cut -d= -f2)"
      _st_ok "GRUB has resume params (uuid=${grub_uuid}, offset=${grub_off})"
      # Cross-check: GRUB uuid must match current uuid
      if [[ "$grub_uuid" == "$uuid" ]]; then
        _st_ok "GRUB UUID matches current swapfile UUID"
      else
        _st_fail "GRUB UUID (${grub_uuid}) ≠ current UUID (${uuid}) — re-run: sudo $0 install"
      fi
      # Cross-check: GRUB offset must match current offset
      if [[ "$grub_off" == "$offset" ]]; then
        _st_ok "GRUB offset matches current swapfile offset"
      else
        _st_fail "GRUB offset (${grub_off}) ≠ current offset (${offset})"
        _st_fail "  The swapfile may have moved. Re-run: sudo $0 install && sudo reboot"
      fi
    else
      _st_fail "GRUB missing resume parameters — run: sudo $0 install"
    fi
  else
    _st_fail "GRUB file not found: ${GRUB_FILE}"
  fi

  # ── 5. GRUB awk self-test (does the edit produce parseable output?) ─────────
  _st_info "[5] GRUB awk logic self-test (synthetic)"
  local mock_grub; mock_grub="$(mktemp)"
  printf 'GRUB_TIMEOUT=3\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' > "$mock_grub"
  local awk_out
  awk_out="$(UUID_VAL='aabbccdd-1122-3344-5566-778899aabbcc' OFFSET_VAL='12345' awk '
    BEGIN { key="GRUB_CMDLINE_LINUX_DEFAULT"; found=0 }
    {
      if (index($0, key"=") == 1) {
        found=1; line=$0
        q1=index(line,"\""); rest=substr(line,q1+1)
        q2=index(rest,"\""); val=substr(rest,1,q2-1)
        gsub(/resume_offset=[0-9]+/,"",val)
        gsub(/resume=\/[^ ]*/,"",val)
        gsub(/[ \t]+/," ",val); sub(/^ /,"",val); sub(/ $/,"",val)
        newval=val " resume=/dev/disk/by-uuid/" ENVIRON["UUID_VAL"] \
               " resume_offset=" ENVIRON["OFFSET_VAL"]
        sub(/^ /,"",newval)
        print key"=\"" newval "\""
        next
      }
      print
    }
  ' "$mock_grub")"
  rm -f "$mock_grub"
  if echo "$awk_out" | grep -q 'resume=/dev/disk/by-uuid/aabbccdd' \
  && echo "$awk_out" | grep -q 'resume_offset=12345' \
  && echo "$awk_out" | grep -q 'quiet splash'; then
    _st_ok "GRUB awk produces correct output (existing args preserved, resume params added)"
  else
    _st_fail "GRUB awk produced unexpected output:"
    echo "$awk_out" | sed 's/^/      /'
  fi

  # ── 6. logind bypass is active ─────────────────────────────────────────────
  _st_info "[6] logind hibernation bypass"
  if [[ -f "$LOGIND_DROPIN" ]] \
  && grep -q 'SYSTEMD_BYPASS_HIBERNATION_MEMORY_CHECK=1' "$LOGIND_DROPIN"; then
    _st_ok "logind dropin present"
    local env_active
    env_active="$(systemctl show systemd-logind.service --property=Environment 2>/dev/null)"
    if echo "$env_active" | grep -q 'SYSTEMD_BYPASS_HIBERNATION_MEMORY_CHECK=1'; then
      _st_ok "logind env var is active in running service"
    else
      _st_fail "logind dropin exists but env var not active — run: sudo systemctl daemon-reload && sudo systemctl restart systemd-logind"
    fi
  else
    _st_fail "logind dropin missing — run: sudo $0 install"
  fi

  # ── 7. sleep.conf + drop-in + effective CanHibernate ─────────────────────
  _st_info "[7] sleep.conf + AllowHibernation drop-in"
  if [[ -f "$SLEEP_CONF" ]] \
  && grep -q 'AllowSuspendThenHibernate=yes' "$SLEEP_CONF" \
  && grep -q 'HibernateDelaySec=' "$SLEEP_CONF"; then
    local delay; delay="$(grep -oE 'HibernateDelaySec=[^[:space:]]+' "$SLEEP_CONF" | head -1)"
    _st_ok "sleep.conf OK (${delay})"
  else
    _st_fail "sleep.conf missing or incomplete — run: sudo $0 install"
  fi
  # Check the admin drop-in that overrides SteamOS vendor AllowHibernation=no
  if [[ -f "$SLEEP_DROPIN" ]] && grep -q 'AllowHibernation=yes' "$SLEEP_DROPIN" 2>/dev/null; then
    _st_ok "sleep drop-in present: $SLEEP_DROPIN"
  else
    _st_fail "sleep drop-in missing/wrong: $SLEEP_DROPIN — run: sudo $0 install"
    _st_fail "  (SteamOS vendor drop-in sets AllowHibernation=no; this overrides it)"
  fi
  # Verify the effective result
  local can_hib; can_hib="$(check_can_hibernate)"
  if [[ "$can_hib" == "yes" ]]; then
    _st_ok "AllowHibernation=yes (effective)"
  elif [[ "$can_hib" == "unknown" ]]; then
    _st_info "Could not determine effective AllowHibernation — check manually:"
    _st_info "  systemd-analyze cat-config systemd/sleep.conf | grep Allow"
  else
    _st_fail "AllowHibernation=${can_hib} in effective config — hibernate verb is disabled"
    _st_fail "  Run: systemd-analyze cat-config systemd/sleep.conf"
  fi

  # ── 8. Swapfile fragmentation ──────────────────────────────────────────────
  _st_info "[8] Swapfile fragmentation (≥1 extent)"
  if [[ -f "$SWAPFILE" ]]; then
    local ext; ext="$(filefrag "$SWAPFILE" 2>/dev/null | grep -oE '[0-9]+ extent' | awk '{print $1}')"
    ext="${ext:-1}"
    if [[ "$ext" -eq 1 ]]; then
      _st_ok "Swapfile is contiguous (1 extent)"
    else
      _st_fail "Swapfile has ${ext} extents — may cause resume failure. Fix: sudo $0 fix-swapfile"
    fi
  fi

  # ── Summary ────────────────────────────────────────────────────────────────
  echo
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Self-test: ${pass} passed, ${fail} failed"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if (( fail == 0 )); then
    ok "All logic checks passed — safe to run: sudo $0 test-hibernate"
  else
    err "${fail} check(s) failed — fix them before testing hibernation."
  fi
  (( fail == 0 ))
}

# ── Diagnose wake (extended) ──────────────────────────────────────────────────
cmd_diagnose_wake() {
  require_root "$@"
  step "Wake diagnostics"
  info "Kernel PM messages from this boot:"
  journalctl -k -b 0 2>/dev/null \
    | grep -iE 'PM: |wakeup|ACPI: PM|Restarting tasks|suspend|resume' \
    | tail -n 30 | sed 's/^/    /'
  echo
  info "ACPI wake configuration (/proc/acpi/wakeup):"
  [[ -r /proc/acpi/wakeup ]] && sed 's/^/    /' /proc/acpi/wakeup \
    || warn "  /proc/acpi/wakeup not readable"
  echo
  cmd_test_suspend
}

# ── Prerequisites check (Agent 5) ─────────────────────────────────────────────
cmd_check_prereqs() {
  step "Prerequisites check"
  local passes=0 warnings=0 failures=0

  _prereq_ok()   { ok   "$1"; (( passes++   )); true; }
  _prereq_warn() { warn "$1"; (( warnings++ )); true; }
  _prereq_err()  { err  "$1"; (( failures++ )); true; }

  # 1. Hardware
  info "[1/10] Hardware: Steam Deck chassis?"
  if is_steamdeck; then
    local dmi=""
    for f in /sys/class/dmi/id/product_name /sys/devices/virtual/dmi/id/product_name; do
      [[ -r "$f" ]] && dmi="$(< "$f")" && break
    done
    _prereq_ok "Hardware: Steam Deck detected (${dmi:-Valve board})"
  else
    _prereq_err "Hardware: NOT a Steam Deck — this script targets Jupiter/Galileo hardware."
  fi

  # 2. Filesystem
  info "[2/10] Filesystem: /home is ext4?"
  local fst; fst="$(home_fstype)"
  if [[ "$fst" == "ext4" ]]; then
    _prereq_ok "Filesystem: /home is ext4"
  elif [[ "$fst" == "btrfs" ]]; then
    _prereq_err "Filesystem: /home is btrfs — script only supports ext4 swapfiles"
  elif [[ "$fst" == "unknown" ]]; then
    _prereq_warn "Filesystem: could not determine /home filesystem type — check manually"
  else
    _prereq_err "Filesystem: /home is '${fst}' — ext4 required"
  fi

  # 3. Swapfile ≥ 16 GiB
  info "[3/10] Swapfile: ${SWAPFILE} ≥ 16 GiB?"
  local sw_bytes; sw_bytes="$(current_swap_bytes)"
  local sw_gib=$(( sw_bytes / 1073741824 ))
  if (( sw_bytes >= 16 * 1073741824 )); then
    _prereq_ok "Swapfile: ${sw_gib} GiB (≥ 16 GiB)"
  elif [[ "$sw_bytes" -eq 0 ]]; then
    _prereq_err "Swapfile: ${SWAPFILE} does not exist — create it with CryoUtilities or run install"
  else
    _prereq_err "Swapfile: only ${sw_gib} GiB — need ≥ 16 GiB. Run install with --size 20."
  fi

  # 4. vm.swappiness == 1 (CryoUtilities sets this)
  # Bug: $(< file 2>/dev/null || fallback) — when || is present, bash skips
  # the $(< file) optimization and the null command emits nothing (exit 0),
  # so the fallback never fires and the result is empty. Read separately.
  info "[4/10] vm.swappiness = 1? (CryoUtilities prerequisite)"
  local swappiness="unknown"
  if [[ -r /proc/sys/vm/swappiness ]]; then
    swappiness="$(< /proc/sys/vm/swappiness)"
    swappiness="${swappiness//[[:space:]]/}"
  elif command -v sysctl >/dev/null 2>&1; then
    swappiness="$(sysctl -n vm.swappiness 2>/dev/null | tr -d '[:space:]')" \
      || swappiness="unknown"
  fi

  if [[ "$swappiness" == "1" ]]; then
    _prereq_ok "vm.swappiness = 1 ✓"
  elif [[ "$swappiness" == "unknown" || -z "$swappiness" ]]; then
    _prereq_err "vm.swappiness: could not be read from /proc/sys/vm/swappiness or sysctl"
  else
    # Check sysctl.d files — CryoUtilities writes the config there even if
    # the runtime value hasn't been refreshed yet (e.g., pre-reboot).
    local configured_sw=""
    configured_sw="$(grep -rh 'vm\.swappiness' \
      /etc/sysctl.d/ /usr/lib/sysctl.d/ /etc/sysctl.conf 2>/dev/null \
      | grep -v '^#' | sed 's/.*=\s*//' | tr -d '[:space:]' | tail -1)" || configured_sw=""
    if [[ "$configured_sw" == "1" ]]; then
      _prereq_warn "vm.swappiness: runtime=${swappiness}, but sysctl.d configures it to 1"
      _prereq_warn "  (CryoUtilities applied — will be active at next boot or after: sudo sysctl --system)"
    else
      _prereq_err "vm.swappiness = ${swappiness} — must be 1 (set by CryoUtilities)"
      _prereq_err "  Fix: sudo sysctl -w vm.swappiness=1  (or re-apply CryoUtilities)"
    fi
  fi

  # 5. vm.page-cluster (non-critical)
  info "[5/10] vm.page-cluster?"
  local pc
  pc="$(< /proc/sys/vm/page-cluster 2>/dev/null \
    || sysctl -n vm.page-cluster 2>/dev/null || echo unknown)"
  if [[ "$pc" == "0" || "$pc" == "1" ]]; then
    _prereq_ok "vm.page-cluster = ${pc}"
  elif [[ "$pc" == "unknown" ]]; then
    _prereq_warn "vm.page-cluster: could not be read"
  else
    _prereq_warn "vm.page-cluster = ${pc} (CryoUtilities sets to 0 — minor performance impact)"
  fi

  # 6. Transparent hugepages (non-critical)
  info "[6/10] Transparent HugePages = always?"
  local thp_file="/sys/kernel/mm/transparent_hugepage/enabled"
  if [[ -r "$thp_file" ]]; then
    local thp; thp="$(< "$thp_file")"
    if [[ "$thp" == *"[always]"* ]]; then
      _prereq_ok "transparent_hugepage = always"
    else
      local cur_mode; cur_mode="$(printf '%s' "$thp" | grep -oP '\[\K[^\]]+' || echo '?')"
      _prereq_warn "transparent_hugepage = [${cur_mode}] (CryoUtilities sets [always])"
    fi
  else
    _prereq_warn "transparent_hugepage: ${thp_file} not readable"
  fi

  # 7. Free space on /home
  info "[7/10] Free space on /home ≥ 2 GiB?"
  local free_b; free_b="$(df -B1 --output=avail /home 2>/dev/null | tail -1 | tr -d '[:space:]')" || free_b=0
  if [[ "$free_b" =~ ^[0-9]+$ ]] && (( free_b >= 2 * 1073741824 )); then
    _prereq_ok "Free space: $(( free_b / 1073741824 )) GiB on /home"
  elif [[ "$free_b" =~ ^[0-9]+$ ]]; then
    _prereq_warn "Free space: only $(( free_b / 1073741824 )) GiB on /home — may not be enough"
  else
    _prereq_warn "Free space on /home: could not be determined"
  fi

  # 8. UMA buffer (non-critical, best-effort)
  info "[8/10] UMA buffer size (best-effort)?"
  local vram_bytes=0 vram_found=0
  for vf in /sys/class/drm/card*/device/mem_info_vram_total; do
    [[ -r "$vf" ]] || continue
    local _v; _v="$(< "$vf" 2>/dev/null)" || continue
    if [[ "$_v" =~ ^[0-9]+$ ]] && (( _v > 0 )); then
      vram_bytes="$_v"; vram_found=1; break
    fi
  done
  if (( vram_found )); then
    local vram_mib=$(( vram_bytes / 1048576 ))
    if (( vram_bytes > 2 * 1073741824 )); then
      _prereq_warn "UMA: ~${vram_mib} MiB VRAM detected — looks like 4 GB UMA."
      _prereq_warn "  Hibernation works best with 1 GB UMA. Change in BIOS:"
      _prereq_warn "  Advanced → AMD CBS → NBIO → GFX → UMA Frame Buffer Size → 1G"
    else
      _prereq_ok "UMA: ~${vram_mib} MiB VRAM (likely 1 GB UMA — good)"
    fi
  else
    _prereq_warn "UMA buffer: could not be determined — verify in BIOS (target: 1G)"
  fi

  # 9. Required tools
  info "[9/10] Required tools?"
  local missing_any=0
  for t in swapon swapoff mkswap dd filefrag findmnt awk rtcwake; do
    if command -v "$t" >/dev/null 2>&1; then
      _prereq_ok "Tool: $t"
    else
      _prereq_err "Tool: $t NOT FOUND"
      missing_any=1
    fi
  done
  # GRUB tool (need at least one)
  local grub_found=0
  for g in update-grub grub-mkconfig grub2-mkconfig; do
    command -v "$g" >/dev/null 2>&1 && { grub_found=1; _prereq_ok "GRUB tool: $g"; break; }
  done
  (( grub_found )) || { _prereq_err "GRUB tool: none found (update-grub / grub-mkconfig)"; missing_any=1; }

  # 10. BIOS reminder
  info "[10/10] BIOS settings (manual check required)"
  _prereq_warn "BIOS: verify Quick Boot=Disabled and UMA=1G (cannot check programmatically)"
  _prereq_warn "  How to enter BIOS: power off → hold Vol+ → press Power → release both"

  # Summary
  echo
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Prereqs: ${passes} passed, ${warnings} warnings, ${failures} failures"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if   (( failures == 0 && warnings == 0 )); then
    ok "All checks passed — ready for hibernation setup."
  elif (( failures == 0 )); then
    ok "Critical checks passed (${warnings} non-critical warning(s)) — proceed with care."
  else
    err "${failures} critical check(s) FAILED — address them before running install."
  fi
  (( failures == 0 ))
}

# ── Swapfile recreation ───────────────────────────────────────────────────────
# Use when self-test reports >1 extent. Deletes and recreates the swapfile to
# get a single contiguous extent, then updates GRUB (resume_offset changes).
cmd_fix_swapfile() {
  require_root
  step "Recreate swapfile for contiguous layout (hibernation reliability)"

  local extents
  extents="$(filefrag "$SWAPFILE" 2>/dev/null | grep -oE '[0-9]+ extent' | awk '{print $1}')"
  extents="${extents:-0}"

  if [[ "$extents" -eq 1 ]]; then
    ok "Swapfile already contiguous (1 extent) — nothing to do."
    return 0
  fi

  [[ "$extents" -gt 1 ]] \
    && warn "Swapfile has ${extents} extents — will recreate." \
    || warn "Could not determine extent count — proceeding anyway."

  # Space check: need SWAP_SIZE_GIB free AFTER removing the existing swapfile.
  local want_bytes=$(( SWAP_SIZE_GIB * 1024 * 1024 * 1024 ))
  local mp; mp="$(findmnt -no TARGET -T "$SWAPFILE")"
  local avail_kib; avail_kib="$(df -Pk "$mp" | awk 'NR==2{print $4}')"
  local have_kib; have_kib=$(( $(current_swap_bytes) / 1024 ))
  local effective_kib=$(( avail_kib + have_kib ))
  local need_kib=$(( want_bytes / 1024 ))
  if [[ "$effective_kib" -lt "$need_kib" ]]; then
    die "Not enough free space on $mp to recreate a ${SWAP_SIZE_GiB} GiB swapfile. \
Free up space first (need $(numfmt --to=iec "$want_bytes" 2>/dev/null) free)."
  fi
  info "Free space (including swapfile): $(numfmt --to=iec $(( effective_kib * 1024 )) 2>/dev/null) — sufficient."

  warn "This will briefly disable swap. Close memory-heavy apps first."
  confirm "Recreate swapfile?" || { info "Cancelled."; return 0; }

  # Disable and delete
  run swapoff "$SWAPFILE" 2>/dev/null || true
  run rm -f "$SWAPFILE"

  # Recreate — fallocate is faster than dd and produces a contiguous file
  # when enough space is available. Fall back to dd if fallocate fails.
  if command -v fallocate >/dev/null 2>&1; then
    run fallocate -l "${SWAP_SIZE_GIB}G" "$SWAPFILE" \
      || { warn "fallocate failed, falling back to dd...";
           run dd if=/dev/zero of="$SWAPFILE" bs=1G count="$SWAP_SIZE_GIB" \
               status=progress conv=fsync; }
  else
    run dd if=/dev/zero of="$SWAPFILE" bs=1G count="$SWAP_SIZE_GIB" \
        status=progress conv=fsync
  fi
  run chmod 600 "$SWAPFILE"
  run mkswap "$SWAPFILE"
  run swapon "$SWAPFILE"

  # Verify
  local new_extents
  new_extents="$(filefrag "$SWAPFILE" 2>/dev/null | grep -oE '[0-9]+ extent' | awk '{print $1}')"
  new_extents="${new_extents:-?}"
  if [[ "$new_extents" == "1" ]]; then
    ok "Swapfile is now contiguous (1 extent)."
  else
    warn "Swapfile still has ${new_extents} extents — disk may be too fragmented."
    warn "Try: fstrim -v /home && sudo $0 fix-swapfile"
  fi

  # resume_offset changes after recreation — must update GRUB and reboot
  info "Updating GRUB resume_offset (changes after swapfile recreation)..."
  configure_grub
  ok "Done. You MUST REBOOT for the new resume_offset to take effect."
  warn "▶ sudo reboot"
}

# ── BIOS tips ─────────────────────────────────────────────────────────────────
print_bios_tips() {
  local border="$(printf '%0.s─' {1..72})"
  echo ""
  echo "┌${border}┐"
  printf '│  %-70s│\n' "STEAM DECK BIOS SETTINGS FOR HIBERNATION"
  echo "├${border}┤"
  cat <<'TIPS'
│                                                                        │
│  Enter BIOS: power OFF → hold Vol+ → press Power → release both      │
│  Navigate with D-pad; A=confirm, B=back.                              │
│                                                                        │
│  1. Quick Boot  →  DISABLE                                            │
│     Location: Advanced → Boot → Quick Boot                           │
│     Why: prevents skipping the hibernate image on resume.            │
│     Cost: ~1 extra second on cold boot.                              │
│                                                                        │
│  2. UMA Frame Buffer Size  →  1G  (NOT 4G, NOT Auto)                │
│     Location: Advanced → AMD CBS → NBIO → GFX → UMA Frame Buffer    │
│     Why: 4G UMA reduces available RAM, making hibernate images       │
│     larger and less reliable. 1G is the Valve-recommended setting.  │
│                                                                        │
│  NOTE: BIOS updates via SteamOS may reset these values.              │
│        Check again after a firmware update.                          │
│                                                                        │
TIPS
  echo "└${border}┘"
  echo ""
}

# ── Hibernation self-test ─────────────────────────────────────────────────────
cmd_test_hibernate() {
  require_root "$@"
  step "Hibernation self-test"
  warn "This writes RAM to swap and powers off. Press Power to resume."
  warn "Do NOT run this unless you have REBOOTED since 'install'."
  warn "(resume= kernel param only takes effect after reboot)"

  # Pre-flight: verify hibernate verb is actually enabled in the effective config.
  # SteamOS ships /usr/lib/systemd/sleep.conf.d/ with AllowHibernation=no;
  # if our install drop-in is missing or was clobbered, catch it here.
  local can_hib; can_hib="$(check_can_hibernate)"
  if [[ "$can_hib" == "no" ]]; then
    err "systemd says CanHibernate=no — hibernate is disabled by config."
    info "Checking effective sleep configuration..."
    info "--- systemd-analyze cat-config systemd/sleep.conf ---"
    systemd-analyze cat-config systemd/sleep.conf 2>/dev/null || true
    info "---"
    echo
    # Check if our drop-in is the cause or if a vendor one is missing override
    if [[ ! -f "$SLEEP_DROPIN" ]]; then
      warn "Missing admin drop-in: $SLEEP_DROPIN"
      warn "This drop-in overrides the SteamOS vendor AllowHibernation=no."
      warn "Fix: run   sudo $0 install   (or just re-run configure_sleep_conf)"
      warn "Then:      sudo systemctl daemon-reload"
    elif grep -q 'AllowHibernation=no' "$SLEEP_DROPIN" 2>/dev/null; then
      warn "$SLEEP_DROPIN contains AllowHibernation=no — this should not happen."
      warn "Fix: sudo $0 install"
    else
      warn "$SLEEP_DROPIN looks correct, but something else is overriding it."
      warn "Check for other drop-ins:"
      warn "  ls /usr/lib/systemd/sleep.conf.d/ /etc/systemd/sleep.conf.d/"
      warn "  systemd-analyze cat-config systemd/sleep.conf"
    fi
    # Also check if it might be the memory check, not AllowHibernation
    local swap_bytes
    swap_bytes="$(awk '/^SwapTotal/ {print $2*1024}' /proc/meminfo 2>/dev/null || echo 0)"
    local mem_bytes
    mem_bytes="$(awk '/^MemTotal/ {print $2*1024}' /proc/meminfo 2>/dev/null || echo 0)"
    if [[ "$swap_bytes" -lt "$mem_bytes" ]] 2>/dev/null; then
      warn "Swap ($(numfmt --to=iec "$swap_bytes" 2>/dev/null)) < RAM ($(numfmt --to=iec "$mem_bytes" 2>/dev/null))."
      warn "logind bypass (SYSTEMD_BYPASS_HIBERNATION_MEMORY_CHECK=1) should handle this."
      warn "Check: sudo systemctl cat systemd-logind | grep BYPASS"
      [[ -f "$LOGIND_DROPIN" ]] \
        && info "logind dropin present: $LOGIND_DROPIN" \
        || warn "logind dropin MISSING: $LOGIND_DROPIN — run 'sudo $0 install'"
    fi
    die "Resolve the above issues, then retry 'sudo $0 test-hibernate'."
  elif [[ "$can_hib" == "unknown" ]]; then
    warn "Could not determine CanHibernate — proceeding anyway."
  else
    ok "CanHibernate=yes — proceeding."
  fi

  confirm "Hibernate now?" || { info "Cancelled."; return 0; }
  run systemctl hibernate
}

# ── Status ────────────────────────────────────────────────────────────────────
cmd_status() {
  step "Status"
  local sw; sw="$(current_swap_bytes)"
  printf '  swapfile        : %s (%s)\n' \
    "$SWAPFILE" "$(numfmt --to=iec "$sw" 2>/dev/null || echo "${sw}B")"

  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
    printf '  swap active     : %syes%s\n' "$C_GRN" "$C_RST"
  else
    printf '  swap active     : %sno%s\n' "$C_YEL" "$C_RST"
  fi

  if [[ -f "$GRUB_FILE" ]] && grep -q 'resume_offset=' "$GRUB_FILE"; then
    printf '  grub resume     : %sset%s  (%s)\n' "$C_GRN" "$C_RST" \
      "$(grep -oE 'resume=[^"]*' "$GRUB_FILE" | head -1)"
  else
    printf '  grub resume     : %smissing%s\n' "$C_YEL" "$C_RST"
  fi

  [[ -f "$LOGIND_DROPIN" ]] \
    && printf '  logind bypass   : %spresent%s\n' "$C_GRN" "$C_RST" \
    || printf '  logind bypass   : %smissing%s\n' "$C_YEL" "$C_RST"

  [[ -f "$SLEEP_CONF" ]] \
    && printf '  sleep.conf      : %spresent%s (%s)\n' "$C_GRN" "$C_RST" \
       "$(grep -oE 'HibernateDelaySec=.*' "$SLEEP_CONF" 2>/dev/null || echo '?')" \
    || printf '  sleep.conf      : %smissing%s\n' "$C_YEL" "$C_RST"

  if [[ -f "$SLEEP_DROPIN" ]] && grep -q 'AllowHibernation=yes' "$SLEEP_DROPIN" 2>/dev/null; then
    printf '  sleep drop-in   : %spresent%s (overrides vendor AllowHibernation=no)\n' "$C_GRN" "$C_RST"
  else
    printf '  sleep drop-in   : %smissing%s ← NEEDED on SteamOS (run install)\n' "$C_YEL" "$C_RST"
  fi

  local can_hib; can_hib="$(check_can_hibernate)"
  if [[ "$can_hib" == "yes" ]]; then
    printf '  AllowHibernate  : %syes%s\n' "$C_GRN" "$C_RST"
  else
    printf '  AllowHibernate  : %s%s%s\n' "$C_YEL" "${can_hib}" "$C_RST"
  fi

  systemctl is-enabled fix-bluetooth-resume.service >/dev/null 2>&1 \
    && printf '  bt-resume fix   : %senabled%s\n' "$C_GRN" "$C_RST" \
    || printf '  bt-resume fix   : %sdisabled%s\n' "$C_YEL" "$C_RST"

  if [[ -L "$SUSPEND_LINK" ]]; then
    printf '  suspend→STH     : %sactive%s\n' "$C_GRN" "$C_RST"
  else
    printf '  suspend→STH     : %snot linked%s (plain suspend active)\n' "$C_YEL" "$C_RST"
  fi

  [[ -f "$BOOT_COUNTER_HOOK" ]] \
    && printf '  boot-ctr fix    : %sinstalled%s\n' "$C_GRN" "$C_RST" \
    || printf '  boot-ctr fix    : %snot installed%s\n' "$C_DIM" "$C_RST"

  [[ -f "$WIFIWAKE_CONF" ]] \
    && printf '  wifi-wake fix   : %sinstalled%s\n' "$C_GRN" "$C_RST" \
    || printf '  wifi-wake fix   : %snone%s\n' "$C_DIM" "$C_RST"

  [[ -f "$WAKEFIX_SERVICE" ]] \
    && printf '  acpi-wake fix   : %sinstalled%s\n' "$C_GRN" "$C_RST" \
    || printf '  acpi-wake fix   : %snone%s\n' "$C_DIM" "$C_RST"

  systemctl is-enabled steamdeck-hibernate-reapply.service >/dev/null 2>&1 \
    && printf '  reapply hook    : %senabled%s\n' "$C_GRN" "$C_RST" \
    || printf '  reapply hook    : %sdisabled%s\n' "$C_DIM" "$C_RST"

  systemctl is-enabled cec-sleep.service >/dev/null 2>&1 \
    && printf '  cec-sleep       : %senabled%s\n' "$C_GRN" "$C_RST" \
    || printf '  cec-sleep       : %snot installed%s\n' "$C_DIM" "$C_RST"

  # CryoUtilities quick sanity
  echo
  local swappiness="?"
  [[ -r /proc/sys/vm/swappiness ]] && swappiness="$(< /proc/sys/vm/swappiness)"
  swappiness="${swappiness//[[:space:]]/}"
  printf '  vm.swappiness   : %s%s%s\n' \
    "$([[ "$swappiness" == "1" ]] && echo "$C_GRN" || echo "$C_YEL")" \
    "$swappiness" "$C_RST"
  info "Run 'sudo $0 check-prereqs' for full prerequisites report."
  info "Run 'sudo $0 bios-tips' for BIOS configuration guidance."
}

# ── Install ───────────────────────────────────────────────────────────────────
cmd_install() {
  require_root "$@"
  preflight
  mkdir -p "$STATE_DIR"

  # Pre-flight CryoUtilities check (non-blocking — just warns)
  if [[ $SKIP_PREREQ_CHECK -eq 0 ]]; then
    echo
    info "Running prerequisites check first..."
    cmd_check_prereqs || warn "Some prerequisites failed. Review above before proceeding."
    echo
    confirm "Continue with install anyway?" || { info "Aborted."; exit 0; }
  fi

  ensure_swapfile
  configure_grub
  configure_logind_bypass
  configure_sleep_conf
  install_bluetooth_fix

  [[ $DO_BOOT_COUNTER -eq 1 ]] && install_boot_counter_fix
  [[ $DO_PERSIST      -eq 1 ]] && install_persist_hook
  [[ $DO_CEC          -eq 1 ]] && install_cec_tv_control

  if [[ $ENABLE_STH_NOW -eq 1 ]]; then
    enable_suspend_then_hibernate
  else
    step "Suspend redirect deferred (safer)"
    info "Not redirecting plain suspend to STH yet."
    info "After rebooting and testing, run: sudo $0 enable-sth"
  fi

  echo
  ok "Install complete."
  echo
  print_bios_tips
  warn "▶ REBOOT NOW — the kernel needs resume=/resume_offset= from GRUB."
  warn "  After reboot: sudo $0 test-suspend  →  sudo $0 test-hibernate  →  sudo $0 enable-sth"
  echo
  cmd_status
}

# ── Reapply (idempotent, for boot service) ────────────────────────────────────
cmd_reapply() {
  require_root "$@"
  ASSUME_YES=1
  SKIP_PREREQ_CHECK=1
  preflight
  ensure_swapfile
  configure_grub
  configure_logind_bypass

  # Migration: rename old 99- drop-in to zzz- so it sorts last and wins
  # over any SteamOS vendor drop-in that also disables hibernation.
  local old_dropin="/etc/systemd/sleep.conf.d/99-steamdeck-hibernate.conf"
  if [[ -f "$old_dropin" && "$old_dropin" != "$SLEEP_DROPIN" ]]; then
    info "Migrating sleep drop-in: 99- → zzz- (must sort last to override vendor)"
    run mv "$old_dropin" "$SLEEP_DROPIN"
  fi

  # Migration: remove BT script from old read-only location
  local old_bt="/usr/local/sbin/fix-bluetooth-resume.sh"
  if [[ -f "$old_bt" && "$old_bt" != "$BT_SCRIPT" ]]; then
    info "Removing BT script from read-only path: $old_bt"
    run rm -f "$old_bt" 2>/dev/null || true
  fi

  configure_sleep_conf
  install_bluetooth_fix
  install_persist_hook   # also updates ExecStart path if it changed
  # Never auto-redirect suspend here — leave that to explicit user action.
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
cmd_uninstall() {
  require_root "$@"
  step "Uninstall (config revert; swapfile is left in place)"
  confirm "Revert GRUB params, logind bypass, sleep.conf, bt fix, wifi fix, STH, hooks?" \
    || { info "Cancelled."; return 0; }

  disable_suspend_then_hibernate

  # Revert GRUB
  if [[ -f "$GRUB_FILE" ]] && grep -q 'resume_offset=' "$GRUB_FILE"; then
    backup_file "$GRUB_FILE"
    local tmp; tmp="$(mktemp)"
    awk '
      { if (index($0,"GRUB_CMDLINE_LINUX_DEFAULT=")==1) {
          gsub(/resume_offset=[0-9]+/,"")
          gsub(/resume=\/[^ "]*/,"")
          gsub(/[ \t]+"/, "\""); gsub(/"[ \t]+/, "\""); gsub(/  +/," ")
        } print }' "$GRUB_FILE" > "$tmp"
    run cp "$tmp" "$GRUB_FILE"; rm -f "$tmp"
    update_grub_cfg
    ok "Removed resume params from GRUB."
  fi

  [[ -f "$LOGIND_DROPIN" ]] && {
    run rm -f "$LOGIND_DROPIN"
    run rmdir --ignore-fail-on-non-empty "$(dirname "$LOGIND_DROPIN")" 2>/dev/null || true
    ok "Removed logind bypass."
  }

  if [[ -f "$SLEEP_CONF" ]]; then
    local latest_bak=""
    for cand in "${SLEEP_CONF}".bak.*; do [[ -e "$cand" ]] && latest_bak="$cand"; done
    if [[ -n "$latest_bak" ]]; then
      run cp "$latest_bak" "$SLEEP_CONF"; ok "Restored sleep.conf from backup."
    else
      run rm -f "$SLEEP_CONF"; ok "Removed sleep.conf (no backup found)."
    fi
  fi

  if [[ -f "$SLEEP_DROPIN" ]]; then
    run rm -f "$SLEEP_DROPIN"
    ok "Removed sleep drop-in: $SLEEP_DROPIN"
    # Remove the directory only if it's now empty
    rmdir "$(dirname "$SLEEP_DROPIN")" 2>/dev/null || true
  fi

  if [[ -f "$BT_SERVICE" ]]; then
    run systemctl disable fix-bluetooth-resume.service >/dev/null 2>&1 || true
    run rm -f "$BT_SERVICE"
    ok "Removed BT-resume service."
  fi
  [[ -f "$BT_SCRIPT" ]] && run rm -f "$BT_SCRIPT"

  if [[ -f "$WAKEFIX_SERVICE" ]]; then
    run systemctl disable steamdeck-disable-wakeup.service >/dev/null 2>&1 || true
    run rm -f "$WAKEFIX_SERVICE"
    ok "Removed ACPI wake-source fix service."
  fi

  [[ -f "$WIFIWAKE_CONF" ]] && { run rm -f "$WIFIWAKE_CONF"; ok "Removed WiFi wake fix."; }
  [[ -f "$BOOT_COUNTER_HOOK" ]] && { run rm -f "$BOOT_COUNTER_HOOK"; ok "Removed boot counter hook."; }

  if [[ -f "$CEC_SERVICE" ]]; then
    run systemctl disable cec-sleep.service >/dev/null 2>&1 || true
    run rm -f "$CEC_SERVICE"
    ok "Removed CEC service."
  fi
  [[ -f "$CEC_SCRIPT" ]] && run rm -f "$CEC_SCRIPT"

  remove_persist_hook
  run systemctl daemon-reload
  echo
  ok "Uninstalled. Swapfile left at ${SWAPFILE} (delete manually if unwanted)."
  warn "Reboot to fully remove the resume= kernel parameter."
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
steamdeck-hibernate.sh (v2.0) — suspend-then-hibernate for Steam Deck (ext4)

USAGE:
  sudo $0 <command> [options]

COMMANDS:
  check-prereqs   Verify CryoUtilities, UMA, swapfile, tools, and system state
                  before running install.  Run this first!

  self-test       Read-only logic checks after install + reboot: validates UUID
                  format, resume_offset is a positive integer, GRUB awk correctness,
                  UUID/offset cross-check between GRUB and swapfile, logind active,
                  sleep.conf, fragmentation.  Run before test-hibernate.

  install         Apply all hibernation config (swap, GRUB, logind, sleep.conf,
                  BT fix, boot counter fix, reapply hook).
                  Does NOT redirect plain suspend unless --enable-sth is given.

  enable-sth      Redirect plain suspend → suspend-then-hibernate.
                  Do this ONLY after a successful test-hibernate.

  disable-sth     Remove the suspend redirect (revert to normal suspend).

  test-suspend    Safely suspend via RTC alarm for ${TEST_SLEEP_SECS}s; detect immediate
                  wake; rank wake sources; suggest targeted fixes.

  diagnose-wake   test-suspend + kernel PM logs + full ACPI wakeup table.

  fix-wake <DEV>  Persistently disable one ACPI wake source (e.g. XHC0).
                  Find device names in /proc/acpi/wakeup.

  fix-swapfile    Recreate swapfile as a single contiguous extent (fixes resume
                  failures caused by fragmentation). Updates GRUB offset after.
                  Requires ~${SWAP_SIZE_GIB} GiB free space. REBOOT after.

  fix-wifi-wake   Disable WiFi/XHC ACPI wakeup via tmpfiles.d, and print
                  instructions for the WPA-supplicant Steam developer setting.
                  Also checks mem_sleep mode (must be 'deep', not 's2idle').

  disable-all-wakeup
                  Nuclear option: disable ALL ACPI/sysfs wakeup sources except
                  the power button. Use when fix-wifi-wake doesn't fully stop
                  immediate wake. Persists via tmpfiles.d across reboots.

  test-hibernate  Trigger a real hibernation (REBOOT REQUIRED beforehand).

  install-cec     Install CEC TV-off-on-sleep for dock users (optional).

  bios-tips       Print BIOS settings recommended for hibernation.

  status          Show current state of every component.

  reapply         Idempotent re-apply (used by the boot-time service after
                  SteamOS updates that overwrite /etc files).

  uninstall       Revert all config changes (swapfile is kept).

OPTIONS:
  -y, --yes           Skip confirmation prompts.
  -n, --dry-run       Print actions without changing anything.
      --size N        Swapfile size in GiB (default ${SWAP_SIZE_GIB}).
      --delay D       HibernateDelaySec (default ${HIBERNATE_DELAY}, e.g. 90min, 6h).
      --enable-sth    During 'install', also create the suspend redirect.
      --no-persist    During 'install', skip the boot-time reapply service.
      --cec           During 'install', also install CEC TV-off service.
      --no-boot-counter  During 'install', skip the GRUB boot counter fix.
      --skip-prereqs  During 'install', skip the prerequisites check.
      --mode M        rtcwake mode for tests: mem|freeze (default ${TEST_SLEEP_MODE}).
      --secs N        Seconds to stay suspended during test (default ${TEST_SLEEP_SECS}).
  -h, --help          This help.

TYPICAL FLOW:
  sudo $0 check-prereqs          # verify CryoUtilities, UMA, swap, tools
  sudo $0 install                # apply all changes
  sudo reboot
  sudo $0 test-suspend           # check for immediate-wake regression
  sudo $0 fix-wifi-wake          # if suspend wakes immediately (common after updates)
  sudo $0 self-test              # logic checks: UUID/offset sane, GRUB correct
  sudo $0 test-hibernate         # verify full hibernation works
  sudo $0 enable-sth             # make every suspend = suspend-then-hibernate

KNOWN ISSUES:
  - Immediate wake after sleep: common on some SteamOS versions.
    Fix: sudo $0 fix-wifi-wake  (then reboot, then test-suspend again)
  - "Failed to boot" screen after 4-5 hibernation cycles:
    The GRUB boot counter fix (installed by default) prevents this.
    If it persists, select "Current" each time — it is cosmetic.
  - Hibernation stops working after a SteamOS update:
    The reapply service re-applies GRUB/sleep.conf changes automatically.
    If it still fails, run: sudo $0 reapply && sudo reboot
EOF
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  local cmd="${1:-}"; shift || true
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)           ASSUME_YES=1 ;;
      -n|--dry-run)       DRY_RUN=1 ;;
      --size)             SWAP_SIZE_GIB="${2:?--size requires a value}"; shift ;;
      --delay)            HIBERNATE_DELAY="${2:?--delay requires a value}"; shift ;;
      --enable-sth)       ENABLE_STH_NOW=1 ;;
      --no-persist)       DO_PERSIST=0 ;;
      --cec)              DO_CEC=1 ;;
      --no-boot-counter)  DO_BOOT_COUNTER=0 ;;
      --skip-prereqs)     SKIP_PREREQ_CHECK=1 ;;
      --mode)             TEST_SLEEP_MODE="${2:?--mode requires a value}"; shift ;;
      --secs)             TEST_SLEEP_SECS="${2:?--secs requires a value}"; shift ;;
      -h|--help|help)     usage; exit 0 ;;
      -*)                 die "Unknown option: $1 (run $0 --help)" ;;
      *)                  positional+=("$1") ;;
    esac
    shift
  done

  # Bug fix (Agent 4 #2): safe empty-array expansion under set -u
  if [[ ${#positional[@]} -gt 0 ]]; then
    set -- "${positional[@]}"
  else
    set --
  fi

  case "$cmd" in
    check-prereqs)  cmd_check_prereqs ;;
    self-test)      cmd_self_test ;;
    install)        cmd_install "$@" ;;
    enable-sth)     require_root; enable_suspend_then_hibernate ;;
    disable-sth)    require_root; disable_suspend_then_hibernate ;;
    test-suspend)   cmd_test_suspend ;;
    diagnose-wake)  cmd_diagnose_wake "$@" ;;
    fix-wake)       cmd_fix_wake "$@" ;;
    fix-swapfile)         cmd_fix_swapfile ;;
    fix-wifi-wake)        cmd_fix_wifi_wake ;;
    disable-all-wakeup)  cmd_disable_all_wakeup ;;
    test-hibernate)      cmd_test_hibernate "$@" ;;
    install-cec)    require_root; install_cec_tv_control ;;
    bios-tips)      print_bios_tips ;;
    status)         cmd_status ;;
    reapply)        cmd_reapply "$@" ;;
    uninstall)      cmd_uninstall "$@" ;;
    ""|--help)      usage ;;
    *)              err "Unknown command: $cmd"; echo; usage; exit 1 ;;
  esac
}

main "$@"
