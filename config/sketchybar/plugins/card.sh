#!/usr/bin/env bash
# Hover-card engine, shared by every item that has one.
#
#   card.sh <item> toggle|open|close|tick
#
# Content lives in cards/<item>.sh, which must define card_rows() emitting one
# row per line as: <glyph>\t<color>\t<text>. The engine owns the delay, the
# cancellation, the watchdog and the row plumbing so six items cannot drift.
#
# Click-driven, like the power menu: clicking the item toggles its card, and
# mouse.exited.global dismisses it when the pointer leaves the bar entirely.
# There is no dwell delay - a click is already a deliberate act, so waiting
# half a second after one would just feel broken.
#
# Rows carry their own actions. cards/<item>.sh may add a fourth field, a
# shell command run when that row is clicked; the engine appends a close so
# every row dismisses the card. Rows without one just close it.

source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/plugins/fit.sh"

ITEM="${1:?card.sh needs an item}"
ACTION="${2:-open}"

MAX_OPEN=45        # watchdog: force-close a card left open this long
MAX_CHARS=64

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar"
STAMP="$STATE_DIR/card-$ITEM.at"
mkdir -p "$STATE_DIR"

# Invalidate any pending open, then hide. Cheap and unconditional.
card_close() {
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
  toggle)
    [ "$(sketchybar --query "$ITEM" 2>/dev/null | jq -r '.popup.drawing')" = "on" ] && card_close
    ;;
  tick)
    [ "$(sketchybar --query "$ITEM" 2>/dev/null | jq -r '.popup.drawing')" = "on" ] || exit 0
    AT="$(cat "$STAMP" 2>/dev/null)"
    case "$AT" in ''|*[!0-9]*) card_close ;; esac
    [ $(( $(date +%s) - AT )) -ge "$MAX_OPEN" ] && card_close
    exit 0 ;;
esac

# --- open --------------------------------------------------------------------
# Close any other card first: two open popups at once is never wanted, and
# mouse.exited.global does not always fire between two quick clicks.
for other in meeting productive media cpu wifi caffeine; do
  [ "$other" = "$ITEM" ] && continue
  [ "$(sketchybar --query "$other" 2>/dev/null | jq -r '.popup.drawing')" = "on" ] \
    && sketchybar --set "$other" popup.drawing=off
done

source "$CONFIG_DIR/cards/$ITEM.sh"
N=1
MAX="$(row_count)"; case "$MAX" in ''|*[!0-9]*) MAX=5 ;; esac

while IFS=$'\t' read -r GLYPH COLOR TEXT ACTION; do
  [ "$N" -gt "$MAX" ] && break
  [ -z "$TEXT" ] && continue
  # Every row dismisses the card; a row with an action runs it first.
  CLICK="$CONFIG_DIR/plugins/card.sh $ITEM close"
  [ -n "$ACTION" ] && CLICK="$ACTION; $CLICK"
  sketchybar --set "$ITEM.pop.$N" drawing=on icon="$GLYPH" icon.color="$COLOR" \
                                  label="$(ellipsize "$TEXT" "$MAX_CHARS")" \
                                  click_script="$CLICK"
  N=$(( N + 1 ))
done <<CARDEOF
$(card_rows)
CARDEOF

# Hide leftovers, or the card keeps the previous state's rows on screen.
while [ "$N" -le "$MAX" ]; do
  sketchybar --set "$ITEM.pop.$N" drawing=off
  N=$(( N + 1 ))
done

date +%s > "$STAMP"
sketchybar --set "$ITEM" popup.drawing=on
