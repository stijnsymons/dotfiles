#!/usr/bin/env bash
# Focus one of Brave's pinned tabs, optionally pointing it at a URL first.
#
#   brave_tab.sh <index> [url]
#
# Navigating the pinned tab rather than opening a new one is the whole point:
# these are long-lived tabs (2 = calendar, 3 = Productive) and a click should
# land in them, not accumulate duplicates. Falls back to `open` only when Brave
# is not running or the tab does not exist, so a click is never a no-op.
set -u

TAB="${1:?brave_tab.sh needs a tab index}"
URL="${2:-}"

# Both go into AppleScript source below, where a quote or a backslash would
# close out of the string literal and run as script. The index must be a
# number, and a URL carrying either is dropped rather than escaped: the click
# then just focuses the tab, which is the same thing passing no URL does.
case "$TAB" in ''|*[!0-9]*) exit 1 ;; esac
case "$URL" in *[\"\\]*) URL="" ;; esac

if [ -n "$URL" ]; then
  SET_URL="set URL of tab $TAB of front window to \"$URL\""
else
  SET_URL=""
fi

if osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Brave Browser"
  if (count of windows) is 0 then error "no windows"
  if (count of tabs of front window) is less than $TAB then error "no tab $TAB"
  activate
  $SET_URL
  set active tab index of front window to $TAB
end tell
APPLESCRIPT
then
  exit 0
fi

[ -n "$URL" ] && open "$URL"
exit 0
