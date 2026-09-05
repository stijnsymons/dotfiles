#!/usr/bin/env bash
# Click handler for the front_app item: drops the FRONTMOST APP'S menu bar
# under the pointer.
#
# It hung off a dedicated  item at the far left first, which was the wrong
# affordance twice over - the glyph promised an Apple menu and delivered the
# focused app's menus, and the item that already NAMES the focused app was
# sitting right next to it doing nothing on click. Clicking "Ghostty" to get
# Ghostty's menus needs no glyph to explain it.
#
# This is omniwm's own `open-menu-anywhere`, the same thing Control+Option+M is
# bound to in ~/.config/omniwm/settings.toml (id openMenuAnywhere). The bar and
# the keyboard therefore reach ONE implementation; the alternative below would
# have meant two menus for one job that could drift apart.
#
# aizigao/sketchybar_apple_memu_via_swift was evaluated as the alternative and
# REJECTED, and it was not on capability - it does the same thing by the same
# route (walk the frontmost app's AXMenuBar, render it, AXPress the row you
# pick) and it compiles clean. What killed it is what it costs to own:
#   - a SECOND Accessibility grant, for a second app that can read every
#     running application's menu tree. omniwm already holds that grant and
#     cannot tile a single window without it, so option B adds no new TCC
#     surface at all and option A adds a duplicate of the most invasive one.
#   - ~500 lines of vendored third-party Swift in this repo, plus a build.sh
#     stanza the generic bin/*.swift loop cannot cover: it is an .app bundle,
#     not a bare binary - Info.plist with LSUIElement, and an ad-hoc codesign
#     carrying a stable designated requirement, which is the only reason its
#     Accessibility grant survives a rebuild. Get that signing detail wrong and
#     the symptom is a menu that silently stops opening after every recompile.
#   - a second long-lived background process, launched through `open -g`.
# What is given up is theming: omniwm draws a native NSMenu, so this one does
# NOT take POPUP_BG/SEPARATOR/FG from colors.sh the way the hover cards do. For
# a menu that is arguably correct - it should look like the menu it is standing
# in for - but it is a real difference from every other popup on this bar.
set -u

# Sourced for the launchd PATH repair, not for a colour: sketchybar is started
# from a login-less context where /opt/homebrew/bin is not on PATH, so a bare
# `omniwmctl` here resolves to nothing and the click does nothing, silently.
source "$CONFIG_DIR/colors.sh"

# Test seam, same shape as meeting_click.sh's --print: name the command instead
# of running it. check.sh must be able to assert this handler without a modal
# NSMenu appearing over the suite and swallowing the rest of the run.
if [ "${1:-}" = "--print" ]; then
  printf 'omniwmctl command open-menu-anywhere\n'
  exit 0
fi

# One menu at a time, enforced here rather than left to omniwm.
#
# MEASURED, not assumed: `omniwmctl command open-menu-anywhere` normally returns
# in well under a second having fired the menu off asynchronously - but invoked
# a SECOND time while a menu is already tracking, it BLOCKS. It was left hung
# past 120s in testing and had to be killed. omniwm itself stays healthy (ping
# and query both answer through it), so this is the controller sitting inside
# NSMenu's nested modal run loop and not servicing the request until the menu
# goes away. sketchybar forks a fresh process per click, so without this guard a
# leaning-on-the-item user accumulates one stuck omniwmctl per extra click.
#
# In practice a real double click rarely gets here - a tracking NSMenu grabs the
# mouse, so the click that dismisses it is eaten by the menu and never reaches
# sketchybar - but "rarely" is not "never" and the failure leaves debris.
#
# ps, not pgrep, for the reason bin/wmswitch.sh records at length: pgrep depends
# on sysmond and has been seen failing outright on this machine, and it fails
# OPEN - it would report no menu open and let the second one stack up. The
# [o]mniwmctl bracket keeps this grep from matching its own pipeline.
if ps -Ao args= | grep -q '[o]mniwmctl command open-menu-anywhere'; then
  exit 0
fi

# --format json so the outcome is a field rather than a guess. Both failure
# modes answer in the same envelope: a dead socket (omniwm down, or IPC still
# switched off in its settings) comes back as ok:false / transport_failure with
# exit 2, and a command omniwm no longer knows as ok:false / invalid_arguments
# with exit 3. Only `ok: true` is success. stderr is folded into the capture so
# "omniwmctl is not on PATH at all" lands in the same branch with its reason
# intact instead of vanishing into an empty string.
OUT="$(omniwmctl command open-menu-anywhere --format json 2>&1)"

# The app icon carries the outcome of the LAST click, which is the only honest
# thing a click handler can report: there is no tick to repaint on, so a red
# icon means "the last time you asked, the menu surface was unreachable" and it
# clears on the next click that works. Silence was the alternative and it is the
# failure this bar keeps rejecting - a click that does nothing and says nothing.
#
# $NAME is the item sketchybar dispatched the click from, so this repaints
# whatever it is hung off without the name being written down twice. The
# fallback only matters when the script is run by hand.
#
# $PINK, not $FG, is the healthy colour: it is what sketchybarrc paints
# front_app's icon and what this has to restore to. front_app.sh sets icon and
# label on every app switch but never touches icon.color, so a red left here
# would survive every switch until the next successful click - which is the
# point, but it does mean this and sketchybarrc have to agree on the colour.
ITEM="${NAME:-front_app}"
if printf '%s' "$OUT" | jq -e '.ok == true' >/dev/null 2>&1; then
  sketchybar --set "$ITEM" icon.color="$PINK"
else
  printf 'sketchybar: app menu unreachable: %s\n' "${OUT:-omniwmctl not found on PATH}" >&2
  sketchybar --set "$ITEM" icon.color="$RED"
fi
