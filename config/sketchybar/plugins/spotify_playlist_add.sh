#!/usr/bin/env bash
# Add whatever Spotify is playing right now to a playlist named for the current
# year ("2026"), creating that playlist the first time it is needed.
#
#   spotify_playlist_add.sh            add the current track  (the hotkey path)
#   spotify_playlist_add.sh card       ditto, but for the now-playing card
#   spotify_playlist_add.sh check      membership only; never writes to Spotify
#
# `add` prints exactly one word-ish line on stdout and nothing else:
#
#   added              the track is now in this year's playlist
#   already in 2026    it was already there; nothing was written
#   no track playing   nothing is playing, or what is playing is not a track
#   not configured     no OAuth credentials yet - see SETUP below
#
# Exit status is 0 for all four of those, including "not configured": an
# unconfigured box is a steady state, not a fault, and a sketchybar item that
# goes red because you have not done the OAuth dance yet is noise. Non-zero is
# reserved for a genuine failure - missing jq/curl, a network or API error, a
# refresh token the server has revoked - and the reason goes to stderr.
#
#
# WHY THERE IS A `card` MODE, AND WHY IT IS THE ONE THE CARD ROW USES
#
# The motivating failure: "Add to 2026" in the now-playing card did nothing at
# all. Nothing was wrong with the wiring - card.sh's metacharacter filter passes
# a bare path untouched, the click_script composed correctly, the script ran and
# exited 0. It ran on a box with no credentials, printed "not configured" to a
# stdout that sketchybar throws away, and card.sh's appended `close` shut the
# popup. Four of this script's outcomes, including every failure, were therefore
# INVISIBLE from a click. The success path was invisible too.
#
# `card` mode fixes the channel rather than the message. It:
#
#   1. forks and returns immediately, because the click_script is synchronous
#      and a 1-3s API round trip would freeze the popup before it closed;
#   2. records the outcome in $SP_OUTCOME, a one-line file the card renders as
#      a short-lived row;
#   3. waits for the engine's close to land, then re-opens the card.
#
# Step 3 is the only channel that works. Anything painted INTO the popup during
# the click is erased a millisecond later by the `; card.sh media close` the
# engine appends to every row action, and the bar item itself is repainted by
# plugins/media.sh on its 15s tick and on every media_change, so a flash there
# survives for an unpredictable fraction of a second. Re-opening the card puts
# the answer where the click was, in the place the pointer already is.
#
# A macOS notification was considered and rejected: `display notification` is
# attributed to whatever process calls osascript, needs its own Notification
# Centre grant that nothing here can arrange, and fails silently when it is not
# granted - which is the exact failure mode being fixed.
#
#
# WHY THERE IS A `check` MODE
#
# The card wants to show whether the current track is ALREADY in this year's
# playlist, on every open, without opening the card ever costing an API call on
# the click path. So the card never checks; it reads $SP_MEMBERS, and when that
# has no fresh answer it renders the honest "not checked" appearance and forks
# `check` to fill the cache in for next time. `check` resolves the track and
# scans the playlist exactly as the add path does, writes the answer, and
# touches nothing on Spotify's side - it will not even create the playlist.
#
#
# WHY THE WEB API AND NOT APPLESCRIPT
#
# The desktop app's AppleScript dictionary can *read* the current track, and
# that is all it can do. It has no vocabulary for playlists at all: no create,
# no add, no membership test. Everything this script exists to do is therefore
# a Web API call, which means OAuth, which means the read may as well come from
# the same place - one credential, one dependency, one failure mode. The Web
# API read also covers playback on a phone or a Connect speaker, which the
# local app cannot see.
#
# AppleScript survives as a fallback for exactly one case: a private session
# (and, in practice, some ad breaks) makes /me/player/currently-playing answer
# 204 while the app on this desktop is quite happily playing something. The
# fallback asks the app for `spotify url of current track`, which is an exact
# `spotify:track:<id>` - no name/artist search, so it cannot bind the wrong
# track. It is guarded by a `ps` check because `tell application "Spotify"`
# LAUNCHES Spotify if it is not running, and a "add to playlist" hotkey that
# boots the app is a bug.
#
#
# SETUP  (one-time; until it is done this script prints "not configured")
#
#   1. https://developer.spotify.com/dashboard -> Create app. Any name.
#      Redirect URI, exactly:   http://127.0.0.1:8888/callback
#      It must be the loopback IP literal. Spotify has rejected
#      http://localhost/... for new/edited apps since Nov 2024, and plain http
#      is only allowed for 127.0.0.1 / [::1].
#      Note the Client ID and Client secret.
#
#   2. Open this in a browser, with CLIENT_ID substituted, and approve:
#
#      https://accounts.spotify.com/authorize?response_type=code
#        &client_id=CLIENT_ID
#        &redirect_uri=http%3A%2F%2F127.0.0.1%3A8888%2Fcallback
#        &scope=user-read-currently-playing%20playlist-read-private%20playlist-modify-private%20playlist-modify-public
#
#      (all one line). The four scopes, and why each is needed:
#        user-read-currently-playing  read the track
#        playlist-read-private        see your own private playlists, so the
#                                     year playlist can be FOUND rather than
#                                     created a second time
#        playlist-modify-private      create it, and add to it
#        playlist-modify-public       add to it if you ever flip it public
#
#      The browser lands on a dead 127.0.0.1 page - that is fine, the `code`
#      query parameter in the URL bar is the payload. It is valid for ~60s.
#
#   3. Trade the code for a refresh token (substitute all three):
#
#      curl -s -X POST https://accounts.spotify.com/api/token \
#        -d grant_type=authorization_code -d code=CODE \
#        -d redirect_uri=http://127.0.0.1:8888/callback \
#        -u CLIENT_ID:CLIENT_SECRET | jq -r .refresh_token
#
#   4. Put all three in ~/dotfiles/zshrc.private, which is where this repo
#      keeps secrets and which git does not track (see plugins/productive_api.sh
#      for the same arrangement):
#
#        export SPOTIFY_CLIENT_ID=...
#        export SPOTIFY_CLIENT_SECRET=...
#        export SPOTIFY_REFRESH_TOKEN=...
#
#      Only those three export lines are lifted out of that file, never the
#      whole thing - it is zsh, and this is bash.
#
# No secret is ever printed by this script, on either stream, in any branch.
# The access token is derived at runtime, cached 0600 under $SB_CACHE_DIR, and
# passed to curl over stdin rather than argv, because argv is world-readable
# via `ps` and a bar plugin runs often enough to be worth watching for.

# Resolvable both as a sketchybar plugin (CONFIG_DIR is exported for us) and by
# hand from anywhere - a hotkey wrapper is the likelier caller than the bar.
CONFIG_DIR="${CONFIG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# For $SB_CACHE_DIR (created 0700 there, which is the whole reason the token
# cache may live in it) and for the PATH repair that makes jq and curl findable
# when launchd starts the bar without a login shell.
# shellcheck source=../colors.sh
. "$CONFIG_DIR/colors.sh"

YEAR="$(date +%Y)"                       # resolved every run: this outlives 2026
API=https://api.spotify.com/v1
TOKEN_CACHE="$SB_CACHE_DIR/spotify_token"
ME_CACHE="$SB_CACHE_DIR/spotify_me"
PL_CACHE="$SB_CACHE_DIR/spotify_playlist_$YEAR"
LOCK="$SB_CACHE_DIR/spotify_playlist_add.lock"

# The three files the now-playing card reads. Nothing here is a secret - a track
# title and an outcome word - but they live in $SB_CACHE_DIR, which is 0700, and
# are written under umask 077 anyway so the whole cache stays one mode.
SP_MEMBERS="$SB_CACHE_DIR/spotify_members"      # membership, one track per line
SP_OUTCOME="$SB_CACHE_DIR/spotify_outcome"      # the last click's result
SP_CHECK_AT="$SB_CACHE_DIR/spotify_check.at"    # throttle for background checks
SP_CHECK_LOCK="$SB_CACHE_DIR/spotify_check.lock"

note() { printf '%s\n' "$*" >&2; }
die()  { printf '%s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# Credentials

# Same shape as productive_creds(): environment first so a one-off can override
# without touching the file, then the three export lines grepped out of
# zshrc.private. Returns 1 - not dies - when they are absent, because "absent"
# is the "not configured" outcome and not an error.
spotify_creds() {
  [ -n "${SPOTIFY_CLIENT_ID:-}" ] && [ -n "${SPOTIFY_CLIENT_SECRET:-}" ] \
    && [ -n "${SPOTIFY_REFRESH_TOKEN:-}" ] && return 0
  [ -r "$HOME/dotfiles/zshrc.private" ] || return 1
  eval "$(grep -E '^[[:space:]]*export[[:space:]]+SPOTIFY_[A-Z_]+=' \
          "$HOME/dotfiles/zshrc.private" 2>/dev/null)"
  [ -n "${SPOTIFY_CLIENT_ID:-}" ] && [ -n "${SPOTIFY_CLIENT_SECRET:-}" ] \
    && [ -n "${SPOTIFY_REFRESH_TOKEN:-}" ]
}

# An access token lasts an hour; a refresh costs a round trip to a second host.
# Caching it turns the common invocation into one HTTP call instead of two, and
# more importantly stops a click-spammed bar item from hammering
# accounts.spotify.com, which rate-limits harder than the API does.
#
# The 60s slack on the expiry is not cosmetic: without it a token fetched at
# T+3599 is handed to a request that arrives after it has died, and the only
# symptom is an intermittent 401 that never reproduces by hand.
load_token() {
  local now exp tok
  now="$(date +%s)"
  if [ -r "$TOKEN_CACHE" ]; then
    IFS=' ' read -r exp tok < "$TOKEN_CACHE"
    # Digits-only test rather than [ -gt ]: a truncated or hand-mangled cache
    # line makes [ ] exit 2 under `set -u` semantics and the error is opaque.
    case "${exp:-}" in
      ''|*[!0-9]*) ;;
      *) if [ -n "${tok:-}" ] && [ "$exp" -gt "$(( now + 60 ))" ]; then
           SP_TOKEN="$tok"; return 0
         fi ;;
    esac
  fi
  refresh_token
}

# The body goes over stdin (`--data @-`), never argv: it carries the client
# secret and the refresh token, and argv is readable by every process on the
# box. curl strips the newline out of @- input, so the here-document's trailing
# newline does not end up inside the client_secret value.
#
# Credentials in the body rather than a Basic auth header purely so there is
# one stdin consumer instead of two - Spotify accepts either for this grant.
refresh_token() {
  local resp tok ttl newrt
  resp="$(curl -sS -m 20 -X POST \
            -H 'Content-Type: application/x-www-form-urlencoded' \
            --data @- https://accounts.spotify.com/api/token <<BODY
grant_type=refresh_token&refresh_token=$SPOTIFY_REFRESH_TOKEN&client_id=$SPOTIFY_CLIENT_ID&client_secret=$SPOTIFY_CLIENT_SECRET
BODY
  )" || { note "token refresh: curl failed"; return 1; }

  tok="$(printf '%s' "$resp" | jq -r '.access_token // empty' 2>/dev/null)"
  if [ -z "$tok" ]; then
    # The error CODE is safe to surface; the response as a whole is not, so it
    # is never echoed. invalid_grant here means the refresh token was revoked
    # (password change, app removed from the account) and step 2-3 of SETUP has
    # to be repeated - no amount of retrying will fix it.
    note "token refresh rejected: $(printf '%s' "$resp" | jq -r '.error // "unparseable response"' 2>/dev/null)"
    rm -f "$TOKEN_CACHE"
    return 1
  fi
  ttl="$(printf '%s' "$resp" | jq -r '.expires_in // 3600' 2>/dev/null)"
  case "$ttl" in ''|*[!0-9]*) ttl=3600 ;; esac

  # Spotify MAY rotate the refresh token on a refresh. It usually does not, but
  # when it does the old one keeps working only for a while, and the failure
  # lands weeks later as a sudden invalid_grant. We cannot write the new one
  # back - zshrc.private is the user's file and is deliberately not touched
  # here - so say so, without the value.
  newrt="$(printf '%s' "$resp" | jq -r '.refresh_token // empty' 2>/dev/null)"
  if [ -n "$newrt" ] && [ "$newrt" != "$SPOTIFY_REFRESH_TOKEN" ]; then
    note "notice: Spotify issued a new refresh token; update SPOTIFY_REFRESH_TOKEN in zshrc.private"
  fi

  # umask around the write, not a chmod after it: the token is in the file from
  # the instant it is created, and a chmod that runs a moment later is a window.
  ( umask 077; printf '%s %s\n' "$(( $(date +%s) + ttl ))" "$tok" > "$TOKEN_CACHE" ) \
    || note "warning: could not cache the access token"
  SP_TOKEN="$tok"
}

# --------------------------------------------------------------------------
# API transport

# Sets SP_CODE and SP_BODY; returns 0 only on 2xx.
#
# The status code is captured with -w rather than leaning on --fail-with-body
# because three non-2xx codes are load-bearing here and have to be told apart:
# 204 (nothing playing - a normal outcome, not an error), 401 (token died early,
# retry once) and everything else (real failure). --fail-with-body collapses all
# three into "exit 22".
#
# The Authorization header goes in over stdin via --config for the argv reason
# above. Only GETs get --retry: curl replays 429/5xx and dropped connections
# regardless of method, and the one mutating call here is the POST that adds a
# track - a replay of a POST the server already committed would add the track
# twice, which is precisely what this script is supposed to prevent.
sp_api() { # sp_api <method> <url> [json-body]
  local method="$1" url="$2" body="${3:-}" out
  if [ -n "$body" ]; then
    out="$(curl -sS -m 20 -w $'\n%{http_code}' -X "$method" \
             -H 'Content-Type: application/json' -d "$body" \
             --config - "$url" <<CURLRC
header = "Authorization: Bearer $SP_TOKEN"
CURLRC
    )" || { SP_CODE=000; SP_BODY=''; return 1; }
  else
    out="$(curl -sS -m 20 -w $'\n%{http_code}' --retry 2 --retry-max-time 15 \
             -X "$method" --config - "$url" <<CURLRC
header = "Authorization: Bearer $SP_TOKEN"
CURLRC
    )" || { SP_CODE=000; SP_BODY=''; return 1; }
  fi
  SP_CODE="${out##*$'\n'}"
  SP_BODY="${out%$'\n'*}"
  case "$SP_CODE" in 2*) return 0 ;; *) return 1 ;; esac
}

# One retry on 401 and one only. A cached token can be killed before its stated
# expiry - the user revokes the app, or changes their password - and the cache
# would then serve a corpse until the hour was up. Purge and re-refresh once;
# a second 401 means the refresh token itself is dead, and looping on that just
# turns a broken credential into a rate-limit ban.
sp() {
  sp_api "$@" && return 0
  if [ "${SP_CODE:-}" = "401" ]; then
    rm -f "$TOKEN_CACHE"
    refresh_token || return 1
    sp_api "$@" && return 0
  fi
  return 1
}

sp_err() { # sp_err <what>
  note "$1 failed (HTTP ${SP_CODE:-?}): $(printf '%s' "${SP_BODY:-}" | jq -r '.error.message // .error // empty' 2>/dev/null)"
}

# jq and curl are a hard requirement for everything that talks to Spotify, and
# nothing else. Deliberately NOT a top-level guard any more: cards/media.sh
# sources this file for the cache readers below, and a `die` at source time
# would take the whole card render down over a dependency the card never uses.
sp_require() {
  command -v jq   >/dev/null 2>&1 || { note "jq not found";   return 1; }
  command -v curl >/dev/null 2>&1 || { note "curl not found"; return 1; }
}

# --------------------------------------------------------------------------
# What is playing

# Echoes `<track-id>` or `<track-id>\t<track-name>`, or nothing. Return 0 = got
# one, 1 = nothing to add, 2 = the request itself broke.
#
# The NAME rides along on the same line, tab-separated, rather than being handed
# back in a global. It has to: every caller reads this through `$(...)`, and a
# command substitution is a subshell - a global assigned in here is discarded
# the moment it returns, silently, and the first version of the membership guard
# below was therefore comparing against an empty string on every single call and
# never firing.
#
# The name is what the membership cache needs. That cache is keyed on what
# nowplaying-cli reports (see np_read), and the two sources can disagree - the
# Web API sees a phone or a Connect speaker, nowplaying-cli only ever sees this
# desktop. Writing the API's answer under the desktop's key when they are looking
# at different playback would make the card claim a track is in the playlist when
# it is a different track that is. An absent name means "nothing to compare
# with", which the AppleScript fallback below returns deliberately.
#
# additional_types=episode is deliberate: without it Spotify answers a podcast
# with a null item, indistinguishable from silence, and "no track playing"
# would be a lie. With it we can see it is an episode and say so on stderr.
# Episodes and ads are then skipped anyway - neither belongs in a year-of-music
# playlist, and an ad's id would be garbage.
#
# A PAUSED track still counts. The whole gesture is "I like this, keep it", and
# hitting pause before reaching for the hotkey is normal behaviour, not a
# reason to refuse.
current_track_id() {
  local kind id local_file name
  if ! sp GET "$API/me/player/currently-playing?additional_types=episode"; then
    sp_err "currently-playing"; return 2
  fi
  # 204: no active device. Playback on a phone that has gone to sleep, Spotify
  # closed, or a private session. Fall through to the desktop app.
  if [ -z "$SP_BODY" ] || [ "${SP_CODE}" = "204" ]; then
    applescript_track_id && return 0
    return 1
  fi

  kind="$(printf '%s' "$SP_BODY" | jq -r '.currently_playing_type // "unknown"')"
  case "$kind" in
    track) ;;
    ad)      note "an ad is playing"; return 1 ;;
    episode) note "a podcast episode is playing, not a track"; return 1 ;;
    *)       note "nothing recognisable is playing (type: $kind)"; return 1 ;;
  esac

  # A local file has a null id and cannot be added to a Spotify-hosted
  # playlist by uri - the add would 400 with a useless message.
  id="$(printf '%s' "$SP_BODY" | jq -r '.item.id // empty')"
  local_file="$(printf '%s' "$SP_BODY" | jq -r '.item.is_local // false')"
  if [ -z "$id" ] || [ "$local_file" = "true" ]; then
    note "the current track is a local file; it has no Spotify id"
    return 1
  fi
  note "current: $(printf '%s' "$SP_BODY" | jq -r '(.item.name // "?") + " - " + ((.item.artists // [] | map(.name) | join(", ")) // "?")')"
  # card_text before it goes on the wire: the name is about to be a tab-separated
  # field, and a track whose title contains a tab would otherwise split into two.
  name="$(card_text "$(printf '%s' "$SP_BODY" | jq -r '.item.name // empty')")"
  printf '%s\t%s' "$id" "$name"
}

# The AppleScript here is checked against Spotify.app's own dictionary
# (Contents/Resources/Spotify.sdef): `current track`, `player state` and
# `spotify url` are all declared there, and ePlS enumerates exactly stopped /
# playing / paused. It has NOT been executed - see the note at the top of the
# file - because this environment cannot load app terminology at all.
#
# The `ps` guard is the important half and IS verified: `tell application
# "Spotify"` launches Spotify when it is not running, so asking it anything
# unconditionally turns a hotkey that should be a no-op into an app launch.
# Matched on the bundle executable name anchored to a path separator, the same
# way bin/wmswitch.sh does it, and for the same reason: pgrep leans on sysmond,
# which has been seen to fail outright on this machine, and it fails silently.
#
# One osascript, not three. Each spawn is ~80ms of terminology loading, and the
# state and the URL have to describe the same instant anyway - asking twice
# lets the track change in between and attributes the wrong id to it. The
# comparison is against the bare enum constant rather than `as text`, so it
# does not depend on how AppleScript decides to stringify it.
#
# The id goes back with no name field on this path on purpose. The name exists
# only to catch the Web API and nowplaying-cli looking at different playback,
# and here they cannot be: this branch only runs because the Web API saw
# nothing, and both this and nowplaying-cli are reading the same desktop app.
applescript_track_id() {
  local uri id
  # shellcheck disable=SC2009  # pgrep leans on sysmond, which fails silently here
  ps -Ao comm= 2>/dev/null | grep -q '/Spotify$' || return 1
  uri="$(osascript \
           -e 'tell application "Spotify"' \
           -e '  if player state is stopped then return ""' \
           -e '  return spotify url of current track' \
           -e 'end tell' 2>/dev/null)" || return 1
  case "$uri" in
    spotify:track:*) id="${uri#spotify:track:}" ;;
    # spotify:local:... is a file on disk that Spotify indexed. No id, nothing
    # to add. Anything else is a shape we do not know and will not guess at.
    *) return 1 ;;
  esac
  [ -n "$id" ] || return 1
  note "current (via the desktop app; the Web API reported nothing)"
  printf '%s' "$id"
}

# --------------------------------------------------------------------------
# The playlist

# The account id never changes, so it is cached forever rather than costing a
# /me round trip on every single invocation.
my_id() {
  local id
  if [ -r "$ME_CACHE" ]; then
    IFS= read -r id < "$ME_CACHE"
    [ -n "${id:-}" ] && { printf '%s' "$id"; return 0; }
  fi
  sp GET "$API/me" || { sp_err "/me"; return 1; }
  id="$(printf '%s' "$SP_BODY" | jq -r '.id // empty')"
  [ -n "$id" ] || { note "/me returned no user id"; return 1; }
  ( umask 077; printf '%s\n' "$id" > "$ME_CACHE" ) 2>/dev/null
  printf '%s' "$id"
}

# Exact name match, and only among playlists this account OWNS.
#
# Both halves matter. /me/playlists also lists playlists you merely FOLLOW, and
# somebody else's "2026" is a thing that exists in quantity - adding to it would
# fail with a 403 at best and silently scribble in a stranger's collaborative
# playlist at worst. And the match is ==, not a substring: "2026" must not bind
# to "Best of 2026" or "2026 running".
find_playlist() { # find_playlist <name> <owner-id>
  local url page id
  url="$API/me/playlists?limit=50"
  while [ -n "$url" ]; do
    sp GET "$url" || { sp_err "list playlists"; return 2; }
    page="$SP_BODY"
    id="$(printf '%s' "$page" | jq -r --arg n "$1" --arg o "$2" \
          'first(.items[]? | select(.name == $n and .owner.id == $o) | .id) // empty')"
    [ -n "$id" ] && { printf '%s' "$id"; return 0; }
    url="$(printf '%s' "$page" | jq -r '.next // empty')"
  done
  return 1
}

create_playlist() { # create_playlist <name> <owner-id>
  local body id
  body="$(jq -nc --arg n "$1" '{name: $n, public: false, description: ("Saved during " + $n)}')"
  sp POST "$API/users/$2/playlists" "$body" || { sp_err "create playlist"; return 1; }
  id="$(printf '%s' "$SP_BODY" | jq -r '.id // empty')"
  [ -n "$id" ] || { note "create playlist returned no id"; return 1; }
  note "created playlist \"$1\""
  printf '%s' "$id"
}

# A cached id skips a scan that is 1-4 round trips, but it is verified against
# the live name and owner before it is trusted. The playlist can be deleted or
# RENAMED behind our back, and a stale id would then bury tracks in whatever
# that playlist has since become - a silent wrong answer, which is worse than
# the round trip it saves.
cached_playlist() { # cached_playlist <name> <owner-id>
  local id
  [ -r "$PL_CACHE" ] || return 1
  IFS= read -r id < "$PL_CACHE"
  [ -n "${id:-}" ] || return 1
  sp GET "$API/playlists/$id?fields=id,name,owner(id)" || return 1
  printf '%s' "$SP_BODY" | jq -e --arg n "$1" --arg o "$2" \
    '.name == $n and .owner.id == $o' >/dev/null 2>&1 || return 1
  printf '%s' "$id"
}

# --------------------------------------------------------------------------
# Membership

# Walk the playlist and look for the id. `fields` trims the response from ~4KB
# a track to ~30 bytes, which is what makes scanning a thousand-track year
# playlist cheap enough to do on every add.
#
# Checked server-side every time rather than against a local cache of ids: the
# playlist is edited from the phone, from the desktop app and from here, so a
# local cache would go stale in exactly the direction that produces duplicates.
# ($SP_MEMBERS below caches the ANSWER for the card to draw, which is a
# different job with a different tolerance - see the note there.)
#
# `.track.id` and not `.track.uri`: an episode row has a uri but its id is null,
# and null == null would match every episode against a null-id lookup - which
# cannot happen here because we refuse null ids upstream, but the shape is one
# refactor away from being true.
playlist_has_track() { # playlist_has_track <playlist-id> <track-id>
  local url page
  url="$API/playlists/$1/tracks?limit=100&fields=next,items(track(id))"
  while [ -n "$url" ]; do
    sp GET "$url" || { sp_err "list playlist tracks"; return 2; }
    page="$SP_BODY"
    printf '%s' "$page" | jq -e --arg t "$2" 'any(.items[]?; .track.id == $t)' >/dev/null 2>&1 && return 0
    # Spotify carries the fields selector through into .next, so the trimming
    # survives pagination without being re-appended here.
    url="$(printf '%s' "$page" | jq -r '.next // empty')"
  done
  return 1
}

# --------------------------------------------------------------------------
# The membership cache the card draws from
#
# $SP_MEMBERS is a flat file, newest first, one track per line:
#
#     <epoch>\t<year>\t<in|out>\t<key>
#
# The KEY is not a Spotify track id, and cannot be: cards/media.sh has to look
# an entry up on every open with nothing but what nowplaying-cli already told
# it, and nowplaying-cli has no notion of a Spotify id. So the key is the title
# and the artist, exactly as that call reported them, joined by a unit separator
# and run through card_text so a tab in a title cannot break the record format.
# The write side derives its key from the same call and refuses to write when
# the Web API disagrees about what is playing (see sp_cache_membership).
#
# THE TRADEOFF, stated plainly: this cache can be wrong. The playlist is also
# edited from the phone, so a track removed there stays "in" here until the
# entry expires, and two distinct recordings that share a title and an artist -
# a remaster and its original - share a key. The two directions are not equally
# bad. A stale "out" costs a redundant click that the add path answers with
# "already in 2026" and no duplicate, because that path always re-checks
# server-side. A stale "in" makes the card LIE. So positive entries carry a
# short-ish life and negative ones a shorter one, and anything expired, missing,
# or written for a different year reads back as `unknown` - a third state the
# card draws differently from both, so "not checked yet" is never dressed up as
# "checked, and not in the playlist".
SP_MEMBER_TTL_IN=43200      # 12h: long enough to survive a day's listening
SP_MEMBER_TTL_OUT=900       # 15m: cheap to be wrong, so re-verify often
SP_MEMBER_MAX=120           # entries kept; skipping back a few tracks stays warm
SP_CHECK_MIN_INTERVAL=60    # seconds between background checks for one key
SP_OUTCOME_TTL=30           # how long a click's result stays on the card

# The record separator is \037 (unit separator), not a printable character: a
# title may contain any of them, and | in particular.
spotify_member_key() { # spotify_member_key <title> <artist>
  printf '%s\037%s' "$(card_text "${1:-}")" "$(card_text "${2:-}")"
}

# nowplaying-cli's view, which is the one the card is drawing. Sets
# SP_NP_TITLE / SP_NP_ARTIST; returns 1 when there is no local session at all.
# One call for both keys - nowplaying-cli costs ~115ms whatever you ask it for.
np_read() {
  local raw
  raw="$(nowplaying-cli get title artist 2>/dev/null)"
  { IFS= read -r SP_NP_TITLE; IFS= read -r SP_NP_ARTIST; } <<NPEOF
$raw
NPEOF
  # nowplaying-cli reports a missing key as the four characters "null".
  [ -n "${SP_NP_TITLE:-}" ] && [ "$SP_NP_TITLE" != "null" ] || return 1
  [ "${SP_NP_ARTIST:-}" = "null" ] && SP_NP_ARTIST=''
  return 0
}

# spotify_member_state <key> -> in | out | unknown
#
# The card's whole read path, and the reason it is a plain file scan rather than
# anything cleverer: this runs inside card.sh's `$(card_rows)` on the click that
# opens the popup, so it may not spawn a process and it may not touch the
# network. 120 short lines is a few hundred microseconds of `read`.
spotify_member_state() { # spotify_member_state <key>
  local at yr st k now ttl
  [ -r "$SP_MEMBERS" ] || { printf 'unknown'; return 0; }
  now="$(date +%s)"
  while IFS=$'\t' read -r at yr st k; do
    [ "${k:-}" = "$1" ] || continue
    # A record from last year is not wrong, it is about a different playlist.
    [ "${yr:-}" = "$YEAR" ] || continue
    case "${at:-}" in ''|*[!0-9]*) continue ;; esac
    case "${st:-}" in
      in)  ttl="$SP_MEMBER_TTL_IN" ;;
      out) ttl="$SP_MEMBER_TTL_OUT" ;;
      *)   continue ;;
    esac
    [ "$(( now - at ))" -le "$ttl" ] || continue
    printf '%s' "$st"; return 0
  done < "$SP_MEMBERS"
  printf 'unknown'
}

# Newest first, one entry per key, capped. Rewritten to a temp file and moved
# into place because a card render may be reading it at the same moment a
# background check is writing it, and a half-written line reads back as a record
# with the wrong number of fields - which spotify_member_state would skip, but
# only by luck.
spotify_member_write() { # spotify_member_write <key> <in|out>
  local tmp
  tmp="$SP_MEMBERS.$$"
  ( umask 077
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$YEAR" "$2" "$1" > "$tmp" || exit 1
    if [ -r "$SP_MEMBERS" ]; then
      local n=1 at yr st k
      while IFS=$'\t' read -r at yr st k; do
        [ "${k:-}" = "$1" ] && continue          # superseded by the line above
        [ -n "${at:-}" ] || continue
        n=$(( n + 1 )); [ "$n" -gt "$SP_MEMBER_MAX" ] && break
        printf '%s\t%s\t%s\t%s\n' "$at" "$yr" "$st" "$k"
      done < "$SP_MEMBERS" >> "$tmp"
    fi ) 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$SP_MEMBERS" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Record what we just learned, under the key the CARD will look up.
#
# Refused in two cases, both of which leave the state `unknown` rather than
# risk a wrong "in": no local session to key on at all (playback is on a phone,
# so the card is not drawing this track anyway), and a Web API track name that
# does not match what nowplaying-cli reports, which means the two are looking at
# different playback and the answer belongs to a track that is not on screen.
# An empty <api-name> waives the second test - see applescript_track_id.
#
# Both sides of the comparison go through card_text so a tab or a stray CR in a
# title cannot make two spellings of the same name look different.
sp_cache_membership() { # sp_cache_membership <in|out> <api-track-name>
  np_read || return 0
  if [ -n "${2:-}" ] && [ "$2" != "$(card_text "$SP_NP_TITLE")" ]; then
    note "not caching membership: the Web API is playing something the desktop is not"
    return 0
  fi
  spotify_member_write "$(spotify_member_key "$SP_NP_TITLE" "$SP_NP_ARTIST")" "$1"
}

# Throttle for the background refresh. Without it, opening the media card ten
# times in a minute on a track with no cached answer is ten forks and ten API
# round trips, all of them asking the same question - and if the answer is
# "not configured" the loop never terminates on its own.
spotify_check_due() { # spotify_check_due <key>
  local at k
  [ -r "$SP_CHECK_AT" ] || return 0
  { IFS=$'\t' read -r at k; } < "$SP_CHECK_AT" 2>/dev/null
  [ "${k:-}" = "$1" ] || return 0
  case "${at:-}" in ''|*[!0-9]*) return 0 ;; esac
  [ "$(( $(date +%s) - at ))" -ge "$SP_CHECK_MIN_INTERVAL" ]
}

spotify_check_stamp() { # spotify_check_stamp <key>
  ( umask 077; printf '%s\t%s\n' "$(date +%s)" "$1" > "$SP_CHECK_AT" ) 2>/dev/null
}

# --------------------------------------------------------------------------
# The outcome the card shows after a click

# One line: <epoch>\t<token>\t<detail>. Tokens are a closed set so the card can
# pick a glyph and a colour without parsing prose: added, already, none,
# unconfigured, error.
spotify_outcome_write() { # spotify_outcome_write <token> [detail]
  ( umask 077
    printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$(card_text "${2:-}")" > "$SP_OUTCOME"
  ) 2>/dev/null
}

# Echoes `<token>\t<detail>` while the outcome is fresh, nothing once it is not.
# The expiry is the point: without it, opening the card an hour later would
# still be told "Added to 2026", which is true but reads as if it just happened.
spotify_outcome_read() {
  local at tok detail
  [ -r "$SP_OUTCOME" ] || return 1
  { IFS=$'\t' read -r at tok detail; } < "$SP_OUTCOME" 2>/dev/null
  case "${at:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "${tok:-}" ] || return 1
  [ "$(( $(date +%s) - at ))" -le "$SP_OUTCOME_TTL" ] || return 1
  printf '%s\t%s' "$tok" "${detail:-}"
}

# --------------------------------------------------------------------------
# add - the original job, unchanged in behaviour

# Kept as a function so `card` mode can run it inside a command substitution and
# still see its result: every `exit` below then ends that subshell rather than
# the worker, so the outcome always gets written even on the paths that die.
sp_main_add() {
  local rc n lock_held FRESH=0 found TRACK_ID TRACK_NAME OWNER PLAYLIST_ID

  sp_require || return 1
  spotify_creds || { printf 'not configured\n'; note "set SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET / SPOTIFY_REFRESH_TOKEN - see the SETUP block in $0"; exit 0; }

  SP_TOKEN=''; SP_CODE=''; SP_BODY=''
  load_token || die "could not obtain a Spotify access token"

  found="$(current_track_id)"; rc=$?
  case "$rc" in
    0) ;;
    1) printf 'no track playing\n'; exit 0 ;;
    *) exit 1 ;;
  esac
  IFS=$'\t' read -r TRACK_ID TRACK_NAME <<<"$found"
  [ -n "${TRACK_ID:-}" ] || { printf 'no track playing\n'; exit 0; }

  OWNER="$(my_id)" || exit 1

  # Serialise the find-or-create. Two invocations racing - a double click, or the
  # bar and a hotkey at once - would both fail to find "2026" and both create it,
  # and Spotify is perfectly happy to hold two playlists with the same name. The
  # only way back from that is deleting one by hand, so it is worth a lock.
  #
  # mkdir, not a lock FILE: mkdir is atomic on every filesystem this could land
  # on, whereas `[ -e ] && touch` is a race with itself. Held across the
  # membership check too, so the check and the add cannot interleave either.
  lock_held=0
  n=0
  while [ "$n" -lt 40 ]; do
    if mkdir "$LOCK" 2>/dev/null; then lock_held=1; break; fi
    # A crash between mkdir and the trap leaves the directory behind forever, and
    # the script would then be permanently wedged with no clue as to why. Anything
    # older than two minutes cannot be a live run of this script - the longest
    # possible one is a handful of 20s curl timeouts.
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
      note "clearing a stale lock"; rmdir "$LOCK" 2>/dev/null; continue
    fi
    sleep 0.25; n=$(( n + 1 ))
  done
  [ "$lock_held" = 1 ] || die "another run is holding the lock"
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

  PLAYLIST_ID="$(cached_playlist "$YEAR" "$OWNER")"
  if [ -z "$PLAYLIST_ID" ]; then
    PLAYLIST_ID="$(find_playlist "$YEAR" "$OWNER")"; rc=$?
    [ "$rc" = 2 ] && exit 1
    if [ -z "$PLAYLIST_ID" ]; then
      PLAYLIST_ID="$(create_playlist "$YEAR" "$OWNER")" || exit 1
      # A playlist created a moment ago is empty by construction, so the
      # membership scan below is skipped for it - saves a round trip and, more
      # to the point, dodges the read-after-write lag Spotify occasionally shows
      # on a brand new playlist's tracks endpoint.
      FRESH=1
    fi
    ( umask 077; printf '%s\n' "$PLAYLIST_ID" > "$PL_CACHE" ) 2>/dev/null
  fi

  if [ "$FRESH" != "1" ]; then
    playlist_has_track "$PLAYLIST_ID" "$TRACK_ID"; rc=$?
    case "$rc" in
      0) sp_cache_membership in "${TRACK_NAME:-}"; printf 'already in %s\n' "$YEAR"; exit 0 ;;
      1) ;;
      *) exit 1 ;;
    esac
  fi

  sp POST "$API/playlists/$PLAYLIST_ID/tracks" \
    "$(jq -nc --arg u "spotify:track:$TRACK_ID" '{uris: [$u]}')" \
    || { sp_err "add track"; exit 1; }

  # Cached only after the POST is acknowledged. Writing "in" optimistically and
  # then failing would leave the card showing a track as saved that is not.
  sp_cache_membership in "${TRACK_NAME:-}"
  printf 'added\n'
}

# --------------------------------------------------------------------------
# check - membership only, never a write to Spotify

# Prints in / out / no track playing / not configured. Fills $SP_MEMBERS so the
# next card open can draw the real state without waiting for anything.
#
# It will NOT create the year playlist. A `check` that created one would mean
# merely opening the media card on the 1st of January conjures an empty "2027"
# into the account - the playlist should appear because you asked to save
# something, not because you looked at a popup. A missing playlist is simply a
# definitive "out": nothing can be in a playlist that does not exist.
sp_main_check() {
  local rc found TRACK_ID TRACK_NAME OWNER PLAYLIST_ID

  sp_require || return 1
  spotify_creds || { printf 'not configured\n'; return 0; }

  SP_TOKEN=''; SP_CODE=''; SP_BODY=''
  load_token || { note "could not obtain a Spotify access token"; return 1; }

  found="$(current_track_id)"; rc=$?
  case "$rc" in
    0) ;;
    1) printf 'no track playing\n'; return 0 ;;
    *) return 1 ;;
  esac
  IFS=$'\t' read -r TRACK_ID TRACK_NAME <<<"$found"
  [ -n "${TRACK_ID:-}" ] || { printf 'no track playing\n'; return 0; }

  OWNER="$(my_id)" || return 1

  PLAYLIST_ID="$(cached_playlist "$YEAR" "$OWNER")"
  if [ -z "$PLAYLIST_ID" ]; then
    PLAYLIST_ID="$(find_playlist "$YEAR" "$OWNER")"; rc=$?
    [ "$rc" = 2 ] && return 1
    if [ -z "$PLAYLIST_ID" ]; then
      sp_cache_membership out "${TRACK_NAME:-}"; printf 'out\n'; return 0
    fi
    ( umask 077; printf '%s\n' "$PLAYLIST_ID" > "$PL_CACHE" ) 2>/dev/null
  fi

  playlist_has_track "$PLAYLIST_ID" "$TRACK_ID"; rc=$?
  case "$rc" in
    0) sp_cache_membership in  "${TRACK_NAME:-}"; printf 'in\n' ;;
    1) sp_cache_membership out "${TRACK_NAME:-}"; printf 'out\n' ;;
    *) return 1 ;;
  esac
}

# One check at a time. Every media card open with no cached answer forks one of
# these, and three opens in three seconds would otherwise be three concurrent
# playlist scans racing to write the same line.
sp_check_guarded() {
  local rc
  mkdir "$SP_CHECK_LOCK" 2>/dev/null || {
    # Two minutes is well past the longest a check can legitimately take (a
    # handful of 20s curl timeouts); anything older is a crashed run's litter.
    [ -n "$(find "$SP_CHECK_LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ] || return 0
    rmdir "$SP_CHECK_LOCK" 2>/dev/null
    mkdir "$SP_CHECK_LOCK" 2>/dev/null || return 0
  }
  trap 'rmdir "$SP_CHECK_LOCK" 2>/dev/null' EXIT INT TERM
  # Stamped before the work, not after: a check that fails must still hold the
  # next one off, or an unreachable API becomes a fork per card open forever.
  np_read && spotify_check_stamp "$(spotify_member_key "$SP_NP_TITLE" "$SP_NP_ARTIST")"
  sp_main_check; rc=$?
  rmdir "$SP_CHECK_LOCK" 2>/dev/null
  trap - EXIT INT TERM
  return "$rc"
}

# --------------------------------------------------------------------------
# card - the row action: fork, record the outcome, put the card back up

# Wait for the engine's close to land before re-opening, rather than sleeping a
# guessed interval. card.sh appends `; card.sh media close` to every row action,
# so at the moment this worker starts the popup is still up and is about to go
# down; opening now would just be undone. Two seconds is a ceiling, not a
# target - the close normally lands within one --query.
#
# When the card was never open (a hotkey add, say) the first query already reads
# `off` and this returns immediately - which is why `card` mode is wired only to
# the row and the hotkey path uses the plain add.
sp_card_reopen() {
  local i=0
  while [ "$i" -lt 20 ]; do
    [ "$(sketchybar --query media 2>/dev/null | jq -r '.popup.drawing' 2>/dev/null)" = "on" ] || break
    sleep 0.1; i=$(( i + 1 ))
  done
  "$CONFIG_DIR/plugins/card.sh" media open >/dev/null 2>&1
}

# stdout and stderr are captured separately: stdout is the one-word outcome and
# stderr is the reason, and folding them together would make the token
# unparseable on exactly the failure paths that need a reason most.
sp_card_worker() {
  local out rc errf tok detail
  # Orphaned on purpose, and deaf to the hangup that tearing down the click
  # script's session could send: the whole point of this worker is to outlive
  # the click that started it.
  trap '' HUP
  errf="$SB_CACHE_DIR/spotify_err.$$"
  out="$(sp_main_add 2>"$errf")"; rc=$?
  detail=''
  case "$out" in
    added)              tok=added ;;
    "already in "*)     tok=already ;;
    "no track playing") tok=none ;;
    "not configured")   tok=unconfigured ;;
    *)                  tok=error ;;
  esac
  # A zero exit with an unrecognised word is still a bug, not a success.
  [ "$rc" = 0 ] || tok=error
  if [ "$tok" = error ]; then
    # The last line of stderr is the proximate cause; the lines above it are
    # context ("current: <track>") that would only crowd a 64-character row.
    detail="$(tail -n 1 "$errf" 2>/dev/null)"
    [ -n "$detail" ] || detail="exit $rc"
  fi
  rm -f "$errf"
  spotify_outcome_write "$tok" "$detail"
  sp_card_reopen
}

# --------------------------------------------------------------------------
# Sourced as a library, or run as a program?
#
# cards/media.sh sources this file for spotify_member_state, spotify_member_key,
# spotify_outcome_read and spotify_check_due - the format of $SP_MEMBERS and
# $SP_OUTCOME is defined here and must not be re-implemented over there, where
# it would drift the first time a field was added. Sourcing costs a parse and no
# process, which is the budget a card render has.
#
# `set -u` therefore belongs to the program and not to the file: check.sh
# sources cards/media.sh with `set +u` deliberately, and a library that turns
# the caller's shell options back on is a library that breaks its callers.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

set -u

case "${1:-add}" in
  add)
    sp_main_add
    ;;
  card)
    # Detached, all three descriptors closed off. sketchybar waits for a
    # click_script to exit before running the next thing, and a child that still
    # holds the inherited stdout would keep that wait alive - the popup would
    # sit frozen for the length of the API round trip and only then close.
    ( sp_card_worker & ) >/dev/null 2>&1 </dev/null
    ;;
  check)
    sp_check_guarded
    ;;
  *)
    die "usage: $(basename "$0") [add|card|check]"
    ;;
esac
