#!/usr/bin/env bash
# Terminal light/dark readout: sun when light, moon when dark - the effective
# mode, so the `theme` override if one is set, else macOS. See
# ~/.config/ghostty/theme for what follows it.
#
# Repaints on appearance_change: `theme` triggers it after every switch, and it
# is also macOS's AppleInterfaceThemeChangedNotification, for a sunset switch
# with no override set. No polling.
set -u
source "$CONFIG_DIR/colors.sh"

# U+F0599 md-weather-sunny / U+F0594 md-weather-night as octal escapes: plane-15
# glyphs, which editors drop silently (see the note on CAFFEINE_ICON).
if [ "$("$HOME/.config/ghostty/theme" status)" = dark ]; then
  sketchybar --set "$NAME" icon="$(printf '\363\260\226\224')" icon.color="$FG_DIM"
else
  sketchybar --set "$NAME" icon="$(printf '\363\260\226\231')" icon.color="$YELLOW"
fi
