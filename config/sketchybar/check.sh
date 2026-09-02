#!/usr/bin/env bash
# Smallest thing that fails if the plugin logic breaks. Run: ./check.sh
set -u
export CONFIG_DIR="${CONFIG_DIR:-$(cd "$(dirname "$0")" && pwd)}"
source "$CONFIG_DIR/colors.sh"
source "$CONFIG_DIR/plugins/app_icon.sh"
source "$CONFIG_DIR/plugins/sys_lib.sh"
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

echo "system.sh readings:"
# The helpers themselves, not a hand-copied pipeline: the old copy asserted a
# `top` sampling loop the plugin had already stopped using, so it kept passing
# while measuring nothing the bar runs - and cost this suite 1.7s a go.
pct "cpu" "$(cpu_pct)"
pct "mem" "$(mem_pct)"

echo "battery.sh parse:"
pct "battery" "$(pmset -g batt | grep -Eo '[0-9]+%' | head -1 | tr -d '%')"

echo "wifi.sh parse:"
WIFI_IF="$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}')"
nonempty "wifi interface" "$WIFI_IF"
# SSID is legitimately empty when not associated, so only assert it does not error.
ipconfig getsummary "${WIFI_IF:-en0}" >/dev/null 2>&1 && ok "ipconfig getsummary" || bad "ipconfig getsummary failed"

echo "network.sh parse:"
NET_IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
nonempty "default interface" "$NET_IF"
read -r RX TX <<<"$(netstat -ibn -I "${NET_IF:-en0}" | awk 'NR>1 {print $(NF-4), $(NF-1); exit}')"
[ "${RX:-x}" -ge 0 ] 2>/dev/null && ok "rx counter = $RX" || bad "rx counter not an int (got '$RX')"
[ "${TX:-x}" -ge 0 ] 2>/dev/null && ok "tx counter = $TX" || bad "tx counter not an int (got '$TX')"

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

echo "power.sh:"
# Assert the real bytes: a grep for the literal matches an EMPTY icon="" too,
# which is exactly how a dropped glyph passed this check before.
WANT="$(printf '\357\205\271' | xxd -p)"
GOT="$(sketchybar --query power 2>/dev/null | jq -r '.icon.value' | tr -d '\n' | xxd -p)"
is "apple glyph U+F179 bytes" "$GOT" "$WANT"
# Ask the script which actions it handles rather than grepping its case arms:
# the old grep pinned the indentation of every arm, so reformatting power.sh
# failed this suite with zero behaviour change.
PACT="$("$CONFIG_DIR/plugins/power.sh" --list-actions 2>/dev/null)"
for a in toggle close about settings appstore force lock sleep logout restart shutdown; do
  printf '%s\n' "$PACT" | grep -qx "$a" && ok "action $a" || bad "action $a missing"
done

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

echo "system stack:"
YC="$(sketchybar --query cpu 2>/dev/null | jq -r '.geometry.y_offset')"
YM="$(sketchybar --query mem 2>/dev/null | jq -r '.geometry.y_offset')"
XC="$(sketchybar --query cpu 2>/dev/null | jq -r '.bounding_rects|to_entries[0].value.origin[0]|floor')"
XM="$(sketchybar --query mem 2>/dev/null | jq -r '.bounding_rects|to_entries[0].value.origin[0]|floor')"
# Positive y_offset is up, so cpu must sit above mem.
if [ -n "$YC" ] && [ "$YC" != null ] && [ "${YC%.*}" -gt "${YM%.*}" ] 2>/dev/null; then
  ok "cpu row above mem row ($YC > $YM)"
else
  bad "cpu/mem y_offset order wrong or unreadable (cpu=$YC mem=$YM)"
fi
# SYS_ROW is only correct if the negative padding lands mem exactly on cpu.
if [ "$XC" = "$XM" ]; then
  ok "cpu/mem stacked at x=$XC"
else
  bad "SYS_ROW wrong: rows not aligned (cpu=$XC mem=$XM)"
fi

echo "network stack:"
YU="$(sketchybar --query net_up 2>/dev/null | jq -r '.geometry.y_offset')"
YD="$(sketchybar --query net_down 2>/dev/null | jq -r '.geometry.y_offset')"
XU="$(sketchybar --query net_up 2>/dev/null | jq -r '.bounding_rects|to_entries[0].value.origin[0]|floor')"
XD="$(sketchybar --query net_down 2>/dev/null | jq -r '.bounding_rects|to_entries[0].value.origin[0]|floor')"
# Positive y_offset is up, so net_up must sit above net_down.
if [ -n "$YU" ] && [ "$YU" != null ] && [ "${YU%.*}" -gt "${YD%.*}" ] 2>/dev/null; then
  ok "up row above down row ($YU > $YD)"
else
  bad "y_offset order wrong or unreadable (up=$YU down=$YD)"
fi
if [ -n "$XU" ] && [ "$XU" != null ] && [ "$XU" = "$XD" ]; then
  ok "rows stacked at x=$XU"
else
  bad "rows not stacked (up=$XU down=$XD)"
fi

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
# Byte-level, like the power glyph check: a grep for the literal matches a dropped glyph too.
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
done

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
# two quick clicks on different items.
"$CONFIG_DIR/plugins/card.sh" wifi toggle >/dev/null 2>&1
"$CONFIG_DIR/plugins/card.sh" cpu toggle  >/dev/null 2>&1
CO="$(sketchybar --query wifi 2>/dev/null | jq -r '.popup.drawing')$(sketchybar --query cpu 2>/dev/null | jq -r '.popup.drawing')"
is "opening one card closes the other" "$CO" "offon"
"$CONFIG_DIR/plugins/card.sh" cpu close >/dev/null 2>&1

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
grep -q -- "--set cpu popup.drawing=off" "$CAW/fresh" \
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
while [ "$CI" -le "$CARD_ROWS" ]; do
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

# Media: exactly one actionable row, and it is the transport control at the end.
# With no session at all (fresh boot, nothing ever played) the card correctly
# renders one actionless "Nothing playing" row instead - a second right shape,
# not a failure, so assert the transport rules only when there IS a session.
CMED="$( set +u; source "$CONFIG_DIR/colors.sh"; source "$CONFIG_DIR/cards/media.sh"; card_rows 2>/dev/null )"
CACT="$(printf '%s\n' "$CMED" | awk -F'\t' '$4!=""' | wc -l | tr -d ' ')"
CLAST="$(printf '%s\n' "$CMED" | tail -1 | awk -F'\t' '{print $4}')"
CMROWS="$(printf '%s\n' "$CMED" | grep -c . | tr -d ' ')"
CMTEXT="$(printf '%s\n' "$CMED" | awk -F'\t' 'NR==1{print $3}')"
if [ "$CMROWS" = "1" ] && [ "$CACT" = "0" ] && [ "$CMTEXT" = "Nothing playing" ]; then
  ok "media: no session"
else
  is "media has one actionable row" "$CACT" "1"
  case "$CLAST" in *togglePlayPause*) ok "play/pause is the last row" ;;
                   *) bad "last media row is not the transport control (got '$CLAST')" ;; esac
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
    [ "$n" = "$want" ] && echo "mirror=yes" || echo "mirror=no"
    echo "mirror_detail=card $n vs art_rows $want"
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
  yes)  ok "card rows match the square the cover is cut to" ;;
  skip) ok "row mirror: no session" ;;
  *)    bad "card rows and art_rows disagree ($(mart mirror_detail))" ;;
esac

echo "clock card:"
# The ISO week is the whole reason this card exists - macOS surfaces it nowhere
# and the weekly rhythm is named by it - so it is asserted against date itself.
KROWS="$( set +u; source "$CONFIG_DIR/colors.sh"; source "$CONFIG_DIR/cards/clock.sh"
          card_rows 2>/dev/null )"
is "week row matches date +%V" \
   "$(printf '%s\n' "$KROWS" | awk -F'\t' 'NR==1{print $3}')" "Week $(date +%V)"
nonempty "date row" "$(printf '%s\n' "$KROWS" | awk -F'\t' 'NR==2{print $3}')"
is "no row spills past four fields" \
   "$(printf '%s\n' "$KROWS" | awk -F'\t' 'NF>4' | grep -c . | tr -d ' ')" "0"

# Opening this card must never wait on the Productive API, so the hours row
# reads productive_week.sh's cache or shows nothing. Three ways to have no
# figure - no file, a file about another week, a file too old - and every one
# of them has to print the dash instead of a number.
KDIR="$(mktemp -d)"
khours() { ( set +u; source "$CONFIG_DIR/colors.sh"; SB_CACHE_DIR="$KDIR"
             source "$CONFIG_DIR/cards/clock.sh"; card_rows 2>/dev/null | sed -n 3p | cut -f3 ); }
KH="$(khours)"
case "$KH" in "—"*) ok "missing cache degrades to a dash" ;;
              *) bad "hours row invented a figure with no cache (got '$KH')" ;; esac
printf '{"week":"1970-W01","logged_minutes":999,"booked_minutes":2400}\n' > "$KDIR/productive-week.json"
KH="$(khours)"
case "$KH" in "—"*) ok "a cache about another week is not quoted" ;;
              *) bad "hours row quoted another week (got '$KH')" ;; esac
printf '{"week":"%s","logged_minutes":1680,"booked_minutes":2400}\n' "$(date +%G-W%V)" \
  > "$KDIR/productive-week.json"
is "this week's cache renders as hours" "$(khours)" "28h / 40h logged this week"
touch -t 200001010000 "$KDIR/productive-week.json"
KH="$(khours)"
case "$KH" in "—"*) ok "a stale cache is not quoted" ;;
              *) bad "hours row quoted a stale cache (got '$KH')" ;; esac
rm -rf "$KDIR"

# Pro-rated by how far into the week you are, which is the only way the figure
# means anything: 8h on Monday is fine and the same 8h on Wednesday is not.
# 2400 minutes = a 40h week.
kcolor() { ( set +u; source "$CONFIG_DIR/cards/clock.sh"; clock_hours_color "$1" "$2" "$3" ); }
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
# Byte-level glyph check, like power and caffeine: a dropped plane-15 glyph
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
is "card lists every agent"  "$(printf '%s' "$HROWS" | grep -c .)" 4
is "blocked agent sorts first" "$(printf '%s' "$HROWS" | head -1 | cut -f3)" "fix the tests  ·  blocked-dir"
is "every row focuses its pane" \
   "$(printf '%s' "$HROWS" | awk -F'\t' '$4 !~ /^herdr agent focus w[0-9]+:p[0-9]+$/{bad=1} END{print bad+0}')" 0
HERDR_AGENT_JSON="$HFIX" "$CONFIG_DIR/plugins/herdr.sh"
is "blocked digit" "$(sketchybar --query herdr.blocked 2>/dev/null | jq -r '.label.value')" "1"
is "working digit" "$(sketchybar --query herdr.working 2>/dev/null | jq -r '.label.value')" "2"
is "zero-count digit hides" "$(sketchybar --query herdr.done 2>/dev/null | jq -r '.geometry.drawing')" "off"
is "sheep wears the urgent colour" "$(sketchybar --query herdr 2>/dev/null | jq -r '.icon.color')" "$RED"
"$CONFIG_DIR/plugins/herdr.sh"   # re-render from the live socket

echo "sb-helper:"
# The helper renders cpu, mem, net_up/down, mic, volume and the herdr cluster
# from one process. It cannot be sourced the way a shell plugin can, so it
# answers --selftest with one key=value per line instead - that is what keeps
# this suite able to assert its arithmetic rather than only its side effects.
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
  pct "helper cpu" "$(hval cpu)"
  pct "helper mem" "$(hval mem)"
  pct "helper mem_resident" "$(hval mem_resident)"
  # The displayed memory number must stay the one memory_pressure reports: the
  # native page-sum reads far higher (it counts what is resident rather than
  # what cannot be reclaimed) and swapping to it would silently redefine the
  # item AND invalidate the 60/85 colour thresholds. Asserted within 3 points
  # of the shell reading, not equality - they are sampled moments apart.
  SHELL_MEM="$(memory_pressure 2>/dev/null | awk '/free percentage/ {gsub("%","",$NF); printf "%.0f", 100-$NF}')"
  HD=$(( $(hval mem) - ${SHELL_MEM:-0} )); HD=${HD#-}
  [ "$HD" -le 3 ] 2>/dev/null && ok "helper mem tracks memory_pressure ($(hval mem) vs $SHELL_MEM)" \
                              || bad "helper mem drifted from memory_pressure ($(hval mem) vs ${SHELL_MEM:-?})"
  # Throughput must stay integers: a nil rate rendered as a label is how the
  # link once showed a multi-GB/s spike off a counter reset.
  case "$(hval net)" in
    [0-9]*/[0-9]*) ok "helper net rates = $(hval net)" ;;
    *)             bad "helper net rates not int/int (got '$(hval net)')" ;;
  esac
  # Five characters max, or the measured label widths in sketchybarrc no longer
  # hold and the cluster grows into the notch.
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
  for i in cpu mem net_down mic volume herdr; do
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
  for i in mem net_down mic herdr; do
    UF="$(sketchybar --query "$i" 2>/dev/null | jq -r '.scripting.update_freq // 0')"
    [ "${UF:-0}" != "0" ] && ok "$i fell back to polling (update_freq=$UF)" \
                          || bad "$i has neither a helper nor a poll timer - it will never update"
  done
fi

echo "cpu card agrees with the bar:"
# The regression this guards is the one the helper could reintroduce: the card
# used to sum `ps` itself, so it and the item quoted different numbers for the
# same thing. The card now reads what the helper published.
CARD_CPU="$( set +u; source "$CONFIG_DIR/colors.sh"; source "$CONFIG_DIR/cards/cpu.sh"
             card_rows 2>/dev/null | head -1 | cut -f3 )"
case "$CARD_CPU" in
  *"CPU "*"Memory "*) ok "card summary row: $CARD_CPU" ;;
  *)                  bad "card summary row malformed (got '$CARD_CPU')" ;;
esac
# A helper that died must not leave the card quoting a frozen reading.
STALE_DIR="$(mktemp -d)"
printf '{"at":1,"cpu":99,"mem":99}\n' > "$STALE_DIR/helper-state.json"
STALE_CPU="$( set +u; source "$CONFIG_DIR/colors.sh"; SB_CACHE_DIR="$STALE_DIR"
              source "$CONFIG_DIR/cards/cpu.sh"; card_rows 2>/dev/null | head -1 | cut -f3 )"
case "$STALE_CPU" in
  *"CPU 99%"*) bad "card quoted a stale helper reading" ;;
  *"CPU "*)    ok "stale helper state ignored, card fell back to sys_lib" ;;
  *)           bad "card produced nothing on the stale path (got '$STALE_CPU')" ;;
esac
rm -rf "$STALE_DIR"

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
