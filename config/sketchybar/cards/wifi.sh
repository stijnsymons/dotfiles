# shellcheck shell=bash
# Wi-Fi detail: the link, what it is moving, and how this machine is addressed.
#
# Laid out as label-on-the-left / value-on-the-right at a fixed pitch, the same
# idiom cards/claude.sh and cards/herdr.sh use. A popup row is one single-line
# label in a monospace font, so there is no real right-alignment - the gap is
# space padding and it only holds because every row is padded by the same code
# to the same width. Widen a label without widening the pitch and the column
# shears.
#
# networksetup -getairportnetwork is broken on macOS 15+, so the SSID comes from
# ipconfig getsummary exactly as plugins/wifi.sh does.
#
# The throughput used to be two permanent items on the bar, net_up stacked over
# net_down. A number that changes every three seconds is something you look AT
# deliberately rather than something worth ~44pt of bar next to the clock, so it
# lives here now. bin/sb-helper still samples the interface at the same rate and
# publishes the rates into helper-state.json; this quotes them rather than
# sampling again, because a rate needs two readings separated in time and the
# card has to answer on a click.

# ellipsize() in plugins/fit.sh measures with ${#text} and cuts with
# ${text:0:n}, and both count BYTES unless the shell is in a UTF-8 locale -
# under launchd it is not, because the bar inherits no LANG at all. This card is
# full of multi-byte characters (↓ ↑ · ▂▄▆█ ░), so without this a row measures
# two to three times its real width and gets truncated on the right - taking off
# exactly the value column that the label was announcing. Same fix, same reason
# as cards/claude.sh and cards/herdr.sh; the long note is in claude.sh.
export LC_ALL=en_US.UTF-8

# Total row width in characters. Under card.sh's MAX_CHARS of 64 so ellipsize()
# is a no-op on every row this card emits: truncation is done here, where the
# right-hand column can be protected, rather than there, where it cannot.
WIFI_ROW_W=44

HELPER_STATE="$SB_CACHE_DIR/helper-state.json"
HELPER_STATE_MAX_AGE=30   # several of the helper's 3s net ticks, plus slack

# helper_reading <key> -> the published value, or nothing if stale/absent.
# The freshness gate is the point: a helper that died must not leave this card
# quoting a frozen rate for as long as the file survives.
helper_reading() {
  [ -r "$HELPER_STATE" ] || return 1
  jq -er --arg k "$1" --argjson max "$HELPER_STATE_MAX_AGE" --argjson now "$(date +%s)" \
     '(if ($now - (.at // 0)) < $max then .[$k] else empty end) // empty' \
     "$HELPER_STATE" 2>/dev/null
}

# wifi_row <glyph> <colour> <label> <value> [action]
# Pads label and value apart to WIFI_ROW_W. Truncates the LABEL when the pair
# will not fit, never the value: the value is the fact, the label is only what
# names it, and a clipped IP address is worse than useless.
wifi_row() {
  local glyph=$1 colour=$2 label=$3 value=$4 action=${5:-} pad
  pad=$(( WIFI_ROW_W - ${#label} - ${#value} ))
  if [ "$pad" -lt 1 ]; then
    label="${label:0:$(( WIFI_ROW_W - ${#value} - 2 ))}…"
    pad=1
  fi
  printf '%s\t%s\t%s%*s%s\t%s\n' "$glyph" "$colour" "$label" "$pad" "" "$value" "$action"
}

card_rows() {
  local iface ssid ip router dns st down up extip rssi bars
  iface="$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}')"
  iface="${iface:-en0}"
  local summary; summary="$(ipconfig getsummary "$iface" 2>/dev/null)"
  ssid="$(printf '%s' "$summary" | awk -F' SSID : ' '/ SSID : / {print $2; exit}')"

  if [ -z "$ssid" ]; then
    printf '󰖪\t%s\tNot connected\n' "$FG_DIM"
    return
  fi

  # Link state rides on the SSID row rather than owning one. It is a property of
  # the connection named beside it, and at eight rows of budget a whole row
  # saying "link active" under a row saying the network name was the least
  # informative line on the card.
  #
  # Captured first: awk exits 0 whether or not it matched, so an `|| echo` after
  # the pipe never runs and the value would go out empty.
  st="$(printf '%s' "$summary" | awk -F': ' '/LinkStatusActive/{print "active"; exit}')"
  wifi_row '󰖩' "$BLUE" "$(card_text "$ssid")" "${st:-up}"

  # Signal, when the interface reports it. RSSI is in dBm and negative: -50 is
  # excellent, -80 is barely there. Drawn as four block cells rather than the
  # raw number because "▆▆▆░" answers the question you actually have and "-63"
  # requires you to remember the scale. The row is omitted entirely when the
  # field is absent - some drivers and every wired interface do not report it,
  # and inventing a full-strength bar for an unknown is the one thing a status
  # card must not do.
  rssi="$(printf '%s' "$summary" | awk -F': ' '/RSSI/{gsub(/[^0-9-]/,"",$2); print $2; exit}')"
  case "$rssi" in
    -[0-9]*)
      # -50 or better = 4 cells, then one cell per 10dBm down to -80.
      local lvl=$(( (rssi + 90) / 10 ))
      [ "$lvl" -gt 4 ] && lvl=4
      [ "$lvl" -lt 0 ] && lvl=0
      bars=""
      local i=1
      while [ "$i" -le 4 ]; do
        if [ "$i" -le "$lvl" ]; then bars="${bars}█"; else bars="${bars}░"; fi
        i=$(( i + 1 ))
      done
      # Colour carries the verdict so the bar does not have to be counted.
      local scol="$GREEN"
      [ "$lvl" -le 2 ] && scol="$YELLOW"
      [ "$lvl" -le 1 ] && scol="$RED"
      wifi_row '󰢾' "$scol" "Signal" "$bars  ${rssi}dBm"
      ;;
  esac

  # Down and up on ONE row. Two would cost a row for a pair that is always read
  # together - the question is almost always "is anything moving", not "how much
  # exactly, upward".
  down="$(helper_reading net_down_human)"
  up="$(helper_reading net_up_human)"
  wifi_row '󰓅' "$AQUA" "Throughput" "↓ ${down:-?}/s  ↑ ${up:-?}/s"

  ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
  [ -n "$ip" ] && wifi_row '󰩟' "$FG" "Local  ·  $iface" "$ip"

  # The public address. extip.sh answers from its cache in the common case and
  # prints nothing at all when it has never reached a provider, which is why the
  # row is conditional - "what's my IP" with no answer is worse than no row.
  # Refreshed only on wifi_change: $SENDER is set by sketchybar and is the one
  # signal that the address plausibly moved. Every other tick reads the cache,
  # so opening the card never waits on the network.
  if [ "${SENDER:-}" = "wifi_change" ]; then
    extip="$("$CONFIG_DIR/plugins/extip.sh" --refresh 2>/dev/null)"
  else
    extip="$("$CONFIG_DIR/plugins/extip.sh" 2>/dev/null)"
  fi
  [ -n "$extip" ] && wifi_row '󰖟' "$VIOLET" "Public" "$extip"

  router="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')"
  [ -n "$router" ] && wifi_row '󰑩' "$FG_DIM" "Gateway" "$router"
  dns="$(scutil --dns 2>/dev/null | awk '/nameserver\[0\]/{print $3; exit}')"
  [ -n "$dns" ] && wifi_row '󰇖' "$FG_DIM" "DNS" "$dns"

  printf '󰒓\t%s\tOpen Wi-Fi settings\t%s\n' "$AQUA" \
         "open 'x-apple.systempreferences:com.apple.wifi-settings-extension'"
}
