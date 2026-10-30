#!/usr/bin/env bash

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

update_summary() {
  info "Update finished. Successful modules: ${EXECUTED[*]:-none}"
  if ((${#FAILED[@]})); then
    warn "Failed modules: ${FAILED[*]}"
  fi
  local message
  for message in "${POST_NOTES[@]}"; do info "$message"; done
  info "User configuration was preserved. Log: $LOG_FILE"
  ((${#FAILED[@]} == 0))
}

update_version() {
  grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sed -n '1p'
}

update_packages() {
  local package
  local installed=()
  for package in "$@"; do
    if [[ "$UPDATE_PLATFORM" == fedora ]]; then
      rpm -q "$package" &>/dev/null && installed+=("$package")
    elif [[ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" == 'install ok installed' ]]; then
      installed+=("$package")
    fi
  done
  ((${#installed[@]})) || return 0
  if [[ "$UPDATE_PLATFORM" == fedora ]]; then
    sudo dnf upgrade --refresh -y "${installed[@]}"
  else
    if [[ "${UPDATE_APT_REFRESHED:-0}" == 0 ]]; then
      sudo apt-get update -qq || return 1
      UPDATE_APT_REFRESHED=1
    fi
    sudo apt-get install -y --only-upgrade "${installed[@]}"
  fi
}

update_checkout() {
  local directory="$1"
  [[ -d "$directory/.git" ]] || return 0
  if [[ -n "$(git -C "$directory" status --porcelain)" ]]; then
    warn "Keeping local changes in $directory; skipping update."
    return 0
  fi
  git -C "$directory" pull --ff-only
}

update_github() (
  local binary="$1" repo="$2" current tag latest target asset archive directory found
  have "$binary" || { info "$binary is not installed; skipping."; return 0; }
  current=$("$binary" --version 2>&1 | update_version || true)
  tag=$(gh_latest_tag "$repo") || return 1
  latest=$(printf '%s\n' "$tag" | update_version)
  [[ -n "$latest" ]] || { warn "Invalid release tag for $repo: $tag"; return 1; }
  if version_ge "$current" "$latest"; then
    success "$binary $current is current (latest stable: $latest)."
    return 0
  fi
  target="${ARCH}-unknown-linux-musl"
  case "$binary" in
    lazygit|lazydocker) asset="${binary}_${latest}_Linux_${ARCH_ALT}.tar.gz" ;;
    gdu) asset="gdu_linux_${ARCH_GO}.tgz" ;;
    delta|hyperfine)
      [[ "$ARCH" == aarch64 ]] && target="aarch64-unknown-linux-gnu"
      if [[ "$binary" == delta ]]; then
        asset="delta-${latest}-${target}.tar.gz"
      else
        asset="hyperfine-v${latest}-${target}.tar.gz"
      fi
      ;;
    atuin) asset="atuin-${target}.tar.gz" ;;
    just) asset="just-${tag}-${target}.tar.gz" ;;
    dust) asset="dust-v${latest}-${target}.tar.gz" ;;
    yazi) asset="yazi-${target}.zip" ;;
    nvim) asset="nvim-linux-${ARCH_ALT}.tar.gz" ;;
    *) warn "No release asset mapping for $binary"; return 1 ;;
  esac
  directory=$(mktemp -d "$WORK_DIR/update-${binary}.XXXXXX") || return 1
  cd "$directory" || return 1
  archive="$directory/$asset"
  info "Updating $binary ${current:-unknown} -> $latest..."
  fetch "https://github.com/${repo}/releases/download/${tag}/${asset}" "$archive" || return 1
  if [[ "$asset" == *.zip ]]; then
    unzip -oq "$archive" || return 1
  else
    tar xf "$archive" || return 1
  fi
  if [[ "$binary" == nvim ]]; then
    [[ -x "nvim-linux-${ARCH_ALT}/bin/nvim" ]] || return 1
    sudo mkdir -p /opt || return 1
    sudo rm -rf "/opt/nvim-linux-${ARCH_ALT}" || return 1
    sudo mv "nvim-linux-${ARCH_ALT}" /opt/ || return 1
    sudo ln -sf "/opt/nvim-linux-${ARCH_ALT}/bin/nvim" /usr/local/bin/nvim || return 1
  else
    if [[ "$binary" == gdu ]]; then
      found=$(find . -type f -name "gdu_linux_${ARCH_GO}" -print -quit)
    else
      found=$(find . -type f -name "$binary" -print -quit)
    fi
    [[ -n "$found" ]] || { warn "$binary missing from release archive"; return 1; }
    sudo install "$found" "/usr/local/bin/$binary" || return 1
    if [[ "$binary" == yazi ]]; then
      found=$(find . -type f -name ya -print -quit)
      [[ -n "$found" ]] && sudo install "$found" /usr/local/bin/ya || return 1
    fi
  fi
  hash -r
  current=$("/usr/local/bin/$binary" --version 2>&1 | update_version || true)
  version_ge "$current" "$latest" || { warn "$binary update verification failed"; return 1; }
  success "$binary $current installed in /usr/local/bin."
  if [[ "$(command -v "$binary")" != "/usr/local/bin/$binary" ]]; then
    warn "PATH still selects $(command -v "$binary"); put /usr/local/bin first to use the update."
  fi
)

update_go() (
  have go || { info "Go is not installed; skipping."; return 0; }
  local current latest directory
  current=$(go version | update_version)
  latest=$(curl -fsSL --retry 3 'https://go.dev/dl/?mode=json' | jq -r '.[0].version // empty') || return 1
  [[ "$latest" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  version_ge "$current" "${latest#go}" && { success "Go $current is current."; return 0; }
  directory=$(mktemp -d "$WORK_DIR/update-go.XXXXXX") || return 1
  fetch "https://go.dev/dl/${latest}.linux-${ARCH_GO}.tar.gz" "$directory/go.tar.gz" || return 1
  tar -xzf "$directory/go.tar.gz" -C "$directory" || return 1
  "$directory/go/bin/go" version || return 1
  sudo rm -rf /usr/local/go || return 1
  sudo mv "$directory/go" /usr/local/go || return 1
  sudo ln -sf /usr/local/go/bin/go /usr/local/bin/go || return 1
  sudo ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt || return 1
  /usr/local/go/bin/go version
)

update_python() (
  [[ -d "$HOME/.pyenv" ]] || { info "pyenv is not installed; skipping."; return 0; }
  update_checkout "$HOME/.pyenv" || return 1
  export PYENV_ROOT="$HOME/.pyenv"
  export PATH="$PYENV_ROOT/bin:$PATH"
  local latest options='--enable-optimizations --with-lto'
  latest=$(pyenv install --list | sed -nE 's/^ +((3\.12)\.[0-9]+)$/\1/p' | sort -V | tail -1)
  [[ -n "$latest" ]] || return 1
  [[ -n "${HEXLAB_PY_FAST:-}" ]] && options='--enable-shared'
  PYTHON_CONFIGURE_OPTS="$options" MAKE_OPTS="-j$(nproc)" pyenv install -s "$latest" || return 1
  note "Python $latest installed; existing pyenv global/local selections are unchanged. Select it with: pyenv global $latest"
)

update_craft() (
  have flatpak || return 0
  local entry repo name app tag current directory
  directory=$(mktemp -d "$WORK_DIR/update-craft.XXXXXX") || return 1
  for entry in "${CRAFT_APPS[@]}"; do
    repo="${entry%%:*}"
    name="${entry#*:}"
    app="ai.storyteller.${name}"
    flatpak info --user "$app" &>/dev/null || continue
    current=$(LC_ALL=C flatpak info --user "$app" | sed -nE 's/^ *Version: *(.+)$/\1/p')
    tag=$(gh_latest_tag "storytold/$repo") || return 1
    if version_ge "$current" "${tag#v}"; then
      success "$app $current is current."
      continue
    fi
    fetch "https://github.com/storytold/${repo}/releases/download/${tag}/${name}-${tag#v}-linux-${ARCH}.flatpak" "$directory/$name.flatpak" || return 1
    flatpak install --user -y --noninteractive --reinstall "$directory/$name.flatpak" || return 1
  done
  if flatpak info --user ai.storyteller.solidcraft &>/dev/null; then
    flatpak update --user -y --noninteractive ai.storyteller.solidcraft || return 1
  fi
)

update_windows_vscode() {
  if ! have powershell.exe; then
    note "Windows interop is unavailable; update VS Code on Windows via Help > Check for Updates."
    return 0
  fi
  powershell.exe -NoProfile -NonInteractive -Command '
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
      Write-Output "winget is unavailable; use VS Code Help > Check for Updates."
      exit 0
    }
    winget.exe upgrade --exact --id Microsoft.VisualStudioCode --silent --disable-interactivity --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -eq 0x8A15002B) { exit 0 }
    exit $LASTEXITCODE
  '
}

update_module() {
  local module="$1" tool custom app
  case "$module" in
    lazygit) update_github lazygit jesseduffield/lazygit ;;
    lazydocker) update_github lazydocker jesseduffield/lazydocker ;;
    gdu) update_github gdu dundee/gdu ;;
    delta) update_github delta dandavison/delta ;;
    atuin) update_github atuin atuinsh/atuin ;;
    hyperfine) update_github hyperfine sharkdp/hyperfine ;;
    yazi) update_github yazi sxyazi/yazi ;;
    nvim) update_github nvim neovim/neovim ;;
    golang) update_go ;;
    pyenv) update_python ;;
    base)
      update_packages curl wget git cmake ninja-build python3-pip pipx ripgrep fd-find bat file \
        zoxide fzf btop fastfetch zsh tealdeer fontconfig lsof unzip zstd ca-certificates jq \
        build-essential pkg-config python3-venv libusb-1.0-0-dev libssl-dev zlib1g-dev \
        libbz2-dev libreadline-dev libsqlite3-dev libncursesw5-dev xz-utils tk-dev libxml2-dev \
        libxmlsec1-dev libffi-dev liblzma-dev libgdbm-dev uuid-dev libnsl-dev p7zip-full gnupg \
        xclip wl-clipboard usb-creator-gtk flatpak fonts-noto-color-emoji \
        gcc gcc-c++ make automake autoconf libtool patch pkgconf-pkg-config libusb1-devel \
        openssl-devel zlib-devel bzip2-devel readline-devel sqlite-devel ncurses-devel xz \
        tk-devel libxml2-devel xmlsec1-devel libffi-devel xz-devel gdbm-devel libuuid-devel \
        libnsl2-devel p7zip p7zip-plugins gnupg2 mediawriter google-noto-color-emoji-fonts
      ;;
    embedded)
      update_packages gdb gdb-multiarch openocd minicom picocom screen clangd clang-format \
        clang-tidy clang-tools-extra dtc device-tree-compiler srecord usbutils
      ;;
    docker)
      if [[ "$UPDATE_PLATFORM" == wsl ]] && have docker && docker info 2>/dev/null | grep -qi 'Docker Desktop'; then
        note "Update Docker Desktop on Windows; its WSL integration is left unchanged."
      else
        update_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      fi
      ;;
    node)
      have node || { info "Node.js is not installed; skipping."; return 0; }
      if [[ "$UPDATE_PLATFORM" == fedora ]]; then
        curl -fsSL https://rpm.nodesource.com/setup_lts.x -o "$WORK_DIR/nodesource.sh" || return 1
      else
        curl -fsSL https://deb.nodesource.com/setup_lts.x -o "$WORK_DIR/nodesource.sh" || return 1
      fi
      sudo -E bash "$WORK_DIR/nodesource.sh" || return 1
      update_packages nodejs
      ;;
    uv)
      have uv || { info "uv is not installed; skipping."; return 0; }
      uv self update || return 1
      for tool in ruff esptool pynvim; do
        if uv tool list | grep -qE "^${tool} "; then
          uv tool upgrade "$tool" || return 1
        fi
      done
      ;;
    devtools)
      update_packages gh direnv || return 1
      update_github just casey/just || return 1
      update_github dust bootandy/dust
      ;;
    eza|wezterm|fastfetch) update_packages "$module" ;;
    tealdeer)
      update_packages tealdeer || return 1
      if have tldr; then tldr --update; fi
      ;;
    vscode)
      if [[ "$UPDATE_PLATFORM" == wsl ]]; then
        update_windows_vscode
      else
        update_packages code
      fi
      ;;
    claude) if have claude; then claude update; fi ;;
    zed)
      if have zed; then
        curl -fsSL https://zed.dev/install.sh -o "$WORK_DIR/zed-install.sh" || return 1
        sh "$WORK_DIR/zed-install.sh"
      fi
      ;;
    ohmyzsh)
      update_checkout "$HOME/.oh-my-zsh" || return 1
      custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
      for tool in themes/powerlevel10k plugins/zsh-autosuggestions plugins/zsh-syntax-highlighting; do
        update_checkout "$custom/$tool" || return 1
      done
      ;;
    flatpaks)
      have flatpak || return 0
      for app in "${FLATHUB_APPS[@]}"; do
        if flatpak info --system "$app" &>/dev/null; then
          sudo flatpak update --system -y --noninteractive "$app" || return 1
        fi
      done
      ;;
    craft) update_craft ;;
    fonts|theme|panel|deskdashboard|gitcfg|zshrc|shell)
      info "Keeping $module unchanged in update mode."
      ;;
    *) warn "No update handler for module: $module"; return 1 ;;
  esac
}