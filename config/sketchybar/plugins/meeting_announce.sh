#!/usr/bin/env bash
# Fire the full-screen overlay one minute before a meeting starts.
#
# Called from meeting.sh on every tick (update_freq=60). Each run looks at the
# cached upcoming list and schedules any meeting whose start falls inside the
# next couple of minutes, sleeping the remainder so the overlay lands at T-60s
# rather than whenever the tick happened to run.
#
# Focus blocks never announce: tier "none" means nobody else is invited, and a
# takeover for your own work block is noise.
#
# Announcements are deduped by event id + start time in a state file, so the
# overlapping tick windows cannot fire the same meeting twice. /tmp-style cache
# under ~/.cache, pruned of past entries each run.

set -u

source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/plugins/meeting_lib.sh"

UPCOMING="${MEETING_UPCOMING:-$HOME/.cache/sketchybar/meetings.json}"
SEEN="${MEETING_ANNOUNCED:-$HOME/.cache/sketchybar/announced}"
# Overridable so check.sh can assert which meetings announce without
# actually taking the screen over.
OVERLAY="${MEETING_OVERLAY:-$CONFIG_DIR/bin/meeting-overlay}"
LEAD=60                 # announce this many seconds before the start
WINDOW=$(( LEAD + 60 )) # a tick's worth of look-ahead beyond the lead

# An epoch as HH:MM in the event's own zone. One-off invites often carry no
# .start.timeZone, only an offset dateTime, and TZ="" means UTC rather than
# local - which renders them 2h early here - so the assignment is skipped
# entirely instead of emptied.
hhmm() { if [ -n "$2" ]; then TZ="$2" date -r "$1" +%H:%M; else date -r "$1" +%H:%M; fi; }

[ -s "$UPCOMING" ] || exit 0
[ -x "$OVERLAY" ]  || exit 0

mkdir -p "$(dirname "$SEEN")"; touch "$SEEN"
NOW="$(date -u +%s)"

# Drop entries whose meeting has already started, so this cannot grow forever.
# Per-pid tmp: a system_woke run and a timer tick overlap, and a fixed name
# means one truncates the other's prune mid-write.
awk -v now="$NOW" -F'\t' '$2 + 0 > now' "$SEEN" > "$SEEN.tmp.$$" 2>/dev/null \
  && mv "$SEEN.tmp.$$" "$SEEN" || rm -f "$SEEN.tmp.$$"

while IFS= read -r ev; do
  [ -z "$ev" ] && continue

  START="$(jq -r '._s // empty' <<<"$ev")"
  case "$START" in ''|*[!0-9]*) continue ;; esac

  DELTA=$(( START - NOW ))
  [ "$DELTA" -gt "$WINDOW" ] && continue      # too far out; a later tick gets it
  [ "$DELTA" -le 0 ] && continue              # already started

  TIER="$(meeting_tier "$ev")"
  [ "$TIER" = "none" ] && continue            # focus block: no takeover

  ID="$(jq -r '.id // empty' <<<"$ev")"
  KEY="${ID}:${START}"
  grep -qF "$KEY	" "$SEEN" 2>/dev/null && continue

  # Enrich for the overlay: it renders, it does not re-derive any of this.
  TZ_EV="$(jq -r '.start.timeZone // empty' <<<"$ev")"
  END="$(jq -r '._e // empty' <<<"$ev")"
  WHEN="$(hhmm "$START" "$TZ_EV")"
  [ -n "$END" ] && WHEN="$WHEN – $(hhmm "$END" "$TZ_EV")"

  N_PEOPLE="$(meeting_people "$ev" | grep -c . || true)"
  case "$TIER" in
    external) PEOPLE="$N_PEOPLE attendees  ·  external" ;;
    *)        PEOPLE="$N_PEOPLE attendees" ;;
  esac

  # Reuse the click resolver so the overlay can never advertise a link the
  # bar item would not open.
  # mktemp per event, NOT one path per run: $$ is the same for every iteration,
  # so a shared name means the second meeting overwrites the first's payload and
  # the first scheduled job then deletes it - two meetings a minute apart
  # announced as one. Same reason the link probe gets its own file.
  # BSD mktemp needs the Xs trailing - a ".json" suffix makes it fail outright.
  PROBE="$(mktemp "$HOME/.cache/sketchybar/announce-probe-XXXXXX")"
  printf '%s\n' "$ev" > "$PROBE"
  LINK="$(MEETING_CACHE="$PROBE" "$CONFIG_DIR/plugins/meeting_click.sh" --print 2>/dev/null)"
  rm -f "$PROBE"

  PAYLOAD="$(mktemp "$HOME/.cache/sketchybar/announce-XXXXXX")"
  jq -c --arg t "$TIER" --arg w "$WHEN" --arg p "$PEOPLE" --arg l "$LINK" \
     '. + {_tier:$t, _when:$w, _people:$p} + (if $l == "" then {} else {_link:$l} end)' \
     <<<"$ev" > "$PAYLOAD" 2>/dev/null || { rm -f "$PAYLOAD"; continue; }

  # Sleep the remainder so it lands at T-LEAD, not at tick time. Detached, or
  # sketchybar reaps it when the plugin returns.
  DELAY=$(( DELTA - LEAD )); [ "$DELAY" -lt 0 ] && DELAY=0
  nohup sh -c "sleep $DELAY; '$OVERLAY' '$PAYLOAD'; rm -f '$PAYLOAD'" >/dev/null 2>&1 &
  disown 2>/dev/null || true

  # Marked announced only now: a failed enrichment above must not suppress the
  # overlay forever, which is the one failure this subsystem exists to prevent.
  # The grep guard higher up still stops a double fire within the same tick.
  printf '%s\t%s\n' "$KEY" "$START" >> "$SEEN"
done <<<"$(jq -c '.[]?' "$UPCOMING" 2>/dev/null)"
