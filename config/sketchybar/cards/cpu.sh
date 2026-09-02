# shellcheck shell=bash
# CPU / memory detail. `ps -r` is already sorted by CPU, so the top consumers
# cost one call - no `top` sampling loop, which would stall the card ~2s.
#
# The first row's two numbers are whatever the bar is showing, not a second
# opinion about them. bin/sb-helper renders the items now and publishes what it
# rendered to helper-state.json, so the card quotes that. The reading is only
# accepted while it is fresh - a helper that died must not leave the card
# quoting a frozen number for as long as the file survives - and sys_lib.sh is
# still there as the fallback, which is also what runs when no helper was ever
# built. Either way the card and the item agree by construction, and in the
# common path the card no longer spawns its own `ps` for the summary row.
source "$CONFIG_DIR/plugins/sys_lib.sh"

HELPER_STATE="$SB_CACHE_DIR/helper-state.json"
HELPER_STATE_MAX_AGE=30   # two of the helper's 10s ticks, plus slack

# helper_reading <key> -> the published value, or nothing if stale/absent
helper_reading() {
  [ -r "$HELPER_STATE" ] || return 1
  jq -e --arg k "$1" --argjson max "$HELPER_STATE_MAX_AGE" --argjson now "$(date +%s)" \
     '(if ($now - (.at // 0)) < $max then .[$k] else empty end) // empty' \
     "$HELPER_STATE" 2>/dev/null
}

card_rows() {
  local cpu mem
  cpu="$(helper_reading cpu || cpu_pct)"
  mem="$(helper_reading mem || mem_pct)"
  printf '󰻠\t%s\tCPU %s%%   ·   Memory %s%%\n' "$AQUA" "${cpu:-?}" "${mem:-?}"
  printf '󰍛\t%s\t%s\n' "$FG_DIM" "$(sysctl -n hw.memsize | awk '{printf "%.0f GB installed", $1/1073741824}')  ·  $(sysctl -n hw.ncpu) cores"
  ps -Aceo pcpu,comm -r 2>/dev/null | awk 'NR>1 && NR<=4 {printf "%s\t%s\t%-18s %5.1f%%\n", "󰘳", "'"$FG"'", $2, $1}'
  printf '󰄉\t%s\tup %s\t\n' "$FG_DIM" "$(uptime | sed -E 's/.*up[[:space:]]+([^,]*(,[[:space:]]*[0-9]+:[0-9]+)?).*/\1/' | sed -E 's/[[:space:]]+/ /g')"
  printf '󰘸\t%s\tOpen Activity Monitor\t%s\n' "$AQUA" "open -a 'Activity Monitor'"
}
