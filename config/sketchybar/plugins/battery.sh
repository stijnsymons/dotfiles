#!/usr/bin/env bash

source "$CONFIG_DIR/colors.sh"

BATT="$(pmset -g batt)"
PERCENTAGE="$(printf '%s' "$BATT" | grep -Eo '[0-9]+%' | head -1 | tr -d '%')"
[ -z "$PERCENTAGE" ] && exit 0

case "$PERCENTAGE" in
  100|9[0-9]) ICON=""; COLOR="$GREEN"  ;;
  [6-8][0-9]) ICON=""; COLOR="$GREEN"  ;;
  [3-5][0-9]) ICON=""; COLOR="$YELLOW" ;;
  [1-2][0-9]) ICON=""; COLOR="$ORANGE" ;;
  *)          ICON=""; COLOR="$RED"    ;;
esac

case "$BATT" in
  *"AC Power"*) ICON=""; COLOR="$AQUA" ;;
esac

sketchybar --set "$NAME" icon="$ICON" icon.color="$COLOR" label="${PERCENTAGE}%"
