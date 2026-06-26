# steamdeck-hibernation

Automated suspend-then-hibernate setup for Steam Deck (OLED/LCD) with ext4 `/home`.

Based on the [nazar256 hibernation guide](https://github.com/nazar256/publications/blob/main/guides/steam-deck-hibernation.md).

> **No warranty.** Hibernation is unsupported by Valve. A wrong `resume_offset` will prevent resume (recoverable via USB recovery stick). Proceed at your own risk.

---

## Requirements

- Steam Deck OLED or LCD running SteamOS 3.x
- **ext4** `/home` partition (not BTRFS)
- [CryoUtilities](https://github.com/CryoByte33/steam-deck-utilities) installed and applied:
  - `vm.swappiness = 1`
  - Swapfile ≥ 16 GiB (20 GiB recommended)
- BIOS settings (enter with **Vol+ + Power** at boot):
  - **Quick Boot → Disabled**
  - **UMA Frame Buffer Size → 1G** (not 4G, not Auto)

---

## Setup

### 1. Download the script

```bash
mkdir -p ~/.local/bin
curl -o ~/.local/bin/steamdeck-hibernate.sh \
  https://raw.githubusercontent.com/bseleng/steam-deck-hibbernation-all-in-one/main/steamdeck-hibernate.sh
chmod +x ~/.local/bin/steamdeck-hibernate.sh
cd ~/.local/bin
```

### 2. Verify prerequisites

```bash
sudo ./steamdeck-hibernate.sh check-prereqs
```

Checks CryoUtilities settings, swapfile size, UMA buffer, and required tools. Fix any failures before continuing.

### 3. Install

```bash
sudo ./steamdeck-hibernate.sh install
```

Applies: swapfile, GRUB resume parameters, logind memory-check bypass, sleep config, Bluetooth fix, GRUB boot counter fix, and boot-time reapply service.

### 4. Reboot

```bash
sudo reboot
```

The kernel resume parameters only take effect after reboot.

### 5. Verify logic (read-only, no hardware needed)

```bash
sudo ./steamdeck-hibernate.sh self-test
```

Validates UUID, resume offset, GRUB parameters, and sleep config without touching anything.

### 6. Test suspend

```bash
sudo ./steamdeck-hibernate.sh test-suspend
```

Suspends for 20 seconds via RTC alarm. Detects immediate-wake issues and analyses the wakeup source.

**If the deck wakes immediately** (common after SteamOS updates):

```bash
sudo ./steamdeck-hibernate.sh fix-wifi-wake
# reboot, then test-suspend again
# if still waking:
sudo ./steamdeck-hibernate.sh disable-all-wakeup
```

### 7. Test hibernation

```bash
sudo ./steamdeck-hibernate.sh test-hibernate
```

Triggers a real hibernation. The deck powers off — press the power button to resume. Confirm Bluetooth and display work correctly after resume.

### 8. Enable suspend-then-hibernate

```bash
sudo ./steamdeck-hibernate.sh enable-sth
```

From this point, every suspend (lid close / sleep button) will suspend first, then automatically hibernate after **60 minutes** (configurable with `--delay`).

---

## All commands

| Command | Description |
|---|---|
| `check-prereqs` | Verify CryoUtilities, UMA, swapfile, tools |
| `install` | Apply all hibernation config |
| `self-test` | Read-only logic checks after install + reboot |
| `test-suspend` | Suspend via RTC alarm, detect immediate-wake |
| `test-hibernate` | Trigger real hibernation |
| `enable-sth` | Make every suspend = suspend-then-hibernate |
| `disable-sth` | Revert to plain suspend |
| `fix-swapfile` | Recreate swapfile as a single contiguous extent (then reboot) |
| `fix-wifi-wake` | Disable WiFi/XHC wakeup, check mem_sleep mode |
| `fix-wake <DEV>` | Disable one specific ACPI wakeup device |
| `disable-all-wakeup` | Nuclear: disable all wakeup except power button |
| `diagnose-wake` | Full PM log + ACPI wakeup analysis |
| `status` | Show state of every component |
| `reapply` | Re-apply config (used after SteamOS updates) |
| `bios-tips` | Print BIOS settings guide |
| `install-cec` | TV off via HDMI-CEC on sleep (dock users) |
| `uninstall` | Remove all changes (swapfile is kept) |

**Flags:**

```
--delay <D>    Time in suspend before hibernating (default: 60min, e.g. 2h, 90min)
--size <N>     Swapfile size in GiB (default: 20)
--dry-run      Print what would happen, change nothing
--yes          Skip confirmation prompts
```

---

## After SteamOS updates

SteamOS updates overwrite `/etc/default/grub` and `/etc/systemd/sleep.conf`. A boot-time reapply service handles this automatically. If hibernation stops working after an update:

```bash
sudo ./steamdeck-hibernate.sh reapply --yes
sudo reboot
```

---

## Troubleshooting

**"sleep verb 'hibernate' is disabled by config"**
A SteamOS vendor drop-in is overriding `AllowHibernation=yes`. Run `reapply` — it writes `zzz-steamdeck-hibernate.conf` which sorts last and wins.

**Deck wakes immediately after suspend**
Run `fix-wifi-wake`. If that doesn't help, run `disable-all-wakeup`. Check `cat /sys/power/mem_sleep` — it must show `[deep]`, not `[s2idle]`.

**Bluetooth devices don't reconnect after hibernate**
The `fix-bluetooth-resume` service handles this automatically. Check it ran:
```bash
journalctl -u fix-bluetooth-resume.service --since "-5 min"
```

**"Failed to boot" screen after several hibernation cycles**
The GRUB boot counter fix (installed by default) prevents this. If it appears anyway, select "Current" — it is cosmetic.

**Deck boots fresh instead of resuming session (resume fails silently)**
The swapfile is likely fragmented. `self-test` will report the extent count. Fix:
```bash
sudo ./steamdeck-hibernate.sh fix-swapfile
sudo reboot
```
Requires ~20 GiB free on `/home`. After recreation the `resume_offset` changes — GRUB is updated automatically, but a reboot is required.

**Deck won't resume from hibernate (black screen)**
Hold power for 10 seconds to force reboot. The hibernation image is discarded and the deck boots normally. This is recoverable.

---

## What the script changes

| File / location | What |
|---|---|
| `/etc/default/grub` | Adds `resume=UUID resume_offset=N` kernel params |
| `/etc/systemd/sleep.conf` | Sets `AllowHibernation=yes`, `HibernateDelaySec` |
| `/etc/systemd/sleep.conf.d/zzz-steamdeck-hibernate.conf` | Overrides vendor `AllowHibernation=no` drop-in |
| `/etc/systemd/system/systemd-logind.service.d/override.conf` | Sets `SYSTEMD_BYPASS_HIBERNATION_MEMORY_CHECK=1` |
| `/etc/systemd/system/fix-bluetooth-resume.service` | Rebinds BT driver after resume |
| `/etc/systemd/system-sleep/steamdeck-fix-boot-counter.sh` | Resets GRUB boot counter after hibernate |
| `/etc/systemd/system/steamdeck-hibernate-reapply.service` | Re-applies config at boot after SteamOS updates |
| `/var/lib/steamdeck-hibernate/` | Script copy + BT fix script |
| `/home/swapfile` | 20 GiB swapfile (created if missing) |

`uninstall` removes all of the above except the swapfile.
