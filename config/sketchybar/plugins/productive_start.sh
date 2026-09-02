#!/usr/bin/env bash
# Start a timer on a service, from a click in the productive card.
#
#   productive_start.sh <service_id> [task_id]
#
# Productive has no "start a timer on a project" call. A timer hangs off a
# TIME ENTRY (its relationships are organization + time_entry), so starting one
# is two writes: create a zero-minute entry for today against the service, then
# post a timer onto that entry. This does create a real timesheet row - that is
# simply how the model works, and it is the row you would have created by hand.
#
# Only one timer per person is allowed, so any running one is stopped first.
#
# Detached from the click, so failures have nowhere to print: they go to the log.

set -u
source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/plugins/productive_api.sh"

export UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}"

LOG="$SB_CACHE_DIR/productive-start.log"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

SERVICE="${1:-}"
[ -n "$SERVICE" ] || { log "no service id given"; exit 1; }

# The CLI reads PRODUCTIVE_API_TOKEN from the ENVIRONMENT - it does no lifting
# of its own. productive_api() lifts the creds itself, but the two CLI calls
# below run before it, and this script is spawned from a card click, not from
# productive.sh, so it inherits nothing. Without the lift the bar's login-less
# environment makes both CLI calls exit non-zero with an empty stdout, which
# reads here as "nothing is timing" and then as "the entry could not be
# created" - the empty-bodied failures in the log.
productive_creds || { log "no Productive credentials available"; exit 1; }

# --- refuse if something is already timing -----------------------------------
# Productive allows one timer per person and offers NO way to stop one through
# the API: /timers supports GET and POST only - PATCH, PUT, DELETE and
# POST /timers/{id}/stop all come back "route not found". Starting a second
# returns 422 timer_already_started.
#
# So bail out BEFORE creating anything. The first version stopped here too late,
# after the entry existed, which left an orphan zero-minute row in the timesheet
# every time you clicked while already timing.
CURRENT="$(productive timer --json 2>/dev/null)"
if printf '%s' "$CURRENT" | jq -e '.running == true' >/dev/null 2>&1; then
  log "already timing $(printf '%s' "$CURRENT" | jq -r '.project // "?"') - stop it in Productive first"
  exit 1
fi

# --- create the entry the timer will hang off -------------------------------
CREATED="$(productive create --date "$(date +%F)" --minutes 0 --service "$SERVICE" 2>/dev/null)"
ENTRY="$(printf '%s' "$CREATED" | jq -r '.created // empty' 2>/dev/null)"
if [ -z "$ENTRY" ]; then
  log "could not create a time entry for service $SERVICE: $(printf '%s' "$CREATED" | head -c 200)"
  exit 1
fi

# --- start the timer --------------------------------------------------------
BODY="$(jq -nc --arg id "$ENTRY" \
       '{data:{type:"timers", relationships:{time_entry:{data:{type:"time_entries", id:$id}}}}}')"
RESP="$(productive_api POST timers "$BODY")"
if ! printf '%s' "$RESP" | jq -e '.data.id' >/dev/null 2>&1; then
  # Roll the entry back rather than leaving a zero-minute row behind.
  log "timer POST failed for entry $ENTRY: $(printf '%s' "$RESP" | head -c 200)"
  productive delete --id "$ENTRY" >/dev/null 2>&1 && log "rolled back entry $ENTRY"
  exit 1
fi

log "started timer on service $SERVICE (entry $ENTRY)"

# Repaint now rather than waiting up to 60s for the next tick.
NAME=productive "$CONFIG_DIR/plugins/productive.sh" >/dev/null 2>&1 || true
