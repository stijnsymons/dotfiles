# shellcheck shell=bash
# Claude usage in detail: the weekly limit with its pace, seven days of token
# throughput as a chart, and the current 5-hour session.
#
# TWO SOURCES, AND THE CARD NEVER MIXES THEM UP. The percentages are the
# server's, mirrored to disk by ~/.claude/statusline-command.sh on every Claude
# Code response; the token chart is this machine's transcripts, counted locally.
# One is a share of a quota, the other is throughput. They are drawn as two
# separate blocks with their own headings for that reason - a "7%" and a "752M"
# on the same line would read as two views of one number, and they are not.
#
# WHAT THE CARD WILL NOT DO IS GUESS. Every row below is emitted only when the
# data behind it is present and in date; there is no placeholder percentage and
# no last-known-good. A card that is three rows tall because the statusline has
# not run today is telling the truth, and a card that is nine rows tall with two
# of them invented is not. plugins/claude_usage.sh owns the same rule for the
# bar item and this reuses its expiry logic verbatim (see CLAUDE_CAPTURE_TTL).
#
# THE MEDIUM. A row is one label in one monospace font, so the layout here is
# Unicode blocks and hand-counted spaces and nothing else. There is no real
# two-column alignment: "31% used  ·  resets in 15h 59m" is a single string
# whose parts happen to line up because every row is built to the same column
# pitch. Widen a label and the block chart shears - the pitch is CLAUDE_COL_W
# and it is the only thing holding the three chart rows together.

# The row text is measured and truncated by ellipsize() in plugins/fit.sh, which
# uses ${#text} and ${text:0:n}. Both count BYTES, not characters, unless the
# shell is in a UTF-8 locale - and under launchd it is not: `launchctl getenv
# LANG` is empty, the bar inherits no locale at all, and /bin/bash then reports
# ${#} of a 24-cell "████..." bar as 72.
#
# The consequence is not cosmetic. Against MAX_CHARS=64 that bar is cut at 21
# cells and given an ellipsis - and the 21 cells that survive are the FILLED
# ones, because the empty ░ cells are all at the right-hand end. Reproduced
# under `env -i`: a 95% bar rendered as 21 solid blocks and a "…", i.e. as a bar
# that is completely full. The card would be lying about the one number it
# exists to show. `env -i bash -c 's="████"; echo ${#s}'` prints 12, and prints
# 4 after this line.
#
# LC_ALL rather than LC_CTYPE because LC_ALL, if launchd or a wrapper ever sets
# it to C, overrides LC_CTYPE and the fix silently stops working. en_US.UTF-8
# rather than the bare "UTF-8" macOS also accepts: setlocale() rejects "UTF-8"
# for LC_ALL and falls straight back to C (measured - ${#s} stayed 12). It also
# pins %a to English three-letter day names, which is what the chart's 5-wide
# columns are cut for.
#
# This is an export, and it is deliberately visible to the rest of card.sh: the
# engine's ellipsize call happens AFTER this file is sourced, in the same
# process, and that call is the one that needs the locale.
export LC_ALL=en_US.UTF-8

# The statusline's export. Same expansion plugins/claude_usage.sh uses, which is
# the same one the patched statusline-command.sh writes with - `${VAR-...}`, not
# `${VAR:-...}`, because upstream documents the empty string as "disable the
# export" and a `:-` would send us looking in the default location for a file
# the user turned off.
CLAUDE_RL_FILE="${CLAUDE_STATUSLINE_RATE_LIMITS_FILE-${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/rate_limits.json}"

# Verbatim from plugins/claude_usage.sh, and it has to stay verbatim: the bar
# item and this card read the same file and must go blank at the same instant,
# or the bar shows "7%" beside a card that says the capture is too old to trust.
# Twelve hours is where "this is roughly where I am" turns into "this is
# yesterday's number" - the percentage can only decay upward while nothing is
# capturing, since the window keeps shedding its oldest usage.
CLAUDE_CAPTURE_TTL=43200

# The weekly window, in seconds, for the pace arithmetic. Copied from
# claude-statusline's calc_pace_pct (which passes 604800 for this bucket and
# 18000 for the 5-hour one) so the card and the statusline cannot disagree about
# how far into a window you are. There is no 5-hour equivalent here on purpose:
# the session row is already 46 characters wide and a pace clause would push it
# past the point where the popup is wider than the useful part of the screen -
# and a five-hour window is short enough to read off the countdown anyway.
CLAUDE_WEEK_WINDOW=604800

# 24 cells at the popup's 12pt FiraMono is ~173pt of bar, which is wide enough
# that one cell is a legible 4% and narrow enough that the bar is never the row
# that sets the popup's width - the chart rows at 41 characters are.
CLAUDE_BAR_CELLS=24

# The chart's column pitch: 5 characters of content, 1 of gutter, 7 columns =
# 41 characters. 5 is the smallest width that fits the widest value the token
# formatter can produce ("56.3M") without the value row overflowing into its
# neighbour and dragging the whole chart out of alignment.
CLAUDE_COL_W=5

# Colour by absolute usage. Monotone green -> yellow -> orange -> red, which is
# NOT what claude-statusline's build_bar does: that ramp goes green, orange at
# 50, yellow at 70, red at 90, i.e. it cools off in the middle. Matching its
# NUMBERS matters (a card and a statusline disagreeing by a point looks like a
# bug in one of them); matching a colour ordering that reads as "getting better
# at 70%" does not.
claude_pct_color() { # claude_pct_color <pct>
  if   [ "$1" -ge 90 ]; then printf '%s' "$RED"
  elif [ "$1" -ge 75 ]; then printf '%s' "$ORANGE"
  elif [ "$1" -ge 50 ]; then printf '%s' "$YELLOW"
  else                       printf '%s' "$GREEN"; fi
}

# Colour by how far ahead of the clock the spend is, and here the thresholds ARE
# claude-statusline's, because this is the number it renders its own bar from.
# Under pace is blue rather than green on purpose: green is "fine", and being
# 59 points under pace is not merely fine, it is a different state - the limit
# is not going to be the thing that stops you this week.
claude_pace_color() { # claude_pace_color <pct_minus_expected>
  if   [ "$1" -lt 0 ];  then printf '%s' "$BLUE"
  elif [ "$1" -le 20 ]; then printf '%s' "$GREEN"
  elif [ "$1" -le 50 ]; then printf '%s' "$YELLOW"
  else                       printf '%s' "$RED"; fi
}

# "6d 22h" / "15h 59m" / "48m". Two units at most, largest first: a countdown is
# read at a glance and "6d 22h 14m 3s" is not a glance.
claude_in() { # claude_in <seconds>
  local s=$1
  [ "$s" -le 0 ] && { printf 'any moment'; return; }
  if   [ "$s" -ge 86400 ]; then printf '%dd %dh' $(( s / 86400 )) $(( s % 86400 / 3600 ))
  elif [ "$s" -ge 3600 ];  then printf '%dh %02dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
  else                          printf '%dm' $(( s / 60 )); fi
}

# The same ladder as claude_in, but rounded DOWN to one unit and never to "0m":
# a capture from 40 seconds ago is "just now", not "0m ago", which reads like a
# broken clock.
claude_ago() { # claude_ago <seconds>
  local s=$1
  if   [ "$s" -ge 86400 ]; then printf '%dd ago'   $(( s / 86400 ))
  elif [ "$s" -ge 3600 ];  then printf '%dh ago'   $(( s / 3600 ))
  elif [ "$s" -ge 120 ];   then printf '%dm ago'   $(( s / 60 ))
  else                          printf 'just now'; fi
}

# Filled/empty blocks. U+2588 and U+2591, both in the Block Elements range that
# FiraMono Nerd Font covers, unlike the box-drawing pace marker this row used to
# carry - one unrenderable glyph in a 24-cell bar is 24 tofu boxes wide.
claude_bar() { # claude_bar <pct> <cells>
  local pct=$1 cells=$2 filled i out=''
  [ "$pct" -lt 0 ] && pct=0
  [ "$pct" -gt 100 ] && pct=100
  filled=$(( pct * cells / 100 ))
  # Floor, with one exception. 1% of 24 cells floors to zero, and an entirely
  # empty bar sitting under a row that says "1% used" reads as "no data" rather
  # than "barely any". Any usage at all gets a cell.
  [ "$filled" -eq 0 ] && [ "$pct" -gt 0 ] && filled=1
  # Braced, and it matters. `out="$out█"` looks fine and is not: in a UTF-8
  # locale bash reads the block character's bytes as part of the parameter NAME,
  # goes looking for a variable called "out█", and under card.sh's `set -u`
  # aborts the function with "unbound variable" - which does not blank the row,
  # it deletes it, because card.sh skips rows with empty text. The bar simply
  # was not there and nothing said why.
  i=0
  while [ "$i" -lt "$cells" ]; do
    if [ "$i" -lt "$filled" ]; then out="${out}█"; else out="${out}░"; fi
    i=$(( i + 1 ))
  done
  printf '%s' "$out"
}

# The three chart rows, built in one awk because they are one grid: the values,
# the bars and the day names have to be padded to the same pitch by the same
# code or they will not line up, and three separate passes is three chances for
# one of them to drift.
#
# stdin  : "<YYYY-MM-DD>\t<Abbrev>\t<tokens>", oldest first, from claude_usage.sh
# stdout : 4 lines - total, values, bars, day names
#
# The block characters live in a split() array, never in substr(): macOS awk is
# byte-oriented, so substr("▁▂▃▄▅▆▇█", 4, 1) returns one byte of a three-byte
# sequence and the whole chart row comes out as mojibake. Nothing here calls
# length() on a string containing one either, for the same reason.
claude_chart() {
  awk -F'\t' -v W="$CLAUDE_COL_W" '
    BEGIN { split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █", lv, " ") }
    { n++; day[n] = $2; val[n] = $3; total += $3; if ($3 > mx) mx = $3 }

    function sp(k,   s) { s = ""; while (k-- > 0) s = s " "; return s }

    # Centred, not right-aligned: the bars are centred in their column (a
    # 3-wide bar in a 5-wide cell), so a right-aligned value sits visibly off
    # its own bar. Overlong input is truncated rather than allowed to widen the
    # column, because one wide cell shifts every column after it.
    function mid(s, w,   l, left) {
      l = length(s)
      if (l >= w) return substr(s, 1, w)
      left = int((w - l) / 2)
      return sp(left) s sp(w - l - left)
    }

    # Five characters maximum, which is what sets CLAUDE_COL_W. One decimal only
    # between 10M and 1G: below that "5.4M" is already short, and above it the
    # integer form loses too much.
    function tok(x) {
      if (x >= 1000000000) return sprintf("%.1fG", x / 1000000000)
      if (x >= 100000000)  return sprintf("%dM",   x / 1000000)
      if (x >= 1000000)    return sprintf("%.1fM", x / 1000000)
      if (x >= 1000)       return sprintf("%dk",   x / 1000)
      return sprintf("%d", x)
    }

    END {
      # Ceiling, not floor: a day with real but small usage must not round to
      # the same height as a day with none. Level 0 is reserved for exactly
      # zero, and it draws a dot rather than ▁ - a lowest-block column and an
      # empty one are indistinguishable at 12pt, and the difference between
      # "barely used it" and "did not touch it" is the whole point of the chart.
      for (i = 1; i <= n; i++) {
        if (mx <= 0 || val[i] <= 0) { lvl = 0 }
        else {
          lvl = int((val[i] * 8 + mx - 1) / mx)
          if (lvl > 8) lvl = 8
          if (lvl < 1) lvl = 1
        }
        vrow = vrow (i > 1 ? " " : "") mid(tok(val[i]), W)
        brow = brow (i > 1 ? " " : "") (lvl ? " " lv[lvl] lv[lvl] lv[lvl] " " : "  ·  ")
        drow = drow (i > 1 ? " " : "") mid(day[i], W)
      }
      printf "%d\n%s\n%s\n%s\n", total, vrow, brow, drow
    }
  '
}

# The compact form for the chart heading. Same ladder as the bar item so the
# card's "752M this week" and the item's "~752M" agree to the digit.
claude_total() { # claude_total <tokens>
  awk -v n="$1" 'BEGIN {
    if      (n >= 1000000000) printf "%.1fG", n / 1000000000
    else if (n >= 1000000)    printf "%dM",   n / 1000000
    else if (n >= 1000)       printf "%dk",   n / 1000
    else                      printf "%d",    n
  }'
}

card_rows() {
  local now cap five_pct five_at seven_pct seven_at
  local age tint provenance colour expected above
  local ch_total ch_val ch_bar ch_day daily
  cap=''; five_pct=''; five_at=''; seven_pct=''; seven_at=''
  ch_total=''; ch_val=''; ch_bar=''; ch_day=''

  now="$(date +%s)"

  # One jq for the whole file, emitting "-" for anything missing rather than an
  # empty field. That is not tidiness: card.sh reads rows with IFS=$'\t', a tab
  # is IFS WHITESPACE, and bash collapses a run of it - so an empty field does
  # not read back as empty, it shifts every later field one column left. The
  # herdr card documents the same trap for its own separator. "-" fails the
  # digit test below and costs nothing.
  #
  # floor(), because used_percentage is a float and arrives with float noise -
  # the live file holds 7.000000000000001 - which bash arithmetic cannot take at
  # all. Flooring also matches claude-statusline's own `cut -d. -f1`.
  IFS=$'\t' read -r cap five_pct five_at seven_pct seven_at <<CLAUDEJQ
$(jq -r '
    def n: if type == "number" then floor else null end;
    [ (.captured_at? | n),
      (.rate_limits?.five_hour?.used_percentage?  | n),
      (.rate_limits?.five_hour?.resets_at?        | n),
      (.rate_limits?.seven_day?.used_percentage?  | n),
      (.rate_limits?.seven_day?.resets_at?        | n) ]
    | map(if . == null then "-" else tostring end) | @tsv
  ' "$CLAUDE_RL_FILE" 2>/dev/null)
CLAUDEJQ
  # A missing file, a malformed one, or a jq that is not installed leaves these
  # empty rather than "-", so both forms are rejected in one place instead of at
  # every use below. Spelled out five times rather than looped:
  # writing back to a name held in a variable needs eval in bash 3.2, and eval
  # on this hot a path buys nothing but a way to get it wrong.
  case "$cap"       in ''|*[!0-9]*) cap='' ;;       esac
  case "$five_pct"  in ''|*[!0-9]*) five_pct='' ;;  esac
  case "$five_at"   in ''|*[!0-9]*) five_at='' ;;   esac
  case "$seven_pct" in ''|*[!0-9]*) seven_pct='' ;; esac
  case "$seven_at"  in ''|*[!0-9]*) seven_at='' ;;  esac

  # --- Row 1: what the numbers below are, and how old they are ----------------
  # Provenance gets a whole row because it is the only thing that makes the rest
  # of the card safe to read. Every other row is conditional on this one's
  # verdict, and the verdict is stated rather than implied by an absence.
  if [ -z "$cap" ]; then
    tint="$FG_DIM"; provenance='Claude  ·  no capture yet'
  else
    age=$(( now - cap ))
    # A capture from the future is clock skew, not staleness - NTP stepping the
    # clock backwards, or the file arriving from a machine a few seconds ahead.
    # Clamping it to fresh is right; letting it fall through to the stale branch
    # would blank the limits and then describe them as captured "just now".
    [ "$age" -lt 0 ] && age=0
    if [ "$age" -le "$CLAUDE_CAPTURE_TTL" ]; then
      tint="$VIOLET"; provenance="Claude  ·  captured $(claude_ago "$age")"
    else
      # Stale is stated in the same words as the fresh case plus the reason the
      # rows are gone. "Limits hidden" rather than nothing at all: a card that
      # is suddenly four rows shorter with no explanation reads as a bug.
      tint="$ORANGE"
      provenance="Claude  ·  capture $(claude_ago "$age")  ·  limits hidden"
      # Both percentages, not just the weekly one. The 5-hour bucket has its own
      # tighter gate below, but a 13-hour-old capture cannot possibly hold a
      # live session anyway, and leaving it to be caught downstream means two
      # places that have to agree about what "too old" means.
      five_pct=''; seven_pct=''
    fi
  fi
  printf '󰚩\t%s\t%s\n' "$tint" "$provenance"

  # --- Rows 2-4: the weekly limit --------------------------------------------
  # resets_at is a second, independent expiry and not a redundant one. The TTL
  # catches "nothing has captured in a while"; this catches the harder case
  # where the window itself rolled over, which makes a capture from ten minutes
  # ago worthless rather than merely old - the number is not stale, it is
  # measuring a window that no longer exists. A rolled-over bucket is therefore
  # dropped outright, NOT downgraded to the no-countdown form below: that form
  # exists for a payload with no resets_at at all, where the window is unknown,
  # and reusing it here would quietly republish a dead window's percentage as if
  # it were the current one.
  [ -n "$seven_at" ] && [ "$now" -ge "$seven_at" ] && seven_pct=''
  [ -n "$five_at" ]  && [ "$now" -ge "$five_at" ]  && five_pct=''

  if [ -n "$seven_pct" ] && [ "$seven_pct" -le 100 ] && [ -n "$seven_at" ]; then
    colour="$(claude_pct_color "$seven_pct")"
    printf '󰄉\t%s\tWeekly  ·  %d%% used  ·  resets in %s\n' \
           "$colour" "$seven_pct" "$(claude_in $(( seven_at - now )))"
    # A blank icon is NOT an option here - see the IFS note above, an empty
    # first field shifts the colour into the glyph and the text into the colour,
    # and card.sh then drops the row for having no text. A single space is a
    # non-empty field and renders as the gutter this row wants.
    printf ' \t%s\t%s\n' "$colour" "$(claude_bar "$seven_pct" "$CLAUDE_BAR_CELLS")"

    # Pace: where the spend would be if it were even across the window. The
    # window start is resets_at minus its fixed length, which is how
    # claude-statusline derives the same figure - the API sends no start.
    expected=$(( (now - (seven_at - CLAUDE_WEEK_WINDOW)) * 100 / CLAUDE_WEEK_WINDOW ))
    [ "$expected" -lt 0 ] && expected=0
    [ "$expected" -gt 100 ] && expected=100
    above=$(( seven_pct - expected ))
    if [ "$above" -lt 0 ]; then
      printf '󰅐\t%s\t%d%% under pace  ·  %d%% expected by now\n' \
             "$(claude_pace_color "$above")" $(( -above )) "$expected"
    elif [ "$above" -eq 0 ]; then
      printf '󰅐\t%s\tExactly on pace  ·  %d%% expected by now\n' \
             "$(claude_pace_color "$above")" "$expected"
    else
      printf '󰅐\t%s\t%d%% over pace  ·  %d%% expected by now\n' \
             "$(claude_pace_color "$above")" "$above" "$expected"
    fi
  elif [ -n "$seven_pct" ] && [ "$seven_pct" -le 100 ]; then
    # Percentage but no reset instant at all: the figure is still the server's,
    # so it is shown - but without a window there is no countdown and no pace,
    # and those two rows are dropped rather than filled with a guessed window.
    printf '󰄉\t%s\tWeekly  ·  %d%% used\n' "$(claude_pct_color "$seven_pct")" "$seven_pct"
    printf ' \t%s\t%s\n' "$(claude_pct_color "$seven_pct")" \
           "$(claude_bar "$seven_pct" "$CLAUDE_BAR_CELLS")"
  fi

  # --- Rows 5-8: seven days of local throughput -------------------------------
  # Independent of everything above. This is the block that still says something
  # when the statusline has not run for a week, which is the whole reason the
  # transcript scan exists.
  daily="$("$CONFIG_DIR/plugins/claude_usage.sh" --daily 2>/dev/null)"
  if [ -z "$daily" ]; then
    printf '󰃰\t%s\tLast 7 days  ·  no local transcripts\n' "$FG_DIM"
  else
    { IFS= read -r ch_total
      IFS= read -r ch_val
      IFS= read -r ch_bar
      IFS= read -r ch_day
    } <<CLAUDECHART
$(printf '%s\n' "$daily" | claude_chart)
CLAUDECHART
    case "${ch_total:-0}" in ''|*[!0-9]*) ch_total=0 ;; esac
    if [ "$ch_total" -le 0 ]; then
      # Seven zero columns and a "0 tokens" heading is four rows spent saying
      # nothing. One row says it better.
      printf '󰃰\t%s\tLast 7 days  ·  no tokens recorded\n' "$FG_DIM"
    else
      printf '󰃰\t%s\tLast 7 days  ·  %s tokens\n' "$FG" "$(claude_total "$ch_total")"
      printf ' \t%s\t%s\n' "$FG_DIM" "$ch_val"
      printf ' \t%s\t%s\n' "$AQUA"   "$ch_bar"
      printf ' \t%s\t%s\n' "$FG_DIM" "$ch_day"
    fi
  fi

  # --- Row 9: the session you are in ------------------------------------------
  # resets_at is doing nearly all the gating here (it was applied above, with
  # the weekly one). The 5-hour window is at most five hours long, so "now <
  # resets_at" is a far tighter test than the 12h capture TTL and subsumes it:
  # if the window is still open, the percentage is measuring the session you are
  # actually in. It can only be LOW - usage since the capture is missing - and
  # row 1 already says how long ago that was.
  #
  # Unlike the weekly bucket there is no no-countdown fallback. A weekly figure
  # is worth something on its own; "you are 15% through some five-hour window,
  # no idea which" is not, so a payload without five_hour.resets_at drops the
  # row rather than printing half of it.
  if [ -n "$five_pct" ] && [ "$five_pct" -le 100 ] && [ -n "$five_at" ]; then
    printf '󰥔\t%s\tSession (5h)  ·  %d%% used  ·  resets in %s\n' \
           "$(claude_pct_color "$five_pct")" "$five_pct" \
           "$(claude_in $(( five_at - now )))"
  fi

  # THERE IS NO PER-MODEL ROW, and there is no way to add one. The mirrored
  # payload holds exactly five scalars - captured_at, and used_percentage plus
  # resets_at for five_hour and seven_day - because that is all
  # statusline-command.sh is handed on stdin. Nothing in it distinguishes Opus
  # from Sonnet from Fable, the transcripts carry per-model token counts but not
  # per-model QUOTA, and there is no local file and no unauthenticated endpoint
  # that does. A "Fable Weekly" row would have to be computed from the weekly
  # percentage by assuming a split, which is inventing a number, so the row is
  # absent rather than wrong. If a per-model bucket ever appears in the payload,
  # this is where it goes and the row budget in colors.sh has room for it.
}
