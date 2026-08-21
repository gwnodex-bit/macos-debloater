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
VERSION="1.3.6"
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
MANUAL_PICKED=0  # 1 = services marked by hand in the Pick menu (SELECTED_TMP already filled)
AUTO_APPLY=0     # 1 = silent run from config file (enterprise fleet / MDM)
PLAN_OK=0        # 1 = plan was built + confirmed inside the TUI (skip re-prompting)
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
    # Trim surrounding whitespace: IT may write "MODE = 2" with spaces.
    v="$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
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
  if [[ "$SIP_STATE" == "disabled" ]]; then
    echo "${C_GRN}${C_BOLD}SIP is disabled - real runs are allowed.${C_RST}"
    echo "The steps below are just for reference in case you ever need them again."
  else
    echo "${C_RED}${C_BOLD}SIP is ${SIP_STATE}.${C_RST} Real runs need SIP disabled."
    echo ""
    echo "How to disable SIP on this Mac:"
  fi
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

# STATEDIR + log dir exist up front; BAKDIR is created lazily only when a
# real apply starts (take_snapshot), so list/restore/dry-run runs don't leave
# empty timestamped directories behind.
mkdir -p "$STATEDIR/backups" "$(dirname "$LOGFILE")" 2>/dev/null

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
  mkdir -p "$BAKDIR" 2>/dev/null
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
  log "${C_BOLD}Plan - $(count_picked) service(s) to disable:${C_RST}"
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

# The one selection routine both the TUI plan and the apply flow use, so what
# is shown on screen is exactly what gets applied. ASK_THERMAL=1 includes the
# thermal daemon in Modes 1-3 without a second prompt (the TUI toggle is the
# consent); the raw terminal flow keeps its own thermal_confirm prompt.
build_plan() {
  : > "$SELECTED_TMP"
  select_by_mode
  if [[ "$ASK_THERMAL" == "1" && "$MODE" != "4" ]]; then thermal_arch_select; fi
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
  local domain label tier group desc rc=0 done=0 total=0
  if [[ "$DRY_RUN" != "1" ]]; then : > "$MANIFEST"; fi
  total=$(sort -u "$SELECTED_TMP" | grep -c '|' || true)
  [[ "$total" == "0" ]] && total=1
  while IFS='|' read -r domain label tier group desc; do
    [[ -z "$label" ]] && continue
    done=$((done+1))
    if [[ -t 1 ]]; then
      # interactive: one progress bar instead of a wall of per-service lines
      printf '\r  %s  %3d/%-3d  %-46s' "$(tui_bar 20 $(( done * 100 / total )))" "$done" "$total" "$label"
    else
      printf "  %-6s %-56s " "$domain" "$label"
    fi
    if disable_service "$domain" "$label"; then
      [[ -t 1 ]] || echo "${C_GRN}disabled${C_RST}"
      if [[ "$DRY_RUN" != "1" ]]; then printf '%s|%s\n' "$domain" "$label" >> "$MANIFEST"; fi
    else
      [[ -t 1 ]] || echo "${C_RED}failed${C_RST}"
    fi
  done < <(sort -u -t'|' -k3,3n -k4,4 -k1,1 -k2,2 "$SELECTED_TMP")
  [[ -t 1 ]] && printf '\r  %s  %d/%d done%s\n' "$(tui_bar 20 100)" "$done" "$total" "$( [[ "$DRY_RUN" == "1" ]] && echo ' (dry-run, nothing changed)' )"
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
  # `launchctl limit maxfiles` prints a single line: "maxfiles soft hard".
  # Match by name, not by line number - NR==2 never fired, so the old limit
  # was never recorded and could never be restored.
  old="$(launchctl limit maxfiles 2>/dev/null | awk '$1=="maxfiles"{print $2"|"$3}')"
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
  # FileVault + ESnet buffers: only after the final Apply gate has passed.
  # In dry-run these print the DRY line without touching anything.
  if [[ "$FILEVAULT_DISABLE" == "1" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then echo "  DRY: sudo fdesetup disable"
    else
      $SUDO fdesetup disable 2>/dev/null || warn "fdesetup disable failed."
      warn "FileVault decryption is running in the background; it can take hours."
    fi
  fi
  if [[ "$NETWORK_TUNING" == "1" ]]; then
    opt_sysctl net.inet.tcp.win_scale_factor 8
    opt_sysctl net.inet.tcp.autorcvbufmax 33554432
    opt_sysctl net.inet.tcp.autosndbufmax 33554432
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
  local dir backup line d restored_sysctl=0
  # The newest backup directory that actually contains a restoreable backup.
  # (Every startup used to create an empty dir; those must be skipped.)
  # BSD stat does not interpret \t in the format string, and the path itself
  # contains spaces ("/Library/Application Support/..."), so delimit with |
  # (backup dir names are timestamps and never contain |).
  dir=""
  while IFS='|' read -r _m d; do
    [[ -z "$d" ]] && continue
    if [[ -s "$d/opts-backup.txt" || -f "$d/mdutil-backup.txt" ]]; then dir="$d"; break; fi
  done < <(find "$STATEDIR/backups" -mindepth 1 -maxdepth 1 -type d -exec stat -f '%m|%N' {} \; 2>/dev/null | sort -rn)
  [[ -z "$dir" ]] && { warn "no backup directory with data found; nothing to restore."; return 1; }
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
        restored_sysctl=1
        if [[ "$DRY_RUN" == "1" ]]; then echo "  DRY: sudo sysctl -w ${F[1]}=${F[2]}"
        else $SUDO sysctl -w "${F[1]}=${F[2]}" >/dev/null 2>&1; fi ;;
      LIMIT)
        if [[ "$DRY_RUN" == "1" ]]; then echo "  DRY: sudo launchctl limit maxfiles ${F[1]} ${F[2]}"
        else $SUDO launchctl limit maxfiles "${F[1]}" "${F[2]}" 2>/dev/null; fi ;;
    esac
  done < "$backup"
  # Only drop the boot-persistence plist when this backup actually restores
  # sysctls. Otherwise an older (Mode 1-2) backup would silently stop a newer
  # run's sysctls from persisting across reboots. Never in dry-run: that would
  # delete the real plist from a preview (sysctl_persist_remove is not
  # DRY-guarded itself).
  if [[ "$restored_sysctl" == "1" && "$DRY_RUN" != "1" ]]; then sysctl_persist_remove; fi
  opt_kill "Dock Finder cfprefsd SystemUIServer"
  ok "optimizations restored."
}

# ---- output -----------------------------------------------------------------
print_header() {
  local sipc drun
  if [[ "$SIP_STATE" == "disabled" ]]; then sipc="${C_GRN}"; elif [[ "$SIP_STATE" == "enabled" ]]; then sipc="${C_RED}"; else sipc="${C_YLW}"; fi
  if [[ "$DRY_RUN" == "1" ]]; then drun="${C_GRN}yes${C_RST}"; else drun="${C_YLW}no${C_RST}"; fi
  echo ""
  printf '%s\n' "${C_BOLD}${C_MAG}${SCRIPT_NAME}${C_RST}${C_BOLD} v${VERSION}${C_RST}   ${C_CYN}${OS_VER}${C_RST}"
  echo "${C_DIM}----------------------------------------------------------${C_RST}"
  echo "  Host    ${C_CYN}${HW_NAME} (${HW_ARCH})${C_RST}"
  echo "  CPU     ${C_CYN}${CPU_BRAND}${C_RST}"
  echo "  RAM     ${C_CYN}${MEM_GB} GB${C_RST}"
  echo "  OS      ${C_CYN}${OS_VER}${C_RST}"
  printf '%s\n' "  SIP     ${sipc}${SIP_STATE}${C_RST}"
  printf '%s\n' "  Scope   ${C_CYN}root - ${USER_COUNT} user account(s)${C_RST}"
  printf '%s\n' "  Dry-run ${drun}"
  echo "${C_DIM}----------------------------------------------------------${C_RST}"
  config_summary
}

mode_note() {
  case "$MODE" in
    1)
      log "${C_GRN}${C_BOLD}Mode 1 - Safe${C_RST}"
      log "  Services: telemetry, analytics, diagnostics, Siri/Apple-Intelligence."
      log "  Optimizations: window/dock animations, save dialogs, file extensions,"
      log "  no .DS_Store on network/USB volumes."
      ;;
    2)
      log "${C_YLW}${C_BOLD}Mode 2 - Balanced${C_RST}"
      log "  Services: Mode 1 + iCloud extras, Maps, media extras, App Store,"
      log "  network sharing services. Some features lost."
      log "  Optimizations: Mode 1 + spring-loading off, transparency off,"
      log "  Time Machine auto-disk prompt off, power nap off."
      ;;
    3)
      log "${C_BLU}${C_BOLD}Mode 3 - Aggressive${C_RST}"
      log "  Services: Mode 2 + Spotlight, Find My, Location, Messages, FaceTime,"
      log "  Handoff/AirDrop/AirPlay, Screen Sharing, Time Machine, Photos, Wallet,"
      log "  Screen Time, Family. Many features lost."
      log "  Optimizations: Mode 2 + reduce motion, Safari extras, wake tweaks,"
      log "  Spotlight indexing off (mdutil)."
      ;;
    4)
      log "${C_RED}${C_BOLD}Mode 4 - Dangerous${C_RST}"
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
RBLOCK_KEY=""; RBLOCK_TEXT=""
TUI_ITEMS=(
  "Safe        telemetry, analytics, Siri/AI backends off; user features kept"
  "Balanced    Safe + iCloud extras, Maps, media, App Store, network services"
  "Aggressive  Balanced + Spotlight, Find My, Messages, sharing, Time Machine, Photos, Wallet"
  "Dangerous   Aggressive + thermal daemon + App Store/Mail/Contacts/reporting extras"
  "Dry-run     OFF - apply changes | ON - preview only"
  "Thermal     OFF - Mode 4 only | ON - also Modes 1-3"
  "List        browse the full catalog for this macOS"
  "Pick        mark services by hand, then disable them"
  "Restore     undo the last run (services only)"
  "Restore features  undo defaults/pmset/Spotlight tweaks"
  "Restore all re-enable every catalog entry"
  "Custom      disable specific services by label"
  "SIP help    how to disable SIP (with video link)"
  "Quit"
)
TUI_ACTIONS=("mode1" "mode2" "mode3" "mode4" "dryrun" "thermal" "list" "pick" "restore" "restorefeat" "restoreall" "custom" "siphelp" "quit")
TUI_SEL=0
TUI_DONE=0
COLS=80
STTY_SAVED=""

tui_screen_off() {
  # Leave the alternate screen, then clear the main screen. Every action and
  # every quit starts from a clean terminal instead of stacking output below
  # everything that ran before.
  printf '\033[?1006l\033[?1000l\033[?25h\033[0m\033[?1049l\033[2J\033[H'
}

tui_screen_on() {
  printf '\033[?1049h\033[?1000h\033[?1006h\033[?25l'
}

tui_cleanup() {
  tui_screen_off
  [[ -n "$STTY_SAVED" ]] && stty "$STTY_SAVED" 2>/dev/null
}

# ---- TUI drawing helpers (box drawing + blocks, no emoji) -------------------
tui_rep() { # char count -> repeated string
  local c="$1" n="$2" s="" i
  for ((i=0;i<n;i++)); do s+="$c"; done
  printf '%s' "$s"
}

tui_lpad() { # text width -> left-justified, truncated to width (char-aware)
  local s="$1" w="$2" i
  s="${s:0:$w}"                      # truncate by characters (UTF-8 safe)
  for ((i=${#s}; i<w; i++)); do s+=" "; done   # pad by characters, not bytes
  printf '%s' "$s"
}

tui_bar() { # width percent -> [blocks] bar
  local w="$1" pct="$2" i s=""
  [[ "$pct" -gt 100 ]] && pct=100
  [[ "$pct" -lt 0 ]] && pct=0
  for ((i=0;i<w;i++)); do
    if (( i * 100 < pct * w )); then s+="█"; else s+="░"; fi
  done
  printf '%s' "$s"
}

tui_topbar() { # plain_title colored_title width -> ┌─ title ─...─┐
  local plain="$1" colored="$2" w="$3" pad
  pad=$(( w - ${#plain} - 4 ))   # ┌─ (2) + title + pad + ─┐ (2) = w
  [[ "$pad" -lt 1 ]] && pad=1
  printf '┌─%s%s─┐' "$colored" "$(tui_rep '─' "$pad")"
}

# Panel borders are drawn with inner width (the item column width); the corners
# sit exactly on the item column's left/right pipes. Returns inner+2 chars.
tui_panel_top() { # title inner_width -> ┌─ title ─...─┐
  local t="$1" w="$2" pad
  pad=$(( w - ${#t} - 2 ))
  [[ "$pad" -lt 1 ]] && pad=1
  printf '┌─%s%s─┐' "$t" "$(tui_rep '─' "$pad")"
}

tui_panel_bottom() { # inner_width -> └...┘
  printf '└%s┘' "$(tui_rep '─' "$1")"
}

tui_cell() { # plain_text color_prefix width -> padded cell with color outside the pad
  local plain="$1" color="$2" w="$3"
  printf '%s%s%s' "$color" "$(tui_lpad "$plain" "$w")" "${C_RST}"
}

TUI_DESC=(
  "Telemetry, analytics, diagnostics, Siri and Apple Intelligence backends off. Nothing user-facing is removed."
  "Safe + iCloud extras, Maps, media extras, App Store, network services. Some features lost."
  "Balanced + Spotlight, Find My, Messages, FaceTime, AirDrop/AirPlay, Screen Sharing, Time Machine, Photos, Wallet. Many features lost."
  "Aggressive + the thermal daemon, App Store, Mail, crash reporting, live transcription. Real risk: double-confirmed."
  "Preview only: every command is printed, nothing is executed. Works even with SIP enabled."
  "Include the thermal daemon in Modes 1-3 as well. Default: Mode 4 only."
  "Print the full service catalog for this exact macOS version."
  "Mark services with space in a browseable list, then disable them. Same safety gates as the modes."
  "Re-enable the services disabled by the last run."
  "Undo the defaults/pmset/Spotlight tweaks back to the saved values."
  "Re-enable every catalog entry, regardless of what ran."
  "Type specific labels to disable, e.g. com.apple.weatherd com.apple.newsd."
  "How to disable SIP: Recovery-mode steps plus a video walkthrough."
  "Exit. Nothing is applied."
)

tui_left_text() { # menu row text (left panel)
  local i="$1" cnt
  case "$i" in
    0) cnt="${MODE_COUNTS[1]:-}"; printf 'Safe%s' "${cnt:+ (${cnt})}" ;;
    1) cnt="${MODE_COUNTS[2]:-}"; printf 'Balanced%s' "${cnt:+ (${cnt})}" ;;
    2) cnt="${MODE_COUNTS[3]:-}"; printf 'Aggressive%s' "${cnt:+ (${cnt})}" ;;
    3) cnt="${MODE_COUNTS[4]:-}"; printf 'Dangerous%s' "${cnt:+ (${cnt})}" ;;
    4) if [[ "$DRY_RUN" == "1" ]]; then printf 'Dry-run: ON'; else printf 'Dry-run: OFF'; fi ;;
    5) if [[ "$ASK_THERMAL" == "1" ]]; then printf 'Thermal: ON'; else printf 'Thermal: OFF'; fi ;;
  6) printf 'List catalog' ;;
  7) printf 'Pick services' ;;
  8) printf 'Restore last run' ;;
  9) printf 'Restore features' ;;
  10) printf 'Restore all' ;;
  11) printf 'Custom labels' ;;
  12) printf 'SIP help' ;;
  13) printf 'Quit' ;;
  esac
}

tui_item_short() { # short label for the About panel
  case "$1" in
    0) printf 'Safe' ;; 1) printf 'Balanced' ;; 2) printf 'Aggressive' ;; 3) printf 'Dangerous' ;;
    4) printf 'Dry-run' ;; 5) printf 'Thermal' ;; 6) printf 'List' ;; 7) printf 'Pick' ;;
    8) printf 'Restore' ;; 9) printf 'Restore features' ;; 10) printf 'Restore all' ;; 11) printf 'Custom' ;;
    12) printf 'SIP help' ;; 13) printf 'Quit' ;;
  esac
}

tui_detail_block() { # right-panel text for the selected item (one line per row, plain)
  local w="$1" i="$TUI_SEL" desc short
  desc="${TUI_DESC[$i]:-}"
  short="$(tui_item_short "$i")"
  printf '%s\n' "$short"
  while [[ "${#desc}" -gt $(( w - 2 )) ]]; do
    printf '%s\n' "${desc:0:$(( w - 2 ))}"
    desc="${desc:$(( w - 2 ))}"
  done
  printf '%s\n' "$desc"
  printf '%s\n' ""
  printf '%s\n' "Host  ${HW_NAME} (${HW_ARCH})"
  printf '%s\n' "CPU   ${CPU_BRAND}"
  printf '%s\n' "RAM   ${MEM_GB} GB"
  printf '%s\n' "OS    ${OS_VER}"
  printf '%s\n' "SIP   ${SIP_STATE}"
  printf '%s\n' "Users ${USER_COUNT}"
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
      # framed layout: padding row at 2, panel top at 3, items start at row 4
      if [[ "$y" =~ ^[0-9]+$ && "$y" -ge 4 && "$y" -lt $(( 4 + ${#TUI_ITEMS[@]} )) && "$x" -ge 3 ]]; then
        TUI_SEL=$(( y - 4 ))
        tui_exec
      fi ;;
    64) TUI_SEL=$(( (TUI_SEL - 1 + ${#TUI_ITEMS[@]}) % ${#TUI_ITEMS[@]} )) ;;
    65) TUI_SEL=$(( (TUI_SEL + 1) % ${#TUI_ITEMS[@]} )) ;;
  esac
}

tui_draw() {
  local i n=${#TUI_ITEMS[@]} left modec sipc title_p title_c dry thm
  local w="${COLS:-80}"
  if [[ "$SIP_STATE" == "disabled" ]]; then sipc="${C_GRN}"; elif [[ "$SIP_STATE" == "enabled" ]]; then sipc="${C_RED}"; else sipc="${C_YLW}"; fi
  # geometry: two panels side by side inside an outer frame
  TL=30
  if [[ "$w" -ge 72 ]]; then
    TR=$(( w - TL - 12 )); [[ "$TR" -lt 22 ]] && TR=22
  else
    TL=$(( w - 8 )); [[ "$TL" -lt 20 ]] && TL=20; TR=0
  fi
  printf '\033[?25l\033[2J\033[H'
  # top bar (title shrinks on narrow terminals so the frame always fits)
  if [[ "$w" -ge 76 ]]; then
    title_p=" macos-debloater v${VERSION}   ${OS_VER}   SIP ${SIP_STATE} "
    title_c=" ${C_BOLD}${C_MAG}${SCRIPT_NAME} v${VERSION}${C_RST}   ${C_CYN}${OS_VER}${C_RST}   ${sipc}SIP ${SIP_STATE}${C_RST} "
  elif [[ "$w" -ge 40 ]]; then
    title_p=" macos-debloater v${VERSION} "
    title_c=" ${C_BOLD}${C_MAG}${SCRIPT_NAME} v${VERSION}${C_RST} "
  else
    title_p=" macos-debloater "
    title_c=" ${C_BOLD}${C_MAG}${SCRIPT_NAME}${C_RST} "
  fi
  tui_topbar "$title_p" "$title_c" "$w"; echo ""
  printf '│%s│\n' "$(tui_rep ' ' $(( w - 2 )))"
  # panel titles
  if [[ "$TR" -gt 0 ]]; then
    printf '│  %s  %s  │\n' "$(tui_panel_top ' Select ' "$TL")" "$(tui_panel_top " About: $(tui_item_short "$TUI_SEL") " "$TR")"
  else
    printf '│  %s  │\n' "$(tui_panel_top ' Select ' "$TL")"
  fi
  # right panel block (cached per TUI_SEL+width: only rebuilt when either changes)
  local -a rblock=()
  local l
  if [[ "$TR" -gt 0 ]]; then
    if [[ "$TUI_SEL:$TR" != "${RBLOCK_KEY:-}" ]]; then
      RBLOCK_KEY="$TUI_SEL:$TR"
      RBLOCK_TEXT="$(tui_detail_block "$TR")"
    fi
    while IFS= read -r l; do rblock+=("$l"); done <<< "$RBLOCK_TEXT"
  fi
  # item rows
  for ((i=0;i<n;i++)); do
    left="$(tui_left_text "$i")"
    case "$i" in
      0) modec="${C_GRN}" ;; 1) modec="${C_CYN}" ;; 2) modec="${C_YLW}" ;; 3) modec="${C_RED}" ;;
      4) [[ "$DRY_RUN" == "1" ]] && modec="${C_GRN}" || modec="${C_DIM}" ;;
      5) [[ "$ASK_THERMAL" == "1" ]] && modec="${C_GRN}" || modec="${C_DIM}" ;;
      *) modec="${C_DIM}" ;;
    esac
    if [[ "$i" == "$TUI_SEL" ]]; then
      printf '│  │%s│' "$(tui_cell " > ${left} " "${C_BG}${C_BOLD}${modec}" "$TL")"
    else
      printf '│  │%s│' "$(tui_cell "   ${left} " "${modec}" "$TL")"
    fi
    if [[ "$TR" -gt 0 ]]; then
      printf '  │%s│  │\n' "$(tui_cell " ${rblock[$i]:-} " "${C_DIM}" "$TR")"
    else
      printf '  │\n'
    fi
  done
  # panel bottoms
  if [[ "$TR" -gt 0 ]]; then
    printf '│  %s  %s  │\n' "$(tui_panel_bottom "$TL")" "$(tui_panel_bottom "$TR")"
  else
    printf '│  %s  │\n' "$(tui_panel_bottom "$TL")"
  fi
  # footer: keys + state (plain text - colors inside a padded line break alignment)
  if [[ "$DRY_RUN" == "1" ]]; then dry="ON"; else dry="off"; fi
  if [[ "$ASK_THERMAL" == "1" ]]; then thm="ON"; else thm="off"; fi
  printf '│  %s  │\n' "$(tui_lpad "↑/↓ or j/k move   Enter select   1-4 jump   q quit    Dry-run: ${dry}  Thermal: ${thm}" $(( w - 6 )))"
  [[ -f "$CONFIG_FILE" ]] && printf '│  %s  │\n' "$(tui_lpad "config $CONFIG_FILE pre-sets values" $(( w - 6 )))"
  printf '└%s┘\n' "$(tui_rep '─' $(( w - 2 )))"
}

tui_pause() {
  printf '\nPress any key to return to the menu'
  IFS='' read -r -s -n1
  echo ""
}

tui_confirm() { # title detail -> Enter confirms (0), q cancels (1)
  local title="$1" detail="$2" w="${COLS:-80}" key
  while :; do
    printf '\033[2J\033[H'
    tui_topbar " $title " " ${C_YLW}${C_BOLD}$title${C_RST} " "$w"; echo ""
    printf '│  %s  │\n' "$(tui_lpad " $detail " $(( w - 6 )))"
    printf '│  %s  │\n' "$(tui_lpad "" $(( w - 6 )))"
    printf '│  %s  │\n' "$(tui_lpad " Enter confirm   q cancel " $(( w - 6 )))"
    printf '└%s┘\n' "$(tui_rep '─' $(( w - 2 )))"
    key="$(tui_key)"
    case "$key" in
      ENTER)   return 0 ;;
      q|Q|ESC|EOF) return 1 ;;
      MOUSE*)  : ;;
    esac
  done
}

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
      PLAN_OK=0
      tui_select_mode ;;
    dryrun)
      if [[ "$DRY_RUN" == "1" ]]; then DRY_RUN=0; else DRY_RUN=1; fi ;;
    thermal)
      if [[ "$ASK_THERMAL" == "1" ]]; then ASK_THERMAL=0; else ASK_THERMAL=1; fi ;;
    list)
      tui_service_list view
      ;;
    pick)
      if tui_service_list pick; then
        MANUAL_PICKED=1
        MODE=0
        TUI_DONE=1
      fi
      ;;
    restore)
      tui_confirm "Restore last run" "Re-enable the services disabled by the last run." || return
      tui_screen_off
      restore_from_manifest
      tui_pause
      tui_screen_on
      ;;
    restorefeat)
      tui_confirm "Restore features" "Undo the defaults/pmset/Spotlight tweaks back to the saved values." || return
      tui_screen_off
      restore_optimizations
      tui_pause
      tui_screen_on
      ;;
    restoreall)
      tui_confirm "Restore all" "Re-enable every catalog entry, regardless of what ran." || return
      tui_screen_off
      restore_all_catalog
      tui_pause
      tui_screen_on
      ;;
    custom)
      tui_screen_off
      [[ -n "$STTY_SAVED" ]] && stty "$STTY_SAVED" 2>/dev/null
      echo ""
      echo "${C_BOLD}Custom services${C_RST} - type label(s) to disable (comma or space separated)."
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
  COLS="${COLUMNS:-$(tput cols 2>/dev/null)}"
  [[ -z "$COLS" || "$COLS" == "0" ]] && COLS=80
  LINES="${LINES:-$(tput lines 2>/dev/null)}"
  [[ -z "$LINES" || "$LINES" == "0" ]] && LINES=24
  STTY_SAVED="$(stty -g 2>/dev/null)"
  stty -icanon -echo min 1 time 0 2>/dev/null
  trap 'tui_cleanup; exit 130' INT TERM
  tui_screen_on
  tui_compute_counts
  while [[ "$TUI_DONE" == "0" ]]; do
    tui_draw
    key="$(tui_key)"
    case "$key" in
      UP|k|K)      TUI_SEL=$(( (TUI_SEL - 1 + ${#TUI_ITEMS[@]}) % ${#TUI_ITEMS[@]} )) ;;
      DOWN|j|J)    TUI_SEL=$(( (TUI_SEL + 1) % ${#TUI_ITEMS[@]} )) ;;
      ENTER)       tui_exec ;;
      1)           TUI_SEL=0 ;;   # jump selects the row; Enter still executes
      2)           TUI_SEL=1 ;;
      3)           TUI_SEL=2 ;;
      4)           TUI_SEL=3 ;;
      MOUSE*)      mouse_handle "$key" ;;
      q|Q|ESC|EOF|"") MODE=0; TUI_DONE=1 ;;
    esac
  done
  tui_cleanup
  echo ""
}

# ---- TUI mode flow: loader -> danger gate (Mode 4) -> plan screen ------------
TUI_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
MODE_COUNTS=()

run_loader() { # title command...  (command runs in a background subshell)
  local title="$1"; shift
  local i=0 pct=0 t0
  t0=$(date +%s)
  ( "$@" >/dev/null 2>&1 ) &
  local pid=$!
  printf '\033[2J\033[H'
  while kill -0 "$pid" 2>/dev/null; do
    pct=$(( ( $(date +%s) - t0 ) * 30 ))
    [[ "$pct" -gt 95 ]] && pct=95
    printf '\033[H│  %s  %s\n' "${TUI_SPIN[$i]}" "$title"
    printf '│  [%s] %3d%%\n' "$(tui_bar 24 "$pct")" "$pct"
    i=$(( (i + 1) % 10 ))
    sleep 0.08
  done
  wait "$pid"
  # settle at 100% for a beat so the bar is visible even for fast work
  for ((i=0;i<4;i++)); do
    printf '\033[H│  %s  %s\n' "${TUI_SPIN[$i]}" "$title"
    printf '│  [%s] 100%%\n' "$(tui_bar 24 100)"
    sleep 0.06
  done
}

tui_count_all_modes() {
  local m n tmp
  for m in 1 2 3 4; do
    tmp="$(mktemp /tmp/${SCRIPT_NAME}.count.XXXXXX)" || continue
    MODE="$m" SELECTED_TMP="$tmp" select_by_mode
    n="$(sort -u "$tmp" | grep -c '|' || true)"
    printf '%s %s\n' "$m" "$n" >> "$COUNTS_TMP"
    rm -f "$tmp"
  done
}

tui_compute_counts() {
  [[ -n "${MODE_COUNTS[1]:-}" ]] && return 0
  COUNTS_TMP="$(mktemp /tmp/${SCRIPT_NAME}.counts.XXXXXX)" || return 0
  run_loader "Analyzing catalog for mode counts" tui_count_all_modes
  local m
  for m in 1 2 3 4; do
    MODE_COUNTS[$m]="$(awk -v m="$m" '$1==m{print $2}' "$COUNTS_TMP" 2>/dev/null)"
  done
  rm -f "$COUNTS_TMP"
}

tui_danger_gate() { # Mode 4: framed warning, requires typing YES
  local ans w="${COLS:-80}"
  printf '\033[2J\033[H'
  printf '┌%s┐\n' "$(tui_rep '─' $(( w - 2 )))"
  printf '│%s%s%s│\n' "${C_RED}${C_BOLD}" "$(tui_lpad ' DANGEROUS MODE ' $(( w - 2 )))" "${C_RST}"
  printf '│%s│\n' "$(tui_lpad ' Disables the CPU thermal-management daemon and a large extra set of services.' $(( w - 2 )))"
  printf '│%s│\n' "$(tui_lpad ' The machine still boots, but it can overheat. On a laptop that is permanent' $(( w - 2 )))"
  printf '│%s│\n' "$(tui_lpad ' hardware-damage territory. Many features stop working until you Restore.' $(( w - 2 )))"
  printf '└%s┘\n' "$(tui_rep '─' $(( w - 2 )))"
  [[ -n "$STTY_SAVED" ]] && stty "$STTY_SAVED" 2>/dev/null
  read -r -p "Type YES to arm dangerous mode (anything else goes back): " ans
  stty -icanon -echo min 1 time 0 2>/dev/null
  [[ "$ans" == "YES" ]]
}

tui_plan_screen() { # scrollable plan inside the TUI; Enter confirms, q backs out
  local -a rows=()
  local i sel=0 off=0 vh key domain label tier desc line
  local tier1=0 tier2=0 tier3=0 tier4=0 n lh
  local w="${COLS:-80}"
  lh="${LINES:-24}"
  while IFS='|' read -r domain label tier desc; do
    [[ -z "$label" ]] && continue
    rows+=("$domain|$label|$tier|$desc")
    case "$tier" in
      1) tier1=$((tier1+1)) ;; 2) tier2=$((tier2+1)) ;; 3) tier3=$((tier3+1)) ;; 4) tier4=$((tier4+1)) ;;
    esac
  done < <(sort -u -t'|' -k3,3n -k4,4 -k1,1 -k2,2 "$SELECTED_TMP")
  n=${#rows[@]}
  while :; do
    printf '\033[2J\033[H'
    tui_topbar " Mode ${MODE} plan - ${n} service(s) " " ${C_BOLD}Mode ${MODE} plan - ${n} service(s)${C_RST} " "$w"; echo ""
    printf '│  %s  │\n' "$(tui_lpad " safe ${tier1}   aggr ${tier2}   thermal ${tier3}   danger ${tier4}   dry-run $([[ "$DRY_RUN" == "1" ]] && echo ON || echo off)" $(( w - 6 )))"
    printf '│  %s  │\n' "$(tui_rep '─' $(( w - 6 )))"
    vh=$(( lh - 9 )); [[ "$vh" -lt 5 ]] && vh=5
    [[ "$sel" -lt "$off" ]] && off=$sel
    [[ "$sel" -ge $(( off + vh )) ]] && off=$(( sel - vh + 1 ))
    for ((i=off; i<off+vh && i<n; i++)); do
      IFS='|' read -r domain label tier desc <<< "${rows[$i]}"
      line="$(printf '%-5s %-6s %-40s %s' "$(tier_tag "$tier")" "$domain" "$label" "$desc")"
      if [[ "$i" == "$sel" ]]; then
        printf '│  %s%s%s│\n' "${C_BG}${C_BOLD}" "$(tui_lpad " ${line} " $(( w - 4 )))" "${C_RST}"
      else
        printf '│  %s%s%s│\n' "$(tier_color "$tier")" "$(tui_lpad " ${line} " $(( w - 4 )))" "${C_RST}"
      fi
    done
    for ((; i<off+vh; i++)); do
      printf '│  %s  │\n' "$(tui_lpad "" $(( w - 6 )))"
    done
    if [[ "$MODE" == "4" ]]; then
      printf '│  %s  │\n' "$(tui_lpad " Enter apply   h hibernation:$HIBERNATE_OFF   f FileVault:$FILEVAULT_DISABLE   n network:$NETWORK_TUNING   q back " $(( w - 6 )))"
    else
      printf '│  %s  │\n' "$(tui_lpad " Enter apply   d dry-run:$DRY_RUN   q back " $(( w - 6 )))"
    fi
    printf '└%s┘\n' "$(tui_rep '─' $(( w - 2 )))"
    key="$(tui_key)"
    case "$key" in
      UP|k|K)          sel=$(( sel > 0 ? sel - 1 : 0 )) ;;
      DOWN|j|J|" ")   sel=$(( sel + 1 < n ? sel + 1 : n - 1 )) ;;
      ENTER)           return 0 ;;
      q|Q|ESC|EOF)     return 1 ;;
      h|H) [[ "$MODE" == "4" ]] && { [[ "$HIBERNATE_OFF" == "1" ]] && HIBERNATE_OFF=0 || HIBERNATE_OFF=1; } ;;
      f|F) [[ "$MODE" == "4" ]] && { [[ "$FILEVAULT_DISABLE" == "1" ]] && FILEVAULT_DISABLE=0 || FILEVAULT_DISABLE=1; } ;;
      n|N) [[ "$MODE" == "4" ]] && { [[ "$NETWORK_TUNING" == "1" ]] && NETWORK_TUNING=0 || NETWORK_TUNING=1; } ;;
      d|D) [[ "$DRY_RUN" == "1" ]] && DRY_RUN=0 || DRY_RUN=1 ;;
      MOUSE*) : ;;
    esac
  done
}

tui_service_list() { # view|pick - framed scrollable catalog; pick returns 0 when confirmed
  local mode="$1"
  local -a rows=() picked=()
  local i sel=0 off=0 vh key domain label tier group desc line mark
  local w="${COLS:-80}" lh="${LINES:-24}" n=0 marked=0 risk=0
  local tier1=0 tier2=0 tier3=0 tier4=0
  while IFS='|' read -r domain label tier group desc; do
    [[ -z "$label" ]] && continue
    [[ "$mode" == "pick" ]] && is_denied "$label" && continue
    rows+=("$domain|$label|$tier|$group|$desc")
    picked+=(0)
    case "$tier" in
      1) tier1=$((tier1+1)) ;; 2) tier2=$((tier2+1)) ;; 3) tier3=$((tier3+1)) ;; 4) tier4=$((tier4+1)) ;;
    esac
  done < <(sort -u -t'|' -k3,3n -k4,4 -k1,1 -k2,2 "$RESOLVED_TMP")
  n=${#rows[@]}
  if [[ "$n" == "0" ]]; then
    printf '\033[2J\033[H'
    printf '┌%s┐\n' "$(tui_rep '─' $(( w - 2 )))"
    printf '│%s│\n' "$(tui_lpad ' No services resolve on this macOS.' $(( w - 2 )))"
    printf '└%s┘\n' "$(tui_rep '─' $(( w - 2 )))"
    return 1
  fi
  while :; do
    printf '\033[2J\033[H'
    if [[ "$mode" == "pick" ]]; then
      tui_topbar " Pick services - ${marked} marked " " ${C_BOLD}${C_MAG}Pick services - ${marked} marked${C_RST} " "$w"; echo ""
    else
      tui_topbar " Catalog - ${OS_VER} (${HW_ARCH}) - ${n} services " " ${C_BOLD}${C_MAG}Catalog - ${OS_VER} (${HW_ARCH})${C_RST} - ${n} services " "$w"; echo ""
    fi
    printf '│  %s  │\n' "$(tui_lpad " safe ${tier1}   aggr ${tier2}   thermal ${tier3}   danger ${tier4}" $(( w - 6 )))"
    printf '│  %s  │\n' "$(tui_rep '─' $(( w - 6 )))"
    vh=$(( lh - 9 )); [[ "$vh" -lt 5 ]] && vh=5
    [[ "$sel" -lt "$off" ]] && off=$sel
    [[ "$sel" -ge $(( off + vh )) ]] && off=$(( sel - vh + 1 ))
    for ((i=off; i<off+vh && i<n; i++)); do
      IFS='|' read -r domain label tier group desc <<< "${rows[$i]}"
      if [[ "$mode" == "pick" ]]; then
        [[ "${picked[$i]}" == "1" ]] && mark="[*]" || mark="[ ]"
        line="$(printf '%-4s %-6s %-36s %s' "$mark" "$domain" "$label" "$desc")"
      else
        line="$(printf '%-5s %-6s %-40s %s' "$(tier_tag "$tier")" "$domain" "$label" "$desc")"
      fi
      if [[ "$i" == "$sel" ]]; then
        printf '│  %s%s%s│\n' "${C_BG}${C_BOLD}" "$(tui_lpad " ${line} " $(( w - 4 )))" "${C_RST}"
      elif [[ "$mode" == "pick" && "${picked[$i]}" == "1" ]]; then
        printf '│  %s%s%s│\n' "${C_GRN}" "$(tui_lpad " ${line} " $(( w - 4 )))" "${C_RST}"
      else
        printf '│  %s%s%s│\n' "$(tier_color "$tier")" "$(tui_lpad " ${line} " $(( w - 4 )))" "${C_RST}"
      fi
    done
    for ((; i<off+vh; i++)); do
      printf '│  %s  │\n' "$(tui_lpad "" $(( w - 6 )))"
    done
    if [[ "$mode" == "pick" ]]; then
      printf '│  %s  │\n' "$(tui_lpad " space mark/unmark   Enter apply ${marked}   q back " $(( w - 6 )))"
    else
      printf '│  %s  │\n' "$(tui_lpad " j/k or arrows scroll   q back " $(( w - 6 )))"
    fi
    printf '└%s┘\n' "$(tui_rep '─' $(( w - 2 )))"
    key="$(tui_key)"
    case "$key" in
      UP|k|K)        sel=$(( sel > 0 ? sel - 1 : 0 )) ;;
      DOWN|j|J)      sel=$(( sel + 1 < n ? sel + 1 : n - 1 )) ;;
      " ")           [[ "$mode" == "pick" ]] && { if [[ "${picked[$sel]}" == "1" ]]; then picked[$sel]=0; marked=$((marked-1)); else picked[$sel]=1; marked=$((marked+1)); fi; } ;;
      ENTER)         [[ "$mode" == "pick" ]] && break ;;
      q|Q|ESC|EOF)   return 1 ;;
      MOUSE*)        : ;;
    esac
  done
  # confirmed: materialize the marked rows; danger tiers need the same gate as Mode 4
  if [[ "$marked" == "0" ]]; then
    printf '\033[2J\033[H'
    printf '┌%s┐\n' "$(tui_rep '─' $(( w - 2 )))"
    printf '│%s│\n' "$(tui_lpad ' Nothing marked. Press any key to go back.' $(( w - 2 )))"
    printf '└%s┘\n' "$(tui_rep '─' $(( w - 2 )))"
    tui_key >/dev/null
    return 1
  fi
  : > "$SELECTED_TMP"
  for ((i=0;i<n;i++)); do
    [[ "${picked[$i]}" == "1" ]] && printf '%s\n' "${rows[$i]}" >> "$SELECTED_TMP"
  done
  if [[ "$DRY_RUN" != "1" ]]; then
    for ((i=0;i<n;i++)); do
      [[ "${picked[$i]}" != "1" ]] && continue
      IFS='|' read -r _ _ tier _ <<< "${rows[$i]}"
      [[ "$tier" == "3" || "$tier" == "4" ]] && risk=1
    done
    if [[ "$risk" == "1" ]]; then tui_danger_gate || return 1; fi
  fi
  return 0
}

tui_select_mode() { # loader -> danger gate (Mode 4) -> plan screen; sets TUI_DONE on confirm
  local count
  run_loader "Building plan for Mode $MODE" build_plan
  count="$(sort -u "$SELECTED_TMP" | grep -c '|' || true)"
  if [[ "$count" == "0" ]]; then
    printf '\033[2J\033[H'
    printf '│  No services matched Mode %s on this macOS.\n' "$MODE"
    printf '│  Try another mode, or List to see what exists.\n'
    sleep 1
    return 1
  fi
  if [[ "$MODE" == "4" && "$DRY_RUN" != "1" ]]; then
    tui_danger_gate || return 1
  fi
  if tui_plan_screen; then
    PLAN_OK=1
    TUI_DONE=1
    return 0
  fi
  return 1
}


# ---- prompts / gates ---------------------------------------------------------
ask_yes() { local ans; read -r -p "${1:-Continue?} [y/N] " ans || return 1; case "$ans" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac; }

thermal_confirm() {
  local answer
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
  echo "${C_RED}${C_BOLD}WARNING 1 - DANGEROUS MODE${C_RST}"
  echo "Disables the thermal daemon (overheating / possible laptop damage) and a"
  echo "large extra set of services. It still boots. Most optional services off."
  ask_yes "${C_RED}Are you sure? (1/2)${C_RST}" || { warn "aborted."; return 1; }
  echo ""
  echo "${C_RED}${C_BOLD}WARNING 2 - REALLY SURE?${C_RST}"
  echo "Thermal protection stays off and many features stop working until you run"
  echo "Restore / Restore all from the menu."
  ask_yes "${C_RED}Are you REALLY sure? (2/2)${C_RST}" || { warn "aborted."; return 1; }
  ok "double confirmation accepted."
  return 0
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
  # Say why there is no menu. A leftover AUTO_APPLY config silently replacing
  # the TUI is the #1 "why is it running by itself?" surprise.
  log "${C_BOLD}Fleet mode: $CONFIG_FILE has AUTO_APPLY=1, so the menu is skipped.${C_RST}"
  log "  Set AUTO_APPLY=0 (or delete the config) to get the interactive menu back."
  log ""
  : > "$SELECTED_TMP"
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

  if [[ "$MODE" == "4" && "$HIBERNATE_OFF" == "1" ]]; then ok "hibernation off (config)."; fi
  # FILEVAULT_DISABLE / NETWORK_TUNING are handled inside tweaks_mode4,
  # which runs after take_snapshot in the apply path below.

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
  log "${C_BOLD}Disabling services...${C_RST}"
  apply_selection
  apply_tweaks "$MODE"
  sysctl_persist
  write_restore_script
  log "${C_GRN}${C_BOLD}Done.${C_RST} $(sort -u "$MANIFEST" 2>/dev/null | grep -c '|' || echo 0) service(s) disabled."
}

# ---- run ---------------------------------------------------------------------
interactive_flow() {
  if [[ "$MANUAL_PICKED" != "1" ]]; then
    : > "$SELECTED_TMP"
  fi
  print_header
  mode_note
  echo ""
  if [[ "$PLAN_OK" == "1" ]]; then
    # Plan was already built and confirmed inside the TUI; reproduce the exact
    # same selection so what gets applied matches what was shown.
    build_plan
  elif [[ "$MANUAL_PICKED" != "1" ]]; then
    select_by_mode
  fi

  if [[ -n "${MANUAL_LABELS// /}" ]]; then
    info "manual labels given; overriding mode selection."
    : > "$SELECTED_TMP"
    local lbl
    for lbl in $(printf '%s' "$MANUAL_LABELS" | tr ',' '\n' | tr ' ' '\n'); do
      [[ -z "$lbl" ]] && continue
      select_label "$lbl" auto
    done
  fi

  if [[ "$PLAN_OK" != "1" ]]; then
    if [[ "$ASK_THERMAL" == "1" && "$MODE" != "4" && "$MODE" != "0" ]]; then thermal_confirm; fi

    if [[ "$MODE" == "4" ]]; then
      if [[ "$DRY_RUN" == "1" ]]; then
        echo ""
        warn "dry-run: no confirmation needed; nothing is applied."
      else
        dangerous_gate || return 1
        kernel_confirm
      fi
    fi

    show_plan
    [[ "$(count_picked)" == "0" ]] && { err "nothing selected."; return 1; }

    ask_yes "Apply these changes?" || { warn "aborted."; return 1; }
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "${C_BOLD}DRY-RUN: commands only.${C_RST}"
    apply_selection
    apply_tweaks "$MODE"
    reboot_prompt
  else
    take_snapshot
    log "${C_BOLD}Disabling services...${C_RST}"
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
  log "  drains completely while asleep - unsaved work is lost."
  if ask_yes "Disable safe sleep (hibernatemode 0 + delete sleepimage)? [y/N]"; then
    HIBERNATE_OFF=1
    ok "hibernation will be disabled."
  else
    HIBERNATE_OFF=0
    info "safe sleep kept."
  fi

  # 2) FileVault: research says hardware-accelerated on Apple Silicon (~free).
  #    Only a flag is set here; the actual `fdesetup disable` runs AFTER the
  #    final "Apply these changes?" gate, so answering N aborts cleanly.
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
      FILEVAULT_DISABLE=1
      ok "FileVault disable queued (applies only if you confirm below)."
    else
      FILEVAULT_DISABLE=0
      info "FileVault kept enabled (recommended)."
    fi
  else
    FILEVAULT_DISABLE=0
    info "FileVault is already OFF - nothing to do."
  fi

  # 3) Network buffers: ESnet tuning is for wired 1Gbps+; degrades Wi-Fi.
  #    Same pattern: flag only, applied after the final gate.
  echo ""
  log "${C_BOLD}Network buffer tuning (ESnet)${C_RST}"
  log "  Raises TCP window scaling to 8 and autotune buffers to 32 MB."
  log "  ESnet guidance: wired 1Gbps+ only. On Wi-Fi this can REDUCE throughput."
  if ask_yes "Apply network buffer tuning? (wired 1Gbps+ only) [y/N]"; then
    NETWORK_TUNING=1
    ok "network tuning queued (applies only if you confirm below)."
  else
    NETWORK_TUNING=0
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

# No command-line flags exist anymore (removed in v1.3.0). Reject them instead
# of silently ignoring them - a flag run that no-ops is the worst failure mode.
if [[ "$#" -gt 0 ]]; then
  err "unknown argument(s): $*"
  echo "macos-debloater is TUI-only. Flags were removed in v1.3.0." >&2
  echo "For unattended/fleet runs, pre-seed $CONFIG_FILE with AUTO_APPLY=1." >&2
  exit 1
fi

# The TUI needs a real terminal. From a pipe/cron/MDM job without AUTO_APPLY,
# fail loudly instead of dumping raw escape codes and exiting 0 doing nothing.
if [[ ! -t 0 || ! -t 1 ]]; then
  err "no terminal detected (stdin/stdout is not a TTY)."
  echo "macos-debloater is interactive: run it in a terminal and use the menu." >&2
  echo "For unattended/fleet runs, pre-seed $CONFIG_FILE with AUTO_APPLY=1." >&2
  exit 1
fi

# The TUI is the whole interface. It returns with MODE set (a mode chosen), or
# with MODE=0 plus MANUAL_LABELS set (Custom), or nothing chosen (Quit).
# interactive_flow returns 1 when the user backs out (abort, nothing selected),
# in which case we loop back to the menu instead of killing the session.
while :; do
  TUI_DONE=0; MODE=0; MANUAL_LABELS=""; PLAN_OK=0; MANUAL_PICKED=0
  tui_main

  [[ "$MODE" == "0" && -z "${MANUAL_LABELS// /}" && "$MANUAL_PICKED" == "0" ]] && break

  # destructive direction requires SIP off (dry-run is exempt)
  if [[ "$SIP_STATE" != "disabled" && "$DRY_RUN" == "0" ]]; then sip_block; fi

  interactive_flow && break
  # aborted / nothing selected / backed out of the plan -> back to the menu
  echo "${C_DIM}Returning to the menu.${C_RST}"
done
