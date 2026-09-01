#!/usr/bin/env bash
# Now playing via nowplaying-cli. Click toggles play/pause.
#
# nowplaying-cli costs ~115ms per invocation regardless of how many keys are
# asked for, so all three are fetched in one call. sketchybar --query is ~22ms,
# so the click path reads its current state from sketchybar and flips the icon
# before touching nowplaying-cli at all - the click feels instant.
#
# Glyphs are UTF-8 octal escapes so no encoding step can drop them:
# U+F04B play, U+F04C pause. (bash 3.2 printf has no \u.)

source "$CONFIG_DIR/colors.sh"
# Hover dispatch, before anything expensive: sketchybar invokes this same
# script for every subscribed event. Leaving the bar closes the card; any other
# event is a routine tick, which is also what polices a card left open by a
# missed mouse.exited.
card_dispatch media

PLAY="$(printf '\357\201\213')"
PAUSE="$(printf '\357\201\214')"

update() {
  RAW="$(nowplaying-cli get title artist playbackRate)"
  { IFS= read -r TITLE; IFS= read -r ARTIST; IFS= read -r RATE; } <<RAWEOF
$RAW
RAWEOF

  if [ -z "$TITLE" ] || [ "$TITLE" = "null" ]; then
    sketchybar --set media drawing=off
    return
  fi

  if [ "$RATE" = "1" ]; then
    ICON="$PLAY"; ICON_COLOR="$GREEN"
  else
    ICON="$PAUSE"; ICON_COLOR="$FG_DIM"
  fi

  LABEL="$TITLE"
  if [ -n "$ARTIST" ] && [ "$ARTIST" != "null" ]; then
    LABEL="$TITLE — $ARTIST"
  fi

  sketchybar --set media drawing=on icon="$ICON" icon.color="$ICON_COLOR" label="$LABEL"
}

toggle() {
  # Read the state we already have locally instead of asking nowplaying-cli.
  { IFS= read -r ICON_NOW; IFS= read -r LABEL_NOW; } <<QEOF
$(sketchybar --query media | jq -r '.icon.value, .label.value')
QEOF

  # No label means no active session. nowplaying-cli would fall through to
  # Music.app and launch it, so bail out instead.
  if [ -z "$LABEL_NOW" ]; then
    sketchybar --set media drawing=off
    return
  fi

  # Optimistic flip: instant feedback, reconciled by update() below and by the
  # media_change event if some other app changed the state underneath us.
  if [ "$ICON_NOW" = "$PLAY" ]; then
    sketchybar --set media icon="$PAUSE" icon.color="$FG_DIM"
  else
    sketchybar --set media icon="$PLAY" icon.color="$GREEN"
  fi

  nowplaying-cli togglePlayPause
  sleep 0.15
  update
}

case "$SENDER" in
  mouse.clicked) toggle ;;
  *)             update ;;
esac
