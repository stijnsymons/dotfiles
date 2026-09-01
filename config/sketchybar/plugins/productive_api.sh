# Shared Productive API access for the plugins that need more than the CLI
# exposes: resolving a booked service to its project, and starting a timer.
#
# The CLI (~/code/assistant/bin/productive) covers reads and creating a time
# entry, but has no timer start and no service->project lookup, so those two go
# straight at the API.
#
# The token is never stored in this repo. It lives in zshrc.private, and only
# the PRODUCTIVE_* export lines are lifted out of it - never the whole (zsh)
# file, which this bash context could not evaluate anyway.
#
# Sourced, not executed.

productive_creds() {
  [ -n "${PRODUCTIVE_API_TOKEN:-}" ] && [ -n "${PRODUCTIVE_ORG_ID:-}" ] && return 0
  [ -r "$HOME/dotfiles/zshrc.private" ] || return 1
  eval "$(grep -E '^[[:space:]]*export[[:space:]]+PRODUCTIVE_[A-Z_]+=' \
          "$HOME/dotfiles/zshrc.private" 2>/dev/null)"
  [ -n "${PRODUCTIVE_API_TOKEN:-}" ] && [ -n "${PRODUCTIVE_ORG_ID:-}" ]
}

# productive_api <method> <path-with-query> [body]
#
# The two auth headers go in over stdin, not argv: a process's arguments are
# readable by every other process on the box, and -m 25 on a 60s tick leaves a
# wide enough window to just watch `ps` for the token. --fail-with-body turns
# an HTTP error into a non-2xx exit while keeping the body, which is the only
# place Productive says WHY (422 service_time_tracking_disabled and friends);
# callers all test the JSON shape, so an error body still reads as failure.
productive_api() {
  local method="$1" path="$2" body="${3:-}"
  productive_creds || return 1
  if [ -n "$body" ]; then
    curl -sS -m 25 --fail-with-body --retry 2 --retry-max-time 20 -X "$method" \
      -H "Content-Type: application/vnd.api+json" \
      -d "$body" --config - "https://api.productive.io/api/v2/$path" 2>/dev/null <<CURLRC
header = "X-Auth-Token: $PRODUCTIVE_API_TOKEN"
header = "X-Organization-Id: $PRODUCTIVE_ORG_ID"
CURLRC
  else
    curl -sS -m 25 --fail-with-body --retry 2 --retry-max-time 20 -X "$method" \
      -H "Content-Type: application/vnd.api+json" \
      --config - "https://api.productive.io/api/v2/$path" 2>/dev/null <<CURLRC
header = "X-Auth-Token: $PRODUCTIVE_API_TOKEN"
header = "X-Organization-Id: $PRODUCTIVE_ORG_ID"
CURLRC
  fi
}
