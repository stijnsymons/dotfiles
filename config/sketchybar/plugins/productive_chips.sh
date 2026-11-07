#!/usr/bin/env bash
# Paint the timer widget's chips and the overtime suffix from the shared board
# ($SB_CACHE_DIR/productive-board.json, owned by productive_board.sh - the same
# file the herdr.app mod reads, so both UIs show the same chips in the same
# order with the same codes and colours).
#
# One chip = a booking. Four slots, each a stripe item (the booking's colour),
# a code item, and a bracket round both that carries the fill: the bracket is
# what turns green when that booking runs, so the stripe and the code sit on one
# continuous pill. Sketchybar has no per-edge border, hence an item for the
# stripe rather than a border-left.
#
# Sourced by productive.sh, which owns the tick; also run by hand to repaint.
# CONFIG_DIR must be set and colors.sh sourced.

BOARD="${PRODUCTIVE_BOARD:-$SB_CACHE_DIR/productive-board.json}"
CHIP_SLOTS=4
BOARD_STALE=900
CHIP_FILL=0xff16161e          # the pill at rest, as the proposal's mock
CHIP_DARK=0xff1a1b26          # text on the green fill
PIN="$(printf '\342\227\206')"   # U+25C6, the pinned diamond

# productive_chips <state-from-anchor> -> one batched sketchybar call
productive_chips() {
  local state="${1:-unknown}" args=() i code color pin key
  local lines
  lines="$(jq -r '
      . as $b
      | ($b.state // "unknown") as $st
      | ($b.running.key // "") as $run
      | (["\($st)\t\($run)\t\($b.overtime_minutes // 0)"]
         + [ ($b.chips // [])[] as $k
             | ($b.bookings[] | select(.key == $k))
             | "\(.code)\t\(.color)\t\(if .pinned then 1 else 0 end)\t\(.key)\t\(.service_id)" ]) | .[]' \
      "$BOARD" 2>/dev/null)"

  if [ -z "$lines" ]; then
    # No board yet: nothing to switch to, so no chips; the anchor still shows its state.
    for i in $(seq 1 $CHIP_SLOTS); do
      args+=(--set "productive_b$i" drawing=off --set "productive_s$i" drawing=off --set "productive_c$i" drawing=off)
    done
    args+=(--set productive_ot drawing=off)
    sketchybar "${args[@]}" 2>/dev/null
    return
  fi

  local board_state running_key over
  # The board is rebuilt every tick, so a file this old means the refresh is failing:
  # its "running" is no evidence any more, the same rule as the anchor's STALE_AFTER.
  local board_age=$(( $(date +%s) - $(stat -f %m "$BOARD" 2>/dev/null || echo 0) ))
  IFS=$'\t' read -r board_state running_key over <<<"$(printf '%s\n' "$lines" | head -1)"

  # Overtime beside the elapsed time, amber: past 40h it is visible without
  # opening the panel. Hours once it is an hour, minutes before that.
  if [ "${over:-0}" -gt 0 ] 2>/dev/null && [ "$state" != unknown ]; then
    local ot; if [ "$over" -ge 60 ]; then ot="+$(( (over + 30) / 60 ))h"; else ot="+${over}m"; fi
    args+=(--set productive_ot drawing=on label="$ot" label.color="$YELLOW")
  else
    args+=(--set productive_ot drawing=off)
  fi

  i=0
  while IFS=$'\t' read -r code color pin key svc; do
    i=$((i + 1)); [ "$i" -le "$CHIP_SLOTS" ] || break
    local fill="$CHIP_FILL" fg="$FG" stripe="0xff${color#\#}" lbl="$code"
    local click="$CONFIG_DIR/plugins/productive_switch.sh $svc"
    [ "$pin" = 1 ] && lbl="$code$PIN"
    if [ "$state" = unknown ] || [ "$board_state" = unknown ] || [ "$board_age" -gt "$BOARD_STALE" ]; then
      # The proposal's stale state: everything at ~45%, still clickable.
      fg="$FG_DIM"; stripe="0x73${color#\#}"
    elif [ -n "$running_key" ] && [ "$key" = "$running_key" ]; then
      fill="$GREEN"; fg="$CHIP_DARK"; stripe="0x80${CHIP_DARK#0xff}"
      # The running chip has nothing to switch to: a second click opens the panel.
      click="$CONFIG_DIR/plugins/productive_panel.sh"
    fi
    args+=(--set "productive_b$i" drawing=on background.color="$fill"
           --set "productive_s$i" drawing=on background.color="$stripe"
           --set "productive_c$i" drawing=on label="$lbl" label.color="$fg"
             click_script="$click"
           --set "productive_s$i" click_script="$click"
           --set "productive_b$i" click_script="$click")
  done < <(printf '%s\n' "$lines" | tail -n +2)
  # Slots the board has no chip for (a fresh week with fewer than four bookings).
  while [ "$i" -lt "$CHIP_SLOTS" ]; do
    i=$((i + 1))
    args+=(--set "productive_b$i" drawing=off --set "productive_s$i" drawing=off --set "productive_c$i" drawing=off)
  done
  sketchybar "${args[@]}" 2>/dev/null
}
