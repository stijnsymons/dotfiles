# shellcheck shell=bash
# Now playing. One nowplaying-cli call (~115ms) for every field, as media.sh
# documents - asking for keys individually costs the same each time.
#
# plugins/spotify_playlist_add.sh is SOURCED, not run: sourced it defines only
# functions (it checks BASH_SOURCE against $0 and returns), and the three the
# card needs - spotify_member_key, spotify_member_state, spotify_outcome_read -
# read two cache files whose record format is defined over there. Re-writing
# those readers here would mean two copies of a format that will grow a field.
# Sourcing costs a parse and no process; a card render cannot afford a spawn it
# does not have to make.
# shellcheck source=../plugins/spotify_playlist_add.sh
source "$CONFIG_DIR/plugins/spotify_playlist_add.sh"

# The result of the last "Add to <year>" click, for as long as it is fresh.
#
# This row is the entire reason the action is usable at all. sketchybar throws a
# click_script's stdout away and card.sh closes the popup the instant the action
# returns, so before this row existed all five of the add path's outcomes -
# including "not configured", which is what an un-set-up box hits every single
# time - looked identical from the user's seat: click, popup shuts, nothing.
media_outcome_row() {
  local tok detail
  { IFS=$'\t' read -r tok detail; } <<OUTEOF
$(spotify_outcome_read)
OUTEOF
  case "${tok:-}" in
    added)        printf '󰄬\t%s\tAdded to %s\n'   "$GREEN"  "$YEAR" ;;
    already)      printf '󰄬\t%s\tAlready in %s\n' "$AQUA"   "$YEAR" ;;
    none)         printf '󰝛\t%s\tNo Spotify track to add\n' "$FG_DIM" ;;
    unconfigured) printf '󰀦\t%s\tSpotify not configured - see SETUP in spotify_playlist_add.sh\n' "$YELLOW" ;;
    error)        printf '󰀦\t%s\tSpotify: %s\n'   "$RED"    "$(card_text "${detail:-failed}")" ;;
  esac
}

# The cover is a popup BACKGROUND image, so it has to be scaled to the height of
# the rows drawn beside it or it ends short of them / overruns them. art_rows()
# in media_lib.sh used to predict that height from artist+album alone, which was
# right while the card was a fixed title + artist + album + transport. It is not
# any more: the transport row DISAPPEARS once the track is in the playlist, the
# add row is always there, and the outcome toast comes and goes - so the count
# now swings between 1 and 6 and depends on cache state the 15s tick cannot see.
#
# So the tick keeps doing the expensive half (decode and resize, ~35ms) and the
# card does the cheap half here, with the count it actually emitted. art_show is
# one batched --set; measured against the click path it is noise.
#
# It runs BEFORE card.sh paints the rows, which is safe: art_show only sets
# icon.padding_left on the row items and card.sh's own row --set never touches
# that property, so the gutter survives the repaint that follows.
card_rows() {
  local out
  out="$(_media_rows)"
  if [ -r "$CONFIG_DIR/plugins/media_lib.sh" ] && [ -n "$out" ]; then
    # shellcheck source=../plugins/media_lib.sh
    source "$CONFIG_DIR/plugins/media_lib.sh"
    [ -f "$ART_JPG" ] && art_show "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  fi
  printf '%s\n' "$out"
}

_media_rows() {
  local raw title artist album rate key state
  raw="$(nowplaying-cli get title artist album playbackRate 2>/dev/null)"
  { IFS= read -r title; IFS= read -r artist; IFS= read -r album; IFS= read -r rate; } <<RAWEOF
$raw
RAWEOF
  if [ -z "$title" ] || [ "$title" = "null" ]; then
    printf '󰝛\t%s\tNothing playing\n' "$FG_DIM"
    # Still worth drawing: "no track playing" is precisely the outcome you get
    # from clicking add with nothing on, and it has to land somewhere.
    media_outcome_row
    return
  fi
  # These three rows carry no action, so a tab in a track title would make the
  # rest of it the row's whole command. card_text takes the tabs out first.
  printf '󰎈\t%s\t%s\n' "$GREEN" "$(card_text "$title")"
  [ -n "$artist" ] && [ "$artist" != "null" ] && printf '󰠃\t%s\t%s\n' "$FG"     "$(card_text "$artist")"
  [ -n "$album"  ] && [ "$album"  != "null" ] && printf '󰀥\t%s\t%s\n' "$FG_DIM" "$(card_text "$album")"

  # Is this track already in this year's playlist? Answered from the cache the
  # add and check paths fill in, never from the network: this function runs
  # inside card.sh's `$(card_rows)` on the click that opens the popup, and a
  # playlist scan there would be one to four round trips of dead popup.
  #
  # "null" is normalised away before the key is built because np_read on the
  # write side does the same - two spellings of "no artist" would key the same
  # track two different ways and the cache would never hit.
  [ "$artist" = "null" ] && artist=''
  key="$(spotify_member_key "$title" "$artist")"
  state="$(spotify_member_state "$key")"

  # Cache miss: fill it in for next time, detached, and draw the honest
  # "not checked" appearance meanwhile. Every descriptor is closed off - a child
  # holding card.sh's captured stdout would keep the `$(card_rows)` substitution
  # blocked until the API answered, which is the exact stall this avoids.
  # spotify_check_due is what stops ten opens in a minute being ten scans, and
  # what stops an unconfigured box forking one of these per click forever.
  if [ "$state" = "unknown" ] && spotify_check_due "$key"; then
    "$CONFIG_DIR/plugins/spotify_playlist_add.sh" check >/dev/null 2>&1 </dev/null &
  fi

  # Transport control. Everything above it is information, so a stray click
  # cannot change playback.
  #
  # Dropped entirely once the track is known to be in the playlist. That is a
  # literal reading of the request - the card in that state is about the
  # playlist, not about playback - and it is why removing it is safe to do
  # blind: `in` is only ever reached from a positive cache hit, never from the
  # unknown state, so the row cannot vanish just because nothing has checked.
  if [ "$state" != "in" ]; then
    if [ "$rate" = "1" ]; then
      printf '󰏤\t%s\tPause\t%s\n' "$YELLOW" "nowplaying-cli togglePlayPause"
    else
      printf '󰐊\t%s\tPlay\t%s\n'  "$AQUA"   "nowplaying-cli togglePlayPause"
    fi
  fi

  # Add to this year's playlist. $YEAR comes from the plugin sourced above, so
  # the label names the playlist the script will actually resolve rather than a
  # second, independently computed year that could disagree across midnight on
  # the 31st of December.
  #
  # Three appearances for three states, and the middle one is the point:
  #
  #   in       checked, and it is in there      -> check glyph, and no add
  #   out      checked, and it is not           -> plus, green: go ahead
  #   unknown  nothing has checked, or the      -> plus, plain foreground
  #            answer expired, or the check
  #            failed
  #
  # `unknown` must not be drawn as `out`. Both offer the same action, so the
  # difference is only ever colour, but collapsing them would have the card
  # assert "not in your playlist" about a track it has never asked about - and
  # the whole reason the cache is allowed to exist is that it is never permitted
  # to state something it does not know.
  #
  # Spotify only: nowplaying-cli reports whatever holds the Now Playing slot,
  # which may be a browser tab or a podcast, and the script answers "no track
  # playing" for anything it cannot resolve to a spotify:track URI. The row is
  # offered regardless rather than being conditional on the source, because
  # asking nowplaying-cli which app is playing costs another call for a guess
  # the script makes properly a moment later anyway.
  #
  # `card`, not a bare path: that mode forks, records its outcome for
  # media_outcome_row and puts the card back up. card.sh filters shell
  # metacharacters out of the action field and a path plus a bare word carries
  # none of them, so this survives the filter with its argument intact - which
  # the bare path it replaces already proved, since that was never the reason
  # the row did nothing.
  #
  # The `in` row keeps the same action deliberately. It is the only way back
  # from a cache that has gone stale in the direction that lies: clicking it
  # re-checks server-side and repaints, and if the track really had been removed
  # from the phone it quietly puts it back, which is what you wanted anyway.
  if [ "$state" = "in" ]; then
    printf '󰄬\t%s\tIn %s\t%s\n' "$AQUA" "$YEAR" \
           "$CONFIG_DIR/plugins/spotify_playlist_add.sh card"
  else
    printf '󰐕\t%s\tAdd to %s\t%s\n' \
           "$([ "$state" = "out" ] && printf '%s' "$GREEN" || printf '%s' "$FG")" \
           "$YEAR" "$CONFIG_DIR/plugins/spotify_playlist_add.sh card"
  fi

  media_outcome_row
}
