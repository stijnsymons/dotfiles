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

echo "system.sh readings:"
pct "cpu" "$(top -l 2 -n 0 -s 1 | awk '/CPU usage/ {u=$3+$5} END {printf "%.0f", u}')"
pct "mem" "$(memory_pressure | awk '/free percentage/ {gsub("%","",$NF); printf "%.0f", 100-$NF}')"

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
for a in toggle close about settings appstore force lock sleep logout restart shutdown; do
  grep -q "^  $a)" "$CONFIG_DIR/plugins/power.sh" && ok "action $a" || bad "action $a missing"
done

echo "layout vs notch:"
read -r M_TOP M_NL M_NR M_W <<<"$(swift "$CONFIG_DIR/bin/screen-metrics.swift" 2>/dev/null)"
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
command -v "$HOME/bin/gws-now" >/dev/null && ok "gws-now on disk" || bad "~/bin/gws-now missing (the meeting item needs it)"

# Link resolution is pure: fixtures in, URL out, no network. These are the three
# shapes that actually occur - Meet/Zoom via conferenceData, Zoom only as a
# google.com/url-wrapped href in the notes, Teams only as an <a href> in the
# HTML description - plus a linkless event, which must fail so the click falls
# through to Brave.
cat > "$MEET_TMP/zoom.json" <<'JSON'
{"summary":"standup","conferenceData":{"entryPoints":[
  {"entryPointType":"video","uri":"https://novemberfive.zoom.us/j/89531039342?jst=2"},
  {"entryPointType":"phone","uri":"tel:+3227880172,,89531039342#"}]}}
JSON
cat > "$MEET_TMP/zoom_notes.json" <<'JSON'
{"summary":"standup","location":"HQ-0-05 (8) [TV, Zoom]","conferenceData":{"notes":
"Join Zoom Meeting: <br /><a href=\"https://www.google.com/url?q=https://novemberfive.zoom.us/j/89531039342?jst%3D2&amp;sa=D&amp;source=calendar\">link</a><br />Agenda: <a href=\"https://docs.zoom.us/agenda/doc/abc\">agenda</a>"}}
JSON
cat > "$MEET_TMP/teams.json" <<'JSON'
{"summary":"review","location":"Microsoft Teams Meeting","description":
"<a href=\"https://www.google.com/url?q=https://teams.microsoft.com/l/meetup-join/19%253ameeting_X%2540thread.v2/0?context%3D%257b%2522Tid%2522%253a%2522t%2522%257d&amp;sa=D\">Click here to join</a><br>Learn more at <a href=\"https://aka.ms/JoinTeamsMeeting\">aka.ms</a>."}
JSON
printf '{"summary":"1:1","location":"HQ-0-05 (8) [TV]"}\n' > "$MEET_TMP/nolink.json"
printf 'null\n' > "$MEET_TMP/none.json"
: > "$MEET_TMP/failed.json"   # empty = the gws-now call itself failed

mlink() { MEETING_CACHE="$MEET_TMP/$1" "$CONFIG_DIR/plugins/meeting_click.sh" --print 2>/dev/null; }
is "zoom via conferenceData"  "$(mlink zoom.json)"       "https://novemberfive.zoom.us/j/89531039342?jst=2"
is "zoom via wrapped notes"   "$(mlink zoom_notes.json)" "https://novemberfive.zoom.us/j/89531039342?jst=2"
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
rm -rf "$MEET_TMP"

echo "caffeine:"
[ -x "$CONFIG_DIR/plugins/caffeine.sh" ] && ok "renderer executable" || bad "plugins/caffeine.sh not executable"
[ -x "$CONFIG_DIR/plugins/caffeine_click.sh" ] && ok "click handler executable" || bad "plugins/caffeine_click.sh not executable"
# Byte-level, like the power glyph check: a grep for the literal matches a dropped glyph too.
CWANT="$(printf '\363\260\205\266' | xxd -p)"
CGOT="$(sketchybar --query caffeine 2>/dev/null | jq -r '.icon.value' | tr -d '\n' | xxd -p)"
is "coffee glyph U+F0176 bytes" "$CGOT" "$CWANT"
CAFFEINE_LIB=1 source "$CONFIG_DIR/plugins/caffeine.sh"
CSF="$(mktemp)"; CAFFEINE_STATE_FILE="$CSF"
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
# A transparent colour means colors.sh was not sourced -- the icon renders invisible.
PICO="$(sketchybar --query productive 2>/dev/null | jq -r '.icon.color')"
case "$PICO" in "$RED"|"$GREEN"|"$FG_DIM") ok "icon colour $PICO from palette" ;;
                *) bad "icon colour not from palette (got '$PICO')" ;; esac

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

echo "deps:"
for d in jq nowplaying-cli; do
  command -v "$d" >/dev/null && ok "$d" || bad "$d missing"
done

echo "colors:"
is "palette exported" "${FG:0:2}" "0x"

exit $fail
