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
# One HUE per client, one SHADE per deal: every vbrb booking is a blue, so the
# customer reads at a glance and the shade tells its deals apart. The client is
# the 4-letter prefix of the product code (vbrb-0001-... -> vbrb); internal work
# is one client of its own, in yellow.
#
# GREEN and RED are never handed out: green means "timing now" and red means
# "nothing is timing", so a booking in either would read as state. mx-mana and
# mx-trai keep their pinned yellow and violet; other internal services get a
# yellow shade, never mana's exact one.
#
# Unpinned clients take a free hue from the pool, picked by a hash of the name so
# it usually holds from week to week.
# ponytail: four pool hues; a fifth client this week shares one (shades still differ).
BOOKING_COLORS_JQ='
  def hash: explode | reduce .[] as $c (7; (. * 31 + $c) % 65521);
  def hex2: ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | .[0] * 16 + .[1];
  def rgb: [.[1:3], .[3:5], .[5:7]] | map(hex2);
  def h2: [(. / 16 | floor), (. % 16)] | map(if . < 10 then . + 48 else . + 87 end) | implode;
  def tohex: "#" + (map(h2) | join(""));
  def mix($t): map(if $t >= 0 then . + (255 - .) * $t else . * (1 + $t) end | round);
  def client: if .project == $internal then "_internal"
              elif (.project | test("^[a-z]{4}-")) then .project[0:4] else .project end;

  map(. + {c: client}) as $b
  | (reduce ($b | map(.c) | unique | .[] | select($pins[.] == null)) as $c ($pins;
       ([.[]]) as $used
       | ($pool | map(select(. as $p | $used | any(. == $p) | not))) as $free
       | .[$c] = (if ($free | length) > 0 then $free[($c | hash) % ($free | length)]
                  else $pool[($c | hash) % ($pool | length)] end))) as $hue
  # Shades alternate lighter / darker round the base, spread over the client
  # deal count, so seven deals are seven shades. Dark stops sooner than light:
  # a near-black stripe vanishes on the bar.
  | [ $b | group_by(.c)[] | sort_by(.key) | (length + (if .[0].c == "_internal" then 1 else 0 end)) as $n
      | to_entries[] | .value as $x | (if $x.c == "_internal" then .key + 1 else .key end) as $i
      | ((($n - 1) / 2) | ceil | if . < 1 then 1 else . end) as $steps
      | (($i + 1) / 2 | floor) as $k
      | (if $i == 0 then 0 elif $i % 2 == 1 then 0.6 * $k / $steps else -0.4 * $k / $steps end) as $t
      | {($x.key): ($keypins[$x.key] // ($hue[$x.c] | rgb | mix($t) | tohex))} ]
  | add // {}'

# stdin: [{key, project}] -> {key: "#rrggbb"}
booking_hex6() { printf '#%s' "${1:4}"; }   # 0xAARRGGBB -> #rrggbb
booking_colors() {
  jq -c --arg internal "$INTERNAL_PROJECT" \
    --argjson pins "{\"vbrb\":\"$(booking_hex6 "$BLUE")\",\"_internal\":\"$(booking_hex6 "$YELLOW")\"}" \
    --argjson keypins "{\"mx-mana\":\"$(booking_hex6 "$YELLOW")\",\"mx-trai\":\"$(booking_hex6 "$VIOLET")\"}" \
    --argjson pool "[\"$(booking_hex6 "$BLUE")\",\"$(booking_hex6 "$ORANGE")\",\"$(booking_hex6 "$AQUA")\",\"$(booking_hex6 "$PINK")\"]" \
    "$BOOKING_COLORS_JQ"
}
