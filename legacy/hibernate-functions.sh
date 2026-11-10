#!/usr/bin/env bash
# hibernate-functions.sh — helper functions for steamdeck-hibernation installer
# Requires: ok(), warn(), err(), info(), step(), run(), confirm(), require_root()
# from the parent script, plus: DRY_RUN (0/1), DECK_USER (string)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
BOOT_COUNTER_SERVICE="/etc/systemd/system/steamdeck-fix-boot-counter.service"

# Default grub boot-counter value SteamOS writes on a fresh successful boot.
# Grub decrements it each failed attempt; when it hits 0 it marks boot_success=0.
# Resetting to 3 matches the SteamOS default.
_BOOT_COUNTER_DEFAULT=3

# Candidate grubenv paths (checked in order; first match wins)
_GRUBENV_CANDIDATES=(
    /boot/efi/EFI/steamos/grubenv
    /boot/efi/EFI/SteamOS/grubenv
    /boot/grub/grubenv
    /boot/grub2/grubenv
)

# ---------------------------------------------------------------------------
# fix_boot_counter()
#
# SteamOS uses a GRUB boot counter stored in a grubenv file on the EFI
# partition.  GRUB decrements the counter on every boot attempt and only
# resets it when the boot is declared "successful" by the running OS.
# Hibernation resume bypasses that reset path, so after ~3-5 hibernate
# cycles GRUB considers every boot a failure and presents the recovery
# menu ("choose between current and previous OS version").
#
# Fix: install a one-shot systemd service that fires *after* the system
# resumes from hibernate/suspend-then-hibernate and resets boot_counter
# back to its default value via grub-editenv.
# ---------------------------------------------------------------------------
fix_boot_counter() {
    step "Installing GRUB boot-counter reset service"
    require_root

    # -- 1. Locate grub-editenv -----------------------------------------------
    local grub_editenv
    if ! grub_editenv=$(command -v grub-editenv 2>/dev/null) \
       && ! grub_editenv=$(command -v grub2-editenv 2>/dev/null); then
        warn "grub-editenv not found in PATH."
        warn "Manual fix: after each hibernate cycle run one of:"
        warn "  grub-editenv /boot/efi/EFI/steamos/grubenv set boot_counter=${_BOOT_COUNTER_DEFAULT}"
        warn "  grub2-editenv /boot/efi/EFI/steamos/grubenv set boot_counter=${_BOOT_COUNTER_DEFAULT}"
        err "Cannot install boot-counter service without grub-editenv. Skipping."
        return 1
    fi
    info "Found grub-editenv: ${grub_editenv}"

    # -- 2. Locate the grubenv file -------------------------------------------
    local grubenv_path=""
    for candidate in "${_GRUBENV_CANDIDATES[@]}"; do
        if [[ -f "${candidate}" ]]; then
            grubenv_path="${candidate}"
            break
        fi
    done

    if [[ -z "${grubenv_path}" ]]; then
        warn "Could not locate a grubenv file in any of:"
        for candidate in "${_GRUBENV_CANDIDATES[@]}"; do
            warn "  ${candidate}"
        done
        warn "Manual fix: find your grubenv with:"
        warn "  find /boot/efi -name grubenv 2>/dev/null"
        warn "Then run:"
        warn "  grub-editenv <path> set boot_counter=${_BOOT_COUNTER_DEFAULT}"
        err "Cannot install boot-counter service without a grubenv path. Skipping."
        return 1
    fi
    info "Found grubenv: ${grubenv_path}"

    # -- 3. Sanity-check that grub-editenv can read/write the file ------------
    if ! "${grub_editenv}" "${grubenv_path}" list &>/dev/null; then
        warn "grub-editenv could not read ${grubenv_path} — permissions issue?"
        warn "Try: sudo ${grub_editenv} ${grubenv_path} list"
        err "Skipping boot-counter service installation."
        return 1
    fi

    local current_counter
    current_counter=$("${grub_editenv}" "${grubenv_path}" list 2>/dev/null \
        | grep '^boot_counter=' | cut -d= -f2 || true)
    if [[ -n "${current_counter}" ]]; then
        info "Current boot_counter value: ${current_counter}"
    else
        info "boot_counter variable not currently set in grubenv (may be absent until first failed boot)."
    fi

    # -- 4. Write the systemd service unit ------------------------------------
    # The service runs *after* resume completes so the reset happens in a
    # fully-booted userspace environment (EFI partition is mounted, etc.).
    # hibernate.target and suspend-then-hibernate.target are the two units
    # that SteamOS uses for the hibernate codepath.
    local service_content
    service_content=$(cat <<EOF
[Unit]
Description=Reset GRUB boot counter after hibernation resume (SteamOS)
Documentation=https://github.com/Valve/steamos-issues
# Run on successful resume — both hibernate and suspend-then-hibernate paths.
After=hibernate.target suspend-then-hibernate.target
# Must run before the sleep target deactivates so systemd sees us as part
# of the resume sequence, not a spurious post-resume unit.
StopWhenUnneeded=no

[Service]
Type=oneshot
# Reset the boot counter to its default value so GRUB does not
# accumulate "failed boot" counts across hibernate cycles.
ExecStart=${grub_editenv} ${grubenv_path} set boot_counter=${_BOOT_COUNTER_DEFAULT}
RemainAfterExit=no
# Run as root; EFI partition requires elevated write access.
User=root

[Install]
WantedBy=hibernate.target suspend-then-hibernate.target
EOF
)

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        info "[DRY RUN] Would write ${BOOT_COUNTER_SERVICE}:"
        echo "${service_content}" | sed 's/^/    /'
    else
        run mkdir -p "$(dirname "${BOOT_COUNTER_SERVICE}")"
        printf '%s\n' "${service_content}" > "${BOOT_COUNTER_SERVICE}"
        run chmod 644 "${BOOT_COUNTER_SERVICE}"
    fi

    # -- 5. Enable and start the service --------------------------------------
    run systemctl daemon-reload
    run systemctl enable --now steamdeck-fix-boot-counter.service

    # -- 6. Immediate one-shot reset (so current counter is clean) ------------
    info "Resetting boot_counter to ${_BOOT_COUNTER_DEFAULT} right now..."
    run "${grub_editenv}" "${grubenv_path}" set boot_counter="${_BOOT_COUNTER_DEFAULT}"

    local new_counter
    new_counter=$("${grub_editenv}" "${grubenv_path}" list 2>/dev/null \
        | grep '^boot_counter=' | cut -d= -f2 || true)
    ok "boot_counter is now: ${new_counter:-${_BOOT_COUNTER_DEFAULT}}"
    ok "Service installed: ${BOOT_COUNTER_SERVICE}"
    ok "GRUB boot-counter fix is active — will auto-reset after every hibernate resume."
}


# ---------------------------------------------------------------------------
# install_cec_tv_control()
#
# Optional feature for Steam Deck dock users.  When the Deck enters sleep or
# hibernate, send a CEC Standby command to the connected TV so it powers off
# automatically.
#
# Requires:
#   /dev/cec0        — present when an HDMI-CEC capable adapter is connected
#   cec-ctl          — from the v4l-utils package
#
# Writes:
#   /home/${DECK_USER}/.local/bin/turn-off-tv.sh   — the CEC command script
#   /etc/systemd/system/cec-sleep.service           — systemd unit
# ---------------------------------------------------------------------------
install_cec_tv_control() {
    step "Installing CEC TV-off-on-sleep service"
    require_root

    local deck_user="${DECK_USER:-deck}"
    local deck_home
    deck_home=$(getent passwd "${deck_user}" 2>/dev/null | cut -d: -f6)
    if [[ -z "${deck_home}" ]]; then
        # Fall back to /home/<user> if getent is unavailable (e.g. live environment)
        deck_home="/home/${deck_user}"
        warn "Could not look up home dir for '${deck_user}' via getent; assuming ${deck_home}"
    fi

    local tv_script="${deck_home}/.local/bin/turn-off-tv.sh"
    local cec_service="/etc/systemd/system/cec-sleep.service"

    # -- 1. Check for /dev/cec0 -----------------------------------------------
    if [[ ! -e /dev/cec0 ]]; then
        warn "/dev/cec0 not found — no HDMI-CEC adapter detected."
        warn "This feature requires the Steam Deck dock (or a CEC-capable USB-C adapter)"
        warn "to be connected.  Re-run the installer with the dock attached, or enable"
        warn "this feature manually after connecting the dock."
        warn "Skipping CEC TV control installation."
        return 0
    fi
    info "Detected /dev/cec0"

    # -- 2. Check for cec-ctl -------------------------------------------------
    local cec_ctl
    if ! cec_ctl=$(command -v cec-ctl 2>/dev/null); then
        warn "cec-ctl not found in PATH."
        warn "Install it with:  sudo pacman -S v4l-utils   (or: sudo apt install v4l-utils)"
        warn "Then re-run the installer to enable CEC TV control."
        warn "Skipping CEC TV control installation."
        return 0
    fi
    info "Found cec-ctl: ${cec_ctl}"

    # -- 3. Write the TV-off script -------------------------------------------
    local tv_script_content
    tv_script_content=$(cat <<EOF
#!/bin/bash
# turn-off-tv.sh — Send CEC Standby to TV when Steam Deck sleeps/hibernates.
# Generated by steamdeck-hibernation installer.  Edit path if cec-ctl moved.

# Register as a CEC playback device so the TV will accept our commands.
${cec_ctl} -d /dev/cec0 -C
${cec_ctl} -d /dev/cec0 --playback

# Send Standby (power-off) to the TV (logical address 0 = TV).
${cec_ctl} -d /dev/cec0 --to 0 --standby

# Re-claim the CEC bus so we're not left in a broken state on resume.
${cec_ctl} -d /dev/cec0 -C
EOF
)

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        info "[DRY RUN] Would write ${tv_script}:"
        echo "${tv_script_content}" | sed 's/^/    /'
    else
        run mkdir -p "$(dirname "${tv_script}")"
        printf '%s\n' "${tv_script_content}" > "${tv_script}"
        run chmod 755 "${tv_script}"
        # Ensure the script is owned by the deck user, not root
        run chown "${deck_user}:${deck_user}" "${tv_script}"
    fi
    info "TV-off script written: ${tv_script}"

    # -- 4. Write the systemd service unit ------------------------------------
    local service_content
    service_content=$(cat <<EOF
[Unit]
Description=CEC TV standby on sleep/hibernate (Steam Deck dock)
# Must complete before the system enters any sleep state.
Before=sleep.target

[Service]
Type=oneshot
ExecStart=${tv_script}
# Run as deck user; cec-ctl doesn't require root and deck is in the video group.
User=${deck_user}
# Best-effort: don't abort sleep if the TV is unreachable or unplugged.
IgnoreOnIsolate=yes

[Install]
WantedBy=sleep.target
EOF
)

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        info "[DRY RUN] Would write ${cec_service}:"
        echo "${service_content}" | sed 's/^/    /'
    else
        run mkdir -p "$(dirname "${cec_service}")"
        printf '%s\n' "${service_content}" > "${cec_service}"
        run chmod 644 "${cec_service}"
    fi

    # -- 5. Ensure deck user is in the 'video' group (needed for /dev/cec0) --
    if ! id -nG "${deck_user}" 2>/dev/null | tr ' ' '\n' | grep -qx video; then
        info "Adding ${deck_user} to 'video' group for /dev/cec0 access..."
        run usermod -aG video "${deck_user}"
        warn "Group change takes effect on next login for ${deck_user}."
    fi

    # -- 6. Enable the service ------------------------------------------------
    run systemctl daemon-reload
    run systemctl enable cec-sleep.service

    ok "CEC service installed: ${cec_service}"
    ok "TV-off script installed: ${tv_script}"
    ok "CEC TV control is active — TV will power off when the Deck sleeps or hibernates."
}


# ---------------------------------------------------------------------------
# print_bios_tips()
#
# Print human-readable BIOS configuration guidance for hibernation on the
# Steam Deck.  These settings must be changed manually; they cannot be set
# programmatically from a running OS.
# ---------------------------------------------------------------------------
print_bios_tips() {
    # Width of the banner border
    local width=70
    local border
    border=$(printf '%*s' "${width}" '' | tr ' ' '-')

    echo ""
    echo "${border}"
    printf '%-*s\n' "${width}" "  STEAM DECK BIOS SETTINGS FOR HIBERNATION"
    echo "${border}"
    cat <<'TIPS'

  These settings improve hibernation reliability and battery life when
  powered off.  They must be changed manually in the BIOS/UEFI firmware.

  HOW TO ENTER THE BIOS
  ---------------------
  1. Power the Steam Deck completely off.
  2. Hold the Volume+ button (top-left of the Deck).
  3. While holding Volume+, press the Power button.
  4. Release both buttons when you see the boot manager / BIOS screen.
  5. Navigate with the D-pad; A = confirm, B = back.

  RECOMMENDED SETTINGS
  --------------------

  1. Quick Boot  ->  DISABLE
     Location: Advanced > Boot > Quick Boot
     Why: When Quick Boot is ON, the firmware skips the POST self-test
     and can miss the stored hibernation image, causing a cold boot instead
     of a proper resume.  Disabling it adds ~1 second to cold boot time
     but ensures the hibernate image is always loaded correctly.

  2. UMA Frame Buffer Size  ->  1G  (NOT 4G)
     Location: Advanced > AMD CBS > NBIO > GFX Configuration > UMA Frame Buffer Size
     Why: This setting controls how much RAM is reserved for the iGPU.
     A 4 GB UMA buffer reduces available system RAM and significantly
     increases the size of the hibernation image (which must be written to
     and read from swap).  1 GB is the best balance between GPU performance
     and fast, reliable hibernation.  Do NOT use "Auto" — it may resolve
     to 4 GB on some firmware versions.

  TIPS
  ----
  * After changing BIOS settings, select "Save & Exit" (usually F10 or
    the last menu option) and let the Deck reboot normally.
  * If the Deck fails to resume after a BIOS change, hold the Power button
    for 10 seconds to force a cold reboot — the hibernation image will be
    discarded and the system will boot fresh.
  * BIOS updates (via SteamOS) may reset these values; check them again
    after a firmware update.

TIPS
    echo "${border}"
    echo ""
}
