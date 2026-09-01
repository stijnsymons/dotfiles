# Productive.io timer. Reads productive.sh's cache - no API call to open.
#
# The detail rows go to Brave's pinned Productive tab. The planning rows below
# them do NOT: clicking one starts the timer on that project directly, which is
# the whole point - no round trip through the website to start tracking.
#
# meeting-style tier colouring is deliberate: a planning row is painted with
# the same rule the item uses, so the colour you click is the colour you get.
# timer_color comes from the plugin, so the card cannot invent its own rule.
source "$CONFIG_DIR/plugins/productive_colors.sh"

card_rows() {
  local cache="${PRODUCTIVE_CACHE:-$HOME/.cache/sketchybar/productive.json}"
  local tab="$CONFIG_DIR/plugins/brave_tab.sh 3"
  local j started iso when note
  j="$(cat "$cache" 2>/dev/null)"

  if [ -z "$j" ] || [ "$(jq -r '.running // false' <<<"$j" 2>/dev/null)" != "true" ]; then
    printf '%s\t%s\tNo timer running\t%s\n'          "$(printf '\357\201\261')" "$RED"    "$tab"
    printf '󰐊\t%s\tClick to open your timesheet\t%s\n' "$FG_DIM" "$tab"
    productive_plan_rows
    return
  fi

  printf '%s\t%s\t%s\t%s\n' "$(printf '\357\201\273')" "$GREEN" \
         "$(card_text "$(jq -r '.project // "(no project)"' <<<"$j")")" "$tab"
  printf '󰃰\t%s\t%s\t%s\n' "$AQUA" \
         "$(card_text "$(jq -r '[.budget,.service]|map(select(.!=null and .!=""))|join("  ·  ")' <<<"$j")")" "$tab"
  printf '󰅐\t%s\t%s elapsed\t%s\n' "$FG" "$(jq -r '.elapsed // "?"' <<<"$j")" "$tab"

  started="$(jq -r '.started_at // empty' <<<"$j")"
  if [ -n "$started" ]; then
    # started_at carries a zone. Truncating it and parsing with a naive format
    # reads UTC as local and shows a 09:12 CEST start as 07:12, so parse the
    # offset: Z -> +0000, no fractional seconds, no colon in the offset.
    iso="$(printf '%s' "$started" | sed -E 's/\.[0-9]+//; s/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')"
    when="$(date -jf '%Y-%m-%dT%H:%M:%S%z' "$iso" +%H:%M 2>/dev/null)"
    [ -n "$when" ] || when="$(date -jf '%Y-%m-%dT%H:%M:%S' "${started%%[.+Z]*}" +%H:%M 2>/dev/null)"
    printf '󰄉\t%s\tstarted %s\t%s\n' "$FG_DIM" "${when:-$started}" "$tab"
  fi

  note="$(jq -r '.note // empty' <<<"$j")"
  [ -n "$note" ] && printf '󰎞\t%s\t%s\t%s\n' "$FG_DIM" "$(card_text "$note")" "$tab"

  productive_plan_rows
}

# This week's planning: one row per project you are booked on, clicking it
# starts the timer against that project's booked service. productive_plan.sh
# keeps the cache warm; this only reads it, so the card still opens instantly.
productive_plan_rows() {
  local plan row project sid color running_project running_task tab
  tab="$CONFIG_DIR/plugins/brave_tab.sh 3"
  plan="${PRODUCTIVE_PLAN_CACHE:-$HOME/.cache/sketchybar/productive-plan.json}"
  [ -s "$plan" ] || return 0

  running_project="$(jq -r '.project // ""' "${PRODUCTIVE_CACHE:-$HOME/.cache/sketchybar/productive.json}" 2>/dev/null)"
  running_task="$(jq -r '.task // ""' "${PRODUCTIVE_CACHE:-$HOME/.cache/sketchybar/productive.json}" 2>/dev/null)"

  while IFS= read -r row; do
    [ -z "$row" ] && continue
    project="$(jq -r '.project' <<<"$row")"
    sid="$(jq -r '.service_id' <<<"$row")"
    [ -n "$sid" ] || continue
    color="$(timer_color "$project" "")"
    # Mark the one already running rather than offering to restart it.
    if [ "$project" = "$running_project" ]; then
      printf '󰔟\t%s\t%s  ·  timing now\t%s\n' "$(timer_color "$project" "$running_task")" "$(card_text "$project")" "$tab"
    else
      # The service is shown, not hidden: it is what the time actually books
      # against, and it is not always the role you are planned as.
      printf '󰐊\t%s\t%s  ·  %s\t%s\n' "$color" "$(card_text "$project")" \
             "$(card_text "$(jq -r '.service // ""' <<<"$row")")" \
             "$CONFIG_DIR/plugins/productive_start.sh $sid"
    fi
  done <<<"$(jq -c '.[]?' "$plan" 2>/dev/null)"
}
