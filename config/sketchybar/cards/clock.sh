# shellcheck shell=bash
# The date, the ISO week, and the shape of the working week: hours logged
# against hours booked, where that sits against a pro-rated pace, and which
# days carried them - then the three places the week is actually worked from.
#
# THE WEEK NUMBER IS THE REASON THIS CARD EXISTS. macOS surfaces it nowhere,
# and every weekly rhythm the user has - Focus updates, timesheet weeks, the
# Thoughts note names - is named by it. It now shares row 1 with the long date
# instead of taking a row of its own: two rows of pure calendar at the top cost
# a row the week chart needed, and "Week 36  ·  Saturday 5 September 2026" is
# one glance either way.
#
# NOTHING HERE TOUCHES THE NETWORK. Two caches are read and neither is written:
# productive_week.sh's weekly totals, and plugins/clock.sh's per-day
# breakdown. Both are gated on the week they describe as well as on their age,
# because the files outlive the week they are about - the only thing worse than
# not knowing how far behind you are is being told Tuesday's number on Friday.
# A block whose data is missing or out of date is DROPPED, never estimated: a
# five-row card is telling the truth and a nine-row card with an invented
# chart in the middle of it is not. Same rule cards/claude.sh runs on.
#
# THE MEDIUM. A row is one label in one monospace font, so there is no real
# column alignment - only hand-counted spaces and Unicode Block Elements. The
# week bar and the three chart rows are all built to CLOCK_COL_W and are the
# only reason they line up; widen one and the whole block shears.

# ellipsize() in plugins/fit.sh measures with ${#text} and cuts with
# ${text:0:n}, both of which count BYTES unless the shell is in a UTF-8 locale
# - and under launchd it is not, `launchctl getenv LANG` is empty. A 41-cell
# block bar then measures as 123, blows past card.sh's MAX_CHARS=64, and gets
# cut at cell 21 - and the cells that survive are the FILLED ones, because the
# empty ░ are all at the right-hand end. The bar would render as a full week
# every time. cards/claude.sh documents the same measurement; this file needs
# it for exactly the same reason and the fix has to be repeated because each
# card is sourced into card.sh separately.
#
# LC_ALL rather than LC_CTYPE, because an LC_ALL set to C by launchd or a
# wrapper would override LC_CTYPE and silently undo this. en_US.UTF-8 rather
# than the bare "UTF-8" macOS also accepts: setlocale() rejects that for LC_ALL
# and falls straight back to C. It also pins %A and %B to English, which is
# what row 1 and the chart's 3-letter day names are written for.
#
# Exported deliberately: card.sh calls ellipsize AFTER sourcing this file, in
# the same process, and that call is the one that needs the locale.
export LC_ALL=en_US.UTF-8

# Six of productive_week.sh's 900s refreshes, and six of plugins/clock.sh's.
# The writer's interval and the reader's expiry are separate jobs and the
# reader's has to be the slacker of the two: at 900s against 900s, a click that
# lands in the second before a refresh completes would find the cache "stale"
# and blank a block that is in fact current. Ninety minutes is long enough that
# only a genuinely dead refresher trips it.
CLOCK_WEEK_STALE_AFTER=5400

# The chart's column pitch: 5 characters of content, 1 of gutter. 5 is set by
# the widest cell the duration formatter can produce ("12h30"); at 4 a long day
# would overflow into its neighbour and drag every column after it out of line.
CLOCK_COL_W=5

# The week bar is exactly as wide as the seven chart columns beneath it
# (7 * 5 + 6 gutters = 41), and is DERIVED from the pitch rather than written
# as 41 so the two cannot drift apart. That shared width is the whole point:
# the bar is the week as one number and the chart is the same week broken up,
# so they read as one block only if their left and right edges agree. 41 cells
# also puts one cell at ~2.4% of the booking, fine enough that a single logged
# hour moves the bar.
CLOCK_BAR_CELLS=$(( 7 * CLOCK_COL_W + 6 ))

# Where the hours "should" be by now, in minutes, pro-rated over halves of a
# working day (10 of them in a week). Working days completed, plus a half for
# today: that is what makes 8h on Monday comfortable and the same 8h on Friday
# alarming, without painting a Friday MORNING red for not having Friday
# evening's hours in yet.
#
# Integer arithmetic over halves rather than anything finer because this runs
# on the click path, and because the estimate is half-a-day granular anyway -
# which is also why the caller refuses to quote the gap to the minute.
clock_week_expect() {   # clock_week_expect <booked_min> <iso_dow>
  local booked=$1 dow=$2 done_days halves
  done_days=$(( dow - 1 )); [ "$done_days" -gt 5 ] && done_days=5
  halves=$(( 2 * done_days ))
  [ "$dow" -le 5 ] && halves=$(( halves + 1 ))
  printf '%s' $(( booked * halves / 10 ))
}

# Colour by logged-against-pace, not by logged-against-booked. An absolute
# ramp would paint every Monday morning red for the crime of being Monday
# morning, which trains you to ignore the colour by Tuesday.
clock_pace_color() {   # clock_pace_color <logged_min> <expect_min>
  [ "$2" -gt 0 ] 2>/dev/null || { printf '%s' "$FG_DIM"; return; }
  if   [ $(( $1 * 100 )) -ge $(( $2 * 90 )) ]; then printf '%s' "$GREEN"
  elif [ $(( $1 * 100 )) -ge $(( $2 * 65 )) ]; then printf '%s' "$YELLOW"
  else printf '%s' "$RED"; fi
}

# "6h30" / "6h" / "45m". Never "0h30": a leading zero hour reads as a broken
# format, and the minutes alone are unambiguous below the hour.
clock_dur() {   # clock_dur <minutes>
  local m=$1
  if [ "$m" -ge 60 ]; then
    if [ $(( m % 60 )) -eq 0 ]; then printf '%dh' $(( m / 60 ))
    else printf '%dh%02d' $(( m / 60 )) $(( m % 60 )); fi
  else printf '%dm' "$m"
  fi
}

# The week bar, in three zones: █ logged, ▒ the shortfall against pace, ░ the
# rest of what is booked. The middle zone is the reason this is not the plain
# two-tone bar the claude card draws - it puts the pace gap INSIDE the bar, at
# the cost of nothing, and saves the separate pace row that would not fit in
# the budget. Read it as "the solid part is done, the speckled part is what
# today should already have covered, the faint part is the rest of the week".
#
# ▒ (U+2592) and not a box-drawing marker or an arrow: it is in Block Elements
# alongside █ and ░, which is the one range FiraMono Nerd Font is known to
# cover here. A glyph it lacks does not degrade, it renders as tofu across the
# full width of the bar. ▒ at 50% also sits visibly between ░ at 25% and █ at
# 100%, where ▓ at 75% was hard to tell from █ at 12pt.
clock_bar() {   # clock_bar <logged_min> <expect_min> <booked_min> <cells>
  local logged=$1 expect=$2 booked=$3 cells=$4 filled pace i out=''
  filled=$(( logged * cells / booked ))
  [ "$filled" -gt "$cells" ] && filled=$cells
  # Floor, with one exception: 20 minutes of a 34-hour week floors to zero
  # cells, and an empty bar under a row that says "0h / 34h" reads as "no
  # data" rather than "barely started". Any time at all gets a cell.
  [ "$filled" -lt 1 ] && [ "$logged" -gt 0 ] && filled=1
  pace=$(( expect * cells / booked ))
  [ "$pace" -gt "$cells" ] && pace=$cells
  # Braced, and it matters. `out="$out█"` looks fine and is not: in a UTF-8
  # locale bash reads the block character's bytes as part of the parameter
  # NAME, looks for a variable called "out█", and under card.sh's `set -u`
  # aborts the function - which does not blank the row, it DELETES it, because
  # card.sh skips rows with empty text. The bar simply would not be there.
  i=0
  while [ "$i" -lt "$cells" ]; do
    if   [ "$i" -lt "$filled" ]; then out="${out}█"
    elif [ "$i" -lt "$pace" ];   then out="${out}▒"
    else                              out="${out}░"; fi
    i=$(( i + 1 ))
  done
  printf '%s' "$out"
}

# The three chart rows, built in one awk because they are one grid: the
# durations, the bars and the day names must be padded to the same pitch by the
# same code, and three passes is three chances for one of them to drift.
#
# argv : vals  - 7 space-separated minute totals, Monday first
#        dow   - ISO weekday of today, 1..7
#        ref   - minutes that count as a full-height column (see below)
# stdout: 3 lines - durations, bars, day names
#
# The block characters live in a split() array and never in substr(): macOS awk
# is byte-oriented, so substr("▁▂▃▄▅▆▇█", 4, 1) returns one byte of a
# three-byte sequence and the row comes out as mojibake. Nothing calls length()
# on a string holding one either, for the same reason.
clock_chart() {   # clock_chart <vals> <dow> <ref>
  awk -v vals="$1" -v dow="$2" -v ref="$3" -v W="$CLOCK_COL_W" '
    BEGIN {
      split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █", lv, " ")
      split("Mon Tue Wed Thu Fri Sat Sun", nm, " ")
      n = split(vals, v, " ")

      # ref is the daily booking, so a full column means "hit the target for
      # the day" and every week is drawn to the same yardstick. Scaling to the
      # tallest day instead - which is what the claude card does, because token
      # throughput has no target - would draw a week of 2h days and a week of
      # 9h days identically, and on a timesheet card that is the one comparison
      # that matters. Falling back to the tallest day when there is no booking
      # keeps the shape rather than flattening every column to level 1.
      if (ref <= 0) { for (i = 1; i <= n; i++) if (v[i] > ref) ref = v[i] }

      for (i = 1; i <= n; i++) {
        # Level 8 is reserved for hitting the target, and everything short of
        # it is scaled across the seven below. Ceiling over all eight instead -
        # which is the arithmetic the claude card uses - rounded a 5h55 day
        # against a 6h43 target up to a full block, so "met the day" and "88%
        # of the day" drew identically and the one distinction the target
        # scaling was added for was the one it lost. The clamp above also
        # matters: a 12-hour Thursday must not out-scale the grid, and the
        # duration row above carries the overshoot.
        if (ref <= 0 || v[i] <= 0) lvl = 0
        else if (v[i] >= ref)      lvl = 8
        else {
          lvl = int((v[i] * 7 + ref - 1) / ref)
          if (lvl > 7) lvl = 7
          if (lvl < 1) lvl = 1
        }

        drow = drow (i > 1 ? " " : "") mid(hm(v[i]), W)
        # Three states, not two. A day that has happened and holds nothing gets
        # a dot rather than ▁, because a lowest block and an empty cell are
        # indistinguishable at 12pt and "did not log anything" is exactly what
        # this chart is for. A day that has NOT happened yet gets blank space:
        # a dot under Sunday on a Wednesday would read as a zero it has not had
        # the chance to earn, and the run of blanks doubles as "this much of
        # the week is left".
        if (lvl > 0)        brow = brow (i > 1 ? " " : "") " " lv[lvl] lv[lvl] lv[lvl] " "
        else if (i <= dow)  brow = brow (i > 1 ? " " : "") "  ·  "
        else                brow = brow (i > 1 ? " " : "") "     "
        nrow = nrow (i > 1 ? " " : "") mid(nm[i], W)
      }
      printf "%s\n%s\n%s\n", drow, brow, nrow
    }

    function sp(k,   s) { s = ""; while (k-- > 0) s = s " "; return s }

    # Centred, not right-aligned: a 3-wide bar sits centred in its 5-wide
    # column, so a right-aligned duration would sit visibly off its own bar.
    function mid(s, w,   l, left) {
      l = length(s)
      if (l >= w) return substr(s, 1, w)
      left = int((w - l) / 2)
      return sp(left) s sp(w - l - left)
    }

    # Five characters at most, which is what sets CLOCK_COL_W. Zero renders
    # empty rather than "0": the bar row below already distinguishes a logged
    # nothing from a day that has not happened, and a column of 0s is noise
    # over the part of the week that has not started.
    function hm(m) {
      if (m <= 0)  return ""
      if (m < 60)  return sprintf("%dm", m)
      if (m % 60)  return sprintf("%dh%02d", int(m / 60), m % 60)
      return sprintf("%dh", int(m / 60))
    }
  '
}

card_rows() {
  local now iso week dow stamp
  local wk_cache wk_week logged booked expect gap colour
  local dy_cache dy_week d1 d2 d3 d4 d5 d6 d7 total
  local ch_dur ch_bar ch_day note

  # One date, not five. Every fork on the click path is felt, and %V/%G/%u all
  # have to come from the same instant anyway - sampling them separately across
  # a midnight or a Sunday-to-Monday boundary is a card that disagrees with
  # itself. %t is awk-style tab, which BSD date emits literally.
  IFS=$'\t' read -r week iso dow now stamp <<CLOCKDATE
$(date '+%V%t%G-W%V%t%u%t%s%t%A %-d %B %Y')
CLOCKDATE

  # --- Row 1: which week, and which day of it --------------------------------
  printf '󰥔\t%s\tWeek %s  ·  %s\n' "$VIOLET" "$week" "$stamp"

  # --- The weekly totals ------------------------------------------------------
  # One jq for the whole file. Three separate ones (the week test, the logged
  # figure, the booked figure) were three process spawns on a click, and it is
  # the click the user is waiting on.
  #
  # "-" for anything missing rather than an empty field, because card.sh reads
  # rows back with IFS=$'\t' and a tab is IFS WHITESPACE: bash collapses a run
  # of it, so an empty field does not read back as empty, it shifts every later
  # field one column left. "-" fails the digit test below and costs nothing.
  wk_cache="${PRODUCTIVE_WEEK_CACHE:-$SB_CACHE_DIR/productive-week.json}"
  wk_week='-'; logged=''; booked=''
  if [ -s "$wk_cache" ] \
     && [ $(( now - $(stat -f %m "$wk_cache" 2>/dev/null || echo 0) )) -le "$CLOCK_WEEK_STALE_AFTER" ]; then
    IFS=$'\t' read -r wk_week logged booked <<CLOCKWEEK
$(jq -r '[ (.week // "-"),
           (.logged_minutes // 0 | if type == "number" then floor else 0 end),
           (.booked_minutes // 0 | if type == "number" then floor else 0 end) ]
         | @tsv' "$wk_cache" 2>/dev/null)
CLOCKWEEK
  fi
  # mtime alone is not enough: the file outlives the week it describes, so a
  # Sunday-night total under a Monday heading reads as real and is not.
  [ "$wk_week" = "$iso" ] || { logged=''; booked=''; }
  case "$logged" in ''|*[!0-9]*) logged='' ;; esac
  case "$booked" in ''|*[!0-9]*) booked='' ;; esac

  # --- Rows 2-3: logged against booked, and against pace ----------------------
  if [ -z "$logged" ]; then
    # Stated, not omitted. A card that is simply three rows shorter than
    # yesterday's reads as a bug in the card; this reads as a fact about the
    # data, which is what it is.
    printf '󰅐\t%s\t—  ·  hours this week unavailable\n' "$FG_DIM"
  elif [ -z "$booked" ] || [ "$booked" -le 0 ]; then
    # Hours with nothing to measure them against. The figure is still real so
    # it is shown, but there is no percentage, no pace and therefore no bar -
    # a bar with an invented denominator is the one thing worse than no bar.
    printf '󰅐\t%s\tLogged  ·  %s this week  ·  no booking found\n' \
           "$FG_DIM" "$(clock_dur "$logged")"
  else
    expect="$(clock_week_expect "$booked" "$dow")"
    colour="$(clock_pace_color "$logged" "$expect")"
    gap=$(( expect - logged ))
    # A quarter of an hour of slack in either direction, because the pace
    # estimate is granular to half a working day: "12m under pace" is false
    # precision dressed up as a measurement, and it would never once say "on
    # pace" - the two numbers are not going to land equal to the minute.
    if   [ "$gap" -gt 14 ];  then gap="$(clock_dur "$gap") under pace"
    elif [ "$gap" -lt -14 ]; then gap="$(clock_dur $(( -gap ))) over pace"
    else                          gap='on pace'
    fi
    printf '󰅐\t%s\tLogged  ·  %dh / %dh  ·  %s\n' \
           "$colour" $(( (logged + 30) / 60 )) $(( (booked + 30) / 60 )) "$gap"
    # A blank glyph field is NOT an option - see the IFS note above: an empty
    # first field shifts the colour into the glyph and the text into the
    # colour, and card.sh then drops the row for having no text. A single space
    # is a non-empty field and renders as the gutter this row wants.
    printf ' \t%s\t%s\n' "$colour" \
           "$(clock_bar "$logged" "$expect" "$booked" "$CLOCK_BAR_CELLS")"
  fi

  # --- Rows 4-6: the shape of the week ----------------------------------------
  # Gated on its OWN cache, independently of the totals above. The two files
  # are written by different refreshers and either can be current while the
  # other is not; tying the chart to the totals would hide a perfectly good
  # chart because a booking lookup failed. It also means the chart still draws
  # when there is no booking at all - it just scales to the tallest day.
  dy_cache="${CLOCK_DAYS_CACHE:-$SB_CACHE_DIR/clock-week-days.json}"
  dy_week='-'; d1=''; total=0
  if [ -s "$dy_cache" ] \
     && [ $(( now - $(stat -f %m "$dy_cache" 2>/dev/null || echo 0) )) -le "$CLOCK_WEEK_STALE_AFTER" ]; then
    IFS=$'\t' read -r dy_week d1 d2 d3 d4 d5 d6 d7 <<CLOCKDAYS
$(jq -r '(.minutes // []) as $m
         | [ (.week // "-") ]
           + ([range(0; 7)] | map(($m[.] // 0) | if type == "number" then floor else 0 end))
         | @tsv' "$dy_cache" 2>/dev/null)
CLOCKDAYS
  fi
  [ "$dy_week" = "$iso" ] || d1=''
  case "$d1" in ''|*[!0-9]*) d1='' ;; esac
  [ -n "$d1" ] && total=$(( d1 + d2 + d3 + d4 + d5 + d6 + d7 ))

  # Seven empty columns and three rows to say "you have logged nothing yet" is
  # three rows spent saying nothing; the totals row above already said it in
  # one. Note this is NOT the same test as the cache being absent - that case
  # says nothing at all, because it has nothing to say.
  if [ -n "$d1" ] && [ "$total" -gt 0 ]; then
    { IFS= read -r ch_dur
      IFS= read -r ch_bar
      IFS= read -r ch_day
    } <<CLOCKCHART
$(clock_chart "$d1 $d2 $d3 $d4 $d5 $d6 $d7" "$dow" \
              "$(( ${booked:-0} / 5 ))")
CLOCKCHART
    printf ' \t%s\t%s\n' "$FG_DIM" "$ch_dur"
    # AQUA, and deliberately not the pace colour the bar above carries. That
    # bar is a verdict on the week; this is a description of it, and colouring
    # both the same would read as one four-row judgement rather than a summary
    # followed by its breakdown.
    printf ' \t%s\t%s\n' "$AQUA"   "$ch_bar"
    printf ' \t%s\t%s\n' "$FG_DIM" "$ch_day"
  fi

  # --- Rows 7-9: the three places the week is worked from ---------------------
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
  note="$HOME/drive/Thoughts/Notes/$iso.md"
  [ -f "$note" ] && printf '󰎞\t%s\t%s\t%s\n' "$VIOLET" \
                           "This week's Focus note" "open -a Obsidian '$note'"
}
