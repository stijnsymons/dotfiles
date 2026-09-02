#!/usr/bin/env bash
# Herdr flock: how many agents the herdr session is running, one digit per
# state so the split reads at a glance - red blocked (waiting on you), blue
# working, green done, dim idle, orange unknown. Zero-count states hide their
# digit, and no server (or an empty flock) hides the whole cluster, separator
# included. The sheep itself wears the most urgent colour present.
#
# HERDR_AGENT_JSON (env) short-circuits the socket call: check.sh injects a
# fixture so the parse is tested without caring what herdr is really running.
set -u
source "$CONFIG_DIR/colors.sh"

LIST="${HERDR_AGENT_JSON:-$(herdr agent list 2>/dev/null)}"

# meeting and productive fit their labels against their own live x, but only on
# their 60s tick - so this cluster appearing or vanishing would leave them
# mis-fit (and under the notch) for up to a minute. Poke them through the
# herdr_flock event on every visibility transition instead.
flock_poke() { # <on|off>
  local was
  was="$(cat "$SB_CACHE_DIR/herdr.visible" 2>/dev/null)"
  [ "$1" = "$was" ] && return 0
  printf '%s' "$1" > "$SB_CACHE_DIR/herdr.visible"
  sketchybar --trigger herdr_flock
}

# Layout settles in waves after a reload or a width change, and meeting and
# productive fit against the x they had when THEY last rendered - so they can
# sit under the notch until their next tick. This runs every 5s tick: measure
# the widest right edge of the two, and if it is past the notch ask for a
# re-fit. Deduped on the measured edge so a floor-limited fit (FIT_MIN_CHARS)
# cannot re-trigger forever - no change, no poke.
notch_guard() {
  local notch_l edge last
  read -r _ notch_l _ _ <<<"$("$CONFIG_DIR/bin/screen-metrics" 2>/dev/null)"
  case "${notch_l:-}" in ''|*[!0-9]*) return 0 ;; esac
  [ "$notch_l" -gt 0 ] || return 0
  edge="$(for it in meeting productive; do sketchybar --query "$it" 2>/dev/null; done \
          | jq -rs 'map(select(.geometry.drawing == "on")
                        | .bounding_rects | to_entries[0].value
                        | .origin[0] + .size[0])
                    | max // 0 | floor')"
  case "${edge:-}" in ''|*[!0-9]*) return 0 ;; esac
  [ "$edge" -gt "$notch_l" ] || return 0
  last="$(cat "$SB_CACHE_DIR/herdr.edge" 2>/dev/null)"
  [ "$edge" = "$last" ] && return 0
  printf '%s' "$edge" > "$SB_CACHE_DIR/herdr.edge"
  sketchybar --trigger herdr_flock
}

hide() {
  sketchybar --set herdr drawing=off \
             --set sep.herdr drawing=off \
             --set herdr.blocked drawing=off \
             --set herdr.working drawing=off \
             --set herdr.done drawing=off \
             --set herdr.idle drawing=off \
             --set herdr.unknown drawing=off
  flock_poke off
  notch_guard
  exit 0
}

# One jq pass for all five counts; anything non-numeric back means no server,
# a malformed reply, or an error object - all of them "show nothing".
COUNTS="$(printf '%s' "$LIST" | jq -r '
  [.result.agents[].agent_status] as $s
  | [("blocked","working","done","idle","unknown") as $st
     | $s | map(select(. == $st)) | length] | join(" ")' 2>/dev/null)"
read -r N_BLOCKED N_WORKING N_DONE N_IDLE N_UNKNOWN <<<"${COUNTS:-}"
case "${N_UNKNOWN:-}" in ''|*[!0-9]*) hide ;; esac

[ $(( N_BLOCKED + N_WORKING + N_DONE + N_IDLE + N_UNKNOWN )) -gt 0 ] || hide

if   [ "$N_BLOCKED" -gt 0 ]; then TINT="$RED"
elif [ "$N_WORKING" -gt 0 ]; then TINT="$BLUE"
elif [ "$N_DONE"    -gt 0 ]; then TINT="$GREEN"
else                              TINT="$FG_DIM"; fi

ARGS=(--set herdr drawing=on icon.color="$TINT" --set sep.herdr drawing=on)
digit() { # digit <state> <count> <colour>
  if [ "$2" -gt 0 ]; then
    ARGS+=(--set "herdr.$1" drawing=on label="$2" label.color="$3")
  else
    ARGS+=(--set "herdr.$1" drawing=off)
  fi
}
digit blocked "$N_BLOCKED" "$RED"
digit working "$N_WORKING" "$BLUE"
digit 'done'  "$N_DONE"    "$GREEN"
digit idle    "$N_IDLE"    "$FG_DIM"
digit unknown "$N_UNKNOWN" "$ORANGE"
sketchybar "${ARGS[@]}"
flock_poke on
notch_guard

card_dispatch herdr
