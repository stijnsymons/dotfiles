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

# PATH. launchd starts sketchybar from a login-less context - PATH is
# /usr/bin:/bin and little else - so gws-now (~/bin), the Productive CLI
# (~/code/assistant/bin) and jq (the brew prefix) are all unreachable and every
# plugin that shells out silently finds nothing. Repaired here, once, for
# everything that sources this file. The brew prefix doubles as the sentinel: a
# PATH that already has it came from a login shell and is left alone.
case ":$PATH:" in
  *:/opt/homebrew/bin:*) ;;
  *) export PATH="$HOME/bin:$HOME/code/assistant/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" ;;
esac

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

# Map a display UUID (fifth field of bin/screen-metrics) to the arrangement id
# sketchybar wants in `--bar display=`. screen-metrics picks the external
# screen when one is plugged in, so this is what pins the bar there without
# making that screen the macOS primary. Falls back to "main" - the old
# behaviour - when the lookup fails, so a bad query never strands the bar on a
# display that no longer exists.
bar_display() {
  local aid
  aid="$(sketchybar --query displays 2>/dev/null \
         | jq -r --arg u "${1:-}" '.[] | select(.UUID == $u) | ."arrangement-id"' 2>/dev/null)"
  case "$aid" in
    ''|*[!0-9]*) printf 'main' ;;
    *)           printf '%s' "$aid" ;;
  esac
}

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
