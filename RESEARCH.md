# macOS debloat — performance / memory research (Aug 2026)

Deep research into what can be modified on macOS 12-26 for higher performance
and lower RAM usage, risk-tiered so a debloater never boots the machine into a
loop. ~36 web searches + primary sources: ESnet, The Eclectic Light Company,
Apple Stack Exchange, Renoise daemon-minimization thread, Leo-YiLuan
Disable-Swap guide, Apple discussions, Apple support, Reddit r/MacOS +
r/Mac, Avid DUC (Pro Tools).

## 0. The boot-safety principle (what must never change)

- **Deny list** (never disable): WindowServer, loginwindow, logind, notifyd,
  configd, launchd itself, diskarbitrationd, fseventsd, opendirectoryd,
  securityd, cfprefsd, syslogd/logd family.
- **Never disable swap / memory compression.** `vm.compressor_mode`,
  `vm_compressor` boot-args and swap-off are the single most crash-prone
  "optimizations" on macOS. Sources: Leo-YiLuan guide ("with insufficient
  memory the kernel may terminate processes"), Apple discussions ("never
  really safe to do so"), windsketch.cc ("Disable swap would cause kernel
  panic if there is not enough RAM"). On an 8 GB M1 this is asking for a
  panic. **Deliberately excluded from the script.**
- **SIP must be off** for real system-domain disables (launchctl disable
  writes the XPC disabled DB). With SIP on, the script blocks real runs.
- **bootout without disable** is not persistent; `launchctl disable` /
  `enable` only (XPC disabled DB) is reversible without touching /System.

## 1. What actually reduces RAM / CPU (most to least)

| Tweak | Effect | Risk |
|---|---|---|
| Disable Apple Intelligence daemons (Sequoia 15.3+, Tahoe 26) | Saves RAM + storage; Apple enables it by default after 15.3 | Low (feature loss only) |
| Disable analytics/telemetry/Spotlight | mds_stores leaks memory on Sequoia (Apple Community threads); Spotlight CPU/mem spikes (Reddit, Setapp, Avid) | Low |
| Reduce transparency + motion (Liquid Glass on Tahoe 26) | Cuts WindowServer GPU/mem load; reduceTransparency is the official lever for Liquid Glass (osxdaily, Mac-Forums) | Low |
| Disable WindowServer-unrelated daemons (duetexpertd, chronod, knowledge-agent, etc.) | duetexpertd high CPU is a known complaint (Reddit) | Low–med |
| Raise per-process FD limit (`launchctl limit maxfiles`) | Fixes "too many open files" (Pro Tools 9022); on modern macOS kern.maxfiles is already ~300k so sysctl is moot | Low |
| `debug.lowpri_throttle_enabled=0` | Removes low-priority CPU throttle on background tasks (Apple discussions /etc/sysctl.conf thread) | Med (heat) |
| pmset: powernap, proximitywake, tcpkeepalive, womp, autopoweroff = 0 | Stops wake-ups, background network, WoL | Low–med |
| `hibernatemode 0` + delete sleepimage | Saves RAM-sized SSD space + write wear | Med (loses battery-drain fallback) |
| Network buffers (win_scale_factor=8, autobuf 32 MB, ESnet) | Wired 1Gbps+ throughput | Med (degrades Wi-Fi; ESnet warning) |
| Disable FileVault | **~zero** speed gain on Apple Silicon (hardware-accelerated); security loss; boot-loop history (12.3 multi-volume bug) | High — keep ON |

## 2. Kernel / sysctl details (macOS 12-26)

- `/etc/sysctl.conf` is **not reliably loaded** on modern macOS (SIP). The
  reliable persistence is a LaunchDaemon plist in `/Library/LaunchDaemons`
  that re-applies `sysctl -w` at boot (RunAtLoad). ESnet says the same for
  network tuning on Ventura+.
- `kern.maxfiles` default on recent macOS ≈ 300,000; raising it is pointless.
  The real FD fix is per-process: `sudo launchctl limit maxfiles 65536 131072`.
- `debug.lowpri_throttle_enabled` exists on macOS 12-15 (and 26); set 0 to
  reduce background throttling. Reversible, boot-safe.
- `net.inet.tcp.win_scale_factor` (default 3) → 8, `autorcvbufmax` /
  `autosndbufmax` 4 MB → 32 MB. Wired-only per ESnet.
- Never: `vm.*`, `machdep.*`, `hw.*` writes.

## 3. FileVault decision (research-backed)

- Apple Silicon: encryption is hardware-accelerated in the SSD controller.
  AllosInsight, Reddit r/macbookpro, Avid DUC: "essentially free",
  "no meaningful speed boost". **Recommendation: keep ON.**
- Intel SSD: small impact; Intel HDD (older iMac/MBP): real I/O cost.
- Boot-loop history: Apple warned of a FileVault boot-loop bug on 12.3
  multi-volume setups (iMore, AppleInsider, Jan 2022); user reports of
  bootloops after toggling FileVault off (Reddit r/mac 2025).
- Script: Mode 4 asks with this evidence, defaults to keeping FileVault on.

## 4. What the script now applies (per mode)

- **Mode 2 (Balanced)**: + `launchctl limit maxfiles 65536 131072`
- **Mode 3 (Aggressive)**: + `sysctl debug.lowpri_throttle_enabled=0`
- **Mode 4 (Dangerous, double-confirmed)**: + `kernel_confirm` flow:
  - Safe-sleep off (`hibernatemode 0` + remove sleepimage) — opt-in
  - FileVault decision — defaults to keep ON
  - ESnet network buffers — opt-in, wired-only warning
- Persistence: `sysctl_persist` writes
  `/Library/LaunchDaemons/com.macos-debloater.sysctl.plist` (RunAtLoad) with
  the applied sysctls; restore removes it and restores old values.

## 5. Sources (primary)

- ESnet — Mac OSX tuning: https://fasterdata.es.net/host-tuning/osx/
- ELC — Can you slim macOS down?: https://eclecticlight.co/2026/01/21/can-you-slim-macos-down/
- Renoise — macOS 12-15 daemon minimization: https://forum.renoise.com/t/macos-12-13-14-15-system-daemon-minimization/68972
- Leo-YiLuan — Disable Swap memory macOS 14: https://github.com/Leo-YiLuan/Disable-Swap-Memory-macOS14
- Apple SE — sysctl at startup Sequoia: https://apple.stackexchange.com/questions/480411
- Apple SE — kern.maxfiles doesn't stick: https://apple.stackexchange.com/questions/168495
- iMore — Apple warns 12.3 FileVault boot loop: https://www.imore.com/apple-warns-macos-catalina-users-boot-loop-bug-caused-macos-123-and-filevault
- Apple SE — FileVault SSD performance: https://apple.stackexchange.com/questions/105320
- AllosInsight — FileVault on M-series: https://allosinsight.com/does-filevault-slow-down-m-series-macs/
- Avid DUC — FileVault on M1-M3: https://duc.avid.com/forum/pro-tools-software/macos/403280
- Apple discussions — FileVault off bootloop: https://www.reddit.com/r/mac/comments/1jju0i2/
- hodorogandrei — macOS Sequoia optimisation (86 services): https://github.com/hodorogandrei/macos-sequoia-optimisation
- b0gdanw — Disable Sequoia Bloatware gist: https://gist.github.com/b0gdanw/b349f5f72097955cf18d6e7d8035c665
