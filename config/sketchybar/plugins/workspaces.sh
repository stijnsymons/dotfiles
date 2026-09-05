#!/usr/bin/env bash
# The workspace pips: one digit per workspace in $SPACE_IDS, the current one on
# a pill.
#
# One script paints the whole cluster in a single sketchybar call. The digits
# only ever change together - a switch repaints the one you left and the one you
# arrived at - so one item per pip carrying its own script would be five forks
# and six round trips for what is one query and one paint. Same reasoning as the
# herdr cluster.
#
# All of them are always drawn, even empty ones, so the cluster is a fixed-width
# anchor: everything to its right would otherwise shuffle sideways every time a
# workspace gained or lost its last window. Occupancy is carried in the colour.
#
# omniwm is the only window manager. There used to be a $SB_WM switch here and a
# second hyprspace backend behind the same three functions; both are gone.
set -u

source "$CONFIG_DIR/colors.sh"

##### omniwm #####
# One call answers both questions here: occupancy is a FIELD on the workspace
# query rather than a separate invocation, so focus and counts come back
# together and cannot disagree with each other.
#
# is-current, NOT is-focused. isFocused tracks the workspace holding the FOCUSED
# WINDOW, so on a workspace with nothing open there is no focused window and
# EVERY workspace answers false. The dispatch below reads that empty answer as
# "the window manager is not up" and hides the whole cluster - so the pips
# vanished on exactly the workspace you most need them to say where you are.
# isCurrent is the workspace you are on and stays true with no windows at all.
# isFocused is kept behind it as a fallback in case the field is ever dropped.
#
# Parsed with a recursive descent over the response rather than a fixed path:
# omniwmctl wraps results in an envelope ({ok, status, result, ...}) and the
# nesting is not part of the documented contract, but "an object that has a
# number field" is unambiguous for this query. `..|objects` also tolerates the
# result being an array or a keyed object.
#
# window-counts selects a payload field named `counts`. Measured against 0.6.5 it
# is an OBJECT - {floating, scratchpad, tiled, total} - so `.total` is the field
# to read. Summing the object's numbers instead double-counts, because `total`
# is itself the sum of the others; that still answers "> 0" correctly, which is
# all the pips ask, but it is the wrong number to hand anything else. The scalar
# and sum branches remain as fallbacks in case the shape changes.
omni_rows() {
  omniwmctl query workspaces --fields number,is-current,is-focused,window-counts --format json 2>/dev/null \
    | jq -r '[..|objects|select(has("number"))] | .[]
             | "\(.number)\t\(.isCurrent // .is_current // .isFocused // .is_focused // false)\t\(
                 if   (.counts|type) == "object" then (.counts.total // ([.counts[]?|numbers] | add) // 0)
                 elif (.counts|type) == "number" then .counts
                 else 0 end)"' 2>/dev/null
}
wm_focused()  { omni_rows | awk -F'\t' '$2=="true"{print $1; exit}'; }
wm_occupied() { omni_rows | awk -F'\t' '$3+0 > 0 {print $1}'; }
wm_focus()    { omniwmctl command switch-workspace "$1" >/dev/null 2>&1; }

# Click. sketchybarrc passes the id, and this is the same command omniwm's own
# Option+<id> binding runs, so a click and the keystroke cannot end up meaning
# different things.
if [ "${1:-}" = "focus" ]; then
  wm_focus "${2:-}"
  exit 0
fi

# Read-only probes, for check.sh. The suite asks through this script rather than
# running the queries itself, so an assertion cannot pass against a query the
# bar is not actually making.
case "${1:-}" in
  --print-focused)  wm_focused; exit 0 ;;
  --print-occupied) wm_occupied; exit 0 ;;
esac

# $FOCUSED_WORKSPACE is set by senders that already know the answer, and omniwm's
# watcher is not one of them - it carries the event on stdin instead - so in
# practice this almost always falls through to the query. It is kept because a
# manual `sketchybar --trigger wm_workspace_change FOCUSED_WORKSPACE=n` is the
# cheapest way to repaint the cluster, and check.sh uses it.
FOCUSED="${FOCUSED_WORKSPACE:-}"
[ -n "$FOCUSED" ] || FOCUSED="$(wm_focused)"

# No answer means the window manager is not up, or - for omniwm - that IPC is
# still disabled, which looks identical from here. Pips that cannot say which
# one you are on are worse than no pips, so the cluster and its rule go away
# together and come back on the next event. Same treatment sep.timing gets from
# meeting.sh: a hidden item never leaves a dangling rule.
if [ -z "$FOCUSED" ]; then
  args=(--set sep.spaces drawing=off)
  for sid in $SPACE_IDS; do args+=(--set "space.$sid" drawing=off); done
  sketchybar "${args[@]}"
  exit 0
fi

# Padded at both ends so the case below matches a whole id, not a digit inside one.
OCCUPIED=" $(wm_occupied | tr '\n' ' ')"

# Three states, and the pill carries the important one: current reads at a
# glance without comparing two shades of blue. Cyan to match the colour omniwm
# draws the active window border in ([borders.color] in its settings.toml), so
# the bar and the frame around the window agree.
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
