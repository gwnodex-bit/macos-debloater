#!/bin/bash
# -*- mode: shell-script; -*-
#
# When invoked as `sh macos-debloater.sh` (or any POSIX sh), re-exec under
# real bash. The rest of this script uses bash-only syntax (arrays, [[ ]] and
# process substitution), which POSIX mode refuses to parse.
if [ -n "${POSIXLY_CORRECT:-}" ]; then
  unset POSIXLY_CORRECT
  exec /bin/bash "$0" "$@"
fi
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi
set -u
VERSION="1.3.0"
SCRIPT_NAME="macos-debloater"

# Root-only by design (enterprise / fleet): state is system-wide under
# /Library and every user account is covered. Re-exec under sudo when needed.
# $0 may be a relative path; sudo resolves command names against PATH, so
# canonicalize to an absolute path before re-execing.
if [[ "$(id -u)" != "0" ]]; then
  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  exec sudo "$SELF" "$@"
fi

# ============================================================================
# macOS debloater + optimizer (root-only, enterprise-ready)
#
# What it does
#   - Disables telemetry, cloud, Siri and other services by writing the
#     launchd XPC disabled DB (launchctl disable). Nothing under /System is
#     touched, no plist is deleted, so everything is reversible.
#   - Applies community optimization tweaks (defaults / pmset / sysctl /
#     mdutil), scaled by mode 1..4. Old values are recorded and can be
#     restored. No telemetry, no analytics, no network calls from this tool.
#
# Modes
#   1 Safe       telemetry, analytics, diagnostics, Siri/Apple-Intelligence
#                backends. Nothing user-facing is removed.
#   2 Balanced   Safe + iCloud extras, Maps, media extras, App Store, network
#                services. Some features lost.
#   3 Aggressive Balanced + Spotlight, Find My, Location, Messages, FaceTime,
#                Handoff/AirDrop/AirPlay, Screen Sharing, Time Machine, Photos,
#                Wallet, Screen Time, Family. Many features lost.
#   4 Dangerous  Aggressive + thermal daemon + App Store/Mail/Contacts/
#                reporting extras. Two warnings before applying.
#
# Requirements
#   - Root. The script auto-elevates via sudo; state is system-wide under
#     /Library and every user account is covered in one run.
#   - SIP must be disabled for real runs. Dry-run/list/restore work regardless.
#   - Interactive: everything is driven from the TUI menu.
#   - Enterprise/fleet: pre-seed /Library/Application Support/macos-debloater/
#     config with MODE=/AUTO_APPLY=1 and the script applies silently, no TUI.
#
# Boot-safety
#   - Hard deny list of boot/critical services (never disabled).
#   - Every label must resolve to a real plist on this macOS before it is
#     touched.
#   - Snapshot + per-run restore material is written before any change.
# ============================================================================

# ---- colors ---------------------------------------------------------------
NO_COLOR=${NO_COLOR:-0}
if [[ -t 1 && "$NO_COLOR" == "0" ]]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YLW=$'\033[33m'; C_BLU=$'\033[34m'; C_MAG=$'\033[35m'; C_CYN=$'\033[36m'
  C_RST=$'\033[0m'; C_BG=$'\033[7m'
else
  C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""
  C_MAG=""; C_CYN=""; C_RST=""; C_BG=""
fi

# ---- environment ----------------------------------------------------------
OS_NAME="$(sw_vers -productName 2>/dev/null)"
OS_VER_RAW="$(sw_vers -productVersion 2>/dev/null)"
OS_MAJOR="${OS_VER_RAW%%.*}"
OS_VER="${OS_NAME:-macOS} ${OS_VER_RAW:-unknown}"
[[ "$OS_MAJOR" == "12" ]] && OS_VER="macOS Monterey (12.x)"
[[ "$OS_MAJOR" == "13" ]] && OS_VER="macOS Ventura (13.x)"
[[ "$OS_MAJOR" == "14" ]] && OS_VER="macOS Sonoma (14.x)"
[[ "$OS_MAJOR" == "15" ]] && OS_VER="macOS Sequoia (15.x)"
[[ "$OS_MAJOR" == "26" ]] && OS_VER="macOS Tahoe (26.x)"
HW_NAME="$(sysctl -n hw.model 2>/dev/null)"
HW_ARCH="$(uname -m)"
CPU_BRAND="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
MEM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))

TS="$(date +%Y%m%d-%H%M%S)"
# System-wide state: one run covers every user account on the machine.
STATEDIR="/Library/Application Support/${SCRIPT_NAME}"
LOGFILE="/Library/Logs/${SCRIPT_NAME}.log"
BAKDIR="$STATEDIR/backups/$TS"
MANIFEST="$STATEDIR/manifest.txt"
CONFIG_FILE="$STATEDIR/config"

# Every real user account on this machine (uid >= 500). gui-domain services
# are disabled/enabled for each of them, not just one account.
all_user_uids() {
  dscl . -list /Users UniqueID 2>/dev/null | awk '$2 >= 500 && $2 < 100000 {print $2}' | sort -n
}
USER_UIDS=()
while IFS= read -r _u; do USER_UIDS+=("$_u"); done < <(all_user_uids)
USER_COUNT="${#USER_UIDS[@]}"

# ---- state (all driven by the TUI; no command-line flags) --------------------
DRY_RUN=0        # 0 = apply for real, 1 = preview only (TUI toggle)
ASK_THERMAL=0    # 0 = thermal daemon only in Mode 4, 1 = also Modes 1-3 (TUI toggle)
MODE=0           # selected mode 1..4; set when a mode is chosen in the TUI
MANUAL_LABELS="" # extra labels typed into the Custom menu item
AUTO_APPLY=0     # 1 = silent run from config file (enterprise fleet / MDM)
HIBERNATE_OFF=0  # 0 = keep safe-sleep/hibernation, 1 = hibernatemode 0 + drop sleepimage (Mode 4)
FILEVAULT_DISABLE=0 # 1 = Mode 4: disable FileVault (config-driven, enterprise only)
NETWORK_TUNING=0    # 1 = Mode 4: ESnet TCP buffers (config-driven, wired 1Gbps+ only)

# ---- enterprise config -------------------------------------------------------
# No command-line flags: IT pre-seeds $CONFIG_FILE and the script reads it.
# Format: one KEY=VALUE per line, # comments allowed.
#   MODE=2             mode to apply (1..4)
#   DRY_RUN=1          preview only
#   ASK_THERMAL=1      thermal daemon also in Modes 1-3
#   AUTO_APPLY=1       skip the TUI entirely and apply $MODE now (fleet runs)
#   HIBERNATE_OFF=1    Mode 4: disable safe sleep + drop sleepimage
#   FILEVAULT_DISABLE=1  Mode 4: turn FileVault off (security loss; default keep)
#   NETWORK_TUNING=1   Mode 4: ESnet TCP buffers (wired 1Gbps+ only)
#   MANUAL_LABELS=...  extra service labels (comma separated)
load_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    k="${k// /}"; [[ -z "$k" || "$k" == \#* ]] && continue
    v="${v%\r}"
    case "$k" in
      MODE)             [[ "$v" =~ ^[1-4]$ ]] && MODE="$v" ;;
      DRY_RUN)          [[ "$v" == "1" ]] && DRY_RUN=1 || DRY_RUN=0 ;;
      ASK_THERMAL)      [[ "$v" == "1" ]] && ASK_THERMAL=1 || ASK_THERMAL=0 ;;
      AUTO_APPLY)       [[ "$v" == "1" ]] && AUTO_APPLY=1 || AUTO_APPLY=0 ;;
      HIBERNATE_OFF)    [[ "$v" == "1" ]] && HIBERNATE_OFF=1 || HIBERNATE_OFF=0 ;;
      FILEVAULT_DISABLE) [[ "$v" == "1" ]] && FILEVAULT_DISABLE=1 || FILEVAULT_DISABLE=0 ;;
      NETWORK_TUNING)   [[ "$v" == "1" ]] && NETWORK_TUNING=1 || NETWORK_TUNING=0 ;;
      MANUAL_LABELS)    MANUAL_LABELS="$v" ;;
    esac
  done < "$CONFIG_FILE"
}

config_summary() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  echo "${C_DIM}  Config  ${CONFIG_FILE}${C_RST}"
  echo "  Mode     $MODE   Dry-run $DRY_RUN   Thermal $ASK_THERMAL   Auto $AUTO_APPLY"
}

# ---- OS support + SIP ------------------------------------------------------
check_os_supported() {
  case "$OS_MAJOR" in
    12|13|14|15|26) return 0 ;;
    *)
      echo "${C_RED}Unsupported macOS: ${OS_VER_RAW:-unknown}.${C_RST}"
      echo "This script supports macOS 12 (Monterey), 13 (Ventura), 14 (Sonoma),"
      echo "15 (Sequoia) and 26 (Tahoe). Refusing to run."
      exit 2
      ;;
  esac
}

sip_state() {
  local s
  s="$(csrutil status 2>/dev/null || echo unknown)"
  case "$s" in
    *enabled*)  echo "enabled" ;;
    *disabled*) echo "disabled" ;;
    *)          echo "unknown" ;;
  esac
}
SIP_STATE="$(sip_state)"

sip_help_text() {
  echo ""
  echo "${C_RED}${C_BOLD}SIP is ${SIP_STATE}.${C_RST} Real runs need SIP disabled."
  echo ""
  echo "How to disable SIP on this Mac:"
  echo "  1. Shut the Mac down."
  echo "  2. Boot into Recovery:"
  echo "     Apple Silicon: hold the power button at startup, then Options -> Continue."
  echo "     Intel: hold Cmd+R at startup."
  echo "  3. In Recovery, open Terminal (Utilities menu) and run:"
  echo "         csrutil disable"
  echo "  4. Reboot:"
  echo "         reboot"
  echo ""
  echo "Video walkthrough:"
  echo "  https://www.youtube.com/results?search_query=how+to+disable+sip+csrutil+disable+apple+silicon+macbook"
  echo ""
  echo "You can still preview from the menu with Dry-run ON, or read the catalog."
}

sip_block() {
  sip_help_text
  exit 1
}

# ---- sudo ------------------------------------------------------------------
# Always root (auto-elevated at the top of this file), so no sudo prefix needed.
SUDO=""

mkdir -p "$STATEDIR/backups" "$BAKDIR" "$(dirname "$LOGFILE")" 2>/dev/null

log()  { echo -e "$*"; printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(echo "$*" | sed 's/\x1b\[[0-9;]*m//g')" >> "$LOGFILE"; }
ok()   { log "  [OK]   $*"; }
warn() { log "  [WARN] $*"; }
err()  { log "  [ERR]  $*"; }
info() { log "  [INFO] $*"; }

# ---- deny list -------------------------------------------------------------
DENYLIST='com.apple.WindowServer
com.apple.loginwindow
com.apple.logind
com.apple.notifyd
com.apple.configd
com.apple.mDNSResponder
com.apple.mDNSResponderHelper
com.apple.opendirectoryd
com.apple.securityd
com.apple.coreauthd
com.apple.diskarbitrationd
com.apple.fseventsd
com.apple.syslogd
com.apple.coreservicesd
com.apple.cfprefsd
com.apple.distnoted
com.apple.runningboardd
com.apple.powerd
com.apple.UserEventAgent
com.apple.tccd
com.apple.sandboxd
com.apple.bluetoothd
com.apple.audio.coreaudiod
com.apple.SystemUIServer'

is_denied() { printf '%s\n' "$DENYLIST" | grep -Fqx "$1"; }

# ---- catalog ----------------------------------------------------------------
# label|hint|tier|group|since|description
#   hint: system | gui | auto (auto = resolve by plist presence)
#   tier: 1 safe, 2 feature-removing, 3 thermal, 4 dangerous-extra
#   since: minimum macOS major (0 = any)
CATALOG=$(cat <<'EOF'

com.apple.analyticsd|system|1|analytics|0|System telemetry and analytics reporter
com.apple.audioanalyticsd|system|1|analytics|0|Audio analytics telemetry
com.apple.ecosystemanalyticsd|system|1|analytics|0|Ecosystem analytics telemetry
com.apple.wifianalyticsd|system|1|analytics|0|Wi-Fi analytics telemetry
com.apple.usbctelemetryd|system|1|analytics|0|USB-C accessory telemetry
com.apple.applessdstatistics|system|1|analytics|0|App Store feature statistics
com.apple.osanalytics.osanalyticshelper|system|1|analytics|0|OS analytics helper
com.apple.systemstats.analysis|system|1|analytics|0|System statistics analysis
com.apple.systemstats.daily|system|1|analytics|0|Daily system statistics
com.apple.systemstats.microstackshot_periodic|system|1|analytics|0|Periodic micro-stackshots
com.apple.triald.system|system|1|analytics|0|Siri/OS experiment trials (system)
com.apple.biomed|system|1|analytics|0|Biome research data collection
com.apple.coreduetd|system|1|analytics|0|Duet activity/context engine
com.apple.awdd|system|1|analytics|0|Apple Wireless Direct diagnostics
com.apple.contextstored|system|1|analytics|0|Context store (system)
com.apple.GameController.gamecontrollerd|system|2|misc|0|Game controller daemon
com.apple.dhcp6d|system|2|network|0|DHCPv6 server (disable only if unused)
com.apple.ftp-proxy|system|2|network|0|FTP proxy helper
com.apple.netbiosd|system|2|network|0|NetBIOS name service
com.apple.smbd|system|2|network|0|SMB file sharing
com.apple.smb.preferences|system|2|network|0|SMB preferences
com.apple.msrpc.mdssvc|system|2|network|0|Legacy SMB/Spotlight network service
com.apple.screensharing|system|2|screen|0|Remote screen sharing (system)
com.apple.backupd|system|2|misc|0|Time Machine backup daemon
com.apple.backupd-helper|system|2|misc|0|Time Machine helper
com.apple.familycontrols|system|2|family|0|Parental controls (system)
com.apple.findmymac|system|2|findmy|0|Find My Mac
com.apple.findmymacmessenger|system|2|findmy|0|Find My Mac messenger
com.apple.findmy.findmybeaconingd|system|2|findmy|0|Find My off-network beaconing
com.apple.icloud.findmydeviced|system|2|findmy|0|Find My device daemon
com.apple.icloud.searchpartyd|system|2|findmy|0|Crowd-sourced Find My network
com.apple.locationd|system|2|location|0|CoreLocation daemon
com.apple.ManagedClient.cloudconfigurationd|system|2|misc|0|MDM cloud configuration (managed Macs only)
com.apple.modelmanagerd|system|2|ai|0|Machine-learning model download manager
com.apple.rapportd|system|2|sharing|0|AirDrop/Handoff/Continuity (system)
com.apple.AirPlayXPCHelper|system|2|sharing|0|AirPlay XPC helper
com.apple.airportd|system|2|network|0|AirPort/Wi-Fi monitoring (ethernet-only machines)
com.apple.metadata.mds|system|2|spot|0|Spotlight metadata server
com.apple.metadata.mds.index|system|2|spot|0|Spotlight indexer
com.apple.metadata.mds.scan|system|2|spot|0|Spotlight scanner
com.apple.metadata.mds.spindump|system|2|spot|0|Spotlight spindump worker
com.apple.installd|system|2|store|0|Installer daemon (CAUTION: disables app installs)
com.apple.thermalmonitord|system|3|thermal|0|Apple Silicon thermal policy daemon - EXTREME
com.apple.thermald|system|3|thermal|0|Intel thermal policy daemon - EXTREME
com.apple.CrashReporterSupportHelper|system|4|extra|0|Crash reporter helper
com.apple.ReportCrash.Root|system|4|extra|0|Root crash reporting
com.apple.ReportSystemMemory|system|4|extra|0|Memory diagnostics report
com.apple.ReportMemoryException|system|4|extra|0|Memory exception report
com.apple.bosreporter|system|4|extra|0|BridgeOS device reporting
com.apple.gkreport|system|4|extra|0|GameKit reporting
com.apple.logd_reporter|system|4|extra|0|Log reporting helper (not logd itself)
com.apple.rtcreportingd|system|4|extra|0|WebRTC/real-time reporting
com.apple.signpost.signpost_reporter|system|4|extra|0|Signpost instrumentation reporter
com.apple.csrutil.report|system|4|extra|0|SIP status reporter (not csrutil itself)
com.apple.appstored|system|4|extra|0|App Store system daemon (stops App Store installs/updates)
com.apple.NetworkSharing|system|4|extra|0|Internet sharing service
com.apple.unmountassistant.sysagent|system|4|extra|0|Disk unmount assistant (system)
com.apple.spindump|system|4|extra|0|Hang/spin dump service
com.apple.tailspind|system|4|extra|0|Tailspin logging service
com.apple.accessibility.MotionTrackingAgent|gui|2|access|0|Head/eye motion tracking
com.apple.accessibility.axassetsd|gui|2|access|0|Accessibility assets cache
com.apple.ap.adprivacyd|gui|1|analytics|0|Ad privacy daemon
com.apple.ap.promotedcontentd|gui|1|analytics|0|Promoted content / ads
com.apple.assistant_service|gui|1|siri|0|Siri assistant service
com.apple.assistantd|gui|1|siri|0|Siri assistant daemon
com.apple.assistant_cdmd|gui|1|siri|0|Siri command daemon
com.apple.avconferenced|gui|2|media|0|FaceTime/camera conference daemon
com.apple.BiomeAgent|gui|1|analytics|0|Biome data agent
com.apple.biomesyncd|gui|1|cloud|0|Biome cross-device sync
com.apple.calaccessd|gui|2|cloud|0|Calendar access daemon
com.apple.CallHistoryPluginHelper|gui|2|messaging|0|Call history plugin
com.apple.chronod|gui|1|misc|0|Background scheduler
com.apple.CloudSettingsSyncAgent|gui|2|cloud|0|iCloud settings sync
com.apple.CommCenter-osx|gui|2|messaging|0|Cellular services on Mac
com.apple.ContextStoreAgent|gui|1|analytics|0|Context store agent
com.apple.CoreLocationAgent|gui|2|location|0|Location UI agent
com.apple.corespeechd|gui|1|siri|0|Speech recognition backend
com.apple.dataaccess.dataaccessd|gui|2|cloud|0|Exchange / accounts sync
com.apple.duetexpertd|gui|1|analytics|0|Duet experiment daemon
com.apple.familycircled|gui|2|family|0|Family sharing daemon
com.apple.familycontrols.useragent|gui|2|family|0|Parental controls (user)
com.apple.familynotificationd|gui|2|family|0|Family notifications
com.apple.financed|gui|2|store|0|Apple Pay / finance
com.apple.findmy.findmylocateagent|gui|2|findmy|0|Find My locator agent
com.apple.followupd|gui|2|misc|0|Follow-up / reminders engine
com.apple.gamed|gui|1|misc|0|Game Center
com.apple.generativeexperiencesd|gui|1|ai|0|Generative AI experiences
com.apple.geoanalyticsd|gui|1|analytics|0|Location / geo analytics
com.apple.geodMachServiceBridge|gui|2|location|0|GeoServices Mach bridge
com.apple.helpd|gui|1|misc|0|Help viewer daemon
com.apple.homed|gui|2|misc|0|HomeKit daemon
com.apple.iCloudNotificationAgent|gui|2|cloud|0|iCloud notifications
com.apple.icloudmailagent|gui|2|cloud|0|iCloud Mail agent
com.apple.iCloudUserNotifications|gui|2|cloud|0|iCloud user notifications
com.apple.icloud.searchpartyuseragent|gui|2|findmy|0|Find My network user agent
com.apple.imagent|gui|2|messaging|0|Messages (iMessage)
com.apple.imautomatichistorydeletionagent|gui|2|messaging|0|Messages auto-delete agent
com.apple.imtransferagent|gui|2|messaging|0|Messages transfer agent
com.apple.inputanalyticsd|gui|1|analytics|0|Input analytics
com.apple.intelligenceflowd|gui|1|ai|0|Apple Intelligence flow runtime
com.apple.intelligencecontextd|gui|1|ai|0|Apple Intelligence context runtime
com.apple.intelligenceplatformd|gui|1|ai|0|Apple Intelligence platform daemon
com.apple.intelligenceplatform|gui|1|ai|0|Apple Intelligence platform
com.apple.intelligentroutingd|gui|1|ai|0|Apple Intelligence routing
com.apple.knowledge-agent|gui|1|ai|0|Knowledge / suggestion agent
com.apple.knowledgeconstructiond|gui|1|ai|0|Knowledge graph construction
com.apple.mlruntimed|gui|1|ai|0|Machine learning runtime
com.apple.spotlightknowledged|gui|1|ai|0|Spotlight knowledge daemon
com.apple.spotlightknowledged.importer|gui|1|ai|0|Spotlight knowledge importer
com.apple.spotlightknowledged.updater|gui|1|ai|0|Spotlight knowledge updater
com.apple.naturallanguaged|gui|1|ai|0|Natural language framework daemon
com.apple.itunescloudd|gui|2|cloud|0|Apple Music / iTunes sync
com.apple.Maps.pushdaemon|gui|2|maps|0|Maps push notifications
com.apple.Maps.mapssyncd|gui|2|maps|0|Maps sync
com.apple.maps.destinationd|gui|2|maps|0|Maps destination daemon
com.apple.mediaanalysisd|gui|1|media|0|Photo / media analysis
com.apple.mediastream.mstreamd|gui|2|cloud|0|Shared photo stream
com.apple.navd|gui|2|location|0|Navigation daemon
com.apple.newsd|gui|1|misc|0|News app daemon
com.apple.parsec-fbf|gui|1|siri|0|Parsec feedback
com.apple.parsecd|gui|1|siri|0|Parsec / Siri suggestion cache
com.apple.passd|gui|2|store|0|Wallet / Apple Pay daemon
com.apple.photoanalysisd|gui|1|media|0|Photos analysis / indexing
com.apple.photolibraryd|gui|2|media|0|Photos library daemon
com.apple.progressd|gui|2|misc|0|Progress reporting daemon
com.apple.protectedcloudstorage.protectedcloudkeysyncing|gui|2|cloud|0|Advanced Data Protection key sync
com.apple.quicklook|gui|2|spot|0|Quick Look service
com.apple.quicklook.ui.helper|gui|2|spot|0|Quick Look UI helper
com.apple.quicklook.ThumbnailsAgent|gui|2|spot|0|Quick Look thumbnail generation
com.apple.rapportd-user|gui|2|sharing|0|AirDrop / Handoff / Continuity (user)
com.apple.remindd|gui|2|misc|0|Reminders daemon
com.apple.replicatord|gui|2|sharing|0|Continuity replicator
com.apple.routined|gui|2|location|0|Routine / location learning
com.apple.screensharing.agent|gui|2|screen|0|Screen sharing agent
com.apple.screensharing.menuextra|gui|2|screen|0|Screen sharing menu extra
com.apple.screensharing.MessagesAgent|gui|2|screen|0|Screen sharing Messages agent
com.apple.ScreenTimeAgent|gui|2|family|0|Screen Time tracking
com.apple.SSInvitationAgent|gui|2|misc|0|Invitation agent
com.apple.security.cloudkeychainproxy3|gui|2|cloud|0|iCloud Keychain proxy
com.apple.sharingd|gui|2|sharing|0|Handoff / universal clipboard
com.apple.sidecar-hid-relay|gui|2|sharing|0|Sidecar HID relay
com.apple.sidecar-relay|gui|2|sharing|0|Sidecar relay
com.apple.siriactionsd|gui|1|siri|0|Siri Actions daemon
com.apple.Siri.agent|gui|1|siri|0|Siri agent
com.apple.siriinferenced|gui|1|siri|0|Siri on-device inference
com.apple.sirittsd|gui|1|siri|0|Siri TextToSpeech
com.apple.SiriTTSTrainingAgent|gui|1|siri|0|Siri TTS training
com.apple.siriknowledged|gui|1|siri|0|Siri knowledge daemon
com.apple.suggestd|gui|1|siri|0|Suggestion engine
com.apple.tipsd|gui|1|misc|0|Tips / onboarding
com.apple.triald|gui|1|analytics|0|OS experiment trials (user)
com.apple.telephonyutilities.callservicesd|gui|2|messaging|0|FaceTime call services
com.apple.TMHelperAgent|gui|2|misc|0|Time Machine helper agent
com.apple.universalaccessd|gui|2|access|0|Universal access daemon
com.apple.UsageTrackingAgent|gui|2|family|0|App usage tracking
com.apple.videosubscriptionsd|gui|2|store|0|TV app subscriptions
com.apple.voicebankingd|gui|1|siri|0|Personal voice banking
com.apple.watchlistd|gui|2|store|0|Watch list daemon
com.apple.weatherd|gui|1|misc|0|Weather daemon
com.apple.analyticsagent|gui|1|analytics|0|Analytics agent
com.apple.appleseed.seedusaged|gui|1|analytics|0|AppleSeed usage reporter
com.apple.appleseed.seedusaged.postinstall|gui|1|analytics|0|AppleSeed postinstall reporter
com.apple.diagnostics_agent|gui|1|analytics|0|Diagnostics agent
com.apple.diagnosticspushd|gui|1|analytics|0|Diagnostics push daemon
com.apple.diagnosticextensionsd|gui|1|analytics|0|Diagnostics extensions
com.apple.feedbackd|gui|1|analytics|0|Feedback assistant
com.apple.corespotlightd|gui|2|spot|0|Spotlight index daemon
com.apple.corespotlightservice|gui|2|spot|0|Spotlight service
com.apple.managedcorespotlightd|gui|2|spot|0|Managed Spotlight
com.apple.Spotlight|gui|2|spot|0|Spotlight UI agent
com.apple.spotlightimporter|gui|2|spot|0|Spotlight importer
com.apple.appstoreagent|gui|4|extra|0|App Store agent
com.apple.appstorecomponentsd|gui|4|extra|0|App Store components
com.apple.storeaccountd|gui|4|extra|0|App Store account service
com.apple.storeassetd|gui|4|extra|0|App Store asset service
com.apple.storedownloadd|gui|4|extra|0|App Store download service
com.apple.storekitagent|gui|4|extra|0|StoreKit agent
com.apple.storelegacy|gui|4|extra|0|Legacy store service
com.apple.storeuid|gui|4|extra|0|App Store UI service
com.apple.bookdatastored|gui|4|extra|0|Books/Apple Books data store
com.apple.commerce|gui|4|extra|0|Commerce engine
com.apple.cloudphotod|gui|4|extra|0|iCloud Photos library sync
com.apple.amp.mediasharingd|gui|4|extra|0|Media sharing (Home Sharing / AirPlay to Mac)
com.apple.keychainsharingmessagingd|gui|4|extra|0|Keychain sharing messaging
com.apple.email.maild|gui|4|extra|0|Mail daemon (disables Mail fetch/push)
com.apple.mdworker.mail|gui|4|extra|0|Mail indexing worker
com.apple.AddressBook.SourceSync|gui|4|extra|0|Contacts source sync
com.apple.AddressBook.AssistantService|gui|4|extra|0|Contacts assistant service
com.apple.CallHistorySyncHelper|gui|4|extra|0|Call history sync helper
com.apple.cmfsyncagent|gui|4|extra|0|Messages/FaceTime sync agent
com.apple.privatecloudcomputed|gui|4|extra|0|Apple Private Cloud Compute agent
com.apple.locationaccessstored|gui|4|extra|0|Location access store
com.apple.DiagnosticsReporter|gui|4|extra|0|Diagnostics reporter
com.apple.ReportCrash|gui|4|extra|0|Crash reporter (user)
com.apple.ReportGPURestart|gui|4|extra|0|GPU restart reporting
com.apple.pluginkit.pkreporter|gui|4|extra|0|PluginKit reporter
com.apple.spindump_agent|gui|4|extra|0|Spin dump agent
com.apple.screencaptureui|gui|4|extra|0|Screenshot on-screen UI
com.apple.accessibility.LiveTranscriptionAgent|gui|4|extra|0|Live transcription feature
com.apple.unmountassistant.useragent|gui|4|extra|0|Disk unmount assistant (user)
com.apple.AssetCacheLocatorService|gui|4|extra|0|Content caching locator

EOF
)

RESOLVED_TMP="$(mktemp /tmp/${SCRIPT_NAME}.XXXXXX)" || RESOLVED_TMP="/tmp/${SCRIPT_NAME}.resolved"
SELECTED_TMP="$(mktemp /tmp/${SCRIPT_NAME}.XXXXXX)" || SELECTED_TMP="/tmp/${SCRIPT_NAME}.selected"
: > "$RESOLVED_TMP"

get_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

resolve_domain() {
  local label="$1"
  [[ -f "/System/Library/LaunchDaemons/$label.plist" || -f "/Library/LaunchDaemons/$label.plist" ]] && { echo "system"; return; }
  [[ -f "/System/Library/LaunchAgents/$label.plist"  || -f "/Library/LaunchAgents/$label.plist" ]] && { echo "gui"; return; }
  echo "auto"
}

build_resolved() {
  local line label hint tier group since desc domain
  : > "$RESOLVED_TMP"
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    label="$(get_field "$line" 1)"; hint="$(get_field "$line" 2)"
    tier="$(get_field "$line" 3)";  group="$(get_field "$line" 4)"
    since="$(get_field "$line" 5)"; desc="$(get_field "$line" 6)"
    if [[ "$since" =~ ^[0-9]+$ && "$since" -gt "$OS_MAJOR" ]]; then continue; fi
    domain="$(resolve_domain "$label" "$hint")"
    [[ "$domain" == "auto" ]] && continue
    printf '%s|%s|%s|%s|%s\n' "$domain" "$label" "$tier" "$group" "$desc" >> "$RESOLVED_TMP"
  done <<< "$CATALOG"
}

# ---- service actions -------------------------------------------------------
disable_service() {
  local domain="$1" label="$2" rc=0 uid
  if [[ "$DRY_RUN" == "1" ]]; then
    if [[ "$domain" == "system" ]]; then
      echo "  DRY: $SUDO launchctl bootout system/$label"
      echo "  DRY: $SUDO launchctl disable system/$label"
    else
      for uid in "${USER_UIDS[@]}"; do
        echo "  DRY: launchctl bootout gui/$uid/$label"
        echo "  DRY: launchctl disable gui/$uid/$label"
      done
    fi
    return 0
  fi
  if [[ "$domain" == "system" ]]; then
    $SUDO launchctl bootout "system/$label" 2>/dev/null
    $SUDO launchctl disable "system/$label" 2>/dev/null || rc=1
  else
    for uid in "${USER_UIDS[@]}"; do
      launchctl bootout "gui/$uid/$label" 2>/dev/null
      launchctl disable "gui/$uid/$label" 2>/dev/null || rc=1
    done
  fi
  return $rc
}

enable_service() {
  local domain="$1" label="$2" base uid
  if [[ "$DRY_RUN" == "1" ]]; then
    if [[ "$domain" == "system" ]]; then echo "  DRY: $SUDO launchctl enable system/$label"
    else
      for uid in "${USER_UIDS[@]}"; do echo "  DRY: launchctl enable gui/$uid/$label"; done
    fi
    return 0
  fi
  if [[ "$domain" == "gui" ]]; then
    for uid in "${USER_UIDS[@]}"; do
      launchctl enable "gui/$uid/$label" 2>/dev/null
      for base in "/System/Library/LaunchAgents" "/Library/LaunchAgents"; do
        [[ -f "$base/$label.plist" ]] && { launchctl bootstrap "gui/$uid" "$base/$label.plist" 2>/dev/null; break; }
      done
    done
  else
    $SUDO launchctl enable "system/$label" 2>/dev/null
    for base in "/System/Library/LaunchDaemons" "/Library/LaunchDaemons"; do
      [[ -f "$base/$label.plist" ]] && { $SUDO launchctl bootstrap system "$base/$label.plist" 2>/dev/null; break; }
    done
  fi
  return 0
}

take_snapshot() {
  local uid
  log "${C_BOLD}Snapshotting the launchd disabled DB.${C_RST}"
  {
    echo "### system print-disabled"
    launchctl print-disabled system 2>/dev/null
    for uid in "${USER_UIDS[@]}"; do
      echo
      echo "### gui/$uid print-disabled"
      launchctl print-disabled "gui/$uid" 2>/dev/null
    done
  } > "$BAKDIR/disabled-print.txt" 2>/dev/null
  cp -p "/private/var/db/com.apple.xpc.launchd/disabled.plist" "$BAKDIR/disabled.plist.bak" 2>/dev/null || true
  for uid in "${USER_UIDS[@]}"; do
    cp -p "/private/var/db/com.apple.xpc.launchd/disabled.${uid}.plist" "$BAKDIR/disabled.${uid}.plist.bak" 2>/dev/null || true
  done
  ok "snapshot -> $BAKDIR"
}

# ---- selection -------------------------------------------------------------
pick_line() { printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$SELECTED_TMP"; }
count_picked() { sort -u "$SELECTED_TMP" | grep -c '|' || true; }

tier_tag() {
  case "$1" in
    1) printf 'safe' ;;
    2) printf 'aggr' ;;
    3) printf 'THERM' ;;
    4) printf 'DANGR' ;;
    *) printf '%s' "$1" ;;
  esac
}

tier_color() {
  case "$1" in
    1) printf '%s' "$C_GRN" ;;
    2) printf '%s' "$C_YLW" ;;
    3|4) printf '%s' "$C_RED" ;;
    *) printf '%s' "$C_DIM" ;;
  esac
}

show_plan() {
  local domain label tier group desc
  log ""
  log "${C_BOLD}Plan — $(count_picked) service(s) to disable:${C_RST}"
  while IFS='|' read -r domain label tier group desc; do
    [[ -z "$label" ]] && continue
    printf "   ${C_CYN}%-6s${C_RST} $(tier_color "$tier")%-5s${C_RST} %-56s ${C_DIM}%s${C_RST}\n" "$domain" "$(tier_tag "$tier")" "$label" "$desc"
  done < <(sort -u -t'|' -k3,3n -k4,4 -k1,1 -k2,2 "$SELECTED_TMP")
}

fill_tier() {
  local t="$1" domain label tier group desc
  while IFS='|' read -r domain label tier group desc; do
    [[ -z "$label" ]] && continue
    is_denied "$label" && continue
    [[ "$tier" == "$t" ]] && pick_line "$domain" "$label" "$tier" "$group" "$desc"
  done < "$RESOLVED_TMP"
}

push_group() {
  local g="$1" domain label tier group desc
  while IFS='|' read -r domain label tier group desc; do
    [[ -z "$label" ]] && continue
    is_denied "$label" && continue
    [[ "$tier" == "2" && "$group" == "$g" ]] && pick_line "$domain" "$label" "$tier" "$group" "$desc"
  done < "$RESOLVED_TMP"
}

thermal_arch_select() {
  local domain label tier group desc
  while IFS='|' read -r domain label tier group desc; do
    [[ "$tier" != "3" ]] && continue
    if [[ "$HW_ARCH" == "arm64" ]]; then
      [[ "$label" == "com.apple.thermalmonitord" ]] && pick_line "$domain" "$label" "$tier" "$group" "$desc"
    else
      [[ "$label" == "com.apple.thermald" ]] && pick_line "$domain" "$label" "$tier" "$group" "$desc"
    fi
  done < "$RESOLVED_TMP"
}

fill_balanced() {
  local g
  fill_tier 1
  for g in cloud maps media store network access misc; do push_group "$g"; done
}

select_by_mode() {
  case "$MODE" in
    1) fill_tier 1 ;;
    2) fill_balanced ;;
    3) fill_tier 1; fill_tier 2 ;;
    4) fill_tier 1; fill_tier 2; fill_tier 4; thermal_arch_select ;;
  esac
}

select_label() {
  local label="$1" line hit="" domain hint tier group desc
  if is_denied "$label"; then err "refusing $label: boot/critical (deny list)."; return 1; fi
  hit=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$(get_field "$line" 1)" == "$label" ]] && { hit="$line"; break; }
  done <<< "$CATALOG"
  domain="$(resolve_domain "$label" "$2")"
  if [[ "$domain" != "system" && "$domain" != "gui" ]]; then
    warn "skipping $label: no matching plist on this macOS."
    return 1
  fi
  if [[ -n "$hit" ]]; then
    tier="$(get_field "$hit" 3)"; group="$(get_field "$hit" 4)"; desc="$(get_field "$hit" 6)"
  else
    tier="2"; group="manual"; desc="(manual label)"
  fi
  pick_line "$domain" "$label" "$tier" "$group" "$desc"
  return 0
}

apply_selection() {
  local domain label tier group desc rc=0
  if [[ "$DRY_RUN" != "1" ]]; then : > "$MANIFEST"; fi
  while IFS='|' read -r domain label tier group desc; do
    [[ -z "$label" ]] && continue
    printf "  %-6s %-56s " "$domain" "$label"
    if disable_service "$domain" "$label"; then
      echo "${C_GRN}disabled${C_RST}"
      if [[ "$DRY_RUN" != "1" ]]; then printf '%s|%s\n' "$domain" "$label" >> "$MANIFEST"; fi
    else
      echo "${C_RED}failed${C_RST}"
    fi
  done < <(sort -u -t'|' -k3,3n -k4,4 -k1,1 -k2,2 "$SELECTED_TMP")
}

# ---- restore ----------------------------------------------------------------
restore_from_manifest() {
  local domain label
  [[ -f "$MANIFEST" ]] && [[ -s "$MANIFEST" ]] || { warn "no manifest at $MANIFEST; nothing to restore."; return 1; }
  while IFS='|' read -r domain label; do
    [[ -z "$label" ]] && continue
    printf "  %-6s %-56s " "$domain" "$label"
    if [[ "$DRY_RUN" == "1" ]]; then echo "re-enable (dry)"; continue; fi
    if enable_service "$domain" "$label"; then echo "${C_GRN}re-enabled${C_RST}"; else echo "${C_RED}failed${C_RST}"; fi
  done < <(sort -u "$MANIFEST")
}

restore_all_catalog() {
  local domain label tier group desc
  while IFS='|' read -r domain label tier group desc; do
    [[ -z "$label" ]] && continue
    is_denied "$label" && continue
    printf "  %-6s %-56s " "$domain" "$label"
    if [[ "$DRY_RUN" == "1" ]]; then echo "re-enable (dry)"; continue; fi
    enable_service "$domain" "$label" && echo "${C_GRN}re-enabled${C_RST}" || echo "${C_RED}failed${C_RST}"
  done < <(sort -u -t'|' -k1,1 -k2,2 "$RESOLVED_TMP")
}

write_restore_script() {
  local r="$STATEDIR/restore.sh" uid
  cat > "$r" <<'RSCRIPT'
#!/bin/bash
# Generated by macos-debloater. Re-enables the services in the last manifest.
# Must be run as root (auto-elevates).
set -u
if [[ "$(id -u)" != "0" ]]; then
  exec sudo "$0" "$@"
fi
MANIFEST="__STATEDIR__/manifest.txt"
if [[ ! -s "$MANIFEST" ]]; then echo "manifest empty or missing: $MANIFEST"; exit 1; fi
USER_UIDS=( $(dscl . -list /Users UniqueID 2>/dev/null | awk '$2 >= 500 && $2 < 100000 {print $2}' | sort -n) )
while IFS='|' read -r domain label; do
  [[ -z "$label" ]] && continue
  echo "  $domain/$label"
  if [[ "$domain" == "system" ]]; then
    launchctl enable "system/$label" 2>/dev/null
    for base in /System/Library/LaunchDaemons /Library/LaunchDaemons; do
      [[ -f "$base/$label.plist" ]] && { launchctl bootstrap system "$base/$label.plist" 2>/dev/null; break; }
    done
  else
    for uid in "${USER_UIDS[@]}"; do
      launchctl enable "gui/$uid/$label" 2>/dev/null
      for base in /System/Library/LaunchAgents /Library/LaunchAgents; do
        [[ -f "$base/$label.plist" ]] && { launchctl bootstrap "gui/$uid" "$base/$label.plist" 2>/dev/null; break; }
      done
    done
  fi
done < "$MANIFEST"
echo "Done. Reboot for full effect."
RSCRIPT
  chmod +x "$r"
  /usr/bin/sed -i '' "s#__STATEDIR__#$STATEDIR#" "$r" 2>/dev/null || true
  ok "restore script: $r"
}

# ---- optimization tweaks ----------------------------------------------------
OPT_BACKUP="$BAKDIR/opts-backup.txt"

pmset_get() { # key src(b|c|u)
  pmset -g custom 2>/dev/null | awk -v key="$1" -v src="$2" '
    /^Battery Power:/ {sec="b"; next}
    /^AC Power:/      {sec="c"; next}
    /^UPS Power:/     {sec="u"; next}
    { if (sec==src && $1==key) { print $2; exit } }
  '
}

opt_defaults() { # domain key type value
  local domain="$1" key="$2" type="$3" value="$4" old
  if [[ "$DRY_RUN" == "1" ]]; then echo "  DRY: defaults write $domain $key -$type $value"; return 0; fi
  if defaults read "$domain" "$key" >/dev/null 2>&1; then
    old="$(defaults read "$domain" "$key" 2>/dev/null | tr '\n' ' ')"
    echo "SET|$domain|$key|$type|$old" >> "$OPT_BACKUP"
  else
    echo "DEL|$domain|$key" >> "$OPT_BACKUP"
  fi
  defaults write "$domain" "$key" "-$type" "$value" 2>/dev/null || return 1
}

opt_pmset() { # key value
  local key="$1" value="$2" s v captured=0
  if [[ "$DRY_RUN" == "1" ]]; then echo "  DRY: sudo pmset -a $key $value"; return 0; fi
  for s in b c u; do
    v="$(pmset_get "$key" "$s")"
    [[ -n "$v" ]] && { echo "PMSET|$key|$s|$v" >> "$OPT_BACKUP"; captured=1; }
  done
  [[ "$captured" == "1" ]] && { $SUDO pmset -a "$key" "$value" 2>/dev/null || return 1; }
  return 0
}

opt_mdutil_off() {
  if [[ "$DRY_RUN" == "1" ]]; then echo "  DRY: sudo mdutil -a -i off"; return 0; fi
  $SUDO mdutil -a -s > "$BAKDIR/mdutil-backup.txt" 2>/dev/null
  $SUDO mdutil -a -i off 2>/dev/null || $SUDO mdutil -a -i off 2>/dev/null
  return 0
}

# ---- kernel tuning (sysctl / launchctl limits) -------------------------------
# Research-driven notes (macOS 12-26):
#   - kern.maxfiles is already ~300k on modern macOS; the real "too many open
#     files" fix is the per-process limit via `launchctl limit maxfiles`.
#   - /etc/sysctl.conf is NOT loaded reliably on Sequoia+ (SIP). Persistence
#     is done with a LaunchDaemon plist that re-applies at boot (see
#     sysctl_persist).
#   - NEVER touch vm.compressor_mode / disable swap: under memory pressure the
#     kernel panics ("never really safe"). Deliberately excluded.
SYSCTL_APPLIED="$BAKDIR/sysctl-applied.txt"
SYSCTL_PLIST="/Library/LaunchDaemons/com.macos-debloater.sysctl.plist"
SYSCTL_LABEL="com.macos-debloater.sysctl"

opt_sysctl() { # key value   (records old value, applies, queues for boot persist)
  local key="$1" value="$2" old
  if [[ "$DRY_RUN" == "1" ]]; then echo "  DRY: sudo sysctl -w $key=$value"; return 0; fi
  old="$(sysctl -n "$key" 2>/dev/null)"
  [[ -n "$old" ]] && echo "SYSCTL|$key|$old" >> "$OPT_BACKUP"
  $SUDO sysctl -w "$key=$value" >/dev/null 2>&1 || return 1
  echo "$key=$value" >> "$SYSCTL_APPLIED"
}

opt_launchctl_limit() { # soft hard   (per-process open-file limit; revertible)
  local soft="$1" hard="$2" old
  if [[ "$DRY_RUN" == "1" ]]; then echo "  DRY: sudo launchctl limit maxfiles $soft $hard"; return 0; fi
  old="$(launchctl limit maxfiles 2>/dev/null | awk 'NR==2{print $2"|"$3}')"
  [[ -n "$old" ]] && echo "LIMIT|$old" >> "$OPT_BACKUP"
  $SUDO launchctl limit maxfiles "$soft" "$hard" 2>/dev/null || return 1
}

sysctl_persist() { # write LaunchDaemon that re-applies applied sysctls at boot
  [[ -s "$SYSCTL_APPLIED" ]] || return 0
  local tmp kv
  tmp="$(mktemp /tmp/${SCRIPT_NAME}.sysctl.XXXXXX)" || return 1
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>Label</key><string>$SYSCTL_LABEL</string>"
    echo '  <key>ProgramArguments</key><array>'
    echo '    <string>/usr/sbin/sysctl</string>'
    echo '    <string>-w</string>'
    while IFS= read -r kv; do
      [[ -z "$kv" ]] && continue
      printf '    <string>%s</string>\n' "$kv"
    done < "$SYSCTL_APPLIED"
    echo '  </array>'
    echo '  <key>RunAtLoad</key><true/>'
    echo '</dict></plist>'
  } > "$tmp"
  $SUDO cp "$tmp" "$SYSCTL_PLIST" 2>/dev/null && $SUDO chown root:wheel "$SYSCTL_PLIST" && $SUDO chmod 644 "$SYSCTL_PLIST"
  $SUDO launchctl bootstrap system "$SYSCTL_PLIST" 2>/dev/null || $SUDO launchctl load -w "$SYSCTL_PLIST" 2>/dev/null || true
  rm -f "$tmp"
  ok "kernel settings persist at boot via $SYSCTL_PLIST"
}

sysctl_persist_remove() {
  $SUDO launchctl bootout "system/$SYSCTL_LABEL" 2>/dev/null || true
  $SUDO rm -f "$SYSCTL_PLIST" 2>/dev/null
}

opt_sleepimage() { # hibernatemode 0 + drop the RAM-sized sleepimage (Mode 4)
  if [[ "$DRY_RUN" == "1" ]]; then echo "  DRY: sudo rm -f /private/var/vm/sleepimage"; return 0; fi
  warn "Removing sleepimage: no hibernation fallback if the battery fully drains."
  $SUDO rm -f /private/var/vm/sleepimage 2>/dev/null
}

opt_kill() { # "Dock Finder cfprefsd"
  local app
  for app in $1; do
    if [[ "$DRY_RUN" == "1" ]]; then echo "  DRY: killall $app"; else killall "$app" 2>/dev/null; fi
  done
}

tweaks_mode1() {
  opt_defaults NSGlobalDomain NSAutomaticWindowAnimationsEnabled bool false
  opt_defaults NSGlobalDomain NSWindowResizeTime float 0.001
  opt_defaults NSGlobalDomain AppleShowAllExtensions bool true
  opt_defaults NSGlobalDomain NSNavPanelExpandedStateForSaveMode bool true
  opt_defaults com.apple.dock expose-animation-duration float 0.1
  opt_defaults com.apple.finder ShowPathbar bool true
  opt_defaults com.apple.desktopservices DSDontWriteNetworkStores bool true
  opt_defaults com.apple.desktopservices DSDontWriteUSBStores bool true
  opt_kill "Dock Finder cfprefsd SystemUIServer"
}

tweaks_mode2() {
  tweaks_mode1
  opt_defaults NSGlobalDomain com.apple.springing.enabled bool false
  opt_defaults NSGlobalDomain com.apple.springing.delay float 0
  opt_defaults com.apple.dock autohide-delay float 0
  opt_defaults com.apple.dock autohide-time-modifier float 0.2
  opt_defaults com.apple.universalaccess reduceTransparency bool true
  opt_defaults com.apple.finder _FXSortFoldersFirst bool true
  opt_defaults com.apple.TimeMachine DoNotOfferNewDisksForBackup bool true
  opt_pmset powernap 0
  opt_launchctl_limit 65536 131072   # raise per-process open-file cap
  opt_kill "Dock Finder cfprefsd SystemUIServer"
}

tweaks_mode3() {
  tweaks_mode2
  opt_defaults com.apple.universalaccess reduceMotion bool true
  opt_defaults com.apple.dock autohide-time-modifier float 0
  opt_defaults com.apple.finder QuitMenuItem bool true
  opt_defaults com.apple.print.PrintingPrefs "Quit When Finished" bool true
  if [[ -d "/Applications/Safari.app" ]]; then
    opt_defaults com.apple.Safari UniversalSearchEnabled bool false
    opt_defaults com.apple.Safari ShowFullURLInSmartSearchField bool true
  fi
  opt_pmset proximitywake 0
  opt_pmset tcpkeepalive 0
  opt_mdutil_off
  opt_sysctl debug.lowpri_throttle_enabled 0   # reduce background-task CPU throttle
  opt_kill "Dock Finder cfprefsd SystemUIServer Safari"
}

tweaks_mode4() {
  tweaks_mode3
  opt_defaults com.apple.CrashReporter DialogType string none
  opt_pmset womp 0
  opt_pmset autopoweroff 0
  if [[ "$HIBERNATE_OFF" == "1" ]]; then
    opt_pmset hibernatemode 0
    opt_sleepimage
  fi
  opt_kill "Dock Finder cfprefsd SystemUIServer"
}

apply_tweaks() {
  case "${1:-$MODE}" in
    1) log ""; log "${C_GRN}Optimization level 1 (UI responsiveness, file hygiene).${C_RST}"; tweaks_mode1 ;;
    2) log ""; log "${C_YLW}Optimization level 2 (level 1 + animations, transparency, power nap).${C_RST}"; tweaks_mode2 ;;
    3) log ""; log "${C_BLU}Optimization level 3 (level 2 + motion, Safari, power nap extras, Spotlight index).${C_RST}"; tweaks_mode3 ;;
    4) log ""; log "${C_RED}Optimization level 4 (level 3 + crash dialogs, wake-on-lan, auto power-off).${C_RST}"; tweaks_mode4 ;;
  esac
}

restore_optimizations() {
  local dir backup line
  dir="$(ls -dt "$STATEDIR/backups"/*/ 2>/dev/null | head -1)"
  [[ -z "$dir" ]] && { warn "no backup directory found; nothing to restore."; return 1; }
  backup="$dir/opts-backup.txt"
  log "Restoring optimizations from $dir"
  if [[ -f "$dir/mdutil-backup.txt" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then echo "  DRY: sudo mdutil -a -i on"; else $SUDO mdutil -a -i on 2>/dev/null; fi
  fi
  [[ -s "$backup" ]] || { warn "no optimization backup in $dir."; return 0; }
  while IFS= read -r line; do
    IFS='|' read -ra F <<< "$line"
    case "${F[0]}" in
      SET)
        if [[ "$DRY_RUN" == "1" ]]; then echo "  DRY: defaults write ${F[1]} ${F[2]} -${F[3]} ${F[4]}"
        else defaults write "${F[1]}" "${F[2]}" "-${F[3]}" "${F[4]}" 2>/dev/null; fi ;;
      DEL)
        if [[ "$DRY_RUN" == "1" ]]; then echo "  DRY: defaults delete ${F[1]} ${F[2]}"
        else defaults delete "${F[1]}" "${F[2]}" 2>/dev/null; fi ;;
      PMSET)
        if [[ "$DRY_RUN" == "1" ]]; then echo "  DRY: sudo pmset -${F[2]} ${F[1]} ${F[3]}"
        else $SUDO pmset -"${F[2]}" "${F[1]}" "${F[3]}" 2>/dev/null; fi ;;
      SYSCTL)
        if [[ "$DRY_RUN" == "1" ]]; then echo "  DRY: sudo sysctl -w ${F[1]}=${F[2]}"
        else $SUDO sysctl -w "${F[1]}=${F[2]}" >/dev/null 2>&1; fi ;;
      LIMIT)
        if [[ "$DRY_RUN" == "1" ]]; then echo "  DRY: sudo launchctl limit maxfiles ${F[1]} ${F[2]}"
        else $SUDO launchctl limit maxfiles "${F[1]}" "${F[2]}" 2>/dev/null; fi ;;
    esac
  done < "$backup"
  sysctl_persist_remove
  opt_kill "Dock Finder cfprefsd SystemUIServer"
  ok "optimizations restored."
}

# ---- output -----------------------------------------------------------------
list_catalog() {
  local domain label tier group desc
  log "${C_BOLD}Catalog for ${OS_VER} (${HW_ARCH})${C_RST}"
  log ""
  log "${C_GRN}Tier 1 — Safe${C_RST}"
  while IFS='|' read -r domain label tier group desc; do
    [[ "$tier" == "1" ]] && printf "  ${C_CYN}%-6s${C_RST} %-56s ${C_DIM}%s${C_RST}\n" "$domain" "$label" "$desc"
  done < <(sort -u -t'|' -k1,1 -k2,2 "$RESOLVED_TMP")
  log ""
  log "${C_YLW}Tier 2 — Balanced / Aggressive${C_RST}"
  while IFS='|' read -r domain label tier group desc; do
    [[ "$tier" == "2" ]] && printf "  ${C_CYN}%-6s${C_RST} %-56s ${C_DIM}%s${C_RST}\n" "$domain" "$label" "$desc"
  done < <(sort -u -t'|' -k4,4 -k1,1 -k2,2 "$RESOLVED_TMP")
  log ""
  log "${C_RED}Tier 3 — Thermal (Mode 4)${C_RST}"
  while IFS='|' read -r domain label tier group desc; do
    [[ "$tier" == "3" ]] && printf "  ${C_CYN}%-6s${C_RST} ${C_BOLD}%-56s${C_RST} ${C_DIM}%s${C_RST}\n" "$domain" "$label" "$desc"
  done < <(sort -u -t'|' -k1,1 -k2,2 "$RESOLVED_TMP")
  log ""
  log "${C_RED}${C_BOLD}Tier 4 — Dangerous extras (Mode 4)${C_RST}"
  while IFS='|' read -r domain label tier group desc; do
    [[ "$tier" == "4" ]] && printf "  ${C_CYN}%-6s${C_RST} ${C_RED}%-56s${C_RST} ${C_DIM}%s${C_RST}\n" "$domain" "$label" "$desc"
  done < <(sort -u -t'|' -k1,1 -k2,2 "$RESOLVED_TMP")
}

print_moon() {
  if [[ -t 1 ]]; then
    printf '%s\n' \
      "${C_DIM}               ·                          ✧${C_RST}" \
      "${C_YLW}     ✧                       .${C_RST}" \
      "${C_CYN}                 ▄▄▄▄▓▓▄▄▄▄${C_RST}" \
      "${C_CYN}       .       ▄▓▓▓██░░░░░░░▀▄${C_RST}" \
      "${C_CYN}             ▄▓▓██░░░░░  ✧  ░░▀▄${C_RST}" \
      "${C_CYN}            ▄▓██░░░░░  ✵      ░░▀▄${C_RST}" \
      "${C_CYN}  ✧        ▄▓█░░░░░░            ░▐█▄${C_RST}" \
      "${C_CYN}           ▐█▌░░░░░░            ░░██${C_RST}" \
      "${C_CYN}            ▀█▄░░░░░          ░░▄█▀${C_RST}" \
      "${C_CYN}             ▀██▄░░░░░      ░░▄█▀${C_RST}" \
      "${C_CYN}      .        ▀▀████▓▄▄▄▄▄██▀▀${C_RST}" \
      "${C_MAG}                 ✧            ✦${C_RST}" \
      "${C_DIM}        ·                        ✧${C_RST}" \
      ""
    printf '%s\n' "${C_BOLD}${C_MAG}   m a c o s - d e b l o a t e r${C_RST}"
  else
    printf '%s\n' "${C_BOLD}macos-debloater${C_RST} — debloat + optimize, mode 1-4."
  fi
}

print_header() {
  local sipc drun
  if [[ "$SIP_STATE" == "disabled" ]]; then sipc="${C_GRN}"; elif [[ "$SIP_STATE" == "enabled" ]]; then sipc="${C_RED}"; else sipc="${C_YLW}"; fi
  if [[ "$DRY_RUN" == "1" ]]; then drun="${C_GRN}yes${C_RST}"; else drun="${C_YLW}no${C_RST}"; fi
  echo ""
  printf '%s\n' "${C_BOLD}${C_MAG}${SCRIPT_NAME}${C_RST}${C_BOLD} v${VERSION}${C_RST}   ${C_CYN}${OS_VER}${C_RST}"
  echo "${C_DIM}──────────────────────────────────────────────────────────${C_RST}"
  echo "  Host    ${C_CYN}${HW_NAME} (${HW_ARCH})${C_RST}"
  echo "  CPU     ${C_CYN}${CPU_BRAND}${C_RST}"
  echo "  RAM     ${C_CYN}${MEM_GB} GB${C_RST}"
  echo "  OS      ${C_CYN}${OS_VER}${C_RST}"
  printf '%s\n' "  SIP     ${sipc}${SIP_STATE}${C_RST}"
  printf '%s\n' "  Scope   ${C_CYN}root · ${USER_COUNT} user account(s)${C_RST}"
  printf '%s\n' "  Dry-run ${drun}"
  echo "${C_DIM}──────────────────────────────────────────────────────────${C_RST}"
  config_summary
}

mode_note() {
  case "$MODE" in
    1)
      log "${C_GRN}${C_BOLD}Mode 1 — Safe${C_RST}"
      log "  Services: telemetry, analytics, diagnostics, Siri/Apple-Intelligence."
      log "  Optimizations: window/dock animations, save dialogs, file extensions,"
      log "  no .DS_Store on network/USB volumes."
      ;;
    2)
      log "${C_YLW}${C_BOLD}Mode 2 — Balanced${C_RST}"
      log "  Services: Mode 1 + iCloud extras, Maps, media extras, App Store,"
      log "  network sharing services. Some features lost."
      log "  Optimizations: Mode 1 + spring-loading off, transparency off,"
      log "  Time Machine auto-disk prompt off, power nap off."
      ;;
    3)
      log "${C_BLU}${C_BOLD}Mode 3 — Aggressive${C_RST}"
      log "  Services: Mode 2 + Spotlight, Find My, Location, Messages, FaceTime,"
      log "  Handoff/AirDrop/AirPlay, Screen Sharing, Time Machine, Photos, Wallet,"
      log "  Screen Time, Family. Many features lost."
      log "  Optimizations: Mode 2 + reduce motion, Safari extras, wake tweaks,"
      log "  Spotlight indexing off (mdutil)."
      ;;
    4)
      log "${C_RED}${C_BOLD}Mode 4 — Dangerous${C_RST}"
      log "  Services: Mode 3 + thermal daemon + App Store, Mail, Contacts,"
      log "  crash/spin reporting, screenshot UI, live transcription."
      log "  Optimizations: Mode 3 + crash dialogs off, wake-on-lan off,"
      log "  auto power-off off."
      log "  Machine still boots, but most optional services are off."
      log "  Two warnings are required before this mode applies."
      ;;
  esac
}

# ---- TUI --------------------------------------------------------------------
TUI_ITEMS=(
  "Safe        telemetry, analytics, Siri/AI backends off; user features kept"
  "Balanced    Safe + iCloud extras, Maps, media, App Store, network services"
  "Aggressive  Balanced + Spotlight, Find My, Messages, sharing, Time Machine, Photos, Wallet"
  "Dangerous   Aggressive + thermal daemon + App Store/Mail/Contacts/reporting extras"
  "Dry-run     OFF - apply changes | ON - preview only"
  "Thermal     OFF - Mode 4 only | ON - also Modes 1-3"
  "List        print the full catalog for this macOS"
  "Restore     undo the last run (services only)"
  "Restore features  undo defaults/pmset/Spotlight tweaks"
  "Restore all re-enable every catalog entry"
  "Custom      disable specific services by label"
  "SIP help    how to disable SIP (with video link)"
  "Quit"
)
TUI_ACTIONS=("mode1" "mode2" "mode3" "mode4" "dryrun" "thermal" "list" "restore" "restorefeat" "restoreall" "custom" "siphelp" "quit")
TUI_SEL=0
TUI_DONE=0
COLS=80
STTY_SAVED=""

tui_screen_off() {
  printf '\033[?1006l\033[?1000l\033[?25h\033[0m\033[?1049l'
}

tui_screen_on() {
  printf '\033[?1049h\033[?1000h\033[?1006h\033[?25l'
}

tui_cleanup() {
  tui_screen_off
  [[ -n "$STTY_SAVED" ]] && stty "$STTY_SAVED" 2>/dev/null
}

tui_crop() {
  local s="$1" w="${2:-$COLS}"
  LC_ALL=C awk -v w="$w" '{ if (length($0) > w) s = substr($0,1,w-3) "..."; else s = $0; print s }' <<< "$s"
}

tui_row_plain() {
  local i="$1"
  case "$i" in
    4) if [[ "$DRY_RUN" == "1" ]]; then printf 'Dry-run     ON  - preview only, nothing changes'; else printf 'Dry-run     OFF - apply changes for real'; fi ;;
    5) if [[ "$ASK_THERMAL" == "1" ]]; then printf 'Thermal     ON  - also disable in Modes 1-3'; else printf 'Thermal     OFF - Mode 4 always includes it'; fi ;;
    *) printf '%s' "${TUI_ITEMS[$i]}" ;;
  esac
}

tui_key() {
  local k c seq
  IFS='' read -r -s -n1 k || { echo EOF; return 0; }
  if [[ "$k" != $'\033' ]]; then
    if [[ "$k" == "" || "$k" == $'\n' || "$k" == $'\r' ]]; then echo ENTER; else printf '%s' "$k"; fi
    return 0
  fi
  IFS='' read -r -s -t 1 -n1 c || { echo ESC; return 0; }
  if [[ "$c" == "[" ]]; then
    IFS='' read -r -s -n1 c || { echo ESC; return 0; }
    if [[ "$c" == "<" ]]; then
      seq=""
      while [[ "$c" != "M" && "$c" != "m" ]]; do
        IFS='' read -r -s -n1 c || { echo NONE; return 0; }
        [[ "$c" != "M" && "$c" != "m" ]] && seq+="$c"
      done
      echo "MOUSE;$seq;${c}"
    else
      case "$c" in
        A) echo UP ;; B) echo DOWN ;; C) echo RIGHT ;; D) echo LEFT ;;
        *) echo NONE ;;
      esac
    fi
    return 0
  elif [[ "$c" == "O" ]]; then
    IFS='' read -r -s -n1 c || { echo ESC; return 0; }
    case "$c" in A) echo UP ;; B) echo DOWN ;; *) echo NONE ;; esac
    return 0
  fi
  echo ESC
}

mouse_handle() {
  local key="$1" _t b x y m
  IFS=';' read -r _t b x y m <<< "$key"
  b="${b:-0}"; x="${x:-1}"; y="${y:-1}"; m="${m:-M}"
  case "$m" in
    m) return ;;
  esac
  case "$b" in
    0)
      if [[ "$y" =~ ^[0-9]+$ && "$y" -ge 3 && "$y" -lt $(( 3 + ${#TUI_ITEMS[@]} )) ]]; then
        TUI_SEL=$(( y - 3 ))
        tui_exec
      fi ;;
    64) TUI_SEL=$(( (TUI_SEL - 1 + ${#TUI_ITEMS[@]}) % ${#TUI_ITEMS[@]} )) ;;
    65) TUI_SEL=$(( (TUI_SEL + 1) % ${#TUI_ITEMS[@]} )) ;;
  esac
}

tui_draw() {
  local i n=${#TUI_ITEMS[@]} text plain dtc sipc modec
  if [[ "$SIP_STATE" == "disabled" ]]; then sipc="${C_GRN}"; elif [[ "$SIP_STATE" == "enabled" ]]; then sipc="${C_RED}"; else sipc="${C_YLW}"; fi
  printf '\033[?25l\033[2J\033[H'
  printf '%s\n' "${C_BOLD}${C_MAG}${SCRIPT_NAME}${C_RST}${C_BOLD} v${VERSION}${C_RST}   ${C_CYN}${OS_VER}${C_RST}   ${sipc}SIP ${SIP_STATE}${C_RST}   ${C_YLW}${USER_COUNT} user(s)${C_RST}"
  echo "${C_DIM}──────────────────────────────────────────────────────────────────${C_RST}"
  for ((i=0;i<n;i++)); do
    plain="$(tui_row_plain "$i")"
    text="$(tui_crop "$plain" $(( COLS - 6 )))"
    if [[ "$i" == "$TUI_SEL" ]]; then
      printf '  %s> %s%s\n' "${C_BG}${C_BOLD}" "$text" "${C_RST}"
    else
      case "$i" in
        0) modec="${C_GRN}" ;;
        1) modec="${C_CYN}" ;;
        2) modec="${C_YLW}" ;;
        3) modec="${C_RED}" ;;
        4|5) if [[ "$i" == "4" ]]; then dtc="$DRY_RUN"; else dtc="$ASK_THERMAL"; fi
             [[ "$dtc" == "1" ]] && modec="${C_GRN}" || modec="${C_DIM}" ;;
        6|7|8|9|10|11) modec="${C_DIM}" ;;
        *) modec="${C_DIM}" ;;
      esac
      printf '    %s%s%s\n' "$modec" "$text" "${C_RST}"
    fi
  done
  echo "${C_DIM}──────────────────────────────────────────────────────────────────${C_RST}"
  echo "  ↑/↓ or j/k move   Enter or click choose   1-4 jump   wheel scrolls   q quit"
}

tui_pause() { printf '%s' "Press any key to return to the menu"; IFS='' read -r -s -n1; }

tui_exec() {
  local a="${TUI_ACTIONS[$TUI_SEL]}"
  case "$a" in
    mode1|mode2|mode3|mode4)
      if [[ "$DRY_RUN" == "0" && "$SIP_STATE" != "disabled" ]]; then
        sip_help_text
        echo ""
        tui_pause
        return
      fi
      MODE="${a#mode}"
      TUI_DONE=1 ;;
    dryrun)
      if [[ "$DRY_RUN" == "1" ]]; then DRY_RUN=0; else DRY_RUN=1; fi ;;
    thermal)
      if [[ "$ASK_THERMAL" == "1" ]]; then ASK_THERMAL=0; else ASK_THERMAL=1; fi ;;
    list)
      tui_screen_off
      list_catalog
      tui_pause
      tui_screen_on
      ;;
    restore)
      tui_screen_off
      restore_from_manifest
      tui_pause
      tui_screen_on
      ;;
    restorefeat)
      tui_screen_off
      restore_optimizations
      tui_pause
      tui_screen_on
      ;;
    restoreall)
      tui_screen_off
      restore_all_catalog
      tui_pause
      tui_screen_on
      ;;
    custom)
      tui_screen_off
      [[ -n "$STTY_SAVED" ]] && stty "$STTY_SAVED" 2>/dev/null
      echo ""
      echo "${C_BOLD}Custom services${C_RST} — type label(s) to disable (comma or space separated)."
      echo "Example: com.apple.weatherd com.apple.newsd"
      echo ""
      read -r -p "Labels: " CUSTOM_LABELS
      MANUAL_LABELS="$CUSTOM_LABELS"
      MODE=0
      TUI_DONE=1
      ;;
    siphelp)
      tui_screen_off
      sip_help_text
      echo ""
      tui_pause
      tui_screen_on
      ;;
    quit)
      MODE=0; TUI_DONE=1 ;;
  esac
}

tui_main() {
  print_moon
  sleep 1 2>/dev/null || true
  COLS="${COLUMNS:-$(tput cols 2>/dev/null)}"
  [[ -z "$COLS" || "$COLS" == "0" ]] && COLS=80
  STTY_SAVED="$(stty -g 2>/dev/null)"
  stty -icanon -echo min 1 time 0 2>/dev/null
  trap 'tui_cleanup; exit 130' INT TERM
  tui_screen_on
  while [[ "$TUI_DONE" == "0" ]]; do
    tui_draw
    key="$(tui_key)"
    case "$key" in
      UP|k|K)      TUI_SEL=$(( (TUI_SEL - 1 + ${#TUI_ITEMS[@]}) % ${#TUI_ITEMS[@]} )) ;;
      DOWN|j|J)    TUI_SEL=$(( (TUI_SEL + 1) % ${#TUI_ITEMS[@]} )) ;;
      ENTER)       tui_exec ;;
      1)           TUI_SEL=0; tui_exec ;;
      2)           TUI_SEL=1; tui_exec ;;
      3)           TUI_SEL=2; tui_exec ;;
      4)           TUI_SEL=3; tui_exec ;;
      MOUSE*)      mouse_handle "$key" ;;
      q|Q|ESC|EOF|"") MODE=0; TUI_DONE=1 ;;
    esac
  done
  tui_cleanup
  echo ""
}


# ---- prompts / gates ---------------------------------------------------------
ask_yes() { local ans; read -r -p "${1:-Continue?} [y/N] " ans || return 1; case "$ans" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac; }

thermal_confirm() {
  echo ""
  echo "${C_RED}${C_BOLD}EXTREME: thermal daemon${C_RST}"
  echo "Disables the hardware thermal-management daemon for this CPU."
  echo "No boot loop, but it can cause overheating, throttling and, on laptops,"
  echo "permanent hardware damage."
  if [[ "$DRY_RUN" == "1" ]]; then
    thermal_arch_select
    ok "thermal daemon added (dry-run preview)."
    return
  fi
  read -r -p "Type YES to add the thermal daemon: " answer
  if [[ "$answer" == "YES" ]]; then
    thermal_arch_select
    ok "thermal daemon added."
  else
    warn "thermal daemon left alone."
  fi
}

dangerous_gate() {
  echo ""
  echo "${C_RED}${C_BOLD}WARNING 1 — DANGEROUS MODE${C_RST}"
  echo "Disables the thermal daemon (overheating / possible laptop damage) and a"
  echo "large extra set of services. It still boots. Most optional services off."
  ask_yes "${C_RED}Are you sure? (1/2)${C_RST}" || { warn "aborted."; exit 0; }
  echo ""
  echo "${C_RED}${C_BOLD}WARNING 2 — REALLY SURE?${C_RST}"
  echo "Thermal protection stays off and many features stop working until you run"
  echo "Restore / Restore all from the menu."
  ask_yes "${C_RED}Are you REALLY sure? (2/2)${C_RST}" || { warn "aborted."; exit 0; }
  ok "double confirmation accepted."
}

reboot_prompt() {
  echo ""
  if [[ "$DRY_RUN" == "1" ]]; then
    info "dry-run: reboot suppressed."
    return 0
  fi
  echo "A reboot makes everything take full effect."
  ask_yes "Reboot now?" && $SUDO reboot || info "Skip. Reboot later; services stay disabled in the XPC DB."
}

# ---- silent fleet run ---------------------------------------------------------
# AUTO_APPLY=1: the config file is the whole interface. No TUI, no prompts;
# the config's existence and contents ARE the authorization (MDM/IT pre-seeds).
silent_flow() {
  local lbl
  if [[ "$MODE" == "0" && -z "${MANUAL_LABELS// /}" ]]; then
    err "AUTO_APPLY requires MODE=1..4 (or MANUAL_LABELS) in $CONFIG_FILE"
    exit 1
  fi
  print_header
  mode_note
  echo ""
  select_by_mode

  if [[ -n "${MANUAL_LABELS// /}" ]]; then
    info "manual labels from config; overriding mode selection."
    : > "$SELECTED_TMP"
    for lbl in $(printf '%s' "$MANUAL_LABELS" | tr ',' '\n' | tr ' ' '\n'); do
      [[ -z "$lbl" ]] && continue
      select_label "$lbl" auto
    done
  fi

  if [[ "$ASK_THERMAL" == "1" && "$MODE" != "4" ]]; then thermal_arch_select; fi

  if [[ "$MODE" == "4" ]]; then
    if [[ "$HIBERNATE_OFF" == "1" ]]; then ok "hibernation off (config)."; fi
    if [[ "$FILEVAULT_DISABLE" == "1" ]]; then
      if [[ "$DRY_RUN" == "1" ]]; then echo "  DRY: sudo fdesetup disable"
      else $SUDO fdesetup disable 2>/dev/null || warn "fdesetup disable failed."; fi
    fi
    if [[ "$NETWORK_TUNING" == "1" ]]; then
      opt_sysctl net.inet.tcp.win_scale_factor 8
      opt_sysctl net.inet.tcp.autorcvbufmax 33554432
      opt_sysctl net.inet.tcp.autosndbufmax 33554432
      ok "network buffers raised (config)."
    fi
  fi

  show_plan
  [[ "$(count_picked)" == "0" ]] && { err "nothing selected."; exit 1; }

  if [[ "$DRY_RUN" == "1" ]]; then
    log "${C_BOLD}DRY-RUN: commands only.${C_RST}"
    apply_selection
    apply_tweaks "$MODE"
    log "${C_GRN}${C_BOLD}Dry-run complete.${C_RST} Nothing was changed."
    exit 0
  fi

  take_snapshot
  log "${C_BOLD}Disabling services…${C_RST}"
  apply_selection
  apply_tweaks "$MODE"
  sysctl_persist
  write_restore_script
  log "${C_GRN}${C_BOLD}Done.${C_RST} $(sort -u "$MANIFEST" 2>/dev/null | grep -c '|' || echo 0) service(s) disabled."
}

# ---- run ---------------------------------------------------------------------
interactive_flow() {
  print_header
  mode_note
  echo ""
  select_by_mode

  if [[ -n "${MANUAL_LABELS// /}" ]]; then
    info "manual labels given; overriding mode selection."
    : > "$SELECTED_TMP"
    local lbl
    for lbl in $(printf '%s' "$MANUAL_LABELS" | tr ',' '\n' | tr ' ' '\n'); do
      [[ -z "$lbl" ]] && continue
      select_label "$lbl" auto
    done
  fi

  if [[ "$ASK_THERMAL" == "1" && "$MODE" != "4" ]]; then thermal_confirm; fi

  if [[ "$MODE" == "4" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      echo ""
      warn "dry-run: no confirmation needed; nothing is applied."
    else
      dangerous_gate
      kernel_confirm
    fi
  fi

  show_plan
  [[ "$(count_picked)" == "0" ]] && { err "nothing selected."; exit 0; }

  ask_yes "Apply these changes?" || { warn "aborted."; exit 0; }

  if [[ "$DRY_RUN" == "1" ]]; then
    log "${C_BOLD}DRY-RUN: commands only.${C_RST}"
    apply_selection
    apply_tweaks "$MODE"
    reboot_prompt
  else
    take_snapshot
    log "${C_BOLD}Disabling services…${C_RST}"
    apply_selection
    apply_tweaks "$MODE"
    sysctl_persist
    write_restore_script
    log "${C_GRN}${C_BOLD}Done.${C_RST} $(sort -u "$MANIFEST" 2>/dev/null | grep -c '|' || echo 0) service(s) disabled."
    reboot_prompt
  fi
}

# ---- kernel / FileVault / network decisions (Mode 4) --------------------------
kernel_confirm() {
  local st
  echo ""
  log "${C_RED}${C_BOLD}Kernel + security decisions${C_RST}"

  # 1) Hibernation: safe-sleep off + drop the RAM-sized sleepimage.
  echo ""
  log "${C_BOLD}Safe sleep / hibernation${C_RST}"
  log "  hibernatemode 0 stops writing the RAM-sized sleepimage on every sleep"
  log "  (saves SSD space + write wear). Risk: no disk fallback if the battery"
  log "  drains completely while asleep — unsaved work is lost."
  if ask_yes "Disable safe sleep (hibernatemode 0 + delete sleepimage)? [y/N]"; then
    HIBERNATE_OFF=1
    ok "hibernation will be disabled."
  else
    HIBERNATE_OFF=0
    info "safe sleep kept."
  fi

  # 2) FileVault: research says hardware-accelerated on Apple Silicon (≈free).
  echo ""
  log "${C_BOLD}FileVault${C_RST}"
  st="$(fdesetup status 2>/dev/null | tr -d '\n')"
  if [[ "$st" == *On* ]]; then
    log "  Status: ON."
    if [[ "$HW_ARCH" == "arm64" ]]; then
      log "  Research: on Apple Silicon the disk encryption is hardware-accelerated;"
      log "  disabling it gives ~no speed gain and removes whole-disk encryption."
      log "  (A FileVault-related boot-loop bug existed on 12.3 multi-volume setups.)"
    else
      log "  Research: on Intel the impact is small on SSD, more on HDD; disabling"
      log "  still removes whole-disk encryption."
    fi
    if ask_yes "${C_RED}Disable FileVault anyway? (security loss, ~no speed gain) [y/N]${C_RST}"; then
      $SUDO fdesetup disable 2>/dev/null || warn "fdesetup disable failed."
      warn "FileVault decryption is running in the background; it can take hours."
    else
      info "FileVault kept enabled (recommended)."
    fi
  else
    info "FileVault is already OFF — nothing to do."
  fi

  # 3) Network buffers: ESnet tuning is for wired 1Gbps+; degrades Wi-Fi.
  echo ""
  log "${C_BOLD}Network buffer tuning (ESnet)${C_RST}"
  log "  Raises TCP window scaling to 8 and autotune buffers to 32 MB."
  log "  ESnet guidance: wired 1Gbps+ only. On Wi-Fi this can REDUCE throughput."
  if ask_yes "Apply network buffer tuning? (wired 1Gbps+ only) [y/N]"; then
    opt_sysctl net.inet.tcp.win_scale_factor 8
    opt_sysctl net.inet.tcp.autorcvbufmax 33554432
    opt_sysctl net.inet.tcp.autosndbufmax 33554432
    ok "network buffers raised."
  else
    info "network tuning skipped."
  fi
}

# ---- main ---------------------------------------------------------------------
check_os_supported
load_config
build_resolved

# Enterprise fleet run: config file is the whole interface, no TUI, no prompts.
if [[ "$AUTO_APPLY" == "1" ]]; then
  # destructive direction requires SIP off (dry-run is exempt)
  if [[ "$SIP_STATE" != "disabled" && "$DRY_RUN" == "0" ]]; then sip_block; fi
  silent_flow
  exit 0
fi

# The TUI is the whole interface. It returns with MODE set (a mode chosen), or
# with MODE=0 plus MANUAL_LABELS set (Custom), or nothing chosen (Quit).
tui_main

[[ "$MODE" == "0" && -z "${MANUAL_LABELS// /}" ]] && exit 0

# destructive direction requires SIP off (dry-run is exempt)
if [[ "$SIP_STATE" != "disabled" && "$DRY_RUN" == "0" ]]; then sip_block; fi

interactive_flow
