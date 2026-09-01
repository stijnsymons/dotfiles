# Now playing. One nowplaying-cli call (~115ms) for every field, as media.sh
# documents - asking for keys individually costs the same each time.
card_rows() {
  local raw title artist album app rate
  raw="$(nowplaying-cli get title artist album playbackRate 2>/dev/null)"
  { IFS= read -r title; IFS= read -r artist; IFS= read -r album; IFS= read -r rate; } <<RAWEOF
$raw
RAWEOF
  if [ -z "$title" ] || [ "$title" = "null" ]; then
    printf '󰝛\t%s\tNothing playing\n' "$FG_DIM"; return
  fi
  # These three rows carry no action, so a tab in a track title would make the
  # rest of it the row's whole command. card_text takes the tabs out first.
  printf '󰎈\t%s\t%s\n' "$GREEN" "$(card_text "$title")"
  [ -n "$artist" ] && [ "$artist" != "null" ] && printf '󰠃\t%s\t%s\n' "$FG"     "$(card_text "$artist")"
  [ -n "$album"  ] && [ "$album"  != "null" ] && printf '󰀥\t%s\t%s\n' "$FG_DIM" "$(card_text "$album")"
  # Transport control, last row: the card's one actionable line. Everything
  # above it is information, so a stray click cannot change playback.
  if [ "$rate" = "1" ]; then
    printf '󰏤\t%s\tPause\t%s\n' "$YELLOW" "nowplaying-cli togglePlayPause"
  else
    printf '󰐊\t%s\tPlay\t%s\n'  "$AQUA"   "nowplaying-cli togglePlayPause"
  fi
}
