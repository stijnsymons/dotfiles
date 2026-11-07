#!/usr/bin/env bash
# Open (or close) the Productive panel, right under the anchor item.
#
#   productive_panel.sh toggle
#
# The panel is bin/productive-panel, a native window that closes itself the
# moment it loses focus. That is what makes a plain toggle wrong: clicking the
# anchor while the panel is open first takes focus away (so the panel closes),
# and THEN delivers the click here - which would reopen what the click just
# closed. The panel stamps productive-panel.closed as it goes, and a click
# within the grace of that stamp is the closing click, not a new one.
#
# The anchor's frame is queried from sketchybar rather than hardcoded, so the
# panel follows the item when the bar re-lays out (a long front_app name, the
# overtime suffix appearing).
set -u
source "$CONFIG_DIR/colors.sh"

BIN="$CONFIG_DIR/bin/productive-panel"
PIDF="$SB_CACHE_DIR/productive-panel.pid"
STAMP="$SB_CACHE_DIR/productive-panel.closed"
GRACE=1   # seconds

[ -x "$BIN" ] || exit 1

# ps, not pkill/pgrep: sysmond has been seen refusing those while ps kept working
# (see the helper start in sketchybarrc).
PID="$(cat "$PIDF" 2>/dev/null)"
case "$PID" in ''|*[!0-9]*) PID="" ;; esac
if [ -n "$PID" ] && [ "$(ps -p "$PID" -o comm= 2>/dev/null | xargs basename 2>/dev/null)" = productive-panel ]; then
  kill "$PID" 2>/dev/null
  exit 0
fi

NOW="$(date +%s)"
AT="$(cat "$STAMP" 2>/dev/null)"; AT="${AT%.*}"
case "$AT" in ''|*[!0-9]*) AT=0 ;; esac
[ $(( NOW - AT )) -lt "$GRACE" ] && exit 0

# The item's rect spans the bar's full height, so its bottom edge IS the bar's
# bottom edge on whichever display the bar is on (30 on the DELL, 32-38 on the
# notched built-in), which no hardcoded number gets right on both.
read -r X BOTTOM <<<"$(sketchybar --query productive 2>/dev/null | jq -r '
  .bounding_rects|to_entries[0].value | "\(.origin[0]|floor) \((.origin[1] + .size[1])|ceil)"' 2>/dev/null)"
case "${X:-}" in ''|*[!0-9]*) X=12 ;; esac
case "${BOTTOM:-}" in ''|*[!0-9]*|0) BOTTOM=34 ;; esac

"$BIN" --x "$X" --top "$(( BOTTOM + 4 ))" >/dev/null 2>&1 &
echo $! >"$PIDF"
