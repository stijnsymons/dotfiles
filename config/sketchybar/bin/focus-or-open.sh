#!/bin/sh
# Focus an app's existing window, and only launch it when there is none.
#
#   focus-or-open.sh <bundle-id>
#
# Bound from KARABINER (alt-t/b/o/s/m), not from the window manager's own
# config, because Karabiner wins the key. macOS global hotkeys are exclusive and
# first-come-first-served, which is how Wispr Flow took alt-m for its meeting
# recorder and left the window manager's registration failing SILENTLY - the key
# looked bound and only ever started a notetaker. Karabiner rewrites the event at
# the HID layer, before any app is offered the combination, so alt-m reaches this
# script and Wispr Flow never sees it.
set -u

# Karabiner runs shell_command through a bare /bin/sh with a minimal PATH -
# omniwmctl and jq are both in /opt/homebrew/bin and neither would resolve. An
# empty PATH lookup here fails the same way "app not running" does (silently,
# then `open`), so it is spelled out rather than inherited.
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

BUNDLE="${1:-}"
[ -n "$BUNDLE" ] || { printf 'usage: focus-or-open.sh <bundle-id>\n' >&2; exit 2; }

# Resolve through symlinks before deriving CONFIG_DIR: this is reached by
# absolute path from Karabiner today, but ~/.config/sketchybar is itself a
# symlink into the dotfiles repo, so a plain dirname would land in the wrong
# tree the moment it is called through one.
SELF="$0"
while [ -L "$SELF" ]; do
  _target="$(readlink "$SELF")"
  case "$_target" in
    /*) SELF="$_target" ;;
    *)  SELF="$(dirname "$SELF")/$_target" ;;
  esac
done
CONFIG_DIR="${CONFIG_DIR:-$(cd "$(dirname "$SELF")/.." && pwd)}"
. "$CONFIG_DIR/colors.sh"

##### omniwm #####
# Two passes, because an app with several windows still has to resolve to one
# and head -1 is "whichever it lists first", not "the most recent". Asking the
# VISIBLE window first makes that choice non-arbitrary for a multi-window app
# like Ghostty: the terminal in front of you wins over one parked on another
# workspace, so alt-t does not yank you somewhere else when there is already a
# window right here.
#
# `omniwmctl window focus` switches workspace to reach a window that is not
# visible (verified against 0.6.5 - `window navigate` behaves identically here),
# so the second pass really does jump, it does not silently no-op.
#
# select(has("id") and has("app")) rather than a fixed path: omniwmctl wraps
# every reply in an envelope that ALSO carries an "id" - the request UUID - so
# a bare has("id") over `..|objects` would happily hand back the envelope's.
# Requiring "app" alongside it picks out a window and nothing else, which is
# why `app` is in --fields even though only the id is used.
omni_id() { # omni_id [selector]
  omniwmctl query windows --bundle-id "$BUNDLE" ${1:+"$1"} --fields id,app --format json 2>/dev/null \
    | jq -r '[..|objects|select(has("id") and has("app"))] | .[0].id // empty' 2>/dev/null
}

focus_window() {
  ID="$(omni_id --visible)"
  [ -n "$ID" ] || ID="$(omni_id)"
  [ -n "$ID" ] || return 1
  omniwmctl window focus "$ID" >/dev/null 2>&1
}

# Falling through is not an error: omniwm being down still has a correct answer
# below - `open -b` - and a key that launches the app beats a key that does
# nothing at all.
focus_window && exit 0

# Nothing listed means the app is not running, or is running with every window
# minimised - omniwm does not track minimised windows, so the two look identical
# from here. `open -b` covers both: it launches a cold app and activates
# (un-minimising) a running one, and never opens a second window.
exec open -b "$BUNDLE"
