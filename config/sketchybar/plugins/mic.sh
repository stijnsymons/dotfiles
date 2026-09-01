#!/usr/bin/env bash
# Mic-in-use indicator. Hidden unless something is actually capturing.
# Click opens the Microphone privacy pane.
#
# The helper is compiled by bin/build.sh at startup, so a fresh clone needs no
# manual build step (binaries are gitignored; only the .swift sources tracked).
set -u

source "$CONFIG_DIR/colors.sh"

BIN="$CONFIG_DIR/bin/mic-active"

# bin/build.sh (run from sketchybarrc) compiles this. If it is absent there is
# no toolchain, so hide rather than spam the bar.
if [ ! -x "$BIN" ]; then
  sketchybar --set "$NAME" drawing=off
  exit 0
fi

if [ "$("$BIN" 2>/dev/null)" = "1" ]; then
  sketchybar --set "$NAME" drawing=on icon="󰍬" icon.color="$RED"
else
  sketchybar --set "$NAME" drawing=off
fi
