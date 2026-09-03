#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '\n==> %s\n' "$*"
}

require_root_or_sudo() {
  if ! command -v sudo >/dev/null 2>&1; then
    echo "Napaka: sudo ni nameščen." >&2
    exit 1
  fi
}

install_displaylink_dependencies() {
  log "Installing DisplayLink/EVDI dependencies"

  sudo apt-get update

  sudo apt-get install -y \
    dkms \
    libdrm-dev \
    evdi-dkms \
    "linux-headers-$(uname -r)"
}

install_displaylink_driver() {
  local installer_dir="${1:-$HOME/Downloads}"
  local installer

  installer="$(find "$installer_dir" -maxdepth 3 -type f \
    -name 'displaylink-driver-*.run' -print -quit 2>/dev/null || true)"

  if [[ -z "$installer" ]]; then
    echo "DisplayLink .run installer ni najden v: $installer_dir" >&2
    echo "Prenesi ga z https://www.displaylink.com/downloads/ubuntu" >&2
    return 1
  fi

  log "Installing DisplayLink driver from $installer"

  # /tmp se izogne težavam, če je Downloads mountan z noexec.
  local tmp_installer="/tmp/$(basename "$installer")"
  cp "$installer" "$tmp_installer"
  chmod +x "$tmp_installer"

  sudo "$tmp_installer"
}

configure_evdi() {
  log "Building and loading EVDI kernel module"

  sudo dkms autoinstall
  sudo depmod -a

  if ! lsmod | grep -q '^evdi'; then
    sudo modprobe evdi
  fi
}

start_displaylink_service() {
  log "Starting DisplayLink service"

  sudo systemctl daemon-reload
  sudo systemctl start displaylink-driver.service

  if ! systemctl is-active --quiet displaylink-driver.service; then
    echo "DisplayLink service se ni uspešno zagnal." >&2
    sudo systemctl status displaylink-driver.service --no-pager -l || true
    return 1
  fi
}

verify_displaylink() {
  log "Verifying DisplayLink installation"

  echo "Installed packages:"
  dpkg -l | grep -iE 'displaylink|evdi' || true

  echo
  echo "EVDI module:"
  lsmod | grep evdi || true

  echo
  echo "DisplayLink service:"
  systemctl status displaylink-driver.service --no-pager -l

  echo
  echo "Session type: ${XDG_SESSION_TYPE:-unknown}"
  echo
  echo "Display providers:"
  xrandr --listproviders 2>/dev/null || true
}

main() {
  require_root_or_sudo
  install_displaylink_dependencies

  # Če je driver že nameščen, namestitve ne ponavljamo.
  if dpkg-query -W -f='${Status}' displaylink-driver 2>/dev/null |
    grep -q 'install ok installed'; then
    log "DisplayLink driver is already installed"
  else
    install_displaylink_driver
  fi

  configure_evdi
  start_displaylink_service
  verify_displaylink

  cat <<'EOF'

DisplayLink installation je končana.

Priporočeno:
- uporabi "Ubuntu on Xorg" namesto Wayland;
- če si trenutno v Wayland session, se odjavi in izberi Ubuntu on Xorg;
- nato ponovno priklopi dock ali ponovno zaženi računalnik.

EOF
}

main "$@"
