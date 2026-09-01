#!/usr/bin/env bash
# Hover card for the meeting item. Reads only ~/.cache/sketchybar/meeting.json,
# which meeting.sh already wrote, so hovering costs zero API calls.
#
# Rows are pre-created in sketchybarrc (meeting.pop.1..N, drawing=off) and
# toggled here. Creating them on hover would flash an empty card while
# sketchybar laid them out.
#
# Usage: meeting_popup.sh open|close|tick
#   tick is the stuck-card watchdog, called from meeting.sh's routine update:
#   dismissal relies on mouse.exited.global, which is not guaranteed to arrive
#   if the pointer leaves fast, a Space changes, or a display reconfigures.

source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/plugins/fit.sh"

ITEM=meeting
ROWS=5
CACHE="${MEETING_CACHE:-$HOME/.cache/sketchybar/meeting.json}"
STAMP="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/meeting-popup.at"
MAX_OPEN=45        # seconds before the watchdog treats the card as stuck
MAX_CHARS=64

close() {
  rm -f "$STAMP"
  sketchybar --set "$ITEM" popup.drawing=off
  exit 0
}

row() {  # row <n> <glyph> <color> <text>
  sketchybar --set "$ITEM.pop.$1" drawing=on icon="$2" icon.color="$3" \
                                  label="$(ellipsize "$4" "$MAX_CHARS")"
}

hide_from() {  # hide rows n..ROWS
  local n=$1
  while [ "$n" -le "$ROWS" ]; do
    sketchybar --set "$ITEM.pop.$n" drawing=off
    n=$(( n + 1 ))
  done
}

case "${1:-}" in
  close) close ;;
  tick)
    # Only ever closes; never opens. An open card with no timestamp is also
    # stuck (the stamp is written on open), so treat that as expired too.
    [ "$(sketchybar --query "$ITEM" 2>/dev/null | jq -r '.popup.drawing')" = "on" ] || exit 0
    OPENED_AT="$(cat "$STAMP" 2>/dev/null)"
    case "$OPENED_AT" in ''|*[!0-9]*) close ;; esac
    [ $(( $(date +%s) - OPENED_AT )) -ge "$MAX_OPEN" ] && close
    exit 0 ;;
esac

# --- open -------------------------------------------------------------------
EVENT="$(cat "$CACHE" 2>/dev/null)"
date +%s > "$STAMP"

if [ -z "$EVENT" ] || [ "$EVENT" = "null" ]; then
  row 1 "󰃭" "$FG_DIM" "No meeting right now"
  hide_from 2
  sketchybar --set "$ITEM" popup.drawing=on
  exit 0
fi

TZ_EVENT="$(jq -r '.start.timeZone // "UTC"' <<<"$EVENT")"
read -r S E <<<"$(jq -r '[(.start.dateTime|fromdateiso8601),(.end.dateTime|fromdateiso8601)]|@tsv' <<<"$EVENT" 2>/dev/null)"
N=1

SUMMARY="$(jq -r '(.summary // "(no title)")|gsub("\\s+";" ")' <<<"$EVENT")"
row $N "󰃭" "$BLUE" "$SUMMARY"; N=$(( N + 1 ))

if [ -n "${S:-}" ] && [ -n "${E:-}" ]; then
  MINS=$(( (E - $(date +%s) + 59) / 60 )); [ "$MINS" -lt 0 ] && MINS=0
  row $N "󰅐" "$FG_DIM" \
    "$(TZ="$TZ_EVENT" date -r "$S" +%H:%M) – $(TZ="$TZ_EVENT" date -r "$E" +%H:%M)  ·  ${MINS}m left"
  N=$(( N + 1 ))
fi

# Reuse the click handler's resolver so the card cannot advertise a different
# link from the one clicking actually opens.
LINK="$(MEETING_CACHE="$CACHE" "$CONFIG_DIR/plugins/meeting_click.sh" --print 2>/dev/null)"
LOCATION="$(jq -r '.location // empty' <<<"$EVENT")"
if [ -n "$LINK" ]; then
  row $N "󰍹" "$AQUA" "$(sed -E 's|^https?://||' <<<"$LINK")"; N=$(( N + 1 ))
elif [ -n "$LOCATION" ]; then
  row $N "󰍎" "$AQUA" "$LOCATION"; N=$(( N + 1 ))
fi

ATT="$(jq -r '
  (.attendees // []) as $a
  | if ($a|length) == 0 then empty
    else ( ($a|length|tostring) + " attendee" + (if ($a|length) == 1 then "" else "s" end)
           + ( [ $a[] | select(.responseStatus == "accepted") ] | length
               | if . > 0 then "  ·  \(.) accepted" else "" end ) )
    end' <<<"$EVENT")"
[ -n "$ATT" ] && { row $N "󰀄" "$VIOLET" "$ATT"; N=$(( N + 1 )); }

DESC="$(jq -r '.description // empty' <<<"$EVENT" \
        | sed -E 's/<br[^>]*>/ /gI; s/<[^>]+>//g' \
        | tr '\n' ' ' | sed -E 's/&nbsp;/ /g; s/&amp;/\&/g; s/  +/ /g; s/^ +//; s/ +$//')"
[ -n "$DESC" ] && { row $N "󰎞" "$FG_DIM" "$DESC"; N=$(( N + 1 )); }

hide_from "$N"
sketchybar --set "$ITEM" popup.drawing=on
