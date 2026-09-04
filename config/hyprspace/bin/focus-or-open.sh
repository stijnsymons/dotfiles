#!/bin/sh
# Focus an app's existing window, and only launch it when there is none.
#
# hyprspace's own new-window-or-open asks a RUNNING app for ANOTHER window, so
# for a single-document app like Obsidian it produced a duplicate of the vault
# already on screen instead of jumping to it. There is no native "focus this
# app" command - `focus` takes a direction or a window id - so the id has to be
# looked up first, and the launch is only the fallback.
#
# Bound from config.toml via exec-and-forget, which inherits the login PATH
# (`hyprspace list-exec-env-vars`), so `hyprspace` and `open` resolve without
# absolute paths here.
#
# Usage: focus-or-open.sh <bundle-id>
set -u

BUNDLE="$1"

# Two passes, because an app with several windows still has to resolve to one
# and hyprspace documents no ordering - head -1 is "whichever it lists first",
# not "the most recent". Asking the focused workspace first makes that choice
# non-arbitrary for a multi-window app like Ghostty: the terminal in front of
# you wins over one parked on another workspace, so alt-t does not yank you
# somewhere else when there is already a window right here.
ID="$(hyprspace list-windows --workspace focused --app-bundle-id "$BUNDLE" \
        --format '%{window-id}' 2>/dev/null | head -1)"

# Nothing here, so widen to every workspace - jumping to a window you cannot
# see is most of the point, and `focus` switches workspace to reach it.
# --monitor all rather than the --all alias: --all refuses to be combined with
# any filter ("--all conflicts with 'filtering' flags").
[ -n "$ID" ] || ID="$(hyprspace list-windows --monitor all --app-bundle-id "$BUNDLE" \
        --format '%{window-id}' 2>/dev/null | head -1)"

if [ -n "$ID" ]; then
  exec hyprspace focus --window-id "$ID"
fi

# Nothing listed means the app is not running, or is running with every window
# minimised - hyprspace does not track minimised windows, so the two look
# identical from here. `open -b` covers both: it launches a cold app and
# activates (un-minimising) a running one, and never opens a second window.
exec open -b "$BUNDLE"
