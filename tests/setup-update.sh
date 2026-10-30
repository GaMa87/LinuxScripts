#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
mkdir -p "$HOME" "$SANDBOX/work"
WORK_DIR="$SANDBOX/work"
CALLS="$SANDBOX/calls"
export CALLS
source <(tr -d '\r' < "$ROOT/setup-update.sh")

info() { :; }
warn() { :; }
success() { :; }
note() { printf '%s\n' "$*" >> "$CALLS"; }
have() { return 0; }
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }
gh_latest_tag() { echo v0.66.0; }
lazygit() { echo "lazygit version=$CURRENT, build=release"; }
sudo() {
  printf 'sudo %s\n' "$*" >> "$CALLS"
  if [[ "$1" == install ]]; then
    [[ "$2" == */lazygit ]] || return 1
    [[ "$3" == /usr/local/bin/lazygit ]] || return 1
  fi
}
fetch() {
  printf 'fetch %s\n' "$1" >> "$CALLS"
  [[ "$1" == "https://github.com/jesseduffield/lazygit/releases/download/v0.66.0/lazygit_0.66.0_Linux_${ARCH_ALT}.tar.gz" ]] || return 1
  [[ "${FAIL_FETCH:-0}" == 0 ]] || return 1
  tar -czf "$2" -C "$SANDBOX/asset" lazygit
}
/usr/local/bin/lazygit() {
  echo 'lazygit version=0.66.0, build=release'
}
mkdir -p "$SANDBOX/asset"
printf '#!/usr/bin/env bash\necho "lazygit version=0.66.0"\n' > "$SANDBOX/asset/lazygit"
chmod +x "$SANDBOX/asset/lazygit"

for CURRENT in 0.66.0 0.67.0; do
  : > "$CALLS"
  update_module lazygit
  [[ ! -s "$CALLS" ]]
done
for ARCH in x86_64 aarch64; do
  ARCH_ALT=x86_64
  ARCH_GO=amd64
  [[ "$ARCH" != aarch64 ]] || { ARCH_ALT=arm64; ARCH_GO=arm64; }
  CURRENT=0.65.0
  : > "$CALLS"
  update_module lazygit
  grep -q 'sudo install' "$CALLS"
done
: > "$CALLS"
FAIL_FETCH=1
if update_module lazygit; then echo 'Failed download reported success' >&2; exit 1; fi
! grep -q 'sudo install' "$CALLS"
FAIL_FETCH=0

(
  have() { return 1; }
  : > "$CALLS"
  update_module lazygit
  [[ ! -s "$CALLS" ]]
)

for config in .zshrc .gitconfig .p10k.zsh; do printf 'keep me\n' > "$HOME/$config"; done
before=$(sha256sum "$HOME"/.*)
for module in gitcfg zshrc shell fonts theme panel deskdashboard; do update_module "$module"; done
[[ "$before" == "$(sha256sum "$HOME"/.*)" ]]

UPDATE_PLATFORM=ubuntu
dpkg-query() { [[ "${*: -1}" == gh ]] && printf 'install ok installed'; }
: > "$CALLS"
update_packages gh direnv
update_packages gh
[[ "$(grep -c 'sudo apt-get update' "$CALLS")" == 1 ]]
grep -q 'sudo apt-get install -y --only-upgrade gh$' "$CALLS"
! grep -q direnv "$CALLS"
UPDATE_PLATFORM=fedora
rpm() { [[ "$2" == gh ]]; }
: > "$CALLS"
update_packages gh direnv
grep -q 'sudo dnf upgrade --refresh -y gh$' "$CALLS"
! grep -q direnv "$CALLS"

for script in Setup.sh SetupWSL.sh SetupUltraMarine.sh; do
  bash -n <(tr -d '\r' < "$ROOT/$script")
  (
    set --
    source <(sed -n '/^UPDATE_MODE=0/,/^}/p' "$ROOT/$script" | tr -d '\r')
    mod_lazygit() { echo install; }
    update_module() { echo "update:$1"; }
    [[ "$(run_selected_module lazygit)" == install ]]
    UPDATE_MODE=1
    [[ "$(run_selected_module lazygit)" == update:lazygit ]]
    set -- --update --only=lazygit,nvim --skip=nvim
    source <(sed -n '/^ALL_MODULES=(/,/^# 1\. BASE/p' "$ROOT/$script" | tr -d '\r')
    should_run lazygit
    ! should_run nvim
    ! should_run base
  )
done
bash -n "$ROOT/setup-update.sh"
if ((EUID != 0)); then
  (
    sudo() {
      printf 'sudo %s\n' "$*" >> "$CALLS"
      [[ "$*" == '-n true' || "$*" == '-v' || "${FAIL_PACKAGE:-0}" == 0 ]]
    }
    sleep() { return 1; }
    dnf() { return 1; }
    dpkg-query() { printf 'install ok installed'; }
    rpm() { return 0; }
    export -f sudo sleep dnf dpkg-query rpm
    export WSL_DISTRO_NAME=Ubuntu
    mkdir -p "$SANDBOX/scripts"
    for script in setup-update.sh Setup.sh SetupWSL.sh SetupUltraMarine.sh; do
      tr -d '\r' < "$ROOT/$script" > "$SANDBOX/scripts/$script"
    done
    for script in Setup.sh SetupWSL.sh SetupUltraMarine.sh; do
      : > "$CALLS"
      bash "$SANDBOX/scripts/$script" --update --only=zshrc
      [[ "$before" == "$(sha256sum "$HOME"/.* 2>/dev/null | grep -v '/\.local$')" ]]
      ! grep -q '/etc/wsl.conf' "$CALLS"
      export FAIL_PACKAGE=1
      if bash "$SANDBOX/scripts/$script" --update --only=base; then
        echo "$script did not report package update failure" >&2
        exit 1
      fi
      export FAIL_PACKAGE=0
    done
  )
else
  echo 'SKIP: full CLI tests require a non-root user (matching script preflight)'
fi
echo 'PASS: release updates, no downgrades, missing tools, failures, config preservation, package scope, module selection'