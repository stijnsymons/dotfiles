# shellcheck shell=bash
# Who is holding the microphone.
#
# The indicator can only ever say "something is listening" - it is one red glyph
# - and that is the least useful half of the question. The list comes from
# `bin/sb-helper --mic-consumers`, which is the SAME binary and the same
# CoreAudio call that decides whether the item is drawn at all, so the card can
# never name a consumer the item disagrees about. Each line is
# `pid<TAB>app<TAB>bundle-id`.
#
# Called on click, not on a tick: ~30ms for CoreAudio's dylib load, which is
# well inside a click, and it means the list is true at the moment you ask
# rather than as of the last poll.
source "$CONFIG_DIR/plugins/app_icon.sh"

card_rows() {
  local privacy pid app bundle glyph any=0
  privacy="open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone'"

  while IFS=$'\t' read -r pid app bundle; do
    [ -n "$pid" ] || continue
    any=1
    # The bundle id is what app_icon prefers, but a capturing process is
    # usually a helper ("com.tinyspeck.slackmacgap.helper"), which matches
    # nothing - so fall back to the app name, which is the first .app in the
    # executable's path and does match.
    glyph="$(app_icon "$bundle")"
    [ -n "$glyph" ] || glyph="$(app_icon "$app")"
    [ -n "$glyph" ] || glyph='󰍬'
    # Clicking a row raises the app that is listening - the useful next move
    # when the answer is "something you forgot about". `open -a` takes the
    # display name; it fails harmlessly if the app has an odd bundle layout.
    printf '%s\t%s\t%s\t%s\n' "$glyph" "$RED" "$(card_text "$app")" \
           "open -a '$(card_text "$app")'"
  done <<MICEOF
$("$CONFIG_DIR/bin/sb-helper" --mic-consumers 2>/dev/null)
MICEOF

  # Reachable: the item hides itself when nothing captures, but card.sh can be
  # asked to open any card by hand, and a stale open should not read as "these
  # three apps are listening".
  [ "$any" = 0 ] && printf '󰍭\t%s\tNothing is using the mic\n' "$FG_DIM"

  printf '󰒓\t%s\tOpen Microphone privacy settings\t%s\n' "$AQUA" "$privacy"
}
