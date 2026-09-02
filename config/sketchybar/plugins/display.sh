#!/usr/bin/env bash
# Move and re-fit the bar on every display_change.
#
# Two jobs:
#  - pick the bar's screen: screen-metrics prefers the external display when
#    one is plugged in and reports its UUID; bar_display maps that to the
#    arrangement id sketchybar wants. Undocking makes screen-metrics fall back
#    to the built-in, so the bar comes home on its own.
#  - re-fit the height: the reserved top inset changes with resolution (38pt at
#    1800x1169, 32pt at the default 1512x982), and a screen that reserves
#    nothing - an external - reports 0, where the 38pt default applies.
set -u
source "$CONFIG_DIR/colors.sh"

METRICS="$CONFIG_DIR/bin/screen-metrics"
[ -x "$METRICS" ] || exit 0

read -r TOP _NL _NR _W UUID <<<"$("$METRICS" 2>/dev/null)"
case "${TOP:-}" in
  ''|*[!0-9]*) exit 0 ;;
esac
[ "$TOP" -gt 0 ] || TOP=38

sketchybar --bar display="$(bar_display "${UUID:-}")" height="$TOP"
