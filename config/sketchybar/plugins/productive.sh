#!/usr/bin/env bash
# Productive.io time tracking. The point of this item is the NEGATIVE state:
# a red alarm when nothing is being timed, because untracked hours are the
# thing that actually costs money.
#
# Data comes from `productive timer --json` (~/code/assistant/bin/productive).
# Its exit code is 0 while a timer runs and 1 when none does -- but a network
# or auth failure also exits 1, so this script keys off the JSON body instead
# and treats "no parseable JSON" as UNKNOWN, not as "not timing". A dropped
# Wi-Fi packet must never fake the alarm.
#
# Glyphs are UTF-8 octal escapes so no encoding step can drop them:
# U+F017 clock (timing), U+F071 warning triangle (not timing).

source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/plugins/fit.sh"
# Hover dispatch, before anything expensive. sketchybar invokes this same
# script for every subscribed event; card.sh owns the dwell delay so the card
# does not fire while the pointer is merely crossing the bar.
case "${SENDER:-}" in
  mouse.exited|mouse.exited.global)  exec "$CONFIG_DIR/plugins/card.sh" productive close ;;
esac


CACHE_DIR="$HOME/.cache/sketchybar"
CACHE="$CACHE_DIR/productive.json"
STALE_AFTER=420          # seconds; past this the cache is no longer evidence

CLOCK="$(printf '\357\200\227')"
WARN="$(printf '\357\201\261')"

# launchd starts sketchybar from a login-less context: neither the CLI's
# directory nor its credentials are in the environment.
export PATH="$HOME/code/assistant/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if [ -z "${PRODUCTIVE_API_TOKEN:-}" ] && [ -r "$HOME/dotfiles/zshrc.private" ]; then
  # Only the PRODUCTIVE_* exports, never the whole (zsh) file. The token stays
  # in that private file; it is never copied into this repo.
  eval "$(grep -E '^[[:space:]]*export[[:space:]]+PRODUCTIVE_[A-Z_]+=' \
          "$HOME/dotfiles/zshrc.private" 2>/dev/null)"
fi

mkdir -p "$CACHE_DIR"

# Keep this week's planning cache warm for the card. Cheap: it returns
# immediately unless the cache is older than its TTL, so this is a stat()
# on all but one tick an hour.
"$CONFIG_DIR/plugins/productive_plan.sh" >/dev/null 2>&1 || true

# Minutes -> "3h45m" / "45m".
fmt() {
  local m=${1:-0}
  [ "$m" -ge 0 ] 2>/dev/null || m=0
  if [ "$m" -ge 60 ]; then printf '%dh%02dm' $((m / 60)) $((m % 60))
  else printf '%dm' "$m"; fi
}

# Test seam, mirroring meeting.sh's MEETING_FIXTURE: read the timer JSON from
# disk instead of the API, so check.sh can assert the colour rules without a
# live timer (and without starting one).
fetch() {
  local out
  if [ -n "${PRODUCTIVE_FIXTURE:-}" ]; then
    out="$(cat "$PRODUCTIVE_FIXTURE" 2>/dev/null)"
  else
    out="$(productive timer --json 2>/dev/null)"
  fi
  printf '%s' "$out" | jq -e 'has("running")' >/dev/null 2>&1 || return 1
  printf '%s' "$out" >"$CACHE"
  printf '%s' "$out"
}

source "$CONFIG_DIR/plugins/productive_colors.sh"

set_running() { sketchybar --set "$NAME" drawing=on \
                  icon="$CLOCK" icon.color="${2:-$GREEN}" label="$(fit_label "$NAME" "$1")" label.color="${2:-$FG}"; }
set_idle()    { sketchybar --set "$NAME" drawing=on \
                  icon="$WARN"  icon.color="$RED"   label="$(fit_label "$NAME" "not timing")" label.color="$RED"; }
set_unknown() { sketchybar --set "$NAME" drawing=on \
                  icon="$CLOCK" icon.color="$FG_DIM" label="--" label.color="$FG_DIM"; }

render() {        # $1 = json, $2 = age of that json in seconds
  local json=$1 age=${2:-0} what elapsed

  if [ "$(printf '%s' "$json" | jq -r '.running')" != "true" ]; then
    set_idle
    return
  fi

  local project task service
  { IFS= read -r what; IFS= read -r elapsed; IFS= read -r project; IFS= read -r task; IFS= read -r service; } <<JQEOF
$(printf '%s' "$json" | jq -r '
   ( [ (.project // empty), (.service // empty), (.task // empty) ]
       | map(select(length > 0)) | join(" · ") ),
   ( .elapsed_minutes // 0 ),
   ( .project // "" ),
   ( .task // "" ),
   ( .service // "" )')
JQEOF

  # A running clock keeps running: age the cached figure forward so a served
  # cache never shows a stale number.
  set_running "${what:-timing} $(fmt $((elapsed + age / 60)))" "$(timer_color "$project" "$task" "$service")"
}

if JSON="$(fetch)"; then
  render "$JSON" 0
elif [ -f "$CACHE" ]; then
  AGE=$(( $(date +%s) - $(stat -f %m "$CACHE") ))
  if [ "$AGE" -le "$STALE_AFTER" ]; then render "$(cat "$CACHE")" "$AGE"
  else set_unknown; fi
else
  set_unknown
fi
