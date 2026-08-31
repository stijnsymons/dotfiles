#!/usr/bin/env bash

source "$CONFIG_DIR/plugins/app_icon.sh"

[ "$SENDER" = "front_app_switched" ] || exit 0

sketchybar --set "$NAME" icon="$(app_icon "$INFO")" label="$INFO"
