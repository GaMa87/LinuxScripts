#!/usr/bin/env bash

set -euo pipefail

KEYD_CONFIG="/etc/keyd/default.conf"

echo "Nameščam keyd..."

if ! command -v keyd >/dev/null 2>&1; then
  sudo dnf install -y keyd
fi

echo "Ustvarjam backup obstoječe konfiguracije..."

if sudo test -f "$KEYD_CONFIG"; then
  sudo cp "$KEYD_CONFIG" "${KEYD_CONFIG}.backup.$(date +%Y%m%d-%H%M%S)"
fi

echo "Ustvarjam novo keyd konfiguracijo..."

sudo mkdir -p /etc/keyd

sudo tee "$KEYD_CONFIG" >/dev/null <<'EOF'
[ids]

*

[main]

# Right Ctrl deluje kot prefix key za compose šumnike.
rightcontrol = layer(altgr)

[altgr]

c = macro2(300,25, macro(compose < c))
s = macro2(300,25, macro(compose < s))
z = macro2(300,25, macro(compose < z))
e = macro2(250,25, macro(compose = e))
0 = macro2(250,25, macro(compose o o))

[altgr+shift]

c = macro2(300,25, macro(compose < C))
s = macro2(250,25, macro(compose < S))
z = macro2(250,25, macro(compose < Z))
EOF

echo "Nalagam novo konfiguracijo (keyd reload)..."

sudo keyd reload

echo "Omogočam in zaganjam keyd ob zagonu sistema..."

sudo systemctl enable --now keyd

echo
echo "Nastavitev keyd je končana."
echo
echo "Bližnjice (Right Ctrl kot prefix, compose dead-key):"
echo
echo "  Right Ctrl + C          -> č"
echo "  Right Ctrl + Shift + C  -> Č"
echo "  Right Ctrl + S          -> š"
echo "  Right Ctrl + Shift + S  -> Š"
echo "  Right Ctrl + Z          -> ž"
echo "  Right Ctrl + Shift + Z  -> Ž"
echo "  Right Ctrl + E          -> ę"
echo "  Right Ctrl + 0          -> ő"
echo
echo "Preostali ročni koraki (sistemske nastavitve tipkovnice):"
echo
echo "  1. Nastavi razporeditev tipkovnice na:"
echo "     English (international, with AltGr dead keys)"
echo "  2. Onemogoči navidezne tipkovnice (virtual keyboards)."
echo "  3. Keyboard / Configure keyboard options / Position of Compose key:"
echo "     omogoči 'Menu' kot compose tipko."
echo
echo "Status preveriš z:"
echo "  systemctl status keyd"
echo
echo "Konfiguracijo lahko preveriš z:"
echo "  sudo cat /etc/keyd/default.conf"
