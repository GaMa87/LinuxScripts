#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf '\n[OPOZORILO] %s\n' "$*" >&2
}

# Nastavi se na 1, če je za dokončanje potreben ponovni zagon (vpis MOK ključa).
NEED_REBOOT=0

require_root_or_sudo() {
  if ! command -v sudo >/dev/null 2>&1; then
    echo "Napaka: sudo ni nameščen." >&2
    exit 1
  fi
}

# Ultramarine/Fedora nima uradnega DisplayLink/evdi paketa - uporabimo
# skupnostni RPM iz https://github.com/displaylink-rpm/displaylink-rpm,
# ki evdi zgradi prek dkms ob namestitvi.
fedora_release_asset_url() {
  local version arch repo="displaylink-rpm/displaylink-rpm" api_url tag

  version="$(. /etc/os-release && echo "${VERSION_ID:-}")"
  [[ -n "$version" ]] || {
    echo "Ne najdem VERSION_ID v /etc/os-release." >&2
    return 1
  }

  arch="$(uname -m)"

  api_url="https://api.github.com/repos/${repo}/releases/latest"
  tag="$(curl -fsSL "$api_url" | jq -r '.tag_name // empty')"
  [[ -n "$tag" ]] || {
    echo "Ne najdem najnovejšega izdaje ${repo} (rate limit?)." >&2
    return 1
  }

  curl -fsSL "$api_url" |
    jq -r --arg pat "fedora-${version}-displaylink-.*\\.${arch}\\.rpm$" \
      '.assets[] | select(.name | test($pat)) | .browser_download_url' |
    head -n1
}

install_displaylink_dependencies() {
  log "Installing DisplayLink/EVDI dependencies"

  sudo dnf install -y \
    dkms \
    gcc \
    make \
    libdrm-devel \
    "kernel-devel-$(uname -r)" \
    "kernel-headers-$(uname -r)"
}

install_displaylink_driver() {
  local url tmp_rpm

  if rpm -q displaylink >/dev/null 2>&1; then
    log "DisplayLink driver is already installed"
    return 0
  fi

  log "Fetching latest DisplayLink RPM for this Fedora release"

  url="$(fedora_release_asset_url)"
  if [[ -z "$url" ]]; then
    echo "Ni najdenega DisplayLink RPM paketa za to Fedora/Ultramarine različico." >&2
    echo "Preveri https://github.com/displaylink-rpm/displaylink-rpm/releases" >&2
    return 1
  fi

  tmp_rpm="/tmp/$(basename "$url")"
  log "Installing DisplayLink driver from $url"
  curl -fsSL -o "$tmp_rpm" "$url"

  # %post skriptlet med namestitvijo tudi sam poskusi naložiti evdi in zagnati
  # storitev; če je vključen Secure Boot in MOK ključ še ni vpisan, to spodleti
  # (non-critical error) in dnf vrne napako, čeprav se paket dejansko namesti.
  sudo dnf install -y "$tmp_rpm" || true

  rpm -q displaylink >/dev/null 2>&1 || {
    echo "Namestitev DisplayLink RPM paketa ni uspela." >&2
    return 1
  }
}

# Če je Secure Boot vključen, mora biti DKMS-ov MOK ključ vpisan (enrolled),
# sicer jedro zavrne nalaganje samopodpisanega evdi modula.
handle_secure_boot_mok() {
  local mok_key="/var/lib/dkms/mok.pub"

  command -v mokutil >/dev/null 2>&1 || return 0
  mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled" || return 0
  [[ -f "$mok_key" ]] || return 0

  if mokutil --test-key "$mok_key" 2>/dev/null | grep -qi "already enrolled"; then
    return 0
  fi

  warn "Secure Boot je vključen, MOK ključ za evdi še ni vpisan."
  echo "Vpisujem DKMS MOK ključ - nastavi enkratno geslo, ko te program vpraša:" >&2
  sudo mokutil --import "$mok_key"
  NEED_REBOOT=1
}

configure_evdi() {
  log "Building and loading EVDI kernel module"

  sudo dkms autoinstall
  sudo depmod -a

  if lsmod | grep -q '^evdi'; then
    return 0
  fi

  if sudo modprobe evdi 2>/tmp/evdi-modprobe.err; then
    return 0
  fi

  if grep -qi "key was rejected" /tmp/evdi-modprobe.err; then
    handle_secure_boot_mok
  else
    cat /tmp/evdi-modprobe.err >&2
    return 1
  fi
}

start_displaylink_service() {
  log "Starting DisplayLink service"

  sudo systemctl daemon-reload
  sudo systemctl start displaylink-driver.service || true

  if ! systemctl is-active --quiet displaylink-driver.service; then
    if ((NEED_REBOOT)); then
      warn "Storitev se bo zagnala šele po ponovnem zagonu in vpisu MOK ključa."
      return 0
    fi
    echo "DisplayLink service se ni uspešno zagnal." >&2
    sudo systemctl status displaylink-driver.service --no-pager -l || true
    return 1
  fi
}

verify_displaylink() {
  log "Verifying DisplayLink installation"

  echo "Installed packages:"
  rpm -qa | grep -iE 'displaylink|evdi' || true

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
  install_displaylink_driver
  configure_evdi
  start_displaylink_service
  verify_displaylink

  if ((NEED_REBOOT)); then
    cat <<'EOF'

MOK ključ je vpisan, a za dokončanje je potreben ponovni zagon.

Naslednji koraki:
1. Ponovno zaženi računalnik.
2. Na modrem MokManager zaslonu izberi "Enroll MOK" -> "Continue" in vnesi
   geslo, ki si ga pravkar nastavil.
3. Po zagonu sistema poženi:
     sudo dkms autoinstall
     sudo systemctl restart displaylink-driver.service

EOF
  else
    cat <<'EOF'

DisplayLink installation je končana.

Priporočeno: po priklopu docka morda potrebuješ ponoven zagon plasma seje
ali sistema.

EOF
  fi
}

main "$@"
