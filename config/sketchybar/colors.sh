#!/usr/bin/env bash
# Tokyo Night Storm palette. Sourced by sketchybarrc and every plugin.

# Backgrounds
export BAR_COLOR=0xff000000       # black
export ISLAND=0x0024283b          # unused in plain style (kept for plugins)
export ISLAND_BORDER=0x00000000
export POPUP_BG=0xff1f2335        # bg_dark
export SEPARATOR=0xff3b4261       # bg_highlight-ish, for divider glyphs

# Foregrounds
export FG=0xffc0caf5              # fg
export FG_DIM=0xff565f89          # comment

# Accents
export VIOLET=0xff9d7cd8          # purple
export BLUE=0xff7aa2f7            # blue
export AQUA=0xff7dcfff            # cyan
export GREEN=0xff9ece6a           # green
export YELLOW=0xffe0af68          # yellow
export ORANGE=0xffff9e64          # orange
export PINK=0xffbb9af7            # magenta
export RED=0xfff7768e             # red

# PATH. launchd starts sketchybar from a login-less context, so gws-now
# (~/bin), the Productive CLI (~/code/assistant/bin) and jq (the brew prefix)
# can all be unreachable and every plugin that shells out silently finds
# nothing. Repaired here, once, for everything that sources this file.
#
# Each directory is tested for on its own. The brew prefix was the sentinel for
# the whole repair - "a PATH that already has it came from a login shell" - but
# Homebrew's own launchd plist hands the bar
# /opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin, which
# satisfies the sentinel without ever having seen a login shell. The repair was
# then skipped whole, ~/code/assistant/bin stayed off PATH, `productive` was
# not found, and the timer item fell back to its cache and then to "--".
#
# Testing per directory is also what keeps this idempotent: productive.sh
# sources this file and then runs productive_plan.sh, which sources it again in
# a child, so an unconditional prepend would grow PATH on every nesting.
# Prepended in reverse so the listed order is the resulting precedence.
for _sb_dir in /usr/local/bin /opt/homebrew/bin "$HOME/code/assistant/bin" "$HOME/bin"; do
  case ":$PATH:" in
    *":$_sb_dir:"*) ;;
    *) PATH="$_sb_dir:$PATH" ;;
  esac
done
unset _sb_dir
export PATH

# Cache. Everything the bar keeps on disk lands here - calendar bodies, join
# links with their passcodes, timesheet rows - so it is ours alone rather than
# the world-readable 755 a plain mkdir leaves behind. This is the only place
# that spells ~/.cache/sketchybar out; everything else takes it from here and
# nothing else creates it. The chmod rides along with the mkdir rather than
# running every time: this file is sourced by every plugin on every tick, and
# an unconditional chmod is one more spawn a second for a mode that only ever
# changes when the directory is first created.
export SB_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar"
[ -d "$SB_CACHE_DIR" ] || { mkdir -p "$SB_CACHE_DIR" && chmod 700 "$SB_CACHE_DIR"; } 2>/dev/null

# Card rows are tab-separated and their fourth field is run by sh, so a literal
# tab in free text - a calendar invite, a track title, an SSID - would shift the
# rest of that text into the action field. Strip the separators at the source.
card_text() { printf '%s' "$1" | tr -d '\011\012\015'; }

# The items that own a hover card, and how many rows each one has room for.
# sketchybarrc pre-creates the rows, card.sh closes the others when one opens
# and check.sh asserts both - naming the set once is what stops those three
# from drifting apart.
export CARD_ITEMS="meeting productive media cpu wifi caffeine herdr clock"
export CARD_ROWS=8

# The events that stand in for the global click sketchybar does not have.
# mouse.exited.global only fires when the pointer LEAVES the bar, so clicking
# straight into another app, cmd-tabbing without touching the trackpad, or
# switching space all used to leave a popup hanging until the 45s watchdog.
# Each of these means the user is no longer looking at the card, so card.sh's
# `away` sweep closes every one. Named here so sketchybarrc's --subscribe and
# check.sh's assertion cannot drift.
#
# space_windows_change is deliberately absent: it fires whenever any app
# anywhere opens or closes a window, so a background notification would shut a
# card mid-read. It is not a click.
#
# A true global click monitor was researched and REJECTED, and permissions were
# NOT what killed it. Measured, not assumed: an unsigned throwaway binary with
# AXIsProcessTrusted()=false and CGPreflightListenEventAccess()=false got all
# three of three real clicks through NSEvent.addGlobalMonitorForEvents, with no
# TCC prompt and no grant. The same process saw zero keyDown events, which is
# what AppKit's own NSEvent.h documents - the accessibility gate is on
# "key-related events" only. Mouse is free; keyboard is not.
#
# What killed it is that the monitor cannot tell an outside click from a click
# ON the bar or the popup, and it must, or every row click and every toggle
# breaks. The same run caught a click at 24.8pt from the top of a 1117pt
# screen - inside the 32pt bar - and the monitor was handed it like any other.
# Rejecting those needs the bar's rect, which is fine, AND the popup's, which
# sketchybar does not expose: --query <item> gives .popup only its per-row
# height and item list, no origin and no size, so the rect would have to be
# rebuilt from the owner's bounding_rect, the align, the y_offset, the visible
# row count and the widest row - on the click hot path, and wrong the moment
# any of those changes. bin/sb-helper could not host it anyway: it is send-only
# by design and cannot read an item's rect back at all, and its main thread
# parks on dispatchMain(), which is not a CFRunLoop - the monitor's callbacks
# arrive on the main run loop, so it would also mean linking AppKit and
# restructuring the helper's main loop. A CGEventTap needs Accessibility
# outright, which is out of all proportion to dismissing a popup.
export CARD_AWAY_EVENTS="front_app_switched space_change display_change system_woke"

# Hover dispatch for a card owner. Every one of them runs on an update_freq, so
# routing the routine tick through here arms the stuck-card watchdog for all
# six rather than for the one item that happened to call card.sh by hand.
card_dispatch() {
  case "${SENDER:-}" in
    mouse.exited|mouse.exited.global) exec "$CONFIG_DIR/plugins/card.sh" "$1" close ;;
  esac
  "$CONFIG_DIR/plugins/card.sh" "$1" tick 2>/dev/null
}
