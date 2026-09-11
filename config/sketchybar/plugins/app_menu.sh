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
# THIS WAS omniwm's `open-menu-anywhere` and is not any more. That version was
# chosen because the bar and the keyboard (Control+Option+M, id
# openMenuAnywhere) then reached ONE implementation that could not drift, and
# because omniwm already holds the Accessibility grant this job needs, so it
# added no new TCC surface. Both arguments still hold. They are simply worth
# less than the assumption underneath them: that omniwm is RUNNING. It is not -
# it was turned off as too intrusive - and a click routed through a stopped
# window manager is a dead click that reports its failure only by turning an
# icon red.
#
# What runs now is aizigao/sketchybar_apple_memu_via_swift, vendored under
# bin/app-menu/ (see ORIGIN.md). It is the alternative that was evaluated and
# REJECTED first time round, and it was never rejected on capability - it does
# the same job by the same route, walking the frontmost app's AXMenuBar and
# AXPressing the row you pick. It was rejected on what it costs to own, and
# taking it now means paying exactly those costs, knowingly:
#
#   - a SECOND Accessibility grant, for a second app that can read every
#     running application's menu tree. This no longer duplicates omniwm's
#     grant, since omniwm is off - it REPLACES it. Granted by hand once, in
#     System Settings > Privacy & Security > Accessibility.
#   - ~520 lines of vendored third-party Swift, plus the build.sh stanza the
#     generic bin/*.swift loop cannot cover, because this is an .app bundle
#     with an Info.plist and a signature whose identifier must stay stable.
#   - a second long-lived background process, launched through `open -g`.
#
# What is BOUGHT, beyond independence from omniwm: theming. omniwm drew a
# native NSMenu that ignored colors.sh; this helper takes the popup palette as
# arguments, so the app menu finally matches every other popup on this bar.
#
# It also makes the old one-menu-at-a-time guard unnecessary. omniwmctl BLOCKED
# when invoked a second time while a menu was tracking - it sat inside NSMenu's
# nested modal run loop until the menu went away, and a leaning-on-the-item user
# accumulated one stuck process per extra click. This helper is a single
# reusable background app: a second launch is delivered to the running instance
# as a reopen, which TOGGLES the panel shut. Clicking twice closes the menu,
# which is what a click on an open menu should do anyway.
set -u

# Defaulted so --print works when this is run by hand. sketchybar always exports
# CONFIG_DIR, and check.sh sets it too, but a bare shell does not - and with
# `set -u` the seam then dies on an unbound variable instead of printing.
CONFIG_DIR="${CONFIG_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

# Sourced for the popup palette AND for the launchd PATH repair: sketchybar is
# started from a login-less context where /opt/homebrew/bin is not on PATH.
source "$CONFIG_DIR/colors.sh"

APP="$CONFIG_DIR/bin/app-menu/SketchyBarAppleMenu.app"

# Test seam, same shape as meeting_click.sh's --print: name the target instead
# of launching it. check.sh must be able to assert this handler without a menu
# panel appearing over the suite and swallowing the rest of the run. It prints
# the BUNDLE PATH rather than a command line, because the bundle is what the
# suite can then verify the identity of - see the codesign assertions there.
if [ "${1:-}" = "--print" ]; then
  printf '%s\n' "$APP"
  exit 0
fi

# $NAME is the item sketchybar dispatched the click from, so this repaints
# whatever it is hung off without the name being written down twice. The
# fallback only matters when the script is run by hand. It is also passed to
# the helper as --item-name, which is what the panel anchors itself under: get
# it wrong and the menu opens in the corner instead of below the app name.
ITEM="${NAME:-front_app}"

# The bar keeps painting fine with no bundle on disk, so the failure to catch
# here is "build.sh never produced it" - a missing directory, not a bad exit
# code from `open`.
if [ ! -d "$APP" ]; then
  printf 'sketchybar: app menu not built: %s missing\n' "$APP" >&2
  sketchybar --set "$ITEM" icon.color="$RED"
  exit 1
fi

# --sketchybar-path is passed EXPLICITLY rather than left to the helper's
# auto-detection, for the same launchd PATH reason above: the helper shells out
# to sketchybar to find the item's bounding box, and a lookup that fails does
# not error - it just returns no frame, and the panel opens somewhere arbitrary.
#
# The colours are the same ones the hover cards use, so the app menu matches
# them. Note these are read only at LAUNCH: the helper stays resident, so a
# palette change needs the running instance killed before it repaints.
SB_BIN="$(command -v sketchybar || echo /opt/homebrew/bin/sketchybar)"

# open -g: launch without stealing focus, which matters because the helper reads
# whichever app is frontmost AT THAT MOMENT to decide whose menu to show. A
# foreground launch would make the helper itself frontmost and it would render
# its own (empty) menu. Second and later clicks are delivered to the resident
# instance as a reopen, which toggles the panel.
if open -g -a "$APP" --args \
        --item-name "$ITEM" \
        --sketchybar-path "$SB_BIN" \
        --background-color "$POPUP_BG" \
        --border-color "$SEPARATOR" \
        --foreground-color "$FG" 2>/dev/null; then
  sketchybar --set "$ITEM" icon.color="$PINK"
else
  # `open` failing is the launch itself being refused - a corrupt or unsignable
  # bundle, typically after a half-finished build. A DENIED Accessibility grant
  # does NOT land here: the helper launches fine and puts up its own alert
  # telling you where to grant it, which is the one failure this cannot report.
  printf 'sketchybar: app menu failed to launch: %s\n' "$APP" >&2
  sketchybar --set "$ITEM" icon.color="$RED"
fi
