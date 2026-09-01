#!/usr/bin/env bash
# One script, two items: cpu + mem. Runs on the cpu item's update_freq.
#
# A failing reading must not paint a confident 0% over a machine that is
# actually busy. Both readings are `<sampler> | awk` pipelines, so it takes two
# halves: pipefail here, and awk printing nothing when the sampler handed it no
# rows (sys_lib.sh). An empty reading then leaves that item untouched, showing
# its last good value until the next tick.
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

# Built up rather than sent as one fixed pair, so a failed sample drops out
# instead of rendering as 0% - and still only one sketchybar spawn a tick.
ARGS=()
[ -n "$CPU" ] && ARGS+=(--set cpu label="${CPU}%" icon.color="$(color_for "$CPU")")
[ -n "$MEM" ] && ARGS+=(--set mem label="${MEM}%" icon.color="$(color_for "$MEM")")
if [ "${#ARGS[@]}" -gt 0 ]; then sketchybar "${ARGS[@]}"; fi
