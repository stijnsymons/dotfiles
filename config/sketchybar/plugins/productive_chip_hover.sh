#!/usr/bin/env bash
# Hover on a timer chip: the chip itself widens to show the booking's full name,
# growing to the LEFT so the chips to its right (and the notch) never move. Driven
# by mouse.entered / exited on productive_c<N> (sketchybarrc), read from the same
# board file as the chips, so the name can never disagree with the chip it is on.
#
#   productive_chip_hover.sh                      run by sketchybar, $NAME = productive_c<N>, $SENDER = mouse.*
#   productive_chip_hover.sh --plan <i> <label> [room]
#                                                 print "<full name>\t<shift px>" for chip i resting on <label>, for check.sh
#
# Growing left: a negative padding_left on BOTH the stripe and the code item moves
# the pair left by exactly the extra width, which leaves the right edge where it
# was. Measured on the live bar: a negative padding on the stripe alone moves only
# the stripe, and the code item keeps its place and grows right. The extra width is
# computed, not queried, because FiraMono is monospace: a query after the label
# change would draw one frame grown the wrong way first.
#
# The chip's bracket carries the fill, so the widened chip covers the anchor or the
# chips to its left while hovered; productive_chips.sh resets both paddings on
# every repaint, so a tick during a hover collapses it rather than leaving it skewed.
set -u
# launchd gives no locale: in C, ${#name} counts the bytes of "·", not one character.
export LC_CTYPE=en_US.UTF-8
BOARD="${PRODUCTIVE_BOARD:-$SB_CACHE_DIR/productive-board.json}"
CHAR_W=69          # tenths of a point per character, FiraMono Bold 11.5 (0.6 em)
STRIPE_PAD=5       # productive_s<N>'s resting padding_left (sketchybarrc)
NAME_MAX=50        # ~345pt: a wider chip is a banner, not a label
EDGE=8             # never grow closer than this to the bar's left edge

plan() { # <chip index> <resting label> [room px to the left] -> "<name>\t<shift>"
  local name max=$NAME_MAX
  name="$(jq -r --argjson i "$1" '((.chips // [])[$i - 1]) as $k | (.bookings[] | select(.key == $k)) | .name' "$BOARD" 2>/dev/null)"
  [ -n "$name" ] || return 1
  # Less room than the name needs (a chip near the left edge): cut the name, not the bar.
  [ -n "${3:-}" ] && [ $(( ${#2} + $3 * 10 / CHAR_W )) -lt "$max" ] && max=$(( ${#2} + $3 * 10 / CHAR_W ))
  [ "${#name}" -le "$max" ] || name="${name:0:$(( max - 1 ))}…"
  printf '%s\t%s\n' "$name" "$(( (${#name} - ${#2}) * CHAR_W / 10 ))"
}

if [ "${1:-}" = "--plan" ]; then plan "$2" "$3" "${4:-}"; exit; fi

i="${NAME#productive_c}"
case "${SENDER:-}" in
  mouse.entered)
    [ -e "$SB_CACHE_DIR/productive-chip-$i.rest" ] && exit 0   # already widened: its label is the name now
    IFS=$'\t' read -r rest x <<<"$(sketchybar --query "$NAME" 2>/dev/null \
      | jq -r '[.label.value, (.bounding_rects | to_entries[0].value.origin[0] | floor)] | @tsv')"
    IFS=$'\t' read -r n d <<<"$(plan "$i" "$rest" $(( ${x:-0} - EDGE )))" || exit 0
    [ -n "$n" ] && [ "${d:-0}" -gt 0 ] || exit 0
    # Kept for the exit: the chips repaint can change the code while hovered.
    printf '%s' "$rest" > "$SB_CACHE_DIR/productive-chip-$i.rest"
    sketchybar --set "productive_s$i" padding_left=$(( STRIPE_PAD - d )) \
               --set "$NAME" label="$n" padding_left=-"$d" ;;
  mouse.exited|mouse.exited.global)
    rest="$(cat "$SB_CACHE_DIR/productive-chip-$i.rest" 2>/dev/null)"
    [ -n "$rest" ] || exit 0
    rm -f "$SB_CACHE_DIR/productive-chip-$i.rest"
    sketchybar --set "productive_s$i" padding_left="$STRIPE_PAD" \
               --set "$NAME" label="$rest" padding_left=0 ;;
esac
