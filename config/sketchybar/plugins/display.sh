#!/usr/bin/env bash
# Re-fit the bar to the current display.
#
# The reserved top inset changes with resolution (38pt at 1800x1169, 32pt at the
# default 1512x982). sketchybarrc reads it once at load, so without this the bar
# keeps its old height after a resolution change and overhangs - or leaves a gap
# above - the app windows below it.
set -u

METRICS="$CONFIG_DIR/bin/screen-metrics"
[ -x "$METRICS" ] || exit 0

read -r TOP _NL _NR _W <<<"$("$METRICS" 2>/dev/null)"
case "${TOP:-}" in
  ''|*[!0-9]*) exit 0 ;;
esac

[ "$TOP" -gt 0 ] && sketchybar --bar height="$TOP"
