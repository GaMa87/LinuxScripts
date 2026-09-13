#!/usr/bin/env bash
#
# install-sweet-kde.sh — Sweet theme for KDE Plasma 6 (Fedora / Ultramarine)
#
# Komponente:
#   Plasma style .... EliverLara/Sweet-kde        -> ~/.local/share/plasma/desktoptheme/Sweet
#   Color scheme .... Sweet (dark-plasma-6)       -> ~/.local/share/color-schemes/
#   Window deco ..... Sweet-Dark (aurorae)        -> ~/.local/share/aurorae/themes/
#   Widget style .... Kvantum Sweet               -> ~/.config/Kvantum/
#   Cursors ......... Sweet-cursors               -> ~/.local/share/icons/
#   Icons ........... candy-icons                 -> ~/.local/share/icons/
#   Konsole ......... Sweet.colorscheme           -> ~/.local/share/konsole/
#   GTK ............. Sweet                       -> ~/.themes/
#
# Uporaba:  ./install-sweet-kde.sh [--no-backup] [--no-gtk] [--no-apply] [--uninstall]

set -euo pipefail

SRC="${SWEET_SRC:-$HOME/.cache/sweet-src}"
LOCAL="$HOME/.local/share"
STAMP="$(date +%Y%m%d-%H%M%S)"

DO_BACKUP=1
DO_GTK=1
DO_APPLY=1
ACTION="install"

# ---------------------------------------------------------------- helpers ---
c_ok=$'\e[32m'
c_warn=$'\e[33m'
c_err=$'\e[31m'
c_dim=$'\e[2m'
c_off=$'\e[0m'
msg() { printf '%s::%s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s!!%s %s\n' "$c_warn" "$c_off" "$*" >&2; }
die() {
  printf '%sxx%s %s\n' "$c_err" "$c_off" "$*" >&2
  exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  awk 'NR>1 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "$0"
  exit 0
}

# Prepiše brez vprašanj tudi ob 'alias cp=cp -i'.
copy() { command cp -rf "$@"; }

# Odmakne pot v <pot>.bak-<stamp>, če obstaja.
backup() {
  local p="$1"
  [ -e "$p" ] || return 0
  if [ "$DO_BACKUP" -eq 1 ]; then
    mv "$p" "$p.bak-$STAMP"
    printf '%s   backup: %s.bak-%s%s\n' "$c_dim" "$p" "$STAMP" "$c_off"
  else
    rm -rf "$p"
  fi
}

# git clone ali osvežitev obstoječega klona.
fetch_repo() {
  local url="$1" dir="$2" branch="${3:-}"
  if [ -d "$dir/.git" ]; then
    msg "posodabljam $(basename "$dir")"
    git -C "$dir" fetch --depth 1 origin "${branch:-HEAD}" -q
    git -C "$dir" reset --hard -q FETCH_HEAD
  else
    msg "kloniram $(basename "$dir")"
    rm -rf "$dir"
    if [ -n "$branch" ]; then
      git clone --depth 1 -b "$branch" -q "$url" "$dir"
    else
      git clone --depth 1 -q "$url" "$dir"
    fi
  fi
}

# ------------------------------------------------------------------- args ---
while [ $# -gt 0 ]; do
  case "$1" in
  --no-backup) DO_BACKUP=0 ;;
  --no-gtk) DO_GTK=0 ;;
  --no-apply) DO_APPLY=0 ;;
  --uninstall) ACTION="uninstall" ;;
  -h | --help) usage ;;
  *) die "neznana opcija: $1 (--help za pomoč)" ;;
  esac
  shift
done

# -------------------------------------------------------------- uninstall ---
if [ "$ACTION" = "uninstall" ]; then
  msg "odstranjujem Sweet"
  rm -rf "$LOCAL/plasma/desktoptheme/Sweet" \
    "$LOCAL/aurorae/themes/Sweet-Dark" \
    "$LOCAL/aurorae/themes/Sweet-Dark-transparent" \
    "$HOME/.config/Kvantum/Sweet" \
    "$HOME/.config/Kvantum/Sweet-transparent-toolbar" \
    "$LOCAL/icons/Sweet-cursors" \
    "$LOCAL/icons/candy-icons" \
    "$LOCAL/color-schemes/Sweet.colors" \
    "$LOCAL/konsole/Sweet.colorscheme" \
    "$HOME/.themes/Sweet"
  if [ "$DO_APPLY" -eq 1 ] && have plasma-apply-desktoptheme; then
    plasma-apply-desktoptheme default || true
    plasma-apply-colorscheme BreezeDark || true
    plasma-apply-cursortheme breeze_cursors || true
    kwriteconfig6 --file kdeglobals --group Icons --key Theme breeze-dark
    kwriteconfig6 --file kdeglobals --group KDE --key widgetStyle Breeze
    kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key library org.kde.breeze
    kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key theme Breeze
    have qdbus6 && qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
  fi
  msg "končano (backupi .bak-* ostanejo nedotaknjeni)"
  exit 0
fi

# ------------------------------------------------------------------ checks ---
have git || die "manjka git: sudo dnf install git"
have plasmashell || warn "plasmashell ni najden — si res na KDE Plasma?"
have kvantummanager || warn "Kvantum ni nameščen: sudo dnf install kvantum (widget style bo ostal Breeze)"

# ------------------------------------------------------------------ fetch ---
mkdir -p "$SRC"
fetch_repo https://github.com/EliverLara/Sweet.git "$SRC/Sweet" dark-plasma-6
fetch_repo https://github.com/EliverLara/Sweet-kde.git "$SRC/Sweet-kde"
fetch_repo https://github.com/EliverLara/candy-icons.git "$SRC/candy-icons"

# ---------------------------------------------------------------- install ---
mkdir -p "$LOCAL"/{color-schemes,aurorae/themes,icons,konsole,plasma/desktoptheme} \
  "$HOME/.config/Kvantum" "$HOME/.themes"

msg "nameščam komponente"
for p in "$LOCAL/color-schemes/Sweet.colors" \
  "$LOCAL/konsole/Sweet.colorscheme" \
  "$LOCAL/aurorae/themes/Sweet-Dark" \
  "$LOCAL/aurorae/themes/Sweet-Dark-transparent" \
  "$HOME/.config/Kvantum/Sweet" \
  "$HOME/.config/Kvantum/Sweet-transparent-toolbar" \
  "$LOCAL/icons/Sweet-cursors" \
  "$LOCAL/icons/candy-icons" \
  "$LOCAL/plasma/desktoptheme/Sweet" \
  "$HOME/.themes/Sweet"; do
  backup "$p"
done

copy "$SRC/Sweet/kde/colorschemes/Sweet.colors" "$LOCAL/color-schemes/"
copy "$SRC/Sweet/kde/konsole/Sweet.colorscheme" "$LOCAL/konsole/"
copy "$SRC/Sweet/kde/aurorae/"* "$LOCAL/aurorae/themes/"
copy "$SRC/Sweet/kde/Kvantum/"* "$HOME/.config/Kvantum/"
copy "$SRC/Sweet/kde/cursors/Sweet-cursors" "$LOCAL/icons/"
copy "$SRC/candy-icons" "$LOCAL/icons/"
copy "$SRC/Sweet-kde" "$LOCAL/plasma/desktoptheme/Sweet"
rm -rf "$LOCAL/icons/candy-icons/.git" \
  "$LOCAL/plasma/desktoptheme/Sweet/.git" \
  "$LOCAL/plasma/desktoptheme/Sweet/.github" \
  "$LOCAL/plasma/desktoptheme/Sweet/preview"

if [ "$DO_GTK" -eq 1 ]; then
  mkdir -p "$HOME/.themes/Sweet"
  copy "$SRC/Sweet"/{gtk-2.0,gtk-3.0,gtk-4.0,assets,index.theme} "$HOME/.themes/Sweet/"
fi

# Plasma 6 (KF6) bere metadata.json; Sweet ima še Plasma 5 metadata.desktop,
# zato tema brez tega ne pade v Plasma Style seznam.
msg "pišem metadata.json"
cat >"$LOCAL/plasma/desktoptheme/Sweet/metadata.json" <<'EOF'
{
    "KPackageStructure": "Plasma/Theme",
    "KPlugin": {
        "Authors": [{ "Email": "eliverlara@gmail.com", "Name": "EliverLara" }],
        "Category": "Plasma Theme",
        "Description": "A dark and modern theme for Plasma",
        "EnabledByDefault": true,
        "Id": "Sweet",
        "License": "CC BY-SA 4.0",
        "Name": "Sweet",
        "Version": "1.0.0",
        "Website": "https://github.com/EliverLara/Sweet"
    },
    "AdaptiveTransparency": { "enabled": true }
}
EOF

# ------------------------------------------------------------------ apply ---
if [ "$DO_APPLY" -eq 0 ]; then
  msg "nameščeno; aktivacija preskočena (--no-apply)"
  exit 0
fi

msg "aktiviram"
for f in kdeglobals kwinrc kcminputrc plasmarc; do
  [ -f "$HOME/.config/$f" ] && [ "$DO_BACKUP" -eq 1 ] &&
    command cp -f "$HOME/.config/$f" "$HOME/.config/$f.bak-$STAMP"
done

have plasma-apply-desktoptheme && plasma-apply-desktoptheme Sweet || true
have plasma-apply-colorscheme && plasma-apply-colorscheme Sweet || true
have plasma-apply-cursortheme && plasma-apply-cursortheme Sweet-cursors || true

if have kwriteconfig6; then
  kwriteconfig6 --file kdeglobals --group Icons --key Theme candy-icons
  have kvantummanager && kwriteconfig6 --file kdeglobals --group KDE --key widgetStyle kvantum
  # KWin Plasma 6 bere dekoracijo še vedno iz skupine org.kde.kdecoration2
  kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key library org.kde.kwin.aurorae
  kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key theme __aurorae__svg__Sweet-Dark
fi

have kvantummanager && kvantummanager --set Sweet >/dev/null 2>&1 || true
have qdbus6 && qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true

msg "končano — odjavi in prijavi se, da se vse usede"
echo "   GTK temo Sweet izberi v System Settings > Colors & Themes > Application Style > GNOME/GTK"
echo "   Razveljavitev: $0 --uninstall"
