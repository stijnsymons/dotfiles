#!/usr/bin/env bash
# Up/down throughput on the default route interface.
# netstat gives cumulative byte counters, so we diff against the last sample.

source "$CONFIG_DIR/colors.sh"

STATE="${TMPDIR:-/tmp}/sketchybar_net_$(id -u)"
IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
[ -z "$IFACE" ] && { sketchybar --set net_down label="0B/s" --set net_up label="0B/s"; exit 0; }

NOW=$(date +%s)
# Count back from the end: Coll=NF, Obytes=NF-1, Ibytes=NF-4. Robust to a
# missing Address column on interfaces without an assigned address.
read -r RX TX <<<"$(netstat -ibn -I "$IFACE" | awk 'NR>1 {print $(NF-4), $(NF-1); exit}')"
[ -z "$TX" ] && exit 0

if [ -r "$STATE" ]; then
  read -r P_TIME P_RX P_TX < "$STATE"
  ELAPSED=$(( NOW - P_TIME ))
else
  ELAPSED=0
fi
printf '%s %s %s\n' "$NOW" "$RX" "$TX" > "$STATE"

# First run, a clock jump, or a counter reset (interface bounce) -> show zero.
if [ "$ELAPSED" -le 0 ] || [ "$RX" -lt "${P_RX:-0}" ] || [ "$TX" -lt "${P_TX:-0}" ]; then
  D_RATE=0; U_RATE=0
else
  D_RATE=$(( (RX - P_RX) / ELAPSED ))
  U_RATE=$(( (TX - P_TX) / ELAPSED ))
fi

human() { # bytes/s -> compact string, never wider than 5 chars
  if   [ "$1" -ge 104857600 ]; then awk -v b="$1" 'BEGIN{printf "%.0fM", b/1048576}'
  elif [ "$1" -ge 1048576 ];   then awk -v b="$1" 'BEGIN{printf "%.1fM", b/1048576}'
  elif [ "$1" -ge 1024 ];      then awk -v b="$1" 'BEGIN{printf "%.0fK", b/1024}'
  else printf '%dB' "$1"
  fi
}

sketchybar --set net_down label="$(human "$D_RATE")" \
           --set net_up   label="$(human "$U_RATE")"
