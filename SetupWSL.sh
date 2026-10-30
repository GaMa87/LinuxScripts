#!/usr/bin/env bash
# ==============================================================================
# HEX-LAB V0.3 - WSL2 (WINDOWS 11) DEVELOPER ENVIRONMENT
# Requires: Windows 11 + WSL2, Ubuntu 22.04+ distro | Run as normal user with sudo access
#
# Usage (inside a WSL terminal, e.g. Ubuntu):
#   ./SetupWSL.sh --update                  # Update installed tools, preserve user configuration
#   ./SetupWSL.sh --update --only=lazygit   # Update selected tools only
#   Keep setup-update.sh next to this script when using --update.
#   ./SetupWSL.sh                      # All modules
#   ./SetupWSL.sh --list               # List modules
#   ./SetupWSL.sh --only=docker,nvim   # Selected modules only
#   ./SetupWSL.sh --skip=pyenv,fonts   # All except selected modules
#   GITHUB_TOKEN=ghp_... ./SetupWSL.sh # Authenticate GitHub API requests
#   HEXLAB_PY_FAST=1 ./SetupWSL.sh     # Build Python without PGO/LTO
# ==============================================================================

# Must be executed (./SetupWSL.sh), not sourced - sourcing leaks pyenv's PYENV_DIR
# (pointing at the temp workdir) into the interactive shell, breaking it once
# the workdir is removed at the end of the script.
(return 0 2>/dev/null) && {
  echo "Do not source this script; run it with: ./SetupWSL.sh" >&2
  return 1
}

set -Eeuo pipefail

UPDATE_MODE=0
UPDATE_PLATFORM=wsl
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for arg in "$@"; do [[ "$arg" == --update ]] && UPDATE_MODE=1; done
if ((UPDATE_MODE)); then
  source "$SCRIPT_DIR/setup-update.sh"
fi
run_selected_module() {
  if ((UPDATE_MODE)); then update_module "$1"; else "mod_$1"; fi
}

# Unset any inherited CA overrides that might point to non-Ubuntu paths
# (e.g. CURL_CA_BUNDLE=/etc/pki/... from RHEL/Fedora environments)
unset CURL_CA_BUNDLE SSL_CERT_FILE

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
info() { echo -e "${CYAN}[HEX-LAB]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die() {
  echo -e "${RED}[FAIL]${NC} $*" >&2
  exit 1
}

# Deferred messages printed in the final banner (re-login hints etc.)
declare -a POST_NOTES=()
note() { POST_NOTES+=("$*"); }

LOG_DIR="$HOME/.local/state/hex-lab"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/wslsetup_$(date +%Y%m%d_%H%M%S).log"

# Keep a full transcript so failures are debuggable even if the terminal closes.
if [[ -t 1 ]]; then
  exec > >(
    trap '' ERR
    tee -a "$LOG_FILE"
  ) 2>&1
else
  exec >>"$LOG_FILE" 2>&1
fi

# --- Interactive I/O helpers (stdout is a tee pipe, so prompt via /dev/tty) ---
HAVE_TTY=0
[[ -e /dev/tty ]] && exec 3<>/dev/tty 2>/dev/null && HAVE_TTY=1

ask() { # ask <prompt> <varname>  -> returns 1 if no tty
  local _p="$1" _v="$2" _a=""
  ((HAVE_TTY)) || return 1
  printf '%b' "${CYAN}${_p}${NC}" >&3
  IFS= read -r _a <&3 || return 1
  printf -v "$_v" '%s' "$_a"
}

pause_tty() {
  ((HAVE_TTY)) || return 0
  printf '%b' "Press Enter to close..." >&3
  read -r _ <&3 || true
}

# ==============================================================================
# 0. PRE-FLIGHT
# ==============================================================================
grep -qi microsoft /proc/version 2>/dev/null || [[ -n "${WSL_DISTRO_NAME:-}" ]] ||
  die "Ta skripta je namenjena zagonu znotraj WSL2 (Windows 11), ne golega Linuxa."

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *debian* ]] ||
    warn "Netestiran distro: ${ID:-unknown} — nadaljujem na lastno odgovornost."
  if [[ "${ID:-}" == "ubuntu" ]]; then
    ((${VERSION_ID%%.*} >= 22)) || die "Potreben Ubuntu 22.04+ (zaznan ${VERSION_ID})."
  fi
fi

[[ $EUID -eq 0 ]] && die "Ne poganjaj kot root — skripta uporablja sudo, kjer je potrebno."

ARCH=$(uname -m)
case "$ARCH" in
x86_64)
  ARCH_ALT="x86_64"
  ARCH_GO="amd64"
  ;;
aarch64)
  ARCH_ALT="arm64"
  ARCH_GO="arm64"
  ;;
*) die "Unsupported architecture: $ARCH" ;;
esac

info "WSL distro: ${WSL_DISTRO_NAME:-neznano}"
info "Architecture: $ARCH"
info "Log file: $LOG_FILE"

# --- sudo keepalive: pyenv compile can take 15+ min and the timestamp expires --
info "Preverjam sudo dostop..."
if ((HAVE_TTY)); then
  sudo -v </dev/tty || die "Potrebujem sudo."
else
  sudo -n true 2>/dev/null || die "Potrebujem sudo (neinteraktivni zagon: najprej 'sudo -v')."
fi
(while true; do
  sudo -n true 2>/dev/null
  sleep 50
  kill -0 "$$" 2>/dev/null || exit
done) 2>/dev/null &
SUDO_KEEPALIVE_PID=$!

WORK_DIR=$(mktemp -d)
ORIG_DIR=$(pwd)
cleanup() {
  local rc=$?
  kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  [[ -d "$ORIG_DIR" ]] && cd "$ORIG_DIR" || true
  rm -rf "$WORK_DIR"
  ((rc != 0)) && warn "Script failed/interrupted — temp files cleaned."
  return 0
}
trap cleanup EXIT
trap 'rc=$?;
      echo -e "${RED}[FAIL]${NC} Error at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2;
      echo -e "${YELLOW}[WARN]${NC} Full log: ${LOG_FILE}" >&2;
      pause_tty; exit ${rc}' ERR
cd "$WORK_DIR"

# ==============================================================================
# HELPERS
# ==============================================================================
extract_semver() { sed -nE 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -1; }

# version_ge <have> <min>  — proper semver compare via sort -V
version_ge() {
  [[ -n "${1:-}" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

backup_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local backup="${file}.backup_$(date +%Y%m%d_%H%M%S)"
    cp "$file" "$backup"
    warn "Existing $(basename "$file") backed up → $backup"
  fi
}

# gh_latest_tag <owner/repo>  — API first (with token if present), HTTP redirect fallback.
# Prevents the classic "jq returns null on 403 rate limit -> tar xf on an HTML page".
gh_latest_tag() {
  local repo="$1" tag="" hdr=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && hdr=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  tag=$(curl -fsSL --retry 3 --retry-delay 2 "${hdr[@]}" \
    "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null |
    jq -r '.tag_name // empty' 2>/dev/null || true)
  if [[ -z "$tag" ]]; then
    # Fallback: follow the /releases/latest redirect and read the tag from Location.
    tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      "https://github.com/${repo}/releases/latest" 2>/dev/null |
      sed -nE 's#.*/tag/(.+)$#\1#p' || true)
  fi
  [[ -z "$tag" || "$tag" == "null" ]] &&
    die "GitHub ni vrnil tag-a za ${repo} (rate limit? nastavi GITHUB_TOKEN)"
  echo "$tag"
}

# fetch <url> <dest> — download + verify it is not an HTML error page
fetch() {
  local url="$1" dest="$2"
  curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url" ||
    die "Prenos ni uspel: $url"
  [[ -s "$dest" ]] || die "Prenesena datoteka je prazna: $url"
  if file -b "$dest" | grep -qiE 'html|ascii text|json'; then
    die "Prenos ni binarni arhiv (verjetno error page): $url"
  fi
}

have() { command -v "$1" &>/dev/null; }

# ==============================================================================
# WSL: systemd is off by default — enable it in /etc/wsl.conf (docker, cron …)
# ==============================================================================
info "Preverjam /etc/wsl.conf (systemd)..."
if (( ! UPDATE_MODE )) && ! grep -q '^systemd=true' /etc/wsl.conf 2>/dev/null; then
  [[ -f /etc/wsl.conf ]] && sudo cp /etc/wsl.conf "/etc/wsl.conf.backup_$(date +%Y%m%d_%H%M%S)"
  sudo tee /etc/wsl.conf >/dev/null <<'WSLCONF'
[boot]
systemd=true

[interop]
enabled=true
appendWindowsPath=true

[automount]
enabled=true
options="metadata,umask=22,fmask=11"
WSLCONF
  note "Omogočil sem systemd v /etc/wsl.conf — iz Windows PowerShella poženi 'wsl --shutdown', nato znova odpri WSL terminal."
fi
if ps -p 1 -o comm= 2>/dev/null | grep -q systemd; then
  success "systemd aktiven (PID 1)."
else
  warn "systemd (še) ni aktiven — servisi (npr. docker) bodo pognani ročno prek 'service'."
fi

# ==============================================================================
# MODULE SELECTION
# ==============================================================================
ALL_MODULES=(
  base docker node golang pyenv uv lazygit nvim eza fonts vscode
  claude ohmyzsh gdu delta atuin hyperfine lazydocker yazi devtools embedded
  tealdeer fastfetch gitcfg zshrc shell
)
RUN_MODULES=("${ALL_MODULES[@]}")
declare -a SKIP_MODULES=()

for arg in "$@"; do
  case "$arg" in
  --update) ;;
  --list)
    printf 'Moduli: %s\n' "${ALL_MODULES[*]}"
    exit 0
    ;;
  --only=*)
    IFS=',' read -r -a RUN_MODULES <<<"${arg#--only=}"
    ;;
  --skip=*)
    IFS=',' read -r -a SKIP_MODULES <<<"${arg#--skip=}"
    ;;
  -h | --help)
    sed -n '2,20p' "$0"
    exit 0
    ;;
  *) die "Neznan argument: $arg (uporabi --help)" ;;
  esac
done

should_run() {
  local m="$1" x
  for x in "${SKIP_MODULES[@]:-}"; do [[ "$x" == "$m" ]] && return 1; done
  for x in "${RUN_MODULES[@]}"; do [[ "$x" == "$m" ]] && return 0; done
  return 1
}

# ==============================================================================
# 1. BASE — SYSTEM PACKAGES
# ==============================================================================
mod_base() {
  info "Installing system packages..."
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends \
    curl wget git build-essential cmake ninja-build pkg-config \
    python3-pip python3-venv pipx \
    ripgrep fd-find bat file \
    zoxide fzf btop fastfetch zsh libusb-1.0-0-dev tealdeer fontconfig lsof \
    libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
    libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev \
    libgdbm-dev uuid-dev libnsl-dev \
    unzip zstd p7zip-full ca-certificates gnupg jq xclip \
    fonts-noto-color-emoji

  # On Ubuntu/Debian, fd-find installs as fdfind and bat as batcat
  [[ ! -e /usr/local/bin/fd ]] && have fdfind && sudo ln -sf "$(command -v fdfind)" /usr/local/bin/fd
  [[ ! -e /usr/local/bin/bat ]] && have batcat && sudo ln -sf "$(command -v batcat)" /usr/local/bin/bat
  success "System packages done."
}

# ==============================================================================
# 2. DOCKER ENGINE (native v WSL2, ali Docker Desktop integracija)
# ==============================================================================
mod_docker() {
  if have docker && docker info 2>/dev/null | grep -qi "Docker Desktop"; then
    success "Docker Desktop WSL integracija zaznana ($(docker --version 2>/dev/null | extract_semver)) — preskakujem Docker Engine."
    return 0
  fi

  if ! have docker; then
    info "Installing Docker Engine (native, znotraj WSL)..."
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
      sudo gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
      sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
    success "Docker Engine installed."
  fi

  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    sudo usermod -aG docker "$USER"
    note "Dodan si v skupino 'docker' — potreben je nov WSL terminal (ali 'wsl --shutdown' iz Windows)."
  fi

  # Without systemd the daemon does not start with the WSL distro
  if ! docker info &>/dev/null; then
    if systemctl is-system-running &>/dev/null; then
      sudo systemctl enable --now docker
    else
      sudo service docker start || true
      note "systemd ni aktiven — po vsakem zagonu WSL poženi: sudo service docker start"
    fi
  fi
  success "docker $(docker --version 2>/dev/null | extract_semver)"
}

# ==============================================================================
# 3. NODE.JS LTS (NodeSource — apt ships outdated versions)
# ==============================================================================
mod_node() {
  if ! have node; then
    info "Installing Node.js LTS..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs
  fi
  success "Node $(node --version) / npm $(npm --version)"
}

# ==============================================================================
# 4. GOLANG (official binary — proper semver check, no lexicographic compare)
# ==============================================================================
GO_MIN="1.22"
mod_golang() {
  local cur=""
  have go && cur=$(go version 2>/dev/null | grep -oP 'go\K[0-9]+\.[0-9]+(\.[0-9]+)?' || true)

  if ! version_ge "$cur" "$GO_MIN"; then
    local gover
    gover=$(curl -fsSL "https://go.dev/dl/?mode=json" | jq -r '.[0].version' | sed 's/^go//')
    [[ -z "$gover" || "$gover" == "null" ]] && die "Ne morem ugotoviti zadnje Go verzije."
    info "Installing Go ${gover} (trenutno: ${cur:-none})..."
    fetch "https://go.dev/dl/go${gover}.linux-${ARCH_GO}.tar.gz" go.tar.gz
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf go.tar.gz
    sudo ln -sf /usr/local/go/bin/go /usr/local/bin/go
    sudo ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  fi
  success "Go $(go version)"
}

# ==============================================================================
# 5. PYENV & PYTHON (latest 3.12.x patch — auto-resolved)
# ==============================================================================
mod_pyenv() {
  info "Setting up pyenv..."
  [[ -d "$HOME/.pyenv" ]] || curl -fsSL https://pyenv.run | bash

  export PYENV_ROOT="$HOME/.pyenv"
  export PATH="$PYENV_ROOT/bin:$PATH"
  eval "$(pyenv init --path)"
  eval "$(pyenv init -)"
  # pyenv exports PYENV_DIR=$(pwd) (currently the temp workdir); drop it so it
  # can't outlive this script once WORK_DIR is gone.
  unset PYENV_DIR

  local pyver
  pyver=$(pyenv install --list | grep -E '^\s+3\.12\.[0-9]+$' | tail -1 | tr -d ' ')
  [[ -z "$pyver" ]] && die "Ne najdem nobene 3.12.x verzije v pyenv seznamu."
  info "Latest Python 3.12 patch: $pyver"

  if ! pyenv versions --bare | grep -qx "$pyver"; then
    local opts="--enable-optimizations --with-lto"
    if [[ -n "${HEXLAB_PY_FAST:-}" ]]; then
      opts="--enable-shared"
      info "HEXLAB_PY_FAST=1 — build brez PGO/LTO (nekajkrat hitreje)."
    else
      info "Compiling Python $pyver with PGO+LTO (10-20 min)... za hiter build: HEXLAB_PY_FAST=1"
    fi
    PYTHON_CONFIGURE_OPTS="$opts" \
      PYTHON_MAKE_OPTS="-j$(nproc)" \
      MAKE_OPTS="-j$(nproc)" \
      pyenv install "$pyver"
  fi
  pyenv global "$pyver"
  success "$(python --version)"
}

# ==============================================================================
# 6. UV — fast Python package/tool manager
# ==============================================================================
mod_uv() {
  if ! have uv && [[ ! -x "$HOME/.local/bin/uv" ]]; then
    info "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi
  export PATH="$HOME/.local/bin:$PATH"
  have uv || {
    warn "uv ni na PATH — preskakujem tool install."
    return 0
  }
  uv tool install --quiet ruff 2>/dev/null || warn "uv tool install ruff failed"
  uv tool install --quiet esptool 2>/dev/null || warn "uv tool install esptool failed"
  success "uv $(uv --version | extract_semver)"
}

# ==============================================================================
# 7. LAZYGIT
# ==============================================================================
mod_lazygit() {
  if ! have lazygit || ! lazygit --version &>/dev/null; then
    info "Installing Lazygit..."
    local tag ver
    tag=$(gh_latest_tag jesseduffield/lazygit)
    ver="${tag#v}"
    fetch "https://github.com/jesseduffield/lazygit/releases/download/${tag}/lazygit_${ver}_Linux_${ARCH_ALT}.tar.gz" lazygit.tar.gz
    tar xf lazygit.tar.gz lazygit
    sudo install lazygit /usr/local/bin
  fi
  success "Lazygit $(lazygit --version 2>/dev/null | grep -oP 'version=\K[^,]+' || echo unknown)"

  info "Writing lazygit config..."
  local lg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/lazygit"
  mkdir -p "$lg_dir"
  backup_if_exists "$lg_dir/config.yml"
  cat >"$lg_dir/config.yml" <<'YML'
gui:
  showIcons: true
  nerdFontsVersion: "3"
  showCommandLog: false
  sidePanelWidth: 0.3
  mainPanelSplitMode: flexible
git:
  paging:
    colorArg: always
    pager: delta --dark --paging=never
  autoFetch: true
os:
  editPreset: nvim
keybinding:
  universal:
    quit: q
YML
  success "lazygit config written."
}

# ==============================================================================
# 8. NEOVIM + LAZYVIM (+ providers + headless bootstrap)
# ==============================================================================
NVIM_MIN_VERSION="0.9.0"
mod_nvim() {
  local nvim_bin nvim_ver=""
  nvim_bin="$(command -v nvim || true)"

  if [[ -n "$nvim_bin" ]] && "$nvim_bin" --version &>/dev/null; then
    mapfile -t nvim_paths < <(which -a nvim 2>/dev/null | awk '!seen[$0]++')
    if ((${#nvim_paths[@]} > 1)); then
      warn "Multiple nvim binaries detected: ${nvim_paths[*]}"
      info "Using first nvim in PATH: $nvim_bin"
    fi
    nvim_ver=$("$nvim_bin" --version | head -1 | sed -nE 's/^NVIM v([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
  fi

  if ! version_ge "$nvim_ver" "$NVIM_MIN_VERSION"; then
    info "Installing Neovim..."
    # Modern releases: nvim-linux-x86_64.tar.gz / nvim-linux-arm64.tar.gz
    # Older (<0.10.4) x86 releases used nvim-linux64.tar.gz — keep a fallback.
    if ! fetch "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${ARCH_ALT}.tar.gz" nvim.tar.gz 2>/dev/null; then
      warn "nvim-linux-${ARCH_ALT}.tar.gz ni na voljo — poskušam legacy ime."
      fetch "https://github.com/neovim/neovim/releases/latest/download/nvim-linux64.tar.gz" nvim.tar.gz
    fi
    local nvim_dir
    nvim_dir=$(tar -tf nvim.tar.gz | head -1 | cut -d/ -f1)
    [[ -z "$nvim_dir" ]] && die "Unable to determine Neovim directory from archive"
    sudo rm -rf "/opt/${nvim_dir}" /opt/nvim
    sudo tar -C /opt -xzf nvim.tar.gz
    sudo ln -sf "/opt/${nvim_dir}/bin/nvim" /usr/local/bin/nvim
    nvim_bin="/usr/local/bin/nvim"
  fi
  success "$($nvim_bin --version | head -1) ($nvim_bin)"

  # --- Providers (silences most :checkhealth warnings) ---
  info "Installing Neovim providers..."
  if have uv; then
    uv tool install --quiet pynvim 2>/dev/null || pipx install pynvim 2>/dev/null || true
  else
    pipx install pynvim 2>/dev/null || pip3 install --user --quiet pynvim || true
  fi
  if have npm; then
    sudo npm install -g --silent neovim tree-sitter-cli 2>/dev/null ||
      warn "npm global install (neovim, tree-sitter-cli) ni uspel."
  fi

  # --- LazyVim starter ---
  if [[ ! -f "$HOME/.config/nvim/lua/config/lazy.lua" ]]; then
    if [[ -d "$HOME/.config/nvim" ]]; then
      local nvim_backup="$HOME/.config/nvim.backup_$(date +%Y%m%d_%H%M%S)"
      mv "$HOME/.config/nvim" "$nvim_backup"
      warn "Existing nvim config backed up -> $nvim_backup"
    fi
    info "Cloning LazyVim starter..."
    git clone --depth=1 https://github.com/LazyVim/starter ~/.config/nvim
    rm -rf ~/.config/nvim/.git
  else
    success "LazyVim config already present — skipping clone."
  fi

  info "Bootstrapping LazyVim plugins (headless)..."
  "$nvim_bin" --headless "+Lazy! sync" +qa 2>/dev/null ||
    warn "Lazy sync ni uspel — zaženi 'nvim' ročno in počakaj na install."
  success "LazyVim ready."
}

# ==============================================================================
# 9. EZA (official deb repo)
# ==============================================================================
mod_eza() {
  if ! have eza; then
    info "Installing eza..."
    sudo mkdir -p /etc/apt/keyrings
    wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc |
      sudo gpg --yes --dearmor -o /etc/apt/keyrings/gierens.gpg
    echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" |
      sudo tee /etc/apt/sources.list.d/gierens.list >/dev/null
    sudo chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
    sudo apt-get update -qq && sudo apt-get install -y eza
  fi
  success "eza $(eza --version | tail -1)"
}

# ==============================================================================
# 10. NERD FONT — JetBrainsMono (WSL + Windows, for Windows Terminal)
# ==============================================================================
mod_fonts() {
  local font_dir="$HOME/.local/share/fonts"
  local font_dest="$font_dir/JetBrainsMono"
  if compgen -G "$font_dest/*.ttf" >/dev/null 2>&1; then
    success "JetBrainsMono Nerd Font already present in WSL — skipping download."
  else
    info "Installing JetBrainsMono Nerd Font (WSL side)..."
    mkdir -p "$font_dest"
    local tag
    tag=$(gh_latest_tag ryanoasis/nerd-fonts)
    fetch "https://github.com/ryanoasis/nerd-fonts/releases/download/${tag}/JetBrainsMono.zip" JetBrainsMono.zip
    unzip -oq JetBrainsMono.zip -d "$font_dest"
    fc-cache -f "$font_dir" >/dev/null 2>&1
    success "JetBrainsMono Nerd Font installed in WSL (${tag})."
  fi

  # Windows Terminal renders with Windows-side fonts, not Linux fontconfig
  if ! have powershell.exe; then
    note "powershell.exe ni na voljo — nastavi JetBrainsMono Nerd Font ročno v Windows Terminal."
    return 0
  fi
  info "Nameščam pisavo tudi v Windows (za Windows Terminal)..."
  local win_local_appdata win_fonts_wsl
  win_local_appdata=$(powershell.exe -NoProfile -Command '[Environment]::GetFolderPath("LocalApplicationData")' 2>/dev/null | tr -d '\r')
  win_fonts_wsl=$([[ -n "$win_local_appdata" ]] && wslpath -u "${win_local_appdata}\Microsoft\Windows\Fonts" 2>/dev/null || true)
  if [[ -z "$win_fonts_wsl" ]]; then
    warn "Ne najdem Windows Fonts mape — nameščanje pisave v Windows preskočeno."
    return 0
  fi
  mkdir -p "$win_fonts_wsl"
  cp -n "$font_dest"/*.ttf "$win_fonts_wsl/" 2>/dev/null || true
  powershell.exe -NoProfile -Command '
    $fontsFolder = [Environment]::GetFolderPath("LocalApplicationData") + "\Microsoft\Windows\Fonts"
    Get-ChildItem $fontsFolder -Filter "*.ttf" | ForEach-Object {
      New-ItemProperty -Name ($_.BaseName + " (TrueType)") -Path "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts" -PropertyType String -Value $_.FullName -Force | Out-Null
    }
  ' >/dev/null 2>&1 || warn "Registracija pisave v Windows ni uspela — dodaj jo ročno (Settings > Fonts)."
  success "Pisava nameščena v Windows."
  note "Windows Terminal: Settings > Profiles > Appearance > Font face: JetBrainsMono Nerd Font."
}

# ==============================================================================
# 12. VISUAL STUDIO CODE (Windows side + WSL extension — 'code' comes via Windows PATH)
# ==============================================================================
mod_vscode() {
  if ! have code; then
    if have winget.exe; then
      info "Installing Visual Studio Code on Windows (winget)..."
      winget.exe install -e --id Microsoft.VisualStudioCode --silent \
        --accept-package-agreements --accept-source-agreements ||
        warn "winget install VS Code ni uspel — namesti ga ročno na Windows."
      note "VS Code nameščen na Windows — odpri nov WSL terminal, da 'code' pride na PATH."
    else
      note "VS Code ni najden — namesti ga na Windows (https://code.visualstudio.com), nato v WSL poženi 'code .'."
      return 0
    fi
  fi
  # The WSL extension must live on the Windows side; cwd on /mnt/c avoids cmd.exe's UNC warning
  if have cmd.exe; then
    (cd /mnt/c && cmd.exe /c "code --install-extension ms-vscode-remote.remote-wsl --force") >/dev/null 2>&1 ||
      warn "Namestitev WSL extensiona ni uspela — namesti 'WSL' extension ročno."
  fi
  have code && success "code (Windows) dosegljiv iz WSL: $(command -v code)"
  return 0
}

# ==============================================================================
# 12b. CLAUDE CODE (native installer -> ~/.local/bin/claude, self-updating)
# ==============================================================================
mod_claude() {
  export PATH="$HOME/.local/bin:$PATH"
  if ! have claude; then
    info "Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash
  fi
  have claude || {
    warn "Claude Code install ni uspel."
    return 1
  }
  success "claude $(claude --version 2>/dev/null | extract_semver)"
  note "Prijavi se v Claude Code: zaženi 'claude' (prvi zagon odpre prijavo)."
}

# ==============================================================================
# 13. OH-MY-ZSH + PLUGINS + POWERLEVEL10K
# ==============================================================================
mod_ohmyzsh() {
  info "Setting up Oh-My-Zsh..."
  if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
  fi

  local zsh_custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

  [[ -d "$zsh_custom/themes/powerlevel10k" ]] ||
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$zsh_custom/themes/powerlevel10k"
  [[ -d "$zsh_custom/plugins/zsh-autosuggestions" ]] ||
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$zsh_custom/plugins/zsh-autosuggestions"
  [[ -d "$zsh_custom/plugins/zsh-syntax-highlighting" ]] ||
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting "$zsh_custom/plugins/zsh-syntax-highlighting"

  [[ -f "$HOME/.p10k.zsh" ]] ||
    note "~/.p10k.zsh ne obstaja — ob prvem zagonu zsh te pričaka 'p10k configure' wizard."

  success "Zsh plugins installed."
}

# ==============================================================================
# 13. GDU — fast disk usage TUI
# ==============================================================================
mod_gdu() {
  if ! have gdu; then
    info "Installing gdu..."
    local tag
    tag=$(gh_latest_tag dundee/gdu)
    fetch "https://github.com/dundee/gdu/releases/download/${tag}/gdu_linux_${ARCH_GO}.tgz" gdu.tgz
    tar xf gdu.tgz
    local bin
    bin=$(find . -maxdepth 2 -name 'gdu_linux_*' -type f | head -1)
    [[ -z "$bin" ]] && bin=$(find . -maxdepth 2 -name 'gdu*' -type f -executable | head -1)
    [[ -z "$bin" ]] && die "gdu binary not found in archive"
    sudo install "$bin" /usr/local/bin/gdu
  fi
  success "gdu $(gdu --version 2>&1 | extract_semver)"
}

# ==============================================================================
# 14. DELTA — better git diff pager
# ==============================================================================
mod_delta() {
  if ! have delta; then
    info "Installing delta..."
    local tag ver darch
    tag=$(gh_latest_tag dandavison/delta)
    ver="${tag#v}"
    case "$ARCH" in
    x86_64) darch="x86_64-unknown-linux-musl" ;;
    aarch64) darch="aarch64-unknown-linux-gnu" ;;
    esac
    # delta tags carry no leading "v" -> use the normalized version in the filename
    fetch "https://github.com/dandavison/delta/releases/download/${tag}/delta-${ver}-${darch}.tar.gz" delta.tar.gz
    tar xf delta.tar.gz
    local bin
    bin=$(find . -name 'delta' -type f | head -1)
    [[ -z "$bin" ]] && die "delta binary not found in archive"
    sudo install "$bin" /usr/local/bin/delta
  fi
  success "delta $(delta --version | extract_semver)"
}

# ==============================================================================
# 15. ATUIN — shell history sync & search
# ==============================================================================
mod_atuin() {
  if ! have atuin; then
    info "Installing atuin..."
    local tag aarch
    tag=$(gh_latest_tag atuinsh/atuin)
    case "$ARCH" in
    x86_64) aarch="x86_64-unknown-linux-musl" ;;
    aarch64) aarch="aarch64-unknown-linux-musl" ;;
    esac
    fetch "https://github.com/atuinsh/atuin/releases/download/${tag}/atuin-${aarch}.tar.gz" atuin.tar.gz
    tar xf atuin.tar.gz
    local bin
    bin=$(find . -name 'atuin' -type f | head -1)
    [[ -z "$bin" ]] && die "atuin binary not found in archive"
    sudo install "$bin" /usr/local/bin/atuin
  fi
  success "atuin $(atuin --version | extract_semver)"
}

# ==============================================================================
# 16. HYPERFINE — command-line benchmarking
# ==============================================================================
mod_hyperfine() {
  if ! have hyperfine; then
    info "Installing hyperfine..."
    local tag ver harch
    tag=$(gh_latest_tag sharkdp/hyperfine)
    ver="${tag#v}"
    case "$ARCH" in
    x86_64) harch="x86_64-unknown-linux-musl" ;;
    aarch64) harch="aarch64-unknown-linux-gnu" ;;
    esac
    fetch "https://github.com/sharkdp/hyperfine/releases/download/v${ver}/hyperfine-v${ver}-${harch}.tar.gz" hyperfine.tar.gz
    tar xf hyperfine.tar.gz
    local bin
    bin=$(find . -name 'hyperfine' -type f | head -1)
    [[ -z "$bin" ]] && die "hyperfine binary not found in archive"
    sudo install "$bin" /usr/local/bin/hyperfine
  fi
  success "hyperfine $(hyperfine --version | extract_semver)"
}

# ==============================================================================
# 17. LAZYDOCKER — Docker TUI
# ==============================================================================
mod_lazydocker() {
  if ! have lazydocker; then
    info "Installing lazydocker..."
    local tag ver
    tag=$(gh_latest_tag jesseduffield/lazydocker)
    ver="${tag#v}"
    fetch "https://github.com/jesseduffield/lazydocker/releases/download/${tag}/lazydocker_${ver}_Linux_${ARCH_ALT}.tar.gz" lazydocker.tar.gz
    tar xf lazydocker.tar.gz lazydocker
    sudo install lazydocker /usr/local/bin
  fi
  local v
  v=$(lazydocker --version 2>/dev/null | extract_semver)
  success "lazydocker ${v:-unknown}"
}

# ==============================================================================
# 17b. YAZI — terminal file manager
# ==============================================================================
mod_yazi() {
  if ! have yazi; then
    info "Installing yazi..."
    local tag yarch
    tag=$(gh_latest_tag sxyazi/yazi)
    case "$ARCH" in
    x86_64) yarch="x86_64-unknown-linux-musl" ;;
    aarch64) yarch="aarch64-unknown-linux-musl" ;;
    esac
    fetch "https://github.com/sxyazi/yazi/releases/download/${tag}/yazi-${yarch}.zip" yazi.zip
    unzip -oq yazi.zip
    local bin
    for bin in yazi ya; do
      local f
      f=$(find . -name "$bin" -type f | head -1)
      [[ -z "$f" ]] && die "$bin binary not found in archive"
      sudo install "$f" "/usr/local/bin/$bin"
    done
  fi
  success "yazi $(yazi --version | extract_semver)"
}

# ==============================================================================
# 18. DEVTOOLS — gh, direnv, just, dust
# ==============================================================================
mod_devtools() {
  # --- GitHub CLI (also fixes API rate limits: gh auth token) ---
  if ! have gh; then
    info "Installing GitHub CLI..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg |
      sudo dd of=/etc/apt/keyrings/githubcli-archive-keyring.gpg status=none
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" |
      sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -qq && sudo apt-get install -y gh
    note "Prijavi se v GitHub CLI: gh auth login"
  fi
  success "gh $(gh --version | extract_semver)"

  # --- direnv (per-project env: IDF_PATH, target chip, secrets) ---
  have direnv || {
    info "Installing direnv..."
    sudo apt-get install -y direnv
  }
  success "direnv $(direnv version 2>/dev/null || echo unknown)"

  # --- just (command runner) ---
  if ! have just; then
    info "Installing just..."
    local tag jarch
    tag=$(gh_latest_tag casey/just)
    case "$ARCH" in
    x86_64) jarch="x86_64-unknown-linux-musl" ;;
    aarch64) jarch="aarch64-unknown-linux-musl" ;;
    esac
    fetch "https://github.com/casey/just/releases/download/${tag}/just-${tag}-${jarch}.tar.gz" just.tar.gz
    tar xf just.tar.gz just
    sudo install just /usr/local/bin
  fi
  success "just $(just --version | extract_semver)"

  # --- dust (non-TUI disk usage) ---
  if ! have dust; then
    info "Installing dust..."
    local tag ver darch
    tag=$(gh_latest_tag bootandy/dust)
    ver="${tag#v}"
    case "$ARCH" in
    x86_64) darch="x86_64-unknown-linux-musl" ;;
    aarch64) darch="aarch64-unknown-linux-musl" ;;
    esac
    if fetch "https://github.com/bootandy/dust/releases/download/${tag}/dust-v${ver}-${darch}.tar.gz" dust.tar.gz 2>/dev/null; then
      tar xf dust.tar.gz
      local bin
      bin=$(find . -name 'dust' -type f | head -1)
      [[ -n "$bin" ]] && sudo install "$bin" /usr/local/bin/dust
    else
      warn "dust download failed — preskočeno (ni kritično)."
    fi
  fi
  have dust && success "dust $(dust --version | extract_semver)"
}

# ==============================================================================
# 19. EMBEDDED TOOLCHAIN — serial access, debuggers, udev rules
# ==============================================================================
mod_embedded() {
  info "Installing embedded toolchain..."
  sudo apt-get install -y --no-install-recommends \
    gdb-multiarch openocd minicom picocom screen \
    clangd clang-format clang-tidy \
    device-tree-compiler srecord usbutils

  # --- dialout group: without this every flash/monitor needs sudo ---
  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx dialout; then
    sudo usermod -aG dialout "$USER"
    note "Dodan si v skupino 'dialout' — potreben je nov WSL terminal za serial dostop."
  fi

  # --- udev rules for common USB-serial bridges + native USB MCUs ---
  info "Writing udev rules for USB-serial adapters..."
  sudo tee /etc/udev/rules.d/99-hexlab-embedded.rules >/dev/null <<'RULES'
# HEX-LAB: USB-serial bridges and native-USB MCUs -> group dialout, no sudo needed
# Silicon Labs CP210x
SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", MODE="0660", GROUP="dialout", TAG+="uaccess"
# FTDI
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", MODE="0660", GROUP="dialout", TAG+="uaccess"
# WCH CH340/CH341
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", MODE="0660", GROUP="dialout", TAG+="uaccess"
# Espressif native USB (ESP32-S2/S3/C3)
SUBSYSTEM=="tty", ATTRS{idVendor}=="303a", MODE="0660", GROUP="dialout", TAG+="uaccess"
SUBSYSTEM=="usb", ATTRS{idVendor}=="303a", MODE="0660", GROUP="dialout", TAG+="uaccess"
# ST-Link v2/v2.1/v3
SUBSYSTEM=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="374*", MODE="0660", GROUP="dialout", TAG+="uaccess"
SUBSYSTEM=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="3748", MODE="0660", GROUP="dialout", TAG+="uaccess"
# SEGGER J-Link
SUBSYSTEM=="usb", ATTRS{idVendor}=="1366", MODE="0660", GROUP="dialout", TAG+="uaccess"
# Raspberry Pi Pico / RP2040 (picoprobe, BOOTSEL)
SUBSYSTEM=="usb", ATTRS{idVendor}=="2e8a", MODE="0660", GROUP="dialout", TAG+="uaccess"
RULES
  sudo udevadm control --reload-rules 2>/dev/null && sudo udevadm trigger 2>/dev/null || true
  note "WSL2 ne vidi USB naprav privzeto — na Windows namesti usbipd-win (winget install usbipd), nato 'usbipd attach --wsl --busid <id>' iz PowerShella."
  success "Embedded toolchain + udev rules installed."
}

# ==============================================================================
# 20. TEALDEER — fetch page cache on first install
# ==============================================================================
mod_tealdeer() {
  if have tldr && [[ ! -d "$HOME/.cache/tealdeer" ]]; then
    info "Fetching tealdeer cache..."
    tldr --update || warn "tldr --update failed — run it manually later."
  fi
  success "tealdeer ready."
}

# ==============================================================================
# 20d. FASTFETCH — GaMa87 gradient logo + extended module list
# ==============================================================================
mod_fastfetch() {
  have fastfetch || sudo apt-get install -y fastfetch
  local ff="$HOME/.config/fastfetch"
  mkdir -p "$ff"
  backup_if_exists "$ff/config.jsonc"

  # Logo is truecolor ANSI (file-raw), so generate it instead of storing escape bytes here
  python3 -I - "$ff/gama87.txt" <<'PY'
import sys
L = {
'G':[" ██████╗ ","██╔════╝ ","██║  ███╗","██║   ██║","╚██████╔╝"," ╚═════╝ "],
'a':["        "," ██████╗","██╔══██║","██║  ██║","╚██████║"," ╚═════╝"],
'M':["███╗   ███╗","████╗ ████║","██╔████╔██║","██║╚██╔╝██║","██║ ╚═╝ ██║","╚═╝     ╚═╝"],
'8':[" █████╗ ","██╔══██╗","╚█████╔╝","██╔══██╗","╚█████╔╝"," ╚════╝ "],
'7':["███████╗","╚════██║","    ██╔╝","   ██╔╝ ","   ██║  ","   ╚═╝  "],
}
rows = [" ".join(L[c][i] for c in "GaMa87") for i in range(6)]
stops = [(255,0,128),(170,60,255),(0,200,255),(0,255,170)]
def grad(t):
    t *= len(stops)-1; i = min(int(t), len(stops)-2); f = t-i
    a,b = stops[i],stops[i+1]
    return tuple(round(a[k]+(b[k]-a[k])*f) for k in range(3))
W = max(len(r) for r in rows)
out = []
for y,r in enumerate(rows):
    s = ""
    for x,ch in enumerate(r):
        if ch == " ": s += ch; continue
        R,G,B = grad((x + y*1.5)/(W+9))
        if ch != "█": R,G,B = (R//2,G//2,B//2)   # darker shadow
        s += f"\033[1;38;2;{R};{G};{B}m{ch}"
    out.append(s + "\033[0m")
tag = "  ⟡ ─── ✦ ─── ⟡  "
out.append("")
out.append(" " * ((W - len(tag))//2) + "\033[38;2;170;60;255m" + tag + "\033[0m")
open(sys.argv[1],"w").write("\n".join(out)+"\n")
PY

  cat >"$ff/config.jsonc" <<'JSONC'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": {
    "type": "file-raw",
    "source": "~/.config/fastfetch/gama87.txt",
    "position": "top",
    "padding": { "top": 1, "left": 2, "right": 2 }
  },
  "display": {
    "separator": "  ",
    "color": { "keys": "magenta", "title": "cyan" },
    "key": { "width": 15 }
  },
  "modules": [
    { "type": "custom", "format": "\u001b[38;2;170;60;255m╭──────────────────────────────────────────────────────╮" },
    { "type": "title", "key": "  ", "format": "{user-name}@{host-name}" },
    { "type": "os",       "key": "  󰣛 OS" },
    { "type": "host",     "key": "  󰌢 Host" },
    { "type": "kernel",   "key": "   Kernel" },
    { "type": "uptime",   "key": "  󰅐 Uptime" },
    { "type": "packages", "key": "  󰏖 Packages" },
    { "type": "shell",    "key": "   Shell" },
    { "type": "display",  "key": "  󰍹 Display" },
    { "type": "de",       "key": "  󰧨 DE" },
    { "type": "wm",       "key": "   WM" },
    { "type": "wmtheme",  "key": "  󰉼 WM Theme" },
    { "type": "theme",    "key": "  󰏘 Theme" },
    { "type": "icons",    "key": "   Icons" },
    { "type": "font",     "key": "   Font" },
    { "type": "cursor",   "key": "  󰆿 Cursor" },
    { "type": "terminal", "key": "   Terminal" },
    { "type": "terminalfont", "key": "   Term Font" },
    { "type": "cpu",      "key": "  󰻠 CPU" },
    { "type": "gpu",      "key": "  󰍛 GPU" },
    { "type": "memory",   "key": "   Memory" },
    { "type": "swap",     "key": "  󰓡 Swap" },
    { "type": "disk",     "key": "  󰋊 Disk" },
    { "type": "localip",  "key": "  󰩟 Local IP" },
    { "type": "battery",  "key": "  󰁹 Battery" },
    { "type": "poweradapter", "key": "  󰚥 Power" },
    { "type": "locale",   "key": "   Locale" },
    { "type": "custom", "format": "\u001b[38;2;170;60;255m╰──────────────────────────────────────────────────────╯" },
    { "type": "colors", "symbol": "circle", "paddingLeft": 2 }
  ]
}
JSONC
  success "fastfetch configured (GaMa87 logo)."
}

# ==============================================================================
# 21. GIT CONFIG (identity + sane defaults + global gitignore)
# ==============================================================================
mod_gitcfg() {
  info "Configuring git..."

  # Identity — without this the first commit fails
  if [[ -z "$(git config --global user.email || true)" ]]; then
    local gn="" ge=""
    if ask "Git user.name  : " gn && ask "Git user.email : " ge; then
      [[ -n "$gn" ]] && git config --global user.name "$gn"
      [[ -n "$ge" ]] && git config --global user.email "$ge"
    fi
    [[ -z "$(git config --global user.email || true)" ]] &&
      note "git user.email ni nastavljen — nastavi: git config --global user.email you@example.com"
  fi
  success "git identity: $(git config --global user.name || echo '-') <$(git config --global user.email || echo '-')>"

  # Pager / diff
  if have delta; then
    git config --global core.pager delta
    git config --global interactive.diffFilter "delta --color-only"
    git config --global delta.navigate true
    git config --global delta.side-by-side true
    git config --global delta.line-numbers true
  fi

  git config --global merge.conflictstyle zdiff3
  git config --global diff.colorMoved default
  git config --global diff.algorithm histogram
  git config --global pull.rebase true
  git config --global rebase.autoStash true
  git config --global rebase.autoSquash true
  git config --global init.defaultBranch main
  git config --global push.autoSetupRemote true
  git config --global fetch.prune true
  git config --global fetch.pruneTags true
  git config --global column.ui auto
  git config --global branch.sort -committerdate
  git config --global help.autocorrect prompt
  git config --global core.fsmonitor true

  # Global gitignore
  local gi="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
  mkdir -p "$(dirname "$gi")"
  if [[ ! -f "$gi" ]]; then
    cat >"$gi" <<'GI'
# --- editors / OS ---
.DS_Store
*.swp
.idea/
.vscode/
# --- python ---
__pycache__/
*.py[cod]
.venv/
venv/
.mypy_cache/
.ruff_cache/
.pytest_cache/
# --- build / embedded ---
build/
dist/
*.o
*.elf
*.bin
*.map
sdkconfig.old
managed_components/
dependencies.lock
# --- env ---
.env
.env.local
.direnv/
GI
  fi
  git config --global core.excludesFile "$gi"
  success "git config written (global ignore: $gi)."
}

# ==============================================================================
# 22. .ZSHRC
# ==============================================================================
mod_zshrc() {
  info "Writing ~/.zshrc..."
  backup_if_exists ~/.zshrc
  cat >~/.zshrc <<'ZSHRC'
# ==========================================
# Early setup (must stay above the p10k instant prompt)
# ==========================================
# Reset XDG_CONFIG_HOME to default if it points to a Flatpak sandbox
if [[ "$XDG_CONFIG_HOME" == *".var/app"* ]]; then
  export XDG_CONFIG_HOME="$HOME/.config"
fi

# fastfetch prints before the prompt, so it doesn't clash with instant prompt
if [[ -o interactive && -z "${SSH_CONNECTION:-}" ]] && (( $+commands[fastfetch] )); then
  fastfetch
fi

typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# ==========================================
# PATH (typeset -U drops duplicates, first entry wins)
# ==========================================
typeset -U path PATH
export PYENV_ROOT="$HOME/.pyenv"
path=(
  $HOME/.local/bin                # pipx / uv tools
  $PYENV_ROOT/bin
  /usr/local/go/bin $HOME/go/bin
  $HOME/Android/Sdk/platform-tools
  /usr/local/bin /usr/bin
  $path
)

# Pyenv
if (( $+commands[pyenv] )); then
  eval "$(pyenv init - zsh)"
fi
unset PYENV_DIR

# ==========================================
# Environment
# ==========================================
export EDITOR=nvim VISUAL=nvim
export LESS='-RXF'
export BAT_THEME="Catppuccin Macchiato"
# Coloured man pages through bat
(( $+commands[bat] )) && export MANPAGER="sh -c 'col -bx | bat -l man -p'" MANROFFOPT="-c"

# History
HISTFILE=~/.zsh_history
HISTSIZE=100000
SAVEHIST=100000
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS HIST_VERIFY
setopt EXTENDED_GLOB AUTO_CD AUTO_PUSHD PUSHD_IGNORE_DUPS PUSHD_SILENT INTERACTIVE_COMMENTS NO_BEEP

# ==========================================
# Oh-My-Zsh  (zoxide se inicializira ročno spodaj — brez OMZ plugina, da ni dvojno)
# ==========================================
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)

# Autosuggestions: from history first, then completion; dim grey like Catppuccin overlay0
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=#6e738d'
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=40

if [[ -r "$ZSH/oh-my-zsh.sh" ]]; then
  source "$ZSH/oh-my-zsh.sh"
else
  echo "[WARN] oh-my-zsh not found at $ZSH/oh-my-zsh.sh"
fi

# Completion (after OMZ so these win over its defaults)
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*' group-name ''
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompcache"
zstyle ':completion:*:descriptions' format '%F{#c6a0f6}-- %d --%f'
zstyle ':completion:*:warnings' format '%F{#ed8796}-- ni zadetkov --%f'

# ==========================================
# FZF (Catppuccin Macchiato colours)
# ==========================================
# Safety aliases for Ubuntu binary name differences
(( $+commands[fdfind] )) && ! (( $+commands[fd] ))  && alias fd='fdfind'
(( $+commands[batcat] )) && ! (( $+commands[bat] )) && alias bat='batcat'

if (( $+commands[fd] || $+commands[fdfind] )); then
  export FZF_DEFAULT_COMMAND="${commands[fd]:-${commands[fdfind]}} --hidden --strip-cwd-prefix --exclude .git"
elif (( $+commands[rg] )); then
  export FZF_DEFAULT_COMMAND='rg --files --hidden --glob "!.git"'
else
  unset FZF_DEFAULT_COMMAND   # fzf falls back to its built-in walker
fi
[[ -n $FZF_DEFAULT_COMMAND ]] && export FZF_CTRL_T_COMMAND=$FZF_DEFAULT_COMMAND
export FZF_DEFAULT_OPTS="--height 45% --layout=reverse --border=rounded --info=inline-right \
--prompt='❯ ' --pointer='▶' --marker='✓' --preview-window=right:55%:border-left \
--color=bg+:#363a4f,bg:-1,spinner:#f4dbd6,hl:#ed8796 \
--color=fg:#cad3f5,header:#ed8796,info:#c6a0f6,pointer:#f4dbd6 \
--color=marker:#b7bdf8,fg+:#cad3f5,prompt:#c6a0f6,hl+:#ed8796 \
--color=selected-bg:#494d64,border:#494d64,label:#cad3f5"
export FZF_CTRL_T_OPTS="--preview 'bat -n --color=always {} 2>/dev/null || eza -T --color=always --icons=always {}'"
export FZF_ALT_C_OPTS="--preview 'eza -T --level=2 --color=always --icons=always {}'"
source <(fzf --zsh) 2>/dev/null

# ==========================================
# Keybindings
# ==========================================
# Extra Emacs-style keybindings (mark/kill/yank region)
bindkey -e
bindkey '^[b'  backward-word
bindkey '^[f'  forward-word
bindkey '^U'   backward-kill-line
bindkey '^@'   set-mark-command           # Ctrl+Space = oznacevanje
bindkey '^X^K' kill-region
bindkey '^[w'  copy-region-as-kill
bindkey '^Y'   yank
bindkey '^[[1;5D' backward-word           # Ctrl+←
bindkey '^[[1;5C' forward-word            # Ctrl+→
bindkey '^H'   backward-kill-word         # Ctrl+Backspace
bindkey '^[[3;5~' kill-word               # Ctrl+Delete
autoload -Uz edit-command-line && zle -N edit-command-line
bindkey '^X^E' edit-command-line
zle_highlight=('region:bg=#494d64' 'paste:none')

# CTRL+Z v shellu prinese zadnji job nazaj v ospredje
fancy-ctrl-z() { fg 2>/dev/null || true }
zle -N fancy-ctrl-z
bindkey '^Z' fancy-ctrl-z

# ==========================================
# Aliases
# ==========================================
# File listing ('--icons=auto': plain '--icons' would swallow the next argument)
alias ls='eza --icons=auto --group-directories-first'
alias l='eza -lh --icons=auto --group-directories-first --git'
alias ll='eza -lah --icons=auto --group-directories-first --git'
alias lt='eza --tree --icons=auto --level=2'

# Better defaults
#   'cat' ostane pravi cat (binarni stream, heredoc, redirect); bat je pod 'c'
alias c='bat -pp'
alias grep='grep --color=auto'
alias df='df -h'
alias diff='diff --color=auto'
alias ip='ip --color=auto'
duh() { du -sh "${@:-.}"; }   # namesto alias du='du -sh' (ne pokvari du -a ipd.)

# Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias d='dirs -v | head -10'  # skok nazaj: cd -<številka>

# WSL <-> Windows integracija
if grep -qi microsoft /proc/version 2>/dev/null; then
  alias open='explorer.exe .'
  alias pbcopy='clip.exe'
  alias pbpaste='powershell.exe -NoProfile -Command "Get-Clipboard" | tr -d "\r"'
fi

# Git shortcuts
alias gs='git status -sb'
alias gp='git push'
alias gl='git pull'
alias gd='git diff'
alias ga='git add -p'
alias grbi='git rebase -i origin/main'
alias glog='git log --graph --pretty="%C(#8aadf4)%h%Creset %C(#a6da95)%ar%Creset %s %C(#c6a0f6)%d%Creset" -20'

# Editor
alias vi='nvim'
alias v='nvim'
alias lg='lazygit'

# Safety nets — '-I' vpraša samo pri >3 datotekah ali -r (manj "yes-spama" kot -i)
alias rm='rm -I'
alias cp='cp -i'
alias mv='mv -i'

# Quick HTTP server in current directory
alias serve='python -m http.server 8000'

# Show PATH entries one per line
alias path='print -l $path'

# Clear + fastfetch
alias cl='clear && fastfetch'

# Quick reload / system info
alias reload='exec zsh'
alias myip='curl -s ifconfig.me; echo'
alias update='sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y'

# Docker
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dex='docker exec -it'
alias dlogs='docker logs -f'
alias ld='lazydocker'

# Tools
alias hf='hyperfine'
alias disk='gdu'
(( $+commands[dust] )) && alias dd2='dust'

# ==========================================
# Serial
# ==========================================
# Serial monitor brez Dockerja (hitrejši od idf.py monitor)
mon() { picocom -b "${2:-1000000}" "${1:-/dev/ttyUSB0}"; }

# ==========================================
# Functions
# ==========================================

# Universal archive extractor
extract() {
  [[ -f "$1" ]] || { echo "Ni datoteke: $1"; return 1; }
  case "$1" in
    *.tar.gz|*.tgz)   tar xzf "$1"   ;;
    *.tar.bz2|*.tbz2) tar xjf "$1"   ;;
    *.tar.xz|*.txz)   tar xJf "$1"   ;;
    *.tar.zst)        tar --zstd -xf "$1" ;;
    *.tar)            tar xf  "$1"   ;;
    *.zip)            unzip   "$1"   ;;
    *.7z)             7z x    "$1"   ;;
    *.rar)            unrar x "$1"   ;;
    *.bz2)            bunzip2 "$1"   ;;
    *.gz)             gunzip  "$1"   ;;
    *.zst)            unzstd  "$1"   ;;
    *)                echo "Unknown format: $1"; return 1 ;;
  esac
}

# mkdir + cd in one step
mkcd() { mkdir -p "$1" && cd "$1"; }

# fzf: open file in nvim
fv() {
  local f
  f=$(eval "${FZF_DEFAULT_COMMAND:-find . -type f -not -path '*/.git/*'}" \
      | fzf --preview 'bat -n --color=always {}') \
    && [[ -n "$f" ]] && nvim "$f"
}

# fzf: switch git branch
fbr() {
  local b
  b=$(git branch --all | grep -v HEAD | sed 's/^[* ] //;s#remotes/origin/##' | sort -u \
      | fzf --preview 'git log --oneline --color=always -20 {}') && [[ -n "$b" ]] && git checkout "$b"
}

# fzf: kill process — privzeto TERM (ne KILL); prvi arg je signal
fkill() {
  local sig="${1:-TERM}" pids
  pids=$(ps -ef | sed 1d | fzf -m --header="TAB za več | signal: $sig" | awk '{print $2}')
  [[ -n "$pids" ]] && echo "$pids" | xargs -r kill "-${sig}"
}

# ripgrep + fzf -> nvim on matching line
rgv() {
  (( $+commands[rg] )) || { echo "rgv potrebuje ripgrep: sudo apt install ripgrep"; return 1; }
  local out file line
  out=$(rg --line-number --no-heading --color=always "${1:-}" \
        | fzf --ansi --delimiter=: --preview 'bat --color=always -H {2} {1}') || return
  file=${out%%:*}; line=$(echo "$out" | cut -d: -f2)
  [[ -n "$file" ]] && nvim "+$line" "$file"
}

# git add all + commit
gac() { git add -A && git commit -m "$*"; }

# who is listening on a port
porty() { lsof -nP -iTCP:"$1" -sTCP:LISTEN; }

# quick ad-hoc backup of a file
bak() { cp -a "$1" "$1.bak.$(date +%Y%m%d-%H%M%S)"; }

# cheat sheet
cheat() { curl -s "cheat.sh/$1"; }

# Interactive history search (named alias — CTRL+R je vezan na atuin)
fh() { local c; c=$(history | fzf --tac | sed 's/ *[0-9]* *//') && print -z -- "$c" }

# Open lazygit from any subdirectory, always at repo root
lgg() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) \
    && lazygit -p "$root" \
    || echo "Not a git repo."
}

# yazi — on quit cd into the directory yazi was in
y() {
  local tmp cwd
  tmp=$(mktemp -t "yazi-cwd.XXXXXX")
  yazi "$@" --cwd-file="$tmp"
  cwd=$(<"$tmp")
  [[ -n "$cwd" && "$cwd" != "$PWD" ]] && builtin cd -- "$cwd"
  rm -f -- "$tmp"
}

# Open nvim at git repo root regardless of cwd
vconf() { nvim "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" }

# ==========================================
# Tool hooks
# ==========================================
# Atuin — replaces CTRL+R with smart history search
if (( $+commands[atuin] )); then
  eval "$(atuin init zsh --disable-up-arrow)"
  bindkey '^R' atuin-search
fi

# direnv — per-project env (IDF_PATH, target chip, secrets)
(( $+commands[direnv] )) && eval "$(direnv hook zsh)"

# zoxide (samo enkrat — brez OMZ zoxide plugina)
(( $+commands[zoxide] )) && eval "$(zoxide init zsh)"

# Keep arrow-down behavior stable even if plugins redefine widgets.
bindkey '^[[B' down-line-or-history
bindkey '^N' down-line-or-history

# ==========================================
# Prompt
# ==========================================
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

# Shell integration za skok med ukazi (WezTerm: Ctrl+Shift+↑/↓).
# p10k sam vgradi oznake 133;A/B v prompt (preživijo tudi njegove osvežitve),
# zato izklopimo podvojene oznake iz /etc/profile.d/wezterm.sh (cwd in user vars ostanejo).
typeset -g POWERLEVEL9K_TERM_SHELL_INTEGRATION=true
precmd_functions=(${precmd_functions:#__wezterm_semantic_precmd})
preexec_functions=(${preexec_functions:#__wezterm_semantic_preexec})
ZSHRC
  success ".zshrc written."
}

# ==============================================================================
# 23. SET ZSH AS DEFAULT SHELL
# ==============================================================================
mod_shell() {
  local zsh_path
  zsh_path=$(command -v zsh) || die "zsh ni nameščen."
  grep -qx "$zsh_path" /etc/shells || echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null
  local cur
  cur=$(getent passwd "$USER" | cut -d: -f7)
  if [[ "$cur" != "$zsh_path" ]]; then
    info "Setting zsh as default shell..."
    sudo chsh -s "$zsh_path" "$USER"
    note "Privzeti shell spremenjen v zsh — učinkuje v novem WSL terminalu."
  fi
  success "default shell: $zsh_path"
}

# ==============================================================================
# RUNNER
# ==============================================================================
declare -a EXECUTED=() FAILED=()
for m in "${ALL_MODULES[@]}"; do
  should_run "$m" || {
    info "-- skip: $m"
    continue
  }
  echo ""
  echo "=============================================================================="
  info "MODULE: $m"
  echo "=============================================================================="
  if run_selected_module "$m"; then
    EXECUTED+=("$m")
  else
    FAILED+=("$m")
    warn "Modul '$m' ni uspel — nadaljujem."
  fi
done

# ==============================================================================
# DONE
# ==============================================================================
trap - EXIT ERR
[[ -d "$ORIG_DIR" ]] && cd "$ORIG_DIR" || true
rm -rf "$WORK_DIR"
kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true

if ((UPDATE_MODE)); then
  update_summary
  exit $?
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     HEX-LAB V0.3 — WSL2 INSTALLED        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""

have python && python --version
have nvim && nvim --version | head -1
have go && go version
have node && echo "node $(node --version)"
if have lazygit; then
  LG_V=$(lazygit --version 2>/dev/null | extract_semver)
  echo "lazygit ${LG_V:-unknown}"
fi
have docker && docker --version

echo ""
echo -e "${CYAN}Moduli OK:${NC} ${EXECUTED[*]:-none}"
((${#FAILED[@]})) && echo -e "${RED}Moduli FAILED:${NC} ${FAILED[*]}"

if ((${#POST_NOTES[@]})); then
  echo ""
  echo -e "${YELLOW}── NASLEDNJI KORAKI ──────────────────────────${NC}"
  for n in "${POST_NOTES[@]}"; do echo -e "${YELLOW}  •${NC} $n"; done
fi

echo ""
echo -e "${CYAN}Log:${NC} $LOG_FILE"
echo -e "${CYAN}Priporočeno:${NC} 'wsl --shutdown' iz Windows PowerShella (group membership + privzeti shell + systemd)."
echo ""
