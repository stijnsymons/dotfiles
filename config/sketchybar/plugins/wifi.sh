#!/usr/bin/env bash
# Wi-Fi SSID. `networksetup -getairportnetwork` is broken since macOS 15,
# so read the SSID out of ipconfig's interface summary instead.
set -u

source "$CONFIG_DIR/colors.sh"
# Hover dispatch, before anything expensive: sketchybar invokes this same
# script for every subscribed event. Leaving the bar closes the card; any other
# event is a routine tick, which is also what polices a card left open by a
# missed mouse.exited.
card_dispatch wifi

IFACE="$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}')"
SSID="$(ipconfig getsummary "${IFACE:-en0}" 2>/dev/null | awk -F' SSID : ' '/ SSID : / {print $2; exit}')"

# Icon-only: the SSID is carried as the tooltip-ish label but never drawn.
if [ -n "$SSID" ]; then
  sketchybar --set "$NAME" icon="󰖩" icon.color="$BLUE"
else
  sketchybar --set "$NAME" icon="󰖪" icon.color="$FG_DIM"
fi
