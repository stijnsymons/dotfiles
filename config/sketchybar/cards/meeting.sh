# Current meeting. Reads only the JSON meeting.sh cached, so opening is free.
#
# Row actions: the conference row launches Zoom/Teams natively; every other row
# points Brave's pinned calendar tab at this event's htmlLink, so a click lands
# on the meeting's details rather than just today's grid.
card_rows() {
  local cache="${MEETING_CACHE:-$HOME/.cache/sketchybar/meeting.json}"
  local ev tz s e mins link loc att desc detail
  ev="$(cat "$cache" 2>/dev/null)"
  if [ -z "$ev" ] || [ "$ev" = "null" ]; then
    printf '󰃭\t%s\tNo meeting right now\t%s\n' "$FG_DIM" "$CONFIG_DIR/plugins/brave_tab.sh 2"; return
  fi
  # htmlLink looks like the obvious target but Google redirects it to the week
  # view - verified: the tab title came back "Week of August 31". The eid it
  # carries, on the /r/eventedit/ path, does open the detail pane ("Event
  # details"). Fall back to plain tab focus if the eid cannot be extracted.
  detail="$(jq -r '.htmlLink // empty' <<<"$ev" | sed -nE 's/.*[?&]eid=([^&]+).*/\1/p')"
  local cal="$CONFIG_DIR/plugins/brave_tab.sh 2"
  [ -n "$detail" ] && cal="$cal 'https://calendar.google.com/calendar/u/0/r/eventedit/$detail'"
  printf '󰃭\t%s\t%s\t%s\n' "$BLUE" "$(jq -r '(.summary // "(no title)")|gsub("\\s+";" ")' <<<"$ev")" "$cal"
  tz="$(jq -r '.start.timeZone // "UTC"' <<<"$ev")"
  read -r s e <<<"$(jq -r '[(.start.dateTime|fromdateiso8601),(.end.dateTime|fromdateiso8601)]|@tsv' <<<"$ev" 2>/dev/null)"
  if [ -n "${s:-}" ] && [ -n "${e:-}" ]; then
    mins=$(( (e - $(date +%s) + 59) / 60 )); [ "$mins" -lt 0 ] && mins=0
    printf '󰅐\t%s\t%s – %s  ·  %sm left\t%s\n' "$FG_DIM" \
      "$(TZ="$tz" date -r "$s" +%H:%M)" "$(TZ="$tz" date -r "$e" +%H:%M)" "$mins" "$cal"
  fi
  # Reuse the click resolver so the card cannot advertise a different link.
  link="$(MEETING_CACHE="$cache" "$CONFIG_DIR/plugins/meeting_click.sh" --print 2>/dev/null)"
  loc="$(jq -r '.location // empty' <<<"$ev")"
  if [ -n "$link" ]; then
    printf '󰍹\t%s\tJoin  ·  %s\t%s\n' "$AQUA" "$(sed -E 's|^https?://||' <<<"$link")" \
           "$CONFIG_DIR/plugins/open_conf.sh"
  elif [ -n "$loc" ]; then printf '󰍎\t%s\t%s\t%s\n' "$AQUA" "$loc" "$cal"; fi
  att="$(jq -r '(.attendees // []) as $a | if ($a|length)==0 then empty else
        (($a|length|tostring) + " attendee" + (if ($a|length)==1 then "" else "s" end)
         + ([$a[]|select(.responseStatus=="accepted")]|length|if .>0 then "  ·  \(.) accepted" else "" end)) end' <<<"$ev")"
  [ -n "$att" ] && printf '󰀄\t%s\t%s\t%s\n' "$VIOLET" "$att" "$cal"
  desc="$(jq -r '.description // empty' <<<"$ev" \
          | sed -E 's/<br[^>]*>/ /gI; s/<[^>]+>//g' | tr '\n' ' ' \
          | sed -E 's/&nbsp;/ /g; s/&amp;/\&/g; s/  +/ /g; s/^ +//; s/ +$//')"
  [ -n "$desc" ] && printf '󰎞\t%s\t%s\t%s\n' "$FG_DIM" "$desc" "$cal"
}
