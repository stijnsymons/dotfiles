#!/usr/bin/env bash
# Switch the running timer to another booking, from a chip or a panel row.
#
#   productive_switch.sh <service_id>
#   productive_switch.sh --stop                              stop whatever runs
#   productive_switch.sh --plan <timer.json> <service_id>    decision only, no calls
#
# productive_start.sh refuses to start while something runs, because the API had
# no stop. Productive's docs do list PATCH /timers/{id}/stop, though, and a
# switch is exactly "stop, then start", so this tries that route first.
#
# UNVERIFIED: that route has never been called from here (every other stop route
# 404s). So the failure path is the designed path, not an afterthought: any stop
# that does not come back as a timer is logged, the pinned Productive tab is
# opened so the stop can be done by hand, and the exit is non-zero. Nothing is
# created before the stop succeeded, so a failed switch leaves no orphan entry.
#
# Decision, kept pure so check.sh can assert it without touching the API:
#   noop        the booking you clicked is already the one running
#   start       nothing is running
#   stop+start  something else is running
set -u
source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/plugins/productive_api.sh"

export UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}"
LOG="$SB_CACHE_DIR/productive-start.log"
log() { printf '%s %s\n' "$(date '+%F %T')" "switch: $*" >>"$LOG"; }

switch_plan() { # <timer-json> <service_id>
  printf '%s' "$1" | jq -r --arg s "$2" '
    if .running != true then "start"
    elif ((.service_id // "") | tostring) == $s then "noop"
    else "stop+start" end' 2>/dev/null || echo start
}

if [ "${1:-}" = "--plan" ]; then
  switch_plan "$(cat "${2:?--plan needs a timer json}")" "${3:?--plan needs a service id}"
  exit 0
fi

SERVICE="${1:-}"
[ "$SERVICE" = --stop ] || case "$SERVICE" in ''|*[!0-9]*) log "bad service id '$SERVICE'"; exit 1 ;; esac
productive_creds || { log "no Productive credentials available"; exit 1; }

repaint() { NAME=productive "$CONFIG_DIR/plugins/productive.sh" >/dev/null 2>&1 || true; }

CURRENT="$(productive timer --json 2>/dev/null)"
# Fail closed: the CLI prints {"running": false} when idle, so no "running" key
# means the lookup itself failed. Going on blind could stop nothing and then
# create an entry whose timer start 422s (a create + rollback for nothing).
printf '%s' "$CURRENT" | jq -e 'has("running")' >/dev/null 2>&1 \
  || { log "could not read the current timer; not switching"; exit 1; }
stop_current() {
  local tid resp=""
  tid="$(printf '%s' "$CURRENT" | jq -r '.timer_id // empty')"
  [ -n "$tid" ] && resp="$(productive_api PATCH "timers/$tid/stop")"
  if ! printf '%s' "$resp" | jq -e '.data.id' >/dev/null 2>&1; then
    log "stop of timer '${tid:-?}' failed ($(printf '%s' "$resp" | head -c 200)); opening the timesheet"
    "$CONFIG_DIR/plugins/brave_tab.sh" 3 >/dev/null 2>&1 || true
    repaint
    exit 1
  fi
  log "stopped timer $tid"
}

# The panel's stop button: stop and repaint, nothing to start after.
if [ "$SERVICE" = --stop ]; then
  printf '%s' "$CURRENT" | jq -e '.running == true' >/dev/null 2>&1 && stop_current
  repaint
  exit 0
fi

case "$(switch_plan "$CURRENT" "$SERVICE")" in
  noop) exit 0 ;;
  start) ;;
  stop+start) stop_current ;;
esac

# productive_start.sh re-checks that nothing runs, creates the entry, starts the
# timer and repaints itself on success; a failure there is already in the log.
"$CONFIG_DIR/plugins/productive_start.sh" "$SERVICE"; rc=$?
repaint
exit $rc
