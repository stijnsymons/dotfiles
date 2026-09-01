#!/usr/bin/env bash
# Up/down throughput on the default route interface.
# netstat gives cumulative byte counters, so we diff against the last sample.

source "$CONFIG_DIR/colors.sh"

# Ours, not a guessable name in a world-writable /tmp - this file is rewritten
# every 3s, so a symlink planted at that name is a free arbitrary-file clobber.
STATE="$SB_CACHE_DIR/net.counters"
IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
[ -z "$IFACE" ] && { sketchybar --set net_down label="0B/s" --set net_up label="0B/s"; exit 0; }

NOW=$(date +%s)
# Count back from the end: Coll=NF, Obytes=NF-1, Ibytes=NF-4. Robust to a
# missing Address column on interfaces without an assigned address.
read -r RX TX <<<"$(netstat -ibn -I "$IFACE" | awk 'NR>1 {print $(NF-4), $(NF-1); exit}')"
[ -z "$TX" ] && exit 0

# The interface is part of the sample: counters are per-interface, so diffing
# en0's total against a docked en11's is meaningless - and when the new one has
# counted more, that meaningless diff renders as a multi-GB/s spike.
if [ -r "$STATE" ]; then
  read -r P_IFACE P_TIME P_RX P_TX < "$STATE"
  ELAPSED=$(( NOW - ${P_TIME:-0} ))
else
  ELAPSED=0
fi
printf '%s %s %s %s\n' "$IFACE" "$NOW" "$RX" "$TX" > "$STATE"

# First run, a clock jump, a route change, or a counter reset (interface
# bounce) -> show zero.
if [ "$ELAPSED" -le 0 ] || [ "${P_IFACE:-}" != "$IFACE" ] \
   || [ "$RX" -lt "${P_RX:-0}" ] || [ "$TX" -lt "${P_TX:-0}" ]; then
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
