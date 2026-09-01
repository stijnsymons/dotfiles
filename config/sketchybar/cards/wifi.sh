# Wi-Fi detail. networksetup -getairportnetwork is broken on macOS 15+, so the
# SSID comes from ipconfig getsummary exactly as wifi.sh does.
card_rows() {
  local iface ssid ip router dns st
  iface="$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}')"
  iface="${iface:-en0}"
  ssid="$(ipconfig getsummary "$iface" 2>/dev/null | awk -F' SSID : ' '/ SSID : / {print $2; exit}')"
  if [ -z "$ssid" ]; then printf '󰖪\t%s\tNot connected\n' "$FG_DIM"; return; fi
  printf '󰖩\t%s\t%s\n' "$BLUE" "$(card_text "$ssid")"
  ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
  [ -n "$ip" ] && printf '󰩟\t%s\t%s  ·  %s\n' "$FG" "$ip" "$iface"
  router="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')"
  [ -n "$router" ] && printf '󰑩\t%s\tgateway %s\n' "$FG_DIM" "$router"
  dns="$(scutil --dns 2>/dev/null | awk '/nameserver\[0\]/{print $3; exit}')"
  [ -n "$dns" ] && printf '󰇖\t%s\tDNS %s\n' "$FG_DIM" "$dns"
  # Captured first: awk exits 0 whether or not it matched, so an `|| echo` after
  # the pipe never runs and the row would go out with an empty text - which
  # card.sh drops entirely.
  st="$(ipconfig getsummary "$iface" 2>/dev/null | awk -F': ' '/LinkStatusActive/{print "link active"; exit}')"
  printf '󰓅\t%s\t%s\n' "$AQUA" "${st:-link up}"
  printf '󰒓\t%s\tOpen Wi-Fi settings\t%s\n' "$AQUA" \
         "open 'x-apple.systempreferences:com.apple.wifi-settings-extension'"
}
