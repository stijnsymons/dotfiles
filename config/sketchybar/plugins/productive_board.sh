#!/usr/bin/env bash
# The shared data layer behind the Productive timer widget: ONE file,
# $SB_CACHE_DIR/productive-board.json, that both UIs (the sketchybar chips and
# panel, and the herdr.app mod) read, so they cannot disagree about what the
# week looks like.
#
#   productive_board.sh                         refresh (run from productive.sh's tick)
#   productive_board.sh --build <dir> <today> <monday>
#                                               build from fixtures in <dir>, print the board
#   productive_board.sh --code <budget> <candidate> <used codes>
#                                               the short-code rule, for check.sh
#
# The unit here is a BOOKING = project + budget (deal), because that is what time
# books against: vbrb-0001 under feature-flags and under partnership-2027 are two
# bookings, not one project. The exception is nove-internal, whose budget says
# nothing - there each SERVICE (mx-mana, mx-trai, mx-busdev) is its own booking.
# key = "<project>/<budget>", or the service name for internal.
#
# What is expensive and what is not. Entries + their service->budget join are one
# CLI call and one API call, so they are cached 15 minutes in a raw file. Everything
# else (the running timer, the plan, booked minutes, day start/end) is already a
# local file, so the board itself is REBUILT on every tick from those: it costs a
# few jq calls, and it means the running timer and the elapsed time are never more
# than a minute old without a second network call.
#
# Reuses, does not redo: productive_plan.sh --usage (service -> project/budget),
# productive_week.sh's booked_by_service (clipped booked minutes), productive.sh's
# productive.json (the running timer), productive_colors.sh (colours).

set -u
source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/plugins/productive_api.sh"
source "$CONFIG_DIR/plugins/productive_colors.sh"

CACHE="${PRODUCTIVE_BOARD_CACHE:-$SB_CACHE_DIR/productive-board.json}"
RAW="${PRODUCTIVE_BOARD_RAW:-$SB_CACHE_DIR/productive-board-raw.json}"
CODES="${PRODUCTIVE_CODES_CACHE:-$SB_CACHE_DIR/productive-codes.json}"
TTL="${PRODUCTIVE_BOARD_TTL:-900}"
ACTIVITY_DIR="${ACTIVITY_DIR:-$HOME/.local/state/activity}"
STALE_AFTER=420            # same as productive.sh: past this the timer cache is no evidence
TARGET=2400                # a 40h week, in minutes
PINNED="${PRODUCTIVE_PINNED:-mx-mana}"
MODEL_CALLS_MAX=2          # per refresh (x15s timeout): a first run with many new bookings must not outlive the 60s tick; the rest are asked next tick
export UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}"

# --- short codes --------------------------------------------------------------
# <budget> <candidate> <codes already taken this week> -> one unique 4-char code.
#
# The candidate (from the model, or from the cache) wins when it is well-formed
# and not taken. Otherwise the first four LETTERS of the budget stand in, padded
# with X when the budget is shorter, and if even that is taken the last char
# becomes a digit - uniqueness matters more than looking pretty, because two
# chips both reading "FLAG" are indistinguishable on a bar.
taken() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
pick_code() {
  local budget="$1" c="$2" fb n=2
  case "$c" in [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;; *) c="" ;; esac
  if [ -n "$c" ] && ! taken "$c" "$3"; then printf '%s' "$c"; return; fi
  fb="$(printf '%s' "$budget" | tr -cd 'A-Za-z' | tr 'a-z' 'A-Z' | cut -c1-4)"
  while [ "${#fb}" -lt 4 ]; do fb="${fb}X"; done
  c="$fb"
  while taken "$c" "$3"; do c="${fb:0:3}$n"; n=$((n + 1)); done
  printf '%s' "$c"
}

# <project> <budget> <taken> -> a code on stdout, or non-zero. Asked ONCE per new
# booking (the caller caches whatever comes back), never on a cached key. The
# timeout is the whole defence against a hung CLI: this runs inside a 60s tick.
ask_model() {
  command -v "${CLAUDE_BIN:-claude}" >/dev/null && command -v timeout >/dev/null || return 1
  local out
  out="$(timeout 15 "${CLAUDE_BIN:-claude}" -p --model haiku \
    "Reply with ONLY a recognisable 4-letter UPPERCASE code (A-Z) for the time-tracking booking below, abbreviated from the BUDGET name as a person would (style only, never reuse: customer-portal -> CPRT, invoice-export -> INVX). No other words. Do not use any of these codes: ${3:-none} CPRT INVX. Project: $1. Budget: $2." \
    </dev/null 2>/dev/null | head -1 | tr -d '[:space:]' | tr 'a-z' 'A-Z')"
  case "$out" in [A-Z][A-Z][A-Z][A-Z]) printf '%s' "$out" ;; *) return 1 ;; esac
}

# --- the pure part ------------------------------------------------------------
# Everything that decides what the board SAYS lives in this one jq program, so
# check.sh can drive it with fixtures. Colour and code need bash (the hash and
# the model), so they are merged in afterwards by board_make.
#
# Day minutes and the booking total include the running timer's CURRENT RUN
# (run_minutes, plus how old the cache is), not its elapsed_minutes: elapsed
# also contains earlier runs of the same entry, which `productive entries`
# already counts, so adding it would count them twice.
BOARD_JQ='
  def key($p;$b;$s):  if $p == $internal then $s else "\($p)/\($b)" end;
  def disp($p;$b;$s): if $p == $internal then $s else $b end;
  def n: (try tonumber catch 0);

  ($usage | map({(.service_id|tostring): .}) | add // {}) as $u
  # An entry whose service the join could not place keeps its minutes under an
  # "(unknown)" booking instead of vanishing: a total that silently drops hours
  # is the failure this widget exists to prevent.
  | ( $entries | map(select(.service_id != null) | . as $e
        | ($u[$e.service_id|tostring] // {project:"(unknown)", budget:"service \($e.service_id)",
                                          service:"service \($e.service_id)"}) as $s
        | { key: key($s.project;$s.budget;$s.service), project: $s.project,
            budget: disp($s.project;$s.budget;$s.service), service_id: ($e.service_id|tostring),
            date: $e.date, id: ($e.id|n), minutes: ($e.minutes // 0) }) ) as $ents0
  | ( if $state == "running" then
        [ $timer | { key: key(.project;.budget;.service), project: .project,
                     budget: disp(.project;.budget;.service), service_id: ((.service_id // "")|tostring),
                     date: $today, id: 999999999999,
                     minutes: ((.run_minutes // .elapsed_minutes // 0) + $age) } ]
      else [] end ) as $run
  | ($ents0 + $run) as $ents

  # The plan, one row per booking: a deal booked on two services is one booking.
  # Booked minutes never apply to internal work (it has no budget to book against).
  | ( if $week.week == $weekid then ($week.booked_by_service // {}) else {} end ) as $bysvc
  | ( $plan | map( (if .service != "" then .service else .booked_role end) as $svc
        | { key: key(.project;.budget;$svc), project: .project, budget: disp(.project;.budget;$svc),
            service_id: (.service_id // ""), booked_service_id: .booked_service_id } )
      | group_by(.key)
      | map({ key: .[0].key, project: .[0].project, budget: .[0].budget,
              service_id: ([.[].service_id | select(. != "")] | .[0] // ""),
              booked: ( if .[0].project == $internal then null
                        else ([.[].booked_service_id | select(. != null) | $bysvc[.] // empty]
                              | if length == 0 then null else add end) end ) }) ) as $pg

  | ( $ents | group_by(.key)
      | map({ key: .[0].key, project: .[0].project, budget: .[0].budget,
              tracked: (map(.minutes) | add),
              top_svc: (group_by(.service_id) | map({s: .[0].service_id, m: (map(.minutes) | add)})
                        | max_by(.m).s),
              last: (max_by([.date, .id]) | [.date, .id]) }) ) as $tr

  | ( ([$pg[].key] + [$tr[].key]) | unique ) as $keys
  | ( $keys | map( . as $k
        | ($pg | map(select(.key == $k)) | .[0]) as $p
        | ($tr | map(select(.key == $k)) | .[0]) as $t
        | { key: $k,
            project: ($p.project // $t.project), budget: ($p.budget // $t.budget),
            service_id: ( ($p.service_id // "") | if . == "" then ($t.top_svc // "") else . end ),
            tracked_minutes: ($t.tracked // 0), booked_minutes: ($p.booked // null),
            pinned: ($k == $pinned), last: ($t.last // ["", 0]) } )
      | sort_by([-.tracked_minutes, .key]) ) as $bk

  # Chips: the 3 most recently tracked bookings that can actually be started,
  # then the pinned one last. Recency is this week only (the week is the one
  # fetch we make); on a Monday morning the slots fall back to tracked-desc and
  # then plan order, which is a fair "what you are probably about to do".
  | ( [ $bk[] | select(.pinned | not) | select(.service_id != "") ]
      | sort_by([.last[0], .last[1], .tracked_minutes]) | reverse | .[:3] | map(.key) ) as $recent
  | ( $recent + [ $bk[] | select(.pinned) | .key ] ) as $chips

  | ( $ents | map(select(.minutes > 0)) | group_by(.date)
      | map({(.[0].date): (group_by(.key) | map({(.[0].key): (map(.minutes) | add)}) | add)})
      | add // {} ) as $bydate
  | ( $bk | map(.tracked_minutes) | add // 0 ) as $total

  | { week: $weekid, from: $mon,
      to: ((($mon | strptime("%Y-%m-%d") | mktime) + 6 * 86400) | strftime("%Y-%m-%d")),
      generated_at: $now, state: $state,
      running: ( if $state == "running" then
                   { key: key($timer.project;$timer.budget;$timer.service),
                     service_id: (($timer.service_id // "")|tostring),
                     elapsed_minutes: (($timer.elapsed_minutes // 0) + $age),
                     started_at: ($timer.started_at // null) }
                 else null end ),
      total_minutes: $total, target_minutes: $target,
      overtime_minutes: ([$total - $target, 0] | max),
      bookings: ( $bk | map(del(.last)
                    | . + { name: "\(.project) · \(.budget)", chip: (.key as $k | $chips | any(. == $k)) }) ),
      chips: $chips,
      days: [ range(0; 7)
              | (($mon | strptime("%Y-%m-%d") | mktime) + . * 86400) as $t
              | ($t | strftime("%Y-%m-%d")) as $d
              | { date: $d, dow: ($t | strftime("%a")),
                  start: ($act[$d].start // null), end: ($act[$d].end // null),
                  minutes: ($bydate[$d] // {}) } ] }'

# First and last sample with less than 5 minutes idle, from 05:00 on (earlier
# samples are the machine ticking over while you sleep). stdin: ndjson samples.
ACT_JQ='map(select(.idle_s != null and .idle_s < 300 and ((.ts[11:13] | tonumber) >= 5)))
        | group_by(.ts[0:10])
        | map({(.[0].ts[0:10]): {start: (map(.ts[11:16]) | min), end: (map(.ts[11:16]) | max)}})
        | add // {}'

board_activity() { # <monday> -> {date: {start,end}}
  local i d files=()
  for i in 0 1 2 3 4 5 6; do
    d="$(date -j -v+${i}d -f %Y-%m-%d "$1" +%F 2>/dev/null)" || continue
    [ -r "$ACTIVITY_DIR/$d.ndjson" ] && files+=("$ACTIVITY_DIR/$d.ndjson")
  done
  [ "${#files[@]}" -gt 0 ] || { printf '{}'; return; }
  cat "${files[@]}" | jq -sc "$ACT_JQ" 2>/dev/null || printf '{}'
}

# idle / running / unknown, the same rule productive.sh renders by: no parseable
# JSON, or JSON older than STALE_AFTER, is UNKNOWN and never "idle" - a dropped
# Wi-Fi packet must not fake the red alarm here either.
timer_state() { # <json> <age>
  printf '%s' "$1" | jq -e 'has("running")' >/dev/null 2>&1 || { echo unknown; return; }
  [ "${2:-0}" -le "$STALE_AFTER" ] || { echo unknown; return; }
  [ "$(printf '%s' "$1" | jq -r '.running')" = "true" ] && echo running || echo idle
}

# Needs: ENTRIES USAGE PLAN TIMER WEEK ACT (json), MON TODAY NOW AGE, LIVE (0/1).
# LIVE gates the two side effects - asking the model and persisting the codes -
# so --build is hermetic.
board_make() {
  local TAB=$'\t' NL=$'\n'
  local state weekid core key budget project cached cand code taken_codes="" calls=0 dirty=0 asked codes meta=""
  weekid="$(date -j -f %Y-%m-%d "$MON" +%G-W%V)"
  state="$(timer_state "$TIMER" "$AGE")"
  printf '%s' "$TIMER" | jq -e 'type == "object"' >/dev/null 2>&1 || TIMER='{}'

  core="$(jq -nc --argjson entries "$ENTRIES" --argjson usage "$USAGE" --argjson plan "$PLAN" \
      --argjson timer "$TIMER" --argjson week "$WEEK" --argjson act "$ACT" \
      --arg mon "$MON" --arg today "$TODAY" --arg now "$NOW" --arg weekid "$weekid" \
      --arg state "$state" --argjson age "$((AGE / 60))" --argjson target "$TARGET" \
      --arg internal "$INTERNAL_PROJECT" --arg pinned "$PINNED" "$BOARD_JQ")" || return 1

  codes="$(cat "$CODES" 2>/dev/null)"
  printf '%s' "$codes" | jq -e 'type == "object"' >/dev/null 2>&1 || codes='{}'

  # In board order (tracked desc), so the booking you work on most gets first
  # pick of its code when two would collide.
  while IFS=$'\t' read -r key project budget; do
    [ -n "$key" ] || continue
    cached="$(printf '%s' "$codes" | jq -r --arg k "$key" '.[$k] // empty')"
    cand="$cached"; asked=0
    # Internal services are named mx-<what>; the <what> IS the code people know
    # (mx-mana -> MANA). The model only ever saw "nove-internal" and answered NINT.
    if [ "$project" = "$INTERNAL_PROJECT" ]; then
      budget="${budget#mx-}"; cand="$(printf '%s' "$budget" | tr -cd 'A-Za-z' | tr 'a-z' 'A-Z' | cut -c1-4)"; cached="$cand"
    elif [ -z "$cached" ] && [ "$LIVE" = 1 ] && [ "$calls" -lt "$MODEL_CALLS_MAX" ]; then
      calls=$((calls + 1)); asked=1
      cand="$(ask_model "$project" "$budget" "$taken_codes")" || cand=""
    fi
    code="$(pick_code "$budget" "$cand" "$taken_codes")"
    # Cached even when the model failed and the fallback stood in: "once per new
    # booking" is the contract, and retrying a dead network every minute is not.
    # Delete the key from productive-codes.json to ask again. A booking the call
    # cap skipped is NOT cached (it shows the fallback for now and is asked on a
    # later tick); caching it would make "the rest are asked next tick" false.
    { [ "$code" = "$cached" ] || { [ -z "$cached" ] && [ "$asked" = 0 ]; }; } || { codes="$(printf '%s' "$codes" | jq -c --arg k "$key" --arg c "$code" '.[$k] = $c')"; dirty=1; }
    taken_codes="$taken_codes $code"
    meta="$meta$key${TAB}$code${TAB}$(booking_hex "$key")${NL}"
  done <<BOARDEOF
$(printf '%s' "$core" | jq -r '.bookings[] | [.key, .project, .budget] | @tsv')
BOARDEOF

  if [ "$LIVE" = 1 ] && [ "$dirty" = 1 ]; then
    printf '%s\n' "$codes" > "$CODES.tmp.$$" && mv "$CODES.tmp.$$" "$CODES" || rm -f "$CODES.tmp.$$"
  fi

  printf '%s' "$core" | jq --argjson meta "$(printf '%s' "$meta" | jq -Rnc '[inputs | select(length > 0) | split("\t") | {(.[0]): {code: .[1], color: .[2]}}] | add // {}')" \
    '.bookings |= map(. + $meta[.key])'
}

# --- a past/future week, for the panel's week switcher -------------------------
# <offset> in weeks from this one (0 this week, -1 last week, +1 next). Builds the
# board for that week and prints it; caches non-current weeks (their entries no
# longer change) for TTL. The plan and booked minutes are this-week caches, so the
# BOARD_JQ guard leaves them empty on other weeks: tracked hours and day start/end
# (from the local activity log) are what another week shows. No running timer there,
# so state is forced "idle" - "unknown" would make the panel cry "no data".
build_week() {
  local off="$1" step mon sun today end weekid wc out
  if [ "$off" -lt 0 ]; then step="-v-$(( -off ))w"; else step="-v+${off}w"; fi
  mon="$(date -v-mon $step +%F)"
  sun="$(date -j -v+6d -f %F "$mon" +%F)"
  today="$(date +%F)"
  weekid="$(date -j -f %F "$mon" +%G-W%V)"
  # end of the fetch window: the week's Sunday, clamped to today for a week in progress.
  if [ "$sun" \> "$today" ]; then end="$today"; else end="$sun"; fi

  if [ "$off" = 0 ]; then
    [ -s "$CACHE" ] && [ "$(jq -r '.week//""' "$CACHE" 2>/dev/null)" = "$weekid" ] && { cat "$CACHE"; return 0; }
  else
    wc="$SB_CACHE_DIR/productive-board-$weekid.json"
    [ -s "$wc" ] && [ "$(( $(date +%s) - $(stat -f %m "$wc") ))" -lt "$TTL" ] && { cat "$wc"; return 0; }
  fi

  productive_creds || true
  local E='[]' U='[]' IDS S
  if [ ! "$mon" \> "$today" ]; then   # a future week has no entries to fetch
    E="$(productive entries --from "$mon" --to "$end" 2>/dev/null)"
    printf '%s' "$E" | jq -e 'type == "array"' >/dev/null 2>&1 || E='[]'
    IDS="$(printf '%s' "$E" | jq -r '[.[]?.service_id | select(. != null)] | unique | join(",")')"
    if [ -n "$IDS" ]; then
      S="$(productive_api GET "services?filter%5Bid%5D=${IDS}&include=deal.project&page%5Bsize%5D=200")"
      printf '%s' "$S" | jq -e '.data' >/dev/null 2>&1 \
        && U="$("$CONFIG_DIR/plugins/productive_plan.sh" --usage <(printf '%s' "$E") <(printf '%s' "$S"))" || U='[]'
      printf '%s' "$U" | jq -e 'type == "array"' >/dev/null 2>&1 || U='[]'
    fi
  fi

  ENTRIES="$E"; USAGE="$U"
  TIMER='{"running":false}'; AGE=0                 # no live timer on another week -> state "idle", not "unknown"
  PLAN="$(cat "${PRODUCTIVE_PLAN_CACHE:-$SB_CACHE_DIR/productive-plan.json}" 2>/dev/null)"
  printf '%s' "$PLAN" | jq -e 'type == "array"' >/dev/null 2>&1 || PLAN='[]'
  WEEK="$(cat "${PRODUCTIVE_WEEK_CACHE:-$SB_CACHE_DIR/productive-week.json}" 2>/dev/null)"
  printf '%s' "$WEEK" | jq -e 'type == "object"' >/dev/null 2>&1 || WEEK='{}'
  ACT="$(board_activity "$mon")"
  MON="$mon"; TODAY="$end"; NOW="$(date +%Y-%m-%dT%H:%M:%S)"; LIVE=0
  out="$(board_make)" || return 1
  if [ "$off" != 0 ]; then printf '%s' "$out" > "$wc.tmp.$$" && mv "$wc.tmp.$$" "$wc" || rm -f "$wc.tmp.$$"; fi
  printf '%s' "$out"
}

case "${1:-}" in
  --code) pick_code "${2:-}" "${3:-}" "${4:-}"; echo; exit 0 ;;
  --week) build_week "${2:-0}"; exit $? ;;
  --build)
    D="${2:?--build needs a fixture dir}"; TODAY="${3:?--build needs today}"; MON="${4:?--build needs the monday}"
    ENTRIES="$(cat "$D/entries.json")"; USAGE="$(cat "$D/usage.json")"; PLAN="$(cat "$D/plan.json")"
    TIMER="$(cat "$D/timer.json")"; WEEK="$(cat "$D/week.json")"
    ACTIVITY_DIR="$D/activity"; ACT="$(board_activity "$MON")"; CODES="$D/codes.json"
    NOW="${TODAY}T12:00:00"; AGE=0; LIVE=0
    board_make
    exit $? ;;
esac

# --- live refresh -------------------------------------------------------------
# One refresher at a time: a tick that lands while a slow model call from the
# previous one is still running would otherwise double the calls. mkdir is the
# atomic test; a lock older than two minutes is a crashed run, not a live one.
LOCK="$SB_CACHE_DIR/productive-board.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  [ "$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))" -gt 120 ] || exit 0
  rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
productive_creds || true
MON="$(date -v-mon +%Y-%m-%d)"; TODAY="$(date +%Y-%m-%d)"; WEEKID="$(date +%G-W%V)"
LIVE=1; NOW="$(date +%Y-%m-%dT%H:%M:%S)"

# Raw weekly entries: refetch past the TTL or when the file is about another week.
fresh=0
if [ -s "$RAW" ] && [ "$(jq -r '.week // ""' "$RAW" 2>/dev/null)" = "$WEEKID" ] \
   && [ "$(( $(date +%s) - $(stat -f %m "$RAW") ))" -lt "$TTL" ]; then fresh=1; fi
# A timer that stopped since the fetch has its finished run missing from the cached
# entries and the live add-on is gone too: the total would dip by that run for up
# to 15 minutes. So a running -> not-running change refetches (once per stop).
TIMER_FILE="${PRODUCTIVE_CACHE:-$SB_CACHE_DIR/productive.json}"
if [ "$fresh" = 1 ] && [ -s "$TIMER_FILE" ] && [ "$(jq -r '.timer // ""' "$RAW" 2>/dev/null)" = running ] \
   && [ "$(jq -r '.running // false' "$TIMER_FILE" 2>/dev/null)" != true ]; then fresh=0; fi

if [ "$fresh" = 0 ]; then
  E="$(productive entries --from "$MON" --to "$TODAY" 2>/dev/null)"
  if printf '%s' "$E" | jq -e 'type == "array"' >/dev/null 2>&1; then
    IDS="$(printf '%s' "$E" | jq -r '[.[]?.service_id | select(. != null)] | unique | join(",")')"
    U='[]'
    if [ -n "$IDS" ]; then
      S="$(productive_api GET "services?filter%5Bid%5D=${IDS}&include=deal.project&page%5Bsize%5D=200")"
      printf '%s' "$S" | jq -e '.data' >/dev/null 2>&1 \
        && U="$("$CONFIG_DIR/plugins/productive_plan.sh" --usage <(printf '%s' "$E") <(printf '%s' "$S"))" \
        || U=""
    fi
    # No usage join means the entries cannot be told apart by budget, and caching
    # them without it would show them all as "(unknown)" for 15 minutes.
    if printf '%s' "$U" | jq -e 'type == "array"' >/dev/null 2>&1; then
      jq -nc --arg week "$WEEKID" --arg timer "$(jq -r 'if .running == true then "running" else "idle" end' "$TIMER_FILE" 2>/dev/null)" \
         --argjson entries "$E" --argjson usage "$U" \
         '{week: $week, timer: $timer, entries: $entries, usage: $usage}' > "$RAW.tmp.$$" \
        && mv "$RAW.tmp.$$" "$RAW" || rm -f "$RAW.tmp.$$"
    fi
  fi
fi

# A failed refetch falls back to whatever raw file exists (any age, same week),
# then to nothing: the board still shows the plan and the running timer.
if [ "$(jq -r '.week // ""' "$RAW" 2>/dev/null)" = "$WEEKID" ]; then
  ENTRIES="$(jq -c '.entries' "$RAW")"; USAGE="$(jq -c '.usage' "$RAW")"
else
  ENTRIES='[]'; USAGE='[]'
fi

TIMER="$(cat "$TIMER_FILE" 2>/dev/null)"
if [ -f "$TIMER_FILE" ]; then AGE=$(( $(date +%s) - $(stat -f %m "$TIMER_FILE") )); else AGE=0; TIMER='{}'; fi
PLAN="$(cat "${PRODUCTIVE_PLAN_CACHE:-$SB_CACHE_DIR/productive-plan.json}" 2>/dev/null)"
printf '%s' "$PLAN" | jq -e 'type == "array"' >/dev/null 2>&1 || PLAN='[]'
WEEK="$(cat "${PRODUCTIVE_WEEK_CACHE:-$SB_CACHE_DIR/productive-week.json}" 2>/dev/null)"
printf '%s' "$WEEK" | jq -e 'type == "object"' >/dev/null 2>&1 || WEEK='{}'
ACT="$(board_activity "$MON")"

# Write-then-rename, as the plan and week caches do: both UIs read this file on
# every repaint and must never see it half-written.
board_make > "$CACHE.tmp.$$" 2>/dev/null && jq -e . "$CACHE.tmp.$$" >/dev/null 2>&1 \
  && mv "$CACHE.tmp.$$" "$CACHE" || rm -f "$CACHE.tmp.$$"
