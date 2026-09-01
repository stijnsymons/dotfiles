#!/usr/bin/env bash
# Refresh the cached view of THIS WEEK's planning: which projects you are
# booked on, and the service to book time against for each.
#
# Two steps, because neither source alone is enough: `productive bookings`
# gives service ids with no project attribution, and the catalog maps projects
# to ids but not services to projects. One API call with
# include=deal.project closes the gap - a booked service belongs to a deal
# (budget), and the deal belongs to the project.
#
# Cached because this is planning data: it changes a few times a week, not
# every minute, and productive.sh already runs on a 60s tick.

set -u
source "$CONFIG_DIR/plugins/productive_api.sh"

CACHE="${PRODUCTIVE_PLAN_CACHE:-$HOME/.cache/sketchybar/productive-plan.json}"
TTL="${PRODUCTIVE_PLAN_TTL:-3600}"
export PATH="$HOME/code/assistant/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}"

mkdir -p "$(dirname "$CACHE")"

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

# Booked service -> project id + name.
PROJECTS="$(printf '%s' "$SVC" | jq -c '
  (reduce (.included[]? | select(.type=="projects")) as $p ({}; .[$p.id] = $p.attributes.name)) as $proj
  | (reduce (.included[]? | select(.type=="deals"))    as $d ({}; .[$d.id] = ($d.relationships.project.data.id // ""))) as $deal
  | [ .data[]? | ($deal[ .relationships.deal.data.id // "" ] // "") as $pid
      | select($pid != "")
      | { project_id: $pid, project: ($proj[$pid] // ""), booked_role: (.attributes.name // "") } ]
  | unique_by(.project_id)')"

# Resolve a service you can actually BOOK against, per project.
#
# Three constraints, learned the hard way:
#   - the booked service is the ROLE you are planned on and is often not
#     time-trackable  -> 422 service_time_tracking_disabled
#   - a trackable service still has to be assigned to you
#     -> 422 "'Senior Architect' is not accessible to Stijn Symons"
#   - which leaves no reliable way to pick one from the service list alone
#
# So use your own history as ground truth: the services you have actually
# booked time against are by definition both trackable and accessible. Recent
# entries give the service ids, one API call maps those to projects, and the
# most-used service for a project is the one to start a timer on.
FROM="$(date -v-60d +%Y-%m-%d)"
ENTRIES="$(productive entries --from "$FROM" --to "$(date +%Y-%m-%d)" 2>/dev/null)"
printf '%s' "$ENTRIES" | jq -e 'type == "array"' >/dev/null 2>&1 || exit 0

USED_IDS="$(printf '%s' "$ENTRIES" | jq -r '[.[]?.service_id | select(. != null)] | unique | join(",")')"
[ -n "$USED_IDS" ] || { printf '[]\n' > "$CACHE"; exit 0; }

USED="$(productive_api GET "services?filter%5Bid%5D=${USED_IDS}&include=deal.project&page%5Bsize%5D=200")"
printf '%s' "$USED" | jq -e '.data' >/dev/null 2>&1 || exit 0

# service_id -> {project, service name}, plus how often you booked it.
USAGE="$(jq -nc \
  --argjson entries "$ENTRIES" \
  --argjson svc "$(printf '%s' "$USED" | jq -c '{data, included}')" '
  ($svc.included // []) as $inc
  | (reduce ($inc[] | select(.type=="projects")) as $p ({}; .[$p.id] = $p.attributes.name)) as $proj
  | (reduce ($inc[] | select(.type=="deals"))    as $d ({}; .[$d.id] = ($d.relationships.project.data.id // ""))) as $deal
  | (reduce ($svc.data[]?) as $s ({};
      .[$s.id] = { project: ($proj[ $deal[ $s.relationships.deal.data.id // "" ] // "" ] // ""),
                   service: ($s.attributes.name // "") })) as $map
  | [ $entries[]? | .service_id | select(. != null) ]
  | group_by(.)
  | map({ service_id: .[0], uses: length })
  | map(. + ($map[.service_id] // {project:"", service:""}))
  | map(select(.project != ""))')"

# Keep only projects you are booked on this week, most-used service each.
jq -nc --argjson projects "$PROJECTS" --argjson usage "$USAGE" '
  $projects
  | map(. as $p
      | ([ $usage[] | select(.project == $p.project) ] | sort_by(-.uses)) as $cand
      | select(($cand | length) > 0)
      | { project: $p.project, project_id: $p.project_id,
          service_id: $cand[0].service_id, service: $cand[0].service,
          booked_role: $p.booked_role, uses: $cand[0].uses })
  | sort_by(.project)
' > "$CACHE" 2>/dev/null
