# Productive.io timer. Reads productive.sh's cache - no API call to open.
#
# Every row goes to Brave's pinned Productive tab, per the item's own rule:
# red means start timing, green means stop it, and both live on that one page.
card_rows() {
  local cache="${PRODUCTIVE_CACHE:-$HOME/.cache/sketchybar/productive.json}"
  local tab="$CONFIG_DIR/plugins/brave_tab.sh 3"
  local j started when note
  j="$(cat "$cache" 2>/dev/null)"

  if [ -z "$j" ] || [ "$(jq -r '.running // false' <<<"$j" 2>/dev/null)" != "true" ]; then
    printf '%s\t%s\tNo timer running\t%s\n'          "$(printf '\357\201\261')" "$RED"    "$tab"
    printf '󰐊\t%s\tClick to open your timesheet\t%s\n' "$FG_DIM" "$tab"
    return
  fi

  printf '%s\t%s\t%s\t%s\n' "$(printf '\357\201\273')" "$GREEN" \
         "$(jq -r '.project // "(no project)"' <<<"$j")" "$tab"
  printf '󰃰\t%s\t%s\t%s\n' "$AQUA" \
         "$(jq -r '[.budget,.service]|map(select(.!=null and .!=""))|join("  ·  ")' <<<"$j")" "$tab"
  printf '󰅐\t%s\t%s elapsed\t%s\n' "$FG" "$(jq -r '.elapsed // "?"' <<<"$j")" "$tab"

  started="$(jq -r '.started_at // empty' <<<"$j")"
  if [ -n "$started" ]; then
    when="$(date -jf '%Y-%m-%dT%H:%M:%S' "${started%%[.+Z]*}" +%H:%M 2>/dev/null)"
    printf '󰄉\t%s\tstarted %s\t%s\n' "$FG_DIM" "${when:-$started}" "$tab"
  fi

  note="$(jq -r '.note // empty' <<<"$j")"
  [ -n "$note" ] && printf '󰎞\t%s\t%s\t%s\n' "$FG_DIM" "$note" "$tab"
}
