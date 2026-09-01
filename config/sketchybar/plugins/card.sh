#!/usr/bin/env bash
# Hover-card engine, shared by every item that has one.
#
#   card.sh <item> open|close|tick
#
# Content lives in cards/<item>.sh, which must define card_rows() emitting one
# row per line as: <glyph>\t<color>\t<text>. The engine owns the delay, the
# cancellation, the watchdog and the row plumbing so six items cannot drift.
#
# Timing is deliberately asymmetric - slow to show, instant to hide. A card
# that appears the moment the pointer crosses the bar fires constantly while
# you are just reaching for the menu bar; one that lingers after you leave is
# in the way. So: OPEN_DELAY before showing, nothing at all before hiding.
#
# Cancellation: `open` stamps a token, sleeps, then re-reads it. Any later
# open or close writes a new token, so the sleeping instance finds its own
# token gone and exits without drawing. Without this, brushing across four
# items queues four cards that all appear a moment later.

source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/plugins/fit.sh"

ITEM="${1:?card.sh needs an item}"
ACTION="${2:-open}"

OPEN_DELAY=0.5     # seconds the pointer must rest before the card appears
MAX_OPEN=45        # watchdog: force-close a card left open this long
MAX_CHARS=64

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar"
TOKEN="$STATE_DIR/card-$ITEM.token"
STAMP="$STATE_DIR/card-$ITEM.at"
mkdir -p "$STATE_DIR"

# Invalidate any pending open, then hide. Cheap and unconditional.
card_close() {
  printf '%s' "$RANDOM$$" > "$TOKEN"
  rm -f "$STAMP"
  sketchybar --set "$ITEM" popup.drawing=off
  exit 0
}

row_count() {
  sketchybar --query bar 2>/dev/null \
    | jq -r --arg p "$ITEM.pop." '[.items[]|select(startswith($p))]|length'
}

case "$ACTION" in
  close) card_close ;;
  tick)
    [ "$(sketchybar --query "$ITEM" 2>/dev/null | jq -r '.popup.drawing')" = "on" ] || exit 0
    AT="$(cat "$STAMP" 2>/dev/null)"
    case "$AT" in ''|*[!0-9]*) card_close ;; esac
    [ $(( $(date +%s) - AT )) -ge "$MAX_OPEN" ] && card_close
    exit 0 ;;
esac

# --- open, after the dwell delay --------------------------------------------
MINE="$RANDOM$$-$(date +%s)"
printf '%s' "$MINE" > "$TOKEN"
sleep "$OPEN_DELAY"
# Pointer moved on, or another card claimed the hover: abandon silently.
[ "$(cat "$TOKEN" 2>/dev/null)" = "$MINE" ] || exit 0

source "$CONFIG_DIR/cards/$ITEM.sh"
N=1
MAX="$(row_count)"; case "$MAX" in ''|*[!0-9]*) MAX=5 ;; esac

while IFS=$'\t' read -r GLYPH COLOR TEXT; do
  [ "$N" -gt "$MAX" ] && break
  [ -z "$TEXT" ] && continue
  sketchybar --set "$ITEM.pop.$N" drawing=on icon="$GLYPH" icon.color="$COLOR" \
                                  label="$(ellipsize "$TEXT" "$MAX_CHARS")"
  N=$(( N + 1 ))
done <<CARDEOF
$(card_rows)
CARDEOF

# Hide leftovers, or the card keeps the previous state's rows on screen.
while [ "$N" -le "$MAX" ]; do
  sketchybar --set "$ITEM.pop.$N" drawing=off
  N=$(( N + 1 ))
done

# Re-check: card_rows() may have taken a moment, and the pointer may have left.
[ "$(cat "$TOKEN" 2>/dev/null)" = "$MINE" ] || exit 0
date +%s > "$STAMP"
sketchybar --set "$ITEM" popup.drawing=on
