#!/usr/bin/env bash
set -u

source "$CONFIG_DIR/colors.sh"
# Hover dispatch, before anything expensive: sketchybar invokes this same
# script for every subscribed event. Leaving the bar closes the card; any other
# event is a routine tick, which is also what polices a card left open by a
# missed mouse.exited.
card_dispatch clock

sketchybar --set "$NAME" label="$(date '+%a %d %b %H:%M')"
