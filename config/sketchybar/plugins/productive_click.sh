#!/usr/bin/env bash
# Click the Productive item -> the pinned Productive tab in Brave.
# Deliberately unconditional: when the item is red, the whole point is reaching
# the page that fixes it in one click; when it is green, the same page is where
# you stop the timer.
#
# Focuses the existing pinned tab rather than calling `open` on the URL, which
# would spawn a fresh window/tab every click. Same approach as meeting_click.sh
# (tab 2, pinned calendar). `active tab index` is Brave's term (Chromium
# dictionary), not `active tab`.

source "$CONFIG_DIR/colors.sh"

TAB=3
URL="https://app.productive.io/22184-november-five/time/me"

if osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Brave Browser"
  if (count of windows) is 0 then error "no windows"
  if (count of tabs of front window) is less than $TAB then error "no tab $TAB"
  activate
  set active tab index of front window to $TAB
end tell
APPLESCRIPT
then
  exit 0
fi

# Brave not running, or fewer than $TAB tabs: fall back rather than no-op.
open "$URL"
