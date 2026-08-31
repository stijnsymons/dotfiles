#!/usr/bin/env bash
# Volume level + mute state. Click toggles mute, scroll changes volume.

source "$CONFIG_DIR/colors.sh"

set_volume() { osascript -e "set volume output volume $1"; }

case "$SENDER" in
  mouse.clicked)
    osascript -e 'set volume output muted not (output muted of (get volume settings))'
    ;;
  mouse.scrolled)
    CUR="$(osascript -e 'output volume of (get volume settings)')"
    DELTA=$(( ${INFO:-0} > 0 ? 6 : -6 ))
    NEXT=$(( CUR + DELTA ))
    [ "$NEXT" -gt 100 ] && NEXT=100
    [ "$NEXT" -lt 0 ] && NEXT=0
    set_volume "$NEXT"
    ;;
esac

# volume_change hands the new level in $INFO; anything else we read the system.
if [ "$SENDER" = "volume_change" ]; then
  VOLUME="$INFO"
  MUTED="false"
else
  VOLUME="$(osascript -e 'output volume of (get volume settings)')"
  MUTED="$(osascript -e 'output muted of (get volume settings)')"
fi

if [ "$MUTED" = "true" ]; then
  ICON="󰖁"; COLOR="$FG_DIM"
else
  COLOR="$YELLOW"
  case "$VOLUME" in
    100|[6-9][0-9])   ICON="󰕾" ;;
    [3-5][0-9])       ICON="󰖀" ;;
    [1-9]|[1-2][0-9]) ICON="󰕿" ;;
    *)                ICON="󰖁" ;;
  esac
fi

sketchybar --set "$NAME" icon="$ICON" icon.color="$COLOR" label="${VOLUME}%"
