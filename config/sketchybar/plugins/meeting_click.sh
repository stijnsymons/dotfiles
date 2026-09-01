#!/usr/bin/env bash
# Click handler for the meeting item. Join the call, or fall back to the
# pinned calendar tab in Brave.
#
# Reads ONLY the cache meeting.sh already wrote ($SB_CACHE_DIR/meeting.json),
# so a click costs no API round-trip and feels instant. colors.sh is sourced
# for that path and for the launchd PATH repair, not for any colour.
#
# Link resolution, in order:
#   1. .hangoutLink                                  (Google Meet)
#   2. .conferenceData.entryPoints[] entryPointType == "video"   (Zoom add-on, Meet)
#   3. a zoom.us / teams.microsoft.com URL anywhere in .location, .description
#      or .conferenceData.notes
#
# Step 3 is what catches Microsoft Teams, whose join link is usually only an
# HTML <a href> buried in the description. Two traps live there:
#   - Google rewrites every href in an invite to
#     https://www.google.com/url?q=<percent-encoded>&sa=D&... , so the real URL
#     has to be unwrapped and percent-decoded;
#   - the same blob also carries docs.zoom.us / zoom.us/launch/jc links, which
#     are NOT join links, hence the join-shaped filter rather than a bare
#     "contains zoom.us".
#
# Test seam / shared helper: `--print` resolves the link and prints it (exit 0)
# or prints nothing (exit 1) instead of opening anything. meeting.sh calls it
# that way so the icon it draws and the action a click takes can never disagree.
# MEETING_CACHE=<file.json> points both at a fixture.
set -u

source "$CONFIG_DIR/colors.sh"

CACHE="${MEETING_CACHE:-$SB_CACHE_DIR/meeting.json}"
DRY=0
[ "${1:-}" = "--print" ] && DRY=1

EVENT="$(cat "$CACHE" 2>/dev/null)"
[ -z "$EVENT" ] && EVENT=null

# Undo Google's redirect wrapper; pass anything else straight through.
unwrap() {
  local u="$1" q
  case "$u" in
    http://www.google.com/url\?*|https://www.google.com/url\?*)
      q="${u#*[?&]q=}"; q="${q%%&*}"
      # bash 3.2 has no printf %u: \x escapes do the percent-decoding.
      q="$(printf '%b' "${q//%/\\x}" 2>/dev/null)"
      printf '%s\n' "${q:-$u}" ;;
    *) printf '%s\n' "$u" ;;
  esac
}

# 1 + 2 — the structured fields.
LINK="$(jq -r '
  .hangoutLink
  // ([.conferenceData.entryPoints[]? | select(.entryPointType == "video") | .uri] | first)
  // empty' <<<"$EVENT" 2>/dev/null)"

# 3 — scan the free text. Rather than stripping tags (which would throw the
# href away with them), un-escape the HTML entities and pull every URL out,
# href-quoted or bare, then keep only the join-shaped ones.
if [ -z "$LINK" ]; then
  TEXT="$(jq -r '[.location?, .description?, .conferenceData.notes?]
                 | map(select(type == "string")) | join("\n")' <<<"$EVENT" 2>/dev/null)"
  TEXT="${TEXT//&amp;/&}"; TEXT="${TEXT//&quot;/\"}"; TEXT="${TEXT//&#39;/\'}"

  while IFS= read -r RAW; do
    [ -n "$RAW" ] || continue
    U="$(unwrap "$RAW")"
    U="${U%%[.,;)]}"                       # trailing sentence punctuation
    case "$U" in
      *zoom.us/j/*|*zoom.us/w/*|*zoom.us/s/*|*zoom.us/my/*|\
      *teams.microsoft.com/l/*|*teams.microsoft.com/dl/*|*teams.live.com/meet/*)
        LINK="$U"; break ;;
    esac
  done <<<"$(printf '%s\n' "$TEXT" | grep -Eo 'https?://[^"'"'"'<>[:space:]]+')"
fi

if [ "$DRY" -eq 1 ]; then
  [ -n "$LINK" ] || exit 1
  printf '%s\n' "$LINK"
  exit 0
fi

if [ -n "$LINK" ]; then
  open "$LINK"
  exit 0
fi

# No conference link, or no meeting at all: focus Brave on the pinned calendar.
# `active tab index` is Brave's term (Chromium dictionary), not `active tab`.
osascript <<'APPLESCRIPT'
tell application "Brave Browser"
  activate
  if (count of windows) is greater than 0 then
    if (count of tabs of front window) is greater than or equal to 2 then
      set active tab index of front window to 2
    end if
  end if
end tell
APPLESCRIPT
