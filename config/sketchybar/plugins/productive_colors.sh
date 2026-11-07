# shellcheck shell=bash
# Shared timer colour rule, used by both the bar item and the card so the
# colour you click in the card is the colour the item turns.
#
#   red     nothing running - the alarm state the item exists for
#   violet  the mx-trai task. It lives INSIDE nove-internal, so it has to be
#           checked before the project or it would come out green.
#   green   nove-internal
#   blue    anything else, i.e. client work
#
# Sourced, not executed. colors.sh must already be sourced.

INTERNAL_PROJECT="${INTERNAL_PROJECT:-nove-internal}"
VIOLET_TASK="${VIOLET_TASK:-mx-trai}"

# <project> <task> [service]. Task OR service is checked for mx-trai: it is a
# task under nove-internal > general, but that project's services are also
# named mx-* (mx-mana, mx-busdev), so matching only one of the two would be a
# coin flip if it ever moves.
timer_color() {
  case "$2" in "$VIOLET_TASK") printf '%s' "$VIOLET"; return ;; esac
  case "${3:-}" in "$VIOLET_TASK") printf '%s' "$VIOLET"; return ;; esac
  case "$1" in "$INTERNAL_PROJECT") printf '%s' "$GREEN" ;; *) printf '%s' "$BLUE" ;; esac
}

# --- booking identity colours -------------------------------------------------
# The timer rule above answers "what is the whole bar's state"; this answers
# "which booking is this", for the chips, panel rows and day columns, which all
# have to show the same colour for the same booking (productive_board.sh puts
# the result in the board JSON so no UI re-derives it).
#
# GREEN and RED are never handed out: green means "timing now" and red means
# "nothing is timing", so a booking in either would read as state.
#
# A hash of the booking key picks the slot, so a booking keeps its colour from
# week to week without anything stored. The override map pins the ones that
# matter (mx-mana, mx-trai), and the slots they pin are left out of the hash
# pool, so an unrelated booking can never be mistaken for them.
booking_color() { # <key> -> 0xAARRGGBB
  case "$1" in
    mx-mana) printf '%s' "$YELLOW"; return ;;
    mx-trai) printf '%s' "$VIOLET"; return ;;
  esac
  local pool=("$BLUE" "$ORANGE" "$AQUA" "$PINK") h
  h="$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
  printf '%s' "${pool[$((h % ${#pool[@]}))]}"
}

# <key> -> "#rrggbb": the form a Swift/HTML UI reads (drops the 0xAA alpha).
booking_hex() { local c; c="$(booking_color "$1")"; printf '#%s' "${c:4}"; }
