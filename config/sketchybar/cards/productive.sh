# Productive.io timer. Reads productive.sh's cache - no API call on hover.
card_rows() {
  local cache="${PRODUCTIVE_CACHE:-$HOME/.cache/sketchybar/productive.json}"
  local j started
  j="$(cat "$cache" 2>/dev/null)"
  if [ -z "$j" ] || [ "$(jq -r '.running // false' <<<"$j" 2>/dev/null)" != "true" ]; then
    printf '%s\t%s\tNo timer running\n' "$(printf '\357\201\261')" "$RED"
    printf '󰐊\t%s\tClick to open your timesheet\n' "$FG_DIM"
    return
  fi
  printf '%s\t%s\t%s\n' "$(printf '\357\201\273')" "$GREEN" "$(jq -r '.project // "(no project)"' <<<"$j")"
  printf '󰃰\t%s\t%s\n' "$AQUA"  "$(jq -r '[.budget,.service]|map(select(.!=null and .!=""))|join("  ·  ")' <<<"$j")"
  printf '󰅐\t%s\t%s elapsed\n' "$FG" "$(jq -r '.elapsed // "?"' <<<"$j")"
  started="$(jq -r '.started_at // empty' <<<"$j")"
  [ -n "$started" ] && printf '󰄉\t%s\tstarted %s\n' "$FG_DIM" \
    "$(date -jf '%Y-%m-%dT%H:%M:%S' "${started%%[.+Z]*}" +%H:%M 2>/dev/null || printf '%s' "$started")"
  local note; note="$(jq -r '.note // empty' <<<"$j")"
  [ -n "$note" ] && printf '󰎞\t%s\t%s\n' "$FG_DIM" "$note"
}
