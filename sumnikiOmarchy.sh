#!/usr/bin/env bash

# Šumniki na US tipkovnici za Omarchy (Arch + Hyprland).
#
# Namesto keyd uporablja lastno XKB razporeditev: Right Ctrl postane
# tipka za 3. nivo (kot AltGr). Brez demona, brez sudo, brez compose
# tipke - aplikacije dobijo prave znake, zato deluje povsod pod Waylandom.
#
# libxkbcommon bere ~/.config/xkb pred sistemskimi datotekami, tako da
# razporeditev "ussi" doda samo nov symbols file. Omarchyjeva opcija
# omarchy:shift_caps_compose (Shift + Caps Lock = Compose) ostane.

set -euo pipefail

LAYOUT="ussi"
XKB_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/xkb/symbols"
XKB_FILE="$XKB_DIR/$LAYOUT"
INPUT_LUA="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/input.lua"
MARK_BEGIN="-- >>> sumnikiOmarchy >>>"
MARK_END="-- <<< sumnikiOmarchy <<<"

echo "Ustvarjam XKB razporeditev $XKB_FILE ..."

mkdir -p "$XKB_DIR"

if [[ -f "$XKB_FILE" ]]; then
  cp "$XKB_FILE" "${XKB_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
fi

cat >"$XKB_FILE" <<'EOF'
// US razporeditev + slovenski znaki na Right Ctrl (3. in 4. nivo).
// Ustvaril sumnikiOmarchy.sh

default partial alphanumeric_keys
xkb_symbols "basic" {
    include "us(basic)"

    name[Group1] = "English (US, Slovenian on Right Ctrl)";

    // Right Ctrl izbere 3. nivo (kot AltGr). XKB nima vgrajene opcije za to.
    key <RCTL> { [ ISO_Level3_Shift ], type[Group1] = "ONE_LEVEL" };

    // Right Ctrl + tipka / Right Ctrl + Shift + tipka
    key <AB03> { type[Group1] = "FOUR_LEVEL_ALPHABETIC", [ c, C, ccaron, Ccaron ] };
    key <AC02> { type[Group1] = "FOUR_LEVEL_ALPHABETIC", [ s, S, scaron, Scaron ] };
    key <AB01> { type[Group1] = "FOUR_LEVEL_ALPHABETIC", [ z, Z, zcaron, Zcaron ] };

    key <AD03> { type[Group1] = "FOUR_LEVEL_ALPHABETIC", [ e, E, EuroSign, EuroSign ] };
    key <AE10> { type[Group1] = "FOUR_LEVEL", [ 0, parenright, degree, degree ] };

    key <AE11> { type[Group1] = "FOUR_LEVEL", [ minus, underscore, endash, emdash ] };
    key <AB08> { type[Group1] = "FOUR_LEVEL", [ comma, less, doublelowquotemark, singlelowquotemark ] };
    key <AB09> { type[Group1] = "FOUR_LEVEL", [ period, greater, leftdoublequotemark, rightdoublequotemark ] };
    key <AC11> { type[Group1] = "FOUR_LEVEL", [ apostrophe, quotedbl, leftsinglequotemark, rightsinglequotemark ] };
    key <AC10> { type[Group1] = "FOUR_LEVEL", [ semicolon, colon, ellipsis, ellipsis ] };

    // Right Ctrl + P -> Print (Print Screen) za tipkovnice brez te tipke.
    key <AD10> { type[Group1] = "FOUR_LEVEL_ALPHABETIC", [ p, P, Print, Print ] };
};
EOF

echo "Preverjam, ali se razporeditev prevede ..."

if command -v xkbcli >/dev/null 2>&1; then
  if ! xkbcli compile-keymap --layout "$LAYOUT" --options omarchy:shift_caps_compose >/dev/null; then
    echo "NAPAKA: XKB razporeditev se ne prevede, input.lua ne spreminjam." >&2
    exit 1
  fi
else
  echo "xkbcli ni nameščen, preskakujem preverjanje."
fi

echo "Nastavljam Hyprland ($INPUT_LUA) ..."

mkdir -p "$(dirname "$INPUT_LUA")"
touch "$INPUT_LUA"
cp "$INPUT_LUA" "${INPUT_LUA}.backup.$(date +%Y%m%d-%H%M%S)"

# Odstrani morebitni prejšnji blok, nato ga dodaj na konec.
sed -i "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/d" "$INPUT_LUA"

cat >>"$INPUT_LUA" <<EOF
$MARK_BEGIN
-- Šumniki na Right Ctrl (XKB razporeditev ~/.config/xkb/symbols/$LAYOUT).
hl.config({
  input = {
    kb_layout = "$LAYOUT",
    kb_variant = "",
  },
})

-- Right Ctrl + P -> Print Screen. Right Ctrl je ISO_Level3_Shift (MOD5),
-- zato Hyprland dobi MOD5 + Print (keysym s 3. nivoja v XKB razporeditvi).
o.bind("MOD5 + Print", "Screenshot (Right Ctrl + P)", "omarchy-capture-screenshot")
$MARK_END
EOF

if command -v hyprctl >/dev/null 2>&1 && [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  echo "Ponovno nalagam Hyprland ..."
  hyprctl reload >/dev/null
  errors="$(hyprctl configerrors)"
  if [[ -n "${errors//[[:space:]]/}" ]]; then
    echo "OPOZORILO: Hyprland javlja napake v konfiguraciji:" >&2
    echo "$errors" >&2
  fi
fi

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
echo "  Right Ctrl + -          -> –"
echo "  Right Ctrl + Shift + -  -> —"
echo "  Right Ctrl + ,          -> „"
echo "  Right Ctrl + .          -> “"
echo "  Right Ctrl + Shift + .  -> ”"
echo "  Right Ctrl + '          -> ‘"
echo "  Right Ctrl + Shift + '  -> ’"
echo "  Right Ctrl + ;          -> …"
echo "  Right Ctrl + 0          -> °"
echo "  Right Ctrl + E          -> €"
echo "  Right Ctrl + P          -> Print Screen (screenshot)"
echo
echo "Shift + Caps Lock ostane Omarchyjeva Compose tipka."
echo
echo "Odstranitev: izbriši blok '$MARK_BEGIN' iz $INPUT_LUA"
echo "in datoteko $XKB_FILE."
