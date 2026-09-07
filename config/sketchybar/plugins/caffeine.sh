#!/usr/bin/env bash
# Keep-awake, cycled by clicking. Three states, and the colour is the whole
# readout:
#
#   dim    off               nothing held
#   green  caffeinate -i     the system will not idle-sleep
#   red    caffeinate -dimu  display, system and disk all held awake
#
# Red is deliberately alarming: -dimu keeps the SCREEN on, which is the mode you
# do not want to leave running by accident on battery.
#
# Click handling lives in caffeine_click.sh, which sources this file for the
# helpers below.
#
# Sourced as a library:  CAFFEINE_LIB=1 source caffeine.sh   (defines only)
# Executed as a plugin:  caffeine.sh                         (renders)

source "$CONFIG_DIR/colors.sh"

# Only the instance this item started counts. The user may well have other
# caffeinate processes around (a long build, `caffeinate -w`, Amphetamine's),
# and killing or reporting on those would be wrong — so we track one PID.
CAFFEINE_STATE_DIR="$SB_CACHE_DIR"      # caffeine_click.sh reads this too
CAFFEINE_STATE_FILE="$CAFFEINE_STATE_DIR/caffeine.pid"

# WHICH mode is running, in a file of its own rather than a second field in the
# pid file. caffeine_pid() parses that file, and check.sh asserts its behaviour
# against three hand-written bare-pid fixtures (a recycled pid, a dead pid,
# garbage) - so widening its format would have meant changing the parser and the
# assertions for a string that has nothing to do with liveness. A missing mode
# file next to a live pid means "i": that is what the only previous version of
# this widget ever started, so a cycle that spans an upgrade reads correctly
# instead of rendering an unknown colour.
CAFFEINE_MODE_FILE="$CAFFEINE_STATE_DIR/caffeine.mode"

# The cycle, in order. off is the absence of a pid file rather than a value.
#
# Read indirectly, as CAFFEINE_ARGS_$mode, by caffeine_click.sh. The linter
# cannot see an indirect expansion, hence the SC2034 waivers below rather than a
# rename. Keeping the flags here rather than in the click handler means a mode's
# arguments sit next to the comment justifying them.
# shellcheck disable=SC2034
CAFFEINE_ARGS_i="-i"
# -u is what turns the display back ON if it is already off, which is the
# difference between "stay awake" and "wake up and stay awake". Note it carries
# a 5 SECOND default timeout of its own (caffeinate(8): "If a timeout is not
# specified with '-t' option, then this assertion is taken with a default of 5
# second timeout") - -d, -i and -m have no timeout and hold for the life of the
# process, so the lasting effect of this mode comes from -d and -m and only the
# initial wake comes from -u.
# shellcheck disable=SC2034
CAFFEINE_ARGS_dimu="-dimu"

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

# The mode of the live caffeinate: i or dimu. Only meaningful while
# caffeine_pid succeeds; on its own it says nothing about liveness.
# Anything unrecognised reads as i rather than as a fourth state - the file is
# ours and short, so a bad value means a half-finished write, and the
# conservative reading of a half-finished write is the gentler mode.
caffeine_mode() {
  local m
  m="$(cat "$CAFFEINE_MODE_FILE" 2>/dev/null | tr -d '[:space:]')"
  case "$m" in dimu) printf 'dimu' ;; *) printf 'i' ;; esac
}

# What a click should start next. off -> i -> dimu -> off.
caffeine_next() {
  if caffeine_pid >/dev/null; then
    case "$(caffeine_mode)" in
      i) printf 'dimu' ;;
      *) printf 'off'  ;;
    esac
  else
    printf 'i'
  fi
}

caffeine_render() {
  if caffeine_pid >/dev/null; then
    local colour
    case "$(caffeine_mode)" in
      dimu) colour="$RED" ;;
      *)    colour="$GREEN" ;;
    esac
    sketchybar --set "$CAFFEINE_ITEM" icon="$CAFFEINE_ICON" icon.color="$colour"
  else
    # Stale or bogus state file (killed externally, PID recycled): forget it,
    # so the next click starts fresh instead of trying to kill a stranger.
    # The mode goes with it - a mode left behind would colour the next cycle's
    # first state red.
    rm -f "$CAFFEINE_STATE_FILE" "$CAFFEINE_MODE_FILE"
    sketchybar --set "$CAFFEINE_ITEM" icon="$CAFFEINE_ICON" icon.color="$FG_DIM"
  fi
}

if [ -z "${CAFFEINE_LIB:-}" ]; then
  # set -u here rather than at the top, unlike every other executed plugin:
  # this file doubles as a sourced library (caffeine_click.sh), and forcing it
  # on a caller that did not ask for it is exactly what a sourced file must not
  # do. The definitions above are set-u-clean either way.
  set -u
  # No card_dispatch: the click is a direct toggle now, so this item owns no
  # popup to close and is not in $CARD_ITEMS. All this tick does is re-validate
  # the PID and repaint, which is what catches a caffeinate killed from outside.
  caffeine_render
fi
