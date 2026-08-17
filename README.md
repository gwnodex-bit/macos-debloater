<div align="center">

<pre>
███████╗██╗   ██╗ ██████╗██╗  ██╗ █████╗ ███████╗██╗     ██████╗
██╔════╝██║   ██║██╔════╝██║ ██╔╝██╔══██╗██╔════╝██║     ██╔══██╗
█████╗  ██║   ██║██║     █████╔╝ ███████║███████╗██║     ██████╔╝
██╔══╝  ██║   ██║██║     ██╔═██╗ ██╔══██║╚════██║██║     ██╔══██╗
██║     ╚██████╔╝╚██████╗██║  ██╗██║  ██║███████║███████╗██║  ██║
╚═╝      ╚═════╝  ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚══════╝╚═╝  ╚═╝
</pre>

**Fuck off the macOS services you don't use. Fuck all of em, or just the safe ones — your call, from a menu.**

<a href="macos-debloater.sh"><img src="https://img.shields.io/badge/macOS-12%20%E2%80%93%2026-000000?logo=apple&logoColor=white&style=for-the-badge" alt="macOS 12-26"/></a>
<a href="macos-debloater.sh"><img src="https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white&style=for-the-badge" alt="Bash"/></a>
<a href="macos-debloater.sh"><img src="https://img.shields.io/badge/Telemetry-None-2ea44f?style=for-the-badge" alt="No telemetry"/></a>
<a href="macos-debloater.sh"><img src="https://img.shields.io/badge/Root-only-important?style=for-the-badge" alt="Root only"/></a>
<a href="macos-debloater.sh"><img src="https://img.shields.io/badge/Modes-1%20%E2%80%93%204-orange?style=for-the-badge" alt="Modes 1-4"/></a>
<a href="macos-debloater.sh"><img src="https://img.shields.io/badge/Enterprise-MDM%20ready-5865F2?style=for-the-badge" alt="Enterprise MDM ready"/></a>

</div>

```bash
curl -fsSL https://raw.githubusercontent.com/xscope0/macos-debloater/main/install.sh | bash
macos-debloater
```

One script. No daemon, no account, no telemetry. It turns services off the same way `launchctl disable` does, and it can undo everything it does.

---

## What this shit does?

macOS starts roughly 200 background services on every boot. Plenty of them exist to phone home, sync, index, or just sit around waiting for a feature you never open. This script turns off the ones you pick, by writing the same launchd disabled database that `launchctl disable` writes. Nothing under `/System` gets touched. No plist gets deleted. Every change is one command away from being undone.

It also applies the optimization tweaks that are safe enough to ship: window and dock animations off, transparency off, Spotlight indexing off, power nap and wake-on-LAN off. The aggressive modes add kernel and network settings that are documented, revertible, and labeled with what they can cost you.

It is **not** a "cleaner," a "booster," or anything that claims to make your Mac 10x faster. It turns services off. Some of those services are things you actually use — that's the trade, and the menu says so before you apply.

---

## Modes

| Mode | Services disabled | What you lose | Risk |
|---|---|---|---|
| 1 · Safe | 65 | Telemetry, analytics, diagnostics, Siri and Apple Intelligence backends | Nothing user-facing. Reversible. |
| 2 · Balanced | 105 | Mode 1 + iCloud extras, Maps, media extras, App Store, network-sharing services | Some features. Reversible. |
| 3 · Aggressive | 152 | Mode 2 + Spotlight, Find My, Messages, FaceTime, AirDrop/AirPlay, Screen Sharing, Time Machine, Photos, Wallet, Screen Time | Many features. Reversible. |
| 4 · Dangerous | 198 | Mode 3 + the thermal daemon, App Store, Mail, Contacts, crash reporting, live transcription | Real. Double-confirmed before applying. |

The counts are the resolved plan on macOS Sequoia (15.x), measured by the script itself on a real install. They shift a bit by OS version, because every entry has to resolve to a plist that actually exists on your macOS before it gets touched.

The catalog has **201 entries** across four risk tiers. Every entry is a real launchd label with a description.

---

## How you use it

Everything lives in one menu. No flags, no arguments, nothing to remember:

- **Pick a mode** — Safe through Dangerous. It prints the full plan before anything happens.
- **Dry-run** — flip it on and every command is shown without being run. This works even with SIP enabled.
- **Custom** — type specific labels (`com.apple.weatherd com.apple.newsd`) and only those get turned off.
- **List** — print the whole catalog for your exact macOS version.
- **Restore** — undo the last run, restore the defaults/pmset/Spotlight tweaks, or re-enable every catalog entry. Restore needs no network and no account.

Two safety rails sit under the whole thing:

1. **A hard deny list.** Boot-critical services — `com.apple.WindowServer`, `com.apple.loginwindow`, and friends — are refused even if you type them by hand.
2. **Snapshot before change.** Every run saves the current disabled database and the old value of every tweak to `/Library/Application Support/macos-debloater/backups/` before touching anything.

### Requirements

- **Root.** The script auto-elevates with `sudo`. State is system-wide and one run covers every user account on the machine.
- **SIP disabled** for real runs. Dry-run, list, and restore work without it. The menu has a SIP help item with the Recovery-mode steps and a video link.
- **macOS 12, 13, 14, 15, or 26.** Anything else is refused at startup.

---

## Enterprise / fleets

Same script, fleet use. IT pre-seeds a config file and the script applies silently — no menu, no prompts:

```ini
# /Library/Application Support/macos-debloater/config
MODE=2
DRY_RUN=0
AUTO_APPLY=1
```

Deploy with MDM: push the config, run `macos-debloater` once per machine. The config file **is** the authorization — its contents replace every confirmation prompt. That's exactly why the dangerous keys (`HIBERNATE_OFF`, `FILEVAULT_DISABLE`, `NETWORK_TUNING`, `ASK_THERMAL`) default to off and have to be set deliberately.

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

Run as root and one run covers **every user account**: gui-domain services get turned off per-uid for each account, snapshots capture every user's disabled database, and the generated restore script re-enables all of them.

---

## The bits that need a warning label

These are in the script, they work, and they each print a warning before they run. Read them once:

- **Thermal daemon (Mode 4, and only Mode 4 by default).** `com.apple.thermalmonitord` on Apple Silicon, `com.apple.thermald` on Intel. Turning it off removes the CPU's thermal throttling. The machine still boots — it can also overheat. On a laptop, that's permanent hardware damage territory. You have to type `YES`, not just `y`, to include it.
- **Hibernation off (Mode 4, opt-in).** `hibernatemode 0` stops writing the RAM-sized sleepimage on sleep. Saves SSD space and write wear. If the battery drains completely while asleep, unsaved work is gone — there's no disk fallback.
- **FileVault off (Mode 4, opt-in).** On Apple Silicon the encryption is hardware-accelerated, so the speed gain is roughly zero and you lose whole-disk encryption. There's also a documented FileVault boot-loop bug on 12.3 multi-volume setups. The script tells you this, then asks again.
- **Network buffer tuning (Mode 4, opt-in).** The ESnet values (`win_scale_factor 8`, 32 MB autotune buffers) are for wired 1Gbps+ links. On Wi-Fi they can *reduce* throughput.
- **`debug.lowpri_throttle_enabled=0` (Mode 3+).** Removes the background-task CPU throttle. Real latency win; costs some heat. It's a sysctl — it reverts on reboot, and the script also records and restores the old value.

Kernel settings applied in a run are re-applied at boot by a generated LaunchDaemon (`/Library/LaunchDaemons/com.macos-debloater.sysctl.plist`) and removed on restore. That's the persistence mechanism, and it's the reason the script doesn't use `/etc/sysctl.conf` — macOS 15+ (SIP intact) doesn't reliably load it.

---

## What you should *not* do

The research behind the risky modes (full notes in [RESEARCH.md](RESEARCH.md)) turned up a short list of "optimizations" that break machines. They are deliberately **not** in the script:

- **Disabling swap or memory compression.** `vm.compressor_mode` / swap-off causes kernel panics under memory pressure. The "you can reclaim GBs of RAM" claim is the single most dangerous piece of debloat lore on the internet. Not in here.
- **`kern.maxfiles` sysctls.** Already ~300k on modern macOS. The real fix for "too many open files" is per-process via `launchctl limit maxfiles`, which the script does (65536/131072).
- **Deleting launchd plists.** The script never deletes a plist. Deleting plists is what actually bricks boot; `launchctl disable` is the reversible path.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/xscope0/macos-debloater/main/install.sh | bash
```

The installer prints the banner, downloads `macos-debloater.sh` from this repo with a spinner, verifies it's a valid bash script, and installs it to `/usr/local/bin` (auto-elevating with sudo when needed). It doesn't run the debloater, doesn't phone home, and doesn't leave anything behind except the script.

Uninstall is deleting one file:

```bash
sudo rm /usr/local/bin/macos-debloater
```

---

## What's in the repo

```
macos-debloater/
├── macos-debloater.sh      the whole tool: catalog, TUI, apply, restore
├── install.sh              curl one-liner installer (banner + progress)
├── README.md               this file
└── RESEARCH.md             sources + risk analysis behind the risky modes
```

### Inside `macos-debloater.sh`

A single bash script, sections in order:

```
macos-debloater.sh
├── env                    OS/CPU/RAM detection, system-wide state paths
├── config                 enterprise presets loaded before the TUI
├── OS support + SIP       refuses unsupported macOS; SIP gate + Recovery help
├── deny list              boot/critical services that are never disabled
├── CATALOG                201 service entries: label|hint|tier|group|since|desc
├── resolve                matches every label to a real plist on this macOS
├── service actions        launchctl disable/enable, per-user gui domain
├── snapshot + restore     disabled-DB snapshot, manifest, generated restore.sh
├── optimization tweaks    defaults / pmset / sysctl / mdutil, old values saved
├── output                 catalog listing, header, mode notes
├── TUI                    the menu: 13 items, mouse + keyboard
├── prompts + gates        thermal YES-gate, double-confirm, reboot prompt
├── silent fleet run       AUTO_APPLY: config replaces the TUI, no prompts
└── main                   load_config -> TUI (or silent) -> SIP gate -> apply
```

### Runtime state (written when you run it)

```
/Library/Application Support/macos-debloater/
├── config                 your presets (MODE, AUTO_APPLY, ...)
├── manifest.txt           what the last run disabled
├── restore.sh             generated: re-enables everything in the manifest
├── backups/<timestamp>/   one directory per run
│   ├── disabled.plist.bak        system disabled DB
│   ├── disabled.<uid>.plist.bak  per-user disabled DBs (every account)
│   ├── disabled-print.txt        launchctl print-disabled for all domains
│   ├── opts-backup.txt           old defaults/pmset/sysctl values
│   ├── mdutil-backup.txt         Spotlight index state
│   └── sysctl-applied.txt        sysctls to re-apply at boot
└── ...and the boot plist:
    /Library/LaunchDaemons/com.macos-debloater.sysctl.plist
```

### The catalog format

Each line in `CATALOG`:

```ini
com.apple.somethingd|gui|2|cloud|12|What it does, honestly
```

| Field | Meaning |
|---|---|
| `label` | launchd label, e.g. `com.apple.somethingd` |
| `hint` | `gui` or `system` domain hint |
| `tier` | risk tier: `1` safe, `2` aggressive, `3` thermal, `4` dangerous |
| `group` | `cloud` / `maps` / `media` / `store` / `network` / `access` / `misc` |
| `since` | first macOS this entry applies to (older ignored) |
| `desc` | one-line description shown in the plan and catalog |

The script only acts on an entry if the plist resolves on the running macOS — a wrong guess degrades to "skipped," never to "disabled something important."

---

## DIY

```bash
git clone https://github.com/xscope0/macos-debloater.git
cd macos-debloater
bash -n macos-debloater.sh        # syntax
shellcheck macos-debloater.sh     # lint, clean at warning level
```

To add a catalog entry, add a line to `CATALOG` in the script per the format above.

---

*No affiliation with Apple. macOS is a trademark of Apple Inc. This tool modifies your system; test in dry-run first, and keep the restore script it writes.*
