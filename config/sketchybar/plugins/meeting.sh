#!/usr/bin/env bash
# Current calendar meeting, via ~/bin/gws-now. Shows a dim "no meetings" when
# the calendar is genuinely clear, and hides entirely only when it cannot tell.
#
# Those two are deliberately different. gws-now --json prints "null" when it
# looked and found nothing, and prints nothing at all when the call itself
# failed (auth, quota, a hung request). Rendering "no meetings" in the second
# case would assert an empty calendar we never actually saw, so that path hides
# instead - an absent item reads as "unknown", a confident one reads as fact.
#
# This is the only plugin that touches the network, so:
#   - it is meant to run on update_freq=60, never on a tight cycle;
#   - the raw event JSON is cached to $SB_CACHE_DIR/meeting.json so
#     meeting_click.sh can resolve the join link with zero extra API calls;
#   - when the fetch comes back empty AND there is no default route, the cached
#     event is kept on screen (dimmed) until its own end time passes, so a Wi-Fi
#     blip does not blink the meeting away mid-call.
#
# gws-now exits 1 for "no meeting", so this script must not use `set -e`.
# `set -u` is orthogonal to that and stays on: every sketchybar-supplied
# variable read here is guarded, so an unset one is a bug, not a state.
#
# Test seams: MEETING_FIXTURE=<file.json> reads an event from disk instead of
# hitting Google; MEETING_CACHE=<file.json> redirects the cache. Used by
# check.sh and for offline development.
set -u

source "$CONFIG_DIR/colors.sh"

# Hover dispatch, before anything expensive: sketchybar invokes this same
# script for every subscribed event, and the card must be dismissed instantly
# rather than after a Calendar round-trip. The routine tick it makes on every
# other event polices a card left open by a missed mouse.exited.
card_dispatch meeting

source "$CONFIG_DIR/plugins/fit.sh"
source "$CONFIG_DIR/plugins/meeting_lib.sh"
source "$CONFIG_DIR/plugins/meeting_fetch.sh"

# Keep exactly what the Productive item next door currently needs, plus the
# divider - no more, so the meeting title gets every remaining pixel.
FIT_RESERVE="$(fit_reserve_for productive)"

ITEM="${NAME:-meeting}"
CACHE="${MEETING_CACHE:-$SB_CACHE_DIR/meeting.json}"
# The rest of the window, for the card's upcoming list and the announcer.
UPCOMING="${MEETING_UPCOMING:-$SB_CACHE_DIR/meetings.json}"

VIDEO="󰕧"   # nf-md-video      - meeting with a join link
ROOM="󰃭"    # nf-md-calendar   - meeting without one

# Could not determine the state: show nothing rather than assert anything. The
# cache is deliberately left alone - this path runs on any transient failure,
# and overwriting it with null would both lose the join link for a rejoin click
# mid-meeting and poison the offline fallback into asserting an empty calendar.
# Only idle(), which did see the calendar, writes null.
hide() {
  sketchybar --set "$ITEM" drawing=off --set sep.timing drawing=off
  exit 0
}

# Looked, and the calendar is clear. Dim, because it is the resting state and
# should not compete with the red "not timing" indicator sitting next to it.
idle() {
  printf 'null\n' > "$CACHE"
  sketchybar --set sep.timing drawing=on
  sketchybar --set "$ITEM" drawing=on \
                           icon="$ROOM" \
                           icon.color="$FG_DIM" \
                           label.color="$FG_DIM" \
                           label="$(fit_label "$ITEM" "no meetings" "$FIT_RESERVE")"
  exit 0
}

# --- fetch ------------------------------------------------------------------
STALE=0
if [ -n "${MEETING_FIXTURE:-}" ]; then
  EVENT="$(cat "$MEETING_FIXTURE" 2>/dev/null)"
else
  command -v gws >/dev/null || hide

  # One windowed call, then derive both halves from it: the event running right
  # now, and everything after it. gws-now answers only the first question and
  # would mean a second request per tick for the list and the announcement.
  WINDOW="$(meeting_fetch)"
  if [ -z "$WINDOW" ]; then
    EVENT=""                                        # call failed: unknown
  else
    NOW_TS="$(date -u +%s)"
    EVENT="$(jq -c --argjson t "$NOW_TS" 'map(select(._s <= $t and ._e > $t)) | .[0] // "null"' <<<"$WINDOW" 2>/dev/null)"
    [ "$EVENT" = '"null"' ] && EVENT="null"
    # Write-then-rename: the card and the announcer read this file on their own
    # schedule and must never catch it half-written.
    jq -c --argjson t "$NOW_TS" 'map(select(._s > $t))' <<<"$WINDOW" > "$UPCOMING.tmp.$$" 2>/dev/null \
      && mv "$UPCOMING.tmp.$$" "$UPCOMING" || rm -f "$UPCOMING.tmp.$$"
    # Schedule the 1-minute overlay off the freshly written list. Runs on every
    # tick and dedups internally, so a missed tick just means the next one
    # picks the meeting up.
    "$CONFIG_DIR/plugins/meeting_announce.sh" 2>/dev/null || true
  fi
fi

# Empty (fetch failed) or null (genuinely no meeting) look identical from here,
# so only fall back to the cache when the machine is provably offline.
if [ -z "$EVENT" ] || [ "$EVENT" = "null" ]; then
  if ! route -n get default >/dev/null 2>&1 && [ -s "$CACHE" ]; then
    EVENT="$(cat "$CACHE")"
    STALE=1
  fi
fi
if [ "$EVENT" = "null" ]; then idle; fi
if [ -z "$EVENT" ]; then hide; fi

# --- parse ------------------------------------------------------------------
# One jq pass, two lines out. The summary is flattened because a stray newline
# would desynchronise the reads below.
{ IFS= read -r SUMMARY; IFS= read -r END; } <<PARSEEOF
$(jq -r '
  ((.summary // "(no title)") | gsub("\\s+"; " ") | sub("^ +"; "") | sub(" +$"; "")),
  ((.end.dateTime // empty) | fromdateiso8601)
' <<<"$EVENT" 2>/dev/null)
PARSEEOF

case "${END:-}" in ''|*[!0-9]*) hide ;; esac

NOW="$(date -u +%s)"
if [ "$END" -le "$NOW" ]; then                      # cached event already over
  [ "$STALE" -eq 1 ] && hide                        # offline: cannot know what replaced it
  idle
fi
if [ "$STALE" -eq 0 ]; then                         # same write-then-rename
  printf '%s\n' "$EVENT" > "$CACHE.tmp.$$" && mv "$CACHE.tmp.$$" "$CACHE" || rm -f "$CACHE.tmp.$$"
fi

MINS=$(( (END - NOW + 59) / 60 ))
[ "$MINS" -lt 0 ] && MINS=0

# --- render -----------------------------------------------------------------
# Ask the click handler (which now reads the cache written above) whether this
# event has a joinable link, rather than re-implementing the lookup: a Teams
# link often exists only as an <a href> in the description, so a naive check on
# conferenceData would draw a "room" icon for a meeting the click does join.
if MEETING_CACHE="$CACHE" "$CONFIG_DIR/plugins/meeting_click.sh" --print >/dev/null 2>&1; then
  ICON="$VIDEO"
else
  ICON="$ROOM"
fi

if   [ "$STALE" -eq 1 ];  then ICON_COLOR="$FG_DIM"   # offline, showing cache
elif [ "$MINS" -le 5 ];   then ICON_COLOR="$ORANGE"   # wrapping up
else                           ICON_COLOR="$GREEN"
fi

# Hours only once it is worth the extra characters.
if [ "$MINS" -ge 60 ]; then
  REMAIN="$(( MINS / 60 ))h$(printf '%02d' $(( MINS % 60 )))"
else
  REMAIN="${MINS}m"
fi

# label.max_chars (set in sketchybarrc) is what makes this scroll; label.width
# only clips. See README > Notes / gotchas.
# Label colour carries WHO is in the meeting, independent of the icon colour
# which carries how long is left. Rooms are not people - see meeting_lib.sh.
TIER="$(meeting_tier "$EVENT")"
LABEL_COLOR="$(meeting_tier_color "$TIER")"
[ "$STALE" -eq 1 ] && LABEL_COLOR="$FG_DIM"   # offline: do not assert a tier

sketchybar --set sep.timing drawing=on
sketchybar --set "$ITEM" drawing=on \
                         icon="$ICON" \
                         icon.color="$ICON_COLOR" \
                         label.color="$LABEL_COLOR" \
                         label="$(fit_label "$ITEM" "$SUMMARY · $REMAIN" "$FIT_RESERVE")"
