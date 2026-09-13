* librewolf
  * privacy/fingerprinting/enable resistfingerprinting: disable
  * privacy/history/clear/settings: disable cookies and site data
  * allow webglcontent on some sites
  * Passwords/Ask to save passwords: disable  


* Šumniki on US keyboard
  * sudo dnf install keyd
  * in /etc/keyd/default.conf
      [ids]
    *
    
    [main]
    rightcontrol = layer(altgr)
    
    [altgr]
    c = macro2(300,25, macro(compose < c))
    s = macro2(300,25, macro(compose < s))
    z = macro2(300,25, macro(compose < z))
    e = macro2(250,25, macro(compose = e))
    d = macro2(250,25, macro(compose o o))
    [altgr+shift]
    c = macro2(300,25, macro(compose < C))
    s = macro2(250,25, macro(compose < S))
    z = macro2(250,25, macro(compose < Z))
  * sudo keyd reload
  * sudo systemctl enable --now keyd
  * keyboard to english international altgr dead keys
  * disable virtual keyboards
  * keyboard/configure keyboard options/position of compose keys/Menu: enable

* Zed
  * curl -f https://zed.dev/install.sh | sh

