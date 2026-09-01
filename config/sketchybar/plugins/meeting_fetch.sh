# One windowed calendar fetch, shared by the item, the card and the announcer.
#
# meeting.sh used to call gws-now, which answers only "what am I in right now".
# The upcoming list and the 1-minute announcement both need the events AFTER
# that one, and this is the only plugin that touches the network - so it makes
# a single windowed call and everything downstream reads the same cache rather
# than each firing its own request.
#
# Filters mirror gws-now's: no cancelled events, no all-day markers, and
# nothing you have already declined.
#
# Sourced, not executed. CONFIG_DIR must be set.

MEETING_WINDOW_HOURS="${MEETING_WINDOW_HOURS:-12}"

# -> JSON array of events, sorted by start, each with _s/_e epoch seconds.
# Prints nothing at all when the call fails (vs "[]" for a genuinely clear
# calendar) - meeting.sh depends on telling those two apart.
meeting_fetch() {
  local cal now until raw
  cal="${GWS_NOW_CALENDAR:-primary}"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  until="$(date -u -v+"${MEETING_WINDOW_HOURS}"H +%Y-%m-%dT%H:%M:%SZ)"

  raw="$(timeout 20 gws calendar events list --params "$(jq -nc \
          --arg cal "$cal" --arg min "$now" --arg max "$until" \
          '{calendarId:$cal, timeMin:$min, timeMax:$max, singleEvents:true,
            orderBy:"startTime", maxResults:25, timeZone:"UTC"}')" 2>/dev/null)"

  [ -n "$raw" ] || return 1
  # _e falls back to the start: Google allows endTimeUnspecified, and one such
  # event would abort the whole jq - which reads downstream as a failed fetch
  # and blanks the meeting subsystem for everything else in the window.
  printf '%s' "$raw" | jq -c --arg now "$now" '
    ($now | fromdateiso8601) as $t
    | [ .items[]?
        | select(.status != "cancelled")
        | select(.start.dateTime != null)
        | select([ .attendees[]? | select(.self) | .responseStatus ] | index("declined") | not)
        | . + { _s: (.start.dateTime | fromdateiso8601),
                _e: ((.end.dateTime // .start.dateTime) | fromdateiso8601) } ]
    | map(select(._e > $t))
    | sort_by(._s)
  ' 2>/dev/null
}
