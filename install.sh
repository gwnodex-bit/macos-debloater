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

show_banner() {
  if [[ -t 1 ]]; then
    local line
    while IFS= read -r line; do
      printf '%b%s%b\n' "$MAG" "$line" "$RST"
      sleep 0.03
    done <<< "$BANNER"
    echo ""
  else
    printf '%s\n\n' "$BANNER"
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
  echo "${DIM}  installing from $REPO_URL${RST}"
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
