# macos-debloater

Turn off the macOS services you don't use. All of them, or just the safe ones — your call, from a menu.

One script. No agent, no daemon, no account, no telemetry. It writes to the launchd disabled database, exactly the way `launchctl disable` does it, and it can undo everything it does.

```bash
curl -fsSL https://raw.githubusercontent.com/xscope0/macos-debloater/main/install.sh | bash
macos-debloater
```

---

## What it actually does

macOS starts ~200 background services on every boot. Most of them exist to phone home, sync, index, or wait for a feature you never open. This script disables the ones you choose, by writing the same XPC disabled database that `launchctl disable` writes. Nothing under `/System` is touched. No plist is deleted. Every change is one command away from being undone.

It also applies the optimization tweaks that are safe enough to ship: window and dock animation off, transparency off, Spotlight indexing off, power-nap and wake-on-LAN off, and — in the aggressive modes — kernel and network settings that are documented, revertible, and labelled with what they can cost you.

**What it is not:** a "cleaner," a "booster," a "defender," or anything that claims to make your Mac 10x faster. It disables services. Some of those services are things you use. That's the trade, and it's printed in the menu.

---

## Modes

| Mode | Services disabled | What you lose | Risk |
|---|---|---|---|
| 1 · Safe | 65 | Telemetry, analytics, diagnostics, Siri and Apple Intelligence backends | None user-facing. Reversible. |
| 2 · Balanced | 105 | Mode 1 + iCloud extras, Maps, media extras, App Store, network-sharing services | Some features. Reversible. |
| 3 · Aggressive | 152 | Mode 2 + Spotlight, Find My, Messages, FaceTime, AirDrop/AirPlay, Screen Sharing, Time Machine, Photos, Wallet, Screen Time | Many features. Reversible. |
| 4 · Dangerous | 198 | Mode 3 + the thermal daemon, App Store, Mail, Contacts, crash reporting, live transcription | Real. Double-confirmed before applying. |

Counts are the resolved plan for macOS Sequoia (15.x), measured by the script itself on a real install — they vary slightly by OS version because every entry must resolve to a plist that actually exists before it's touched.

The catalog has 201 entries across four risk tiers. Every entry is a real launchd label with a description, and every one must resolve to a plist on *your* macOS before the script will touch it.

---

## How you use it

Everything lives in one TUI. No flags, no arguments, nothing to remember:

- **Pick a mode** — Safe through Dangerous. The plan is printed before anything happens.
- **Dry-run** — toggle it on and every command is shown without being executed. This works even with SIP enabled.
- **Custom** — type specific labels (`com.apple.weatherd com.apple.newsd`) and only those get disabled.
- **List** — print the full catalog for your exact macOS version.
- **Restore** — undo the last run, restore the defaults/pmset/Spotlight tweaks, or re-enable every catalog entry. Restore needs no network and no account.

Two safety rails sit under the whole thing:

1. **A hard deny list.** Boot-critical services — `com.apple.WindowServer`, `com.apple.loginwindow`, and friends — are refused even if you type them by hand.
2. **Snapshot before change.** Every run writes the current disabled database and every optimization's old value to `/Library/Application Support/macos-debloater/backups/` before touching anything.

### Requirements

- **Root.** The script auto-elevates with `sudo`. State is system-wide and covers every user account on the machine in one run.
- **SIP disabled** for real runs (dry-run, list, and restore work regardless). The menu has a SIP help item with the Recovery-mode steps and a video link.
- macOS 12, 13, 14, 15, or 26. Anything else is refused at startup.

---

## Enterprise / fleet

The same script is the fleet tool. IT pre-seeds a config file and the script applies silently — no TUI, no prompts:

```
# /Library/Application Support/macos-debloater/config
MODE=2
DRY_RUN=0
AUTO_APPLY=1
```

Deploy with MDM: push the config, run `macos-debloater` once per machine. The config file *is* the authorization — its existence and contents replace every confirmation prompt, which is exactly why the dangerous keys (`HIBERNATE_OFF`, `FILEVAULT_DISABLE`, `NETWORK_TUNING`, `ASK_THERMAL`) default to off and have to be set deliberately.

Supported keys:

| Key | Default | Effect |
|---|---|---|
| `MODE` | — | 1–4, required with `AUTO_APPLY` |
| `DRY_RUN` | `0` | `1` = preview only |
| `AUTO_APPLY` | `0` | `1` = silent run, no TUI |
| `ASK_THERMAL` | `0` | `1` = include the thermal daemon in Modes 1–3 |
| `HIBERNATE_OFF` | `0` | Mode 4: `hibernatemode 0` + delete sleepimage |
| `FILEVAULT_DISABLE` | `0` | Mode 4: turn FileVault off (security loss, ~no speed gain on Apple Silicon) |
| `NETWORK_TUNING` | `0` | Mode 4: ESnet TCP buffers (wired 1Gbps+ only, degrades Wi-Fi) |
| `MANUAL_LABELS` | — | Comma-separated labels, overrides mode |

When run as root, one run covers **every user account** — gui-domain services are disabled per-uid for each account the machine has, snapshots capture every user's disabled database, and the generated restore script re-enables all of them.

---

## The bits that need a warning label

These are in the script, they work, and they each carry a printed warning before they run. Read them once:

- **Thermal daemon (Mode 4, and Mode 4 only by default).** `com.apple.thermalmonitord` on Apple Silicon, `com.apple.thermald` on Intel. Disabling it removes the CPU's thermal throttling. The machine still boots — it can also overheat. On a laptop, that's permanent hardware damage territory. You must type `YES`, not just `y`, to include it.
- **Hibernation off (Mode 4, opt-in).** `hibernatemode 0` stops writing the RAM-sized sleepimage on sleep. Saves SSD space and write wear. If the battery drains completely while asleep, unsaved work is gone — there's no disk fallback.
- **FileVault off (Mode 4, opt-in).** On Apple Silicon the encryption is hardware-accelerated, so the speed gain is roughly zero and you lose whole-disk encryption. There's also a documented FileVault boot-loop bug on 12.3 multi-volume setups. The script tells you this, then asks again.
- **Network buffer tuning (Mode 4, opt-in).** The ESnet values (`win_scale_factor 8`, 32 MB autotune buffers) are for wired 1Gbps+ links. On Wi-Fi they can *reduce* throughput.
- **`debug.lowpri_throttle_enabled=0` (Mode 3+).** Removes the background-task CPU throttle. Real latency win; costs some heat. It's a sysctl — it reverts on reboot, and the script also records and restores the old value.

Kernel settings applied in a run are re-applied at boot by a generated LaunchDaemon (`/Library/LaunchDaemons/com.macos-debloater.sysctl.plist`) and removed on restore. That's the persistence mechanism, and it's the documented reason the script does not use `/etc/sysctl.conf` — macOS 15+ (SIP intact) doesn't reliably load it.

---

## What you should *not* do

The research that built this script (full notes in [RESEARCH.md](RESEARCH.md)) turned up a short list of "optimizations" that break machines. They are deliberately **not** in the script:

- **Disabling swap or memory compression.** `vm.compressor_mode` / swap-off causes kernel panics under memory pressure. The "you can reclaim GBs of RAM" claim is the single most dangerous piece of debloat lore on the internet. Not in here.
- **`kern.maxfiles` sysctls.** Already ~300k on modern macOS. The real fix for "too many open files" is per-process via `launchctl limit maxfiles`, which the script does (65536/131072).
- **Deleting launchd plists.** The script never deletes a plist. Deleting plists is what actually bricks boot; `launchctl disable` is the reversible path.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/xscope0/macos-debloater/main/install.sh | bash
```

The installer downloads `macos-debloater.sh` from this repo, verifies it's a valid bash script, installs it to `/usr/local/bin`, and stops. It doesn't run the debloater, doesn't phone home, and doesn't leave anything behind except the script.

Uninstall is deleting one file:

```bash
sudo rm /usr/local/bin/macos-debloater
```

---

## Development

```bash
git clone https://github.com/xscope0/macos-debloater.git
cd macos-debloater
bash -n macos-debloater.sh        # syntax
shellcheck macos-debloater.sh     # lint, clean at warning level
```

To contribute a catalog entry, add a line to `CATALOG` in the script:

```
com.apple.somethingd|gui|2|cloud|12|What it does, honestly
```

Fields: `label|domain-hint|tier(1-4)|group|min-macOS-version|description`. The script only acts on an entry if the plist resolves on the running macOS — a wrong guess degrades to "skipped," never to "disabled something important."

---

*No affiliation with Apple. macOS is a trademark of Apple Inc. This tool modifies your system; test in dry-run first, and keep the restore script it writes.*
