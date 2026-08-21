#!/bin/bash
# macos-debloater installer - single command, nothing else.
#
#   curl -fsSL https://raw.githubusercontent.com/gwnodex-bit/macos-debloater/main/install.sh | bash
#
# Downloads macos-debloater.sh from this repo, verifies it is a valid bash
# script, and installs it to /usr/local/bin. No telemetry, no analytics,
# nothing is run except the installer itself.
set -u

tmp=""   # global: the EXIT trap must see it even after main() returns
REPO_URL="${REPO_URL:-https://raw.githubusercontent.com/gwnodex-bit/macos-debloater/main}"
SRC="$REPO_URL/macos-debloater.sh"
DEST="${DEST:-/usr/local/bin/macos-debloater}"

BANNER='███████╗██╗   ██╗ ██████╗██╗  ██╗ █████╗ ███████╗██╗     ██████╗
██╔════╝██║   ██║██╔════╝██║ ██╔╝██╔══██╗██╔════╝██║     ██╔══██╗
█████╗  ██║   ██║██║     █████╔╝ ███████║███████╗██║     ██████╔╝
██╔══╝  ██║   ██║██║     ██╔═██╗ ██╔══██║╚════██║██║     ██╔══██╗
██║     ╚██████╔╝╚██████╗██║  ██╗██║  ██║███████║███████╗██║  ██║
╚═╝      ╚═════╝  ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚══════╝╚═╝  ╚═╝'

MAG='\033[35m'; GRN='\033[32m'; DIM='\033[2m'; RST='\033[0m'

# Center a line in the terminal width (banner lines are 66 chars wide).
center() {
  local line="$1" cols pad
  cols="${COLUMNS:-$(tput cols 2>/dev/null)}"
  [[ -z "$cols" || ! "$cols" =~ ^[0-9]+$ ]] && cols=80
  [[ "$cols" -lt 70 ]] && cols=70
  pad=$(( (cols - 66) / 2 ))
  [[ "$pad" -lt 0 ]] && pad=0
  printf '%*s%s\n' "$pad" "" "$line"
}

show_banner() {
  local line
  if [[ -t 1 ]]; then
    while IFS= read -r line; do
      printf '%b' "$MAG"
      center "$line"
      printf '%b' "$RST"
      sleep 0.03
    done <<< "$BANNER"
    echo ""
  else
    while IFS= read -r line; do center "$line"; done <<< "$BANNER"
    echo ""
  fi
}

# Single-line progress bar: [████████░░░░]  63%  label
bar() { # width pct -> block string
  local w="$1" pct="$2" i s="" filled
  [[ "$pct" -gt 100 ]] && pct=100
  [[ "$pct" -lt 0 ]] && pct=0
  filled=$(( pct * w / 100 ))
  for ((i=0;i<filled;i++)); do s+="█"; done
  for ((i=filled;i<w;i++)); do s+="░"; done
  printf '%s' "$s"
}

progress() { # pct label
  local pct="$1" label="$2"
  if [[ -t 1 ]]; then
    printf '\r  [%s] %3d%%  %s' "$(bar 24 "$pct")" "$pct" "$label"
  else
    printf '  %s\n' "$label"
  fi
}

main() {
  local size cpid got pct t0
  tmp="$(mktemp /tmp/macos-debloater.XXXXXX)" || exit 1
  trap 'rm -f "$tmp"' EXIT   # tmp is global so the EXIT trap can see it

  show_banner
  # printf %b so the DIM/RST escape codes are interpreted, not printed raw.
  printf '%b\n' "${DIM}  installing from $REPO_URL${RST}"
  echo ""

  # Best-effort content-length for a real download bar; falls back to a
  # time-based animation when the server doesn't report one.
  size=$(curl -fsSLI "$SRC" 2>/dev/null | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r')
  [[ "$size" =~ ^[0-9]+$ ]] || size=0

  curl -fsSL "$SRC" -o "$tmp" 2>/dev/null &
  cpid=$!
  t0=$(date +%s)
  while kill -0 "$cpid" 2>/dev/null; do
    if [[ "$size" -gt 0 ]]; then
      got=$(wc -c < "$tmp" 2>/dev/null || echo 0)
      pct=$(( got * 100 / size ))
      [[ "$pct" -gt 88 ]] && pct=88   # leave the tail for verify/install
    else
      pct=$(( ( $(date +%s) - t0 ) * 12 ))
      [[ "$pct" -gt 88 ]] && pct=88
    fi
    progress "$pct" "downloading"
    sleep 0.08
  done
  wait "$cpid" || {
    printf '\n'
    echo "  ERROR: could not download $SRC" >&2
    echo "  Check the URL, your network, or set REPO_URL to a mirror." >&2
    exit 1
  }

  progress 92 "verifying"
  if ! grep -q 'macos-debloater' "$tmp" || ! bash -n "$tmp" 2>/dev/null; then
    printf '\n'
    echo "  ERROR: downloaded file is not a valid macos-debloater script." >&2
    echo "  Refusing to install a possibly-corrupt or tampered file." >&2
    exit 1
  fi

  if [[ ! -d "$(dirname "$DEST")" ]]; then
    printf '\n'
    echo "  ERROR: $(dirname "$DEST") does not exist; set DEST to a writable bin dir." >&2
    exit 1
  fi

  if [[ -w "$(dirname "$DEST")" ]]; then
    progress 96 "installing"
    install -m 0755 "$tmp" "$DEST" || { printf '\n'; echo "  ERROR: install failed." >&2; exit 1; }
  else
    progress 96 "installing (needs root)"
    sudo install -m 0755 "$tmp" "$DEST" || { printf '\n'; echo "  ERROR: install failed (sudo)." >&2; exit 1; }
  fi

  progress 100 "done"
  printf '\n\n'
  echo "  Run it (will auto-elevate with sudo):"
  printf '%b\n' "${GRN}  macos-debloater${RST}"
  echo ""
  echo "  SIP must be disabled for real runs. Dry-run, list, and restore work without it."
}

main
