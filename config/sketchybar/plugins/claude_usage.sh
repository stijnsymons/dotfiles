#!/usr/bin/env bash
# Claude weekly usage for the bar. Two sources, one of them the real thing.
#
#   claude_usage.sh            -> "47%"  weekly limit used, when the capture is fresh
#                              -> "~688M" rolling-7d tokens, when it is not
#   claude_usage.sh --tokens   -> "688M"  force the token figure
#   claude_usage.sh --raw      -> the underlying number of whichever source won
#   claude_usage.sh --daily    -> 7 lines of "<YYYY-MM-DD>\t<Abbrev>\t<tokens>",
#                                 oldest first, for cards/claude.sh's sparkline.
#                                 Prints nothing and exits 1 when there is no
#                                 transcript to read.
#
# HOW TO TELL THE TWO APART AT A GLANCE: the units cannot collide. The real
# figure always ends in "%", the fallback always ends in k/M/G and is prefixed
# with "~" to mark it as the substitute signal rather than the quota. You never
# have to remember which mode the bar is in - the string says so.
#
# ---------------------------------------------------------------------------
# SOURCE 1 (preferred): ~/.cache/claude-statusline/rate_limits.json
#
# The same number ~/code/claude-statusline draws its "weekly:" bar from:
# .rate_limits.seven_day.used_percentage, i.e. percent of the Claude.ai
# subscription's 7-day limit consumed in the window that ends at .resets_at.
# Not tokens, not dollars, and not a rolling 7 days from now - it is a fixed
# window with a server-defined reset instant.
#
# That block reaches this machine only on the statusline command's STDIN, once
# per Claude Code response, and used to be written nowhere: grepping ~/.claude,
# ~/.claude.json, ~/Library/Caches/claude-cli-nodejs and Claude Desktop's Local
# Storage / IndexedDB for five_hour|seven_day|resets_at|utilization turned up
# only the statusline script's own source, and the session transcripts have no
# rate_limits key either. statusline-command.sh now mirrors it to the file above
# on every response, so source 1 exists - but only while Claude Code is being
# used, and only on a Pro/Max session (the patch emits nothing when .rate_limits
# is absent from the payload). Source 2 still has to stand on its own.
#
# THE WHOLE PAYLOAD, read off the live file - there is no third bucket and no
# per-model bucket, so anything a UI wants beyond these five scalars has to come
# from somewhere else or not be shown:
#
#   {"captured_at":1788640395,
#    "rate_limits":{"five_hour":{"used_percentage":33,"resets_at":1788647400},
#                   "seven_day":{"used_percentage":7.000000000000001,
#                                "resets_at":1788699600}}}
#
# used_percentage is a FLOAT and arrives with float noise (that 7.000000000000001
# is verbatim), so it is floored before it is shown or compared - never printed
# raw. resets_at is epoch seconds.
#
# SOURCE 2 (fallback): ~/.claude/projects/**/*.jsonl
#
# Total tokens Claude Code on THIS machine put through the API in the last
# rolling 7*24h - input + cache-creation + cache-read + output - across all
# sessions including subagent and sidechain transcripts, de-duplicated by API
# message id. Read out of the session transcripts, where every assistant entry
# carries the usage block the API returned, so the counts are the server's own
# rather than an estimate. A throughput figure, NOT a share of any quota, and
# blind to claude.ai in the browser and the desktop app.
#
# Neither source touches the network, an OAuth token, or the keychain.
#
# COST: source 1 is one stat + one jq, ~10ms. Source 2 is ~0.22s wall over 85
# files / 81MB (the current 8-day window).
#
# Source 2 IS CACHED NOW, and this comment used to say the opposite ("a second
# cache file would be more moving parts than the scan it saves"). cards/claude.sh
# is what changed the arithmetic. The bar's own tick is on a 300s timer where
# 0.22s is 0.07% duty and nobody is watching; the card is on the CLICK path,
# where 0.22s between pressing the item and the popup drawing is the difference
# between a card and a lag. So the scan writes $SB_CACHE_DIR/claude_usage_scan.tsv
# and the tick keeps it warm, which is what makes the click cost a stat and a cat.
set -u

# PATH repair before anything shells out. Under launchd the bar gets a PATH
# without /opt/homebrew/bin, so jq, rg and fd are all simply not found and this
# would print nothing forever with no symptom. colors.sh owns that repair (and
# $SB_CACHE_DIR) for every plugin; sourced only when reachable so the script
# still runs by hand from anywhere, with a minimal fallback for that case.
if [ -n "${CONFIG_DIR:-}" ] && [ -r "$CONFIG_DIR/colors.sh" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_DIR/colors.sh"
else
  case ":$PATH:" in *":/opt/homebrew/bin:"*) ;; *) PATH="/opt/homebrew/bin:$PATH" ;; esac
  export PATH
fi

RAW=0
FORCE_TOKENS=0
DAILY=0
for _arg in "$@"; do
  case "$_arg" in
    --raw)    RAW=1 ;;
    --tokens) FORCE_TOKENS=1 ;;
    --daily)  DAILY=1 ;;
  esac
done

# Print AND paint. sketchybar ignores a script's stdout - a plugin that only
# echoes leaves its item blank forever, which is exactly how this shipped the
# first time - so anything invoked as an item script has to --set its own label.
# $NAME is set by sketchybar and unset when run by hand, which is what keeps
# this usable as a plain command and as a bar plugin without a second wrapper.
#
# Called with no argument to CLEAR the label: a slot holding last week's number
# because today's lookup failed is worse than an empty one.
emit() {
  [ -n "${1:-}" ] && printf '%s\n' "$1"
  [ -n "${NAME:-}" ] && sketchybar --set "$NAME" label="${1:-}" 2>/dev/null
  exit 0
}

command -v jq >/dev/null 2>&1 || emit

# The statusline's export, NOT ours - it is the writer, we only read. Spelled
# with the same expansion the patched statusline-command.sh uses, character for
# character, including `${VAR-...}` rather than `${VAR:-...}`: upstream documents
# the EMPTY string as "disable the export", so a `:-` here would send us hunting
# in the default location for a file the user has explicitly turned off.
#
# It does not live in $SB_CACHE_DIR because it is not the bar's data. The
# statusline exports it for any out-of-process widget - waybar, tmux, polybar -
# and putting the one writer's output inside one reader's cache directory would
# make the bar look like the owner of a file it does not own and cannot rewrite.
# Mode 0600 in a 0700 directory, which is readable here only because the bar
# runs as the same user.
CACHE_FILE="${CLAUDE_STATUSLINE_RATE_LIMITS_FILE-${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/rate_limits.json}"

# Ours, by contrast: the transcript scan's result. Spelled with the same default
# as colors.sh so the script is still correct when run standalone, but
# $SB_CACHE_DIR wins when the bar has already exported it.
SCAN_FILE="${SB_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/sketchybar}/claude_usage_scan.tsv"

# How old a blob a READER will accept. Two of the bar item's 300s ticks, and
# deliberately not one: the tick refreshes unconditionally (see the warm below),
# so under normal operation the file is never more than 300s old and this
# expiry never fires at all. It exists for the case where the tick has stopped -
# a reload, a wedged item - and it is the CARD that must then decide the numbers
# are too old to reuse.
#
# It was 240 first, i.e. under the tick interval, on the theory that expiring
# early keeps the file fresh. It does the opposite. The tick would rebuild at
# t=0, a click at t=250 would find the blob expired and pay the full 0.38s
# itself, and its write then makes the t=300 tick see a 50s-old file and skip -
# so the refresh drifts, and roughly one click in five lands in the gap and
# rebuilds on the click path. Refreshing on a timer and expiring on a read are
# two different jobs and tying them to one number gets both wrong.
SCAN_TTL=600

# How long a capture stays believable. The percentage can only be wrong in one
# direction while nothing is capturing: usage does not grow when Claude Code is
# idle, but the window keeps shedding its oldest usage, so an old figure reads
# HIGH, never low. That decay is slow, so a few hours of staleness still informs
# - and while Claude Code is actually running the file is seconds old, because
# the statusline fires on every response. Twelve hours is where "this is roughly
# where I am" turns into "this is yesterday's number": long enough to survive a
# lunch, a meeting block or an evening, short enough that a figure from a
# previous working day never gets shown as if it were current.
CACHE_TTL=43200

# Rounded down, not nearest: claude-statusline renders this with `cut -d. -f1`,
# and the bar disagreeing with the statusline by a point would look like a bug
# in one of them.
weekly_pct() {
  [ -f "$CACHE_FILE" ] || return 1
  jq -er --argjson ttl "$CACHE_TTL" --argjson now "$(date +%s)" '
      (.captured_at        // empty) as $cap
    | (.rate_limits.seven_day.used_percentage // empty) as $pct
    | (.rate_limits.seven_day.resets_at       // empty) as $reset
    | select(($cap | type) == "number" and ($pct | type) == "number")
    # Two independent expiries. The TTL catches "nothing has captured in a
    # while". resets_at catches the harder case: the window rolled over, so the
    # stored percentage is not stale, it is measuring a window that no longer
    # exists. A capture from ten minutes ago can still be worthless this way.
    | select($now - $cap <= $ttl)
    | select(($reset | type) != "number" or $now < $reset)
    | select($pct >= 0 and $pct <= 100)
    | $pct
  ' "$CACHE_FILE" 2>/dev/null
}

# One pass over the transcripts, two answers.
#
# The bar wants a ROLLING 7*24h ending now; the card's sparkline wants SEVEN
# LOCAL CALENDAR DAYS, midnight to midnight. Those are different windows and
# neither can be derived from the other - the rolling one has a partial day at
# each end - so they have to be counted separately. But the scan is the entire
# cost of this file, and running it twice to answer two questions about the same
# 26MB of text would double it for nothing. Both are counted in one awk.
#
# Emits, tab-separated, in this order:
#   TOTAL <tokens>                        rolling 7*24h
#   DAY   <YYYY-MM-DD> <Abbrev> <tokens>  exactly 7 rows, oldest first
usage_scan() {
  local projects="$HOME/.claude/projects"
  [ -d "$projects" ] || return 1
  command -v fd >/dev/null 2>&1 || return 1
  command -v rg >/dev/null 2>&1 || return 1

  # The window, as a string. Both sides are zero-padded UTC ISO-8601, so awk's
  # lexicographic >= is a correct time comparison and no per-row date parsing is
  # needed - 9k rows through `date` would cost more than the whole scan.
  local cutoff
  cutoff="$(date -u -v-7d +%Y-%m-%dT%H:%M:%S 2>/dev/null)" || return 1
  [ -n "$cutoff" ] || return 1

  # The day boundaries, in the same UTC ISO-8601 alphabet, so the per-day
  # bucketing is the same free string compare as the rolling cutoff.
  #
  # `date -v-${k}d -v0H -v0M -v0S`, NOT (today's midnight - k*86400): a day is
  # not 86400 seconds twice a year, and a 7-day window straddles the DST switch
  # every March and October. Getting that wrong slides one boundary by an hour
  # and silently moves an hour of usage into the neighbouring bar - the kind of
  # error nobody would ever notice was there.
  #
  # LC_TIME=C on the label, so the abbreviation is always the three ASCII
  # characters the card's 5-wide columns are laid out for. Under a Dutch locale
  # %a is "zo"/"wo" and the whole chart shears.
  local bounds="" labels="" k ep
  for k in 6 5 4 3 2 1 0; do
    ep="$(date -v-"${k}"d -v0H -v0M -v0S +%s 2>/dev/null)" || return 1
    case "$ep" in ''|*[!0-9]*) return 1 ;; esac
    bounds="$bounds${bounds:+ }$(date -u -r "$ep" +%Y-%m-%dT%H:%M:%S 2>/dev/null)"
    labels="$labels${labels:+ }$(LC_TIME=C date -r "$ep" '+%Y-%m-%d|%a' 2>/dev/null)"
  done

  # --changed-within 8d, not 7d: a file's mtime is its LAST write, so anything
  # older than the window cannot hold an entry inside it. One day of slack
  # covers clock skew and the boundary. This is what keeps the scan off the
  # other ~48MB of transcripts sitting in that directory.
  #
  # rg pre-filters to the lines that could possibly match before jq sees them:
  # 81MB -> 26MB, 0.40s -> 0.18s. It is also the more correct reader. `cat`-ing
  # the files together would glue the last line of one onto the first line of
  # the next wherever a transcript lacks a trailing newline, silently destroying
  # both records; rg reads each file on its own and cannot do that.
  #
  # De-dup by message id is not optional. Claude Code appends one transcript
  # entry per content block of a response - text, then each tool_use - and every
  # one of them repeats the SAME full usage object. Measured here: 9104 usage
  # rows for 3773 real responses, so summing raw overstates by ~2.4x.
  fd -e jsonl --changed-within 8d -0 . "$projects" 2>/dev/null \
    | xargs -0 rg -NI --no-messages '"usage":\{' 2>/dev/null \
    | jq -rc 'select(.message.usage != null and .timestamp != null)
              | [ (.message.id // .requestId // "-"),
                  .timestamp,
                  ( (.message.usage.input_tokens                // 0)
                  + (.message.usage.cache_creation_input_tokens // 0)
                  + (.message.usage.cache_read_input_tokens     // 0)
                  + (.message.usage.output_tokens               // 0) ) ]
              | @tsv' 2>/dev/null \
    | awk -F'\t' -v cut="$cutoff" -v bounds="$bounds" -v labels="$labels" '
        BEGIN { nb = split(bounds, b, " "); split(labels, l, " ") }
        # The de-dup is the OUTER guard, not one term of an &&: it has to see
        # every row exactly once. Hang it off a condition that can short-circuit
        # and the second sighting of an id whose first sighting fell outside the
        # window is counted as if it were new.
        !seen[$1]++ {
          if ($2 >= cut) total += $3
          # Newest boundary first: nearly every row is from the last day or two,
          # so this exits on the first or second compare. A row older than b[1]
          # matches nothing and is dropped, which is correct - it is inside the
          # 8-day file filter but outside the 7-day chart.
          for (i = nb; i >= 1; i--) if ($2 >= b[i]) { day[i] += $3; break }
        }
        END {
          printf "TOTAL\t%d\n", total
          for (i = 1; i <= nb; i++) {
            split(l[i], p, "|")
            printf "DAY\t%s\t%s\t%d\n", p[1], p[2], day[i]
          }
        }'
}

# Scan, publish, and echo. The writer half.
usage_scan_refresh() {
  local out
  out="$(usage_scan)" || return 1
  [ -n "$out" ] || return 1

  # Temp file plus rename, not a redirect onto the live path. The card reads
  # this on the click path while the bar's 300s tick may be rewriting it, and a
  # reader that catches a truncated blob does not get an error - it gets a chart
  # with three days in it. A failed write is not fatal: the blob is an
  # optimisation, so the caller still gets its answer on stdout.
  if printf '%s\n' "$out" > "$SCAN_FILE.$$" 2>/dev/null; then
    mv -f "$SCAN_FILE.$$" "$SCAN_FILE" 2>/dev/null || rm -f "$SCAN_FILE.$$"
  fi
  printf '%s\n' "$out"
}

# The reader half: the published blob if it is still good, a fresh scan if not.
usage_scan_cached() {
  local age today
  today="$(date +%Y-%m-%d)"

  if [ -s "$SCAN_FILE" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$SCAN_FILE" 2>/dev/null || echo 0) ))
    # Two expiries, and the second one is the reason this is not just an mtime
    # check. The blob names the seven days it counted; crossing local midnight
    # does not change its mtime but does change which seven days "the last seven
    # days" means, so a cache written at 23:58 would keep drawing yesterday's
    # chart under today's heading until the TTL happened to lapse.
    if [ "$age" -ge 0 ] && [ "$age" -le "$SCAN_TTL" ] &&
       [ "$(awk -F'\t' '$1 == "DAY" { d = $2 } END { print d }' "$SCAN_FILE")" = "$today" ]; then
      cat "$SCAN_FILE"
      return 0
    fi
  fi

  usage_scan_refresh
}

weekly_tokens() {
  local total
  total="$(usage_scan_cached | awk -F'\t' '$1 == "TOTAL" { print $2; exit }')"
  case "$total" in ''|*[!0-9]*) return 1 ;; esac
  [ "$total" -gt 0 ] || return 1
  printf '%s\n' "$total"
}

# --- The card's per-day view ---
# Answered before anything else and with a bare exit, never through emit(): this
# mode is called by cards/claude.sh, not by sketchybar, and emit() would paint
# seven lines of TSV into the bar's label on its way out.
if [ "$DAILY" -eq 1 ]; then
  usage_scan_cached 2>/dev/null \
    | awk -F'\t' '$1 == "DAY" { printf "%s\t%s\t%s\n", $2, $3, $4; n++ }
                  END { exit(n ? 0 : 1) }'
  exit $?
fi

# Card plumbing, the same line every other card owner's plugin carries. It arms
# the stuck-card watchdog on the routine tick and closes the popup on
# mouse.exited, which is an exec - so it has to come before the scan below, or a
# pointer leaving the bar would pay 0.38s to warm a cache and then throw the
# process away.
#
# Guarded three ways, and each guard is load-bearing. $NAME keeps it off the
# --daily path, where SENDER is unset and `card.sh claude tick` would be this
# card asking the engine to reconsider a popup that is mid-render. command -v
# keeps it off the standalone path, where colors.sh was never sourced and the
# function does not exist. And card.sh's own tick is a no-op against an item
# that does not exist, so this is already safe on a bar where the claude item
# has not been renamed and wired up yet.
if [ -n "${NAME:-}" ] && command -v card_dispatch >/dev/null 2>&1; then
  card_dispatch claude
fi

# Keep the blob warm for the card, on the bar's own tick and only there.
#
# The tick is the one caller that is already on a timer and that nobody is
# waiting for, so it is where the 0.38s belongs. Unconditionally - _refresh, not
# _cached - because "refresh on a schedule" and "expire on a read" are different
# jobs; see SCAN_TTL for what tying them to one number did.
#
# It has to run BEFORE source 1 gets a chance to win, because source 1 wins most
# of the time - the statusline rewrites the rate-limit file on every Claude Code
# response - and emit() exits the process. Warming after it would mean the blob
# is only ever rebuilt on the days the capture is missing, i.e. approximately
# never, and the card's click would pay full price every single time.
#
# $NAME is the guard: sketchybar sets it for an item script and nothing else
# does, so running this by hand does not force a rescan it did not ask for.
[ -n "${NAME:-}" ] && usage_scan_refresh >/dev/null 2>&1

# --- Source 1 first, unless the caller asked for tokens outright ---
if [ "$FORCE_TOKENS" -eq 0 ]; then
  PCT="$(weekly_pct)" || PCT=""
  if [ -n "$PCT" ]; then
    if [ "$RAW" -eq 1 ]; then
      emit "$PCT"
    else
      emit "$(awk -v p="$PCT" 'BEGIN { printf "%d%%", int(p) }')"
    fi
  fi
fi

# --- Source 2 ---
TOKENS="$(weekly_tokens)" || TOKENS=""

# Anything missing means every source failed, and a bar item must never print an
# error string into the bar - a blank slot reads as "nothing to say", which is
# true. Zero is blank for the same reason: a week with no Claude Code usage has
# no number worth a slot.
[ -n "$TOKENS" ] || emit

[ "$RAW" -eq 1 ] && emit "$TOKENS"

# "~" only when this is standing in for the percentage. Asked for explicitly
# with --tokens it is not a fallback, so it is not marked as one.
PREFIX="~"
[ "$FORCE_TOKENS" -eq 1 ] && PREFIX=""

# Compact enough for a bar slot: 688M, 1.2G. One significant decimal only above
# a billion, where the integer form loses too much.
emit "$(awk -v n="$TOKENS" -v p="$PREFIX" 'BEGIN {
  if      (n >= 1000000000) printf "%s%.1fG", p, n / 1000000000
  else if (n >= 1000000)    printf "%s%dM",   p, n / 1000000
  else if (n >= 1000)       printf "%s%dk",   p, n / 1000
  else                      printf "%s%d",    p, n
}')"
