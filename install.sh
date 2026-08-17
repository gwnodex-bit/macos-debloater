#!/bin/bash
# macos-debloater installer - single command, nothing else.
#
#   curl -fsSL https://raw.githubusercontent.com/xscope0/macos-debloater/main/install.sh | bash
#
# Downloads macos-debloater.sh from this repo, verifies it is a valid bash
# script, and installs it to /usr/local/bin. No telemetry, no analytics,
# nothing is run except the installer itself.
set -u

REPO_URL="${REPO_URL:-https://raw.githubusercontent.com/xscope0/macos-debloater/main}"
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

spinner() { # $1 = pid to watch
  local pid="$1" frames=('|' '/' '-' '\') i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s  Fetching macos-debloater.sh ...' "${frames[$i]}"
    i=$(( (i + 1) % 4 ))
    sleep 0.1
  done
  printf '\r'
  printf '%*s\r' 40 ""
}

main() {
  tmp="$(mktemp /tmp/macos-debloater.XXXXXX)" || exit 1
  trap 'rm -f "$tmp"' EXIT

  show_banner
  # printf %b so the DIM/RST escape codes are interpreted, not printed raw.
  printf '%b\n' "${DIM}  installing from $REPO_URL${RST}"
  echo ""

  curl -fsSL "$SRC" -o "$tmp" 2>/dev/null &
  local cpid=$!
  spinner "$cpid"
  wait "$cpid" || {
    echo "  ERROR: could not download $SRC" >&2
    echo "  Check the URL, your network, or set REPO_URL to a mirror." >&2
    exit 1
  }
  printf '%b\n' "${GRN}  OK${RST}  downloaded macos-debloater.sh ($(wc -c < "$tmp") bytes)"

  if ! grep -q 'macos-debloater' "$tmp" || ! bash -n "$tmp" 2>/dev/null; then
    echo "  ERROR: downloaded file is not a valid macos-debloater script." >&2
    echo "  Refusing to install a possibly-corrupt or tampered file." >&2
    exit 1
  fi
  printf '%b\n' "${GRN}  OK${RST}  verified (valid bash, macos-debloater)"

  if [[ ! -d "$(dirname "$DEST")" ]]; then
    echo "  ERROR: $(dirname "$DEST") does not exist; set DEST to a writable bin dir." >&2
    exit 1
  fi

  if [[ -w "$(dirname "$DEST")" ]]; then
    install -m 0755 "$tmp" "$DEST" || { echo "  ERROR: install failed." >&2; exit 1; }
  else
    echo "  (elevating: $(dirname "$DEST") needs root)"
    sudo install -m 0755 "$tmp" "$DEST" || { echo "  ERROR: install failed (sudo)." >&2; exit 1; }
  fi
  printf '%b\n' "${GRN}  OK${RST}  installed: $DEST"
  echo ""
  echo "  Run it (will auto-elevate with sudo):"
  printf '%b\n' "${GRN}  macos-debloater${RST}"
  echo ""
  echo "  SIP must be disabled for real runs. Dry-run, list, and restore work without it."
}

main
