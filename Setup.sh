#!/bin/bash
# ==============================================================================
# HEX-LAB V0.1 - UBUNTU DEVELOPER ENVIRONMENT
# Requires: Ubuntu 22.04+ | Run as normal user with sudo access
# ==============================================================================

set -Eeuo pipefail

# Unset any inherited CA overrides that might point to non-Ubuntu paths
# (e.g. CURL_CA_BUNDLE=/etc/pki/... from RHEL/Fedora environments)
unset CURL_CA_BUNDLE SSL_CERT_FILE

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[HEX-LAB]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

LOG_DIR="$HOME/.local/state/hex-lab"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/setup_$(date +%Y%m%d_%H%M%S).log"

# Keep a full transcript so failures are debuggable even if the terminal closes.
if [[ -t 1 ]]; then
  exec > >(trap '' ERR; tee -a "$LOG_FILE") 2>&1
else
  exec >> "$LOG_FILE" 2>&1
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH_ALT="x86_64"; ARCH_GO="amd64" ;;
  aarch64) ARCH_ALT="arm64";  ARCH_GO="arm64"  ;;
  *)       die "Unsupported architecture: $ARCH" ;;
esac
info "Architecture: $ARCH"
info "Log file: $LOG_FILE"

WORK_DIR=$(mktemp -d)
ORIG_DIR=$(pwd)
cleanup() {
  local rc=$?
  [[ -d "$ORIG_DIR" ]] && cd "$ORIG_DIR" || true
  rm -rf "$WORK_DIR"
  (( rc != 0 )) && warn "Script failed/interrupted — temp files cleaned."
}
trap cleanup EXIT
trap 'rc=$?; echo -e "${RED}[FAIL]${NC} Error at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2; echo -e "${YELLOW}[WARN]${NC} Full log: ${LOG_FILE}" >&2; [[ -t 0 ]] && read -r -p "Press Enter to close..." _; exit ${rc}' ERR
cd "$WORK_DIR"

extract_semver() {
  sed -nE 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -1
}

# ==============================================================================
# 1. SYSTEM PACKAGES
# ==============================================================================
info "Installing system packages..."
sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends \
  curl wget git build-essential cmake ninja-build \
  python3-pip pipx \
  ripgrep fd-find bat \
  zoxide fzf btop fastfetch zsh libusb-1.0-0-dev tealdeer fontconfig \
  libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
  libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev \
  unzip ca-certificates gnupg jq

# On Ubuntu/Debian, fd-find installs as fdfind and bat as batcat
[[ ! -e /usr/local/bin/fd  ]] && sudo ln -sf "$(which fdfind)" /usr/local/bin/fd
[[ ! -e /usr/local/bin/bat ]] && sudo ln -sf "$(which batcat)" /usr/local/bin/bat
success "System packages done."

# ==============================================================================
# 1.1 DOCKER ENGINE INSTALLATION (Added)
# ==============================================================================
if ! command -v docker &>/dev/null; then
  info "Installing Docker Engine..."
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -qq && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER"
  success "Docker Engine installed."
fi

# Pull ESP-IDF Images
info "Pulling ESP-IDF Docker images..."
sudo docker pull espressif/idf:latest
sudo docker pull espressif/idf:release-v5.0
success "Docker images pulled."

# ==============================================================================
# 2. NODE.JS LTS (NodeSource — apt ships outdated versions)
# ==============================================================================
if ! command -v node &>/dev/null; then
  info "Installing Node.js LTS..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi
success "Node $(node --version) / npm $(npm --version)"

# ==============================================================================
# 3. GOLANG (official binary — apt is usually 1-2 versions behind)
# ==============================================================================
GO_VERSION=$(curl -fsSL "https://go.dev/dl/?mode=json" | jq -r '.[0].version' | sed 's/go//')
if ! command -v go &>/dev/null || [[ "$(go version 2>/dev/null | grep -oP '\d+\.\d+'| head -1)" < "1.22" ]]; then
  info "Installing Go $GO_VERSION..."
  wget -q "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH_GO}.tar.gz" -O go.tar.gz
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf go.tar.gz
  sudo ln -sf /usr/local/go/bin/go    /usr/local/bin/go
  sudo ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
fi
success "Go $(go version)"

# ==============================================================================
# 4. PYENV & PYTHON (latest 3.12.x patch — auto-resolved)
# ==============================================================================
info "Setting up pyenv..."
if [[ ! -d "$HOME/.pyenv" ]]; then
  curl -fsSL https://pyenv.run | bash
fi

export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init --path)"
eval "$(pyenv init -)"

PYTHON_VERSION=$(pyenv install --list | grep -E '^\s+3\.12\.[0-9]+$' | tail -1 | tr -d ' ')
info "Latest Python 3.12 patch: $PYTHON_VERSION"

if ! pyenv versions --bare | grep -qx "$PYTHON_VERSION"; then
  info "Compiling Python $PYTHON_VERSION (this takes a while)..."
  PYTHON_CONFIGURE_OPTS="--enable-optimizations --with-lto" \
  MAKE_OPTS="-j$(nproc)" \
    pyenv install "$PYTHON_VERSION"
fi
pyenv global "$PYTHON_VERSION"
success "$(python --version)"

# ==============================================================================
# 5. LAZYGIT
# ==============================================================================
if ! command -v lazygit &>/dev/null || ! lazygit --version &>/dev/null; then
  info "Installing Lazygit..."
  LAZYGIT_VERSION=$(curl -fsSL "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" \
    | jq -r '.tag_name' | sed 's/v//')
  curl -fsSLo lazygit.tar.gz \
    "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_${ARCH_ALT}.tar.gz"
  tar xf lazygit.tar.gz lazygit
  sudo install lazygit /usr/local/bin
fi
success "Lazygit $(lazygit --version | grep -oP 'version=\K[^,]+')"

# ==============================================================================
# 6. NEOVIM + LAZYVIM
# ==============================================================================
NVIM_MIN_VERSION="0.9.0"
NVIM_BIN="$(command -v nvim || true)"
NVIM_VERSION=""

if [[ -n "$NVIM_BIN" ]] && "$NVIM_BIN" --version &>/dev/null; then
  mapfile -t NVIM_PATHS < <(which -a nvim 2>/dev/null | awk '!seen[$0]++')
  if (( ${#NVIM_PATHS[@]} > 1 )); then
    warn "Multiple nvim binaries detected: ${NVIM_PATHS[*]}"
    info "Using first nvim in PATH: $NVIM_BIN"
  fi
  NVIM_VERSION=$("$NVIM_BIN" --version | head -1 | sed -nE 's/^NVIM v([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
fi

if [[ -z "$NVIM_BIN" || -z "$NVIM_VERSION" || "$(printf '%s\n' "$NVIM_MIN_VERSION" "$NVIM_VERSION" | sort -V | head -1)" != "$NVIM_MIN_VERSION" ]]; then
  info "Installing Neovim..."
  curl -fsSLo nvim.tar.gz \
    "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${ARCH_ALT}.tar.gz"
  NVIM_DIR=$(tar -tf nvim.tar.gz | head -1 | cut -d/ -f1)
  [[ -z "$NVIM_DIR" ]] && die "Unable to determine Neovim directory from archive"
  sudo rm -rf "/opt/${NVIM_DIR}" /opt/nvim
  sudo tar -C /opt -xzf nvim.tar.gz
  sudo ln -sf "/opt/${NVIM_DIR}/bin/nvim" /usr/local/bin/nvim
  NVIM_BIN="/usr/local/bin/nvim"
fi
success "$($NVIM_BIN --version | head -1) ($NVIM_BIN)"

if [[ ! -f "$HOME/.config/nvim/lua/config/lazy.lua" ]]; then
  if [[ -d "$HOME/.config/nvim" ]]; then
    NVIM_BACKUP="$HOME/.config/nvim.backup_$(date +%Y%m%d_%H%M%S)"
    mv "$HOME/.config/nvim" "$NVIM_BACKUP"
    warn "Existing nvim config backed up -> $NVIM_BACKUP"
  fi
  info "Cloning LazyVim starter..."
  git clone --depth=1 https://github.com/LazyVim/starter ~/.config/nvim
  rm -rf ~/.config/nvim/.git
else
  success "LazyVim config already present — skipping clone."
fi

# ==============================================================================
# 7. EZA (official deb repo)
# ==============================================================================
if ! command -v eza &>/dev/null; then
  info "Installing eza..."
  sudo mkdir -p /etc/apt/keyrings
  wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
    | sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
  echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
    | sudo tee /etc/apt/sources.list.d/gierens.list
  sudo chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
  sudo apt-get update -qq && sudo apt-get install -y eza
fi
success "eza $(eza --version | head -1)"

# ==============================================================================
# 8. NERD FONT — JetBrainsMono (required for WezTerm config)
# ==============================================================================
FONT_DIR="$HOME/.local/share/fonts"
FONT_DEST="$FONT_DIR/JetBrainsMono"
if compgen -G "$FONT_DEST/*.ttf" > /dev/null 2>&1; then
  success "JetBrainsMono Nerd Font already present — skipping download."
else
  info "Installing JetBrainsMono Nerd Font..."
  mkdir -p "$FONT_DEST"
  FONT_VERSION=$(curl -fsSL "https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest" \
    | jq -r '.tag_name')
  curl -fsSLo JetBrainsMono.zip \
    "https://github.com/ryanoasis/nerd-fonts/releases/download/${FONT_VERSION}/JetBrainsMono.zip"
  unzip -oq JetBrainsMono.zip -d "$FONT_DEST"
  fc-cache -fv "$FONT_DIR" >/dev/null 2>&1
  success "JetBrainsMono Nerd Font installed."
fi

# ==============================================================================
# 9. WEZTERM
# ==============================================================================
if ! command -v wezterm &>/dev/null; then
  info "Installing WezTerm..."
  curl -fsSL https://apt.fury.io/wez/gpg.key \
    | sudo gpg --yes --dearmor -o /usr/share/keyrings/wezterm-fury.gpg
  echo 'deb [signed-by=/usr/share/keyrings/wezterm-fury.gpg] https://apt.fury.io/wez/ * *' \
    | sudo tee /etc/apt/sources.list.d/wezterm.list
  sudo apt-get update -qq && sudo apt-get install -y wezterm
fi

backup_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local backup="${file}.backup_$(date +%Y%m%d_%H%M%S)"
    cp "$file" "$backup"
    warn "Existing $(basename "$file") backed up → $backup"
  fi
}

backup_if_exists ~/.wezterm.lua
cat > ~/.wezterm.lua << 'EOF'
local wezterm = require("wezterm")
local act = wezterm.action
local config = wezterm.config_builder()

-- ==========================================
-- GENERAL SETTINGS
-- ==========================================
config.color_scheme = "Catppuccin Macchiato"
config.term = "xterm-256color"
config.default_prog = { "/usr/bin/env", "zsh", "-l" }
config.font = wezterm.font("JetBrainsMono Nerd Font", { weight = "Medium" })
config.font_size = 14.0
config.window_background_opacity = 0.95
config.default_cursor_style = "BlinkingBlock"
config.window_decorations = "NONE"
config.enable_scroll_bar = false
config.window_padding = { left = "2cell", right = "2cell", top = "1cell", bottom = "0cell" }

-- Maximize on startup
wezterm.on("gui-startup", function(spawn_window)
  local _, _, window = wezterm.mux.spawn_window(spawn_window or {})
  window:gui_window():maximize()
end)

-- Tab bar appearance
config.use_fancy_tab_bar = false
config.tab_bar_at_bottom = true
config.hide_tab_bar_if_only_one_tab = true

-- ==========================================
-- LEADER KEY
-- ==========================================
config.leader = { key = "a", mods = "CTRL", timeout_milliseconds = 1000 }

config.keys = {
  -- Send "CTRL-A" to the terminal when pressing LEADER twice
  { key = "a",     mods = "LEADER|CTRL",  action = act.SendString("\x01") },

  -- ==========================================
  -- PANE MANAGEMENT
  -- ==========================================
  -- Splitting panes
  { key = "s",     mods = "LEADER",       action = act.SplitVertical({ domain = "CurrentPaneDomain" }) },
  { key = "-",     mods = "LEADER",       action = act.SplitVertical({ domain = "CurrentPaneDomain" }) },
  { key = "v",     mods = "LEADER",       action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }) },
  { key = "\\",    mods = "LEADER",       action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }) },
  
  -- Pane navigation (Vim-style)
  { key = "h",     mods = "LEADER",       action = act.ActivatePaneDirection("Left") },
  { key = "j",     mods = "LEADER",       action = act.ActivatePaneDirection("Down") },
  { key = "k",     mods = "LEADER",       action = act.ActivatePaneDirection("Up") },
  { key = "l",     mods = "LEADER",       action = act.ActivatePaneDirection("Right") },
  
  -- Resizing panes
  { key = "H",     mods = "LEADER|SHIFT", action = act.AdjustPaneSize({ "Left", 5 }) },
  { key = "J",     mods = "LEADER|SHIFT", action = act.AdjustPaneSize({ "Down", 5 }) },
  { key = "K",     mods = "LEADER|SHIFT", action = act.AdjustPaneSize({ "Up", 5 }) },
  { key = "L",     mods = "LEADER|SHIFT", action = act.AdjustPaneSize({ "Right", 5 }) },
  
  -- Zoom and closing (NO CONFIRMATION)
  { key = "z",     mods = "LEADER",       action = act.TogglePaneZoomState },
  { key = "o",     mods = "LEADER",       action = act.TogglePaneZoomState },
  { key = "x",     mods = "LEADER",       action = act.CloseCurrentPane({ confirm = false }) },
  { key = "d",     mods = "LEADER",       action = act.CloseCurrentPane({ confirm = false }) },

  -- ==========================================
  -- TAB MANAGEMENT
  -- ==========================================
  -- Creating and closing tabs
  { key = "c",     mods = "LEADER",       action = act.SpawnTab("CurrentPaneDomain") },
  { key = "&",     mods = "LEADER|SHIFT", action = act.CloseCurrentTab({ confirm = false }) },
  
  -- Fast tab navigation (1-9)
  { key = "1",     mods = "LEADER",       action = act.ActivateTab(0) },
  { key = "2",     mods = "LEADER",       action = act.ActivateTab(1) },
  { key = "3",     mods = "LEADER",       action = act.ActivateTab(2) },
  { key = "4",     mods = "LEADER",       action = act.ActivateTab(3) },
  { key = "5",     mods = "LEADER",       action = act.ActivateTab(4) },
  { key = "6",     mods = "LEADER",       action = act.ActivateTab(5) },
  { key = "7",     mods = "LEADER",       action = act.ActivateTab(6) },
  { key = "8",     mods = "LEADER",       action = act.ActivateTab(7) },
  { key = "9",     mods = "LEADER",       action = act.ActivateTab(8) },
  
  -- Advanced tab features
  { key = "Tab",   mods = "LEADER",       action = act.ActivateLastTab },
  { key = "w",     mods = "LEADER",       action = act.ShowTabNavigator },
  { key = "<",     mods = "LEADER|SHIFT", action = act.MoveTabRelative(-1) },
  { key = ">",     mods = "LEADER|SHIFT", action = act.MoveTabRelative(1) },
  {
    key = ",",
    mods = "LEADER",
    action = act.PromptInputLine({
      description = "Rename tab:",
      action = wezterm.action_callback(function(window, pane, line)
        if line then window:active_tab():set_title(line) end
      end),
    }),
  },

  -- ==========================================
  -- SEARCH AND UTILITIES
  -- ==========================================
  { key = "Enter", mods = "ALT",          action = act.ToggleFullScreen },
  { key = "/",     mods = "LEADER",       action = act.Search("CurrentSelectionOrEmptyString") },
  { key = "[",     mods = "LEADER",       action = act.ActivateCopyMode },
  { key = "r",     mods = "LEADER",       action = act.ReloadConfiguration },
}

-- ==========================================
-- PLUGIN: TABLINE
-- ==========================================
local ok, tabline = pcall(wezterm.plugin.require, "https://github.com/michaelbrusegard/tabline.wez")
if ok then
  tabline.setup({
    options = { theme = "Catppuccin Macchiato", section_separators = "", component_separators = "" },
    sections = {
      tabline_a   = { "mode" },
      tabline_b   = { "workspace" },
      tabline_c   = { "cpu" },
      tab_active   = { "index", "tab", "zoomed" },
      tab_inactive = { "index", "tab" },
      tabline_x   = { "ram" },
      tabline_y   = { "datetime" },
      tabline_z   = { "hostname" },
    },
  })
end

return config
EOF
success "WezTerm configured."

# ==============================================================================
# 10. OH-MY-ZSH + PLUGINS + POWERLEVEL10K
# ==============================================================================
info "Setting up Oh-My-Zsh..."
if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
    "" --unattended
fi

ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

[[ ! -d "$ZSH_CUSTOM/themes/powerlevel10k" ]] && \
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
    "$ZSH_CUSTOM/themes/powerlevel10k"

[[ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]] && \
  git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
    "$ZSH_CUSTOM/plugins/zsh-autosuggestions"

[[ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]] && \
  git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
    "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"

success "Zsh plugins installed."

# ==============================================================================
# 11. GDU — fast disk usage TUI
# ==============================================================================
if ! command -v gdu &>/dev/null; then
  info "Installing gdu..."
  GDU_VERSION=$(curl -fsSL "https://api.github.com/repos/dundee/gdu/releases/latest" \
    | jq -r '.tag_name' | sed 's/v//')
  curl -fsSLo gdu.tgz \
    "https://github.com/dundee/gdu/releases/latest/download/gdu_linux_${ARCH_GO}.tgz"
  tar xf gdu.tgz
  GDU_BIN=$(find . -name 'gdu*' -type f | head -1)
  [[ -z "$GDU_BIN" ]] && die "gdu binary not found in archive"
  sudo install "$GDU_BIN" /usr/local/bin/gdu
fi
success "gdu $(gdu --version 2>&1 | head -1)"

# ==============================================================================
# 12. DELTA — better git diff pager
# ==============================================================================
if ! command -v delta &>/dev/null; then
  info "Installing delta..."
  DELTA_VERSION=$(curl -fsSL "https://api.github.com/repos/dandavison/delta/releases/latest" \
    | jq -r '.tag_name')
  case "$ARCH" in
    x86_64)  DELTA_ARCH="x86_64-unknown-linux-musl" ;;
    aarch64) DELTA_ARCH="aarch64-unknown-linux-gnu"  ;;
  esac
  curl -fsSLo delta.tar.gz \
    "https://github.com/dandavison/delta/releases/latest/download/delta-${DELTA_VERSION}-${DELTA_ARCH}.tar.gz"
  tar xf delta.tar.gz
  DELTA_BIN=$(find . -name 'delta' -type f | head -1)
  [[ -z "$DELTA_BIN" ]] && die "delta binary not found in archive"
  sudo install "$DELTA_BIN" /usr/local/bin/delta
fi

# Configure delta as git pager globally
git config --global core.pager delta
git config --global interactive.diffFilter "delta --color-only"
git config --global delta.navigate true
git config --global delta.side-by-side true
git config --global delta.line-numbers true
git config --global merge.conflictstyle diff3
git config --global diff.colorMoved default
success "delta $(delta --version)"

# ==============================================================================
# 13. ATUIN — shell history sync & search (binary install — no curl|bash)
# ==============================================================================
if ! command -v atuin &>/dev/null; then
  info "Installing atuin..."
  ATUIN_VERSION=$(curl -fsSL "https://api.github.com/repos/atuinsh/atuin/releases/latest" \
    | jq -r '.tag_name' | sed 's/v//')
  case "$ARCH" in
    x86_64)  ATUIN_ARCH="x86_64-unknown-linux-musl"  ;;
    aarch64) ATUIN_ARCH="aarch64-unknown-linux-musl"  ;;
  esac
  curl -fsSLo atuin.tar.gz \
    "https://github.com/atuinsh/atuin/releases/latest/download/atuin-${ATUIN_ARCH}.tar.gz"
  tar xf atuin.tar.gz
  ATUIN_BIN=$(find . -name 'atuin' -type f | head -1)
  [[ -z "$ATUIN_BIN" ]] && die "atuin binary not found in archive"
  sudo install "$ATUIN_BIN" /usr/local/bin/atuin
fi
success "atuin $(atuin --version)"

# ==============================================================================
# 14. HYPERFINE — command-line benchmarking
# ==============================================================================
if ! command -v hyperfine &>/dev/null; then
  info "Installing hyperfine..."
  HYPER_VERSION=$(curl -fsSL "https://api.github.com/repos/sharkdp/hyperfine/releases/latest" \
    | jq -r '.tag_name' | sed 's/v//')
  case "$ARCH" in
    x86_64)  HYPER_ARCH="x86_64-unknown-linux-musl" ;;
    aarch64) HYPER_ARCH="aarch64-unknown-linux-gnu"  ;;
  esac
  curl -fsSLo hyperfine.tar.gz \
    "https://github.com/sharkdp/hyperfine/releases/latest/download/hyperfine-v${HYPER_VERSION}-${HYPER_ARCH}.tar.gz"
  tar xf hyperfine.tar.gz
  HYPER_BIN=$(find . -name 'hyperfine' -type f | head -1)
  [[ -z "$HYPER_BIN" ]] && die "hyperfine binary not found in archive"
  sudo install "$HYPER_BIN" /usr/local/bin/hyperfine
fi
success "hyperfine $(hyperfine --version)"

# ==============================================================================
# 15. LAZYDOCKER — Docker TUI
# ==============================================================================
if ! command -v lazydocker &>/dev/null; then
  info "Installing lazydocker..."
  LD_VERSION=$(curl -fsSL "https://api.github.com/repos/jesseduffield/lazydocker/releases/latest" \
    | jq -r '.tag_name' | sed 's/v//')
  curl -fsSLo lazydocker.tar.gz \
    "https://github.com/jesseduffield/lazydocker/releases/latest/download/lazydocker_${LD_VERSION}_Linux_${ARCH_ALT}.tar.gz"
  tar xf lazydocker.tar.gz lazydocker
  sudo install lazydocker /usr/local/bin
fi
LD_INSTALLED_VERSION=$(lazydocker --version 2>/dev/null | extract_semver)
[[ -z "$LD_INSTALLED_VERSION" ]] && LD_INSTALLED_VERSION=$(lazydocker --version 2>/dev/null | head -1)
success "lazydocker ${LD_INSTALLED_VERSION:-unknown}"

# ==============================================================================
# 16. TEALDEER — fetch page cache on first install
# ==============================================================================
if command -v tldr &>/dev/null && [[ ! -d "$HOME/.cache/tealdeer" ]]; then
  info "Fetching tealdeer cache..."
  tldr --update || warn "tldr --update failed — run it manually later."
fi

# ==============================================================================
# 17. .ZSHRC
# ==============================================================================
info "Writing ~/.zshrc..."
backup_if_exists ~/.zshrc
cat > ~/.zshrc << 'ZSHRC'
# Reset XDG_CONFIG_HOME to default if it points to Flatpak sandbox
if [[ "$XDG_CONFIG_HOME" == *".var/app"* ]]; then
  export XDG_CONFIG_HOME="$HOME/.config"
fi

if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Keep common system binary paths available in all shells.
export PATH="/usr/local/bin:/usr/bin:$PATH"

# Pyenv
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init --path)"
eval "$(pyenv init -)"

# Go
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"

# Oh-My-Zsh
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting zoxide)
if [[ -r "$ZSH/oh-my-zsh.sh" ]]; then
  source "$ZSH/oh-my-zsh.sh"
else
  echo "[WARN] oh-my-zsh not found at $ZSH/oh-my-zsh.sh"
fi

# Safety aliases for Ubuntu binary name differences
(( $+commands[fdfind] )) && alias fd='fdfind'
(( $+commands[batcat] )) && alias bat='batcat'

# File listing
alias ls='eza --icons'
alias l='eza -lh --icons --group-directories-first'
alias ll='eza -lah --icons'
alias lt='eza --tree --icons --level=2'

# Better defaults
alias cat='bat -pp'
alias grep='grep --color=auto'
alias df='df -h'
alias du='du -sh'
alias diff='diff --color=auto'
alias ip='ip --color=auto'

# Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# Git shortcuts
alias gs='git status'
alias gp='git push'
alias gl='git pull'
alias gd='git diff'
alias ga='git add -p'

# Editor
alias vi='nvim'
alias v='nvim'
alias lg='lazygit'

# Safety nets
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# Quick HTTP server in current directory
alias serve='python -m http.server 8000'

# Show PATH entries one per line
alias path='echo $PATH | tr ":" "\n"'

# Clear + fastfetch
alias cl='clear && fastfetch'

# Docker
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dex='docker exec -it'
alias dlogs='docker logs -f'

# ESP-IDF via Docker aliases
# idf -> Uses latest version
new_idf.py() {
  docker run --rm \
    -v "$(pwd):/project" \
    -w /project \
    --privileged \
    --device=/dev/ttyUSB0:/dev/ttyUSB0 \
    -it espressif/idf:latest \
    idf.py "$@"
}

# idf50 -> Uses release-v5.0
idf.py() {
  docker run --rm \
    -v "$(pwd):/project" \
    -w /project \
    --privileged \
    --device=/dev/ttyUSB0:/dev/ttyUSB0 \
    -it espressif/idf:release-v5.0 \
    idf.py "$@"
}

# Universal archive extractor
extract() {
  case "$1" in
    *.tar.gz|*.tgz) tar xzf "$1"  ;;
    *.tar.bz2)       tar xjf "$1"  ;;
    *.tar.xz)        tar xJf "$1"  ;;
    *.zip)           unzip  "$1"   ;;
    *.7z)            7z x   "$1"   ;;
    *.gz)            gunzip "$1"   ;;
    *)               echo "Unknown format: $1" ;;
  esac
}

# mkdir + cd in one step
mkcd() { mkdir -p "$1" && cd "$1"; }

# Interactive history search (named alias — CTRL+R is already bound by fzf)
fh() { eval "$(history | fzf --tac | sed 's/ *[0-9]* *//')" }

# Open lazygit from any subdirectory, always at repo root
lgg() {
  git -C "$(git rev-parse --show-toplevel)" status &>/dev/null \
    && lazygit -p "$(git rev-parse --show-toplevel)" \
    || echo "Not a git repo."
}

# Lazydocker
alias ld='lazydocker'

# Hyperfine shorthand
alias hf='hyperfine'

# Disk usage TUI (gdu — 'disk' chosen to avoid conflict with git diff alias gd)
alias disk='gdu'

# Git + delta
alias grbi='git rebase -i origin/main'

# Open nvim at git repo root regardless of cwd
vconf() { v "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" }

# CTRL+Z in normal shell suspends — this brings the process back instantly
fancy-ctrl-z() { fg 2>/dev/null || true }
zle -N fancy-ctrl-z
bindkey '^Z' fancy-ctrl-z

# Atuin — replaces CTRL+R with smart history search
if (( $+commands[atuin] )); then
  eval "$(atuin init zsh --disable-up-arrow)"
  bindkey '^R' atuin-search
fi

# Keep arrow-down behavior stable even if plugins redefine widgets.
bindkey '^[[B' down-line-or-history
bindkey '^N' down-line-or-history

eval "$(zoxide init zsh)"

[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

if [[ -o interactive && -z "${SSH_CONNECTION:-}" ]] && command -v fastfetch >/dev/null 2>&1; then
  fastfetch
fi
typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet
ZSHRC
success ".zshrc written."

# ==============================================================================
# 18. SET ZSH AS DEFAULT SHELL
# ==============================================================================
ZSH_PATH=$(which zsh)
if [[ "$SHELL" != "$ZSH_PATH" ]]; then
  info "Setting zsh as default shell..."
  sudo chsh -s "$ZSH_PATH" "$USER"
fi

# ==============================================================================
# DONE
# ==============================================================================
trap - EXIT
[[ -d "$ORIG_DIR" ]] && cd "$ORIG_DIR" || true
rm -rf "$WORK_DIR"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       HEX-LAB V0.1 — INSTALLED           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
python --version
nvim --version | head -1
LAZYGIT_SUMMARY_VERSION=$(lazygit --version 2>/dev/null | extract_semver)
[[ -z "$LAZYGIT_SUMMARY_VERSION" ]] && LAZYGIT_SUMMARY_VERSION=$(lazygit --version 2>/dev/null | head -1)
