#!/usr/bin/env bash
# ==============================================================================
# HEX-LAB V0.3 - OMARCHY (ARCH + HYPRLAND) DEVELOPER ADD-ONS
# Requires: Omarchy (Arch Linux) | Run as normal user with sudo access
#
# Omarchy already ships nvim + LazyVim, lazygit, docker, mise (node, uv, gh,
# claude ...), eza, fzf, zoxide, ripgrep, bat, btop, fastfetch, Nerd Fonts and
# themes. This script only adds what is missing from SetupUltraMarine.sh and
# leaves Omarchy's own config alone (bash + starship stay, own snippets are
# sourced from separate files, so 'omarchy refresh' does not clash with them).
#
# Usage:
#   ./SetupOmarchy.sh                      # vse
#   ./SetupOmarchy.sh --list               # izpis modulov
#   ./SetupOmarchy.sh --only=embedded,git  # samo izbrani moduli
#   ./SetupOmarchy.sh --skip=sumniki       # vse razen izbranih
#
# Updates: everything comes from pacman/mise, so 'omarchy update' and
# 'mise up' keep it current; rerunning this script is safe (idempotent).
# ==============================================================================

(return 0 2>/dev/null) && {
  echo "Ne source-aj te skripte, pozeni jo z: ./SetupOmarchy.sh" >&2
  return 1
}

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

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

# Modules run in subshells, so deferred messages go through a file
NOTES_FILE=$(mktemp)
note() { echo "$*" >>"$NOTES_FILE"; }

LOG_DIR="$HOME/.local/state/hex-lab"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/setup-omarchy_$(date +%Y%m%d_%H%M%S).log"

if [[ -t 1 ]]; then
  exec > >(
    trap '' ERR
    tee -a "$LOG_FILE"
  ) 2>&1
else
  exec >>"$LOG_FILE" 2>&1
fi

have() { command -v "$1" &>/dev/null; }

backup_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local backup="${file}.backup_$(date +%Y%m%d_%H%M%S)"
    cp "$file" "$backup"
    warn "Existing $(basename "$file") backed up → $backup"
  fi
}

# pkg <packages...> — install missing Arch packages (Omarchy helper, pacman fallback)
pkg() {
  if have omarchy-pkg-add; then
    omarchy-pkg-add "$@"
  else
    sudo pacman -S --noconfirm --needed -- "$@"
  fi
}

# add_to_group <group> — returns 0 if the user was newly added
add_to_group() {
  local group="$1"
  id -nG "$USER" | tr ' ' '\n' | grep -qx "$group" && return 1
  sudo usermod -aG "$group" "$USER"
}

# ensure_line <file> <line> — append a line once
ensure_line() {
  local file="$1" line="$2"
  touch "$file"
  grep -qxF "$line" "$file" || printf '\n%s\n' "$line" >>"$file"
}

# ==============================================================================
# MODULE SELECTION
# ==============================================================================
ALL_MODULES=(
  cli docker lang embedded git lazygit bash fastfetch appimage sumniki
)
RUN_MODULES=("${ALL_MODULES[@]}")
declare -a SKIP_MODULES=()

for arg in "$@"; do
  case "$arg" in
  --list)
    printf 'Moduli: %s\n' "${ALL_MODULES[*]}"
    exit 0
    ;;
  --only=*) IFS=',' read -r -a RUN_MODULES <<<"${arg#--only=}" ;;
  --skip=*) IFS=',' read -r -a SKIP_MODULES <<<"${arg#--skip=}" ;;
  -h | --help)
    sed -n '2,20p' "$0"
    exit 0
    ;;
  *) die "Neznan argument: $arg (uporabi --help)" ;;
  esac
done

for m in "${RUN_MODULES[@]}" "${SKIP_MODULES[@]}"; do
  [[ " ${ALL_MODULES[*]} " == *" $m "* ]] || die "Neznan modul: $m (uporabi --list)"
done

should_run() {
  local m="$1" x
  for x in "${SKIP_MODULES[@]:-}"; do [[ "$x" == "$m" ]] && return 1; done
  for x in "${RUN_MODULES[@]}"; do [[ "$x" == "$m" ]] && return 0; done
  return 1
}

# ==============================================================================
# 0. PRE-FLIGHT
# ==============================================================================
[[ $EUID -eq 0 ]] && die "Ne poganjaj kot root — skripta uporablja sudo, kjer je potrebno."
have pacman || die "pacman ni na voljo — ta skripta je namenjena Omarchy/Arch sistemom."
have omarchy || warn "Ukaz 'omarchy' ni najden — nadaljujem kot na navadnem Archu."

info "Log file: $LOG_FILE"
info "Preverjam sudo dostop..."
sudo -v || die "Potrebujem sudo."
(while true; do
  sudo -n true 2>/dev/null
  sleep 50
  kill -0 "$$" 2>/dev/null || exit
done) 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; rm -f "$NOTES_FILE"' EXIT
# shellcheck disable=SC2016  # expanded when the trap fires
ERR_TRAP='rc=$?;
      echo -e "${RED}[FAIL]${NC} Error at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2;
      echo -e "${YELLOW}[WARN]${NC} Full log: ${LOG_FILE}" >&2'
trap "$ERR_TRAP" ERR

# ==============================================================================
# 1. CLI — tools Omarchy does not ship (all from the Arch repos)
# ==============================================================================
mod_cli() {
  info "Installing CLI tools..."
  pkg git-delta atuin bash-preexec direnv just dust gdu hyperfine lazydocker \
    yazi 7zip unrar python-pynvim lsof
  # tealdeer conflicts with the 'tldr' (Python) package — keep whichever client is already there
  if pacman -Qq tldr &>/dev/null; then
    info "tldr (Python client) je že nameščen — preskočim tealdeer."
  else
    pkg tealdeer
  fi
  if pacman -Qq tealdeer &>/dev/null && [[ ! -d "$HOME/.cache/tealdeer" ]]; then
    tldr --update || warn "tldr --update ni uspel — zaženi ga ročno kasneje."
  fi
  success "CLI tools ready."
}

# ==============================================================================
# 2. DOCKER — Omarchy installs it, make sure the service + group are set
# ==============================================================================
mod_docker() {
  pkg docker docker-compose docker-buildx
  sudo systemctl enable --now docker.service
  if add_to_group docker; then
    note "Dodan si v skupino 'docker' — potreben je re-login (ali: newgrp docker)."
  fi
  success "$(docker --version)"
}

# ==============================================================================
# 3. LANGUAGES — Go via mise, Python 3.12 via uv (prebuilt, no pyenv compile)
#   System python stays the default (python-pynvim, Omarchy scripts depend on it);
#   projects pick 3.12 with 'uv venv -p 3.12' or '.python-version'.
# ==============================================================================
mod_lang() {
  have mise || pkg mise
  info "Installing Go (latest) and uv via mise..."
  mise use -g go@latest uv@latest
  eval "$(mise env -s bash)"
  info "Installing Python 3.12 (uv managed)..."
  uv python install 3.12
  info "Installing uv tools (ruff, esptool)..."
  uv tool install --quiet ruff || warn "uv tool install ruff ni uspel."
  uv tool install --quiet esptool || warn "uv tool install esptool ni uspel."
  success "$(go version) | $(uv python find 3.12) | uv $(uv --version | awk '{print $2}')"
}

# ==============================================================================
# 4. EMBEDDED — serial, debuggers, udev rules (Arch uses 'uucp', not 'dialout')
# ==============================================================================
mod_embedded() {
  info "Installing embedded toolchain..."
  pkg gdb openocd minicom picocom screen dtc usbutils clang

  if add_to_group uucp; then
    note "Dodan si v skupino 'uucp' — potreben je re-login za serial dostop."
  fi

  info "Writing udev rules for USB-serial adapters..."
  sudo tee /etc/udev/rules.d/99-hexlab-embedded.rules >/dev/null <<'RULES'
# HEX-LAB: USB-serial bridges and native-USB MCUs -> group uucp, no sudo needed
# Silicon Labs CP210x
SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", MODE="0660", GROUP="uucp", TAG+="uaccess"
# FTDI
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", MODE="0660", GROUP="uucp", TAG+="uaccess"
# WCH CH340/CH341
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", MODE="0660", GROUP="uucp", TAG+="uaccess"
# Espressif native USB (ESP32-S2/S3/C3)
SUBSYSTEM=="tty", ATTRS{idVendor}=="303a", MODE="0660", GROUP="uucp", TAG+="uaccess"
SUBSYSTEM=="usb", ATTRS{idVendor}=="303a", MODE="0660", GROUP="uucp", TAG+="uaccess"
# ST-Link v2/v2.1/v3
SUBSYSTEM=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="374*", MODE="0660", GROUP="uucp", TAG+="uaccess"
# SEGGER J-Link
SUBSYSTEM=="usb", ATTRS{idVendor}=="1366", MODE="0660", GROUP="uucp", TAG+="uaccess"
# Raspberry Pi Pico / RP2040 (picoprobe, BOOTSEL)
SUBSYSTEM=="usb", ATTRS{idVendor}=="2e8a", MODE="0660", GROUP="uucp", TAG+="uaccess"
RULES
  sudo udevadm control --reload-rules && sudo udevadm trigger
  success "Embedded toolchain + udev rules installed."
}

# ==============================================================================
# 5. GIT — extras on top of Omarchy's ~/.config/git/config (via include file)
# ==============================================================================
mod_git() {
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/git"
  local inc="$dir/hexlab.gitconfig" gi="$dir/ignore"
  mkdir -p "$dir"

  info "Writing $inc..."
  cat >"$inc" <<'GIT'
# HEX-LAB additions (included from ~/.config/git/config, managed by SetupOmarchy.sh)
[core]
	pager = delta
[interactive]
	diffFilter = delta --color-only
[delta]
	navigate = true
	side-by-side = true
	line-numbers = true
[merge]
	conflictStyle = zdiff3
[rebase]
	autoStash = true
	autoSquash = true
[fetch]
	prune = true
	pruneTags = true
[help]
	autocorrect = prompt
GIT
  git config --file "$dir/config" --get-all include.path 2>/dev/null | grep -qxF "$inc" ||
    git config --file "$dir/config" --add include.path "$inc"

  if [[ ! -f "$gi" ]]; then
    cat >"$gi" <<'GI'
# Global gitignore (git reads $XDG_CONFIG_HOME/git/ignore by default)
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

  if [[ -z "$(git config --global user.email || true)" ]]; then
    note "git user.email ni nastavljen — nastavi: git config --global user.email you@example.com"
  fi
  success "git: $(git config --global user.name || echo '-') <$(git config --global user.email || echo '-')>, delta + global ignore."
}

# ==============================================================================
# 6. LAZYGIT — delta pager (Omarchy's lazygit config is empty by default)
# ==============================================================================
mod_lazygit() {
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/lazygit/config.yml"
  mkdir -p "$(dirname "$cfg")"
  if [[ -s "$cfg" ]] && grep -qvE '^\s*(#|$)' "$cfg"; then
    warn "$cfg ni prazen — ne prepisujem (delta pager dodaj ročno pod git.paging)."
    return 0
  fi
  cat >"$cfg" <<'YML'
gui:
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
YML
  success "lazygit config written."
}

# ==============================================================================
# 7. BASH — own aliases/functions/hooks, sourced from ~/.bashrc
#   Omarchy already defines: ls/lt/lsa, ff, cd (zoxide), .., c, d, g, n, t, h,
#   compress/decompress, starship, mise, fzf keybindings — those are not repeated.
# ==============================================================================
mod_bash() {
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/bash"
  local rc="$dir/hexlab.bash"
  mkdir -p "$dir"
  info "Writing $rc..."
  cat >"$rc" <<'BASHRC'
# HEX-LAB shell additions for Omarchy (managed by SetupOmarchy.sh)
# Sourced from ~/.bashrc after Omarchy's defaults.

# --- Listing / defaults ---
alias l='eza -lh --icons=auto --group-directories-first --git'
alias ll='eza -lah --icons=auto --group-directories-first --git'
alias grep='grep --color=auto'
alias diff='diff --color=auto'
alias ip='ip --color=auto'
alias df='df -h'
duh() { du -sh "${@:-.}"; }

# Safety nets — '-I' asks only for >3 files or -r
alias rm='rm -I'
alias cp='cp -i'
alias mv='mv -i'

# --- Git ---
alias gs='git status -sb'
alias gp='git push'
alias gl='git pull'
alias gd='git diff'
alias ga='git add -p'
alias glog='git log --graph --pretty="%C(blue)%h%Creset %C(green)%ar%Creset %s %C(magenta)%d%Creset" -20'
alias lg='lazygit'
gac() { git add -A && git commit -m "$*"; }
lgg() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) && lazygit -p "$root" || echo "Not a git repo."
}
fbr() {
  local b
  b=$(git branch --all | grep -v HEAD | sed 's/^[* ] //;s#remotes/origin/##' | sort -u |
    fzf --preview 'git log --oneline --color=always -20 {}') && [[ -n "$b" ]] && git checkout "$b"
}

# --- Editor ---
alias v='nvim'
alias vi='nvim'
vconf() { nvim "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"; }
fv() {
  local f
  f=$(fd --type f --hidden --exclude .git | fzf --preview 'bat -n --color=always {}') &&
    [[ -n "$f" ]] && nvim "$f"
}
rgv() {
  local out file line
  out=$(rg --line-number --no-heading --color=always "${1:-}" |
    fzf --ansi --delimiter=: --preview 'bat --color=always -H {2} {1}') || return
  file=${out%%:*}
  line=$(echo "$out" | cut -d: -f2)
  [[ -n "$file" ]] && nvim "+$line" "$file"
}

# --- Docker ---
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dex='docker exec -it'
alias dlogs='docker logs -f'
alias ld='lazydocker'

# --- Tools ---
alias hf='hyperfine'
alias disk='gdu'
alias serve='python -m http.server 8000'
alias myip='curl -s ifconfig.me; echo'
alias path='tr ":" "\n" <<<"$PATH"'
alias cl='clear && fastfetch'
alias reload='exec bash'

mkcd() { mkdir -p "$1" && cd "$1"; }
porty() { lsof -nP -iTCP:"$1" -sTCP:LISTEN; }
bak() { cp -a "$1" "$1.bak.$(date +%Y%m%d-%H%M%S)"; }
cheat() { curl -s "cheat.sh/$1"; }

fkill() {
  local sig="${1:-TERM}" pids
  pids=$(ps -ef | sed 1d | fzf -m --header="TAB za več | signal: $sig" | awk '{print $2}')
  [[ -n "$pids" ]] && echo "$pids" | xargs -r kill "-${sig}"
}

extract() {
  [[ -f "$1" ]] || { echo "Ni datoteke: $1"; return 1; }
  case "$1" in
    *.tar.gz|*.tgz)   tar xzf "$1" ;;
    *.tar.bz2|*.tbz2) tar xjf "$1" ;;
    *.tar.xz|*.txz)   tar xJf "$1" ;;
    *.tar.zst)        tar --zstd -xf "$1" ;;
    *.tar)            tar xf "$1" ;;
    *.zip)            unzip "$1" ;;
    *.7z)             7z x "$1" ;;
    *.rar)            unrar x "$1" ;;
    *.bz2)            bunzip2 "$1" ;;
    *.gz)             gunzip "$1" ;;
    *.zst)            unzstd "$1" ;;
    *)                echo "Unknown format: $1"; return 1 ;;
  esac
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

# Serial monitor (default ESP32 baud)
mon() { picocom -b "${2:-1000000}" "${1:-/dev/ttyUSB0}"; }

# --- Hooks ---
# direnv — per-project env (IDF_PATH, target chip, secrets)
command -v direnv &>/dev/null && eval "$(direnv hook bash)"

# atuin — replaces fzf's CTRL+R with synced, searchable history (needs bash-preexec)
if command -v atuin &>/dev/null && [[ -f /usr/share/bash-preexec/bash-preexec.sh ]]; then
  source /usr/share/bash-preexec/bash-preexec.sh
  eval "$(atuin init bash --disable-up-arrow)"
fi
BASHRC

  # shellcheck disable=SC2016
  ensure_line "$HOME/.bashrc" '[[ -r "${XDG_CONFIG_HOME:-$HOME/.config}/bash/hexlab.bash" ]] && source "${XDG_CONFIG_HOME:-$HOME/.config}/bash/hexlab.bash"'
  success "Bash additions installed ($rc). Odpri nov terminal ali: exec bash"
}

# ==============================================================================
# 8. FASTFETCH — GaMa87 gradient logo + extended module list
# ==============================================================================
mod_fastfetch() {
  local ff="$HOME/.config/fastfetch"
  mkdir -p "$ff"
  backup_if_exists "$ff/config.jsonc"

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
        if ch != "█": R,G,B = (R//2,G//2,B//2)
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
    { "type": "wm",       "key": "   WM" },
    { "type": "theme",    "key": "  󰏘 Theme" },
    { "type": "icons",    "key": "   Icons" },
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
# 9. APPIMAGE — auto-installer + Downloads watcher (replaces Flatpak/Craft bundles)
# ==============================================================================
mod_appimage() {
  local installer="$SCRIPT_DIR/appimage-install/install.sh"
  [[ -x "$installer" ]] || die "Ne najdem $installer"
  pkg inotify-tools libnotify fuse2
  "$installer"
  note "AppImage-e (BambuStudio, OrcaSlicer, *Craft ...) samo prenesi v ~/Downloads — namestijo se same."
  success "appimage-install ready."
}

# ==============================================================================
# 10. SUMNIKI — č/š/ž on US layout via XKB (Right Ctrl as 3rd level)
# ==============================================================================
mod_sumniki() {
  local script="$SCRIPT_DIR/sumnikiOmarchy.sh"
  [[ -f "$script" ]] || die "Ne najdem $script"
  bash "$script"
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
  # Subshell outside an 'if', so 'set -e' really stops a failing module
  set +e
  trap - ERR
  (
    set -e
    trap "$ERR_TRAP" ERR
    "mod_$m"
  )
  rc=$?
  trap "$ERR_TRAP" ERR
  set -e
  if ((rc == 0)); then
    EXECUTED+=("$m")
  else
    FAILED+=("$m")
    warn "Modul '$m' ni uspel (exit $rc) — nadaljujem."
  fi
done
mapfile -t POST_NOTES <"$NOTES_FILE"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   HEX-LAB V0.3 — OMARCHY ADD-ONS DONE    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Moduli OK:${NC} ${EXECUTED[*]:-none}"
((${#FAILED[@]})) && echo -e "${RED}Moduli FAILED:${NC} ${FAILED[*]}"

if ((${#POST_NOTES[@]})); then
  echo ""
  echo -e "${YELLOW}── NASLEDNJI KORAKI ──────────────────────────${NC}"
  for n in "${POST_NOTES[@]}"; do echo -e "${YELLOW}  •${NC} $n"; done
fi

echo ""
echo -e "${CYAN}Posodobitve:${NC} omarchy update && mise up"
echo -e "${CYAN}Editorji (opcijsko):${NC} omarchy install editor vscode|zed"
echo -e "${CYAN}Log:${NC} $LOG_FILE"
echo ""
# Non-zero exit when a module failed, without firing the ERR trap a second time
trap - ERR
((${#FAILED[@]} == 0)) || exit 1
