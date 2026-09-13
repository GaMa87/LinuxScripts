#!/usr/bin/env bash

set -euo pipefail

KEYD_CONFIG="/etc/keyd/default.conf"

echo "Nameščam keyd..."

if ! command -v keyd >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y keyd
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

# Right Ctrl deluje kot prefix key.
# Držiš Right Ctrl in pritisneš drugo tipko.
rightcontrol = layer(slovenski)

[slovenski]

# Mala č: č
c = macro(C-S-u 0 1 0 d enter)

# Mala š: š
s = macro(C-S-u 0 1 6 1 enter)

# Mala ž: ž
z = macro(C-S-u 0 1 7 e enter)

# keyd nima ločenih velikih/malih tipk, zato je za Shift+tipko
# potrebna posebna kombinirana plast (composite layer).
[shift+slovenski]

# Velika Č: Č
c = macro(C-S-u 0 1 0 c enter)

# Velika Š: Š
s = macro(C-S-u 0 1 6 0 enter)

# Velika Ž: Ž
z = macro(C-S-u 0 1 7 d enter)

# Ločila so na desni strani tipkovnice, zato gredo na Left Ctrl (control
# layer je privzeto vezan na leftcontrol) - lažje je pritisniti z drugo roko
# kot Right Ctrl, ki je zaseden za slovenske črke.
# OPOZORILO: to prepiše privzete Ctrl+, / Ctrl+. / Ctrl+- / Ctrl+; / Ctrl+'
# bližnjice v drugih programih.
[control]

# Pomišljaj: –
minus = macro(C-S-u 2 0 1 3 enter)

# Spodnji narekovaj: „
comma = macro(C-S-u 2 0 1 e enter)

# Zgornji narekovaj: "
dot = macro(C-S-u 2 0 1 c enter)

# Odpiralni enojni narekovaj: '
apostrophe = macro(C-S-u 2 0 1 8 enter)

# Tripičje: …
semicolon = macro(C-S-u 2 0 2 6 enter)

[shift+control]

# Dolgi pomišljaj: —
minus = macro(C-S-u 2 0 1 4 enter)

# Zapiralni enojni narekovaj: '
apostrophe = macro(C-S-u 2 0 1 9 enter)

# Left Ctrl + Alt deluje kot prefix za znake, ki se ne nanašajo na
# slovenske črke (Right Ctrl je zaseden kot prefix za slovenski layer,
# zato ta kombinacija sproži samo Left Ctrl, saj je Right Ctrl preusmerjen zgoraj).
[control+alt]

# Stopinje: °
0 = macro(C-S-u 0 0 b 0 enter)

# Euro: €
e = macro(C-S-u 2 0 a c enter)
EOF

echo "Omogočam keyd ob zagonu sistema..."

sudo systemctl enable keyd

echo "Ponovno zaganjam keyd..."

sudo systemctl restart keyd

echo
echo "Nastavitev je končana."
echo
echo "Bližnjice:"
echo
echo "  Right Ctrl + C          -> č"
echo "  Right Ctrl + Shift + C  -> Č"
echo "  Right Ctrl + S          -> š"
echo "  Right Ctrl + Shift + S  -> Š"
echo "  Right Ctrl + Z          -> ž"
echo "  Right Ctrl + Shift + Z  -> Ž"
echo "  Left Ctrl + -           -> –"
echo "  Left Ctrl + Shift + -   -> —"
echo "  Left Ctrl + ,           -> „"
echo "  Left Ctrl + .           -> \""
echo "  Left Ctrl + '           -> '"
echo "  Left Ctrl + Shift + '   -> '"
echo "  Left Ctrl + ;           -> …"
echo "  Left Ctrl + Alt + 0     -> °"
echo "  Left Ctrl + Alt + E     -> €"
echo
echo "Status preveriš z:"
echo "  systemctl status keyd"
echo
echo "Konfiguracijo lahko preveriš z:"
echo "  sudo cat /etc/keyd/default.conf"
