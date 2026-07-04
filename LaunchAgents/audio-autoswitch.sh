#!/bin/sh
# Auto-activate the "E30 II" DAC as the default audio output the moment it
# appears. Edge-triggered: it switches ONLY on the absent→present transition,
# so if you manually pick another output while the E30 II stays connected,
# your choice is respected until it's unplugged and reconnected.
#
# Driven by com.local.AudioAutoSwitch.plist (polls every few seconds).
# Verify the device name with: SwitchAudioSource -a -t output

SAS="$(command -v SwitchAudioSource || echo /opt/homebrew/bin/SwitchAudioSource)"
TARGET="E30 II"
STATE="/tmp/.audio-autoswitch.$(id -u)"   # /tmp is cleared at boot → fresh state

[ -x "$SAS" ] || exit 0

if "$SAS" -a -t output | grep -qx "$TARGET"; then
  if [ ! -f "$STATE" ]; then                                   # just connected
    [ "$("$SAS" -c -t output)" != "$TARGET" ] && "$SAS" -s "$TARGET" -t output
    : > "$STATE"
  fi
else
  rm -f "$STATE"                                               # gone; arm for next connect
fi
