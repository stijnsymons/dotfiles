#!/usr/bin/env bash
# Shared label fitter for the two wide left-cluster items (meeting, productive).
#
# Why not the obvious options:
#   - label.width is a FIXED constant. It clips mid-glyph, never grows into
#     space that is free, and if the constant is ever undefined it silently
#     expands to width 0 - the item renders as a bare icon with no other
#     symptom. That is exactly how these two items broke.
#   - scroll_texts animates. A meeting title you have to wait for is not
#     readable at a glance, which is the whole point of the item.
#
# Instead: automatic (content-sized) width, with the text truncated here to
# whatever actually fits before the notch. Recomputed every tick, so the items
# grow and shrink as the front_app name changes and as each other's content
# changes.
#
# Sourced, not executed. CONFIG_DIR must be set.

# FiraMono is monospace, so one constant covers every string. Tenths of a point
# to keep the arithmetic integer. Re-measure if FONT_TEXT or SZ change:
#   sketchybar --add item probe left --set probe label.font="<font>:<size>"
#   ...set a 20- and a 30-M label, diff the two bounding widths, divide by 10.
FIT_CHAR_W=78        # 7.80pt per character at FiraMono Regular 13.0
FIT_ITEM_OVERHEAD=30 # icon glyph + its padding (24) + label padding (6)
FIT_SAFETY=12        # never crowd the notch edge exactly

# fit_label <item> <text> [reserve_px]
# Echoes text, truncated with a single-character ellipsis if it cannot fit.
# reserve_px is space to leave for whatever sits between this item and the
# notch (meeting must leave room for the divider and the productive item).
fit_label() {
  local item="$1" text="$2" reserve="${3:-0}"
  local notch_l x avail chars

  read -r _ notch_l _ _ <<<"$("$CONFIG_DIR/bin/screen-metrics" 2>/dev/null)"
  notch_l="${notch_l%.*}"
  x="$(sketchybar --query "$item" 2>/dev/null \
       | jq -r '.bounding_rects|to_entries[0].value.origin[0] // empty')"
  x="${x%.*}"

  # No notch on this display: nothing to fit against, emit as-is.
  case "${notch_l:-}" in ''|*[!0-9]*) printf '%s' "$text"; return ;; esac
  [ "$notch_l" -gt 0 ] || { printf '%s' "$text"; return; }

  # A hidden item has no bounding rect, so x is unreadable exactly on the
  # hidden -> visible transition - which is when a fresh meeting first appears.
  # Passing the text through untruncated there would overrun the notch until
  # the next tick, 60s later. Use the last position this item held instead, and
  # only if there has never been one, assume the worst half of the bar.
  local xcache="${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar/fit-${item}.x"
  case "${x:-}" in
    ''|*[!0-9]*)
      x="$(cat "$xcache" 2>/dev/null)"
      case "${x:-}" in ''|*[!0-9]*) x=$(( notch_l / 2 )) ;; esac
      ;;
    *)
      mkdir -p "$(dirname "$xcache")"
      printf '%s' "$x" > "$xcache"
      ;;
  esac

  # reserve may be "45%", meaning: keep that share of the run-up to the notch
  # for the items to my right. Meeting uses this so a long meeting title cannot
  # starve the Productive warning sitting beside it.
  case "$reserve" in
    *%) reserve=$(( (notch_l - x - FIT_SAFETY) * ${reserve%\%} / 100 )) ;;
  esac

  avail=$(( notch_l - x - reserve - FIT_ITEM_OVERHEAD - FIT_SAFETY ))
  chars=$(( avail * 10 / FIT_CHAR_W ))

  if [ "$chars" -lt 3 ]; then printf ''; return; fi
  if [ "${#text}" -le "$chars" ]; then printf '%s' "$text"; return; fi

  printf '%s…' "${text:0:$(( chars - 1 ))}"
}

# fit_reserve_for <item-to-my-right>
# Space that item currently occupies, plus the divider between us. Measured
# rather than guessed as a percentage: a fixed share left the meeting title
# ellipsised while ~150pt sat unused next to it. Falls back to a typical width
# when the neighbour is not laid out yet (first paint) or is hidden.
fit_reserve_for() {
  local w
  w="$(sketchybar --query "$1" 2>/dev/null | jq -r '
         if .geometry.drawing == "on"
         then (.bounding_rects | to_entries[0].value.size[0] // 0)
         else 0 end | floor')"
  case "$w" in ''|*[!0-9]*) w=110 ;; esac
  printf '%s' "$(( w + 10 ))"
}

