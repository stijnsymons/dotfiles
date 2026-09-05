#!/usr/bin/env bash
set -u

source "$CONFIG_DIR/colors.sh"
# Hover dispatch, before anything expensive: sketchybar invokes this same
# script for every subscribed event. Leaving the bar closes the card; any other
# event is a routine tick, which is also what polices a card left open by a
# missed mouse.exited.
card_dispatch clock

sketchybar --set "$NAME" label="$(date '+%a %d %b %H:%M')"

# --- keeping the card's per-day cache warm ------------------------------------
# cards/clock.sh draws the week as seven columns, one per day. Nothing else in
# the bar knows the per-day split: productive_week.sh fetches the same entries
# but only ever writes their SUM, so the breakdown has to be built somewhere,
# and it cannot be built on the click path - the card would then open on a
# network round trip, which is exactly the failure the whole cache layer exists
# to avoid.
#
# It is built here, on the clock's own 15s tick, because that is the tick the
# card belongs to. Everything below is skipped on all but one tick in 900.
#
# THE OBVIOUS BETTER HOME IS productive_week.sh, which already has these
# entries in a variable and would need one more jq to bucket them by date. That
# file is not this agent's to change; folding it in there and deleting this
# block would halve the API traffic for the same result.

CLOCK_DAYS_CACHE="${CLOCK_DAYS_CACHE:-$SB_CACHE_DIR/clock-week-days.json}"
CLOCK_DAYS_TTL="${CLOCK_DAYS_TTL:-900}"

# The rate limiter is a stamp of the last ATTEMPT, never the cache's own mtime.
# Touching the cache to mark an attempt would give stale content a fresh mtime
# and the card reads mtime for freshness - it would quote last week's split
# under this week's heading. Stamping separately also means a failed fetch
# backs off for the full TTL instead of retrying on every 15s tick against an
# API that is plainly not answering.
CLOCK_DAYS_STAMP="$SB_CACHE_DIR/clock-week-days.at"

clock_days_due() {
  local at=0
  # Braces rather than a trailing 2>/dev/null: bash applies the input redirect
  # first and reports a missing file on the stderr it still has, which would
  # leak "No such file or directory" into the bar's log on the very first tick
  # after a cache wipe. card.sh documents the same trap.
  { read -r at < "$CLOCK_DAYS_STAMP"; } 2>/dev/null
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  [ $(( $(date +%s) - at )) -ge "$CLOCK_DAYS_TTL" ]
}

# One HTTP call, and it reuses productive_week.sh's memoised person id rather
# than resolving it again - the CLI's `entries` subcommand costs a whoami round
# trip per invocation, which is a second request for a value that never
# changes. No id cached means productive_week.sh has never succeeded, and there
# is nothing useful this could do about that: skip, and the card simply draws
# without a chart.
#
# filter[after]/[before] and the Monday anchor are copied from
# productive_week.sh deliberately. The two files must agree about where the
# week starts or the columns here will not add up to the total the row above
# them prints.
clock_days_refresh() {
  local me mon today week entries
  me="$(cat "$SB_CACHE_DIR/productive-me" 2>/dev/null)"
  case "$me" in ''|*[!0-9]*) return 0 ;; esac

  mon="$(date -v-mon +%Y-%m-%d)"
  today="$(date +%Y-%m-%d)"
  week="$(date +%G-W%V)"

  entries="$(productive_api GET \
    "time_entries?filter%5Bperson_id%5D=${me}&filter%5Bafter%5D=${mon}&filter%5Bbefore%5D=${today}&page%5Bsize%5D=200")"
  printf '%s' "$entries" | jq -e '.data' >/dev/null 2>&1 || return 0

  # Bucketed into a fixed seven-slot array, Monday first, so the card does no
  # date arithmetic at all on the click path - it reads seven integers and
  # draws them. Days are parsed as UTC midnight throughout (jq's mktime is
  # gmtime's inverse), which keeps a DST boundary inside the week from shifting
  # an entry into the wrong column; productive_week.sh relies on the same.
  #
  # Write-then-rename, same reason as productive_week.sh: redirecting straight
  # into $CACHE truncates it first, so a failing jq would leave an empty file
  # that never passes `[ -s ]` again.
  printf '%s' "$entries" | jq -c --arg week "$week" --arg mon "$mon" '
      def day($s): $s | strptime("%Y-%m-%d") | mktime;
      day($mon) as $w0
      | reduce ( .data[]?.attributes | select(.date != null) ) as $a
          ([0,0,0,0,0,0,0];
           ( ((day($a.date) - $w0) / 86400) | floor ) as $i
           | if $i >= 0 and $i < 7 then .[$i] += ($a.time // 0) else . end)
      | {week: $week, from: $mon, minutes: .}' \
    > "$CLOCK_DAYS_CACHE.tmp.$$" 2>/dev/null \
    && mv "$CLOCK_DAYS_CACHE.tmp.$$" "$CLOCK_DAYS_CACHE" \
    || rm -f "$CLOCK_DAYS_CACHE.tmp.$$"
}

if clock_days_due; then
  date +%s > "$CLOCK_DAYS_STAMP"
  # Sourced only on the tick that actually fetches: productive_api.sh reads
  # zshrc.private through a grep and an eval, and that is not worth doing four
  # times a minute for a function that is called four times an hour.
  source "$CONFIG_DIR/plugins/productive_api.sh"
  # Backgrounded, because the label above is what this script exists for and a
  # curl with retries can sit for the better part of a minute. The clock would
  # visibly stop.
  #
  # The redirect is not tidiness. sketchybar reads the script's stdout, and a
  # background child that inherits it holds the pipe open after the parent
  # exits - the item would be treated as still running and its next tick
  # dropped. No lock is needed alongside it: the stamp was written BEFORE the
  # fork, so no later tick inside the TTL can start a second fetch.
  clock_days_refresh >/dev/null 2>&1 &
fi
