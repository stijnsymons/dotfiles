#!/usr/bin/env bash
# Wi-Fi SSID. `networksetup -getairportnetwork` is broken since macOS 15,
# so read the SSID out of ipconfig's interface summary instead.

source "$CONFIG_DIR/colors.sh"
# Hover dispatch, before anything expensive. sketchybar invokes this same
# script for every subscribed event; card.sh owns the dwell delay so the card
# does not fire while the pointer is merely crossing the bar.
case "${SENDER:-}" in
  mouse.entered)                     exec "$CONFIG_DIR/plugins/card.sh" wifi open ;;
  mouse.exited|mouse.exited.global)  exec "$CONFIG_DIR/plugins/card.sh" wifi close ;;
esac


IFACE="$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}')"
SSID="$(ipconfig getsummary "${IFACE:-en0}" 2>/dev/null | awk -F' SSID : ' '/ SSID : / {print $2; exit}')"

# Icon-only: the SSID is carried as the tooltip-ish label but never drawn.
if [ -n "$SSID" ]; then
  sketchybar --set "$NAME" icon="󰖩" icon.color="$BLUE"
else
  sketchybar --set "$NAME" icon="󰖪" icon.color="$FG_DIM"
fi
