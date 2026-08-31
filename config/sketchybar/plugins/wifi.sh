#!/usr/bin/env bash
# Wi-Fi SSID. `networksetup -getairportnetwork` is broken since macOS 15,
# so read the SSID out of ipconfig's interface summary instead.

source "$CONFIG_DIR/colors.sh"

IFACE="$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}')"
SSID="$(ipconfig getsummary "${IFACE:-en0}" 2>/dev/null | awk -F' SSID : ' '/ SSID : / {print $2; exit}')"

# Icon-only: the SSID is carried as the tooltip-ish label but never drawn.
if [ -n "$SSID" ]; then
  sketchybar --set "$NAME" icon="󰖩" icon.color="$BLUE"
else
  sketchybar --set "$NAME" icon="󰖪" icon.color="$FG_DIM"
fi
