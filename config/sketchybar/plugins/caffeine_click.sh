#!/usr/bin/env bash
# Click handler for the keep-awake item: toggles our own `caffeinate -i`
# and repaints the item straight away.

CAFFEINE_LIB=1 source "$CONFIG_DIR/plugins/caffeine.sh"

mkdir -p "$CAFFEINE_STATE_DIR"

if PID="$(caffeine_pid)"; then
  # Kill only the PID we started. `pkill caffeinate` would take out the one a
  # long build or another tool is holding.
  kill "$PID" 2>/dev/null
  rm -f "$CAFFEINE_STATE_FILE"
else
  # Must outlive this click handler: sketchybar reaps the script, and a plain
  # background job would take the SIGHUP with it, leaving a green icon and no
  # caffeinate. nohup + & detaches it; disown drops it from the jobs table.
  nohup caffeinate -i >/dev/null 2>&1 &
  PID=$!
  disown "$PID" 2>/dev/null || true
  # Only record it if it actually came up (no caffeinate binary, exec failure).
  if kill -0 "$PID" 2>/dev/null; then
    printf '%s\n' "$PID" > "$CAFFEINE_STATE_FILE"
  fi
fi

caffeine_render
