# Current meeting. Reads only the JSON meeting.sh cached, so hovering is free.
card_rows() {
  local cache="${MEETING_CACHE:-$HOME/.cache/sketchybar/meeting.json}"
  local ev tz s e mins link loc att desc
  ev="$(cat "$cache" 2>/dev/null)"
  if [ -z "$ev" ] || [ "$ev" = "null" ]; then
    printf '󰃭\t%s\tNo meeting right now\n' "$FG_DIM"; return
  fi
  printf '󰃭\t%s\t%s\n' "$BLUE" "$(jq -r '(.summary // "(no title)")|gsub("\\s+";" ")' <<<"$ev")"
  tz="$(jq -r '.start.timeZone // "UTC"' <<<"$ev")"
  read -r s e <<<"$(jq -r '[(.start.dateTime|fromdateiso8601),(.end.dateTime|fromdateiso8601)]|@tsv' <<<"$ev" 2>/dev/null)"
  if [ -n "${s:-}" ] && [ -n "${e:-}" ]; then
    mins=$(( (e - $(date +%s) + 59) / 60 )); [ "$mins" -lt 0 ] && mins=0
    printf '󰅐\t%s\t%s – %s  ·  %sm left\n' "$FG_DIM" \
      "$(TZ="$tz" date -r "$s" +%H:%M)" "$(TZ="$tz" date -r "$e" +%H:%M)" "$mins"
  fi
  # Reuse the click resolver so the card cannot advertise a different link.
  link="$(MEETING_CACHE="$cache" "$CONFIG_DIR/plugins/meeting_click.sh" --print 2>/dev/null)"
  loc="$(jq -r '.location // empty' <<<"$ev")"
  if [ -n "$link" ]; then printf '󰍹\t%s\t%s\n' "$AQUA" "$(sed -E 's|^https?://||' <<<"$link")"
  elif [ -n "$loc" ]; then printf '󰍎\t%s\t%s\n' "$AQUA" "$loc"; fi
  att="$(jq -r '(.attendees // []) as $a | if ($a|length)==0 then empty else
        (($a|length|tostring) + " attendee" + (if ($a|length)==1 then "" else "s" end)
         + ([$a[]|select(.responseStatus=="accepted")]|length|if .>0 then "  ·  \(.) accepted" else "" end)) end' <<<"$ev")"
  [ -n "$att" ] && printf '󰀄\t%s\t%s\n' "$VIOLET" "$att"
  desc="$(jq -r '.description // empty' <<<"$ev" \
          | sed -E 's/<br[^>]*>/ /gI; s/<[^>]+>//g' | tr '\n' ' ' \
          | sed -E 's/&nbsp;/ /g; s/&amp;/\&/g; s/  +/ /g; s/^ +//; s/ +$//')"
  [ -n "$desc" ] && printf '󰎞\t%s\t%s\n' "$FG_DIM" "$desc"
}
