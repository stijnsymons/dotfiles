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
# A fourth colour is not part of the cycle and is not yours to click:
#
#   blue   caffeinate -idsu  an agent is working (herdr flock), hands off
#
# That one is held automatically for as long as the flock reports a working
# agent, and it outranks both manual colours because it holds strictly more.
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

# The automatic hold. While any herdr agent is working the machine stays fully
# awake, whatever the manual toggle is doing. It gets a pid file of its OWN
# rather than a third mode in the files above: an agent starting must not stomp
# a -dimu the user chose, and a click must not release a hold an agent still
# needs. The two caffeinates coexist; each is tracked and killed only by its
# own side.
CAFFEINE_AGENT_FILE="$CAFFEINE_STATE_DIR/caffeine.agent.pid"
# -idsu, per the ask: idle, display, disk, and wake the screen if it is already
# off. Strictly stronger than either manual mode, which is why it wins the
# colour below.
CAFFEINE_AGENT_ARGS="-idsu"

# Who is working, per the flock sb-helper already polls every 10s and publishes.
# NOT `herdr agent list` again: that fork was the most expensive item on the bar
# and the helper exists to have paid for it once.
CAFFEINE_HELPER_STATE="$SB_CACHE_DIR/helper-state.json"
CAFFEINE_HELPER_MAX_AGE=40   # four of the helper's 10s flock ticks, plus slack

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

# Print the PID of a live caffeinate of ours, or return 1. Takes the state file
# to read, defaulting to the manual one, so the agent hold reuses the liveness
# rule rather than a second copy of it. A PID file alone proves
# nothing: PIDs are recycled, so the process must be alive AND still be a
# caffeinate. Anything else is stale and reads as "off".
caffeine_pid() {
  local pid comm file="${1:-$CAFFEINE_STATE_FILE}"
  [ -r "$file" ] || return 1
  pid="$(cat "$file" 2>/dev/null | tr -d '[:space:]')"
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

# True while at least one agent is working. Stale or missing state reads as
# none: a helper that died must not pin the machine awake for as long as its
# last file survives, and `missing herdr key` is the normal reading when herdr
# is not running at all.
caffeine_agents_working() {
  local n
  n="$(jq -er --argjson max "$CAFFEINE_HELPER_MAX_AGE" --argjson now "$(date +%s)" \
       'if ($now - (.at // 0)) < $max then (.herdr.working // 0) else 0 end' \
       "$CAFFEINE_HELPER_STATE" 2>/dev/null)" || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -gt 0 ]
}

# Is the automatic hold up? caffeine_pid's rule, plus one fallback: if ps(1)
# itself is unusable (sandbox, no proc list) it cannot tell "dead" from
# "unverifiable", and on THIS file the two must not read the same. Sync runs
# unattended every tick, so reading an unverifiable pid as dead would spawn a
# caffeinate per tick forever, each orphaned by the next overwrite of the file.
# The ps -p $$ probe is what keeps that fallback from swallowing the recycled-
# pid case it would otherwise mask: a working ps means caffeine_pid's "no" is
# the truth, and a stale file after a reboot is still cleaned up.
caffeine_agent_up() {
  local pid
  caffeine_pid "$CAFFEINE_AGENT_FILE" >/dev/null && return 0
  ps -p $$ -o comm= >/dev/null 2>&1 && return 1
  pid="$(cat "$CAFFEINE_AGENT_FILE" 2>/dev/null | tr -d '[:space:]')"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

# Make the automatic hold match the flock. Idempotent - it runs on every tick
# and on every herdr_flock event, and does nothing when the two already agree -
# which is also what reaps a hold left behind by a crash or a reload.
caffeine_agent_sync() {
  local pid
  if caffeine_agents_working; then
    caffeine_agent_up && return 0
    # nohup + disown for the same reason as the click handler: sketchybar reaps
    # the plugin, and a plain background job takes the SIGHUP with it.
    # shellcheck disable=SC2086  # our own literal, deliberately word-split
    nohup caffeinate $CAFFEINE_AGENT_ARGS >/dev/null 2>&1 &
    pid=$!
    disown "$pid" 2>/dev/null || true
    kill -0 "$pid" 2>/dev/null && printf '%s\n' "$pid" > "$CAFFEINE_AGENT_FILE"
  elif pid="$(caffeine_pid "$CAFFEINE_AGENT_FILE")"; then
    kill "$pid" 2>/dev/null
    rm -f "$CAFFEINE_AGENT_FILE"
  fi
  return 0
}

caffeine_render() {
  local colour=""
  # Agent hold first: -idsu holds strictly more than either manual mode, and
  # blue is the colour herdr already paints a working agent, so the mug reads
  # "something else is holding this, your click will not release it".
  if caffeine_agent_up; then
    colour="$BLUE"
  else
    rm -f "$CAFFEINE_AGENT_FILE"
  fi
  if caffeine_pid >/dev/null; then
    if [ -z "$colour" ]; then
      case "$(caffeine_mode)" in
        dimu) colour="$RED" ;;
        *)    colour="$GREEN" ;;
      esac
    fi
  else
    # Stale or bogus state file (killed externally, PID recycled): forget it,
    # so the next click starts fresh instead of trying to kill a stranger.
    # The mode goes with it - a mode left behind would colour the next cycle's
    # first state red.
    rm -f "$CAFFEINE_STATE_FILE" "$CAFFEINE_MODE_FILE"
  fi
  sketchybar --set "$CAFFEINE_ITEM" icon="$CAFFEINE_ICON" icon.color="${colour:-$FG_DIM}"
}

if [ -z "${CAFFEINE_LIB:-}" ]; then
  # set -u here rather than at the top, unlike every other executed plugin:
  # this file doubles as a sourced library (caffeine_click.sh), and forcing it
  # on a caller that did not ask for it is exactly what a sourced file must not
  # do. The definitions above are set-u-clean either way.
  set -u
  # No card_dispatch: the click is a direct toggle now, so this item owns no
  # popup to close and is not in $CARD_ITEMS. All this tick does is reconcile
  # the automatic hold, re-validate the PIDs and repaint - which is what catches
  # a caffeinate killed from outside, and what makes the agent hold survive a
  # missed herdr_flock event.
  caffeine_agent_sync
  caffeine_render
fi
