#!/usr/bin/env bash
# Open the current meeting's conference link in its native app.
#
# Handing Zoom/Teams an https URL bounces through the browser, which then shows
# an interstitial and re-launches the app. The app URL schemes skip both:
#   zoom  https://HOST/j/ID?pwd=X  ->  zoommtg://HOST/join?confno=ID&pwd=X
#   teams https://teams...         ->  msteams://teams...
# Anything unrecognised falls through to `open`, which is still correct - just
# slower - so a new provider never means a dead click.

# --print resolves the app URI and prints it instead of launching anything, so
# the translation can be asserted without joining a real call.
DRY=0; [ "${1:-}" = "--print" ] && DRY=1
launch() { [ "$DRY" = 1 ] && { printf '%s\n' "$1"; exit 0; }; open "$1"; exit 0; }

source "$CONFIG_DIR/colors.sh"   # jq on the PATH, under launchd
LINK="$("$CONFIG_DIR/plugins/meeting_click.sh" --print 2>/dev/null)"
[ -z "$LINK" ] && exit 0

case "$LINK" in
  *zoom.us/j/*|*zoom.us/w/*|*zoom.us/s/*)
    HOST="$(printf '%s' "$LINK" | sed -E 's|^https?://([^/]+)/.*|\1|')"
    # -n/p, so a non-numeric /s/ SSO link yields nothing and falls through to
    # the browser instead of coming back whole as a bogus confno=https://...
    ID="$(printf '%s'   "$LINK" | sed -nE 's|^https?://[^/]+/[jws]/([0-9]+).*|\1|p')"
    PWD_Q="$(printf '%s' "$LINK" | sed -nE 's|.*[?&]pwd=([^&]+).*|\1|p')"
    if [ -n "$ID" ]; then
      URI="zoommtg://$HOST/join?confno=$ID"
      [ -n "$PWD_Q" ] && URI="$URI&pwd=$PWD_Q"
      launch "$URI"
    fi
    ;;
  https://teams.microsoft.com/*|https://teams.live.com/*)
    launch "msteams://${LINK#https://}"
    ;;
esac

launch "$LINK"
