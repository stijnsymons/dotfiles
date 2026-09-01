# shellcheck shell=bash
# Keep-awake state. Reuses caffeine.sh's PID validation rather than re-deriving
# it, so the card and the icon can never disagree about whether it is running.
card_rows() {
  CAFFEINE_LIB=1 source "$CONFIG_DIR/plugins/caffeine.sh"
  local pid start
  if pid="$(caffeine_pid)"; then
    printf '󰅶\t%s\tKeeping this Mac awake\n' "$GREEN"
    start="$(ps -p "$pid" -o lstart= 2>/dev/null | sed -E 's/^[A-Za-z]+ +//')"
    [ -n "$start" ] && printf '󰄉\t%s\tsince %s\n' "$FG_DIM" "$start"
    printf '󰆍\t%s\tcaffeinate -i  ·  pid %s\n' "$FG_DIM" "$pid"
    printf '󰐎\t%s\tLet it sleep again\t%s\n' "$FG_DIM" "$CONFIG_DIR/plugins/caffeine_click.sh"
  else
    printf '󰾪\t%s\tNormal sleep behaviour\n' "$FG_DIM"
    printf '󰅶\t%s\tKeep this Mac awake\t%s\n' "$FG_DIM" "$CONFIG_DIR/plugins/caffeine_click.sh"
  fi
}
