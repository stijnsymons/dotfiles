#!/usr/bin/env bash
# One script, two items: cpu + mem. Runs on the cpu item's update_freq.

source "$CONFIG_DIR/colors.sh"
# Hover dispatch, before anything expensive: sketchybar invokes this same
# script for every subscribed event. Leaving the bar closes the card; any other
# event is a routine tick, which is also what polices a card left open by a
# missed mouse.exited.
# mem is stacked on top of cpu and shares its card, so both dispatch to "cpu".
card_dispatch cpu

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
