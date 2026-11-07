#!/usr/bin/env bash
# Hover detail for a timer chip: a two-row popup beneath it with the booking's
# full name, tracked / planned and the pace. Driven by mouse.entered / exited on
# productive_c<N> (sketchybarrc), read from the same board file as the chips, so
# the detail can never disagree with the chip it hangs off.
#
#   productive_chip_hover.sh            run by sketchybar, $NAME = productive_c<N>, $SENDER = mouse.*
#   productive_chip_hover.sh --text <i> print the two rows for chip i (tab separated), for check.sh
#
# Pace: a booking's plan is spread over the five working days, so by day D of the
# week the tracked time should be about planned * D/5. Weekend counts as day 5.
# Bookings without a plan (internal) have no pace to judge, only a total.
set -u
source "$CONFIG_DIR/colors.sh"
BOARD="${PRODUCTIVE_BOARD:-$SB_CACHE_DIR/productive-board.json}"

fmt() { local m=${1:-0}; if [ "$m" -ge 60 ]; then printf '%dh%02dm' $((m / 60)) $((m % 60)); else printf '%dm' "$m"; fi; }

rows() { # rows <chip index>  -> "<name>\t<detail>"
  local i="$1" name tracked planned dow exp detail
  IFS=$'\t' read -r name tracked planned <<<"$(jq -r --argjson i "$i" '
      ((.chips // [])[$i - 1]) as $k
      | (.bookings[] | select(.key == $k)) | "\(.name)\t\(.tracked_minutes)\t\(.booked_minutes // "")"' "$BOARD" 2>/dev/null)"
  [ -n "$name" ] || return 1
  dow="${PRODUCTIVE_DOW:-$(date +%u)}"; [ "$dow" -gt 5 ] && dow=5
  if [ -z "$planned" ] || [ "$planned" = 0 ]; then detail="$(fmt "$tracked") tracked, no plan this week"
  else
    exp=$(( planned * dow / 5 ))
    detail="$(fmt "$tracked") of $(fmt "$planned") planned"
    if   [ "$tracked" -gt "$planned" ]; then detail="$detail, over by $(fmt $(( tracked - planned )))"
    elif [ "$tracked" -ge "$exp" ];     then detail="$detail, on pace"
    else detail="$detail, behind: ~$(fmt "$exp") expected by now"; fi
  fi
  printf '%s\t%s\n' "$name" "$detail"
}

if [ "${1:-}" = "--text" ]; then rows "$2"; exit; fi

i="${NAME#productive_c}"
case "${SENDER:-}" in
  mouse.entered)
    IFS=$'\t' read -r n d <<<"$(rows "$i")" || exit 0
    [ -n "$n" ] || exit 0
    sketchybar --set "productive_ha$i" label="$n" --set "productive_hb$i" label="$d" \
               --set "$NAME" popup.drawing=on ;;
  mouse.exited|mouse.exited.global)
    sketchybar --set "$NAME" popup.drawing=off ;;
esac
