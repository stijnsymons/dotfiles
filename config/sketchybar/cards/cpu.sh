# shellcheck shell=bash
# CPU / memory detail. `ps -r` is already sorted by CPU, so the top consumers
# cost one call - no `top` sampling loop, which would stall the card ~2s.
#
# The first row's two numbers come from sys_lib.sh, the same helpers the cpu and
# mem items run, so the card can never quote a different figure than the bar.
source "$CONFIG_DIR/plugins/sys_lib.sh"
card_rows() {
  local cpu mem
  cpu="$(cpu_pct)"
  mem="$(mem_pct)"
  printf '󰻠\t%s\tCPU %s%%   ·   Memory %s%%\n' "$AQUA" "${cpu:-?}" "${mem:-?}"
  printf '󰍛\t%s\t%s\n' "$FG_DIM" "$(sysctl -n hw.memsize | awk '{printf "%.0f GB installed", $1/1073741824}')  ·  $(sysctl -n hw.ncpu) cores"
  ps -Aceo pcpu,comm -r 2>/dev/null | awk 'NR>1 && NR<=4 {printf "%s\t%s\t%-18s %5.1f%%\n", "󰘳", "'"$FG"'", $2, $1}'
  printf '󰄉\t%s\tup %s\t\n' "$FG_DIM" "$(uptime | sed -E 's/.*up[[:space:]]+([^,]*(,[[:space:]]*[0-9]+:[0-9]+)?).*/\1/' | sed -E 's/[[:space:]]+/ /g')"
  printf '󰘸\t%s\tOpen Activity Monitor\t%s\n' "$AQUA" "open -a 'Activity Monitor'"
}
