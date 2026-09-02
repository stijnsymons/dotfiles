# shellcheck shell=bash
# The date, the ISO week, and this week's hours. The week number is the reason
# this card exists: macOS surfaces it nowhere, and every weekly rhythm the user
# has - Focus updates, timesheet weeks, the Thoughts note names - is named by
# it, so it is the one thing that must always be on the card.
#
# The hours row reads productive_week.sh's cache and never the API. Missing,
# stale or from another week all render the same dim dash: the only thing worse
# than not knowing how far behind you are is being told Tuesday's number on
# Friday.
CLOCK_WEEK_STALE_AFTER=5400   # six of productive_week.sh's 900s refreshes

# Colour for logged-vs-booked, pro-rated by how far into the week you are.
# Working days completed, plus a half for today: that is what makes 8h on
# Monday comfortable and the same 8h on Friday alarming, without painting a
# Friday MORNING red for not having Friday evening's hours in yet.
#
# Everything is integer minutes over halves-of-a-working-day (10 of them in a
# week), because this runs on the click path and a card is not worth an awk.
clock_hours_color() {   # clock_hours_color <logged_min> <booked_min> <iso_dow>
  local logged=$1 booked=$2 dow=$3 done_days halves expect
  [ "$booked" -gt 0 ] 2>/dev/null || { printf '%s' "$FG_DIM"; return; }
  done_days=$(( dow - 1 )); [ "$done_days" -gt 5 ] && done_days=5
  halves=$(( 2 * done_days ))
  [ "$dow" -le 5 ] && halves=$(( halves + 1 ))
  expect=$(( booked * halves / 10 ))
  [ "$expect" -le 0 ] && { printf '%s' "$GREEN"; return; }
  if   [ $(( logged * 100 )) -ge $(( expect * 90 )) ]; then printf '%s' "$GREEN"
  elif [ $(( logged * 100 )) -ge $(( expect * 65 )) ]; then printf '%s' "$YELLOW"
  else printf '%s' "$RED"; fi
}

card_rows() {
  local cache j age logged booked note
  printf '󰥔\t%s\tWeek %s\n' "$VIOLET" "$(date +%V)"
  printf '󰄉\t%s\t%s\n' "$FG_DIM" "$(date '+%A %-d %B %Y')"

  cache="${PRODUCTIVE_WEEK_CACHE:-$SB_CACHE_DIR/productive-week.json}"
  j=""
  if [ -s "$cache" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$cache" 2>/dev/null || echo 0) ))
    [ "$age" -le "$CLOCK_WEEK_STALE_AFTER" ] && j="$(cat "$cache" 2>/dev/null)"
  fi
  # The file outlives the week it describes, so mtime alone is not enough: a
  # Sunday-night total under a Monday heading reads as real and is not.
  [ "$(printf '%s' "$j" | jq -r '.week // ""' 2>/dev/null)" = "$(date +%G-W%V)" ] || j=""

  if [ -z "$j" ]; then
    printf '󰅐\t%s\t—  ·  hours this week unavailable\n' "$FG_DIM"
  else
    logged="$(printf '%s' "$j" | jq -r '.logged_minutes // 0')"
    booked="$(printf '%s' "$j" | jq -r '.booked_minutes // 0')"
    printf '󰅐\t%s\t%dh / %dh logged this week\n' \
           "$(clock_hours_color "$logged" "$booked" "$(date +%u)")" \
           $(( (logged + 30) / 60 )) $(( (booked + 30) / 60 ))
  fi

  # The day view, not htmlLink's default: this row answers "what is left of
  # today", which the week grid buries.
  printf '󰃰\t%s\tGoogle Calendar  ·  today\t%s\n' "$BLUE" \
         "$CONFIG_DIR/plugins/brave_tab.sh 2 'https://calendar.google.com/calendar/u/0/r/day'"
  printf '󰐊\t%s\tProductive timesheet\t%s\n' "$AQUA" "$CONFIG_DIR/plugins/brave_tab.sh 3"

  # Obsidian's own obsidian:// URI carries a `&` between vault and file, and
  # card.sh clears any action containing one - so the row would keep its text
  # and lose its click. `open -a` on the note's real path inside the vault gets
  # Obsidian to the same place with no query string at all.
  #
  # Emitted only when the note exists: /my-focus creates it, and a row that
  # opens Monday's blank editor is worse than no row.
  note="$HOME/drive/Thoughts/Notes/$(date +%G-W%V).md"
  [ -f "$note" ] && printf '󰎞\t%s\t%s\t%s\n' "$VIOLET" \
                           "This week's Focus note" "open -a Obsidian '$note'"
}
