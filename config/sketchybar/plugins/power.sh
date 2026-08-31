#!/usr/bin/env bash
# Apple-style menu popup. Invoked as: power.sh <action>
#
# Two actions need Accessibility permission for sketchybar, because macOS has no
# scriptable equivalent and both are keystroke-driven:
#   lock  - Ctrl+Cmd+Q. CGSession was removed in macOS 15, and this Mac's
#           screenLock delay is 3600s, so the screensaver would blank the
#           display without actually locking it.
#   force - Cmd+Opt+Esc, the Force Quit dialog.

close() { sketchybar --set power popup.drawing=off; }

case "$1" in
  toggle)   sketchybar --set power popup.drawing=toggle ;;
  close)    close ;;

  about)    close; open "x-apple.systempreferences:com.apple.SystemProfiler.AboutExtension" ;;
  settings) close; open -a "System Settings" ;;
  appstore) close; open -a "App Store" ;;
  force)    close; osascript -e 'tell application "System Events" to key code 53 using {command down, option down}' ;;

  lock)     close; osascript -e 'tell application "System Events" to keystroke "q" using {control down, command down}' ;;
  sleep)    close; pmset sleepnow ;;
  logout)   close; osascript -e 'tell application "System Events" to log out' ;;
  restart)  close; osascript -e 'tell application "System Events" to restart' ;;
  shutdown) close; osascript -e 'tell application "System Events" to shut down' ;;
esac
