#!/usr/bin/env bash
# The hyprspace workspace pips: one digit per workspace in $SPACE_IDS, the
# focused one on a pill.
#
# One script paints the whole cluster in a single sketchybar call rather than
# one script per pip. The four digits only ever change together - a switch
# repaints the one you left and the one you arrived at - so four items each
# carrying their own script would be four forks and five round trips for what
# is two queries and one paint. Same reasoning as the herdr cluster.
#
# All four are always drawn, even empty ones, so the cluster is a fixed-width
# anchor: everything to its right (front_app, meeting, productive) would
# otherwise shuffle sideways every time a workspace gained or lost its last
# window. Occupancy is carried in the colour instead.
set -u

source "$CONFIG_DIR/colors.sh"

# Click. sketchybarrc passes the id, and this is the same command that
# alt-<id> is bound to in ~/.config/hyprspace/config.toml, so a click and the
# keystroke cannot end up meaning different things.
if [ "${1:-}" = "focus" ]; then
  hyprspace workspace "${2:-}" >/dev/null 2>&1
  exit 0
fi

# hyprspace_workspace_change carries the newly focused id in its payload (see
# exec-on-workspace-change in config.toml), so the common case - you just
# switched - costs no query at all. Every other sender (a window opened, an app
# switch, waking) has to ask.
FOCUSED="${FOCUSED_WORKSPACE:-}"
[ -n "$FOCUSED" ] || FOCUSED="$(hyprspace list-workspaces --focused 2>/dev/null)"

# No answer means the hyprspace server is not up. It is start-at-login, so this
# is a crash or a restart rather than the normal state - and four pips that
# cannot say which one you are on are worse than no pips, so the cluster and
# its rule go away together and come back on the next event. Same treatment
# sep.timing gets from meeting.sh: a hidden item never leaves a dangling rule.
if [ -z "$FOCUSED" ]; then
  args=(--set sep.spaces drawing=off)
  for sid in $SPACE_IDS; do args+=(--set "space.$sid" drawing=off); done
  sketchybar "${args[@]}"
  exit 0
fi

# Occupancy needs its own call: --focused and --empty are separate forms of
# list-workspaces (see `hyprspace list-workspaces --help`), and there is no one
# invocation that answers both. Padded with spaces at both ends so the case
# below matches a whole id and not a digit inside one.
OCCUPIED=" $(hyprspace list-workspaces --monitor all --empty no 2>/dev/null | tr '\n' ' ')"

# Three states, and the pill is what carries the important one: focused reads
# at a glance without having to compare two shades of blue against each other.
# Cyan for it because that is the colour hyprspace draws the active window
# border in (borders active_color in config.toml), so the bar and the frame
# around the window agree.
args=(--set sep.spaces drawing=on)
for sid in $SPACE_IDS; do
  if [ "$sid" = "$FOCUSED" ]; then
    args+=(--set "space.$sid" drawing=on icon.color="$AQUA" background.drawing=on)
  else
    case "$OCCUPIED" in
      *" $sid "*) args+=(--set "space.$sid" drawing=on icon.color="$FG"     background.drawing=off) ;;
      *)          args+=(--set "space.$sid" drawing=on icon.color="$FG_DIM" background.drawing=off) ;;
    esac
  fi
done
sketchybar "${args[@]}"
