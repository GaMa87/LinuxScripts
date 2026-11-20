#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
SYSTEMD_DIR="$HOME/.config/systemd/user"
SERVICE_NAME="appimage-watch.service"

if [[ "${1:-}" == "--uninstall" ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/$SERVICE_NAME"
    systemctl --user daemon-reload 2>/dev/null || true
  else
    rm -f "$SYSTEMD_DIR/$SERVICE_NAME"
  fi
  if [[ -L "$BIN_DIR/appimage-install" ]]; then
    rm -f "$BIN_DIR/appimage-install"
  fi
  echo "Uninstalled appimage-install CLI symlink and watcher service."
  echo "Note: Already installed AppImages in ~/Applications were kept."
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required." >&2
  exit 1
fi

if ! command -v inotifywait >/dev/null 2>&1; then
  echo "Warning: 'inotifywait' not found (required for automatic Downloads watching)." >&2
  if command -v omarchy >/dev/null 2>&1; then
    echo "  Install with: omarchy pkg add inotify-tools" >&2
  elif command -v pacman >/dev/null 2>&1; then
    echo "  Install with: sudo pacman -S inotify-tools" >&2
  elif command -v apt >/dev/null 2>&1; then
    echo "  Install with: sudo apt install inotify-tools" >&2
  elif command -v dnf >/dev/null 2>&1; then
    echo "  Install with: sudo dnf install inotify-tools" >&2
  elif command -v zypper >/dev/null 2>&1; then
    echo "  Install with: sudo zypper install inotify-tools" >&2
  else
    echo "  Install the 'inotify-tools' package for your distribution." >&2
  fi
fi

mkdir -p "$BIN_DIR" "$SYSTEMD_DIR"

chmod +x "$SCRIPT_DIR/appimage-install"
ln -sf "$SCRIPT_DIR/appimage-install" "$BIN_DIR/appimage-install"

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  # Cleanly reset any prior target symlink (e.g. if upgrading service unit)
  systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
  cp "$SCRIPT_DIR/$SERVICE_NAME" "$SYSTEMD_DIR/$SERVICE_NAME"
  systemctl --user daemon-reload
  systemctl --user enable --now "$SERVICE_NAME"
  systemctl --user restart "$SERVICE_NAME"
  SERVICE_STATUS="enabled & running"
else
  cp "$SCRIPT_DIR/$SERVICE_NAME" "$SYSTEMD_DIR/$SERVICE_NAME"
  SERVICE_STATUS="unit copied (systemd --user session not active; enable manually)"
fi

echo "Installed appimage-install:"
echo "  CLI:     $BIN_DIR/appimage-install -> $SCRIPT_DIR/appimage-install"
echo "  Service: $SYSTEMD_DIR/$SERVICE_NAME ($SERVICE_STATUS)"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo ""
    echo "Note: $BIN_DIR is not currently in your PATH."
    echo "Log out and back in, or add this to your shell rc (~/.bashrc or ~/.zshrc):"
    echo '  export PATH="$HOME/.local/bin:$PATH"'
    ;;
esac
