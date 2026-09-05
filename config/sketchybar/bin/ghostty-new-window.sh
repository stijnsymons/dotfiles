#!/bin/sh
# Open a NEW Ghostty WINDOW in the Ghostty that is already running.
#
#   ghostty-new-window.sh
#
# Bound from KARABINER (alt-enter), next to the alt-t focus binding in
# focus-or-open.sh, for the same two reasons spelled out there: it survives a
# wmswitch, and Karabiner rewrites the event at the HID layer so no app can
# take the chord first.
#
# alt-enter was free only because toggleFullscreen was moved off it and onto
# alt-f in ~/.config/omniwm/settings.toml. Those two edits are a pair - putting
# this binding back without moving the OmniWM hotkey means Karabiner eats the
# chord and maximise silently stops working.
#
# THE INVOCATION. Three routes were considered and two are wrong:
#
#   open -na Ghostty          Spawns a SECOND Ghostty PROCESS, not a second
#                             window. Two instances do not share tabs, config
#                             reloads, or the quit prompt, and the window
#                             manager sees an unrelated app. This is the
#                             obvious command and it is the wrong one.
#
#   ghostty +new-window       Exists in `ghostty +help` on 1.3.1, which makes
#                             it look like the answer. It is Linux-only - the
#                             action needs the D-Bus single-instance channel
#                             that the macOS build does not have. Running it
#                             here prints "+new-window is not supported on
#                             this platform." and exits non-zero. Verified
#                             against the installed 1.3.1.
#
#   osascript ... new window  What is used below, and the only first-party
#                             route on macOS. Ghostty ships a real scripting
#                             dictionary (Info.plist: NSAppleScriptEnabled=true,
#                             OSAScriptingDefinition=Ghostty.sdef) and that
#                             dictionary declares `new window` as a command of
#                             the application class, handled by
#                             handleNewWindowScriptCommand:. An Apple Event is
#                             addressed to the RUNNING process, so it lands in
#                             the existing instance by construction - which is
#                             exactly the property `open -na` throws away.
#
# `tell application "Ghostty"` also auto-launches a cold Ghostty before
# delivering the event, so the not-running case needs no separate branch.
#
# FIRST RUN WILL PROMPT. Apple Events are gated by TCC per sending process, and
# the sender here is karabiner_console_user_server, not a terminal. Expect one
# "Karabiner-Elements wants to control Ghostty" dialog the first time alt-enter
# is pressed; until it is approved the osascript exits 1 with error -1743 and
# the key appears dead. It is a one-time grant under
# System Settings > Privacy & Security > Automation.
set -u

# Karabiner runs shell_command through a bare /bin/sh with a minimal PATH. This
# only needs /usr/bin/osascript, which is on any sane PATH, but it is pinned
# for the same reason focus-or-open.sh pins its own: a PATH miss fails silently
# and looks identical to "the key is not bound".
PATH="/usr/bin:/bin"
export PATH

exec osascript -e 'tell application "Ghostty" to new window'
