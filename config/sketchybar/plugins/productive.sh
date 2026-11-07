#!/usr/bin/env bash
# Productive.io time tracking. The point of this item is the NEGATIVE state:
# a red alarm when nothing is being timed, because untracked hours are the
# thing that actually costs money.
#
# Data comes from `productive timer --json` (~/tools/assistant/bin/productive).
# Its exit code is 0 while a timer runs and 1 when none does -- but a network
# or auth failure also exits 1, so this script keys off the JSON body instead
# and treats "no parseable JSON" as UNKNOWN, not as "not timing". A dropped
# Wi-Fi packet must never fake the alarm.
#
# This item is the ANCHOR of the timer widget: state glyph + elapsed time (or the
# red alarm), plus an amber overtime suffix (productive.ot) once the week passes
# 40h. Next to it sit four chips (productive_chips.sh), one booking each, and a
# click on the anchor opens the native panel (productive_panel.sh). It used to be
# a hover card; the card file is kept for check.sh but no longer wired in.
#
# Glyphs are UTF-8 octal escapes so no encoding step can drop them:
# U+F017 clock (timing), U+F071 warning triangle (not timing).
set -u
# launchd gives no locale, and fit_label cuts by character: in the C locale it would
# cut the name's "·" in half.
export LC_CTYPE=en_US.UTF-8

source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/plugins/fit.sh"
CACHE="$SB_CACHE_DIR/productive.json"
STALE_AFTER=420          # seconds; past this the cache is no longer evidence

CLOCK="$(printf '\357\200\227')"
WARN="$(printf '\357\201\261')"

# launchd starts sketchybar from a login-less context, so the CLI's credentials
# are not in the environment either. productive_api.sh owns that lift: one copy
# of the only code in here that goes near the token.
source "$CONFIG_DIR/plugins/productive_api.sh"
productive_creds || true

# Keep this week's planning cache warm for the card. Cheap: it returns
# immediately unless the cache is older than its TTL, so this is a stat()
# on all but one tick an hour.
"$CONFIG_DIR/plugins/productive_plan.sh" >/dev/null 2>&1 || true

# Same arrangement for this week's logged-vs-booked total, which the clock card
# reads. It lives on this tick and not the clock's because this is the item
# that already holds the Productive credentials and the 60s budget for a
# network call; the clock ticks every 15s and must stay a `date` call.
"$CONFIG_DIR/plugins/productive_week.sh" >/dev/null 2>&1 || true

# Minutes -> "3h45m" / "45m".
fmt() {
  local m=${1:-0}
  [ "$m" -ge 0 ] 2>/dev/null || m=0
  if [ "$m" -ge 60 ]; then printf '%dh%02dm' $((m / 60)) $((m % 60))
  else printf '%dm' "$m"; fi
}

# Test seam, mirroring meeting.sh's MEETING_FIXTURE: read the timer JSON from
# disk instead of the API, so check.sh can assert the colour rules without a
# live timer (and without starting one).
fetch() {
  local out
  if [ -n "${PRODUCTIVE_FIXTURE:-}" ]; then
    out="$(cat "$PRODUCTIVE_FIXTURE" 2>/dev/null)"
  else
    out="$(productive timer --json 2>/dev/null)"
  fi
  printf '%s' "$out" | jq -e 'has("running")' >/dev/null 2>&1 || return 1
  printf '%s' "$out" >"$CACHE"
  printf '%s' "$out"
}

source "$CONFIG_DIR/plugins/productive_chips.sh"

# fit_label reserves room for the four chips to its right (a code is 4-5 chars at
# 11.5pt bold plus the stripe and padding), or a long timer label would push the
# last chip under the notch.
CHIPS_RESERVE=${CHIPS_RESERVE:-230}
IDLE_TINT=0x29f7768e     # RED at 16%: the alarm reads as a patch, not just a glyph

# The booking's full name follows the elapsed time when the bar has room for it:
# fit_label truncates "<elapsed> <name>" to what fits before the notch, and a name
# that would get fewer than NAME_MIN visible characters is dropped altogether - a
# stub like "vb…" tells nothing (counted without the "…" and the space). fit_label's own floor (8 chars) is why the check
# is on the result and not on the room.
NAME_MIN=8
set_running() { # $1 = elapsed, $2 = booking name (may be empty)
  local label="$1" full
  if [ -n "${2:-}" ]; then
    full="$(fit_label "$NAME" "$1 $2" "$CHIPS_RESERVE")"
    case "$full" in
      *…) [ $(( ${#full} - ${#1} - 2 )) -ge "$NAME_MIN" ] && label="$full" ;;
      *)  label="$full" ;;
    esac
  else
    label="$(fit_label "$NAME" "$1" "$CHIPS_RESERVE")"
  fi
  sketchybar --set "$NAME" drawing=on background.drawing=off \
    icon="$CLOCK" icon.color="$GREEN" label="$label" label.color="$GREEN"
}
set_idle()    { sketchybar --set "$NAME" drawing=on background.drawing=on background.color="$IDLE_TINT" \
                  icon="$WARN"  icon.color="$RED"   label="$(fit_label "$NAME" "not timing" "$CHIPS_RESERVE")" label.color="$RED"; }
set_unknown() { sketchybar --set "$NAME" drawing=on background.drawing=off \
                  icon="$CLOCK" icon.color="$FG_DIM" label="--" label.color="$FG_DIM"; }

render() {        # $1 = json, $2 = age of that json in seconds
  local json=$1 age=${2:-0} elapsed svc bname

  if [ "$(printf '%s' "$json" | jq -r '.running')" != "true" ]; then
    STATE=idle; set_idle
    return
  fi

  elapsed="$(printf '%s' "$json" | jq -r '.elapsed_minutes // 0')"
  # A running clock keeps running: age the cached figure forward so a served
  # cache never shows a stale number. The name comes from the board (matched by
  # service id, which the timer carries), so it is the same string the panel shows.
  svc="$(printf '%s' "$json" | jq -r '.service_id // empty')"
  bname="$(jq -r --arg s "$svc" '[.bookings[]? | select(.service_id == $s)][0].name // empty' "$BOARD" 2>/dev/null)"
  STATE=running; set_running "$(fmt $(( ${elapsed:-0} + age / 60 )))" "$bname"
}

STATE=unknown
if JSON="$(fetch)"; then
  render "$JSON" 0
elif [ -f "$CACHE" ]; then
  AGE=$(( $(date +%s) - $(stat -f %m "$CACHE") ))
  if [ "$AGE" -le "$STALE_AFTER" ]; then render "$(cat "$CACHE")" "$AGE"
  else set_unknown; fi
else
  set_unknown
fi

# The widget's shared board (chips, panel, herdr mod). After the repaint, so a
# slow first-sight short-code call to the model can never delay the bar; the
# board's own heavy work is cached, so on most ticks this is a few jq calls.
"$CONFIG_DIR/plugins/productive_board.sh" >/dev/null 2>&1 || true
# Chips and the overtime suffix read that board, so they paint after it.
productive_chips "$STATE"
