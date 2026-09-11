#!/usr/bin/env bash
# Re-fit the bar to the current PRIMARY display.
#
# sketchybarrc reads bin/screen-metrics ONCE at load and bakes all four numbers
# into the layout: the bar height, the notch bounds fit.sh ellipsises against,
# and the screen width the fixed item widths were measured for. Any of them can
# change under a running bar - a resolution change, or the primary display
# moving to another screen - and nothing recomputes them.
#
# WHY THIS IS A FULL RELOAD AND NOT `--bar height=`. It used to be the latter,
# on the theory that only the reserved inset moves with resolution. That was
# never true - NOTCH_L/NOTCH_R and SCREEN_W move with it too - and it broke
# outright when the primary display moved to the external:
#
#   built-in primary   32 771 956 1728    notched, menu bar reserves 32pt
#   DELL primary        0   0   0 2560    no notch, and see below
#
# The bar kept height=32 and went on dodging a notch at x=771..956 that does not
# exist on a 2560pt-wide screen. Only re-running sketchybarrc fixes that, because
# only sketchybarrc reads those three into the item definitions.
#
# THE ZERO. safeAreaInsets.top is 0 on a display with no notch, so screen-metrics
# falls back to frame.maxY - visibleFrame.maxY - what macOS reserves for the menu
# bar. With "Automatically hide and show the menu bar" ON macOS reserves NOTHING,
# so an external primary reports a literal
# 0 and the old `[ "$TOP" -gt 0 ]` guard skipped the re-fit entirely, leaving the
# previous display's height. 0 is a VALID reading here, not a failure: it means
# "macOS reserves nothing, pick your own height", and sketchybarrc's `[ -gt 0 ]
# || BAR_HEIGHT=38` fallback is what picks it. So this must reload ON zero, which
# is the opposite of what it used to do. What protects the bar from tiled windows
# is omniwm's gaps.outer.top (47pt = 38 + the 9pt gap), not the macOS inset.
set -u

# SB_CACHE_DIR and the launchd PATH repair both live here, same as every other
# plugin. Without it this script referenced $SB_CACHE_DIR unset and `set -u`
# killed it on the STATE line - so the re-fit did not merely mis-handle a
# display change, it never ran at all. The symptom was the bar coming back at
# the wrong height after every unplug/replug with nothing in any log.
source "$CONFIG_DIR/colors.sh"

METRICS="$CONFIG_DIR/bin/screen-metrics"
[ -x "$METRICS" ] || exit 0

LINE="$("$METRICS" 2>/dev/null)"
read -r TOP _NL _NR W <<<"$LINE"

# Reject only a MALFORMED reading, never a zero one. A non-numeric or empty
# field means the probe failed, and reloading on that would rebuild the bar from
# garbage; 0 is a real answer and is handled above.
case "${TOP:-}" in ''|*[!0-9]*) exit 0 ;; esac
case "${W:-}"   in ''|*[!0-9]*) exit 0 ;; esac
[ "$W" -gt 0 ] || exit 0

# ---- A zero inset during a replug is a LIE, and caching it is the bug --------
#
# Measured, unplugging and replugging the external screen: macOS reports the
# display back at full width BEFORE it has put the menu bar on it, so the probe
# catches a moment where the inset is 0. That 0 used to be cached below and
# reloaded on, sketchybarrc's `-gt 0` guard turned it into the 38pt fallback,
# and the bar then sat 8pt over a 30pt menu bar until the next reboot - because
# once the display settles macOS fires NO further display_change to correct it.
#
# A 0 is only ever legitimate when the menu bar is set to auto-hide, and that is
# a setting this can read rather than guess at. With the menu bar set to always
# show, a 0 is a reading taken too early: re-probe a few times, and if it stays
# 0, leave the cache untouched and do nothing. Doing nothing keeps the last good
# state and lets the next event try again; caching it is what made it permanent.
AUTOHIDE="$(defaults read NSGlobalDomain _HIHideMenuBar 2>/dev/null)"
[ -n "${AUTOHIDE:-}" ] || AUTOHIDE=0

if [ "$TOP" -eq 0 ] && [ "$AUTOHIDE" != "1" ]; then
  TRIES=0
  while [ "$TRIES" -lt 3 ]; do
    sleep 1
    TRIES=$(( TRIES + 1 ))
    RETRY="$("$METRICS" 2>/dev/null)"
    read -r RTOP _RNL _RNR RW <<<"$RETRY"
    case "${RTOP:-}" in ''|*[!0-9]*) continue ;; esac
    case "${RW:-}"   in ''|*[!0-9]*) continue ;; esac
    if [ "$RTOP" -gt 0 ]; then LINE="$RETRY"; TOP="$RTOP"; W="$RW"; break; fi
  done
fi
[ "$TOP" -eq 0 ] && [ "$AUTOHIDE" != "1" ] && exit 0

# ---- The metrics line alone is not proof the bar is right --------------------
#
# If none of the four numbers moved, nothing sketchybarrc baked in has changed.
# display_change fires on far more than a real change (wake, clamshell, a second
# monitor being redetected), so that common case must stay free.
#
# But an unchanged line does NOT mean the bar is wearing the right height - a
# bad reading latched earlier leaves the two disagreeing forever, which is
# exactly the failure above. So when the inset is a REAL number, also assert the
# bar actually matches it. TOP is compared, never a second copy of sketchybarrc's
# fallback constant: where TOP is 0 sketchybarrc picks a height of its own and
# nothing here could predict it. sed, not jq, to keep this script dependency-free.
STATE="$SB_CACHE_DIR/display-metrics"
REFIT="$SB_CACHE_DIR/display-refit"
CACHED="$(cat "$STATE" 2>/dev/null)"
CHANGED=0
[ "$LINE" = "$CACHED" ] || CHANGED=1

LIVE="$(sketchybar --query bar 2>/dev/null \
        | sed -n 's/.*"height"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
MISFIT=0
[ "$TOP" -gt 0 ] && [ -n "$LIVE" ] && [ "$LIVE" != "$TOP" ] && MISFIT=1

[ "$CHANGED" = 0 ] && [ "$MISFIT" = 0 ] && exit 0

mkdir -p "$SB_CACHE_DIR"

if [ "$CHANGED" = 1 ]; then
  printf '%s' "$LINE" > "$STATE"
  rm -f "$REFIT"          # new display situation: allow a refit again
else
  # Reloading to fix a misfit must not become a loop - this runs on every wake,
  # and the bar may be unable to reach TOP for a reason not visible from here.
  # Remember the exact situation reloaded for and refuse to repeat it verbatim.
  SIG="$LINE|$TOP|$LIVE"
  [ "$SIG" = "$(cat "$REFIT" 2>/dev/null)" ] && exit 0
  printf '%s' "$SIG" > "$REFIT"
fi

exec sketchybar --reload
