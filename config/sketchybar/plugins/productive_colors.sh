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
