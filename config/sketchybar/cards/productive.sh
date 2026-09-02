# shellcheck shell=bash
# Productive.io timer. Reads productive.sh's cache - no API call to open.
#
# The detail rows go to Brave's pinned Productive tab. The planning rows below
# them do NOT: clicking one starts the timer on that booking directly, which is
# the whole point - no round trip through the website to start tracking. The
# exception is a booking with no service anyone can start; that row stays, dim,
# and falls back to the tab.
#
# meeting-style tier colouring is deliberate: a planning row is painted with
# the same rule the item uses, so the colour you click is the colour you get.
# timer_color comes from the plugin, so the card cannot invent its own rule.
source "$CONFIG_DIR/plugins/productive_colors.sh"

card_rows() {
  local cache="${PRODUCTIVE_CACHE:-$SB_CACHE_DIR/productive.json}"
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
    # Both dates failing falls back to the raw API string, which is the one
    # path here that prints a field the API wrote - so it goes through card_text
    # like every other one.
    printf '󰄉\t%s\tstarted %s\t%s\n' "$FG_DIM" "${when:-$(card_text "$started")}" "$tab"
  fi

  note="$(jq -r '.note // empty' <<<"$j")"
  [ -n "$note" ] && printf '󰎞\t%s\t%s\t%s\n' "$FG_DIM" "$(card_text "$note")" "$tab"

  productive_plan_rows
}

# This week's planning: one row per BOOKING - a project booked under two
# budgets is two rows, because the budget is what the time books against and
# they are two different plans. Clicking a row starts the timer against that
# booking's resolved service. productive_plan.sh keeps the cache warm; this
# only reads it, so the card still opens instantly.
productive_plan_rows() {
  local plan cache project budget label sid tab
  local running_sid="" running_project="" running_budget="" running_task=""
  tab="$CONFIG_DIR/plugins/brave_tab.sh 3"
  plan="${PRODUCTIVE_PLAN_CACHE:-$SB_CACHE_DIR/productive-plan.json}"
  cache="${PRODUCTIVE_CACHE:-$SB_CACHE_DIR/productive.json}"
  [ -s "$plan" ] || return 0

  # One jq for the running timer and one for the whole plan, not three per row:
  # this runs on the click path, and the card is now sixteen rows deep.
  { IFS= read -r running_sid; IFS= read -r running_project
    IFS= read -r running_budget; IFS= read -r running_task; } <<PJEOF
$(jq -r '(.service_id // ""), (.project // ""), (.budget // ""), (.task // "")' "$cache" 2>/dev/null)
PJEOF

  # Fields are separated by US (0x1f), like the meeting card: a tab would be
  # stripped by card_text and a space is legal inside a budget name.
  while IFS=$'\037' read -r project budget sid; do
    [ -z "$project" ] && continue
    # The budget is shown, not the booked role: it is what the time actually
    # books against, and it is what tells two bookings on one project apart. A
    # cache written before budgets were carried has none, so the service
    # stands in.
    label="$(card_text "$project")"
    [ -n "$budget" ] && label="$label  ·  $(card_text "$budget")"
    # Mark the one already running rather than offering to restart it. Matched
    # on the service the timer is actually on, with project plus budget as the
    # fallback for a timer started from the website against some other service:
    # the project alone would light up both rows of a twice-booked project.
    if { [ -n "$sid" ] && [ "$sid" = "$running_sid" ]; } ||
       { [ -n "$running_project" ] && [ "$project" = "$running_project" ] &&
         { [ -z "$running_budget" ] || [ "$budget" = "$running_budget" ]; }; }; then
      # Project only here: the budget, service and elapsed are the detail rows
      # directly above this one.
      printf '󰔟\t%s\t%s  ·  timing now\t%s\n' \
             "$(timer_color "$project" "$running_task")" "$(card_text "$project")" "$tab"
    elif [ -n "$sid" ]; then
      printf '󰐊\t%s\t%s\t%s\n' "$(timer_color "$project" "")" "$label" \
             "$CONFIG_DIR/plugins/productive_start.sh $sid"
    else
      # Nothing trackable and accessible could be resolved for this booking, so
      # there is no timer to offer. The row stays anyway: it is still your week,
      # and a row you cannot start is information where a missing row is a lie.
      # Dim, and it opens the timesheet like the detail rows do.
      printf '󰋽\t%s\t%s\t%s\n' "$FG_DIM" "$label" "$tab"
    fi
  done <<PLANEOF
$(jq -r '.[]? | [ (.project // ""), (.budget // .service // .booked_role // ""),
                  (.service_id // "") ] | join("\u001f")' "$plan" 2>/dev/null)
PLANEOF
}
