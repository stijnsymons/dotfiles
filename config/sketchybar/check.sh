#!/usr/bin/env bash
# Smallest thing that fails if the plugin logic breaks. Run: ./check.sh
set -u
export CONFIG_DIR="${CONFIG_DIR:-$(cd "$(dirname "$0")" && pwd)}"
source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/plugins/app_icon.sh"
fail=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }
nonempty() { [ -n "$2" ] && ok "$1" || bad "$1 (empty)"; }
pct()  { [ "$2" -ge 0 ] 2>/dev/null && [ "$2" -le 100 ] && ok "$1 = $2%" || bad "$1 not a 0-100 int (got '$2')"; }

echo "app_icon:"
nonempty "known app"   "$(app_icon Ghostty)"
nonempty "bundle id"   "$(app_icon com.mitchellh.ghostty)"
nonempty "unknown app" "$(app_icon "Totally Fake App")"
is "distinct glyphs" "$([ "$(app_icon Slack)" != "$(app_icon Ghostty)" ] && echo yes)" yes

echo "battery.sh parse:"
pct "battery" "$(pmset -g batt | grep -Eo '[0-9]+%' | head -1 | tr -d '%')"

echo "wifi.sh parse:"
WIFI_IF="$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}')"
nonempty "wifi interface" "$WIFI_IF"
# SSID is legitimately empty when not associated, so only assert it does not error.
ipconfig getsummary "${WIFI_IF:-en0}" >/dev/null 2>&1 && ok "ipconfig getsummary" || bad "ipconfig getsummary failed"

echo "bin/ helpers:"
# build.sh keeps the last working binary and leaves the compiler's reason in a
# build-<name>.err it removes on success, so a leftover .err IS the failure.
for b in screen-metrics mic-active meeting-overlay; do
  [ -x "$CONFIG_DIR/bin/$b" ] && ok "bin/$b built" || bad "bin/$b missing or not executable"
done
BERR=""
for e in "$SB_CACHE_DIR"/build-*.err; do
  [ -s "$e" ] && BERR="$BERR $(basename "$e")"
done
[ -z "$BERR" ] && ok "no build errors logged" || bad "build failures logged:$BERR"

echo "mic-active:"
if [ -x "$CONFIG_DIR/bin/mic-active" ]; then
  M="$("$CONFIG_DIR/bin/mic-active")"
  case "$M" in 0|1) ok "returns $M" ;; *) bad "expected 0 or 1 (got '$M')" ;; esac
else
  bad "bin/mic-active not built (swiftc -O -o bin/mic-active bin/mic-active.swift)"
fi

echo "app menu:"
# There is no glyph assertion here any more. This hung off a dedicated  item
# whose only job was to carry U+F179, and the byte-level check existed because a
# grep for the literal also matches an EMPTY icon="". The menu moved onto
# front_app, whose icon is the focused app's own glyph and changes on every
# switch - there is no fixed byte string left to assert.
[ -x "$CONFIG_DIR/plugins/app_menu.sh" ] && ok "click handler executable" \
                                         || bad "plugins/app_menu.sh not executable"
# The click has to actually be wired to it. front_app carries a script AND a
# click_script and only the latter opens the menu, so a config that drops the
# click_script leaves an item that still paints correctly and silently does
# nothing when clicked - which is precisely the bug that is easy to miss.
sketchybar --query front_app 2>/dev/null | jq -e --arg h "$CONFIG_DIR/plugins/app_menu.sh" \
  '.click_script | test($h)' >/dev/null \
  && ok "front_app click opens the app menu" \
  || bad "front_app has no click_script pointing at app_menu.sh"
# --print, never the handler itself: a real invocation drops a modal NSMenu
# over the rest of this suite, and omniwmctl BLOCKS on a second one while the
# first is tracking. The seam names the command instead of running it.
AM_CMD="$("$CONFIG_DIR/plugins/app_menu.sh" --print 2>/dev/null)"
is "handler drives omniwm's open-menu-anywhere" "$AM_CMD" "omniwmctl command open-menu-anywhere"
# Drift guard on the other side of that contract: the click is silent when
# omniwm renames or drops the command, because the handler only prints its
# complaint to a stderr nobody reads. `omniwmctl help` is local usage text, so
# this holds whether or not omniwm is running - unlike the ipc probe further down.
omniwmctl help 2>&1 | grep -qF -- "$AM_CMD" \
  && ok "omniwm still exposes the command" \
  || bad "omniwmctl no longer lists '$AM_CMD' - the app menu click is a no-op"

echo "layout vs notch:"
read -r M_TOP M_NL M_NR _ <<<"$(swift "$CONFIG_DIR/bin/screen-metrics.swift" 2>/dev/null)"
BAR_H="$(sketchybar --query bar 2>/dev/null | jq -r '.height')"
is "bar height matches reserved top inset" "$BAR_H" "$M_TOP"
if [ "${M_NR:-0}" = "0" ]; then
  ok "no notch on this display, skipping clearance"
else
  # Items drawn between M_NL and M_NR are hidden behind the notch.
  edge_of() { # $1 = left|right -> innermost x of that cluster
    sketchybar --query bar | jq -r '.items[]' | while read -r i; do
      pos="$(sketchybar --query "$i" 2>/dev/null | jq -r '.geometry.position // ""')"
      [ "$pos" = "$1" ] || continue
      sketchybar --query "$i" 2>/dev/null \
        | jq -r '.bounding_rects|to_entries[0].value|select(.origin[0] > -9000)|"\(.origin[0]|floor) \((.origin[0]+.size[0])|floor)"'
    done
  }
  L_MAX="$(edge_of left  | awk '{if($2>m)m=$2}END{print m+0}')"
  R_MIN="$(edge_of right | awk 'NR==1||$1<m{m=$1}END{print m+0}')"
  if [ "$L_MAX" -le "${M_NL%.*}" ]; then
    ok "left cluster ends at $L_MAX, notch starts $M_NL"
  else
    bad "left cluster runs under the notch ($L_MAX > $M_NL)"
  fi
  if [ "$R_MIN" -ge "${M_NR%.*}" ]; then
    ok "right cluster starts at $R_MIN, notch ends $M_NR"
  else
    bad "right cluster runs under the notch ($R_MIN < $M_NR)"
  fi
fi

echo "media glyphs:"
# Byte-level, because a grep for the literal also matches a dropped glyph.
MP="$(printf '\357\201\213' | xxd -p)"; MU="$(printf '\357\201\214' | xxd -p)"
MG="$(sketchybar --query media 2>/dev/null | jq -r '.icon.value' | tr -d '\n' | xxd -p)"
case "$MG" in
  "$MP") ok "play glyph U+F04B" ;;
  "$MU") ok "pause glyph U+F04C" ;;
  "")    ok "media hidden (nothing playing)" ;;
  *)     bad "unexpected media glyph bytes: $MG" ;;
esac

echo "meeting.sh / meeting_click.sh:"
MEET_TMP="$(mktemp -d)"   # removed at the end of this block; no trap, so
                          # merging this into check.sh cannot clobber one.
command -v "$HOME/bin/gws-now" >/dev/null && ok "gws-now on disk" || bad "gws-now missing from ~/bin (the meeting item needs it)"

# Link resolution is pure: fixtures in, URL out, no network. These are the three
# shapes that actually occur - Meet/Zoom via conferenceData, Zoom only as a
# google.com/url-wrapped href in the notes, Teams only as an <a href> in the
# HTML description - plus a linkless event, which must fail so the click falls
# through to Brave.
cat > "$MEET_TMP/zoom.json" <<'JSON'
{"summary":"standup","conferenceData":{"entryPoints":[
  {"entryPointType":"video","uri":"https://example.zoom.us/j/12345678901?jst=2"},
  {"entryPointType":"phone","uri":"tel:+3200000000,,12345678901#"}]}}
JSON
cat > "$MEET_TMP/zoom_notes.json" <<'JSON'
{"summary":"standup","location":"HQ-0-05 (8) [TV, Zoom]","conferenceData":{"notes":
"Join Zoom Meeting: <br /><a href=\"https://www.google.com/url?q=https://example.zoom.us/j/12345678901?jst%3D2&amp;sa=D&amp;source=calendar\">link</a><br />Agenda: <a href=\"https://docs.zoom.us/agenda/doc/abc\">agenda</a>"}}
JSON
cat > "$MEET_TMP/teams.json" <<'JSON'
{"summary":"review","location":"Microsoft Teams Meeting","description":
"<a href=\"https://www.google.com/url?q=https://teams.microsoft.com/l/meetup-join/19%253ameeting_X%2540thread.v2/0?context%3D%257b%2522Tid%2522%253a%2522t%2522%257d&amp;sa=D\">Click here to join</a><br>Learn more at <a href=\"https://aka.ms/JoinTeamsMeeting\">aka.ms</a>."}
JSON
printf '{"summary":"1:1","location":"HQ-0-05 (8) [TV]"}\n' > "$MEET_TMP/nolink.json"
printf 'null\n' > "$MEET_TMP/none.json"
: > "$MEET_TMP/failed.json"   # empty = the gws-now call itself failed

mlink() { MEETING_CACHE="$MEET_TMP/$1" "$CONFIG_DIR/plugins/meeting_click.sh" --print 2>/dev/null; }
is "zoom via conferenceData"  "$(mlink zoom.json)"       "https://example.zoom.us/j/12345678901?jst=2"
is "zoom via wrapped notes"   "$(mlink zoom_notes.json)" "https://example.zoom.us/j/12345678901?jst=2"
case "$(mlink teams.json)" in
  https://teams.microsoft.com/l/meetup-join/*) ok "teams via html description" ;;
  *) bad "teams via html description (got '$(mlink teams.json)')" ;;
esac
mlink nolink.json >/dev/null && bad "linkless event must not resolve a link" || ok "linkless event falls through to Brave"
mlink none.json   >/dev/null && bad "absent meeting must not resolve a link" || ok "no meeting falls through to Brave"

# Brave's dictionary term is `active tab index`, not `active tab`. Read-only:
# this must not steal focus or move the user's tab.
if osascript -e 'tell application "System Events" to (name of processes) contains "Brave Browser"' 2>/dev/null | grep -q true; then
  osascript -e 'tell application "Brave Browser" to get active tab index of front window' >/dev/null 2>&1 \
    && ok "brave 'active tab index' readable" || bad "brave AppleScript failed (no window, or dictionary changed)"
else
  ok "brave not running, skipping AppleScript probe"
fi

# Rendering, driven by a fixture so check.sh stays offline and instant.
MEET_END="$(date -u -v+37M +%Y-%m-%dT%H:%M:%SZ)"
jq --arg e "$MEET_END" '. + {end:{dateTime:$e}}' "$MEET_TMP/teams.json" > "$MEET_TMP/live.json"
NAME=meeting MEETING_CACHE="$MEET_TMP/cache.json" MEETING_FIXTURE="$MEET_TMP/live.json" \
  "$CONFIG_DIR/plugins/meeting.sh" 2>/dev/null
MEET_LABEL="$(sketchybar --query meeting 2>/dev/null | jq -r '.label.value')"
case "$MEET_LABEL" in
  "review · 3"[0-9]m) ok "renders '$MEET_LABEL'" ;;
  *) bad "expected 'review · 37m'-ish (got '$MEET_LABEL')" ;;
esac
is "cache written for the click path" "$(jq -r '.summary' "$MEET_TMP/cache.json" 2>/dev/null)" "review"

# Byte-wise, because a grep for the literal also matches a dropped glyph.
MV="$(printf '\363\260\225\247' | xxd -p)"   # U+F0567 nf-md-video
MG="$(sketchybar --query meeting 2>/dev/null | jq -r '.icon.value' | tr -d '\n' | xxd -p)"
is "video glyph U+F0567 bytes" "$MG" "$MV"
grep -q "$(printf '\363\260\203\255')" "$CONFIG_DIR/plugins/meeting.sh" && ok "calendar glyph U+F00ED present" || bad "calendar glyph U+F00ED dropped from meeting.sh"

# "looked, found nothing" and "could not look" must not render the same. A
# failed call rendering "no meetings" would assert an empty calendar we never saw.
NAME=meeting MEETING_CACHE="$MEET_TMP/cache.json" MEETING_FIXTURE="$MEET_TMP/none.json" \
  "$CONFIG_DIR/plugins/meeting.sh" 2>/dev/null
is "no meeting -> drawn"        "$(sketchybar --query meeting 2>/dev/null | jq -r '.geometry.drawing')" "on"
is "no meeting -> 'no meetings'" "$(sketchybar --query meeting 2>/dev/null | jq -r '.label.value')" "no meetings"
is "no meeting -> dimmed"       "$(sketchybar --query meeting 2>/dev/null | jq -r '.label.color')" "$FG_DIM"

NAME=meeting MEETING_CACHE="$MEET_TMP/cache.json" MEETING_FIXTURE="$MEET_TMP/failed.json" \
  "$CONFIG_DIR/plugins/meeting.sh" 2>/dev/null
is "failed fetch -> hidden"     "$(sketchybar --query meeting 2>/dev/null | jq -r '.geometry.drawing')" "off"
is "failed fetch -> no dangling rule" "$(sketchybar --query sep.timing 2>/dev/null | jq -r '.geometry.drawing')" "off"

# The fixture above left the LIVE item hidden. One real run, no overrides, puts
# the bar back where it was - otherwise a check during an actual meeting blanks
# it until the next 60s tick, and running this suite twice is not idempotent.
NAME=meeting "$CONFIG_DIR/plugins/meeting.sh" >/dev/null 2>&1 || true
rm -rf "$MEET_TMP"

echo "caffeine:"
[ -x "$CONFIG_DIR/plugins/caffeine.sh" ] && ok "renderer executable" || bad "plugins/caffeine.sh not executable"
[ -x "$CONFIG_DIR/plugins/caffeine_click.sh" ] && ok "click handler executable" || bad "plugins/caffeine_click.sh not executable"
# Byte-level: a grep for the literal matches a dropped glyph (icon="") too.
CWANT="$(printf '\363\260\205\266' | xxd -p)"
CGOT="$(sketchybar --query caffeine 2>/dev/null | jq -r '.icon.value' | tr -d '\n' | xxd -p)"
is "coffee glyph U+F0176 bytes" "$CGOT" "$CWANT"
CAFFEINE_LIB=1 source "$CONFIG_DIR/plugins/caffeine.sh"
CSF="$(mktemp)"
# shellcheck disable=SC2034  # read by caffeine_pid(), sourced just above
CAFFEINE_STATE_FILE="$CSF"
echo 1 > "$CSF"        # alive, but launchd -- i.e. a recycled PID
caffeine_pid >/dev/null && bad "recycled PID reads as running" || ok "recycled PID reads as off"
echo 999999 > "$CSF"   # dead
caffeine_pid >/dev/null && bad "dead PID reads as running" || ok "dead PID reads as off"
echo "junk" > "$CSF"
caffeine_pid >/dev/null && bad "garbage PID file reads as running" || ok "garbage PID file reads as off"
rm -f "$CSF"
# Never a blanket kill: pkill would take out a caffeinate a long build is holding.
grep -vE '^[[:space:]]*#' "$CONFIG_DIR/plugins/caffeine_click.sh" | grep -qE 'pkill|killall' \
  && bad "click handler uses a blanket kill" || ok "kills only its own PID"

echo "productive:"
{ command -v productive >/dev/null || [ -x "$HOME/code/assistant/bin/productive" ]; } \
  && ok "CLI reachable" || bad "productive CLI missing"
PC="$(printf '\357\200\227' | xxd -p)"; PW="$(printf '\357\201\261' | xxd -p)"
PG="$(sketchybar --query productive 2>/dev/null | jq -r '.icon.value' | tr -d '\n' | xxd -p)"
case "$PG" in
  "$PC") ok "clock glyph U+F017 (timing)" ;;
  "$PW") ok "warning glyph U+F071 (not timing)" ;;
  *)     bad "unexpected productive glyph bytes: $PG" ;;
esac
# A transparent colour means colors.sh was not sourced -- the icon renders
# invisible. The full set is timer_color's tiers (blue client / green internal /
# violet mx-trai) plus red idle and the dim stale state.
PICO="$(sketchybar --query productive 2>/dev/null | jq -r '.icon.color')"
case "$PICO" in "$RED"|"$GREEN"|"$BLUE"|"$VIOLET"|"$FG_DIM") ok "icon colour $PICO from palette" ;;
                *) bad "icon colour not from palette (got '$PICO')" ;; esac

echo "launchd PATH:"
# launchd hands sketchybar /usr/bin:/bin and nothing else. colors.sh is the one
# place that repairs it, so every script that sources it finds jq, gws and the
# Productive CLI - without it every hover card and the calendar item go blank.
CJQ="$(env -i HOME="$HOME" CONFIG_DIR="$CONFIG_DIR" PATH=/usr/bin:/bin \
       /bin/bash -c 'source "$CONFIG_DIR/colors.sh"; command -v jq' 2>/dev/null)"
nonempty "colors.sh puts jq on a launchd PATH" "$CJQ"

echo "hover cards:"
[ -x "$CONFIG_DIR/plugins/card.sh" ] && ok "engine executable" || bad "plugins/card.sh not executable"
for c in $CARD_ITEMS; do
  [ -r "$CONFIG_DIR/cards/$c.sh" ] || { bad "cards/$c.sh missing"; continue; }
  # Every provider must define card_rows and emit well-formed <glyph>TAB<color>TAB<text>.
  # shellcheck source=/dev/null
  CROWS="$( set +u; source "$CONFIG_DIR/colors.sh"; source "$CONFIG_DIR/cards/$c.sh"
            type card_rows >/dev/null 2>&1 && card_rows 2>/dev/null )"
  if [ -z "$CROWS" ]; then bad "$c: card_rows produced nothing"; continue; fi
  CBAD=0
  while IFS=$'\t' read -r g col t; do
    [ -z "$g" ]   && { bad "$c: a row has no glyph"; CBAD=1; break; }
    [ -z "$t" ]   && { bad "$c: a row has no text";  CBAD=1; break; }
    case "$col" in 0x*) ;; *) bad "$c: colour '$col' not from the palette"; CBAD=1; break ;; esac
  done <<CHKEOF
$CROWS
CHKEOF
  [ "$CBAD" -eq 0 ] && ok "$c: $(printf '%s' "$CROWS" | grep -c .) well-formed rows"
done

# Enough pre-created rows for the longest card, or content is silently dropped.
for c in $CARD_ITEMS; do
  CN="$(sketchybar --query bar 2>/dev/null | jq -r --arg p "$c.pop." '[.items[]|select(startswith($p))]|length')"
  # shellcheck source=/dev/null
  CW="$( set +u; source "$CONFIG_DIR/colors.sh"; source "$CONFIG_DIR/cards/$c.sh"; card_rows 2>/dev/null | grep -c . )"
  [ "${CN:-0}" -ge "${CW:-0}" ] && ok "$c: $CN rows for $CW needed" \
                                || bad "$c: only $CN rows for $CW content lines - card truncated"
  # card.sh addresses rows up to this card's own budget, both to fill and to
  # hide leftovers, so anything it can address has to exist on the bar.
  CB="$(card_rows_max "$c")"
  [ "${CN:-0}" -ge "$CB" ] && ok "$c: budget of $CB rows pre-created" \
                           || bad "$c: budget is $CB but only $CN rows exist"
  # And the same comparison without the bar in it. The one above only catches an
  # overlong card because sketchybarrc happens to pre-create exactly the budget,
  # so it reads as a truncation rather than as the budget being too small - and
  # it cannot fire at all when the bar is unreachable. wifi is the card this
  # matters for: eight rows against a budget of eight since the throughput moved
  # into it, so the next row added there is the one that vanishes.
  [ "${CW:-0}" -le "$CB" ] && ok "$c: $CW rows fit the budget of $CB" \
                           || bad "$c: emits $CW rows against a budget of $CB - raise card_rows_max"
done
is "an unknown card falls back to the default budget" "$(card_rows_max not_a_card)" "$CARD_ROWS"

# Open/close and the watchdog, exercised on one card (the engine is shared).
"$CONFIG_DIR/plugins/card.sh" wifi open >/dev/null 2>&1
is "opens" "$(sketchybar --query wifi 2>/dev/null | jq -r '.popup.drawing')" "on"
CSTAMP="$SB_CACHE_DIR/card-wifi.at"
printf '%s' "$(( $(date +%s) - 600 ))" > "$CSTAMP"
"$CONFIG_DIR/plugins/card.sh" wifi tick >/dev/null 2>&1
is "watchdog closes a stale card" "$(sketchybar --query wifi 2>/dev/null | jq -r '.popup.drawing')" "off"
"$CONFIG_DIR/plugins/card.sh" wifi open >/dev/null 2>&1
"$CONFIG_DIR/plugins/card.sh" wifi tick >/dev/null 2>&1
is "watchdog leaves a fresh card open" "$(sketchybar --query wifi 2>/dev/null | jq -r '.popup.drawing')" "on"
"$CONFIG_DIR/plugins/card.sh" wifi close >/dev/null 2>&1
is "closes" "$(sketchybar --query wifi 2>/dev/null | jq -r '.popup.drawing')" "off"

# Click toggles: a second click on the same item must dismiss, not re-open.
"$CONFIG_DIR/plugins/card.sh" wifi toggle >/dev/null 2>&1
is "click opens" "$(sketchybar --query wifi 2>/dev/null | jq -r '.popup.drawing')" "on"
"$CONFIG_DIR/plugins/card.sh" wifi toggle >/dev/null 2>&1
is "click again closes" "$(sketchybar --query wifi 2>/dev/null | jq -r '.popup.drawing')" "off"

# Only one card at a time: mouse.exited.global does not reliably fire between
# two quick clicks on different items. The second card used to be cpu; clock is
# the stand-in now that cpu is gone, and it is the one card that is always
# drawn - media hides itself and mic is empty most of the day.
"$CONFIG_DIR/plugins/card.sh" wifi  toggle >/dev/null 2>&1
"$CONFIG_DIR/plugins/card.sh" clock toggle >/dev/null 2>&1
CO="$(sketchybar --query wifi 2>/dev/null | jq -r '.popup.drawing')$(sketchybar --query clock 2>/dev/null | jq -r '.popup.drawing')"
is "opening one card closes the other" "$CO" "offon"
"$CONFIG_DIR/plugins/card.sh" clock close >/dev/null 2>&1

# Hover must be gone entirely.
grep -rq "mouse.entered" "$CONFIG_DIR/sketchybarrc" "$CONFIG_DIR/plugins" "$CONFIG_DIR/cards" 2>/dev/null \
  && bad "mouse.entered still wired somewhere" || ok "no hover wiring left"

echo "outside click:"
# sketchybar has no global click event, so a click elsewhere is inferred from
# $CARD_AWAY_EVENTS and swept by `card.sh away`. Three things can rot: the
# watcher item, its subscriptions, and the sweep missing a card. The sweep is
# driven against a STUB sketchybar rather than the live bar - the bar cannot be
# reloaded from here, and a real sweep would tell us nothing about the six
# cards that happened to be closed already.
CAW="$(mktemp -d)"   # removed at the end of this block; no trap, as above
mkdir -p "$CAW/bin"
cat > "$CAW/bin/sketchybar" <<'CHKSTUB'
#!/bin/sh
printf 'CALL' >> "$SB_AWAY_LOG"
printf ' %s' "$@" >> "$SB_AWAY_LOG"
printf '\n' >> "$SB_AWAY_LOG"
CHKSTUB
chmod +x "$CAW/bin/sketchybar"
# Every directory colors.sh prepends is already listed, so its PATH repair is a
# no-op here and the stub stays in front of the real binary. XDG_CACHE_HOME
# moves SB_CACHE_DIR aside so the sweep sees no stamps - and cannot touch the
# stamp of a card the user has open right now.
card_away_run() { # card_away_run <log>
  : > "$1"
  SB_AWAY_LOG="$1" XDG_CACHE_HOME="$CAW/cache" \
  PATH="$CAW/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/bin:$HOME/code/assistant/bin:/usr/bin:/bin" \
    "$CONFIG_DIR/plugins/card.sh" away 2>"$1.err"
}

card_away_run "$CAW/cold"
CAMISS=""
for c in $CARD_ITEMS; do
  grep -q -- "--set $c popup.drawing=off" "$CAW/cold" || CAMISS="$CAMISS $c"
done
CANUM="$(printf '%s\n' $CARD_ITEMS | grep -c .)"
[ -z "$CAMISS" ] && ok "sweep closes all $CANUM cards" || bad "sweep never reaches:$CAMISS"
# One call, not one per card: this runs on every app switch.
is "sweep is a single sketchybar call" "$(grep -c '^CALL' "$CAW/cold")" 1
# A closed card has no stamp, and bash reports a failed input redirect on the
# stderr it still has - the trailing-2>/dev/null form leaked six lines into the
# bar's log per app switch.
is "sweep is silent on stampless cards" "$(wc -c < "$CAW/cold.err" | tr -d ' ')" 0

# A card opened in the same instant must survive. A row action that focuses an
# app fires front_app_switched straight back at the sweep, and --update at
# config load runs it with SENDER=forced.
date +%s > "$CAW/cache/sketchybar/card-wifi.at"
card_away_run "$CAW/fresh"
grep -q -- "--set wifi popup.drawing=off" "$CAW/fresh" \
  && bad "sweep shut a card that had just opened" || ok "a just-opened card survives the sweep"
# clock, because it is a card that is always on the bar and is not the one
# whose stamp was just written. It used to be cpu, which is no longer a card.
grep -q -- "--set clock popup.drawing=off" "$CAW/fresh" \
  && ok "the grace spares only the fresh card" || bad "grace spared a card that was not fresh"

# An unreadable stamp must not wedge the sweep shut, the way tick treats one.
printf 'not-a-number' > "$CAW/cache/sketchybar/card-herdr.at"
card_away_run "$CAW/junk"
grep -q -- "--set herdr popup.drawing=off" "$CAW/junk" \
  && ok "a corrupt stamp still closes" || bad "a corrupt stamp left a card open"

# The watcher on the live bar. Everything above passes with the item deleted,
# which is exactly the regression this catches.
CWQ="$(sketchybar --query card_watch 2>/dev/null)"
is "watcher item exists" "$(printf '%s' "$CWQ" | jq -r '.name // ""')" "card_watch"
# Matched on the suffix: the bar records the path it was loaded through
# (~/.config/sketchybar, a symlink), not the directory this script lives in.
case "$(printf '%s' "$CWQ" | jq -r '.scripting.script // ""')" in
  */plugins/card.sh\ away) ok "watcher runs the away sweep" ;;
  *)                       bad "watcher does not run card.sh away" ;;
esac
# One mask bit per event, so the popcount is how many subscriptions actually
# took. Asserting the mask itself would pin this to sketchybar's internal
# event ordering.
CWM="$(printf '%s' "$CWQ" | jq -r '.scripting.update_mask // 0')"
CWBITS=0
while [ "${CWM:-0}" -gt 0 ] 2>/dev/null; do
  CWBITS=$(( CWBITS + (CWM & 1) )); CWM=$(( CWM >> 1 ))
done
is "watcher took every away event" "$CWBITS" "$(printf '%s\n' $CARD_AWAY_EVENTS | grep -c .)"
# And it must subscribe through the named set, or colors.sh and sketchybarrc
# drift the moment an event is added to one of them.
grep -q -- '--subscribe card_watch \$CARD_AWAY_EVENTS' "$CONFIG_DIR/sketchybarrc" \
  && ok "sketchybarrc subscribes the named event set" \
  || bad "sketchybarrc hardcodes the away events instead of \$CARD_AWAY_EVENTS"
# space_windows_change fires on any window opening anywhere - it would shut a
# card mid-read, and it is not a click.
case " $CARD_AWAY_EVENTS " in
  *" space_windows_change "*) bad "space_windows_change would close cards on background windows" ;;
  *)                          ok "no window-churn event in the away set" ;;
esac
rm -rf "$CAW"

echo "card row actions:"
# Every row must carry a click_script, or a row silently does nothing.
"$CONFIG_DIR/plugins/card.sh" meeting open >/dev/null 2>&1
CMISS=0
CI=1
CMAX="$(card_rows_max meeting)"
while [ "$CI" -le "$CMAX" ]; do
  CQ="$(sketchybar --query "meeting.pop.$CI" 2>/dev/null)"
  CI=$(( CI + 1 ))
  [ "$(printf '%s' "$CQ" | jq -r '.geometry.drawing')" = "on" ] || continue
  [ -n "$(printf '%s' "$CQ" | jq -r '.scripting.click_script // ""')" ] || CMISS=1
done
[ "$CMISS" -eq 0 ] && ok "every visible meeting row has a click_script" || bad "a meeting row has no click_script"
"$CONFIG_DIR/plugins/card.sh" meeting close >/dev/null 2>&1

# The conference row must resolve to a native app URI, not an https bounce.
CT="$(mktemp -d)"
cat > "$CT/zoom.json" <<'CHKZOOM'
{"summary":"Z","end":{"dateTime":"2099-01-01T00:00:00Z"},
 "conferenceData":{"entryPoints":[{"entryPointType":"video","uri":"https://acme.zoom.us/j/99887766?pwd=SEKRIT"}]}}
CHKZOOM
cat > "$CT/teams.json" <<'CHKTEAMS'
{"summary":"T","end":{"dateTime":"2099-01-01T00:00:00Z"},
 "description":"<a href=\"https://teams.microsoft.com/l/meetup-join/19%3ax/0?context=y\">Join</a>"}
CHKTEAMS
# A /s/ SSO link carries a token, not a numeric id. There is no confno to build
# from it, so it must come back untouched and let the browser handle it.
cat > "$CT/sso.json" <<'CHKSSO'
{"summary":"S","end":{"dateTime":"2099-01-01T00:00:00Z"},
 "conferenceData":{"entryPoints":[{"entryPointType":"video","uri":"https://acme.zoom.us/s/abcToken123"}]}}
CHKSSO
CZ="$(MEETING_CACHE="$CT/zoom.json"  "$CONFIG_DIR/plugins/open_conf.sh" --print 2>/dev/null)"
CM="$(MEETING_CACHE="$CT/teams.json" "$CONFIG_DIR/plugins/open_conf.sh" --print 2>/dev/null)"
CS="$(MEETING_CACHE="$CT/sso.json"   "$CONFIG_DIR/plugins/open_conf.sh" --print 2>/dev/null)"
is "zoom -> zoommtg app URI"  "$CZ" "zoommtg://acme.zoom.us/join?confno=99887766&pwd=SEKRIT"
is "zoom /s/ token stays https" "$CS" "https://acme.zoom.us/s/abcToken123"
case "$CM" in msteams://teams.microsoft.com/l/meetup-join/*) ok "teams -> msteams app URI" ;;
              *) bad "teams not translated (got '$CM')" ;; esac
rm -rf "$CT"

# Calendar rows must target the detail view. htmlLink redirects to the week
# view - verified against the live tab title - so the eid/eventedit form is used.
CCAL="$( set +u; source "$CONFIG_DIR/colors.sh"; source "$CONFIG_DIR/cards/meeting.sh"
         card_rows 2>/dev/null | awk -F'\t' 'NR==1{print $4}' )"
case "$CCAL" in
  *"brave_tab.sh 2"*eventedit*) ok "calendar rows open the event detail" ;;
  *"brave_tab.sh 2"*)           ok "calendar rows focus tab 2 (no eid on this event)" ;;
  *) bad "first meeting row does not target Brave tab 2 (got '$CCAL')" ;;
esac

# Productive: detail rows go to tab 3; the planning rows deliberately do not -
# they start a timer on that project instead, which is the point of them.
CPROD="$( set +u; source "$CONFIG_DIR/colors.sh"; source "$CONFIG_DIR/cards/productive.sh"
          card_rows 2>/dev/null | awk -F'\t' '{print $4}' | sort -u )"
CP_TAB="$(printf '%s\n' "$CPROD" | grep -c 'brave_tab.sh 3' || true)"
CP_START="$(printf '%s\n' "$CPROD" | grep -c 'productive_start.sh' || true)"
CP_OTHER="$(printf '%s\n' "$CPROD" | grep -cv 'brave_tab.sh 3\|productive_start.sh' || true)"
[ "$CP_TAB" -ge 1 ] && [ "$CP_OTHER" -eq 0 ] \
  && ok "productive rows -> tab 3 ($CP_TAB) or start-timer ($CP_START)" \
  || bad "productive rows disagree: $CPROD"

# The plan is the TAIL of this card, so it is what a too-small budget eats:
# five detail rows go out first and the planning rows take the remainder.
# Fixture-driven with a fuller week than the live cache holds, because the real
# one is only as long as this week happens to be.
PT="$(mktemp -d)"
printf '%s' '{"running":true,"project":"aaaa-0001","budget":"Budget","service":"Svc",
  "elapsed":"1h 02m","started_at":"2026-09-01T09:12:00+02:00","note":"a note"}' > "$PT/timer.json"
jq -nc '[range(10) | {project:"proj-\(.)", project_id:"\(.)",
                      service_id:"\(1000+.)", service:"Senior Architect"}]' > "$PT/plan.json"
# shellcheck source=/dev/null
PROWS="$( set +u; source "$CONFIG_DIR/colors.sh"; source "$CONFIG_DIR/cards/productive.sh"
          export PRODUCTIVE_CACHE="$PT/timer.json" PRODUCTIVE_PLAN_CACHE="$PT/plan.json"
          card_rows 2>/dev/null | grep -c . )"
is "productive emits 5 detail rows plus every planned project" "$PROWS" "15"
[ "$PROWS" -le "$(card_rows_max productive)" ] \
  && ok "productive fits its budget of $(card_rows_max productive) rows" \
  || bad "productive needs $PROWS rows but its budget is $(card_rows_max productive)"
rm -rf "$PT"

# A booking must never be lost between Productive and the card. Two failures
# lived in the joins and neither showed up anywhere: two bookings on ONE
# project (two budgets - this week's real shape) were collapsed into one row by
# unique_by(.project_id), and a project you have never tracked against was
# dropped whole by a select() on your own history. Both are invisible in the
# cache, because the cache is the thing that lost them, so this drives
# productive_plan.sh --plan with fixtures instead: the API half cannot be
# tested, the join half is where the rows die.
PP="$(mktemp -d)"
cat > "$PP/svc.json" <<'CHKPLAN'
{"data":[
 {"id":"111","attributes":{"name":"Senior Architect"},"relationships":{"deal":{"data":{"id":"d1"}}}},
 {"id":"222","attributes":{"name":"Senior Architect (def)"},"relationships":{"deal":{"data":{"id":"d2"}}}},
 {"id":"333","attributes":{"name":"Arch Lead"},"relationships":{"deal":{"data":{"id":"d3"}}}}],
 "included":[
 {"id":"d1","type":"deals","attributes":{"name":"policy-rule-engine"},"relationships":{"project":{"data":{"id":"p1"}}}},
 {"id":"d2","type":"deals","attributes":{"name":"healthcare-2dot0"},"relationships":{"project":{"data":{"id":"p1"}}}},
 {"id":"d3","type":"deals","attributes":{"name":"discovery"},"relationships":{"project":{"data":{"id":"p2"}}}},
 {"id":"p1","type":"projects","attributes":{"name":"vbrb-0001"}},
 {"id":"p2","type":"projects","attributes":{"name":"newly-booked"}}]}
CHKPLAN
# History on p1 only, and on d2 through a service you were NOT booked on: the
# same-budget preference is what has to keep the two p1 rows on their own
# budgets instead of both starting the project's most-used service.
cat > "$PP/usage.json" <<'CHKUSE'
[{"service_id":"111","uses":9,"project":"vbrb-0001","project_id":"p1","deal_id":"d1","service":"Senior Architect"},
 {"service_id":"999","uses":4,"project":"vbrb-0001","project_id":"p1","deal_id":"d2","service":"Delivery"}]
CHKUSE
PPR="$("$CONFIG_DIR/plugins/productive_plan.sh" --plan "$PP/svc.json" "$PP/usage.json" 2>/dev/null)"
is "every booking becomes a row" "$(printf '%s' "$PPR" | jq -r 'length')" "3"
is "two budgets on one project stay two rows" \
   "$(printf '%s' "$PPR" | jq -r '[.[]|select(.project=="vbrb-0001")|.budget]|sort|join(",")')" \
   "healthcare-2dot0,policy-rule-engine"
is "each row starts a timer on its own budget" \
   "$(printf '%s' "$PPR" | jq -r '[.[]|select(.project=="vbrb-0001")]|sort_by(.budget)|map(.service_id)|join(",")')" \
   "999,111"
is "a project with no history keeps its row" \
   "$(printf '%s' "$PPR" | jq -r '[.[]|select(.project=="newly-booked")]|length')" "1"
is "and that row has no service to start" \
   "$(printf '%s' "$PPR" | jq -r '.[]|select(.project=="newly-booked")|.service_id')" ""
# on_budget is what plan_fill keys off, so the flag has to mean what it says:
# only the booking history could not place on its own budget carries false.
is "only the unplaced booking is flagged off-budget" \
   "$(printf '%s' "$PPR" | jq -r '[.[]|select(.on_budget==false)|.project]|join(",")')" \
   "newly-booked"

# ...and the card renders that row rather than skipping it: the loop used to
# `continue` on an empty service_id, which is a third place a booking died.
printf '%s' "$PPR" > "$PP/plan.json"
printf '%s' '{"running":false}' > "$PP/idle.json"
# shellcheck source=/dev/null
PCR="$( set +u; source "$CONFIG_DIR/colors.sh"; source "$CONFIG_DIR/cards/productive.sh"
        export PRODUCTIVE_CACHE="$PP/idle.json" PRODUCTIVE_PLAN_CACHE="$PP/plan.json"
        card_rows 2>/dev/null )"
is "card shows 2 detail rows and all 3 bookings" "$(printf '%s\n' "$PCR" | grep -c .)" "5"
is "the two budgets are told apart on the card" \
   "$(printf '%s\n' "$PCR" | awk -F'\t' '$3 ~ /vbrb-0001/ {print $3}' | sort | tr '\n' '/')" \
   "vbrb-0001  ·  healthcare-2dot0/vbrb-0001  ·  policy-rule-engine/"
is "the unstartable booking opens the timesheet" \
   "$(printf '%s\n' "$PCR" | awk -F'\t' '$3 ~ /newly-booked/ {print $4}')" \
   "$CONFIG_DIR/plugins/brave_tab.sh 3"
rm -rf "$PP"

# Media's actionable rows. This asserted exactly ONE, the transport control, at
# the end - both facts are now wrong by design. The card grew an "Add to <year>"
# row, so there are two; and the transport row is DROPPED once the track is
# known to be in the playlist, so the add row is last and play/pause may be
# absent entirely. What is still worth pinning is the pair of invariants the
# card must never break: the add row is always offered while something is
# playing, and it is always the last actionable row - a stray click at the
# bottom of the card must never hit playback.
#
# With no session at all (fresh boot, nothing ever played) the card correctly
# renders "Nothing playing" plus its outcome row instead - a second right shape,
# not a failure, so the transport rules are asserted only when there IS a track.
CMED="$( set +u; source "$CONFIG_DIR/colors.sh"; source "$CONFIG_DIR/cards/media.sh"; card_rows 2>/dev/null )"
CACT="$(printf '%s\n' "$CMED" | awk -F'\t' '$4!=""' | wc -l | tr -d ' ')"
CLASTACT="$(printf '%s\n' "$CMED" | awk -F'\t' '$4!=""{a=$4} END{print a}')"
CMROWS="$(printf '%s\n' "$CMED" | grep -c . | tr -d ' ')"
CMTEXT="$(printf '%s\n' "$CMED" | awk -F'\t' 'NR==1{print $3}')"
if [ "$CMTEXT" = "Nothing playing" ]; then
  # The add row is not offered with nothing playing, so nothing here is
  # actionable. The outcome row may or may not be present depending on whether
  # a click happened in the last 30s, which is why the count is not pinned.
  is "media: no session, nothing actionable" "$CACT" "0"
else
  case "$CLASTACT" in
    *spotify_playlist_add.sh*) ok "the add row is the last actionable row" ;;
    *) bad "last actionable media row is not the playlist add (got '$CLASTACT')" ;;
  esac
  # Transport is optional now, but when it IS drawn it must still be the only
  # other action - a third actionable row would mean something new slipped in
  # unnoticed.
  case "$CACT" in
    1|2) ok "media has $CACT actionable row(s)" ;;
    *)   bad "media has $CACT actionable rows, expected 1 (in playlist) or 2" ;;
  esac
fi

echo "media card artwork:"
# The cover is the popup's background image, which sketchybar draws flush left
# and full-height behind the rows. So its square has to equal the popup's
# height, and the popup is exactly as tall as the rows the card emits - two
# facts kept in step by hand in media_lib.sh. Nothing in the drawing path can
# notice them drifting apart; a clipped cover is the only symptom.
MPOPH="$(sketchybar --query media 2>/dev/null | jq -r '.popup.height')"
# A 1x1 PNG - the smallest thing that is genuinely an image, so the extract is
# exercised on real bytes rather than on a mock, and on the PNG that plenty of
# players publish rather than only on the JPEG that Music does.
ART_FIX="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/wcAAwAB/8lJIVEAAAAASUVORK5CYII="
MART="$( set +u
  source "$CONFIG_DIR/colors.sh"
  source "$CONFIG_DIR/plugins/media_lib.sh"
  # Never the live path: the assertions below overwrite it and then delete it,
  # and the bar is drawing the current track from it right now.
  ART_JPG="$SB_CACHE_DIR/check-media-art.jpg"
  echo "row_h=$ART_ROW_H"
  echo "px=$ART_PX"
  echo "has_empty=$(art_has ""     && echo yes || echo no)"
  echo "has_null=$( art_has "null" && echo yes || echo no)"
  echo "has_real=$( art_has "x"    && echo yes || echo no)"
  echo "rows_bare=$(  art_rows ""  "")"
  echo "rows_artist=$(art_rows "a" "null")"
  echo "rows_both=$(  art_rows "a" "b")"

  art_extract "$ART_FIX"; echo "fix_exit=$?"
  echo "fix_type=$(file -b "$ART_JPG" 2>/dev/null | awk '{print $1}')"
  echo "fix_dims=$(sips -g pixelWidth "$ART_JPG" 2>/dev/null | awk '/pixelWidth/{print $2}')x$(sips -g pixelHeight "$ART_JPG" 2>/dev/null | awk '/pixelHeight/{print $2}')"

  # A track with no cover at all, straight after one that had it: the file the
  # popup would still be pointing at has to be gone, not merely unassigned.
  art_extract "null"; echo "null_exit=$?"
  [ -f "$ART_JPG" ] && echo "null_gone=no" || echo "null_gone=yes"

  # base64 --decode turns "null" into three bytes of junk without complaint, so
  # bytes that are not an image are their own case, and must not survive either.
  art_extract "$ART_FIX" >/dev/null 2>&1
  art_extract "$(printf 'notanimage' | base64)"; echo "junk_exit=$?"
  [ -f "$ART_JPG" ] && echo "junk_gone=no" || echo "junk_gone=yes"
  rm -f "$ART_JPG" "$ART_JPG.new"

  # sips exits 0 for an input it never managed to read and writes nothing, so a
  # cover that failed to land has to report failure anyway - the alternative is
  # a popup left pointed at a file that is not there, which draws the last one.
  ( ART_JPG="/nonexistent/media-art.jpg"; art_extract "$ART_FIX" ) >/dev/null 2>&1
  echo "unwritable_exit=$?"

  # The mirror: what the card really prints, against what the cover was cut for.
  raw="$(nowplaying-cli get title artist album 2>/dev/null)"
  { IFS= read -r t; IFS= read -r ar; IFS= read -r al; } <<ARTEOF
$raw
ARTEOF
  if art_has "$t"; then
    source "$CONFIG_DIR/cards/media.sh"
    n="$(card_rows 2>/dev/null | grep -c .)"
    want="$(art_rows "$ar" "$al")"
    # >=, not =. art_rows is a FLOOR now rather than a prediction: the card's
    # real height also depends on whether the transport row was dropped and
    # whether an outcome toast is live, neither of which the tick can see, so
    # cards/media.sh re-runs art_show with its true count when the popup opens.
    # What must still hold is that the tick never cuts the cover TALLER than the
    # card - that is the direction that overruns the popup - so the floor has to
    # stay at or below what the card actually emits.
    [ "$n" -ge "$want" ] && echo "mirror=yes" || echo "mirror=no"
    echo "mirror_detail=card $n vs art_rows floor $want"
  else
    echo "mirror=skip"
  fi )"
mart() { printf '%s\n' "$MART" | awk -F= -v k="$1" '$1==k{print $2}'; }
is "cover square tracks popup row height" "$(mart row_h)" "$MPOPH"
is "art_has rejects empty"        "$(mart has_empty)" "no"
is "art_has rejects null"         "$(mart has_null)"  "no"
is "art_has accepts a value"      "$(mart has_real)"  "yes"
is "bare track is title+transport" "$(mart rows_bare)"   "2"
is "artist adds a row"             "$(mart rows_artist)" "3"
is "artist and album add two"      "$(mart rows_both)"   "4"
is "fixture extracts"             "$(mart fix_exit)" "0"
is "fixture stored as JPEG"       "$(mart fix_type)" "JPEG"
is "fixture fills the square"     "$(mart fix_dims)" "$(mart px)x$(mart px)"
is "no cover -> nonzero"          "$(mart null_exit)" "1"
is "no cover -> no stale file"    "$(mart null_gone)" "yes"
is "non-image bytes -> nonzero"   "$(mart junk_exit)" "1"
is "non-image bytes -> no stale file" "$(mart junk_gone)" "yes"
is "cover that cannot be written -> nonzero" "$(mart unwritable_exit)" "1"
case "$(mart mirror)" in
  yes)  ok "the cover's square never exceeds the card's height" ;;
  skip) ok "row mirror: no session" ;;
  *)    bad "art_rows floor is taller than the card ($(mart mirror_detail))" ;;
esac

echo "clock card:"
# The ISO week is the whole reason this card exists - macOS surfaces it nowhere
# and the weekly rhythm is named by it - so it is asserted against date itself.
KROWS="$( set +u; source "$CONFIG_DIR/colors.sh"; source "$CONFIG_DIR/cards/clock.sh"
          card_rows 2>/dev/null )"
# Prefix, not equality: the week and the long date share row 1 now (merged to
# free a row for the chart), and the pace clause after them moves with the
# weekday. Pinning the whole string would make this fail every day for a
# formatting reason rather than a correctness one.
case "$(printf '%s\n' "$KROWS" | awk -F'\t' 'NR==1{print $3}')" in
  "Week $(date +%V)"*) ok "week row matches date +%V" ;;
  *) bad "week row does not start with 'Week $(date +%V)' (got '$(printf '%s\n' "$KROWS" | awk -F'\t' 'NR==1{print $3}')')" ;;
esac
nonempty "hours row" "$(printf '%s\n' "$KROWS" | awk -F'\t' 'NR==2{print $3}')"
is "no row spills past four fields" \
   "$(printf '%s\n' "$KROWS" | awk -F'\t' 'NF>4' | grep -c . | tr -d ' ')" "0"

# Opening this card must never wait on the Productive API, so the hours row
# reads productive_week.sh's cache or shows nothing. Three ways to have no
# figure - no file, a file about another week, a file too old - and every one
# of them has to print the dash instead of a number.
KDIR="$(mktemp -d)"
# Row 2, not row 3. The card grew a progress bar directly under the hours line,
# so `sed -n 3p` was reading the bar - a row of block characters that matches
# none of the four cases below and would have failed all of them for the wrong
# reason.
khours() { ( set +u; source "$CONFIG_DIR/colors.sh"; SB_CACHE_DIR="$KDIR"
             source "$CONFIG_DIR/cards/clock.sh"; card_rows 2>/dev/null | sed -n 2p | cut -f3 ); }
KH="$(khours)"
case "$KH" in "—"*) ok "missing cache degrades to a dash" ;;
              *) bad "hours row invented a figure with no cache (got '$KH')" ;; esac
printf '{"week":"1970-W01","logged_minutes":999,"booked_minutes":2400}\n' > "$KDIR/productive-week.json"
KH="$(khours)"
case "$KH" in "—"*) ok "a cache about another week is not quoted" ;;
              *) bad "hours row quoted another week (got '$KH')" ;; esac
printf '{"week":"%s","logged_minutes":1680,"booked_minutes":2400}\n' "$(date +%G-W%V)" \
  > "$KDIR/productive-week.json"
# Prefix again: the row ends with a pace clause ("6h03 under pace") computed
# from how far into the week it is, so the tail changes every day and only the
# figures are worth pinning.
case "$(khours)" in
  "Logged  ·  28h / 40h  ·  "*) ok "this week's cache renders as hours" ;;
  *) bad "hours row is not 'Logged · 28h / 40h · …' (got '$(khours)')" ;;
esac
touch -t 200001010000 "$KDIR/productive-week.json"
KH="$(khours)"
case "$KH" in "—"*) ok "a stale cache is not quoted" ;;
              *) bad "hours row quoted a stale cache (got '$KH')" ;; esac
rm -rf "$KDIR"

# Pro-rated by how far into the week you are, which is the only way the figure
# means anything: 8h on Monday is fine and the same 8h on Wednesday is not.
# 2400 minutes = a 40h week.
# clock_hours_color was split into clock_week_expect (how much you should have
# logged by this weekday) and clock_pace_color (how the gap is coloured), so the
# card could show the expectation as the bar's ▒ zone as well as colour by it.
# Composed here to keep asserting the same five behaviours through the same
# three arguments - the split is an implementation detail, not a contract change.
kcolor() { ( set +u; source "$CONFIG_DIR/cards/clock.sh"
             clock_pace_color "$1" "$(clock_week_expect "$2" "$3")" ); }
is "8h on Monday is on track"      "$(kcolor 480 2400 1)"  "$GREEN"
is "8h by Wednesday is far behind" "$(kcolor 480 2400 3)"  "$RED"
is "15h by Wednesday is behind"    "$(kcolor 900 2400 3)"  "$YELLOW"
is "36h by Friday is on track"     "$(kcolor 2160 2400 5)" "$GREEN"
is "nothing booked stays dim"      "$(kcolor 0 0 3)"       "$FG_DIM"

# The jump-offs are half of what this card is for, and a row pointing at
# something that is not a command fails silently - it still draws.
KACT="$(printf '%s\n' "$KROWS" | awk -F'\t' 'NF==4{print $4}')"
KMISS=0
while IFS= read -r ka; do
  [ -z "$ka" ] && continue
  ka="${ka%% *}"
  [ -x "$ka" ] || command -v "$ka" >/dev/null 2>&1 \
    || { bad "clock action '$ka' is not a command"; KMISS=1; }
done <<CHKCLOCK
$KACT
CHKCLOCK
[ "$KMISS" -eq 0 ] && ok "every clock action resolves to a command"
# card.sh clears any action carrying one of these, which costs the row its
# click and nothing else - so it fails without a symptom. Obsidian's own
# obsidian:// URI carries an `&`, which is why the note row uses `open -a`.
is "no clock action trips card.sh's filter" "$(printf '%s\n' "$KACT" | tr -cd ';`$|&<>()')" ""
case "$KACT" in
  *"brave_tab.sh 2"*"r/day"*) ok "calendar row opens the day view in tab 2" ;;
  *) bad "clock has no day-view row for Brave tab 2" ;;
esac
case "$KACT" in *"brave_tab.sh 3"*) ok "timesheet row focuses tab 3" ;;
                *) bad "clock has no timesheet row" ;; esac

echo "untrusted text:"
# Row text is free text from calendars, Productive, nowplaying and SSIDs, and
# the row separator is a tab - so a tab inside one shifts everything after it
# into the action field, which card.sh hands to sh.
is "card_text strips tabs"     "$(card_text "$(printf 'a\tb')")" "ab"
is "card_text strips newlines" "$(card_text "$(printf 'a\nb')")" "ab"
# The cache holds event bodies, join links with their passcodes and timesheets.
is "cache dir is ours alone" "$(stat -f %Lp "$SB_CACHE_DIR" 2>/dev/null)" "700"

# A calendar invite is the one input a stranger writes: anyone who can invite
# you fills in these fields. Nothing in a crafted one may reach a row's action.
UT="$(mktemp -d)"
cat > "$UT/evil.json" <<'CHKEVIL'
{"summary":"pwn\tx","location":"HQ-0-05\t; touch /tmp/sb-pwn",
 "description":"agenda\t`touch /tmp/sb-pwn`",
 "htmlLink":"https://www.google.com/calendar/event?eid=ab'; touch /tmp/sb-pwn;'cd&ctz=x"}
CHKEVIL
CEVIL="$( set +u; source "$CONFIG_DIR/colors.sh"; source "$CONFIG_DIR/cards/meeting.sh"
          MEETING_CACHE="$UT/evil.json" MEETING_UPCOMING="$UT/absent.json" card_rows 2>/dev/null )"
is "crafted invite keeps every row at four fields" \
   "$(printf '%s\n' "$CEVIL" | awk -F'\t' '{print NF}' | sort -u | tr -d '\n')" "4"
is "crafted invite cannot reach a row action" \
   "$(printf '%s\n' "$CEVIL" | awk -F'\t' '{print $4}' | tr -cd ';`$|&')" ""
# The eid is spliced inside a quoted URL, so a quote in it closes the command.
CEID="$( set +u; source "$CONFIG_DIR/colors.sh"; source "$CONFIG_DIR/cards/meeting.sh"
         meeting_event_link "$(cat "$UT/evil.json")" )"
is "crafted eid loses its quotes" "$(printf '%s' "$CEID" | tr -cd "';")" "''"
rm -rf "$UT"
[ -e /tmp/sb-pwn ] && { bad "a fixture actually executed something"; rm -f /tmp/sb-pwn; } \
                   || ok "no fixture command ran"

echo "label fitting:"
# The regression this guards: label.width referenced an undefined constant, so
# it expanded to 0 and both items rendered as a bare icon. The label VALUE was
# still correct, so nothing else noticed.
for it in meeting productive; do
  FD="$(sketchybar --query "$it" 2>/dev/null | jq -r '.geometry.drawing')"
  FL="$(sketchybar --query "$it" 2>/dev/null | jq -r '.label.value')"
  FW="$(sketchybar --query "$it" 2>/dev/null | jq -r '.bounding_rects|to_entries[0].value.size[0]|floor')"
  if [ "$FD" != "on" ]; then
    ok "$it hidden, nothing to fit"
  elif [ -n "$FL" ] && [ "${FW:-0}" -le 40 ] 2>/dev/null; then
    bad "$it has label '$FL' but renders only ${FW}pt (label.width 0?)"
  else
    ok "$it renders its label (${FW}pt)"
  fi
done

source "$CONFIG_DIR/plugins/fit.sh"
FLONG="$(printf 'x%.0s' $(seq 1 300))"
FFIT="$(fit_label productive "$FLONG")"
case "$FFIT" in
  *…) ok "fit_label ellipsises overlong text" ;;
  *)  bad "fit_label did not truncate (returned ${#FFIT} chars)" ;;
esac
[ "${#FFIT}" -lt 300 ] && ok "fit_label shortened 300 -> ${#FFIT} chars" || bad "fit_label returned full length"
# Short text must pass through untouched, or every label gains a stray ellipsis.
FSHORT="$(fit_label productive "ok")"
is "fit_label leaves short text alone" "$FSHORT" "ok"
# A hidden item has no x. It must still truncate (from cache or the conservative
# default), or a newly-appearing meeting overruns the notch for a whole tick.
FHIDDEN="$(fit_label definitely_not_an_item "$FLONG")"
[ "${#FHIDDEN}" -lt 300 ] && ok "fit_label truncates without a laid-out item (${#FHIDDEN} chars)" \
                          || bad "fit_label passed 300 chars through for an unlaid-out item"

echo "herdr:"
# Byte-level glyph check, like caffeine: a dropped plane-15 glyph
# renders as a blank box with no other symptom.
HWANT="$(printf '\363\260\263\206' | xxd -p)"
HGOT="$(sketchybar --query herdr 2>/dev/null | jq -r '.icon.value' | tr -d '\n' | xxd -p)"
is "sheep glyph U+F0CC6 bytes" "$HGOT" "$HWANT"
# Fixture-driven, so the parse is tested no matter what herdr is doing live:
# one blocked, two working, one idle - and zero done, which must hide its digit.
HFIX='{"result":{"agents":[
  {"pane_id":"w1:p1","agent_status":"blocked","terminal_title_stripped":"fix the tests","cwd":"/a/blocked-dir"},
  {"pane_id":"w2:p1","agent_status":"working","terminal_title_stripped":"build things","cwd":"/a/build-dir"},
  {"pane_id":"w3:p1","agent_status":"working","terminal_title_stripped":"write docs","cwd":"/a/docs-dir"},
  {"pane_id":"w4:p1","agent_status":"idle","terminal_title_stripped":"waiting","cwd":"/a/idle-dir"}]}}'
HROWS="$(set +u; export HERDR_AGENT_JSON="$HFIX"; source "$CONFIG_DIR/cards/herdr.sh"; card_rows)"
# The card is a block per workspace now - a header, a rule, group rows, repo
# sub-lines and an overflow notice - so a bare row count no longer counts
# agents. Filter to the rows that carry an agent focus action, which is exactly
# the set that used to be the whole card.
HAGENTS="$(printf '%s\n' "$HROWS" | awk -F'\t' '$4 ~ /^herdr agent focus /')"
is "card lists every agent" "$(printf '%s\n' "$HAGENTS" | grep -c .)" 4
# head -1 of the whole card is the header row now; the ordering claim is about
# the agent rows, so it is asserted against those. Prefix match because the text
# is space-padded out to a fixed column pitch to fake the right-hand status
# column, and pinning the padding would make this a whitespace test.
case "$(printf '%s\n' "$HAGENTS" | head -1 | cut -f3)" in
  *"fix the tests"*) ok "blocked agent sorts first" ;;
  *) bad "blocked agent is not first (got '$(printf '%s\n' "$HAGENTS" | head -1 | cut -f3)')" ;;
esac
# Two things wrong with the old form of this. It required EVERY row to carry an
# agent focus, which the header, rule, repo and overflow rows deliberately do
# not; and `w[0-9]+` was wrong against real data regardless - herdr numbers
# workspaces in BASE 36, and this machine is running wB, wF, wQ, wS and wV right
# now, so the assertion would have failed on the live flock while passing on the
# decimal fixture. Now: rows either carry no action, or carry a well-formed
# agent-or-workspace focus.
is "every actionable row focuses an agent or a workspace" \
   "$(printf '%s\n' "$HROWS" | awk -F'\t' '$4 != "" && $4 !~ /^herdr (agent|workspace) focus [A-Za-z0-9:_-]+$/{bad=1} END{print bad+0}')" 0
HERDR_AGENT_JSON="$HFIX" "$CONFIG_DIR/plugins/herdr.sh"
is "blocked digit" "$(sketchybar --query herdr.blocked 2>/dev/null | jq -r '.label.value')" "1"
is "working digit" "$(sketchybar --query herdr.working 2>/dev/null | jq -r '.label.value')" "2"
is "zero-count digit hides" "$(sketchybar --query herdr.done 2>/dev/null | jq -r '.geometry.drawing')" "off"
is "sheep wears the urgent colour" "$(sketchybar --query herdr 2>/dev/null | jq -r '.icon.color')" "$RED"
"$CONFIG_DIR/plugins/herdr.sh"   # re-render from the live socket

# `claude` is drawn inside the herdr cluster but is the one item there the helper
# does not paint, so it carries its own update_freq and its own script - and a
# script that cannot run leaves the field blank with no other symptom. The EXIT
# STATUS is the assertion, not the output: with no rate-limit capture and no
# recent transcripts it legitimately prints nothing, and demanding a figure here
# would fail on a machine that simply has not used Claude Code this week.
[ -x "$CONFIG_DIR/plugins/claude_usage.sh" ] && ok "claude_usage.sh executable" \
                                             || bad "plugins/claude_usage.sh not executable"
"$CONFIG_DIR/plugins/claude_usage.sh" >/dev/null 2>&1 \
  && ok "claude_usage.sh exits 0" \
  || bad "claude_usage.sh exited $? (the claude item will stay blank)"
# Undotted on purpose. card.sh maps an item name straight onto cards/$ITEM.sh
# and $ITEM.pop.$N, so naming it herdr.claude to match its neighbours would send
# it looking for cards/herdr.claude.sh and the popup would never open.
"$CONFIG_DIR/plugins/card.sh" claude toggle >/dev/null 2>&1
CLROWS="$(sketchybar --query claude 2>/dev/null | jq -r '.popup.items[]?' | grep -c '^claude\.pop\.')"
[ "${CLROWS:-0}" -gt 0 ] && ok "claude card has rows" \
                         || bad "claude card has no popup rows - cards/claude.sh or the name is wrong"
"$CONFIG_DIR/plugins/card.sh" claude close >/dev/null 2>&1

echo "sb-helper:"
# The helper renders mic, volume and the herdr cluster from one process, and
# still SAMPLES the network without owning an item for it: the throughput is a
# row in the Wi-Fi card now, read out of helper-state.json. So the rate
# assertions below stay even though nothing on the bar draws a rate. It cannot
# be sourced the way a shell plugin can, so it answers --selftest with one
# key=value per line instead - that is what keeps this suite able to assert its
# arithmetic rather than only its side effects.
HELPER="$CONFIG_DIR/bin/sb-helper"
if [ ! -x "$HELPER" ]; then
  bad "bin/sb-helper not built (see ~/.cache/sketchybar/build-sb-helper.err)"
  HST=""
else
  ok "helper built"
  # A fixture drives the herdr half, the same hook plugins/herdr.sh honours, so
  # the counts under test do not depend on what herdr is really running.
  HFIX_H='{"result":{"agents":[
    {"pane_id":"w1:p1","agent_status":"blocked"},{"pane_id":"w2:p1","agent_status":"working"},
    {"pane_id":"w3:p1","agent_status":"working"},{"pane_id":"w4:p1","agent_status":"idle"}]}}'
  HST="$(SB_HELPER_HERDR_JSON="$HFIX_H" "$HELPER" --selftest 2>/dev/null)"
  [ -n "$HST" ] && ok "selftest ran" || bad "selftest produced nothing"
fi

hval() { printf '%s\n' "$HST" | awk -F= -v k="$1" '$1==k {print $2; exit}'; }

if [ -n "$HST" ]; then
  # Throughput must stay integers: a nil rate rendered as a label is how the
  # link once showed a multi-GB/s spike off a counter reset.
  case "$(hval net)" in
    [0-9]*/[0-9]*) ok "helper net rates = $(hval net)" ;;
    *)             bad "helper net rates not int/int (got '$(hval net)')" ;;
  esac
  # Five characters max. It used to be the measured label widths of the net_up
  # /net_down items that depended on this; those are gone, but the pair now
  # shares ONE row of the Wi-Fi card as "↓ x/s   ·   ↑ y/s", and that card is at
  # its full eight-row budget - so a rate that grows a character widens the
  # popup instead, toward the screen edge the "popups fit the screen" block
  # guards. humanRate() is unchanged, so this is still an exact match.
  is "helper rate formatting" "$(hval human)" "0B/2K/5.0M/200M"
  case "$(hval mic)" in 0|1) ok "helper mic = $(hval mic)" ;; *) bad "helper mic not 0/1 (got '$(hval mic)')" ;; esac
  case "$(hval volume)" in
    NONE)                 ok "helper volume: device exposes no scalar" ;;
    ''|*[!0-9]*)          bad "helper volume not an int (got '$(hval volume)')" ;;
    *)                    pct "helper volume" "$(hval volume)" ;;
  esac
  case "$(hval muted)" in 0|1) ok "helper muted = $(hval muted)" ;; *) bad "helper muted not 0/1" ;; esac
  is "helper counts the fixture flock" "$(hval herdr)" "1/2/0/1/0"
  is "helper tints by the urgent state" "$(hval tint)" "$RED"
  # sb-helper.swift carries its own copy of the palette - it starts once, and
  # sourcing colors.sh would reintroduce the fork the helper exists to remove.
  # This is the guard on that duplication.
  is "helper palette matches colors.sh" "$(hval colors)" \
     "$RED,$BLUE,$GREEN,$FG_DIM,$ORANGE,$YELLOW,$AQUA"
fi

echo "sb-helper ownership:"
# Guards the whole point of the helper: if one of these regains an update_freq
# it is being polled by a forked script again, and the duty cycle quietly
# returns to what it was. The items keep script= for event dispatch (card
# closing), which is correct - only a nonzero update_freq means polling.
if pgrep -x sb-helper >/dev/null 2>&1; then
  ok "helper process running"
  for i in mic volume herdr; do
    UF="$(sketchybar --query "$i" 2>/dev/null | jq -r '.scripting.update_freq // 0')"
    [ "${UF:-0}" = "0" ] && ok "$i has no poll timer" \
                         || bad "$i is polling again (update_freq=$UF)"
  done
  # Set by the helper itself, once it has claimed the bootstrap name - that is
  # what makes a scroll instant instead of a ~107ms wait on osascript.
  VU="$(sketchybar --query volume 2>/dev/null | jq -r '.scripting.update_mask // 0')"
  [ "${VU:-0}" -gt 0 ] 2>/dev/null && ok "volume still subscribed to its events" \
                                   || bad "volume lost its event subscriptions"
else
  # Legitimate state: no toolchain, or a failed build. sketchybarrc restores the
  # shell timers in that case, so assert the FALLBACK rather than the helper.
  ok "helper not running, checking shell fallback"
  # mic and herdr only: sketchybarrc's fallback hands volume a script but no
  # timer (it is event-driven), and there is no net item left to restore a
  # sampler to - without the helper the Wi-Fi card's throughput row simply
  # reports nothing, which is the honest outcome and not a failure here.
  for i in mic herdr; do
    UF="$(sketchybar --query "$i" 2>/dev/null | jq -r '.scripting.update_freq // 0')"
    [ "${UF:-0}" != "0" ] && ok "$i fell back to polling (update_freq=$UF)" \
                          || bad "$i has neither a helper nor a poll timer - it will never update"
  done
fi

echo "mic card:"
# The card and the indicator must never contradict each other: a red "mic in
# use" over a card saying nothing is capturing, or the reverse, is worse than
# either alone. Both read the same CoreAudio call in the same binary, and
# --selftest reports whether they agreed at the same instant.
if [ -x "$CONFIG_DIR/bin/sb-helper" ]; then
  is "item and card agree on mic state" "$(hval mic_agree)" "1"
  MC="$(hval mic_consumers)"
  case "$MC" in ''|*[!0-9]*) bad "consumer count not an int (got '$MC')" ;;
                *)           ok "helper reports $MC mic consumer(s)" ;; esac
  # An unknown flag must NOT be taken for a bootstrap name: the default mode of
  # this binary is to daemonise, so a typo used to fork a second helper holding
  # a junk name and fighting the real one over the same items, silently.
  "$CONFIG_DIR/bin/sb-helper" --not-a-real-flag >/dev/null 2>&1
  is "unknown option is rejected, not daemonised" "$?" "2"
fi
MROWS="$( set +u; source "$CONFIG_DIR/colors.sh"; source "$CONFIG_DIR/cards/mic.sh"
          card_rows 2>/dev/null )"
nonempty "mic card emits rows" "$MROWS"
# The privacy pane was the item's old click action; it has to survive as a row
# or the click that used to reach it now reaches nothing.
case "$MROWS" in
  *Privacy_Microphone*) ok "privacy pane still reachable from the card" ;;
  *) bad "mic card lost the privacy settings row" ;;
esac
# Every row must carry a glyph and text, and no action may trip card.sh's
# metacharacter filter - an app name is free text off a filesystem path.
MBAD=0
while IFS="$(printf '\t')" read -r mg mc mt ma; do
  [ -z "$mg" ] && { bad "mic row has no glyph"; MBAD=1; break; }
  [ -z "$mt" ] && { bad "mic row has no text";  MBAD=1; break; }
  case "$mc" in 0x*) ;; *) bad "mic row colour '$mc' not from the palette"; MBAD=1; break ;; esac
  case "$ma" in *[\;\|\&\$\`\\\<\>\(\)]*) bad "mic action would be stripped: '$ma'"; MBAD=1; break ;; esac
done <<MICCHK
$MROWS
MICCHK
[ "$MBAD" -eq 0 ] && ok "mic rows well-formed ($(printf '%s' "$MROWS" | grep -c .) rows)"
# The empty state must say so rather than render an unexplained bare list. A
# stub CONFIG_DIR whose sb-helper prints nothing is the no-consumer case; the
# real one cannot be forced to report zero while anything is capturing.
MSTUB="$(mktemp -d)"
mkdir -p "$MSTUB/bin" "$MSTUB/plugins" "$MSTUB/cards"
printf '#!/bin/sh\nexit 0\n' > "$MSTUB/bin/sb-helper"; chmod +x "$MSTUB/bin/sb-helper"
cp "$CONFIG_DIR/plugins/app_icon.sh" "$MSTUB/plugins/"
cp "$CONFIG_DIR/cards/mic.sh" "$MSTUB/cards/"
MEMPTY="$( set +u; source "$CONFIG_DIR/colors.sh"; CONFIG_DIR="$MSTUB"
           source "$MSTUB/cards/mic.sh"; card_rows 2>/dev/null | head -1 | cut -f3 )"
rm -rf "$MSTUB"
case "$MEMPTY" in
  *"Nothing is using the mic"*) ok "empty state names itself" ;;
  *) bad "no-consumer path did not render the empty row (got '$MEMPTY')" ;;
esac

echo "popups fit the screen:"
# A popup grows from its owner in the direction of popup.align, and nothing
# stops it leaving the display. The clock found this the hard way: rightmost
# item, card_popup's align=left, and the widest row ran 72pt past a 1728pt
# screen - the hours figure simply was not there. Cheap to assert, invisible
# otherwise, and it has to be measured per card because it depends on the
# owner's x, the align, and the widest row's text.
read -r _ _ _ PS_W <<<"$("$CONFIG_DIR/bin/screen-metrics" 2>/dev/null)"
PS_W="${PS_W%.*}"
case "${PS_W:-0}" in
  ''|*[!0-9]*|0) ok "screen width unreadable, skipping popup fit" ;;
  *)
    for c in $CARD_ITEMS; do
      "$CONFIG_DIR/plugins/card.sh" "$c" open >/dev/null 2>&1
      PS_MAX=0; PS_MIN=999999
      PS_N=1
      while [ "$PS_N" -le "$(card_rows_max "$c" 2>/dev/null || echo "${CARD_ROWS:-8}")" ]; do
        read -r PS_L PS_R <<<"$(sketchybar --query "$c.pop.$PS_N" 2>/dev/null \
          | jq -r '.bounding_rects|to_entries[0].value|select(.origin[0] > -9000)|"\(.origin[0]|floor) \((.origin[0]+.size[0])|floor)"')"
        case "${PS_R:-}" in ''|*[!0-9-]*) : ;; *)
          [ "$PS_R" -gt "$PS_MAX" ] && PS_MAX="$PS_R"
          [ "$PS_L" -lt "$PS_MIN" ] && PS_MIN="$PS_L" ;;
        esac
        PS_N=$(( PS_N + 1 ))
      done
      "$CONFIG_DIR/plugins/card.sh" "$c" close >/dev/null 2>&1
      if [ "$PS_MAX" -eq 0 ]; then
        ok "$c: card empty, nothing to fit"
      elif [ "$PS_MAX" -le "$PS_W" ] && [ "$PS_MIN" -ge 0 ]; then
        ok "$c: card spans $PS_MIN..$PS_MAX inside ${PS_W}pt"
      else
        bad "$c: card spans $PS_MIN..$PS_MAX, outside the ${PS_W}pt screen"
      fi
    done ;;
esac

echo "reserved inset:"
# The bar draws in space macOS does not reserve for it, so omniwm has to. On an
# external display visibleFrame equals frame - nothing is reserved at all - and
# with topmost=off every tiled window covers the bar completely. The symptom is
# "the bar is gone on my monitor", the cause is a number in a file this repo
# does not contain, and nothing else in this suite would notice.
#
# Asserted against $BAR_H - the LIVE bar's height, queried at the top of this
# file - rather than a literal 38, so a re-measured bar cannot drift away from
# the gap that protects it. >= rather than ==, so scoping this per monitor later
# (monitorGapOverrides, or omniwm's Settings UI) still passes.
OW_GAPS="$(omniwmctl query displays --fields name,outer-gap-top --format json 2>/dev/null \
           | jq -r '..|objects|select(has("outerGapTop"))|"\(.outerGapTop)\t\(.name)"' 2>/dev/null)"
if [ -z "$OW_GAPS" ]; then
  bad "omniwm not answering, cannot verify the bar's reserved inset"
elif [ -z "$BAR_H" ] || [ "$BAR_H" = "null" ]; then
  # The bar itself is the reference, so without it there is nothing to compare
  # against and claiming a pass would be a tautology.
  bad "cannot read the bar's height, so the reserved inset is unverifiable"
else
  while IFS="$(printf '\t')" read -r gap name; do
    [ -n "$gap" ] || continue
    if [ "${gap%%.*}" -ge "${BAR_H%%.*}" ] 2>/dev/null; then
      ok "$name reserves ${gap%%.*}pt, bar is ${BAR_H%%.*}pt"
    else
      bad "$name reserves ${gap%%.*}pt but the bar is ${BAR_H%%.*}pt - windows will cover it"
    fi
  done <<OWEOF
$OW_GAPS
OWEOF
fi

echo "workspaces:"
# The bindings the pips claim to be a legend for. omniwm keeps its hotkeys in
# ~/.config/omniwm/settings.toml as [[hotkeys]] blocks pairing an `id` with a
# `binding`, so the claim is asserted against that file the way it used to be
# against the old manager's config. Matched on the PAIR - the id line follows
# the binding line inside one block - because grepping for the binding alone
# would pass on any block that happens to carry it.
OW_CONF="$HOME/.config/omniwm/settings.toml"
if [ ! -r "$OW_CONF" ]; then
  bad "omniwm settings unreadable at $OW_CONF"
else
  for sid in $SPACE_IDS; do
    # switchWorkspace is 0-indexed against a 1-indexed pip: Option+1 is
    # switchWorkspace.0. Getting this backwards asserts a binding that exists
    # for the wrong workspace, which passes and means nothing.
    want_id="switchWorkspace.$(( sid - 1 ))"
    awk -v id="$want_id" -v key="Option+$sid" '
      /^\[\[hotkeys\]\]/ { b = "" }
      /^binding = / { gsub(/binding = |"/, ""); b = $0 }
      /^id = / { gsub(/id = |"/, ""); if ($0 == id && b == key) { found = 1 } }
      END { exit !found }' "$OW_CONF" \
      && ok "Option+$sid switches to workspace $sid" \
      || bad "Option+$sid is not bound to $want_id in settings.toml"
  done

  # omniwm has no config-level callback; the watcher started by sketchybarrc is
  # what turns its IPC stream into the wm_workspace_change trigger, so its
  # absence is why the pips would stop repainting on a switch.
  # ps, not pgrep: pgrep needs sysmond and has failed outright on this machine.
  ps -Ao args= | grep -q '[o]mniwmctl watch active-workspace' \
    && ok "omniwm event watcher running" \
    || bad "no omniwmctl watcher - pips will not repaint on a switch"
  omniwmctl ping >/dev/null 2>&1 \
    && ok "omniwm ipc reachable" \
    || bad "omniwm ipc unreachable (enable it from the OmniWM menu bar)"
fi

# Item set and paint set, same drift guard as the card rows: sketchybarrc
# creates one pip per id and the plugin addresses one pip per id, both out of
# $SPACE_IDS, so another workspace is wired in by editing colors.sh alone.
SB_ITEMS="$(sketchybar --query bar 2>/dev/null | jq -r '.items[]')"
for sid in $SPACE_IDS; do
  printf '%s\n' "$SB_ITEMS" | grep -qx "space.$sid" \
    && ok "space.$sid exists" || bad "space.$sid missing from the bar"
done
printf '%s\n' "$SB_ITEMS" | grep -qx "space_watch" \
  && ok "space_watch paints them" || bad "space_watch missing from the bar"

# The live paint. Exactly one pill, on the workspace omniwm says is current:
# two pills means a repaint that only ever turned one on, none means the cluster
# is showing you nothing at all. Read through the plugin's own query so the
# suite cannot drift from what the bar actually asks.
WS_FOCUSED="$("$CONFIG_DIR/plugins/workspaces.sh" --print-focused 2>/dev/null)"
if [ -z "$WS_FOCUSED" ]; then
  ok "omniwm not answering, skipping the live paint"
else
  WS_PILLS=""
  for sid in $SPACE_IDS; do
    [ "$(sketchybar --query "space.$sid" 2>/dev/null | jq -r '.geometry.background.drawing')" = "on" ] \
      && WS_PILLS="$WS_PILLS$sid"
  done
  printf '%s\n' "$SPACE_IDS" | grep -qw "$WS_FOCUSED" \
    && is "the pill is on the focused workspace" "$WS_PILLS" "$WS_FOCUSED" \
    || is "focused workspace $WS_FOCUSED is off the cluster, no pill" "$WS_PILLS" ""
fi

echo "deps:"
# timeout is Homebrew coreutils, not stock macOS: meeting_fetch.sh loses its
# hang watchdog without it, and gws is the calendar itself - a missing one
# hides the meeting item, which looks exactly like an auth failure.
for d in jq nowplaying-cli timeout gws; do
  command -v "$d" >/dev/null && ok "$d" || bad "$d missing"
done

echo "colors:"
is "palette exported" "${FG:0:2}" "0x"

exit $fail
