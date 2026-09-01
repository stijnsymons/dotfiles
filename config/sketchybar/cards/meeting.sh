# Current meeting, then what is coming up. Reads only the JSON meeting.sh
# cached, so opening the card is free - no calendar round-trip on hover.
#
# meeting_lib.sh is sourced for the tier colours; card.sh only brings in
# colors.sh and fit.sh.
source "$CONFIG_DIR/plugins/meeting_lib.sh"
#
# An epoch as HH:MM in the event's own zone. One-off invites often carry no
# .start.timeZone, only an offset dateTime, and TZ="" means UTC rather than
# local - which renders them 2h early here - so the assignment is skipped
# entirely instead of emptied.
meeting_hhmm() { if [ -n "$2" ]; then TZ="$2" date -r "$1" +%H:%M; else date -r "$1" +%H:%M; fi; }
#
# Row actions: the conference row launches Zoom/Teams natively; every other row
# points Brave's pinned calendar tab at this event's htmlLink, so a click lands
# on the meeting's details rather than just today's grid.
card_rows() {
  local cache="${MEETING_CACHE:-$HOME/.cache/sketchybar/meeting.json}"
  local ev tz s e mins link loc att desc detail
  ev="$(cat "$cache" 2>/dev/null)"
  if [ -z "$ev" ] || [ "$ev" = "null" ]; then
    printf '󰃭\t%s\tNo meeting right now\t%s\n' "$FG_DIM" "$CONFIG_DIR/plugins/brave_tab.sh 2"
    # Still list what is coming - an empty right-now is exactly when the
    # upcoming list is the useful part of this card.
    meeting_upcoming_rows
    return
  fi
  # htmlLink looks like the obvious target but Google redirects it to the week
  # view - verified: the tab title came back "Week of August 31". The eid it
  # carries, on the /r/eventedit/ path, does open the detail pane ("Event
  # details"). Fall back to plain tab focus if the eid cannot be extracted.
  #
  # The eid is spliced into a quoted URL inside a click_script, and anyone who
  # can invite you writes it, so keep it to the base64url alphabet Google
  # actually uses - a quote in there would close out of the command.
  detail="$(jq -r '.htmlLink // empty' <<<"$ev" | sed -nE 's/.*[?&]eid=([^&]+).*/\1/p' | tr -cd 'A-Za-z0-9_=-')"
  local cal="$CONFIG_DIR/plugins/brave_tab.sh 2"
  [ -n "$detail" ] && cal="$cal 'https://calendar.google.com/calendar/u/0/r/eventedit/$detail'"
  printf '󰃭\t%s\t%s\t%s\n' "$BLUE" "$(card_text "$(jq -r '(.summary // "(no title)")|gsub("\\s+";" ")' <<<"$ev")")" "$cal"
  tz="$(jq -r '.start.timeZone // empty' <<<"$ev")"
  read -r s e <<<"$(jq -r '[(.start.dateTime|fromdateiso8601),(.end.dateTime|fromdateiso8601)]|@tsv' <<<"$ev" 2>/dev/null)"
  if [ -n "${s:-}" ] && [ -n "${e:-}" ]; then
    mins=$(( (e - $(date +%s) + 59) / 60 )); [ "$mins" -lt 0 ] && mins=0
    printf '󰅐\t%s\t%s – %s  ·  %sm left\t%s\n' "$FG_DIM" \
      "$(meeting_hhmm "$s" "$tz")" "$(meeting_hhmm "$e" "$tz")" "$mins" "$cal"
  fi
  # Reuse the click resolver so the card cannot advertise a different link.
  link="$(MEETING_CACHE="$cache" "$CONFIG_DIR/plugins/meeting_click.sh" --print 2>/dev/null)"
  loc="$(jq -r '.location // empty' <<<"$ev")"
  if [ -n "$link" ]; then
    printf '󰍹\t%s\tJoin  ·  %s\t%s\n' "$AQUA" "$(sed -E 's|^https?://||' <<<"$link")" \
           "$CONFIG_DIR/plugins/open_conf.sh"
  elif [ -n "$loc" ]; then printf '󰍎\t%s\t%s\t%s\n' "$AQUA" "$(card_text "$loc")" "$cal"; fi
  att="$(jq -r '(.attendees // []) as $a | if ($a|length)==0 then empty else
        (($a|length|tostring) + " attendee" + (if ($a|length)==1 then "" else "s" end)
         + ([$a[]|select(.responseStatus=="accepted")]|length|if .>0 then "  ·  \(.) accepted" else "" end)) end' <<<"$ev")"
  [ -n "$att" ] && printf '󰀄\t%s\t%s\t%s\n' "$VIOLET" "$(card_text "$att")" "$cal"
  desc="$(jq -r '.description // empty' <<<"$ev" \
          | sed -E 's/<br[^>]*>/ /gI; s/<[^>]+>//g' | tr '\n' ' ' \
          | sed -E 's/&nbsp;/ /g; s/&amp;/\&/g; s/  +/ /g; s/^ +//; s/ +$//')"
  [ -n "$desc" ] && printf '󰎞\t%s\t%s\t%s\n' "$FG_DIM" "$(card_text "$desc")" "$cal"

  meeting_upcoming_rows
}

# The rest of the window, below the current meeting's detail. Each row is
# coloured by the same tier the bar item uses, so the card and the item agree,
# and each opens that event in the pinned calendar tab.
#
# The card has 8 rows total (sketchybarrc card_rows_for). Detail takes what it
# needs first and upcoming fills whatever is left, so a meeting with a long
# description simply shows fewer of them rather than pushing detail off.
meeting_upcoming_rows() {
  local up ev tz start tier color
  up="${MEETING_UPCOMING:-$HOME/.cache/sketchybar/meetings.json}"
  [ -s "$up" ] || return 0

  # No row budgeting here: card.sh stops at row_count() on its own, so detail
  # rows are emitted first and take what they need, and these fill the rest.
  while IFS= read -r ev; do
    [ -z "$ev" ] && continue
    tier="$(meeting_tier "$ev")"
    color="$(meeting_tier_color "$tier")"
    tz="$(jq -r '.start.timeZone // empty' <<<"$ev")"
    start="$(jq -r '._s // empty' <<<"$ev")"
    [ -n "$start" ] || continue
    printf '󰃰\t%s\t%s  ·  %s\t%s\n' "$color" \
      "$(meeting_hhmm "$start" "$tz")" \
      "$(card_text "$(jq -r '(.summary // "(no title)") | gsub("\\s+"; " ")' <<<"$ev")")" \
      "$(meeting_event_link "$ev")"
  done <<<"$(jq -c '.[]?' "$up" 2>/dev/null)"
}

# Same eid trick as the current meeting: htmlLink redirects to the week view,
# the eid on /r/eventedit/ opens the detail pane. Same whitelist too - this eid
# ends up inside the same quoted URL in a click_script.
meeting_event_link() {
  local eid
  eid="$(jq -r '.htmlLink // empty' <<<"$1" | sed -nE 's/.*[?&]eid=([^&]+).*/\1/p' | tr -cd 'A-Za-z0-9_=-')"
  if [ -n "$eid" ]; then
    printf "%s 2 'https://calendar.google.com/calendar/u/0/r/eventedit/%s'" "$CONFIG_DIR/plugins/brave_tab.sh" "$eid"
  else
    printf '%s 2' "$CONFIG_DIR/plugins/brave_tab.sh"
  fi
}
