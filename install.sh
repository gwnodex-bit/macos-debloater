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

main() {
  tmp="$(mktemp /tmp/macos-debloater.XXXXXX)" || exit 1
  trap 'rm -f "$tmp"' EXIT

  echo "Fetching macos-debloater.sh from $REPO_URL ..."
  if ! curl -fsSL "$SRC" -o "$tmp" 2>/dev/null; then
    echo "ERROR: could not download $SRC" >&2
    echo "Check the URL, your network, or set REPO_URL to a mirror." >&2
    exit 1
  fi

  if ! grep -q 'macos-debloater' "$tmp" || ! bash -n "$tmp" 2>/dev/null; then
    echo "ERROR: downloaded file is not a valid macos-debloater script." >&2
    echo "Refusing to install a possibly-corrupt or tampered file." >&2
    exit 1
  fi

  if [[ ! -d "$(dirname "$DEST")" ]]; then
    echo "ERROR: $(dirname "$DEST") does not exist; set DEST to a writable bin dir." >&2
    exit 1
  fi

  install -m 0755 "$tmp" "$DEST" || { echo "ERROR: install failed (need write access to $(dirname "$DEST")?)." >&2; exit 1; }
  echo "Installed: $DEST"
  echo ""
  echo "Run it (will auto-elevate with sudo):"
  echo "  macos-debloater"
  echo ""
  echo "SIP must be disabled for real runs. Dry-run, list, and restore work without it."
}

main
