#!/usr/bin/env bash
# Hover-card engine, shared by every item that has one.
#
#   card.sh <item> toggle|open|close|tick
#   card.sh away
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
# `away` is the outside click. sketchybar has no global click event, so the
# card_watch item in sketchybarrc subscribes to the ones a click elsewhere
# implies ($CARD_AWAY_EVENTS) and routes them all here.
#
# Rows carry their own actions. cards/<item>.sh may add a fourth field, a
# shell command run when that row is clicked; the engine appends a close so
# every row dismisses the card. Rows without one just close it.
set -u

source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/plugins/fit.sh"

ITEM="${1:?card.sh needs an item}"
ACTION="${2:-open}"

# `away` is the one action with no item - an outside click dismisses every card -
# so it is accepted as the sole argument rather than made to name one.
[ "$ITEM" = away ] && ACTION=away

MAX_OPEN=45        # watchdog: force-close a card left open this long
AWAY_GRACE=1       # away: spare a card opened this recently (see card_away)
MAX_CHARS=64

STAMP="$SB_CACHE_DIR/card-$ITEM.at"

# Invalidate any pending open, then hide. Cheap and unconditional.
card_close() {
  rm -f "$STAMP"
  sketchybar --set "$ITEM" popup.drawing=off
  exit 0
}

# The outside click. Closes every card rather than asking which one was open:
# seven --query round trips cost more than seven blind closes, and
# popup.drawing=off on an already-closed card is a no-op - the same trade the
# open path below makes. Driven by $CARD_ITEMS so a new card is wired in by
# naming it there and nowhere else.
card_away() {
  NOW="$(date +%s)"
  AWAY_ARGS=()
  for away_item in $CARD_ITEMS; do
    # Braces, not a trailing 2>/dev/null: bash applies the input redirect first
    # and reports a missing stamp on the stderr it still has, so the trailing
    # form leaked "No such file or directory" for every closed card - six or
    # seven lines into the bar's log on every single app switch.
    AT=0
    { read -r AT < "$SB_CACHE_DIR/card-$away_item.at"; } 2>/dev/null
    case "$AT" in ''|*[!0-9]*) AT=0 ;; esac
    # A card opened in this same second keeps its popup. A row action that
    # focuses an app - the meeting row's zoom://, herdr's editor - fires
    # front_app_switched straight back at us, and sketchybar's --update at
    # config load runs this script with SENDER=forced; without the grace either
    # would shut a card before it had drawn.
    [ "$AT" -gt 0 ] && [ $(( NOW - AT )) -lt "$AWAY_GRACE" ] && continue
    rm -f "$SB_CACHE_DIR/card-$away_item.at"
    AWAY_ARGS+=(--set "$away_item" popup.drawing=off)
  done
  [ "${#AWAY_ARGS[@]}" -gt 0 ] && sketchybar "${AWAY_ARGS[@]}"
  exit 0
}

case "$ACTION" in
  close) card_close ;;
  away)  card_away ;;
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
#
# Set unconditionally, in one call: popup.drawing=off on an already-closed card
# is a no-op, so asking each of the five siblings whether it was open first
# bought nothing and cost a query plus a jq apiece on every single click.
CLOSE_ARGS=()
for other in $CARD_ITEMS; do
  [ "$other" = "$ITEM" ] && continue
  CLOSE_ARGS+=(--set "$other" popup.drawing=off)
done
[ "${#CLOSE_ARGS[@]}" -gt 0 ] && sketchybar "${CLOSE_ARGS[@]}"

# shellcheck source=/dev/null
source "$CONFIG_DIR/cards/$ITEM.sh"
N=1
MAX="$(card_rows_max "$ITEM")"   # sketchybarrc pre-created exactly this many rows

TAB_CH=$'\t'
# Rows are collected and sent as one call, together with the popup.drawing=on
# that reveals them: a card of eight rows was eight round trips, each ~8ms, on
# the click path where the delay is felt.
ROW_ARGS=()
while IFS=$'\t' read -r GLYPH COLOR TEXT ACTION; do
  [ "$N" -gt "$MAX" ] && break
  [ -z "$TEXT" ] && continue
  # Belt and braces behind card_text: an action is handed to sh, so anything
  # that could chain a second command onto it has no business in one. Every
  # real action is a path, an index and maybe a quoted URL. Quotes stay legal -
  # the calendar and Wi-Fi rows need them - which is why the one value that
  # lands inside them, the calendar eid, is whitelisted where it is extracted.
  # A cleared action costs the row its click, never its text.
  case "$ACTION" in *[\;\|\&\$\`\\\<\>\(\)]*|*"$TAB_CH"*) ACTION="" ;; esac
  # Every row dismisses the card; a row with an action runs it first.
  CLICK="$CONFIG_DIR/plugins/card.sh $ITEM close"
  [ -n "$ACTION" ] && CLICK="$ACTION; $CLICK"
  ROW_ARGS+=(--set "$ITEM.pop.$N" drawing=on icon="$GLYPH" icon.color="$COLOR"
                   label="$(ellipsize "$TEXT" "$MAX_CHARS")"
                   click_script="$CLICK")
  N=$(( N + 1 ))
done <<CARDEOF
$(card_rows)
CARDEOF

# Hide leftovers, or the card keeps the previous state's rows on screen.
while [ "$N" -le "$MAX" ]; do
  ROW_ARGS+=(--set "$ITEM.pop.$N" drawing=off)
  N=$(( N + 1 ))
done

date +%s > "$STAMP"
sketchybar "${ROW_ARGS[@]}" --set "$ITEM" popup.drawing=on
