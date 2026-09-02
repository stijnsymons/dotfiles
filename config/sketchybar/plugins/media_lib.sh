# shellcheck shell=bash
# Album artwork for the now-playing card: a cover in a left gutter, the text
# rows beside it.
#
# The cover rides along in the SAME nowplaying-cli call that already fetches
# the title - measured at 106ms with and without artworkData, so the bytes come
# free. The decode and the resize do not (~35ms), which is why both happen on
# media.sh's 15s tick and never when the card opens: everything the popup needs
# is on disk and already assigned before the item is clickable at all.
#
# A popup is one stack, and the two-column trick the bar uses for cpu/mem does
# NOT carry over to a vertical one: a popup item's content is clipped to its own
# row band, so any y_offset big enough to lift a row up beside a 96pt cover
# erases the row instead of moving it (v2.24.0, verified on screen). Turning the
# popup horizontal does make the stack work - equal widths, opposite y_offset, a
# negative padding_right - but then every row's hit rectangle becomes the full
# popup height at the same x, so all four rows share one click target and the
# transport row can no longer be aimed at. That is the trade the card refuses.
#
# What gives two real columns for free is the popup's OWN background image:
# sketchybar draws it flush LEFT and full-height inside the popup background,
# behind the rows. Indent every row past it and the cover sits in a left gutter
# with the text to its right - while the rows stay in a vertical popup and keep
# their own 24pt hit rectangles.

ART_JPG="$SB_CACHE_DIR/media-art.jpg"
# Twice the largest square the card can offer, so the cover stays crisp on a
# Retina panel; art_show divides by this to get sketchybar's scale factor.
ART_PX=192
ART_ROW_H=24   # popup.height in sketchybarrc's card_popup; check.sh asserts it
ART_GAP=10     # gutter between the cover and the row glyphs
ART_INDENT=12  # card_rows_for's plain-text indent, restored when there is no cover

# The test every field in this card is read through: nowplaying-cli reports a
# missing key as the four characters "null", not as nothing at all.
art_has() { [ -n "${1:-}" ] && [ "$1" != "null" ]; }

# How many rows cards/media.sh will draw, which is how tall the popup will be,
# which is the side the cover has to be to fill the gutter without being
# clipped. Title and the transport control are always drawn; artist and album
# only when the player published them. check.sh asserts this still matches what
# the card actually emits - nothing in the drawing path would notice if it drifted.
art_rows() { # art_rows <artist> <album>
  local n=2
  art_has "${1:-}" && n=$(( n + 1 ))
  art_has "${2:-}" && n=$(( n + 1 ))
  printf '%s' "$n"
}

art_forget() { rm -f "$ART_JPG" "$ART_JPG.new"; }

# art_extract <base64> - the cover for the current track, overwritten in place.
#
# One file, one sips call: -s format jpeg normalises the PNG some players publish,
# -Z fits the long edge and -c then squares the short one, because a letterboxed
# cover reads better in a square gutter than a cropped one.
#
# Returns nonzero for every shape of "no cover" there is, and takes the stale
# file with it. `base64 --decode` turns the literal "null" into three bytes of
# junk perfectly happily, so the decode's exit status says nothing; sips
# refusing to READ those bytes is what actually distinguishes a cover.
#
# sips is only trustworthy about bytes that exist. Handed a missing or an empty
# input it exits 0 and writes nothing at all, so a non-empty result - not the
# exit status, and not the mv either - is what "we have a cover" has to mean.
art_extract() { # art_extract <base64>
  local b64="${1:-}"
  art_has "$b64" || { art_forget; return 1; }
  printf '%s' "$b64" | base64 --decode > "$ART_JPG.new" 2>/dev/null
  if sips -s format jpeg -Z "$ART_PX" -c "$ART_PX" "$ART_PX" \
          "$ART_JPG.new" --out "$ART_JPG.new" >/dev/null 2>&1 &&
     [ -s "$ART_JPG.new" ] && mv -f "$ART_JPG.new" "$ART_JPG"; then
    return 0
  fi
  art_forget
  return 1
}

# art_show <rows> - the cover in the gutter, every row indented past it.
art_show() { # art_show <rows>
  local side scale i args
  side=$(( ART_ROW_H * $1 ))
  scale="$(awk -v s="$side" -v p="$ART_PX" 'BEGIN { printf "%.4f", s / p }')"
  args=(--set media popup.background.image="$ART_JPG"
                    popup.background.image.drawing=on
                    popup.background.image.scale="$scale")
  i=1
  while [ "$i" -le "${CARD_ROWS:-8}" ]; do
    args+=(--set "media.pop.$i" icon.padding_left=$(( side + ART_GAP )))
    i=$(( i + 1 ))
  done
  sketchybar "${args[@]}" >/dev/null 2>&1
}

# art_hide - podcasts, live streams and most web players publish no cover at
# all, and the card has to fall back to today's plain-text layout rather than
# hold open an empty gutter or keep drawing the last track's sleeve.
art_hide() {
  local i args
  art_forget
  args=(--set media popup.background.image.drawing=off)
  i=1
  while [ "$i" -le "${CARD_ROWS:-8}" ]; do
    args+=(--set "media.pop.$i" icon.padding_left="$ART_INDENT")
    i=$(( i + 1 ))
  done
  sketchybar "${args[@]}" >/dev/null 2>&1
}

# art_update <base64> <artist> <album> - the whole job, once per tick.
#
# Re-assigning the path on every tick is also the cache-bust: sketchybar re-reads
# the file when the property is assigned, even to the byte-identical path it
# already held (verified - the drawn cover follows the bytes), so a track can
# flip without the filename ever having to change and without the popup ever
# holding an image the file no longer contains.
art_update() { # art_update <base64> <artist> <album>
  if art_extract "${1:-}"; then
    art_show "$(art_rows "${2:-}" "${3:-}")"
  else
    art_hide
  fi
}
