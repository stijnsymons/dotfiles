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

# Cache. Everything the bar keeps on disk lands here - calendar bodies, join
# links with their passcodes, timesheet rows - so it is ours alone rather than
# the world-readable 755 a plain mkdir leaves behind.
export SB_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar"
[ -d "$SB_CACHE_DIR" ] || mkdir -p "$SB_CACHE_DIR"
chmod 700 "$SB_CACHE_DIR" 2>/dev/null

# Card rows are tab-separated and their fourth field is run by sh, so a literal
# tab in free text - a calendar invite, a track title, an SSID - would shift the
# rest of that text into the action field. Strip the separators at the source.
card_text() { printf '%s' "$1" | tr -d '\011\012\015'; }
