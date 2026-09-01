# Shared meeting classification. Sourced by meeting.sh, cards/meeting.sh and
# meeting_announce.sh so the item, the card and the overlay can never disagree
# about what colour a meeting is.
#
# Sourced, not executed. CONFIG_DIR must be set and colors.sh already sourced.

MEETING_INTERNAL_DOMAIN="${MEETING_INTERNAL_DOMAIN:-novemberfive.co}"

# The real human attendees: everyone except yourself, and except meeting rooms.
#
# Rooms ARE attendees as far as the API is concerned - they come back with
# .resource = true and an @resource.calendar.google.com address. Counting them
# is the whole trap here: a solo focus block with a room booked would classify
# as "a meeting with someone else" and come out green instead of purple.
# Checked both ways because either alone is one API change from being wrong;
# on this calendar all 10 room entries carry both markers and nothing else does.
meeting_people() {   # <event-json>  ->  one attendee email per line
  jq -r '
    (.attendees // [])
    | map(select(.self != true))
    | map(select(.resource != true))
    | map(select(((.email // "") | test("resource\\.calendar\\.google\\.com")) | not))
    | .[].email // empty
  ' <<<"$1" 2>/dev/null
}

# none      - nobody else invited: a work/focus block
# internal  - everyone else is a colleague
# external  - at least one attendee from outside
meeting_tier() {     # <event-json>  ->  none|internal|external
  local people ext
  people="$(meeting_people "$1")"
  if [ -z "$people" ]; then printf 'none'; return; fi

  # COUNT the outsiders rather than testing grep's exit status. `grep -qv` is
  # not trustworthy here: on macOS `grep -iv PATTERN` prints the non-matching
  # line and exits 0, but `grep -qiv PATTERN` on the same input exits 1, so the
  # obvious `if ... | grep -qv` reads every mixed meeting as fully internal -
  # which is exactly backwards, and silently: vanbreda.be guests came out green.
  # -c has no such ambiguity, it just counts non-matching lines.
  ext="$(printf '%s\n' "$people" | grep -civ "@${MEETING_INTERNAL_DOMAIN}\$" || true)"
  case "${ext:-0}" in ''|*[!0-9]*) ext=0 ;; esac
  if [ "$ext" -gt 0 ]; then printf 'external'; else printf 'internal'; fi
}

meeting_tier_color() {   # <tier> -> palette colour
  case "$1" in
    none)     printf '%s' "$VIOLET" ;;   # focus block
    internal) printf '%s' "$GREEN"  ;;
    external) printf '%s' "$BLUE"   ;;
    *)        printf '%s' "$FG_DIM" ;;   # unknown / no meeting
  esac
}
