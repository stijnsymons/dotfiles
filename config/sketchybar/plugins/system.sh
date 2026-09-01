#!/usr/bin/env bash
# One script, two items: cpu + mem. Runs on the cpu item's update_freq.

source "$CONFIG_DIR/colors.sh"
# Hover dispatch, before anything expensive. sketchybar invokes this same
# script for every subscribed event; card.sh owns the dwell delay so the card
# does not fire while the pointer is merely crossing the bar.
case "${SENDER:-}" in
  mouse.entered)                     exec "$CONFIG_DIR/plugins/card.sh" cpu open ;;
  mouse.exited|mouse.exited.global)  exec "$CONFIG_DIR/plugins/card.sh" cpu close ;;
esac


# top samples twice so the second reading is a real delta, not since-boot average.
CPU=$(top -l 2 -n 0 -s 1 | awk '/CPU usage/ {u=$3+$5} END {printf "%.0f", u}')
# memory_pressure reports free %, so used = 100 - free.
MEM=$(memory_pressure | awk '/free percentage/ {gsub("%","",$NF); printf "%.0f", 100-$NF}')

color_for() { # $1 = percentage
  if   [ "$1" -ge 85 ]; then echo "$RED"
  elif [ "$1" -ge 60 ]; then echo "$YELLOW"
  else echo "$AQUA"; fi
}

sketchybar --set cpu label="${CPU}%" icon.color="$(color_for "${CPU:-0}")" \
           --set mem label="${MEM}%" icon.color="$(color_for "${MEM:-0}")"
