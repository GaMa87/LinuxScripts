#!/usr/bin/env bash
# ==============================================================================
# HEX-LAB V0.3 - macOS (Apple Silicon / Intel) DEVELOPER ENVIRONMENT
# Requires: macOS 13+, admin user | Homebrew + Xcode CLT se namestita samodejno
#
# Usage:
#   ./SetupMac.sh                      # vse
#   ./SetupMac.sh --list               # izpis modulov
#   ./SetupMac.sh --only=docker,nvim   # samo izbrani moduli
#   ./SetupMac.sh --skip=pyenv,fonts   # vse razen izbranih
#   GITHUB_TOKEN=ghp_... ./SetupMac.sh # obide GitHub API rate limit
#   HEXLAB_PY_FAST=1 ./SetupMac.sh     # Python brez PGO/LTO (hiter build)
#   HEXLAB_DOCKER=docker-desktop ./SetupMac.sh  # Docker Desktop namesto OrbStack
# ==============================================================================

# Must be executed (./SetupMac.sh), not sourced - sourcing leaks pyenv's PYENV_DIR
# (pointing at the temp workdir) into the interactive shell, breaking it once
# the workdir is removed at the end of the script.
(return 0 2>/dev/null) && {
  echo "Ne source-aj te skripte, pozeni jo z: ./SetupMac.sh" >&2
  return 1
}

# ==============================================================================
# BOOTSTRAP (bash 3.2 safe) — macOS ships bash 3.2; re-exec under Homebrew bash 5
# ==============================================================================
if [ "$(uname -s)" != "Darwin" ]; then
  echo "Ta skripta je za macOS. Za Ultramarine/Fedora uporabi SetupUltraMarine.sh" >&2
  exit 1
fi

if ((BASH_VERSINFO[0] < 4)); then
  echo "[HEX-LAB] Sistemski bash ${BASH_VERSION} je prestar — pripravljam Homebrew bash..."
  if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install >/dev/null 2>&1 || true
    echo "[HEX-LAB] Namesti Xcode Command Line Tools (okno se je odprlo), nato ponovno zaženi ./SetupMac.sh" >&2
    exit 1
  fi
  BREW=""
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && BREW="$b" && break; done
  if [ -z "$BREW" ]; then
    echo "[HEX-LAB] Nameščam Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || exit 1
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && BREW="$b" && break; done
  fi
  [ -n "$BREW" ] || {
    echo "[FAIL] Homebrew ni na voljo." >&2
    exit 1
  }
  BPREFIX=$("$BREW" --prefix)
  [ -x "$BPREFIX/bin/bash" ] || "$BREW" install bash || exit 1
  exec "$BPREFIX/bin/bash" "$0" "$@"
fi

set -Eeuo pipefail

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

# ==============================================================================
# MODULE SELECTION (before logging/sudo, so --list/--help exit immediately)
# ==============================================================================
ALL_MODULES=(
  base docker node golang pyenv uv lazygit nvim eza fonts wezterm vscode
  claude zed ohmyzsh gdu delta atuin hyperfine lazydocker yazi devtools embedded
  tealdeer casks craft theme dock fastfetch gitcfg zshrc shell
)
RUN_MODULES=("${ALL_MODULES[@]}")
declare -a SKIP_MODULES=()

for arg in "$@"; do
  case "$arg" in
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
    sed -n '2,15p' "$0"
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

LOG_DIR="$HOME/.local/state/hex-lab"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/setup_$(date +%Y%m%d_%H%M%S).log"

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
MACOS_VER=$(sw_vers -productVersion)
((${MACOS_VER%%.*} >= 13)) || die "Potreben macOS 13+ (zaznan ${MACOS_VER})."
[[ $EUID -eq 0 ]] && die "Ne poganjaj kot root — skripta uporablja sudo, kjer je potrebno."
xcode-select -p &>/dev/null || die "Xcode Command Line Tools manjkajo: xcode-select --install"

ARCH=$(uname -m)
case "$ARCH" in
arm64 | x86_64) ;;
*) die "Unsupported architecture: $ARCH" ;;
esac

if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
else
  die "Homebrew ni nameščen."
fi
export HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1
NPROC=$(sysctl -n hw.ncpu)

info "macOS ${MACOS_VER} / $ARCH / Homebrew: $HOMEBREW_PREFIX"
info "Log file: $LOG_FILE"

# --- sudo keepalive: pkg-based casks (Docker, fonts …) ask for sudo mid-run ---
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
done &) 2>/dev/null
SUDO_KEEPALIVE_PID=$!

WORK_DIR=$(mktemp -d)
ORIG_DIR=$(pwd)
cleanup() {
  local rc=$?
  [[ -d "$ORIG_DIR" ]] && cd "$ORIG_DIR" || true
  # Detach any DMG left mounted by an interrupted craft install
  local m
  for m in "$WORK_DIR"/mnt_*; do [[ -d "$m" ]] && hdiutil detach -quiet -force "$m" 2>/dev/null; done
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

# version_ge <have> <min>  — numeric dotted compare (BSD sort has no reliable -V)
version_ge() {
  [[ -n "${1:-}" ]] || return 1
  local IFS=. i
  local -a a=($1) b=($2)
  for ((i = 0; i < ${#b[@]}; i++)); do
    ((10#${a[i]:-0} > 10#${b[i]:-0})) && return 0
    ((10#${a[i]:-0} < 10#${b[i]:-0})) && return 1
  done
  return 0
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
gh_latest_tag() {
  local repo="$1" tag="" hdr=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && hdr=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  tag=$(curl -fsSL --retry 3 --retry-delay 2 "${hdr[@]}" \
    "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null |
    jq -r '.tag_name // empty' 2>/dev/null || true)
  if [[ -z "$tag" ]]; then
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

# brew_install <formula...> — installs only what is missing (brew errors on re-install noise)
brew_install() {
  local f missing=()
  for f in "$@"; do brew list --formula "$f" &>/dev/null || missing+=("$f"); done
  ((${#missing[@]})) || return 0
  info "brew install ${missing[*]}"
  brew install "${missing[@]}"
}

# cask_install <cask> <App.app> — skips when the app already exists (even if not from brew)
cask_install() {
  local cask="$1" app="$2"
  if [[ -d "/Applications/$app" || -d "$HOME/Applications/$app" ]]; then
    success "$app already installed"
    return 0
  fi
  info "brew install --cask $cask"
  brew install --cask "$cask"
}

# ==============================================================================
# 1. BASE — HOMEBREW PACKAGES
# ==============================================================================
mod_base() {
  info "Updating Homebrew..."
  brew update
  export HOMEBREW_NO_AUTO_UPDATE=1
  info "Installing base packages..."
  # zsh, lsof, file, unzip, curl, screen are part of macOS
  brew_install \
    wget git coreutils gnu-sed gnu-tar findutils automake autoconf libtool \
    cmake ninja pkgconf \
    pipx \
    ripgrep fd bat \
    zoxide fzf btop fastfetch libusb tealdeer \
    openssl@3 readline sqlite xz zlib tcl-tk gdbm \
    zstd sevenzip ca-certificates gnupg jq
  success "Base packages done."
}

# ==============================================================================
# 2. DOCKER (OrbStack by default — lighter than Docker Desktop on Apple Silicon)
# ==============================================================================
mod_docker() {
  case "${HEXLAB_DOCKER:-orbstack}" in
  docker-desktop) cask_install docker-desktop Docker.app ;;
  *) cask_install orbstack OrbStack.app ;;
  esac
  export PATH="$HOME/.orbstack/bin:$PATH"
  brew_install docker-compose 2>/dev/null || true
  if have docker; then
    success "docker $(docker --version 2>/dev/null | extract_semver)"
  else
    note "Docker: enkrat odpri ${HEXLAB_DOCKER:-OrbStack} (Launchpad), da namesti 'docker' CLI in zažene engine."
  fi
}

# ==============================================================================
# 3. NODE.JS LTS (current LTS major from nodejs.org -> brew node@<major>)
# ==============================================================================
mod_node() {
  if ! have node; then
    local major
    major=$(curl -fsSL https://nodejs.org/dist/index.json |
      jq -r '[.[] | select(.lts != false)][0].version' | sed -E 's/^v([0-9]+).*/\1/')
    info "Installing Node.js ${major:-?} LTS..."
    if [[ -n "$major" ]] && brew info --formula "node@${major}" &>/dev/null; then
      brew_install "node@${major}"
      brew link --overwrite --force "node@${major}"
    else
      brew_install node
    fi
  fi
  success "Node $(node --version) / npm $(npm --version)"
}

# ==============================================================================
# 4. GOLANG (brew — always current)
# ==============================================================================
GO_MIN="1.22"
mod_golang() {
  local cur=""
  have go && cur=$(go version 2>/dev/null | sed -nE 's/.*go([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')
  if ! version_ge "$cur" "$GO_MIN"; then
    info "Installing Go (trenutno: ${cur:-none})..."
    brew_install go
    brew upgrade go 2>/dev/null || true
  fi
  success "Go $(go version)"
}

# ==============================================================================
# 5. PYENV & PYTHON (latest 3.12.x patch — auto-resolved)
# ==============================================================================
mod_pyenv() {
  info "Setting up pyenv..."
  brew_install pyenv

  export PYENV_ROOT="$HOME/.pyenv"
  eval "$(pyenv init - bash)"
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
    # python-build finds brew's openssl/readline/tcl-tk on its own
    PYTHON_CONFIGURE_OPTS="$opts" \
      PYTHON_MAKE_OPTS="-j${NPROC}" \
      MAKE_OPTS="-j${NPROC}" \
      pyenv install "$pyver"
  fi
  pyenv global "$pyver"
  success "$(python --version)"
}

# ==============================================================================
# 6. UV — fast Python package/tool manager
# ==============================================================================
mod_uv() {
  brew_install uv
  export PATH="$HOME/.local/bin:$PATH"
  uv tool install --quiet ruff 2>/dev/null || warn "uv tool install ruff failed"
  uv tool install --quiet esptool 2>/dev/null || warn "uv tool install esptool failed"
  success "uv $(uv --version | extract_semver)"
}

# ==============================================================================
# 7. LAZYGIT
# ==============================================================================
mod_lazygit() {
  brew_install lazygit
  success "Lazygit $(lazygit --version 2>/dev/null | sed -nE 's/.*version=([^,]+).*/\1/p')"

  info "Writing lazygit config..."
  # macOS default: ~/Library/Application Support/lazygit (unless XDG_CONFIG_HOME is set)
  local lg_dir
  lg_dir=$(lazygit --print-config-dir 2>/dev/null || echo "$HOME/Library/Application Support/lazygit")
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
  success "lazygit config written ($lg_dir)."
}

# ==============================================================================
# 8. NEOVIM + LAZYVIM (+ providers + headless bootstrap)
# ==============================================================================
NVIM_MIN_VERSION="0.9.0"
mod_nvim() {
  local nvim_ver=""
  have nvim && nvim_ver=$(nvim --version | head -1 | sed -nE 's/^NVIM v([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')

  if ! version_ge "$nvim_ver" "$NVIM_MIN_VERSION"; then
    info "Installing Neovim..."
    brew_install neovim
    brew upgrade neovim 2>/dev/null || true
  fi
  success "$(nvim --version | head -1) ($(command -v nvim))"

  # --- Providers (silences most :checkhealth warnings) ---
  info "Installing Neovim providers..."
  if have uv; then
    uv tool install --quiet pynvim 2>/dev/null || pipx install pynvim 2>/dev/null || true
  else
    pipx install pynvim 2>/dev/null || true
  fi
  if have npm; then
    # Homebrew's npm prefix is user-owned — no sudo
    npm install -g --silent neovim tree-sitter-cli 2>/dev/null ||
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
  nvim --headless "+Lazy! sync" +qa 2>/dev/null ||
    warn "Lazy sync ni uspel — zaženi 'nvim' ročno in počakaj na install."
  success "LazyVim ready."
}

# ==============================================================================
# 9. EZA
# ==============================================================================
mod_eza() {
  brew_install eza
  success "eza $(eza --version | sed -n 2p)"
}

# ==============================================================================
# 10. NERD FONT — JetBrainsMono (cask -> ~/Library/Fonts)
# ==============================================================================
mod_fonts() {
  if compgen -G "$HOME/Library/Fonts/JetBrainsMonoNerdFont*" >/dev/null 2>&1; then
    success "JetBrainsMono Nerd Font already present — skipping."
    return 0
  fi
  info "Installing JetBrainsMono Nerd Font..."
  brew install --cask font-jetbrains-mono-nerd-font
  success "JetBrainsMono Nerd Font installed."
}

# ==============================================================================
# 11. WEZTERM
# ==============================================================================
mod_wezterm() {
  if ! have wezterm && [[ ! -d /Applications/WezTerm.app ]]; then
    info "Installing WezTerm (nightly)..."
    # the stable cask is from 2024; nightly matches the Linux copr build
    brew install --cask wezterm@nightly 2>/dev/null || brew install --cask wezterm
  fi
  [[ -d /Applications/WezTerm.app ]] || die "WezTerm install ni uspel."

  backup_if_exists ~/.wezterm.lua
  cat >~/.wezterm.lua <<'EOF'
-- ~/.wezterm.lua
-- Leader = Ctrl+A (tmux style). Leader + ? lists every shortcut, fuzzy-searchable.
local wezterm = require("wezterm")
local act = wezterm.action
local nf = wezterm.nerdfonts
local config = wezterm.config_builder()

-- Catppuccin Macchiato palette (for the tab and status bar)
local c = {
  crust = "#181926", mantle = "#1e2030", base = "#24273a",
  surface0 = "#363a4f", surface1 = "#494d64", overlay0 = "#6e738d",
  subtext0 = "#a5adcb", text = "#cad3f5",
  mauve = "#c6a0f6", blue = "#8aadf4", sapphire = "#7dc4e4", teal = "#8bd5ca",
  green = "#a6da95", yellow = "#eed49f", peach = "#f5a97f", red = "#ed8796",
  lavender = "#b7bdf8",
}

-- Nerd Font glyph by name, with a fallback if the name ever disappears
local function icon(name, fallback)
  return nf[name] or fallback or ""
end

-- ==========================================
-- LOOK
-- ==========================================
config.color_scheme = "Catppuccin Macchiato"
config.font = wezterm.font_with_fallback({
  { family = "JetBrainsMono Nerd Font", weight = "Medium", harfbuzz_features = { "calt=1", "liga=1" } },
  "Apple Color Emoji",
})
config.font_size = 15.0
config.line_height = 1.08
config.warn_about_missing_glyphs = false

config.window_background_opacity = 0.92
config.macos_window_background_blur = 20 -- frosted glass on macOS
config.window_padding = { left = "2cell", right = "2cell", top = "1cell", bottom = "0.5cell" }
config.inactive_pane_hsb = { saturation = 0.85, brightness = 0.65 } -- active pane stands out

config.default_cursor_style = "BlinkingBar"
config.cursor_blink_rate = 550
config.cursor_blink_ease_in = "EaseOut"
config.cursor_blink_ease_out = "EaseOut"
config.cursor_thickness = "0.12cell"

config.front_end = "WebGpu"
config.webgpu_power_preference = "HighPerformance"
config.max_fps = 120
config.animation_fps = 60

-- "RESIZE" hides the title bar but keeps resizable edges
config.window_decorations = "RESIZE"
config.native_macos_fullscreen_mode = false
config.enable_scroll_bar = false
config.adjust_window_size_when_changing_font_size = false

config.audible_bell = "Disabled"
config.visual_bell = {
  fade_in_function = "EaseIn", fade_in_duration_ms = 80,
  fade_out_function = "EaseOut", fade_out_duration_ms = 150,
}
config.colors = {
  visual_bell = c.surface0,
  split = c.surface1,
  tab_bar = { background = "rgba(0,0,0,0)" },
}

config.command_palette_font_size = 14.0
config.command_palette_bg_color = c.mantle
config.command_palette_fg_color = c.text
config.char_select_font_size = 14.0
config.char_select_bg_color = c.mantle
config.char_select_fg_color = c.text

-- ==========================================
-- BEHAVIOUR
-- ==========================================
config.term = "xterm-256color"
config.default_prog = { "/bin/zsh", "-l" }
config.scrollback_lines = 50000
config.switch_to_last_active_tab_when_closing_tab = true
config.status_update_interval = 1000
config.unicode_version = 14
config.selection_word_boundary = " \t\n{}[]()\"'`,;:│=&|"
-- Left Option keeps composing characters (@, [, ], { … on the Slovenian layout)
config.send_composed_key_when_left_alt_is_pressed = true
config.send_composed_key_when_right_alt_is_pressed = true

-- Ctrl+Click opens these; Leader+u picks one by keyboard
config.hyperlink_rules = wezterm.default_hyperlink_rules()
table.insert(config.hyperlink_rules, { regex = [[\b(localhost|127\.0\.0\.1):\d+\S*]], format = "http://$0" })
-- Leader+e highlights these for one-key copying (on top of the built-in URLs, hashes, paths…)
config.quick_select_patterns = {
  [[\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b]], -- IPv4 (with port)
  [[\b[0-9a-f]{7,40}\b]],                   -- git hashes
  [[[\w.-]+@[\w.-]+\.\w+]],                 -- e-mail addresses
}

-- Maximize on startup
wezterm.on("gui-startup", function(cmd)
  local _, _, window = wezterm.mux.spawn_window(cmd or {})
  window:gui_window():maximize()
end)

-- ==========================================
-- TAB BAR (rounded "pill" tabs with app icons)
-- ==========================================
config.use_fancy_tab_bar = false
config.tab_bar_at_bottom = true
config.hide_tab_bar_if_only_one_tab = false -- keep the status bar visible
config.show_new_tab_button_in_tab_bar = false
config.tab_max_width = 32

local process_icons = {
  zsh = icon("dev_terminal", ">"), bash = icon("dev_terminal", ">"), fish = icon("dev_terminal", ">"),
  nvim = icon("custom_vim", "v"), vim = icon("custom_vim", "v"),
  git = icon("dev_git", "g"), lazygit = icon("dev_git", "g"),
  node = icon("dev_nodejs_small", "n"), npm = icon("dev_nodejs_small", "n"), bun = icon("dev_nodejs_small", "n"),
  python = icon("dev_python", "py"), python3 = icon("dev_python", "py"),
  cargo = icon("dev_rust", "rs"), go = icon("seti_go", "go"),
  docker = icon("linux_docker", "d"), ssh = icon("md_server_network", "ssh"),
  btop = icon("md_chart_donut_variant", "b"), htop = icon("md_chart_donut_variant", "b"),
  claude = icon("md_robot", "*"), adb = icon("dev_android", "a"),
}

local function basename(s)
  return (s or ""):gsub("(.*[/\\])(.*)", "%2"):gsub("%.exe$", "")
end

local function tab_title(tab)
  if tab.tab_title and #tab.tab_title > 0 then return tab.tab_title end
  local pane = tab.active_pane
  local proc = basename(pane.foreground_process_name)
  local cwd = pane.current_working_dir
  local dir = cwd and basename(cwd.file_path:gsub("/$", "")) or ""
  if dir == wezterm.home_dir:gsub(".*/", "") then dir = "~" end
  if proc == "zsh" or proc == "bash" or proc == "fish" or proc == "" then
    return (process_icons[proc] or icon("dev_terminal")) .. "  " .. dir
  end
  return (process_icons[proc] or icon("cod_terminal_cmd", "$")) .. "  " .. proc
end

wezterm.on("format-tab-title", function(tab, _tabs, _panes, _cfg, hover, max_width)
  local L, R = icon("ple_left_half_circle_thick", ""), icon("ple_right_half_circle_thick", "")
  local bg, fg = c.surface0, c.subtext0
  if tab.is_active then
    bg, fg = c.mauve, c.crust
  elseif hover then
    bg, fg = c.surface1, c.text
  end
  local zoom = tab.active_pane.is_zoomed and (" " .. icon("md_magnify_plus_outline", "+")) or ""
  local title = (tab.tab_index + 1) .. " " .. tab_title(tab) .. zoom
  title = wezterm.truncate_right(title, max_width - 4)
  return {
    { Background = { Color = "rgba(0,0,0,0)" } }, { Text = " " },
    { Foreground = { Color = bg } }, { Text = L },
    { Background = { Color = bg } }, { Foreground = { Color = fg } },
    { Attribute = { Intensity = tab.is_active and "Bold" or "Normal" } },
    { Text = " " .. title .. " " },
    { Background = { Color = "rgba(0,0,0,0)" } }, { Foreground = { Color = bg } }, { Text = R },
  }
end)

-- ==========================================
-- STATUS BAR (mode/workspace left; cwd, battery, clock right)
-- ==========================================
local function pill(color, text)
  return {
    { Background = { Color = "rgba(0,0,0,0)" } }, { Foreground = { Color = color } },
    { Text = icon("ple_left_half_circle_thick", "") },
    { Background = { Color = color } }, { Foreground = { Color = c.crust } },
    { Attribute = { Intensity = "Bold" } }, { Text = text },
    "ResetAttributes",
    { Background = { Color = "rgba(0,0,0,0)" } }, { Foreground = { Color = color } },
    { Text = icon("ple_right_half_circle_thick", "") .. " " },
  }
end

local function append(t, items)
  for _, v in ipairs(items) do table.insert(t, v) end
end

wezterm.on("update-status", function(window, pane)
  -- Left: leader / key-table indicator, then workspace
  local left = { { Text = " " } }
  local key_table = window:active_key_table()
  if window:leader_is_active() then
    append(left, pill(c.peach, icon("md_keyboard", "") .. " LEADER"))
  elseif key_table then
    append(left, pill(c.yellow, icon("md_arrow_expand_all", "") .. " " .. key_table:upper():gsub("_", " ")))
  end
  append(left, pill(c.blue, icon("cod_window", "") .. " " .. window:active_workspace()))
  window:set_left_status(wezterm.format(left))

  -- Right: cwd, battery (laptops only), clock
  local right = {}
  local cwd = pane:get_current_working_dir()
  if cwd then
    local path = cwd.file_path:gsub("^" .. wezterm.home_dir, "~")
    append(right, {
      { Foreground = { Color = c.subtext0 } },
      { Text = icon("md_folder_outline", "") .. " " .. wezterm.truncate_left(path, 40) .. "   " },
    })
  end
  for _, b in ipairs(wezterm.battery_info()) do
    local pct = math.floor(b.state_of_charge * 100 + 0.5)
    local glyph = b.state == "Charging" and icon("md_battery_charging", "+")
      or (pct > 60 and icon("md_battery_high", "") or pct > 25 and icon("md_battery_medium", "") or icon("md_battery_low", "!"))
    local color = pct <= 20 and b.state ~= "Charging" and c.red or c.green
    append(right, { { Foreground = { Color = color } }, { Text = glyph .. " " .. pct .. "%   " } })
  end
  append(right, pill(c.lavender, icon("md_clock_outline", "") .. " " .. wezterm.strftime("%H:%M")))
  window:set_right_status(wezterm.format(right))
end)

-- Leader + t: toggle between see-through and solid background
wezterm.on("toggle-opacity", function(window)
  local o = window:get_config_overrides() or {}
  o.window_background_opacity = (o.window_background_opacity == 1.0) and 0.92 or 1.0
  window:set_config_overrides(o)
end)

-- ==========================================
-- KEYS (Leader = Ctrl+A, then the key)
-- ==========================================
config.leader = { key = "a", mods = "CTRL", timeout_milliseconds = 1500 }

config.keys = {
  -- Send "CTRL-A" to the terminal when pressing LEADER twice
  { key = "a",     mods = "LEADER|CTRL",  action = act.SendString("\x01") },
  -- Shift+Enter inserts a newline in Claude Code and similar prompts
  { key = "Enter", mods = "SHIFT",        action = act.SendString("\x1b\r") },

  -- ===== HELP =====
  { key = "?",     mods = "LEADER|SHIFT", action = act.ShowLauncherArgs({ flags = "FUZZY|KEY_ASSIGNMENTS" }) },
  { key = "Space", mods = "LEADER",       action = act.ActivateCommandPalette },

  -- ===== PANE MANAGEMENT =====
  { key = "s",     mods = "LEADER",       action = act.SplitVertical({ domain = "CurrentPaneDomain" }) },
  { key = "-",     mods = "LEADER",       action = act.SplitVertical({ domain = "CurrentPaneDomain" }) },
  { key = "v",     mods = "LEADER",       action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }) },
  { key = "\\",    mods = "LEADER",       action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }) },

  { key = "h",     mods = "LEADER",       action = act.ActivatePaneDirection("Left") },
  { key = "j",     mods = "LEADER",       action = act.ActivatePaneDirection("Down") },
  { key = "k",     mods = "LEADER",       action = act.ActivatePaneDirection("Up") },
  { key = "l",     mods = "LEADER",       action = act.ActivatePaneDirection("Right") },
  -- Same without the leader
  { key = "LeftArrow",  mods = "ALT|SHIFT", action = act.ActivatePaneDirection("Left") },
  { key = "DownArrow",  mods = "ALT|SHIFT", action = act.ActivatePaneDirection("Down") },
  { key = "UpArrow",    mods = "ALT|SHIFT", action = act.ActivatePaneDirection("Up") },
  { key = "RightArrow", mods = "ALT|SHIFT", action = act.ActivatePaneDirection("Right") },

  { key = "H",     mods = "LEADER|SHIFT", action = act.AdjustPaneSize({ "Left", 5 }) },
  { key = "J",     mods = "LEADER|SHIFT", action = act.AdjustPaneSize({ "Down", 5 }) },
  { key = "K",     mods = "LEADER|SHIFT", action = act.AdjustPaneSize({ "Up", 5 }) },
  { key = "L",     mods = "LEADER|SHIFT", action = act.AdjustPaneSize({ "Right", 5 }) },
  -- Resize mode: hjkl / arrows repeatedly, Esc or Enter to leave
  { key = "m",     mods = "LEADER",       action = act.ActivateKeyTable({ name = "resize_pane", one_shot = false }) },

  { key = "p",     mods = "LEADER",       action = act.PaneSelect({ alphabet = "asdfghjkl" }) },
  { key = "P",     mods = "LEADER|SHIFT", action = act.PaneSelect({ alphabet = "asdfghjkl", mode = "SwapWithActive" }) },
  { key = "Space", mods = "LEADER|CTRL",  action = act.RotatePanes("Clockwise") },
  { key = "!",     mods = "LEADER|SHIFT", action = wezterm.action_callback(function(_, pane) pane:move_to_new_tab() end) },

  { key = "z",     mods = "LEADER",       action = act.TogglePaneZoomState },
  { key = "o",     mods = "LEADER",       action = act.TogglePaneZoomState },
  -- Closing panes asks for confirmation: cheap insurance against a stray Ctrl-A x
  { key = "x",     mods = "LEADER",       action = act.CloseCurrentPane({ confirm = true }) },
  { key = "d",     mods = "LEADER",       action = act.CloseCurrentPane({ confirm = true }) },

  -- ===== TAB MANAGEMENT =====
  { key = "c",     mods = "LEADER",       action = act.SpawnTab("CurrentPaneDomain") },
  { key = "&",     mods = "LEADER|SHIFT", action = act.CloseCurrentTab({ confirm = true }) },
  { key = "n",     mods = "LEADER",       action = act.ActivateTabRelative(1) },
  { key = "b",     mods = "LEADER",       action = act.ActivateTabRelative(-1) },

  { key = "Tab",   mods = "LEADER",       action = act.ActivateLastTab },
  { key = "w",     mods = "LEADER",       action = act.ShowTabNavigator },
  { key = "<",     mods = "LEADER|SHIFT", action = act.MoveTabRelative(-1) },
  { key = ">",     mods = "LEADER|SHIFT", action = act.MoveTabRelative(1) },
  {
    key = ",",
    mods = "LEADER",
    action = act.PromptInputLine({
      description = wezterm.format({ { Foreground = { Color = c.mauve } }, { Text = "Rename tab:" } }),
      action = wezterm.action_callback(function(window, _pane, line)
        if line then window:active_tab():set_title(line) end
      end),
    }),
  },

  -- ===== WORKSPACES (separate sets of tabs, like tmux sessions) =====
  { key = "f",     mods = "LEADER",       action = act.ShowLauncherArgs({ flags = "FUZZY|WORKSPACES" }) },
  {
    key = "N",
    mods = "LEADER|SHIFT",
    action = act.PromptInputLine({
      description = wezterm.format({ { Foreground = { Color = c.blue } }, { Text = "New workspace name:" } }),
      action = wezterm.action_callback(function(window, pane, line)
        if line and #line > 0 then
          window:perform_action(act.SwitchToWorkspace({ name = line }), pane)
        end
      end),
    }),
  },
  { key = "(",     mods = "LEADER|SHIFT", action = act.SwitchWorkspaceRelative(-1) },
  { key = ")",     mods = "LEADER|SHIFT", action = act.SwitchWorkspaceRelative(1) },

  -- ===== SEARCH, COPY AND UTILITIES =====
  { key = "Enter", mods = "ALT",          action = act.ToggleFullScreen },
  { key = "/",     mods = "LEADER",       action = act.Search("CurrentSelectionOrEmptyString") },
  { key = "[",     mods = "LEADER",       action = act.ActivateCopyMode },
  { key = "e",     mods = "LEADER",       action = act.QuickSelect },
  {
    key = "u",
    mods = "LEADER",
    action = act.QuickSelectArgs({
      label = "open url",
      patterns = { [[https?://\S+]] },
      action = wezterm.action_callback(function(window, pane)
        wezterm.open_with(window:get_selection_text_for_pane(pane))
      end),
    }),
  },
  { key = "i",     mods = "LEADER",       action = act.CharSelect({ copy_on_select = true, copy_to = "ClipboardAndPrimarySelection" }) },
  { key = "t",     mods = "LEADER",       action = act.EmitEvent("toggle-opacity") },
  { key = "g",     mods = "LEADER",       action = act.SpawnCommandInNewTab({ args = { "lazygit" } }) },
  { key = "r",     mods = "LEADER",       action = act.ReloadConfiguration },
  { key = "k",     mods = "CTRL|SHIFT",   action = act.Multiple({ act.ClearScrollback("ScrollbackAndViewport"), act.SendKey({ key = "l", mods = "CTRL" }) }) },

  -- Jump between shell prompts in the scrollback (zsh/p10k OSC 133 marks)
  { key = "UpArrow",   mods = "CTRL|SHIFT", action = act.ScrollToPrompt(-1) },
  { key = "DownArrow", mods = "CTRL|SHIFT", action = act.ScrollToPrompt(1) },
}

config.key_tables = {
  resize_pane = {
    { key = "h", action = act.AdjustPaneSize({ "Left", 2 }) },
    { key = "j", action = act.AdjustPaneSize({ "Down", 2 }) },
    { key = "k", action = act.AdjustPaneSize({ "Up", 2 }) },
    { key = "l", action = act.AdjustPaneSize({ "Right", 2 }) },
    { key = "LeftArrow",  action = act.AdjustPaneSize({ "Left", 2 }) },
    { key = "DownArrow",  action = act.AdjustPaneSize({ "Down", 2 }) },
    { key = "UpArrow",    action = act.AdjustPaneSize({ "Up", 2 }) },
    { key = "RightArrow", action = act.AdjustPaneSize({ "Right", 2 }) },
    { key = "Escape", action = "PopKeyTable" },
    { key = "Enter",  action = "PopKeyTable" },
    { key = "q",      action = "PopKeyTable" },
  },
}

-- ==========================================
-- MOUSE
-- ==========================================
config.mouse_bindings = {
  -- Right click pastes
  { event = { Down = { streak = 1, button = "Right" } }, mods = "NONE", action = act.PasteFrom("Clipboard") },
  -- Plain click only selects; Ctrl+Click opens links
  {
    event = { Up = { streak = 1, button = "Left" } }, mods = "NONE",
    action = act.CompleteSelection("ClipboardAndPrimarySelection"),
  },
  { event = { Up = { streak = 1, button = "Left" } }, mods = "CTRL", action = act.OpenLinkAtMouseCursor },
  { event = { Down = { streak = 1, button = "Left" } }, mods = "CTRL", action = act.Nop },
  -- Ctrl+scroll zooms the font
  { event = { Down = { streak = 1, button = { WheelUp = 1 } } }, mods = "CTRL", action = act.IncreaseFontSize },
  { event = { Down = { streak = 1, button = { WheelDown = 1 } } }, mods = "CTRL", action = act.DecreaseFontSize },
}

return config
EOF
  success "WezTerm configured."
}

# ==============================================================================
# 12. VISUAL STUDIO CODE (+ 'code' CLI on PATH)
# ==============================================================================
mod_vscode() {
  cask_install visual-studio-code "Visual Studio Code.app"
  local cli="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  if ! have code && [[ -x "$cli" ]]; then
    ln -sf "$cli" "$HOMEBREW_PREFIX/bin/code"
  fi
  success "code $(code --version 2>/dev/null | head -1 || echo unknown)"
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
# 12c. ZED EDITOR (cask, self-updating) + config
#   Catppuccin theme/icons, VS Code layout and keymap with vim mode, JetBrainsMono
#   Nerd Font (module "fonts"), sticky scroll, rainbow brackets, inlay hints, inline
#   diagnostics. Extensions listed in auto_install_extensions install on first start.
# ==============================================================================
mod_zed() {
  cask_install zed Zed.app
  [[ -d /Applications/Zed.app ]] || {
    warn "Zed install ni uspel."
    return 1
  }

  mkdir -p ~/.config/zed
  backup_if_exists ~/.config/zed/settings.json
  cat >~/.config/zed/settings.json <<'ZEDCFG'
// Zed settings
//
// For information on how to configure Zed, see the Zed
// documentation: https://zed.dev/docs/configuring-zed
//
// To see all of Zed's default settings without changing your
// custom settings, run `zed: open default settings` from the
// command palette (cmd-shift-p)
{
  "proxy": "",

  // ---------------------------------------------------------------- extensions (installed automatically)
  "auto_install_extensions": {
    "catppuccin": true, // theme
    "catppuccin-icons": true, // file icons
    "git-firefly": true, // syntax for commit messages, .gitignore, .gitattributes
    "neocmake": true, // CMakeLists.txt with language server
    "kconfig": true, // Kconfig / Kconfig.projbuild
    "rainbow-csv": true, // ui_strings.csv in coloured columns
    "log": true, // highlighted serial monitor logs (*.log)
    "make": true,
    "toml": true,
    "ini": true,
    "linkerscript": true, // ESP-IDF linker fragments (*.ld)
    "xml": true,
    "html": true,
    "dockerfile": true
  },

  // ---------------------------------------------------------------- look
  "theme": {
    "mode": "system",
    "light": "Catppuccin Latte",
    "dark": "Catppuccin Mocha"
  },
  "icon_theme": {
    "mode": "system",
    "light": "Catppuccin Latte",
    "dark": "Catppuccin Mocha"
  },
  "ui_font_size": 16,
  "buffer_font_family": "JetBrainsMono Nerd Font",
  "buffer_font_size": 15,
  "buffer_font_features": { "calt": true, "liga": true }, // ligatures: != -> <= ==
  "buffer_line_height": "comfortable",
  "cursor_blink": true,
  "cursor_animation": { "enabled": true },
  "current_line_highlight": "all",
  "colorize_brackets": true, // rainbow brackets
  "unnecessary_code_fade": 0.5, // dim unused code reported by clangd
  "show_whitespaces": "boundary",
  "wrap_guides": [100], // matches ColumnLimit in .clang-format
  "show_wrap_guides": true,
  "indent_guides": {
    "enabled": true,
    "coloring": "indent_aware",
    "active_line_width": 2
  },

  // ---------------------------------------------------------------- editor helpers
  "vim_mode": true,
  "base_keymap": "VSCode",
  "relative_line_numbers": "enabled",
  "sticky_scroll": { "enabled": true }, // keeps the current function header on top
  "vertical_scroll_margin": 5,
  "inlay_hints": {
    "enabled": true, // parameter names and types from clangd
    "show_background": true
  },
  "diagnostics": {
    "inline": { "enabled": true } // errors shown at the end of the line
  },
  "lsp_document_colors": "inlay",
  "auto_signature_help": true,
  "hover_popover_delay": 300,
  "gutter": {
    "line_numbers": true,
    "folds": true,
    "runnables": true,
    "breakpoints": true
  },
  "minimap": {
    "show": "always",
    "thumb": "hover",
    "current_line_highlight": "line"
  },
  "scrollbar": {
    "show": "auto",
    "git_diff": true,
    "search_results": true,
    "selected_symbol": true,
    "diagnostics": "all"
  },
  "autosave": "on_focus_change",

  // ---------------------------------------------------------------- layout (VS Code style)
  "project_panel": {
    "dock": "left",
    "starts_open": true,
    "button": true,
    "auto_reveal_entries": true,
    "git_status": true,
    "file_icons": true,
    "folder_icons": true,
    "bold_folder_labels": true,
    "indent_size": 16,
    "indent_guides": { "show": "always" },
    "sticky_scroll": true,
    "show_diagnostics": "all"
  },
  "outline_panel": { "dock": "left" },
  "git_panel": { "dock": "left" },
  "tabs": {
    "file_icons": true,
    "git_status": true,
    "close_position": "right",
    "show_diagnostics": "errors"
  },
  "tab_bar": { "show_nav_history_buttons": true },
  "preview_tabs": { "enabled": true },
  "toolbar": { "breadcrumbs": true, "quick_actions": true },
  "title_bar": {
    "show_menus": false,
    "show_branch_name": true,
    "show_project_items": true,
    "show_user_picture": true
  },
  "status_bar": {
    "cursor_position_button": true,
    "active_language_button": true
  },

  // ---------------------------------------------------------------- git
  "git": {
    "inline_blame": {
      "enabled": true,
      "delay_ms": 500,
      "show_commit_summary": true
    },
    "hunk_style": "staged_hollow"
  },

  // ---------------------------------------------------------------- terminal
  "terminal": {
    "dock": "bottom",
    "font_size": 15.0,
    "font_family": "JetBrainsMono Nerd Font Mono",
    "line_height": "comfortable",
    "cursor_shape": "bar",
    "blinking": "on",
    "copy_on_select": true,
    "option_as_meta": false, // keep Option for @ [ ] { } on the Slovenian layout
    "toolbar": { "breadcrumbs": true }
  },

  // ---------------------------------------------------------------- AI
  "agent": {
    "dock": "right",
    "tool_permissions": {
      "tools": {
        "terminal": {
          "default": "allow"
        }
      }
    },
    "default_model": {
      "provider": "anthropic",
      "model": "claude-opus-5-5",
      "enable_thinking": true,
      "effort": "high"
    },
    "favorite_models": [],
    "model_parameters": []
  },
  "agent_servers": {
    "claude-acp": {
      "default_config_options": {
        "mode": "auto"
      },
      "type": "registry"
    },
    "github-copilot-cli": {
      "type": "registry"
    }
  },

  "session": {
    "trust_all_worktrees": true
  }
}
ZEDCFG
  # 'zed' CLI: Zed menu → "Install CLI" does the same
  [[ -x /Applications/Zed.app/Contents/MacOS/cli ]] && ! have zed &&
    ln -sf /Applications/Zed.app/Contents/MacOS/cli "$HOMEBREW_PREFIX/bin/zed"
  success "$(zed --version 2>/dev/null | head -1 || echo 'zed') configured."
  note "Zed: ob prvem zagonu se namestijo razširitve (tema, ikone, CMake, Kconfig …) — počakaj nekaj sekund."
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
# 13b-17b. CLI TOOLS (brew)
# ==============================================================================
mod_gdu() {
  brew_install gdu # installed as 'gdu-go' (coreutils already owns 'gdu')
  success "gdu $(gdu-go --version 2>&1 | extract_semver)"
}

mod_delta() {
  brew_install git-delta
  success "delta $(delta --version | extract_semver)"
}

mod_atuin() {
  brew_install atuin
  success "atuin $(atuin --version | extract_semver)"
}

mod_hyperfine() {
  brew_install hyperfine
  success "hyperfine $(hyperfine --version | extract_semver)"
}

mod_lazydocker() {
  brew_install lazydocker
  success "lazydocker $(lazydocker --version 2>/dev/null | extract_semver)"
}

mod_yazi() {
  brew_install yazi poppler resvg # PDF / SVG previews
  success "yazi $(yazi --version | extract_semver)"
}

# ==============================================================================
# 18. DEVTOOLS — gh, direnv, just, dust
# ==============================================================================
mod_devtools() {
  have gh || note "Prijavi se v GitHub CLI: gh auth login"
  brew_install gh direnv just dust
  success "gh $(gh --version | extract_semver)"
  success "direnv $(direnv version 2>/dev/null || echo unknown)"
  success "just $(just --version | extract_semver)"
  success "dust $(dust --version | extract_semver)"
}

# ==============================================================================
# 19. EMBEDDED TOOLCHAIN — serial access, debuggers
#   macOS has built-in drivers for CP210x / FTDI / CH34x / CDC-ACM and needs no
#   udev rules or dialout group: ports show up as /dev/cu.usbserial-* / cu.usbmodem*.
#   GNU gdb does not run on Apple Silicon — use lldb or arm-none-eabi-gdb.
# ==============================================================================
mod_embedded() {
  info "Installing embedded toolchain..."
  brew_install openocd minicom picocom dtc srecord stlink lsusb
  # clangd comes with Zed / VS Code (clangd extension) — full llvm is ~2 GB, skipped
  success "Embedded toolchain installed."
}

# ==============================================================================
# 20. TEALDEER — fetch page cache on first install
# ==============================================================================
mod_tealdeer() {
  if have tldr && ! tldr --quiet tar &>/dev/null; then
    info "Fetching tealdeer cache..."
    tldr --update || warn "tldr --update failed — run it manually later."
  fi
  success "tealdeer ready."
}

# ==============================================================================
# 20a. CASKS — desktop apps (Flathub equivalents)
# ==============================================================================
# <cask>:<App bundle>
CASK_APPS=(
  "bambu-studio:BambuStudio.app" # Bambu Studio (3D print slicer)
  "librewolf:LibreWolf.app"      # LibreWolf
  "keka:Keka.app"                # Keka (archive manager — PeaZip has no macOS cask)
)
mod_casks() {
  local entry
  for entry in "${CASK_APPS[@]}"; do
    cask_install "${entry%%:*}" "${entry#*:}" || warn "${entry%%:*} install ni uspel."
  done
  note "LibreWolf nastavitve (fingerprinting, cookies, WebGL, gesla): glej instruction.md."
  success "Desktop apps ready."
}

# ==============================================================================
# 20b. CRAFT APPS — Storyteller apps (GitHub release macOS universal DMGs)
# ==============================================================================
# <github repo under storytold>:<bundle name>
CRAFT_APPS=(
  craft-launcher:artcraft-launcher
  cadcraft:cadcraft
  figcraft:figcraft
  gridcraft:gridcraft
  pdfcraft:pdfcraft
  photocraft:photocraft
  vectorcraft:vectorcraft
  wordcraft:wordcraft
)
mod_craft() {
  # DMG installs carry no version brew could track — remember what we installed
  local state="$LOG_DIR/craft_versions"
  touch "$state"
  local entry repo name tag ver cur app dmg base mnt expected actual
  for entry in "${CRAFT_APPS[@]}"; do
    repo="${entry%%:*}"
    name="${entry#*:}"
    tag=$(gh_latest_tag "storytold/${repo}")
    ver="${tag#v}"
    cur="" app=""
    read -r _ cur app < <(grep "^${name} " "$state" || true) || true
    if [[ "$cur" == "$ver" && -n "$app" && -d "/Applications/$app" ]]; then
      success "$name $cur"
      continue
    fi
    info "Installing $name ${ver} (trenutno: ${cur:-none})..."
    dmg="${name}-${ver}-macos-universal.dmg"
    base="https://github.com/storytold/${repo}/releases/download/${tag}"
    if ! (fetch "$base/$dmg" "$dmg"); then
      warn "$name: macOS DMG ni na voljo — preskočeno."
      continue
    fi

    expected=$(curl -fsSL "$base/SHA256SUMS.txt" 2>/dev/null | awk -v f="$dmg" '$2 == f {print $1}' || true)
    actual=$(shasum -a 256 "$dmg" | awk '{print $1}')
    if [[ -z "$expected" ]]; then
      warn "$name: SHA256SUMS.txt brez vnosa za $dmg — nameščam brez preverjanja."
    elif [[ "$expected" != "$actual" ]]; then
      warn "$name: SHA256 se ne ujema — preskočeno."
      continue
    fi

    mnt="$WORK_DIR/mnt_${name}"
    mkdir -p "$mnt"
    hdiutil attach -nobrowse -readonly -quiet -mountpoint "$mnt" "$dmg" || {
      warn "$name: DMG se ne da priklopiti."
      continue
    }
    app=$(find "$mnt" -maxdepth 1 -name '*.app' -print -quit)
    if [[ -n "$app" ]]; then
      app=$(basename "$app")
      rm -rf "/Applications/$app"
      ditto "$mnt/$app" "/Applications/$app"
      { grep -v "^${name} " "$state" || true; echo "$name $ver $app"; } >"$state.tmp"
      mv "$state.tmp" "$state"
      success "$name $ver → /Applications/$app"
    else
      warn "$name: v DMG ni .app."
    fi
    hdiutil detach -quiet "$mnt" || true
  done
  note "SolidCraft obstaja samo kot Linux flatpak repo — na macOS preskočen."
  success "Craft apps ready."
}

# ==============================================================================
# 20c. THEME — dark mode, purple accent (Catppuccin Mauve), Catppuccin bat theme
# ==============================================================================
mod_theme() {
  info "Applying dark mode + purple accent..."
  osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true' ||
    warn "Dark mode ni nastavljen (dovoli Terminalu nadzor nad 'System Events')."
  defaults write -g AppleAccentColor -int 5 # 5 = purple
  defaults write -g AppleHighlightColor -string "0.968627 0.831373 1.000000 Purple"

  # Catppuccin Macchiato for bat (BAT_THEME in .zshrc), works whether or not bat ships it
  if have bat; then
    local themes
    themes="$(bat --config-dir)/themes"
    mkdir -p "$themes"
    curl -fsSL -o "$themes/Catppuccin Macchiato.tmTheme" \
      "https://raw.githubusercontent.com/catppuccin/bat/main/themes/Catppuccin%20Macchiato.tmTheme" &&
      bat cache --build >/dev/null ||
      warn "Catppuccin bat tema ni nameščena."
  fi
  note "Barvni poudarek (accent) se v nekaterih aplikacijah uveljavi po ponovnem zagonu."
  success "Theme applied."
}

# ==============================================================================
# 20c1. DOCK — bottom, autohide, my launchers (macOS take on the Plasma panel)
#   Rebuilds the Dock (after a backup) unless it already has exactly these apps.
# ==============================================================================
DOCK_APPS=(
  "/System/Applications/System Settings.app"
  "/System/Applications/App Store.app"
  "/Applications/LibreWolf.app"
  "/Applications/Visual Studio Code.app"
  "/Applications/WezTerm.app"
  "/Applications/WhatsApp.app"
  "/Applications/BambuStudio.app"
  "/Applications/Zed.app"
)
mod_dock() {
  brew_install dockutil
  local apps=() a
  for a in "${DOCK_APPS[@]}"; do [[ -d "$a" ]] && apps+=("$a"); done

  local want have_now
  want=$(for a in "${apps[@]}"; do basename "$a" .app; done)
  have_now=$(dockutil --list | awk -F'\t' '$3 == "persistentApps" {print $1}')
  if [[ "$want" == "$have_now" ]]; then
    success "Dock že ima to postavitev — ne spreminjam."
  else
    local bak="$LOG_DIR/dock_backup_$(date +%Y%m%d_%H%M%S).plist"
    defaults export com.apple.dock "$bak"
    info "Dock nastavitve shranjene → $bak (obnovi: defaults import com.apple.dock <file>; killall Dock)"
    dockutil --remove all --section apps --no-restart >/dev/null
    for a in "${apps[@]}"; do dockutil --add "$a" --no-restart >/dev/null; done
  fi

  defaults write com.apple.dock orientation -string bottom
  defaults write com.apple.dock autohide -bool true # ~ Plasma "dodge windows"
  defaults write com.apple.dock tilesize -int 54
  defaults write com.apple.dock show-recents -bool false
  defaults write com.apple.dock minimize-to-application -bool true
  killall Dock 2>/dev/null || true
  success "Dock nastavljen (spodaj, samodejno skrivanje)."
}

# ==============================================================================
# 20d. FASTFETCH — GaMa87 gradient logo + extended module list
# ==============================================================================
mod_fastfetch() {
  brew_install fastfetch
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
    { "type": "os",       "key": "   OS" },
    { "type": "host",     "key": "  󰌢 Host" },
    { "type": "kernel",   "key": "   Kernel" },
    { "type": "uptime",   "key": "  󰅐 Uptime" },
    { "type": "packages", "key": "  󰏖 Packages" },
    { "type": "shell",    "key": "   Shell" },
    { "type": "display",  "key": "  󰍹 Display" },
    { "type": "de",       "key": "  󰧨 DE" },
    { "type": "wm",       "key": "   WM" },
    { "type": "theme",    "key": "  󰏘 Theme" },
    { "type": "font",     "key": "   Font" },
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
  git config --global core.precomposeunicode true # macOS NFD file names (č, š, ž)
  git config --global credential.helper osxkeychain

  # Global gitignore
  local gi="$HOME/.config/git/ignore"
  mkdir -p "$(dirname "$gi")"
  if [[ ! -f "$gi" ]]; then
    cat >"$gi" <<'GI'
# --- editors / OS ---
.DS_Store
._*
.AppleDouble
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
# Homebrew first, so fastfetch & co. are found below
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
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
  $HOME/.local/bin                # pipx / uv tools / claude
  $PYENV_ROOT/bin
  $HOME/go/bin
  $HOME/.orbstack/bin
  $HOME/Library/Android/sdk/platform-tools
  $HOMEBREW_PREFIX/bin $HOMEBREW_PREFIX/sbin
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
export HOMEBREW_NO_ENV_HINTS=1
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

# Homebrew completions (gh, just, docker …) before OMZ runs compinit
[[ -d $HOMEBREW_PREFIX/share/zsh/site-functions ]] && fpath=($HOMEBREW_PREFIX/share/zsh/site-functions $fpath)

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
if (( $+commands[fd] )); then
  export FZF_DEFAULT_COMMAND="fd --hidden --strip-cwd-prefix --exclude .git"
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
bindkey '^[[1;3D' backward-word           # Option+← (WezTerm / iTerm)
bindkey '^[[1;3C' forward-word            # Option+→
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
duh() { du -sh "${@:-.}"; }   # namesto alias du='du -sh' (ne pokvari du -a ipd.)

# Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias d='dirs -v | head -10'  # skok nazaj: cd -<številka>

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
alias localip='ipconfig getifaddr en0 || ipconfig getifaddr en1'
alias update='brew update && brew upgrade && brew cleanup'
alias o='open .'              # trenutna mapa v Finderju
alias flushdns='sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder'

# Docker
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dex='docker exec -it'
alias dlogs='docker logs -f'
alias ld='lazydocker'

# Tools
alias hf='hyperfine'
alias disk='gdu-go'
(( $+commands[dust] )) && alias dd2='dust'

# ==========================================
# Serial
# ==========================================
# Serial monitor brez Dockerja (hitrejši od idf.py monitor); brez arg vzame prvi USB port
mon() {
  local dev="${1:-}"
  if [[ -z $dev ]]; then
    local -a devs=(/dev/cu.usbserial*(N) /dev/cu.usbmodem*(N) /dev/cu.SLAB*(N) /dev/cu.wchusbserial*(N))
    dev=${devs[1]:-}
    [[ -z $dev ]] && { echo "Ni serijske naprave (/dev/cu.usb*)"; return 1; }
  fi
  picocom -b "${2:-1000000}" "$dev"
}
alias ports='ls /dev/cu.* 2>/dev/null'

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
    *.7z|*.rar)       7zz x   "$1"   ;;
    *.bz2)            bunzip2 "$1"   ;;
    *.gz)             gunzip  "$1"   ;;
    *.zst)            unzstd  "$1"   ;;
    *.dmg)            hdiutil attach "$1" ;;
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
  (( $+commands[rg] )) || { echo "rgv potrebuje ripgrep: brew install ripgrep"; return 1; }
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
# zato izklopimo podvojene oznake iz WezTerm shell integration (cwd in user vars ostanejo).
typeset -g POWERLEVEL9K_TERM_SHELL_INTEGRATION=true
precmd_functions=(${precmd_functions:#__wezterm_semantic_precmd})
preexec_functions=(${preexec_functions:#__wezterm_semantic_preexec})
ZSHRC
  success ".zshrc written."
}

# ==============================================================================
# 23. SET ZSH AS DEFAULT SHELL (macOS system zsh)
# ==============================================================================
mod_shell() {
  local zsh_path=/bin/zsh cur
  cur=$(dscl . -read "/Users/$USER" UserShell | awk '{print $2}')
  if [[ "$cur" != "$zsh_path" ]]; then
    info "Setting zsh as default shell..."
    sudo chsh -s "$zsh_path" "$USER"
    note "Privzeti shell spremenjen v zsh — učinkuje v novem terminalu."
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
  if "mod_$m"; then
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

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║    HEX-LAB V0.3 (macOS) — INSTALLED      ║${NC}"
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
echo -e "${CYAN}Priporočeno:${NC} odpri nov terminal (WezTerm), da se naloži novi .zshrc."
echo ""
