#!/usr/bin/env bash
# Refresh the cached view of THIS WEEK's hours: minutes logged Monday-to-today
# against the minutes you are booked for Monday-to-Sunday. cards/clock.sh only
# ever reads this file - a card that waits on a network round trip to open is a
# card that feels broken.
#
# Booked minutes do NOT come from `productive bookings`. Its `minutes` field
# maps the API's `time`, which is null on every percentage-based booking, and
# in practice they all are. The figure that is always present is total_time
# over total_working_days - minutes per working day - so that is multiplied by
# the booking's working days that actually fall inside this week. The clipping
# is not decoration: a booking routinely starts before Monday and ends after
# Sunday, and filter[after]/[before] returns it whole.
#
# The person filter needs an id the CLI resolves per invocation with its own
# API call. It never changes, so it is memoised next to the week cache rather
# than bought again every refresh.
#
# Cached because a weekly total does not move minute to minute, and
# productive.sh's 60s tick must not spend three round trips on one.

set -u
source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/plugins/productive_api.sh"

CACHE="${PRODUCTIVE_WEEK_CACHE:-$SB_CACHE_DIR/productive-week.json}"
ME_CACHE="$SB_CACHE_DIR/productive-me"
TTL="${PRODUCTIVE_WEEK_TTL:-900}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}"

MON="$(date -v-mon +%Y-%m-%d)"; SUN="$(date -v-mon -v+6d +%Y-%m-%d)"
TODAY="$(date +%Y-%m-%d)"
WEEK="$(date +%G-W%V)"

# Freshness is mtime AND the week the file is about. Without the second test a
# Sunday-evening refresh stays "fresh" past midnight and the card would spend
# the first quarter of an hour of the new week quoting the old one's total.
if [ -s "$CACHE" ] && [ "$(( $(date +%s) - $(stat -f %m "$CACHE") ))" -lt "$TTL" ] \
   && [ "$(jq -r '.week // ""' "$CACHE" 2>/dev/null)" = "$WEEK" ]; then
  exit 0
fi

ENTRIES="$(productive entries --from "$MON" --to "$TODAY" 2>/dev/null)"
printf '%s' "$ENTRIES" | jq -e 'type == "array"' >/dev/null 2>&1 || exit 0
LOGGED="$(printf '%s' "$ENTRIES" | jq '[.[]?.minutes // 0] | add // 0')"

ME="$(cat "$ME_CACHE" 2>/dev/null)"
case "$ME" in
  ''|*[!0-9]*)
    ME="$(productive whoami 2>/dev/null | jq -r '.id // empty')"
    case "$ME" in ''|*[!0-9]*) exit 0 ;; esac
    printf '%s' "$ME" > "$ME_CACHE" ;;
esac

BOOKINGS="$(productive_api GET \
  "bookings?filter%5Bperson_id%5D=${ME}&filter%5Bafter%5D=${MON}&filter%5Bbefore%5D=${SUN}&page%5Bsize%5D=200")"
printf '%s' "$BOOKINGS" | jq -e '.data' >/dev/null 2>&1 || exit 0

# jq's gmtime puts the weekday at index 6, 0 = Sunday, so 1..5 is Mon-Fri.
# Dates are parsed as UTC midnight throughout, which keeps a DST boundary
# inside the week from shifting a day across the 86400 steps.
BOOKED="$(printf '%s' "$BOOKINGS" | jq --arg mon "$MON" --arg sun "$SUN" '
  def day($s): $s | strptime("%Y-%m-%d") | mktime;
  def wdays($a; $b):
    if $b < $a then 0
    else [ range(0; (($b - $a) / 86400 | floor) + 1)
           | ($a + . * 86400) | gmtime | .[6] | select(. >= 1 and . <= 5) ] | length
    end;
  day($mon) as $w0 | day($sun) as $w1
  | [ .data[]?.attributes
      | select((.canceled // false) == false)
      | select((.rejected // false) == false)
      | select((.draft // false) == false)
      | select((.total_working_days // 0) > 0)
      | ((.total_time // 0) / .total_working_days) as $per_day
      | wdays(([day(.started_on), $w0] | max); ([day(.ended_on), $w1] | min)) * $per_day ]
  | add // 0 | round' 2>/dev/null)"
case "$BOOKED" in ''|*[!0-9]*) exit 0 ;; esac

# Write-then-rename, same reason as productive_plan.sh: redirecting into $CACHE
# truncates it first, so a failing jq would leave an empty file that never
# passes `[ -s ]` again and refetches on every tick forever.
jq -nc --arg week "$WEEK" --arg from "$MON" --arg to "$SUN" --arg through "$TODAY" \
       --argjson logged "$LOGGED" --argjson booked "$BOOKED" \
  '{week: $week, from: $from, to: $to, through: $through,
    logged_minutes: $logged, booked_minutes: $booked}' \
  > "$CACHE.tmp.$$" 2>/dev/null && mv "$CACHE.tmp.$$" "$CACHE" || rm -f "$CACHE.tmp.$$"
