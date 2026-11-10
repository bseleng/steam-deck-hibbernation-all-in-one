#!/usr/bin/env bash
# suspend-prereq-functions.sh — suspend test, WiFi-wake fix, and prereq checker
# for the Steam Deck hibernation script.
#
# Requires helpers defined in the parent script:
#   ok(), warn(), err(), info(), step(), run(), confirm(), require_root(), die()
#
# Requires variables set in the parent script:
#   DRY_RUN              — 0|1; when 1 no destructive changes are made
#   ASSUME_YES           — 0|1; when 1 confirm() auto-answers yes
#   WAKEFIX_SERVICE      — basename of the wakeup-disable systemd service
#   DECK_USER            — login name of the Steam Deck user (usually "deck")
#   TEST_SLEEP_MODE      — sleep mode passed to rtcwake -m (e.g. "mem", "freeze")
#   TEST_SLEEP_SECS      — how many seconds rtcwake should sleep before waking
#   IMMEDIATE_WAKE_THRESHOLD — seconds; wake faster than this = immediate wake
#
# Defines:
#   cmd_test_suspend()   — interactive suspend/wake test with dmesg analysis
#   cmd_fix_wifi_wake()  — disable WiFi/XHC ACPI wakeup + print WPA-S instructions
#   cmd_check_prereqs()  — full pre-install readiness check

# ---------------------------------------------------------------------------
# Internal constant — where the WiFi/USB wakeup tmpfiles snippet lives.
# The parent may override this with its own WIFIWAKE_CONF variable.
# ---------------------------------------------------------------------------
WIFIWAKE_CONF="${WIFIWAKE_CONF:-/etc/tmpfiles.d/steamdeck-wifi-nowake.conf}"


# ===========================================================================
# cmd_test_suspend()
#
# Interactive test: suspend the system for TEST_SLEEP_SECS seconds using
# rtcwake, then analyse what woke it and whether the wake was healthy.
#
# Before suspend:
#   - Warns about any enabled XHC/USB/WiFi ACPI wakeup entries
#   - Mounts debugfs if not already mounted
#   - Snapshots /sys/kernel/debug/wakeup_sources
#   - Records the current dmesg timestamp
#
# After wake:
#   - Diffs wakeup_sources to find changed counters
#   - Greps journalctl for PM/wakeup/IRQ/ACPI messages since sleep began
#   - Detects immediate wake (<IMMEDIATE_WAKE_THRESHOLD seconds)
#   - Suggests targeted fixes or confirms healthy sleep and proposes next step
#
# Globals read: TEST_SLEEP_MODE, TEST_SLEEP_SECS, IMMEDIATE_WAKE_THRESHOLD
# ===========================================================================
cmd_test_suspend() {
    step "Test suspend (mode=${TEST_SLEEP_MODE:-mem}, secs=${TEST_SLEEP_SECS:-10})"
    require_root

    local mode="${TEST_SLEEP_MODE:-mem}"
    local secs="${TEST_SLEEP_SECS:-10}"
    local wake_threshold="${IMMEDIATE_WAKE_THRESHOLD:-5}"

    # Verify rtcwake is available — it is the only hard dependency here.
    if ! command -v rtcwake &>/dev/null; then
        die "rtcwake not found in PATH. Install util-linux or run cmd_check_prereqs first."
    fi

    # -----------------------------------------------------------------------
    # PRE-SUSPEND: warn about known-bad ACPI wakeup entries
    # -----------------------------------------------------------------------
    info "--- Pre-suspend checks ---"

    local acpi_wakeup_file="/proc/acpi/wakeup"
    local enabled_bad_entries=()   # entries that may cause immediate wake

    if [[ -r "${acpi_wakeup_file}" ]]; then
        local _line _devname _status
        while IFS= read -r _line; do
            # /proc/acpi/wakeup columns: Device  S-state  Status  Sysfs-Node
            # Status column is either "*enabled" or "*disabled"
            _devname=$(awk '{print $1}' <<< "${_line}")
            _status=$(awk  '{print $3}' <<< "${_line}")
            [[ "${_status}" != "*enabled" ]] && continue
            case "${_devname}" in
                XHC*|XHCI*|USB*|EHC*|OHC*)
                    warn "ACPI wakeup ENABLED for USB/XHC device: ${_devname}"
                    warn "  This may cause an immediate wake-from-sleep."
                    warn "  Fix: sudo $0 fix-wake ${_devname}"
                    enabled_bad_entries+=("${_devname}:usb")
                    ;;
                WLAN*|WIFI*|PXSX*)
                    warn "ACPI wakeup ENABLED for WiFi/PCIe device: ${_devname}"
                    warn "  This may cause an immediate wake-from-sleep."
                    warn "  Fix: sudo $0 fix-wifi-wake"
                    enabled_bad_entries+=("${_devname}:wifi")
                    ;;
            esac
        done < "${acpi_wakeup_file}"

        if (( ${#enabled_bad_entries[@]} == 0 )); then
            ok "No obviously problematic ACPI wakeup entries found"
        fi
    else
        warn "/proc/acpi/wakeup not readable — skipping ACPI wakeup check"
    fi

    # -----------------------------------------------------------------------
    # PRE-SUSPEND: ensure debugfs is mounted
    # -----------------------------------------------------------------------
    local debugfs_mounted=0
    local debugfs_was_mounted=0

    if mount | grep -q 'debugfs'; then
        debugfs_mounted=1
        debugfs_was_mounted=1
        info "debugfs already mounted"
    else
        info "debugfs not mounted — mounting temporarily"
        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
            info "[DRY RUN] Would run: mount -t debugfs none /sys/kernel/debug"
            debugfs_mounted=1
        else
            if mount -t debugfs none /sys/kernel/debug 2>/dev/null; then
                debugfs_mounted=1
                info "debugfs mounted at /sys/kernel/debug"
            else
                warn "Could not mount debugfs — wakeup_sources diff will be skipped"
            fi
        fi
    fi

    # -----------------------------------------------------------------------
    # PRE-SUSPEND: snapshot wakeup_sources
    # -----------------------------------------------------------------------
    local wakeup_sources_file="/sys/kernel/debug/wakeup_sources"
    local snap_before
    snap_before=$(mktemp /tmp/wakeup_sources_before.XXXXXX)

    if [[ "${debugfs_mounted}" -eq 1 && -r "${wakeup_sources_file}" ]]; then
        cp "${wakeup_sources_file}" "${snap_before}" 2>/dev/null || {
            warn "Could not snapshot ${wakeup_sources_file}"
        }
        info "Snapshotted wakeup_sources → ${snap_before}"
    fi

    # -----------------------------------------------------------------------
    # PRE-SUSPEND: record current dmesg/journal timestamp
    # -----------------------------------------------------------------------
    # Use epoch seconds so we can do --since "@EPOCH" with journalctl.
    local start_ts
    start_ts=$(date +%s)
    info "Suspend start timestamp: ${start_ts} ($(date -d "@${start_ts}" 2>/dev/null || date -r "${start_ts}" 2>/dev/null || echo 'N/A'))"

    # -----------------------------------------------------------------------
    # SUSPEND
    # -----------------------------------------------------------------------
    info ""
    info "Suspending for ${secs} seconds (mode: ${mode})…"
    info "The system will wake automatically via RTC."

    if ! confirm "Ready to suspend? (The terminal will freeze until wake)"; then
        info "Suspend test cancelled."
        rm -f "${snap_before}"
        return 0
    fi

    local suspend_start_ts
    suspend_start_ts=$(date +%s)

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        info "[DRY RUN] Would run: rtcwake -m ${mode} -s ${secs}"
        sleep 2  # simulate a very short pause so the rest of the logic runs
    else
        # rtcwake blocks until the system resumes — this is intentional.
        if ! run rtcwake -m "${mode}" -s "${secs}"; then
            err "rtcwake returned a non-zero exit code."
            err "The system may not have suspended correctly."
        fi
    fi

    local wake_ts
    wake_ts=$(date +%s)
    local elapsed=$(( wake_ts - suspend_start_ts ))

    info ""
    info "=== System woke after ${elapsed} second(s) ==="

    # -----------------------------------------------------------------------
    # POST-WAKE: snapshot wakeup_sources again and diff
    # -----------------------------------------------------------------------
    local snap_after
    snap_after=$(mktemp /tmp/wakeup_sources_after.XXXXXX)

    if [[ "${debugfs_mounted}" -eq 1 && -r "${wakeup_sources_file}" ]]; then
        cp "${wakeup_sources_file}" "${snap_after}" 2>/dev/null || true

        info ""
        info "--- wakeup_sources diff (changed event counters) ---"
        if [[ -s "${snap_before}" && -s "${snap_after}" ]]; then
            # The first line is a header; skip it in the diff output.
            local diff_output
            diff_output=$(diff "${snap_before}" "${snap_after}" \
                | grep '^[<>]' | grep -v '^[<>] name' || true)
            if [[ -n "${diff_output}" ]]; then
                echo "${diff_output}"
            else
                info "  No changes in wakeup_sources (expected for a clean timed wake)"
            fi
        else
            info "  (snapshots unavailable — skipping diff)"
        fi
    fi

    # -----------------------------------------------------------------------
    # POST-WAKE: grep journalctl for wake-reason messages
    # -----------------------------------------------------------------------
    info ""
    info "--- Kernel messages since suspend (PM / wakeup / IRQ / ACPI) ---"
    local journal_output=""
    if command -v journalctl &>/dev/null; then
        journal_output=$(
            journalctl -k --since "@${start_ts}" 2>/dev/null \
                | grep -iE 'wakeup|PM: |IRQ |ACPI' \
                | head -40 \
            || true
        )
        if [[ -n "${journal_output}" ]]; then
            echo "${journal_output}"
        else
            info "  No matching kernel messages found (journald may not have flushed yet)"
            info "  Try: journalctl -k --since \"@${start_ts}\" | grep -iE 'wakeup|PM:|IRQ|ACPI'"
        fi
    else
        warn "journalctl not available — cannot retrieve wake-reason messages"
        info "  Fallback: dmesg | grep -iE 'wakeup|PM:|IRQ|ACPI'"
    fi

    # -----------------------------------------------------------------------
    # POST-WAKE: detect immediate wake and suggest fixes
    # -----------------------------------------------------------------------
    info ""
    if (( elapsed < wake_threshold )); then
        err "IMMEDIATE WAKE DETECTED — system woke after only ${elapsed}s (threshold: ${wake_threshold}s)"
        info ""
        info "Possible causes and suggested fixes:"
        info ""

        # Check if any XHC/USB entries were flagged above
        local suggested_fix_wifi=0
        local suggested_fix_bt=0
        for entry in "${enabled_bad_entries[@]}"; do
            local _ename="${entry%%:*}"
            local _etype="${entry##*:}"
            case "${_etype}" in
                usb)
                    case "${_ename}" in
                        *BT*|*BTUS*)
                            info "  [Bluetooth] ACPI wakeup enabled for ${_ename}"
                            info "    Fix: disable Bluetooth devices or run: sudo $0 fix-wake ${_ename}"
                            suggested_fix_bt=1
                            ;;
                        *)
                            info "  [USB/XHC] ACPI wakeup enabled for ${_ename}"
                            info "    Fix: sudo $0 fix-wake ${_ename}"
                            ;;
                    esac
                    ;;
                wifi)
                    info "  [WiFi] ACPI wakeup enabled for ${_ename}"
                    info "    Fix: sudo $0 fix-wifi-wake"
                    suggested_fix_wifi=1
                    ;;
            esac
        done

        # Parse journal output for additional hints even if we did not catch
        # the device in /proc/acpi/wakeup (e.g., it appeared as PXSX or similar).
        if echo "${journal_output}" | grep -qi 'xhc\|xhci\|usb'; then
            info "  [USB/XHC] Journal mentions XHC/USB around wake time."
            info "    Fix: sudo $0 fix-wake XHC0"
        fi

        if echo "${journal_output}" | grep -qi 'wifi\|wlan\|ath11k\|ath10k\|iwlwifi'; then
            info "  [WiFi] Journal mentions WiFi/WLAN around wake time."
            info "    Fix: sudo $0 fix-wifi-wake"
            suggested_fix_wifi=1
        fi

        if echo "${journal_output}" | grep -qi 'bluetooth\|btusb\|hci'; then
            info "  [Bluetooth] Journal mentions Bluetooth around wake time."
            info "    Fix: disable paired Bluetooth devices, or: sudo $0 fix-wake"
            suggested_fix_bt=1
        fi

        # Always print the Steam setting reminder
        info ""
        info "  [Steam] 'Use As Wake Movie' can trigger immediate wake:"
        info "    Check: Steam → Settings → Customization → disable 'Use As Wake Movie'"
        info ""
        if (( suggested_fix_wifi == 0 && suggested_fix_bt == 0 )); then
            info "  No specific device identified from pre-suspend check."
            info "  General advice: check all *enabled entries in /proc/acpi/wakeup"
            info "  and run: sudo $0 fix-wifi-wake"
        fi
    else
        ok "Sleep duration looks healthy (${elapsed}s ≥ threshold ${wake_threshold}s)"
        info ""
        info "Suspend test PASSED. Next recommended step:"
        info "  sudo $0 test-hibernate"
        info ""
        info "This will test a full hibernate-to-disk cycle (suspend-then-hibernate)"
        info "which writes RAM to the swapfile and powers off completely."
    fi

    # -----------------------------------------------------------------------
    # Cleanup
    # -----------------------------------------------------------------------
    rm -f "${snap_before}" "${snap_after}"

    # Unmount debugfs only if we mounted it ourselves
    if [[ "${debugfs_was_mounted}" -eq 0 && "${debugfs_mounted}" -eq 1 \
          && "${DRY_RUN:-0}" -ne 1 ]]; then
        umount /sys/kernel/debug 2>/dev/null || true
        info "debugfs unmounted"
    fi

    return 0
}


# ===========================================================================
# cmd_fix_wifi_wake()
#
# Three-pronged approach to the immediate-wake-after-sleep issue caused by
# WiFi and USB/XHC ACPI wakeup sources on SteamOS:
#
#   Prong 1 — systemd-tmpfiles.d entry that disables wakeup at every boot:
#             Scans for ath11k/ath10k WiFi PCI devices and enabled XHC entries
#             and writes "w …/power/wakeup … disabled" lines to
#             WIFIWAKE_CONF (/etc/tmpfiles.d/steamdeck-wifi-nowake.conf).
#
#   Prong 2 — Prints formatted Steam UI instructions for switching to the
#             WPA Supplicant WiFi backend (prevents spurious stack wakeups).
#
#   Prong 3 — Checks Steam localconfig.vdf for Wake Movie / Wake on Music
#             and warns if enabled (cannot be changed programmatically).
#
# Globals read: DRY_RUN, DECK_USER, WIFIWAKE_CONF
# ===========================================================================
cmd_fix_wifi_wake() {
    step "Fixing WiFi/USB immediate-wake issue"
    require_root

    local conf="${WIFIWAKE_CONF:-/etc/tmpfiles.d/steamdeck-wifi-nowake.conf}"
    local deck_user="${DECK_USER:-deck}"

    # -----------------------------------------------------------------------
    # PRONG 1: Build a tmpfiles.d snippet that persists wakeup=disabled
    # -----------------------------------------------------------------------
    info "--- Prong 1: disable WiFi/XHC ACPI wakeup at boot via tmpfiles.d ---"

    # Collect tmpfiles.d lines in an array; each entry is one "w" line.
    local tmpfiles_lines=()

    # -- 1a. WiFi PCI devices (driver = ath11k or ath10k) --------------------
    local uevent_path pci_dev_dir pci_driver wakeup_file pci_addr
    for uevent_path in /sys/bus/pci/devices/*/uevent; do
        [[ -r "${uevent_path}" ]] || continue
        pci_dev_dir="${uevent_path%/uevent}"

        pci_driver=""
        # Read DRIVER= from the uevent file
        while IFS='=' read -r _key _val; do
            [[ "${_key}" == "DRIVER" ]] && { pci_driver="${_val}"; break; }
        done < "${uevent_path}"

        # Fall back to the driver symlink if uevent did not carry DRIVER=
        if [[ -z "${pci_driver}" && -L "${pci_dev_dir}/driver" ]]; then
            pci_driver=$(basename "$(readlink "${pci_dev_dir}/driver")" 2>/dev/null) || true
        fi

        case "${pci_driver}" in
            ath11k*|ath10k*)
                wakeup_file="${pci_dev_dir}/power/wakeup"
                if [[ -e "${wakeup_file}" ]]; then
                    local current_val
                    current_val=$(< "${wakeup_file}" 2>/dev/null) || current_val="unknown"
                    pci_addr="${pci_dev_dir##*/}"  # e.g. 0000:04:00.0
                    if [[ "${current_val}" == "enabled" ]]; then
                        warn "WiFi PCI device ${pci_addr} (${pci_driver}): wakeup is enabled — will disable"
                    else
                        info "WiFi PCI device ${pci_addr} (${pci_driver}): wakeup is already ${current_val}"
                    fi
                    # Add tmpfiles.d line regardless of current state — ensures
                    # it stays disabled across future power-management resets.
                    tmpfiles_lines+=("w /sys/bus/pci/devices/${pci_addr}/power/wakeup - - - - disabled")
                    # Disable immediately as well (best-effort, no fatal error).
                    if [[ "${DRY_RUN:-0}" -ne 1 ]]; then
                        echo "disabled" > "${wakeup_file}" 2>/dev/null \
                            && info "  Disabled wakeup immediately for ${pci_addr}" \
                            || warn "  Could not disable wakeup immediately for ${pci_addr} (will take effect at next boot via tmpfiles.d)"
                    fi
                fi
                ;;
        esac
    done

    # -- 1b. XHC/XHCI entries from /proc/acpi/wakeup -------------------------
    # For each enabled XHC entry, find its sysfs power/wakeup path by matching
    # the ACPI path embedded in /proc/acpi/wakeup column 4 (Sysfs-Node).
    if [[ -r /proc/acpi/wakeup ]]; then
        local _line _devname _status _sysfs_node
        while IFS= read -r _line; do
            _devname=$(awk '{print $1}' <<< "${_line}")
            _status=$( awk '{print $3}' <<< "${_line}")
            _sysfs_node=$(awk '{print $4}' <<< "${_line}")

            [[ "${_status}" != "*enabled" ]] && continue

            case "${_devname}" in
                XHC*|XHCI*)   : ;;   # match
                *)             continue ;;
            esac

            # Prefer the sysfs node path printed by the kernel if available.
            # Column 4 looks like: /sys/devices/pci0000:00/0000:00:10.0
            local xhc_wakeup_file=""
            if [[ -n "${_sysfs_node}" && "${_sysfs_node}" == /sys/devices/* ]]; then
                xhc_wakeup_file="${_sysfs_node}/power/wakeup"
            fi

            # Fallback: glob for any xhci_hcd controller under /sys/devices
            if [[ -z "${xhc_wakeup_file}" || ! -e "${xhc_wakeup_file}" ]]; then
                # Find the first xhci controller's power/wakeup
                local _found_path
                _found_path=$(find /sys/devices -maxdepth 6 -name 'wakeup' \
                    -path '*/xhci_hcd*' -o \
                    -name 'wakeup' -path '*/0000:*/power/wakeup' \
                    2>/dev/null | head -1) || true
                [[ -n "${_found_path}" ]] && xhc_wakeup_file="${_found_path}"
            fi

            if [[ -n "${xhc_wakeup_file}" && -e "${xhc_wakeup_file}" ]]; then
                warn "XHC ACPI wakeup ENABLED for ${_devname} — will disable via sysfs"
                # Strip /sys/ prefix for the tmpfiles.d path
                local sysfs_rel="${xhc_wakeup_file#/sys/}"
                # tmpfiles.d operates relative to the real path from /
                tmpfiles_lines+=("w /sys/${sysfs_rel} - - - - disabled")
                if [[ "${DRY_RUN:-0}" -ne 1 ]]; then
                    echo "disabled" > "${xhc_wakeup_file}" 2>/dev/null \
                        && info "  Disabled wakeup immediately for ${_devname}" \
                        || warn "  Could not disable wakeup immediately for ${_devname}"
                fi
            else
                warn "Could not find sysfs power/wakeup path for ACPI entry ${_devname}"
                warn "  You can disable it manually: echo '${_devname}' | sudo tee /proc/acpi/wakeup"
                warn "  (Note: writing to /proc/acpi/wakeup toggles state — check status first)"
            fi
        done < /proc/acpi/wakeup
    else
        warn "/proc/acpi/wakeup not readable — skipping XHC ACPI wakeup check"
    fi

    # -- 1c. Write (or update) the tmpfiles.d configuration file -------------
    if (( ${#tmpfiles_lines[@]} == 0 )); then
        warn "No WiFi or XHC wakeup sysfs paths found to disable."
        warn "  The tmpfiles.d file will NOT be written."
        warn "  If this is unexpected, check: /sys/bus/pci/devices/ for your WiFi device"
        warn "  and /proc/acpi/wakeup for XHC entries."
    else
        info ""
        info "Writing tmpfiles.d entry: ${conf}"

        # Build file content
        local conf_content
        conf_content="# steamdeck-wifi-nowake.conf"$'\n'
        conf_content+="# Generated by steamdeck-hibernation installer on $(date -I)."$'\n'
        conf_content+="# Disables WiFi and USB/XHC ACPI wakeup sources at every boot"$'\n'
        conf_content+="# to prevent immediate wake-from-sleep (SteamOS regression)."$'\n'
        conf_content+="# Type  Path                                      Mode UID GID Age Argument"$'\n'
        for line in "${tmpfiles_lines[@]}"; do
            conf_content+="${line}"$'\n'
        done

        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
            info "[DRY RUN] Would write ${conf}:"
            echo "${conf_content}" | sed 's/^/    /'
        else
            run mkdir -p "$(dirname "${conf}")"
            printf '%s' "${conf_content}" > "${conf}"
            run chmod 644 "${conf}"
            ok "Written: ${conf}"

            # Apply immediately so we don't need a reboot for the current session.
            info "Applying tmpfiles.d rules now…"
            if run systemd-tmpfiles --create "${conf}"; then
                ok "Wakeup sources disabled for this session and every boot going forward."
            else
                warn "systemd-tmpfiles --create returned non-zero; changes may not have applied."
                warn "  They will take effect on next boot."
            fi
        fi
    fi

    # -----------------------------------------------------------------------
    # PRONG 2: Print WPA Supplicant instructions as a formatted box
    # -----------------------------------------------------------------------
    info ""
    info "--- Prong 2: enable WPA Supplicant WiFi backend (Steam UI) ---"
    # Use printf so the box renders correctly regardless of locale / terminal.
    printf '\n'
    printf '  ┌──────────────────────────────────────────────────────────┐\n'
    printf '  │  WiFi immediate-wake fix: enable WPA-supplicant mode    │\n'
    printf '  ├──────────────────────────────────────────────────────────┤\n'
    printf '  │  1. Press the STEAM button                              │\n'
    printf '  │  2. Go to Settings → System                            │\n'
    printf '  │  3. Enable "Developer Mode"                             │\n'
    printf '  │  4. Scroll to bottom → Developer section               │\n'
    printf '  │  5. Enable "Use Experimental WiFi Backend               │\n'
    printf '  │         (WPA Supplicant)"                               │\n'
    printf '  │  6. Reboot the Steam Deck                               │\n'
    printf '  └──────────────────────────────────────────────────────────┘\n'
    printf '\n'

    # -----------------------------------------------------------------------
    # PRONG 3: Check Steam localconfig.vdf for Wake Movie / Wake on Music
    # -----------------------------------------------------------------------
    info "--- Prong 3: Steam 'Use As Wake Movie' / Wake on Music check ---"

    # Determine the deck user's home directory safely.
    local deck_home
    deck_home=$(getent passwd "${deck_user}" 2>/dev/null | cut -d: -f6) \
        || deck_home="/home/${deck_user}"
    [[ -z "${deck_home}" ]] && deck_home="/home/${deck_user}"

    local localconfig="${deck_home}/.steam/steam/config/localconfig.vdf"

    if [[ ! -e "${localconfig}" ]]; then
        info "Steam localconfig.vdf not found at expected path:"
        info "  ${localconfig}"
        info "  Skipping Wake Movie check."
    elif [[ ! -r "${localconfig}" ]]; then
        warn "Steam localconfig.vdf exists but is not readable (permission issue):"
        warn "  ${localconfig}"
        warn "  Run as ${deck_user} or check permissions."
    else
        # grep is case-insensitive; VDF format: "KeyName"<TAB>"value"
        local wm_line
        wm_line=$(grep -i 'UseWakeOnMusicEnabled\|WakeOnMusic\|UseAsWakeMovie' \
            "${localconfig}" 2>/dev/null | head -1) || wm_line=""

        if [[ -z "${wm_line}" ]]; then
            ok "Steam 'Use As Wake Movie' key not found in localconfig.vdf (likely disabled by default)"
        else
            # Extract value — VDF wraps values in double-quotes: "KeyName"  "1"
            local wm_val
            wm_val=$(printf '%s' "${wm_line}" \
                | grep -oP '"\K[01](?="\s*$)' | head -1) || wm_val=""
            if [[ "${wm_val}" == "1" ]]; then
                warn "Steam 'Use As Wake Movie' is ENABLED in localconfig.vdf."
                warn "  This can cause the Steam Deck to wake from sleep to play a video."
                warn "  Cannot disable programmatically. Disable it manually:"
                warn "    Steam → Settings → Customization → disable 'Use As Wake Movie'"
            elif [[ "${wm_val}" == "0" ]]; then
                ok "Steam 'Use As Wake Movie' is disabled in localconfig.vdf"
            else
                info "Steam Wake Movie key found but value could not be parsed: ${wm_line}"
                info "  Check ${localconfig} manually."
            fi
        fi
    fi

    info ""
    ok "cmd_fix_wifi_wake complete."
    info "  If immediate wakes persist after rebooting, run: sudo $0 test-suspend"
    info "  to gather fresh dmesg evidence."
    return 0
}


# ===========================================================================
# cmd_check_prereqs()
#
# Standalone pre-install readiness check.  Reports each item with ok/warn/err
# and prints a summary line.  Returns 0 if all critical checks pass, 1 if any
# critical check fails.
#
# Critical checks (failures block install):
#   1. Hardware   — Steam Deck (Jupiter / Galileo chassis)
#   2. Filesystem — /home is ext4
#   3. Swapfile   — /home/swapfile ≥ 16 GiB
#   4. vm.swappiness — value is 1
#   9. Tools      — required binaries present
#
# Non-critical (warn only):
#   5. vm.page-cluster
#   6. transparent_hugepage
#   7. Free space on /home
#   8. UMA buffer size
#  10. BIOS Quick Boot reminder (cannot be checked programmatically)
#
# Globals read: (none required beyond what the helpers provide)
# ===========================================================================
cmd_check_prereqs() {
    step "Checking prerequisites for Steam Deck hibernation"

    local passes=0
    local warnings=0
    local failures=0

    # Internal helpers — accumulate counters and call the appropriate helper.
    # These are local functions; they do not leak into the parent scope.
    _prereq_ok()   { ok "$1";   (( passes++   )); }
    _prereq_warn() { warn "$1"; (( warnings++ )); }
    _prereq_err()  { err "$1";  (( failures++ )); }

    # -----------------------------------------------------------------------
    # CHECK 1 (CRITICAL): Hardware — Steam Deck chassis
    # -----------------------------------------------------------------------
    info "[1/10] Hardware: checking for Steam Deck (Jupiter / Galileo)…"
    local chassis_ok=0

    # Method A: DMI product name
    local dmi_product=""
    for dmi_file in \
        /sys/class/dmi/id/product_name \
        /sys/devices/virtual/dmi/id/product_name; do
        [[ -r "${dmi_file}" ]] && { dmi_product=$(< "${dmi_file}"); break; }
    done

    case "${dmi_product}" in
        Jupiter|Galileo|"Steam Deck"|"Steam Deck OLED")
            _prereq_ok "Hardware: Steam Deck detected (${dmi_product})"
            chassis_ok=1
            ;;
    esac

    # Method B: board vendor — Valve is the OEM
    if (( chassis_ok == 0 )); then
        local board_vendor=""
        for vendor_file in \
            /sys/class/dmi/id/board_vendor \
            /sys/devices/virtual/dmi/id/board_vendor; do
            [[ -r "${vendor_file}" ]] && { board_vendor=$(< "${vendor_file}"); break; }
        done
        if [[ "${board_vendor}" == "Valve" ]]; then
            _prereq_ok "Hardware: Valve board vendor detected — assuming Steam Deck"
            chassis_ok=1
        fi
    fi

    if (( chassis_ok == 0 )); then
        _prereq_err "Hardware: NOT a Steam Deck (detected: '${dmi_product:-unknown}')"
        _prereq_err "  This installer is designed for Steam Deck only."
    fi

    # -----------------------------------------------------------------------
    # CHECK 2 (CRITICAL): /home filesystem is ext4
    # -----------------------------------------------------------------------
    info "[2/10] Filesystem: checking /home is ext4…"
    local home_fstype=""

    if command -v findmnt &>/dev/null; then
        home_fstype=$(findmnt -n -o FSTYPE --target /home 2>/dev/null) || true
    fi

    # Fallback: parse /proc/mounts
    if [[ -z "${home_fstype}" && -r /proc/mounts ]]; then
        # Find the deepest mount point that is a prefix of /home
        local _mp _fstype _rest
        while IFS=' ' read -r _ _mp _fstype _rest; do
            case "/home" in
                "${_mp}"*) home_fstype="${_fstype}" ;;  # keep overwriting for deepest match
            esac
        done < /proc/mounts
    fi

    if [[ "${home_fstype}" == "ext4" ]]; then
        _prereq_ok "Filesystem: /home is ext4"
    elif [[ -z "${home_fstype}" ]]; then
        _prereq_warn "Filesystem: could not determine /home filesystem type"
        (( warnings++ ))
        # Already counted by _prereq_warn but we need to not double-count; reset
        (( warnings-- ))
        _prereq_warn "  Install findmnt (util-linux) or check /proc/mounts manually"
    elif [[ "${home_fstype}" == "btrfs" ]]; then
        _prereq_err "Filesystem: /home is btrfs — hibernation swapfile requires ext4"
        _prereq_err "  btrfs does not support swapfiles usable as hibernation targets."
    else
        _prereq_err "Filesystem: /home is ${home_fstype} — ext4 required for hibernation swapfile"
    fi

    # -----------------------------------------------------------------------
    # CHECK 3 (CRITICAL): /home/swapfile exists and is ≥ 16 GiB
    # -----------------------------------------------------------------------
    info "[3/10] Swapfile: checking /home/swapfile ≥ 16 GiB…"
    local swapfile_path="/home/swapfile"
    local swapfile_min_bytes=$(( 16 * 1024 * 1024 * 1024 ))  # 16 GiB

    if [[ ! -e "${swapfile_path}" ]]; then
        _prereq_err "Swapfile: ${swapfile_path} does not exist"
        _prereq_err "  Create it with CryoUtilities or: sudo dd if=/dev/zero of=${swapfile_path} bs=1G count=16 && sudo mkswap ${swapfile_path}"
    else
        local swapfile_bytes
        swapfile_bytes=$(stat -c '%s' "${swapfile_path}" 2>/dev/null) || swapfile_bytes=0
        local swapfile_gib=$(( swapfile_bytes / 1073741824 ))
        if (( swapfile_bytes >= swapfile_min_bytes )); then
            _prereq_ok "Swapfile: ${swapfile_path} is ${swapfile_gib} GiB (≥ 16 GiB required)"
        else
            _prereq_err "Swapfile: ${swapfile_path} is only ${swapfile_gib} GiB (need ≥ 16 GiB)"
            _prereq_err "  Resize with CryoUtilities or by recreating the swapfile."
        fi
    fi

    # -----------------------------------------------------------------------
    # CHECK 4 (CRITICAL): vm.swappiness == 1
    # -----------------------------------------------------------------------
    info "[4/10] vm.swappiness: checking value is 1…"
    local swappiness
    if [[ -r /proc/sys/vm/swappiness ]]; then
        swappiness=$(< /proc/sys/vm/swappiness)
    else
        swappiness=$(sysctl -n vm.swappiness 2>/dev/null) || swappiness="unknown"
    fi

    if [[ "${swappiness}" == "1" ]]; then
        _prereq_ok "vm.swappiness = 1 (CryoUtilities default)"
    elif [[ "${swappiness}" == "unknown" ]]; then
        _prereq_err "vm.swappiness: could not be read"
    else
        _prereq_err "vm.swappiness = ${swappiness} — must be 1 for reliable hibernation"
        _prereq_err "  Fix: sudo sysctl -w vm.swappiness=1   (and persist via /etc/sysctl.d/)"
        _prereq_err "  Or run CryoUtilities which sets this automatically."
    fi

    # -----------------------------------------------------------------------
    # CHECK 5 (warn): vm.page-cluster == 0 or 1
    # -----------------------------------------------------------------------
    info "[5/10] vm.page-cluster: checking value is 0 or 1…"
    local page_cluster
    if [[ -r /proc/sys/vm/page-cluster ]]; then
        page_cluster=$(< /proc/sys/vm/page-cluster)
    else
        page_cluster=$(sysctl -n vm.page-cluster 2>/dev/null) || page_cluster="unknown"
    fi

    if [[ "${page_cluster}" == "0" || "${page_cluster}" == "1" ]]; then
        _prereq_ok "vm.page-cluster = ${page_cluster}"
    elif [[ "${page_cluster}" == "unknown" ]]; then
        _prereq_warn "vm.page-cluster: could not be read"
    else
        _prereq_warn "vm.page-cluster = ${page_cluster} (CryoUtilities sets this to 0 or 1)"
        _prereq_warn "  Fix: sudo sysctl -w vm.page-cluster=0"
    fi

    # -----------------------------------------------------------------------
    # CHECK 6 (warn): transparent_hugepage == always
    # -----------------------------------------------------------------------
    info "[6/10] Transparent Huge Pages: checking for 'always'…"
    local thp_file="/sys/kernel/mm/transparent_hugepage/enabled"
    if [[ ! -r "${thp_file}" ]]; then
        _prereq_warn "transparent_hugepage: ${thp_file} not readable"
    else
        local thp_val
        thp_val=$(< "${thp_file}")
        if [[ "${thp_val}" == *"[always]"* ]]; then
            _prereq_ok "transparent_hugepage = always"
        else
            # Extract the currently-selected mode (surrounded by brackets).
            local thp_active
            thp_active=$(printf '%s' "${thp_val}" | grep -oP '\[\K[^\]]+' || echo "unknown")
            _prereq_warn "transparent_hugepage = [${thp_active}] — CryoUtilities sets this to [always]"
            _prereq_warn "  Fix: echo always | sudo tee ${thp_file}"
        fi
    fi

    # -----------------------------------------------------------------------
    # CHECK 7 (warn): ≥ 2 GB free on /home
    # -----------------------------------------------------------------------
    info "[7/10] Disk space: checking ≥ 2 GB free on /home…"
    local free_bytes=0
    if command -v df &>/dev/null; then
        # df -B1 outputs available bytes in column 4
        free_bytes=$(df -B1 --output=avail /home 2>/dev/null | tail -1 | tr -d '[:space:]') || free_bytes=0
    fi

    if [[ "${free_bytes}" =~ ^[0-9]+$ ]] && (( free_bytes > 0 )); then
        local free_gib=$(( free_bytes / 1073741824 ))
        if (( free_bytes >= 2 * 1073741824 )); then
            _prereq_ok "Free space on /home: ${free_gib} GiB (≥ 2 GiB)"
        else
            _prereq_warn "Free space on /home: ${free_gib} GiB — less than 2 GiB available"
            _prereq_warn "  You may not have enough room to resize the swapfile if needed."
        fi
    else
        _prereq_warn "Free space on /home: could not be determined"
    fi

    # -----------------------------------------------------------------------
    # CHECK 8 (warn): UMA buffer — best-effort via DRM sysfs
    # -----------------------------------------------------------------------
    info "[8/10] UMA buffer: best-effort check via /sys/class/drm…"
    local vram_bytes=0 vram_found=0 vram_source=""
    for vram_file in /sys/class/drm/card*/device/mem_info_vram_total; do
        [[ -r "${vram_file}" ]] || continue
        local _candidate
        _candidate=$(< "${vram_file}" 2>/dev/null) || continue
        if [[ "${_candidate}" =~ ^[0-9]+$ ]] && (( _candidate > 0 )); then
            vram_bytes="${_candidate}"
            vram_source="${vram_file}"
            vram_found=1
            break
        fi
    done

    if (( vram_found == 1 )); then
        local vram_mib=$(( vram_bytes / 1048576 ))
        # 2 GiB threshold: above this strongly suggests 4 GiB UMA configuration
        if (( vram_bytes > 2 * 1073741824 )); then
            _prereq_warn "UMA buffer: ~${vram_mib} MiB detected — this looks like 4 GB UMA (${vram_source})"
            _prereq_warn "  Hibernation is significantly more reliable with 1 GB UMA."
            _prereq_warn "  To change: power off → hold Vol- + Power → BIOS"
            _prereq_warn "    → Advanced → AMD CBS → NBIO → GFX → UMA Frame Buffer Size → 1G"
        else
            _prereq_ok "UMA buffer: ~${vram_mib} MiB (likely 1 GB UMA — good)"
        fi
    else
        _prereq_warn "UMA buffer: could not be determined via DRM sysfs"
        _prereq_warn "  Verify manually in BIOS: Advanced → UMA Frame Buffer Size should be 1G"
    fi

    # -----------------------------------------------------------------------
    # CHECK 9 (CRITICAL): required tools
    # -----------------------------------------------------------------------
    info "[9/10] Tools: checking required binaries…"
    local required_tools=(rtcwake swapon mkswap dd filefrag findmnt awk)
    local optional_grub_tools=(grub-mkconfig grub2-mkconfig update-grub grub-update)
    local missing_critical=()

    for tool in "${required_tools[@]}"; do
        if command -v "${tool}" &>/dev/null; then
            _prereq_ok "Tool: ${tool} found at $(command -v "${tool}")"
        else
            _prereq_err "Tool: ${tool} NOT found in PATH"
            missing_critical+=("${tool}")
        fi
    done

    # grub tool: need at least one of the variants
    local grub_tool_found=0
    local found_grub_tool=""
    for grub_tool in "${optional_grub_tools[@]}"; do
        if command -v "${grub_tool}" &>/dev/null; then
            grub_tool_found=1
            found_grub_tool="${grub_tool}"
            break
        fi
    done
    if (( grub_tool_found == 1 )); then
        _prereq_ok "Tool: GRUB update tool found: ${found_grub_tool}"
    else
        _prereq_err "Tool: no GRUB update tool found (tried: ${optional_grub_tools[*]})"
        missing_critical+=("grub-mkconfig/update-grub")
    fi

    if (( ${#missing_critical[@]} > 0 )); then
        _prereq_err "Missing required tools: ${missing_critical[*]}"
        _prereq_err "  Install the missing packages; on SteamOS try:"
        _prereq_err "    sudo steamos-readonly disable && sudo pacman -S util-linux grub"
    fi

    # -----------------------------------------------------------------------
    # CHECK 10 (reminder): BIOS Quick Boot
    # -----------------------------------------------------------------------
    info "[10/10] BIOS Quick Boot: cannot be checked programmatically."
    # Count as a warning since we cannot verify — user must act manually.
    _prereq_warn "BIOS Quick Boot: please verify manually."
    _prereq_warn "  Quick Boot should be DISABLED for reliable hibernation resume."
    _prereq_warn "  To check: power off → hold Vol- + Power → BIOS"
    _prereq_warn "    → Advanced → Boot → Quick Boot → Disabled → Save & Exit"

    # -----------------------------------------------------------------------
    # Summary
    # -----------------------------------------------------------------------
    info ""
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "Prereq summary: ${passes} passed, ${warnings} warnings, ${failures} failures"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if (( failures == 0 && warnings == 0 )); then
        ok "All checks passed — system is ready for hibernation setup."
    elif (( failures == 0 )); then
        ok "All critical checks passed with ${warnings} warning(s) — proceed with caution."
    else
        err "${failures} critical check(s) FAILED — do not proceed until fixed."
    fi

    # Return 1 if any critical failure was logged.
    (( failures == 0 ))
}
