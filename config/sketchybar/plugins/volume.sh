#!/usr/bin/env bash
# Volume level + mute state. Click toggles mute, scroll changes volume.
set -u

source "$CONFIG_DIR/colors.sh"

set_volume() { osascript -e "set volume output volume $1"; }

case "${SENDER:-}" in
  mouse.clicked)
    osascript -e 'set volume output muted not (output muted of (get volume settings))'
    ;;
  mouse.scrolled)
    # The direction arrives in $SCROLL_DELTA, not $INFO. Zero is a momentum-end
    # event: bail before the osascript rather than nudge the volume down.
    D="${SCROLL_DELTA:-0}"
    # Tested as a string, not with $(( )): sketchybar formats the delta as a
    # float and arithmetic would choke on the decimal point.
    case "$D" in ''|0|-0|0.0*|-0.0*) exit 0 ;; esac
    CUR="$(osascript -e 'output volume of (get volume settings)')"
    case "$D" in -*) DELTA=-6 ;; *) DELTA=6 ;; esac
    NEXT=$(( CUR + DELTA ))
    [ "$NEXT" -gt 100 ] && NEXT=100
    [ "$NEXT" -lt 0 ] && NEXT=0
    set_volume "$NEXT"
    ;;
esac

# volume_change hands the new level in $INFO; anything else we read the system.
# The mute flag is never in $INFO though, and there is no update_freq to
# self-correct, so a keyboard mute would stay bright yellow. Ask for it.
if [ "${SENDER:-}" = "volume_change" ]; then
  VOLUME="${INFO:-}"
  MUTED="$(osascript -e 'output muted of (get volume settings)')"
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
