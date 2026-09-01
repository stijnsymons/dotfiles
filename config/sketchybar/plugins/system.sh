#!/usr/bin/env bash
# One script, two items: cpu + mem. Runs on the cpu item's update_freq.
#
# pipefail matters here: the readings are `ps | awk` and `memory_pressure | awk`
# pipelines, and a failing left side would otherwise hand awk nothing and paint
# a confident 0% over a machine that is actually busy.
set -u
set -o pipefail

source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/plugins/sys_lib.sh"
# Hover dispatch, before anything expensive: sketchybar invokes this same
# script for every subscribed event. Leaving the bar closes the card; any other
# event is a routine tick, which is also what polices a card left open by a
# missed mouse.exited.
# mem is stacked on top of cpu and shares its card, so both dispatch to "cpu".
card_dispatch cpu

# Both numbers come from sys_lib.sh, which is what the card behind this item
# reads too - see there for why `top -l 2` is gone (1.7s per tick, and the card
# disagreed with the item it belongs to).
CPU="$(cpu_pct)"
MEM="$(mem_pct)"

color_for() { # $1 = percentage
  if   [ "$1" -ge 85 ]; then echo "$RED"
  elif [ "$1" -ge 60 ]; then echo "$YELLOW"
  else echo "$AQUA"; fi
}

sketchybar --set cpu label="${CPU}%" icon.color="$(color_for "${CPU:-0}")" \
           --set mem label="${MEM}%" icon.color="$(color_for "${MEM:-0}")"
