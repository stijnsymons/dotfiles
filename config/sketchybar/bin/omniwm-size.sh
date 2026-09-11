#!/bin/sh
# Layout-aware size step for omniwm.
#
#   omniwm-size.sh <increase|decrease>
#
# Bound from KARABINER (alt-minus/alt-equal) rather than from omniwm's own
# config, because omniwm's hotkey table is one command per key with no
# conditional - and its sizing commands are LAYOUT-SCOPED. `query commands`
# reports set-container-primary-span as layoutCompatibility "niri", so on a
# dwindle workspace alt-minus/alt-equal reached a command that does not apply
# there and silently did nothing. cycle-size is shared and does apply, so this
# asks which layout the current workspace runs and dispatches accordingly:
#
#   niri     -/+ 10% of the container primary span (the previous behaviour)
#   dwindle  cycle-size backward/forward (identical to alt-comma/alt-period)
#
# The dwindle half is deliberately the same action as alt-comma/alt-period.
# omniwm's incremental dwindle equivalent is `resize horizontal grow|shrink`,
# which would be the swap to make if stepped resizing is wanted there instead.
set -u

# Karabiner runs shell_command through a bare /bin/sh with a minimal PATH -
# omniwmctl and jq are both in /opt/homebrew/bin and neither would resolve.
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

case "${1:-}" in
  increase) SPAN='+10%' ; CYCLE=forward  ;;
  decrease) SPAN='-10%' ; CYCLE=backward ;;
  *) printf 'usage: omniwm-size.sh <increase|decrease>\n' >&2; exit 2 ;;
esac

# select(has("layout")) rather than a fixed path: omniwmctl wraps every reply in
# an envelope, so walking to the one object that actually carries the field is
# steadier than indexing through result.payload.workspaces[0].
layout="$(omniwmctl query workspaces --current --fields layout --format json 2>/dev/null \
  | jq -r '[..|objects|select(has("layout"))] | .[0].layout // empty' 2>/dev/null)"

# An unreadable layout (omniwm down, IPC off) falls to the niri branch, which is
# what the key did before this script existed - no worse than the status quo.
case "$layout" in
  dwindle) exec omniwmctl command cycle-size "$CYCLE" ;;
  *)       exec omniwmctl command set-container-primary-span "$SPAN" ;;
esac
