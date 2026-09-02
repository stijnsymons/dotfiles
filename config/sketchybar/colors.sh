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
export CARD_ITEMS="meeting productive media cpu wifi caffeine"
export CARD_ROWS=8

# Hover dispatch for a card owner. Every one of them runs on an update_freq, so
# routing the routine tick through here arms the stuck-card watchdog for all
# six rather than for the one item that happened to call card.sh by hand.
card_dispatch() {
  case "${SENDER:-}" in
    mouse.exited|mouse.exited.global) exec "$CONFIG_DIR/plugins/card.sh" "$1" close ;;
  esac
  "$CONFIG_DIR/plugins/card.sh" "$1" tick 2>/dev/null
}
