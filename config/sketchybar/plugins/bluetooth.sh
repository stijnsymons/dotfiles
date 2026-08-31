#!/usr/bin/env bash
# Bluetooth power + first connected device. Click opens Settings > Bluetooth.
#
# blueutil is NOT used: on macOS 26 `blueutil --power` reports 0 while Bluetooth
# is on (system_profiler says "attrib_on" for the same controller), which showed
# the item as permanently off. Same class of bug as the networksetup one in
# wifi.sh. system_profiler is authoritative and costs ~0.2s, fine at update_freq=60.

source "$CONFIG_DIR/colors.sh"

BT="$(system_profiler SPBluetoothDataType -json 2>/dev/null)"
STATE="$(printf '%s' "$BT" | jq -r '.SPBluetoothDataType[0].controller_properties.controller_state // empty')"

# Icon-only: 󰂱 blue = connected, 󰂯 = on but idle, 󰂲 dim = powered off.
# "on but idle" is deliberately NOT dimmed - a dim icon reads as "off", which is
# exactly the confusion this plugin used to cause.
if [ "$STATE" != "attrib_on" ]; then
  sketchybar --set "$NAME" icon="󰂲" icon.color="$FG_DIM"
  exit 0
fi

DEVICE="$(printf '%s' "$BT" | jq -r '[.SPBluetoothDataType[0].device_connected[]? | keys[0]] | first // empty')"

if [ -n "$DEVICE" ]; then
  sketchybar --set "$NAME" icon="󰂱" icon.color="$BLUE"
else
  sketchybar --set "$NAME" icon="󰂯" icon.color="$FG"
fi
