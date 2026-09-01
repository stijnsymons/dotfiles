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
#   - the raw event JSON is cached to ~/.cache/sketchybar/meeting.json so
#     meeting_click.sh can resolve the join link with zero extra API calls;
#   - when the fetch comes back empty AND there is no default route, the cached
#     event is kept on screen (dimmed) until its own end time passes, so a Wi-Fi
#     blip does not blink the meeting away mid-call.
#
# gws-now exits 1 for "no meeting", so this script must not use `set -e`.
#
# Test seams: MEETING_FIXTURE=<file.json> reads an event from disk instead of
# hitting Google; MEETING_CACHE=<file.json> redirects the cache. Used by
# check.sh and for offline development.

source "$CONFIG_DIR/colors.sh"

# Hover dispatch, before anything expensive: sketchybar invokes this same
# script for every subscribed event, and the card must open instantly rather
# than wait on a Calendar round-trip.
case "${SENDER:-}" in
  mouse.entered)                     exec "$CONFIG_DIR/plugins/meeting_popup.sh" open ;;
  mouse.exited|mouse.exited.global)  exec "$CONFIG_DIR/plugins/meeting_popup.sh" close ;;
esac

source "$CONFIG_DIR/plugins/fit.sh"

# Keep exactly what the Productive item next door currently needs, plus the
# divider - no more, so the meeting title gets every remaining pixel.
FIT_RESERVE="$(fit_reserve_for productive)"

# launchd hands sketchybar a minimal PATH: gws-now lives in ~/bin, gws/jq in
# the brew prefix. Without this the plugin silently never finds anything.
PATH="$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

ITEM="${NAME:-meeting}"
CACHE="${MEETING_CACHE:-$HOME/.cache/sketchybar/meeting.json}"
mkdir -p "$(dirname "$CACHE")"

VIDEO="󰕧"   # nf-md-video      - meeting with a join link
ROOM="󰃭"    # nf-md-calendar   - meeting without one

# Could not determine the state: show nothing rather than assert anything.
hide() {
  printf 'null\n' > "$CACHE"
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

# Routine update: also police a card left open by a missed mouse.exited.
"$CONFIG_DIR/plugins/meeting_popup.sh" tick 2>/dev/null

# --- fetch ------------------------------------------------------------------
STALE=0
if [ -n "${MEETING_FIXTURE:-}" ]; then
  EVENT="$(cat "$MEETING_FIXTURE" 2>/dev/null)"
else
  command -v gws-now >/dev/null || hide
  # A hung API call would otherwise pin the plugin until the next tick.
  if command -v timeout >/dev/null; then
    EVENT="$(timeout 20 gws-now --json 2>/dev/null)"
  else
    EVENT="$(gws-now --json 2>/dev/null)"
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
[ "$STALE" -eq 0 ] && printf '%s\n' "$EVENT" > "$CACHE"

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
sketchybar --set sep.timing drawing=on
sketchybar --set "$ITEM" drawing=on \
                         icon="$ICON" \
                         icon.color="$ICON_COLOR" \
                         label.color="$FG" \
                         label="$(fit_label "$ITEM" "$SUMMARY · $REMAIN" "$FIT_RESERVE")"
