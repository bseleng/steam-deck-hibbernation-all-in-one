#!/usr/bin/env bash
# Bash function stubs for Steam Deck hibernation script.
# Requires: ok(), warn(), err(), info(), step() helpers, SWAPFILE variable,
#           and WAKEFIX_SERVICE variable to be defined in the parent script.
# Parent script must use: set -uo pipefail (or equivalent)

# ---------------------------------------------------------------------------
# check_cryoutilities
#
# Verify that CryoUtilities tweaks are applied before attempting hibernation.
# Critical check: swapfile must exist and be >= 16 GiB.
# Non-critical checks: vm.swappiness, vm.page-cluster, transparent hugepages.
#
# Returns: 0 if all critical checks pass, 1 if any critical check fails.
# ---------------------------------------------------------------------------
check_cryoutilities() {
    local critical_ok=0  # 0 = pass, 1 = fail (set to 1 on any critical failure)

    step "Checking CryoUtilities configuration..."

    # --- Check 1: Swapfile exists and is >= 16 GiB (critical) ---
    local swapfile_min_bytes=17179869184  # 16 * 1024^3
    if [[ ! -e "${SWAPFILE}" ]]; then
        err "Swapfile not found: ${SWAPFILE}"
        err "  CryoUtilities must be run first to create a 16 GiB swapfile."
        critical_ok=1
    else
        local swapfile_bytes
        swapfile_bytes=$(stat -c '%s' "${SWAPFILE}" 2>/dev/null) || {
            err "Cannot stat swapfile: ${SWAPFILE}"
            critical_ok=1
            swapfile_bytes=0
        }
        if (( swapfile_bytes >= swapfile_min_bytes )); then
            local swapfile_gib=$(( swapfile_bytes / 1073741824 ))
            ok "Swapfile: ${SWAPFILE} (${swapfile_gib} GiB >= 16 GiB)"
        else
            local swapfile_gib=$(( swapfile_bytes / 1073741824 ))
            err "Swapfile too small: ${swapfile_gib} GiB (need >= 16 GiB)"
            err "  Run CryoUtilities and set swapfile size to 16 GiB."
            critical_ok=1
        fi
    fi

    # --- Check 2: vm.swappiness == 1 (non-critical, warn only) ---
    local swappiness
    if [[ -r /proc/sys/vm/swappiness ]]; then
        swappiness=$(< /proc/sys/vm/swappiness)
    else
        swappiness=$(sysctl -n vm.swappiness 2>/dev/null) || swappiness="unknown"
    fi
    if [[ "${swappiness}" == "1" ]]; then
        ok "vm.swappiness = ${swappiness}"
    elif [[ "${swappiness}" == "unknown" ]]; then
        warn "vm.swappiness: could not be read"
    else
        warn "vm.swappiness = ${swappiness} (CryoUtilities sets this to 1)"
        warn "  Run CryoUtilities or: sudo sysctl -w vm.swappiness=1"
    fi

    # --- Check 3: vm.page-cluster == 0 or 1 (non-critical, warn only) ---
    local page_cluster
    if [[ -r /proc/sys/vm/page-cluster ]]; then
        page_cluster=$(< /proc/sys/vm/page-cluster)
    else
        page_cluster=$(sysctl -n vm.page-cluster 2>/dev/null) || page_cluster="unknown"
    fi
    if [[ "${page_cluster}" == "0" || "${page_cluster}" == "1" ]]; then
        ok "vm.page-cluster = ${page_cluster}"
    elif [[ "${page_cluster}" == "unknown" ]]; then
        warn "vm.page-cluster: could not be read"
    else
        warn "vm.page-cluster = ${page_cluster} (CryoUtilities sets this to 0 or 1)"
        warn "  Run CryoUtilities or: sudo sysctl -w vm.page-cluster=0"
    fi

    # --- Check 4: Transparent hugepages enabled (non-critical, warn only) ---
    local thp_file="/sys/kernel/mm/transparent_hugepage/enabled"
    if [[ ! -r "${thp_file}" ]]; then
        warn "Transparent hugepages: ${thp_file} not readable"
    else
        local thp_value
        thp_value=$(< "${thp_file}")
        if [[ "${thp_value}" == *"[always]"* ]]; then
            ok "Transparent hugepages: always (enabled)"
        else
            # Extract active mode (the bracketed entry)
            local thp_active
            thp_active=$(printf '%s' "${thp_value}" | grep -oP '\[\K[^\]]+' || echo "unknown")
            warn "Transparent hugepages: [${thp_active}] — CryoUtilities sets this to [always]"
            warn "  To fix: echo always | sudo tee ${thp_file}"
        fi
    fi

    if (( critical_ok == 0 )); then
        ok "CryoUtilities: all critical checks passed"
    else
        err "CryoUtilities: critical checks FAILED — hibernation may not work correctly"
    fi

    return "${critical_ok}"
}

# ---------------------------------------------------------------------------
# check_uma_buffer
#
# Best-effort check for UMA (Unified Memory Architecture) buffer size.
# Hibernation on Steam Deck works best with 1 GB UMA (not 4 GB).
# Reads VRAM allocation via DRM sysfs; warns if 4 GB UMA is likely.
#
# Returns: always 0 (non-critical; informational only)
# ---------------------------------------------------------------------------
check_uma_buffer() {
    step "Checking UMA buffer size..."

    local uma_gib_threshold=2147483648  # 2 GiB in bytes; above this → likely 4 GB UMA
    local vram_detected=0
    local vram_bytes=0
    local vram_source=""

    # Attempt 1: Read VRAM total from DRM sysfs (most reliable on Steam Deck).
    # /sys/class/drm/card*/device/mem_info_vram_total contains VRAM in bytes.
    local drm_dev
    for drm_dev in /sys/class/drm/card*/device/mem_info_vram_total; do
        [[ -r "${drm_dev}" ]] || continue
        local candidate
        candidate=$(< "${drm_dev}") 2>/dev/null || continue
        # Sanity check: must be a positive integer
        if [[ "${candidate}" =~ ^[0-9]+$ ]] && (( candidate > 0 )); then
            vram_bytes="${candidate}"
            vram_source="${drm_dev}"
            vram_detected=1
            break
        fi
    done

    # Attempt 2: Fall back to /proc/cmdline for explicit UMA hints.
    # Some setups pass umab=<bytes> on the kernel command line.
    if (( vram_detected == 0 )) && [[ -r /proc/cmdline ]]; then
        local cmdline
        cmdline=$(< /proc/cmdline)
        if [[ "${cmdline}" =~ umab=([0-9]+) ]]; then
            vram_bytes="${BASH_REMATCH[1]}"
            vram_source="/proc/cmdline (umab=)"
            vram_detected=1
        fi
    fi

    if (( vram_detected == 1 )); then
        local vram_mib=$(( vram_bytes / 1048576 ))
        if (( vram_bytes > uma_gib_threshold )); then
            warn "UMA buffer: ~${vram_mib} MiB detected (source: ${vram_source})"
            warn "  This looks like a 4 GB UMA configuration."
            warn "  Hibernation is significantly more reliable with 1 GB UMA."
            warn "  To change: Steam Deck → power off → hold Vol- + Power → BIOS"
            warn "  → Advanced → UMA Frame Buffer Size → 1 GB → Save & Exit"
        else
            ok "UMA buffer: ~${vram_mib} MiB (source: ${vram_source}) — looks like 1 GB UMA"
        fi
    else
        warn "UMA buffer: could not be determined automatically"
        warn "  Please verify manually in BIOS:"
        warn "    Power off → hold Vol- + Power → BIOS → Advanced"
        warn "    → UMA Frame Buffer Size → set to 1 GB → Save & Exit"
        warn "  Hibernation is NOT reliable with 4 GB UMA."
    fi

    return 0
}

# ---------------------------------------------------------------------------
# cmd_fix_wifi_wake
#
# Fix the "wakes immediately after hibernate/suspend" issue caused by WiFi
# or USB/XHC ACPI wakeup sources remaining enabled.
#
# Approach A: Disable ACPI wakeup for XHC/USB and WiFi PCI devices via sysfs
#             (installed as a systemd service so it persists across reboots).
# Approach B: Print instructions for enabling WPA Supplicant mode in Steam,
#             which also prevents spurious wakeups from the WiFi stack.
#
# Also checks for Steam "Wake on Music" which can cause premature wake.
#
# Returns: 0 on success, 1 if service installation failed.
# ---------------------------------------------------------------------------
cmd_fix_wifi_wake() {
    step "Fixing WiFi/USB wakeup sources..."

    # -----------------------------------------------------------------------
    # Approach A: Disable ACPI wakeup via sysfs power/wakeup files
    # -----------------------------------------------------------------------

    # Collect XHC/XHCI entries from /proc/acpi/wakeup that are currently enabled.
    # File format (columns): Device  Sleep-State  Status  Sysfs-Node
    local xhc_entries=()
    if [[ -r /proc/acpi/wakeup ]]; then
        while IFS= read -r line; do
            # Match lines whose first token is XHC* or XHCI* and status is *enabled
            local dev_name
            dev_name=$(printf '%s' "${line}" | awk '$3 == "*enabled" && $1 ~ /^(XHC[0-9A-Z]*|XHCI[0-9A-Z]*)$/ { print $1 }')
            [[ -n "${dev_name}" ]] && xhc_entries+=("${dev_name}")
        done < /proc/acpi/wakeup
    fi

    if (( ${#xhc_entries[@]} > 0 )); then
        info "Found enabled ACPI wakeup entries: ${xhc_entries[*]}"
    else
        info "No enabled XHC/XHCI ACPI wakeup entries found (or /proc/acpi/wakeup not readable)"
    fi

    # Collect PCI sysfs power/wakeup paths for WiFi and USB host controllers.
    # - WiFi: PCI class 0x028000 (802.11 network controller) or driver name ath11k
    # - USB host: PCI class 0x0C0330 (xHCI), 0x0C0320 (EHCI), 0x0C0310 (OHCI)
    local wakeup_paths=()
    local uevent_path pci_dev_dir
    for uevent_path in /sys/bus/pci/devices/*/uevent; do
        [[ -r "${uevent_path}" ]] || continue
        pci_dev_dir="${uevent_path%/uevent}"

        local pci_class="" pci_driver=""
        while IFS='=' read -r key val; do
            case "${key}" in
                PCI_CLASS) pci_class="${val}" ;;
                DRIVER)    pci_driver="${val}" ;;
            esac
        done < "${uevent_path}"

        # Also check driver symlink if DRIVER was not in uevent
        if [[ -z "${pci_driver}" && -L "${pci_dev_dir}/driver" ]]; then
            pci_driver=$(basename "$(readlink "${pci_dev_dir}/driver")") 2>/dev/null || true
        fi

        local is_target=0
        # Normalize class to uppercase for comparison (kernel may omit leading zeros)
        local pci_class_upper="${pci_class^^}"
        case "${pci_class_upper}" in
            028000|"0X028000") is_target=1 ;;   # 802.11 wireless
            0C0330|0C0320|0C0310) is_target=1 ;; # USB host controller
        esac
        [[ "${pci_driver}" == *ath11k* ]] && is_target=1

        if (( is_target == 1 )); then
            local wakeup_file="${pci_dev_dir}/power/wakeup"
            if [[ -w "${wakeup_file}" ]]; then
                wakeup_paths+=("${wakeup_file}")
            fi
        fi
    done

    if (( ${#wakeup_paths[@]} == 0 )); then
        info "No writable PCI sysfs wakeup paths found for WiFi/USB devices"
    else
        info "Found PCI wakeup paths to disable: ${wakeup_paths[*]}"
    fi

    # Build the systemd service ExecStart lines.
    # XHC entries: writing the device name to /proc/acpi/wakeup toggles its state.
    # We check state at runtime inside the service so we only toggle if still enabled.
    local exec_lines=""
    for dev in "${xhc_entries[@]}"; do
        # Toggle only if currently enabled (grep for "<dev> *enabled" pattern)
        exec_lines+="ExecStart=/bin/sh -c 'grep -q \"^${dev}.*\\*enabled\" /proc/acpi/wakeup 2>/dev/null && echo ${dev} > /proc/acpi/wakeup || true'\n"
    done

    for wakeup_file in "${wakeup_paths[@]}"; do
        exec_lines+="ExecStart=/bin/sh -c 'echo disabled > ${wakeup_file} || true'\n"
    done

    if [[ -z "${exec_lines}" ]]; then
        warn "No wakeup sources identified to disable"
        warn "  Check /proc/acpi/wakeup and /sys/bus/pci/devices/ manually"
        exec_lines="ExecStart=/bin/true\n"
    fi

    # Install the systemd service.
    local service_name="${WAKEFIX_SERVICE:-steamdeck-fix-wifi-wake.service}"
    local service_path="/etc/systemd/system/${service_name}"

    info "Installing wakeup-disable service: ${service_path}"

    # Construct service file content without using a heredoc through sudo tee,
    # so that variable expansion is controlled and the file is written atomically.
    local service_content
    service_content="$(cat << EOF
[Unit]
Description=Disable WiFi/USB ACPI wakeup sources (Steam Deck hibernation fix)
After=multi-user.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
$(printf '%b' "${exec_lines}")
[Install]
WantedBy=multi-user.target
EOF
)"

    if ! printf '%s\n' "${service_content}" | sudo tee "${service_path}" > /dev/null; then
        err "Failed to write service file: ${service_path}"
        return 1
    fi

    sudo systemctl daemon-reload 2>/dev/null || true

    if sudo systemctl enable --now "${service_name}" 2>/dev/null; then
        ok "Wakeup-disable service installed and started: ${service_name}"
    else
        err "Failed to enable/start service: ${service_name}"
        return 1
    fi

    # -----------------------------------------------------------------------
    # Approach B: WPA Supplicant mode (Steam GUI setting — cannot automate)
    # -----------------------------------------------------------------------
    info ""
    info "--- Approach B: Enable WPA Supplicant WiFi backend in Steam ---"
    info "  This prevents the WiFi firmware from triggering spurious wakeups."
    info "  This cannot be set programmatically; you must use the Steam UI:"
    info ""
    info "    1. Press the Steam button → Settings → System"
    info "    2. Scroll to 'Developer Mode' and toggle it ON"
    info "    3. A 'Developer' section now appears in the left sidebar — open it"
    info "    4. Enable: 'Use Experimental WiFi Backend (WPA Supplicant)'"
    info "    5. Reboot the Steam Deck"
    info ""
    info "  Note: WPA Supplicant may cause slightly slower WiFi reconnection"
    info "  after resume, but eliminates the immediate-wake issue for most users."

    # -----------------------------------------------------------------------
    # Bonus: Check Steam "Wake on Music" setting in localconfig.vdf
    # -----------------------------------------------------------------------
    # Steam stores this as a VDF (Valve Data Format) key-value under the user's
    # config. The key name observed in the wild is "UseWakeOnMusicEnabled".
    local localconfig="/home/deck/.steam/steam/config/localconfig.vdf"
    if [[ -r "${localconfig}" ]]; then
        local wake_music_line
        wake_music_line=$(grep -i "UseWakeOnMusicEnabled\|WakeOnMusic\|UseAsWakeMovie" \
            "${localconfig}" 2>/dev/null | head -1) || true

        if [[ -n "${wake_music_line}" ]]; then
            # Extract the value token — VDF format: "KeyName"  "value"
            local wake_music_val
            wake_music_val=$(printf '%s' "${wake_music_line}" \
                | grep -oP '"\K[01](?=")' | head -1) || wake_music_val=""

            if [[ "${wake_music_val}" == "1" ]]; then
                warn "Steam 'Wake on Music' is ENABLED in ${localconfig}"
                warn "  This causes the Steam Deck to wake from hibernation to play music."
                warn "  Disable it: Steam → Settings → Music → disable 'Play while waking from sleep'"
            else
                ok "Steam 'Wake on Music' is disabled in localconfig.vdf"
            fi
        else
            info "Steam 'Wake on Music' key not found in localconfig.vdf (likely off by default)"
        fi
    else
        info "Steam localconfig.vdf not found at ${localconfig}; skipping Wake on Music check"
        info "  If running as a non-deck user, check: ~/.steam/steam/config/localconfig.vdf"
    fi

    return 0
}
