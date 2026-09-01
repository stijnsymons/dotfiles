#!/usr/bin/env bash
# Keep-awake toggle. Renders the state of *our* `caffeinate -i`: green mug when
# it is running, dim mug when it is not. Click handling lives in
# caffeine_click.sh, which sources this file for the helpers below.
#
# Sourced as a library:  CAFFEINE_LIB=1 source caffeine.sh   (defines only)
# Executed as a plugin:  caffeine.sh                         (renders)

source "$CONFIG_DIR/colors.sh"

# Only the instance this item started counts. The user may well have other
# caffeinate processes around (a long build, `caffeinate -w`, Amphetamine's),
# and killing or reporting on those would be wrong — so we track one PID.
CAFFEINE_STATE_DIR="$SB_CACHE_DIR"      # caffeine_click.sh reads this too
CAFFEINE_STATE_FILE="$CAFFEINE_STATE_DIR/caffeine.pid"

# U+F0176 md-coffee, written as an octal escape. The glyph lives in plane 15
# (SPUA-A); editors and copy/paste drop those silently, and a dropped glyph
# renders as a blank box with no other symptom. Verified present in
# HackNerdFont-{Regular,Bold}.ttf as glyph `md-coffee`.
CAFFEINE_ICON="$(printf '\363\260\205\266')"

# The item this plugin paints. Deliberately NOT $NAME: caffeine_click.sh is
# also wired as the click_script of a card ROW, and sketchybar sets NAME to the
# row it fired from (caffeine.pop.N). Rendering to $NAME therefore recoloured
# the row and left the mug stale until the next update_freq tick - up to 30s of
# "I turned it on and the cup is still grey".
CAFFEINE_ITEM="caffeine"

# Print the PID of our live caffeinate, or return 1. A PID file alone proves
# nothing: PIDs are recycled, so the process must be alive AND still be a
# caffeinate. Anything else is stale and reads as "off".
caffeine_pid() {
  local pid comm
  [ -r "$CAFFEINE_STATE_FILE" ] || return 1
  pid="$(cat "$CAFFEINE_STATE_FILE" 2>/dev/null | tr -d '[:space:]')"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm="$(ps -p "$pid" -o comm= 2>/dev/null)"
  case "$comm" in
    */caffeinate|caffeinate) printf '%s' "$pid" ;;
    *) return 1 ;;
  esac
}

caffeine_render() {
  if caffeine_pid >/dev/null; then
    sketchybar --set "$CAFFEINE_ITEM" icon="$CAFFEINE_ICON" icon.color="$GREEN"
  else
    # Stale or bogus state file (killed externally, PID recycled): forget it,
    # so the next click starts fresh instead of trying to kill a stranger.
    rm -f "$CAFFEINE_STATE_FILE"
    sketchybar --set "$CAFFEINE_ITEM" icon="$CAFFEINE_ICON" icon.color="$FG_DIM"
  fi
}

if [ -z "${CAFFEINE_LIB:-}" ]; then
  # set -u here rather than at the top, unlike every other executed plugin:
  # this file doubles as a sourced library (caffeine_click.sh), and forcing it
  # on a caller that did not ask for it is exactly what a sourced file must not
  # do. The definitions above are set-u-clean either way.
  set -u
  card_dispatch caffeine
  caffeine_render
fi
