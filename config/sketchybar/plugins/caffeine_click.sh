#!/usr/bin/env bash
# Click handler for the keep-awake item. Cycles off -> -i -> -dimu -> off and
# repaints straight away; see caffeine.sh for what each state holds and why red
# is the alarming one.
#
# Every transition kills first and starts second, including i -> dimu. Two
# caffeinates would both be ours by the state file's reckoning but only one pid
# fits in it, so the other would be orphaned for the rest of the login session
# with nothing tracking it - which is exactly the leak the single-pid design
# exists to prevent.
set -u

CAFFEINE_LIB=1 source "$CONFIG_DIR/plugins/caffeine.sh"

mkdir -p "$CAFFEINE_STATE_DIR"

NEXT="$(caffeine_next)"

# Stop whatever we are holding, whichever direction we are going. Only ever the
# pid we recorded: `pkill caffeinate` would take out the one a long build, a
# `caffeinate -w`, or Amphetamine is holding - and on this machine that is not
# hypothetical, there are usually strangers in `ps`.
if PID="$(caffeine_pid)"; then
  kill "$PID" 2>/dev/null
  rm -f "$CAFFEINE_STATE_FILE" "$CAFFEINE_MODE_FILE"
fi

if [ "$NEXT" != "off" ]; then
  # Indirect through the CAFFEINE_ARGS_<mode> pair rather than a case here, so
  # the flags for a mode are written down once, next to the comment explaining
  # them, and adding a fourth state is one variable and one line in
  # caffeine_next.
  eval "ARGS=\"\${CAFFEINE_ARGS_$NEXT}\""
  # Word-split on purpose: ARGS is our own literal, never user input.
  # shellcheck disable=SC2086
  #
  # Must outlive this click handler: sketchybar reaps the script, and a plain
  # background job would take the SIGHUP with it, leaving a coloured icon and no
  # caffeinate. nohup + & detaches it; disown drops it from the jobs table.
  nohup caffeinate $ARGS >/dev/null 2>&1 &
  PID=$!
  disown "$PID" 2>/dev/null || true
  # Record only if it actually came up. A missing caffeinate binary, or an exec
  # that fails, would otherwise leave a pid file pointing at nothing and paint
  # the item as holding something it is not.
  #
  # The mode is written BEFORE the pid, so the two can only ever be inconsistent
  # in the harmless direction: a mode with no pid reads as off and is cleaned up
  # on the next render, whereas a pid with no mode would render green while
  # -dimu was actually running.
  if kill -0 "$PID" 2>/dev/null; then
    printf '%s\n' "$NEXT" > "$CAFFEINE_MODE_FILE"
    printf '%s\n' "$PID"  > "$CAFFEINE_STATE_FILE"
  fi
fi

caffeine_render
