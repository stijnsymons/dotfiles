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
productive_api() {
  local method="$1" path="$2" body="${3:-}"
  productive_creds || return 1
  if [ -n "$body" ]; then
    curl -sS -m 25 -X "$method" \
      -H "X-Auth-Token: $PRODUCTIVE_API_TOKEN" \
      -H "X-Organization-Id: $PRODUCTIVE_ORG_ID" \
      -H "Content-Type: application/vnd.api+json" \
      -d "$body" "https://api.productive.io/api/v2/$path" 2>/dev/null
  else
    curl -sS -m 25 -X "$method" \
      -H "X-Auth-Token: $PRODUCTIVE_API_TOKEN" \
      -H "X-Organization-Id: $PRODUCTIVE_ORG_ID" \
      -H "Content-Type: application/vnd.api+json" \
      "https://api.productive.io/api/v2/$path" 2>/dev/null
  fi
}
