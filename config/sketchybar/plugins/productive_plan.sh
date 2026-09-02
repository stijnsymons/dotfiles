#!/usr/bin/env bash
# Refresh the cached view of THIS WEEK's planning: every booking you have, and
# the service to book time against for each.
#
#   productive_plan.sh
#   productive_plan.sh --plan <services.json> <usage.json>
#
# Two steps, because neither source alone is enough: `productive bookings`
# gives service ids with no project attribution, and the catalog maps projects
# to ids but not services to projects. One API call with
# include=deal.project closes the gap - a booked service belongs to a deal
# (budget), and the deal belongs to the project.
#
# Cached because this is planning data: it changes a few times a week, not
# every minute, and productive.sh already runs on a 60s tick.
#
# --plan runs the two joins on fixtures and prints the rows. The API calls are
# the half that cannot be tested; the joins are the half where a booking gets
# lost, so check.sh drives them through here. There is no network in that mode,
# so the trackable-service fallback is skipped - a row it would have filled
# comes out with the empty service_id it starts with, which is the case worth
# asserting anyway.

set -u
source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/plugins/productive_api.sh"

CACHE="${PRODUCTIVE_PLAN_CACHE:-$SB_CACHE_DIR/productive-plan.json}"
TTL="${PRODUCTIVE_PLAN_TTL:-3600}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}"

# Booked services -> one row each, carrying the budget (deal) they sit under.
#
# Keyed by SERVICE, not by project. `unique_by(.project_id)` collapsed two
# bookings on one project into one row, and that is a whole budget gone: this
# week vbrb-0001 is booked under both policy-rule-engine and healthcare-2dot0,
# and only the first survived - four bookings, three rows, no symptom. The row
# that did survive then resolved its timer from the most-used service for the
# PROJECT, so clicking it could book time against the budget you were not
# planned on, which is worse than the missing row.
plan_booked() { # services payload on stdin
  jq -c '
    (reduce (.included[]? | select(.type=="projects")) as $p ({}; .[$p.id] = $p.attributes.name)) as $proj
    | (reduce (.included[]? | select(.type=="deals")) as $d ({};
        .[$d.id] = { project_id: ($d.relationships.project.data.id // ""),
                     budget: ($d.attributes.name // "") })) as $deal
    | [ .data[]?
        | ($deal[ .relationships.deal.data.id // "" ] // {project_id:"",budget:""}) as $b
        | select($b.project_id != "")
        | { booked_service_id: .id,
            booked_role: (.attributes.name // ""),
            deal_id: (.relationships.deal.data.id // ""),
            budget: $b.budget,
            project_id: $b.project_id,
            project: ($proj[$b.project_id] // "") } ]
    | unique_by(.booked_service_id)'
}

# Your own booking history: service_id -> {project, budget, service} + how
# often you booked it.
#
# Three constraints, learned the hard way:
#   - the booked service is the ROLE you are planned on and is often not
#     time-trackable  -> 422 service_time_tracking_disabled
#   - a trackable service still has to be assigned to you
#     -> 422 "'Senior Architect' is not accessible to Stijn Symons"
#   - which leaves no reliable way to pick one from the service list alone
#
# So use your own history as ground truth: the services you have actually
# booked time against are by definition both trackable and accessible.
plan_usage() { # plan_usage <entries-json> <services-payload>
  jq -nc --argjson entries "$1" --argjson svc "$(printf '%s' "$2" | jq -c '{data, included}')" '
    ($svc.included // []) as $inc
    | (reduce ($inc[] | select(.type=="projects")) as $p ({}; .[$p.id] = $p.attributes.name)) as $proj
    | (reduce ($inc[] | select(.type=="deals"))    as $d ({}; .[$d.id] = ($d.relationships.project.data.id // ""))) as $deal
    | (reduce ($svc.data[]?) as $s ({};
        ($s.relationships.deal.data.id // "") as $did
        | .[$s.id] = { project: ($proj[ $deal[$did] // "" ] // ""),
                       project_id: ($deal[$did] // ""),
                       deal_id: $did,
                       service: ($s.attributes.name // "") })) as $map
    | [ $entries[]? | .service_id | select(. != null) ]
    | group_by(.)
    | map({ service_id: .[0], uses: length })
    | map(. + ($map[.service_id] // {project:"", project_id:"", deal_id:"", service:""}))
    | map(select(.project != ""))'
}

# One row per booking, each with the service its click should start.
#
# Preference order, most specific first, and it is a concatenation so the first
# candidate that exists wins: the booked service itself if you have tracked
# against it (history is what proves trackable AND accessible), else the
# most-used service on the SAME budget - which is what keeps two bookings on
# one project from both starting the same timer - else the most-used service
# anywhere on the project, right project and wrong budget, which is the old
# behaviour and only a last resort. on_budget records which of those happened,
# because plan_fill gets a better answer for the ones where it is false.
plan_rows() { # plan_rows <booked-json> <usage-json>
  jq -nc --argjson booked "$1" --argjson usage "$2" '
    $booked
    | map(. as $b
        | [ $usage[] | select(.service_id == $b.booked_service_id) ] as $self
        | ([ $usage[] | select(.deal_id == $b.deal_id) ]    | sort_by(-.uses)) as $onbudget
        | ([ $usage[] | select(.project_id == $b.project_id) ] | sort_by(-.uses)) as $onproject
        | (($self + $onbudget + $onproject) | .[0]) as $pick
        | { project: $b.project, project_id: $b.project_id,
            budget: $b.budget, deal_id: $b.deal_id,
            booked_role: $b.booked_role, booked_service_id: $b.booked_service_id,
            service_id: ($pick.service_id // ""), service: ($pick.service // ""),
            uses: ($pick.uses // 0),
            on_budget: (($pick.service_id // "") != "" and ($pick.deal_id // "") == $b.deal_id) })
    | sort_by(.project, .budget)'
}

# The bookings history could not place on their own budget: a project you have
# never tracked against (those used to be dropped outright by
# `select(($cand | length) > 0)`, so a newly booked project was simply not in
# your week - the one failure a planning card must not have), and the ones
# history could only answer from a DIFFERENT budget of the same project.
#
# Both get the same treatment: ask Productive for the trackable services on the
# project and take one on the booked budget. It is preferred over the
# cross-budget pick from history even though accessibility cannot be proven
# from here - only your own history proves that - because a start that 422s
# fails loudly into productive_start.sh's log, while a start on the wrong
# budget quietly books your time in the wrong place. Nothing on the budget at
# all leaves the row as plan_rows left it: the cross-budget service if there
# was one, otherwise no service, which the card renders dim and clicking it
# opens the timesheet rather than pretending.
#
# One CLI call per off-budget booking, and only in the hourly refresh.
plan_fill() { # plan_fill <rows-json>
  local rows="$1" pid deal svcs
  while IFS=$'\t' read -r pid deal; do
    [ -n "$pid" ] || continue
    svcs="$(productive services --project "$pid" --trackable 2>/dev/null)"
    printf '%s' "$svcs" | jq -e 'type == "array"' >/dev/null 2>&1 || continue
    rows="$(jq -nc --argjson rows "$rows" --argjson svcs "$svcs" \
                   --arg pid "$pid" --arg deal "$deal" '
      ([ $svcs[] | select((.budget_id // "") == $deal) ] | .[0]) as $pick
      | $rows
      | map(if .project_id == $pid and .deal_id == $deal and .on_budget == false
                 and ($pick != null)
            then . + { service_id: ($pick.id // ""), service: ($pick.role // ""),
                       uses: 0, on_budget: true }
            else . end)')"
  done <<PLANEOF
$(printf '%s' "$rows" | jq -r '[ .[] | select(.on_budget == false)
                                | { project_id, deal_id } ] | unique
                              | .[] | "\(.project_id)\t\(.deal_id)"')
PLANEOF
  printf '%s\n' "$rows"
}

if [ "${1:-}" = "--plan" ]; then
  plan_rows "$(plan_booked < "${2:?--plan needs a services payload}")" \
            "$(cat "${3:?--plan needs a usage array}")"
  exit 0
fi

# Fresh enough? Nothing to do.
if [ -s "$CACHE" ] && [ "$(( $(date +%s) - $(stat -f %m "$CACHE") ))" -lt "$TTL" ]; then
  exit 0
fi

MON="$(date -v-mon +%Y-%m-%d)"; SUN="$(date -v-mon -v+6d +%Y-%m-%d)"
BOOKINGS="$(productive bookings --from "$MON" --to "$SUN" 2>/dev/null)"
printf '%s' "$BOOKINGS" | jq -e 'type == "array"' >/dev/null 2>&1 || exit 0

IDS="$(printf '%s' "$BOOKINGS" | jq -r '[.[].service_id] | unique | join(",")')"
[ -n "$IDS" ] || { printf '[]\n' > "$CACHE"; exit 0; }

SVC="$(productive_api GET "services?filter%5Bid%5D=${IDS}&include=deal.project&page%5Bsize%5D=200")"
printf '%s' "$SVC" | jq -e '.data' >/dev/null 2>&1 || exit 0
BOOKED="$(printf '%s' "$SVC" | plan_booked)"

FROM="$(date -v-60d +%Y-%m-%d)"
ENTRIES="$(productive entries --from "$FROM" --to "$(date +%Y-%m-%d)" 2>/dev/null)"
printf '%s' "$ENTRIES" | jq -e 'type == "array"' >/dev/null 2>&1 || exit 0

USED_IDS="$(printf '%s' "$ENTRIES" | jq -r '[.[]?.service_id | select(. != null)] | unique | join(",")')"
[ -n "$USED_IDS" ] || { printf '[]\n' > "$CACHE"; exit 0; }

USED="$(productive_api GET "services?filter%5Bid%5D=${USED_IDS}&include=deal.project&page%5Bsize%5D=200")"
printf '%s' "$USED" | jq -e '.data' >/dev/null 2>&1 || exit 0

ROWS="$(plan_rows "$BOOKED" "$(plan_usage "$ENTRIES" "$USED")")"
printf '%s' "$ROWS" | jq -e 'type == "array"' >/dev/null 2>&1 || exit 0

# Write-then-rename: redirecting straight into $CACHE truncates it before the
# rows are built, so a failure leaves an empty file, `[ -s "$CACHE" ]` never
# passes again and this refetches (2 CLI + 2 API calls) every 60s forever.
plan_fill "$ROWS" > "$CACHE.tmp.$$" 2>/dev/null && mv "$CACHE.tmp.$$" "$CACHE" || rm -f "$CACHE.tmp.$$"
