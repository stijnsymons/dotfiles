#!/bin/sh
# Close dead "open in the app" launcher tabs in Brave a few seconds after
# Zoom / Teams / Notion / Figma actually take the handoff.
#
# The problem: click a Zoom or Teams link, Brave shows an interstitial ("open
# in zoom.us?" / "Open Microsoft Teams?"), the desktop app opens, and the
# now-useless tab just sits there in Brave forever. Notion and Figma have the
# same problem but a worse tell: their desktop-app dialog fires while the tab
# is STILL SITTING ON THE REAL DOCUMENT URL -- there is no distinct handoff
# URL to match on, so URL alone can never tell a dead launcher tab apart from
# a document you're actually reading in the browser. This agent watches for
# both shapes and cleans up only the dead ones.
#
# TWO MATCHING CLASSES, because Zoom/Teams and Notion/Figma need genuinely
# different evidence (see service_class() below):
#
#   "url" class (Zoom, Teams) -- the URL itself is trustworthy: Zoom appends
#   '#success' only after a real app handoff, and Teams' '/dl/launcher/' page
#   only exists to hand off. A tab is closed once (a) its URL matches one of
#   these narrow post-handoff patterns, (b) the desktop app is running
#   (pgrep -x), and (c) it has held that URL for DWELL seconds. Frontmost
#   app is deliberately NOT part of this class: after a real handoff the
#   user is often back in the desktop app already, but they don't have to
#   be -- staying in Brave after clicking a Zoom link is normal, and adding
#   a focus check here would only produce false negatives (real launcher
#   tabs that never close because the user didn't tab away). The URL is
#   already the trustworthy signal here; a focus check would just weaken it.
#
#   "heuristic" class (Notion, Figma) -- URL can't discriminate (see above),
#   so this class leans on behaviour instead. A tab is closed only when ALL
#   of: (a) its URL is in-scope for the service, (b) it was first observed
#   less than NEWNESS seconds ago (a real handoff tab is brand new; a
#   document you're reading has been open a while), (c) the desktop app is
#   running, (d) the MAPPED desktop app is currently frontmost (Notion for
#   notion.so/notion.com, Figma for figma.com -- not merely "Brave isn't
#   frontmost"), and (e) it has held that state for DWELL seconds. A
#   document you're actively reading keeps Brave frontmost and fails (d);
#   it also drops out of consideration on its own once it's older than
#   NEWNESS seconds, well before (d) is even checked.
#
#   Why "mapped app frontmost", not "Brave not frontmost": an independent
#   validation pass reproduced closing a Notion doc the user had open and
#   was actively reading, seconds after cmd-tabbing to Slack to reply to a
#   message -- "Brave isn't frontmost" is true of cmd-tabbing to ANYTHING,
#   Slack included, and that is not evidence the desktop app took over.
#   "The mapped app is frontmost" is the actual claim the user's approved
#   rule makes ("focus was stolen by the desktop app"), and it costs
#   nothing on the true positive: with StartInterval=3, DWELL=5, NEWNESS=15
#   there are ~4 polls (t~=6,9,12,15s) at which a real handoff's frontmost
#   app can be observed, comfortably covering a cold app launch. The one
#   case this stricter gate loses is the app coming frontmost only
#   momentarily between two polls -- rare, and it just leaves one junk tab
#   open (the safe-direction failure this whole script is built around).
#
# THE FALSE-NEWNESS GOTCHA, take two: "first observed" is measured by this
# script's own poller, not by Brave, and it is keyed on the tab's URL -- but
# Figma rewrites `?node-id=` on every selection and Notion rewrites its path
# (and appends `?pvs=`) on ordinary subpage navigation. Left keyed on the
# exact URL string, EVERY such rewrite mints a brand new state key with
# firstSeen=now, silently resetting the newness clock on a document that
# might have been open for hours -- which defeats NEWNESS entirely, not just
# at the edges. Fixed two ways, both required: (1) for the heuristic class
# only, the state key strips the query string and fragment before anything
# is carried forward or compared (`?node-id=`/`?pvs=` churn no longer mints
# a new key -- see the state-rebuild section below); (2) every entry
# recorded during a poll where the state file did not yet exist is flagged
# "cold" (pre-existing) right there in the state file, and a "cold" entry is
# permanently excluded from the newness check for as long as its key stays
# in state -- not just for one poll. Both mechanisms matter: (1) stops churn
# from resetting a key that's already tracked; (2) stops a document that
# was open before this agent ever looked from being treated as new in the
# first place.
#
# Driven by com.local.MeetingTabCloser.plist, which polls every 3 seconds.
# With a 5 s dwell, a tab first seen matching at poll N is eligible to close
# at poll N+2 (~6 s later) -- close enough to "5 seconds after handoff".
#
# THE FAILURE MODE THIS SCRIPT IS BUILT AROUND: closing a tab the user is
# actually working in is much worse than leaving a junk tab open one extra
# poll. Every pattern below is deliberately narrow because of that. The
# single biggest trap is Microsoft Teams: teams.cloud.microsoft is the URL
# of the user's LIVE Teams web client (chats, notifications, the works) --
# a domain-level Teams match would silently eat that tab. Only the dedicated
# "/dl/launcher/" handoff page is ever a close-pattern; teams.cloud.microsoft
# and teams.microsoft.com/v2/* are additionally listed in the never-close
# guard below, checked BEFORE any close-pattern, so they win even if some
# future close-pattern edit is written too broadly. The equivalent trap for
# Notion/Figma would be guarding the *entire* notion.so/figma.com domain in
# never-close -- don't: never-close always wins over classify_close, so a
# blanket domain guard would make the heuristic class permanently dead on
# arrival. Only the known marketing/login/file-browser pages are guarded
# there, never the actual document/design paths (see is_never_close below).
#
# HOST-ANCHORED MATCHING: every pattern below matches the URL's HOST and
# PATH separately (see url_host/url_path), never the full URL as one glob.
# A shell glob `*` matches `/`, so a naive `case "$url" in https://*.zoom.us/*)`
# doesn't just match zoom.us -- it matches ANY url that merely *contains*
# that text anywhere, including in a query string:
# `https://www.google.com/search?q=...notion.so/Some-Doc...` would classify
# as a Notion document, and `https://duckduckgo.com/?q=.zoom.us/postattendee`
# would classify as Zoom, with no focus or newness gate in the url class to
# catch it. Splitting host from path before matching closes that hole while
# still allowing subdomain wildcards (`*.zoom.us` matches `us02web.zoom.us`)
# without falling for host-suffix confusion (`evil.zoom.us.attacker.com`
# does NOT match `*.zoom.us` under this scheme, because the whole host has
# to match the pattern, not just a prefix of it).
#
# TWO SEPARATE ARMING SWITCHES, on purpose: DRY_RUN below gates the url
# class (Zoom/Teams), and DRY_RUN_HEURISTIC gates the heuristic class
# (Notion/Figma) independently. They ship both =1. Zoom/Teams are
# empirically verified (the Zoom `#success` fragment is screenshot-
# confirmed); the Notion/Figma frontmost-handoff premise is not -- nobody
# has yet watched a real Notion or Figma handoff and confirmed the log shows
# `front=Notion` / `front=Figma` at the right moment. A single DRY_RUN=0
# flip must not be able to arm both at once: review Zoom/Teams evidence and
# flip DRY_RUN separately from reviewing Notion/Figma evidence (via
# CAPTURE=1 through a real handoff of each) and flipping DRY_RUN_HEURISTIC.
# See the CONFIG block below for the exact two-step sequence.
#
# Ships with DRY_RUN=1 and DRY_RUN_HEURISTIC=1: everything below runs
# identically, but instead of closing a tab it logs "WOULD CLOSE". Read a
# day of ~/Library/Logs/meeting-tab-closer.log, confirm nothing surprising
# shows up (especially: teams.cloud.microsoft never appears as a close
# candidate, and no Notion/Figma document you were actually reading shows up
# as WOULD CLOSE), THEN flip the two switches -- separately, per above.
#
# Kill switch: touch /tmp/.meeting-tab-closer.off.$(id -u) for an instant,
# reversible stop (checked first thing, before any osascript, and it also
# resets state -- so anything you did in Notion/Figma/Brave while the
# switch was on starts fresh instead of looking newly-opened the moment you
# remove it). Permanent: launchctl bootout gui/$(id -u)/com.local.MeetingTabCloser.
#
# TCC note: AppleScript control of Brave from an interactive shell needs no
# prompt on this machine, but launchd runs this script in a different TCC
# context and macOS will ask for one-time Automation permission the first
# time osascript actually talks to Brave from launchd -- click Allow. If
# that prompt never appears and the log shows an Apple Event error, check
# System Settings -> Privacy & Security -> Automation for a stale/missing
# entry. (Apple Event error -10810 seen while testing this script in an
# agent sandbox is a sandbox artefact, not a TCC problem -- ignore it there.)
#
# The frontmost-app check (heuristic class only) uses `lsappinfo front` +
# `lsappinfo info`, NOT AppleScript/System Events -- confirmed working from
# a plain shell during build with zero prompts. It was picked over `tell
# application "System Events" to ... whose frontmost is true` deliberately:
# that route needs its own Accessibility grant (separate from the Automation
# grant Brave control needs) and can fail silently under launchd, which
# would make the whole heuristic class quietly never fire -- a false sense
# of safety that's worse than an obvious failure. If lsappinfo ever returns
# nothing (parse failure, sandboxed context, etc.), the heuristic class
# fails CLOSED: "cannot confirm focus was stolen" logs and skips the close,
# it never guesses. The check itself is STRICT -- frontmost must equal the
# one specific app mapped to the matched service (service_app()), not
# merely "anything other than Brave" -- see the false-newness/false-focus
# discussion above for why the looser check was unsafe.
#
# ASYMMETRY WITH THE SIBLING BROWSER-EXTENSION VARIANT, on purpose: this
# script enables Notion and Figma behind the heuristic class above.
# /Users/stijn/code/chrome-auto-meeting-closer (the MV3 extension variant)
# ships Notion/Figma disabled and does NOT implement anything like this
# heuristic, because it structurally can't: a browser extension has no way
# to see macOS processes (condition (c), app-running) or which application
# is frontmost (condition (d)) -- both are OS-level facts only a launchd
# agent can observe. That is the whole reason this launchd variant is the
# PRIMARY deliverable and the extension is the fallback. If you ever look at
# the two side by side and wonder why Notion/Figma behave differently, this
# is why -- it's not an oversight, it's the one thing this variant can do
# that the extension fundamentally cannot.

##############################################################################
# CONFIG -- tune here; nothing below this block should need editing for
# day-to-day use.
##############################################################################
DRY_RUN="${DRY_RUN:-1}"   # 1 = log "WOULD CLOSE" only (SHIP AS 1). 0 = actually
                     # close tabs -- but ONLY for the url class (Zoom/Teams).
                     # Flip this one line after reading a day of DRY_RUN logs
                     # for Zoom/Teams and finding no surprises. Does NOT arm
                     # the heuristic class -- see DRY_RUN_HEURISTIC below.
DRY_RUN_HEURISTIC="${DRY_RUN_HEURISTIC:-1}"  # SEPARATE dry-run switch for the Notion/Figma
                     # heuristic class only (DRY_RUN above no longer covers
                     # it). Kept independent on purpose: Zoom/Teams rest on
                     # an empirically verified URL signal, Notion/Figma rest
                     # on an unverified "the mapped app took focus" premise,
                     # and a single DRY_RUN=0 edit must not arm both at once.
                     # Two-step arming: (1) review a day of Zoom/Teams WOULD
                     # CLOSE lines, flip DRY_RUN=0. (2) separately, run
                     # CAPTURE=1 through one real Notion handoff and one real
                     # Figma handoff, confirm the log shows front=Notion /
                     # front=Figma at the expected moment, THEN flip
                     # DRY_RUN_HEURISTIC=0. Until step 2, Notion/Figma stay
                     # enabled and fully evaluated (dwell, newness, focus --
                     # everything except the actual close) so their WOULD
                     # CLOSE lines are real evidence to review.
CAPTURE="${CAPTURE:-0}"   # 1 = additionally log EVERY tab URL+title seen on the
                     # five target domains, matched or not (noisy), plus the
                     # frontmost app each poll -- use this to sanity-check
                     # the heuristic class (Notion/Figma) and to confirm the
                     # frontmost-app check isn't silently failing. Ship as 0.
                     #
                     # All five values above take an environment override,
                     # so a one-off diagnostic needs no edit to this file:
                     #   CAPTURE=1 sh meeting-tab-closer.sh
                     # The launchd job passes no environment, so it always
                     # gets the shipped defaults written here.
DWELL="${DWELL:-5}"     # seconds a tab must continuously match a close-pattern
                     # before it becomes eligible to close. Applies to both
                     # matching classes below.
NEWNESS="${NEWNESS:-15}"  # heuristic class ONLY (Notion/Figma): a tab must have
                     # been first observed less than this many seconds ago
                     # to even be considered a handoff candidate. This is
                     # what keeps a document you've had open for an hour out
                     # of consideration, on top of the frontmost-app check.
BROWSER="Brave Browser"   # only Brave is polled. A second browser would be
                     # a mechanical copy of this whole script, not a flag.
LOG="$HOME/Library/Logs/meeting-tab-closer.log"
STATE="/tmp/.meeting-tab-closer.$(id -u)"        # /tmp is cleared at boot -> fresh state
OFF="/tmp/.meeting-tab-closer.off.$(id -u)"      # touch this file for an instant kill switch

# Per-service enable flag + pgrep(1) process name. Process names were
# confirmed by hand during build (`ps -axo comm` while each app was running,
# cross-checked against `defaults read .../Info.plist CFBundleExecutable`):
#   zoom.us          -> zoom.us     (matches the bundle/domain name)
#   Microsoft Teams  -> MSTeams     (NOT "Microsoft Teams" -- easy to get
#                                     wrong; the actual binary/comm is MSTeams)
#   Notion           -> Notion
#   Figma            -> Figma
# All four are <=15 chars, so `pgrep -x` (exact, non-truncated) is safe to
# use for all of them.
ZOOM_ENABLED=1;    ZOOM_PROC="zoom.us"
TEAMS_ENABLED=1;   TEAMS_PROC="MSTeams"
NOTION_ENABLED=1;  NOTION_PROC="Notion"   # heuristic class -- see service_class()
FIGMA_ENABLED=1;   FIGMA_PROC="Figma"     # heuristic class -- see service_class()
##############################################################################

# unit separator (0x1F) -- used as the field delimiter when talking to
# osascript, since tab titles can contain almost any other character.
US="$(printf '\037')"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

# --- defensive early exits (cheapest possible idle path first) -------------

# kill switch also resets state (F7): without this, anything opened while
# the switch was on would carry no state entry, so on resume it would look
# newly-opened (firstSeen=now, flag=live) -- indistinguishable from a fresh
# handoff for the heuristic class. Resuming should start cold, exactly like
# the Brave-not-running path just below.
[ -f "$OFF" ] && { rm -f "$STATE"; exit 0; }

pgrep -q "$BROWSER" || {
  rm -f "$STATE"
  exit 0
}

# log housekeeping: keep the audit trail from growing without bound
if [ -f "$LOG" ]; then
  log_size="$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')"
  case "$log_size" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$log_size" -gt 1048576 ]; then
        tail -n 2000 "$LOG" > "$LOG.trunc" 2>/dev/null && mv "$LOG.trunc" "$LOG"
      fi
      ;;
  esac
fi

# --- matching -----------------------------------------------------------
#
# Adding a pattern is meant to be a one-line edit: add a `case` arm to
# classify_close() guarded by that service's _ENABLED flag. Never-close
# guards are a separate list, checked first, so they always win even if a
# close-pattern above is (or becomes) too broad -- belt and braces.

# url_host URL -- echoes the exact host of an https:// URL, or nothing for
# any other scheme (http://, javascript:, etc. never match anything below --
# same as before this fix). This is the F3 fix: a shell glob `*` matches
# `/`, so matching a pattern like `https://*.zoom.us/j/*` against the WHOLE
# url (as this script used to) doesn't anchor to the host at all -- it also
# matches `https://duckduckgo.com/?q=.zoom.us/postattendee`, because the
# leading `*` is happy to consume "duckduckgo.com/?q=" too. Splitting host
# from path FIRST, then matching each half separately (host below, path in
# is_never_close/classify_close), closes that hole. It also does not
# reintroduce host-suffix confusion: `case "$host" in *.zoom.us)` requires
# the ENTIRE $host string to match, so "evil.zoom.us.attacker.com" (where
# ".zoom.us" is merely a substring in the middle) correctly does not match.
url_host() {
  case "$1" in
    https://*)
      rest="${1#https://}"
      printf '%s\n' "${rest%%/*}"
      ;;
  esac
}

# url_path URL -- echoes everything from the first '/' after the host
# onward (path + query + fragment intact, e.g. '/j/123?pwd=x#success'), or
# '/' if the URL is bare (no trailing slash). Nothing for non-https URLs.
url_path() {
  case "$1" in
    https://*)
      rest="${1#https://}"
      case "$rest" in
        */*) printf '/%s\n' "${rest#*/}" ;;
        *)   printf '/\n' ;;
      esac
      ;;
  esac
}

# is_never_close URL -- returns 0 (true) if this URL must NEVER be closed,
# regardless of anything else. Checked BEFORE classify_close. Matches host
# and path separately (see url_host/url_path above -- F3).
is_never_close() {
  host="$(url_host "$1")"
  path="$(url_path "$1")"
  case "$host" in
    # Zoom marketing/account host: guard the whole thing.
    www.zoom.us) return 0 ;;

    # Zoom meeting hosts (any subdomain, and the bare host -- see F8): the
    # web client the user deliberately chose ("Join from browser"), plus
    # account/marketing paths. Never the interstitial /j/<id> without
    # #success -- that one just isn't a close-pattern below.
    *.zoom.us|zoom.us)
      case "$path" in
        /wc/*) return 0 ;;
        /profile*|/meeting*|/recording*|/signin*) return 0 ;;
      esac
      ;;

    # Teams: THE trap. teams.cloud.microsoft is the user's live Teams web
    # client (confirmed open with unread chats during build) -- never touch
    # it, full stop, no path restriction.
    teams.cloud.microsoft) return 0 ;;

    # teams.microsoft.com/v2/* is the other web-client shape. The
    # meetup-join link usually redirects to /dl/launcher/ (caught by the
    # close-pattern below once it lands there) but can settle as the web
    # client if it doesn't redirect, so it's guarded here too rather than
    # ever being a close-pattern.
    teams.microsoft.com)
      case "$path" in
        /v2/*|/l/meetup-join/*) return 0 ;;
      esac
      ;;

    # Notion: guard only the known NON-document pages (marketing, login,
    # account/help) on the www host. Deliberately NOT a blanket
    # notion.so/notion.com guard -- that would make the heuristic
    # close-path in classify_close() permanently dead on arrival, since
    # never-close always wins. This list is best-effort (Notion's marketing
    # surface wasn't exhaustively crawled) rather than empirically verified
    # page-by-page like the Zoom fragment was; treat it as a starting
    # point, not a guarantee -- the newness + focus-stolen legs of the
    # heuristic are what actually carry the safety weight for Notion.
    www.notion.so|www.notion.com)
      case "$path" in
        /|/product*|/pricing*|/login*|/signup*|/desktop*|/help*|/security*|/about*|/templates*|/enterprise*) return 0 ;;
      esac
      ;;

    # Figma marketing/account host: guard the whole thing (root + the
    # known marketing/login paths), PLUS /files/* (the recents/drafts file
    # browser, plural -- not a specific file) since that's also served from
    # www. This arm is checked before the general *.figma.com arm below, so
    # /files/* has to be listed here too or www.figma.com/files/* would
    # fall through unguarded (case picks the first matching host arm only --
    # a real bug caught by the harness during the F3 host-anchoring
    # rewrite). Deliberately NOT guarding /file/, /design/ or /board/
    # (singular) -- those are exactly the shapes classify_close() needs to
    # see for the heuristic close-path; guarding them here would kill
    # Figma the same way a blanket Notion guard would kill Notion.
    www.figma.com)
      case "$path" in
        /|/pricing*|/login*|/signup*|/downloads*|/about*|/education*|/community*|/files/*) return 0 ;;
      esac
      ;;

    # Figma file BROWSER/dashboard on any OTHER figma.com host (fallback
    # for non-www subdomains; www is handled above).
    *.figma.com|figma.com)
      case "$path" in
        /files/*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# classify_close URL -- echoes a service name (zoom/teams/notion/figma) on
# stdout if URL matches an ENABLED close-pattern, else echoes nothing.
# Caller must have already checked is_never_close first. Host-anchored, same
# as is_never_close above (F3).
classify_close() {
  host="$(url_host "$1")"
  path="$(url_path "$1")"
  case "$host" in
    # --- Zoom (any subdomain, and the bare host -- F8). Verified: '#success'
    # fragment appended after successful app handoff, screenshot-confirmed
    # for /j/<id>...#success. ---
    *.zoom.us|zoom.us)
      case "$path" in
        /j/*'#success'*|/s/*'#success'*) [ "$ZOOM_ENABLED" = 1 ] && echo zoom ;;
        /postattendee*)                  [ "$ZOOM_ENABLED" = 1 ] && echo zoom ;;
        /launch/*)                       [ "$ZOOM_ENABLED" = 1 ] && echo zoom ;;
      esac
      ;;

    # --- Teams (the dedicated launcher page only -- see is_never_close
    # for why nothing broader than this exact path prefix is ever added) ---
    teams.microsoft.com)
      case "$path" in
        /dl/launcher/launcher.html*) [ "$TEAMS_ENABLED" = 1 ] && echo teams ;;
      esac
      ;;
    teams.live.com)
      case "$path" in
        /dl/launcher/*) [ "$TEAMS_ENABLED" = 1 ] && echo teams ;;
      esac
      ;;

    # --- Notion (HEURISTIC class -- see service_class()). No URL alone
    # distinguishes a handoff from a document you're reading: the app
    # dialog fires while the tab still sits on the real notion.so/notion.com
    # document URL. So this arm intentionally matches BROADLY (any
    # non-marketing notion.so/notion.com page, see is_never_close for what's
    # excluded) -- it only scopes the URL into the heuristic class. The
    # actual close decision is carried by newness + frontmost-app in the
    # close loop below, not by this pattern. `*.notion.com` also covers
    # `app.notion.com`, which real Notion docs were empirically observed
    # redirecting to during build (`app.notion.com/p/<workspace>/<slug>`).
    *.notion.so|notion.so|*.notion.com|notion.com)
      [ "$NOTION_ENABLED" = 1 ] && echo notion
      ;;

    # --- Figma (HEURISTIC class -- see service_class()). Same story as
    # Notion: the handoff keeps the real file/design URL, so URL alone
    # can't tell handoff from active in-browser editing. Matches the
    # singular file/design/board paths (the actual document shapes) broadly
    # -- the heuristic (newness + frontmost-app), not this pattern, is what
    # gates the close.
    *.figma.com|figma.com)
      case "$path" in
        /design/*|/file/*|/board/*) [ "$FIGMA_ENABLED" = 1 ] && echo figma ;;
      esac
      ;;
  esac
}

# service_class SERVICE -- echoes "url" or "heuristic". The url class trusts
# the URL alone (Zoom/Teams); the heuristic class additionally requires
# newness + frontmost-app evidence in the close loop below (Notion/Figma).
# See the top-of-file comment for why these two classes exist and why the
# url class deliberately does NOT check frontmost app.
service_class() {
  case "$1" in
    zoom|teams)   echo url ;;
    notion|figma) echo heuristic ;;
  esac
}

# service_app SERVICE -- echoes the frontmost-app DISPLAY NAME the
# heuristic class expects to see when a real handoff has happened (F1: the
# focus gate is "the mapped app is frontmost", strictly -- not merely
# "Brave isn't frontmost". See top-of-file comment for why the looser
# check was unsafe). Deliberately a SEPARATE mapping from service_proc()
# below: the pgrep name and the LSDisplayName happen to coincide for Notion
# and Figma, but do not in general (Teams' pgrep name is "MSTeams", its
# display name is "Microsoft Teams") -- keeping them separate avoids
# silently coupling the two if a future service's names diverge. Only
# defined for the heuristic-class services; the url class never calls this.
service_app() {
  case "$1" in
    notion) echo "Notion" ;;
    figma)  echo "Figma" ;;
  esac
}

# frontmost_app -- echoes the display name of the currently-frontmost app
# (e.g. "Brave Browser", "Finder", "Notion"), or nothing if it can't be
# determined. Uses `lsappinfo`, not AppleScript/System Events -- see the
# top-of-file TCC note for why. Callers MUST treat an empty result as
# "cannot confirm focus was stolen" and fail closed (never close).
frontmost_app() {
  front_asn="$(lsappinfo front 2>/dev/null)"
  [ -n "$front_asn" ] || return 0
  lsappinfo info -only name "$front_asn" 2>/dev/null | sed -n 's/.*"LSDisplayName"="\(.*\)"/\1/p'
}

# service_proc SERVICE -- echoes the pgrep(1) process name for a service.
service_proc() {
  case "$1" in
    zoom)   echo "$ZOOM_PROC" ;;
    teams)  echo "$TEAMS_PROC" ;;
    notion) echo "$NOTION_PROC" ;;
    figma)  echo "$FIGMA_PROC" ;;
  esac
}

# is_target_domain URL -- true if URL belongs to one of the four services,
# used only to scope CAPTURE=1 logging (otherwise every poll would dump the
# user's entire tab list).
is_target_domain() {
  case "$1" in
    *zoom.us*|*teams.microsoft.com*|*teams.live.com*|*teams.cloud.microsoft*|*notion.so*|*notion.com*|*figma.com*) return 0 ;;
  esac
  return 1
}

# frontmost app, computed once per poll and reused everywhere below (both
# CAPTURE logging and the heuristic close-decision loop) -- see
# frontmost_app() above for the method and why it's allowed to come back
# empty (fail-closed: an empty FRONT_APP means "cannot confirm focus was
# stolen", never "assume it was").
FRONT_APP="$(frontmost_app)"

# --- enumerate tabs: ONE osascript call -------------------------------
# Loops windows x tabs, prints one line per tab as `URL<US>title`. The URL
# can contain anything except our US delimiter, so it's safe to split on.
# Titles are NOT: a page controls its own <title>, newlines and all, and a
# newline would end the record early and turn the rest of the title into a
# phantom tab with an attacker-chosen "URL". Nothing would actually close
# (the close pass re-matches against live tabs, and no such tab exists), but
# it would corrupt CAPTURE output and hand a web page a say in what we
# consider a candidate -- so titles get their line breaks flattened to
# spaces in AppleScript, before they ever reach the shell.
# AppleScript's `URL of tab` is confirmed (by
# inspecting the user's real, currently-open tabs during build -- several
# already contain a `#fragment`, e.g. gmail's #inbox/... and a Google Docs
# #heading=... link) to include the URL fragment, which the Zoom `#success`
# pattern above depends on.
TABS_RAW="$(osascript 2>>"$LOG" <<APPLESCRIPT
tell application "$BROWSER"
  set urls to {}
  set titles to {}
  repeat with w in windows
    repeat with t in tabs of w
      set end of urls to URL of t
      set end of titles to title of t
    end repeat
  end repeat
end tell

-- Flatten the titles OUT here, not inside the tell block: text item
-- delimiters are a property of AppleScript itself; inside a tell-application
-- block the browser gets asked for them instead and errors (-10006, then
-- -1700). So: collect raw inside the tell, sanitise outside it.
set out to ""
repeat with i from 1 to count of urls
  set text item delimiters to {linefeed, return}
  set parts to text items of (item i of titles)
  set text item delimiters to " "
  set cleanTitle to parts as text
  set text item delimiters to ""
  set out to out & (item i of urls) & (character id 31) & cleanTitle & linefeed
end repeat
return out
APPLESCRIPT
)"

CANDIDATES="$STATE.candidates"
: > "$CANDIDATES"

if [ -n "$TABS_RAW" ]; then
  printf '%s\n' "$TABS_RAW" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    url="${line%%"$US"*}"
    title="${line#*"$US"}"

    if is_never_close "$url"; then
      if [ "$CAPTURE" = 1 ] && is_target_domain "$url"; then
        log "CAPTURE never-close-guard url=$url title=$title front=${FRONT_APP:-UNKNOWN}"
      fi
      continue
    fi

    svc="$(classify_close "$url")"

    if [ "$CAPTURE" = 1 ] && is_target_domain "$url"; then
      log "CAPTURE svc=${svc:-none} url=$url title=$title front=${FRONT_APP:-UNKNOWN}"
    fi

    if [ -n "$svc" ]; then
      # F2: the heuristic class (Notion/Figma) keys state on the URL with
      # its query string and fragment stripped, so ordinary in-app
      # navigation -- Figma's `?node-id=` rewrite on every selection,
      # Notion's `?pvs=` and path changes on subpage nav -- cannot mint a
      # new state key and silently reset firstSeen/the cold flag on a
      # document that's been open for hours (see top-of-file comment). The
      # url class (Zoom/Teams) keys on the exact URL, unchanged: their
      # patterns depend on the fragment (`#success`) and dwell there is
      # about a continuously-matching exact URL, not document identity.
      class="$(service_class "$svc")"
      if [ "$class" = "heuristic" ]; then
        key="${url%%\?*}"
        key="${key%%#*}"
      else
        key="$url"
      fi
      printf '%s %s\n' "$key" "$url" >> "$CANDIDATES"
    fi
  done
fi

# --- state: rebuild from scratch every poll -----------------------------
# Carry forward firstSeen (and the cold flag, see below) for keys still
# matching; new matches get firstSeen=now; anything not in this poll's
# candidate set (navigated away, tab closed, closed by us) is simply not
# written back, i.e. pruned. Line format: `epoch flag key url` (key and url
# last, in that order, since neither can be trusted to be a single token in
# general -- but URLs/keys contain no raw spaces, so splitting on the first
# two spaces for epoch/flag and then taking key as the next token and url
# as everything after it is safe: epoch = up to 1st space, flag = up to
# 2nd space, key = up to 3rd space, url = the rest). For the url class
# key==url always (see the CANDIDATES-building loop above); for the
# heuristic class key is url with '?query'/'#fragment' stripped (F2).
#
# The "flag" column exists only for the false-newness gotcha (see top-of-
# file comment): if $STATE did not exist BEFORE this poll (a cold start --
# first-ever run, or state reset by reboot/kill-switch/Brave relaunch),
# every candidate first recorded on THIS poll is flagged "cold" instead of
# "live". A "cold" entry is pre-existing by definition -- it was open
# before we ever looked -- so the heuristic close-path below refuses to
# ever treat it as newly-opened, for as long as its key stays in state.
# Only entries first recorded on an ordinary (non-cold) poll are flagged
# "live" and eligible for the newness check. Carried-forward entries keep
# whatever flag they already had; the flag is only ever assigned once, at
# the moment an entry is first written.
#
# F4: cold-poll detection uses `[ -f "$STATE" ]` (exists), NOT
# `[ -s "$STATE" ]` (exists AND non-empty). State is legitimately empty
# every poll where there happen to be zero candidate tabs -- which is the
# NORMAL steady state, not a reset -- so `-s` misfired as "cold" on every
# single ordinary Notion/Figma handoff (the poll right before the tab
# opened almost always had zero candidates) and the heuristic class never
# fired at all. `-f` correctly tracks "have we polled before", which is
# true the instant the file has been created once, empty or not.
NOW="$(date +%s)"
NEW_STATE="$STATE.new"
: > "$NEW_STATE"

if [ -f "$STATE" ]; then COLD_POLL=0; else COLD_POLL=1; fi
if [ "$COLD_POLL" = 1 ] && [ -s "$CANDIDATES" ]; then
  log "cold-start: state did not exist -- this poll's candidate(s) are flagged pre-existing, never treated as newly-opened"
fi

if [ -s "$CANDIDATES" ]; then
  while IFS= read -r c_line; do
    [ -z "$c_line" ] && continue
    c_key="${c_line%% *}"
    c_url="${c_line#* }"
    firstseen="$NOW"
    flag="live"
    if [ -f "$STATE" ]; then
      while IFS= read -r s_line; do
        [ -z "$s_line" ] && continue
        s_epoch="${s_line%% *}"
        s_rest="${s_line#* }"
        s_flag="${s_rest%% *}"
        s_rest2="${s_rest#* }"
        s_key="${s_rest2%% *}"
        if [ "$s_key" = "$c_key" ]; then
          firstseen="$s_epoch"
          flag="$s_flag"
          break
        fi
      done < "$STATE"
    fi
    if [ "$firstseen" = "$NOW" ] && [ "$COLD_POLL" = 1 ]; then
      flag="cold"
    fi
    printf '%s %s %s %s\n' "$firstseen" "$flag" "$c_key" "$c_url" >> "$NEW_STATE"
  done < "$CANDIDATES"
fi

mv "$NEW_STATE" "$STATE"
rm -f "$CANDIDATES"

# --- log_once: dedupe close-decision log lines (F5) ----------------------
# Every poll re-evaluates every state entry, and in DRY_RUN a stuck tab
# never leaves state -- so logging unconditionally floods the file
# (measured: ~124 bytes/poll/tab, which is ~10 MB/day with just three
# stuck Zoom tabs), and 1 MB truncation then silently discards all but the
# last ~30 minutes. That defeats the log's entire job: it's the dry-run
# review the whole safety story rests on ("read a day of logs, then arm
# it" is impossible against a 30-minute window). Fix: log a given verdict
# for a given key only the first time it's reached, or when it changes
# from the previous poll's verdict for that same key -- so the log becomes
# a readable event trail (state transitions) instead of a sampling stream
# (every poll, forever). CAPTURE mode's per-tab lines above are untouched
# by this -- that firehose is per-poll on purpose, it's the diagnostic
# tool for exactly this kind of question.
VERDICT_FILE="$STATE.verdict"
NEW_VERDICT_FILE="$STATE.verdict.new"
: > "$NEW_VERDICT_FILE"

log_once() {
  lo_key="$1"; lo_verdict="$2"; lo_msg="$3"
  lo_prev=""
  if [ -f "$VERDICT_FILE" ]; then
    while IFS= read -r lo_line; do
      [ -z "$lo_line" ] && continue
      lo_line_key="${lo_line%% *}"
      lo_line_verdict="${lo_line#* }"
      if [ "$lo_line_key" = "$lo_key" ]; then
        lo_prev="$lo_line_verdict"
        break
      fi
    done < "$VERDICT_FILE"
  fi
  [ "$lo_prev" != "$lo_verdict" ] && log "$lo_msg"
  printf '%s %s\n' "$lo_key" "$lo_verdict" >> "$NEW_VERDICT_FILE"
}

# --- close: url class needs DWELL + app-running; heuristic class ALSO
# needs newness + frontmost-app-stolen (see top-of-file comment and
# service_class() for why the two classes diverge here) -------------------
TO_CLOSE="$STATE.toclose"
: > "$TO_CLOSE"

if [ -s "$STATE" ]; then
  while IFS= read -r st_line; do
    [ -z "$st_line" ] && continue
    st_epoch="${st_line%% *}"
    st_rest="${st_line#* }"
    st_flag="${st_rest%% *}"
    st_rest2="${st_rest#* }"
    st_key="${st_rest2%% *}"
    st_url="${st_rest2#* }"
    elapsed=$((NOW - st_epoch))
    svc="$(classify_close "$st_url")"
    proc="$(service_proc "$svc")"
    class="$(service_class "$svc")"

    if [ "$elapsed" -lt "$DWELL" ]; then
      log_once "$st_key" "dwell-pending" "dwell-pending url=$st_url svc=$svc class=$class elapsed=${elapsed}s"
      continue
    fi

    if ! pgrep -qx "$proc"; then
      log_once "$st_key" "app-not-running" "matched-but-app-not-running url=$st_url svc=$svc class=$class expected_proc=$proc elapsed=${elapsed}s"
      continue
    fi

    if [ "$class" = "heuristic" ]; then
      if [ "$st_flag" = "cold" ]; then
        log_once "$st_key" "cold-preexisting" "heuristic-preexisting url=$st_url svc=$svc elapsed=${elapsed}s (seen on a cold-start poll -- never treated as newly-opened, see top-of-file comment)"
        continue
      fi
      if [ "$elapsed" -ge "$NEWNESS" ]; then
        log_once "$st_key" "not-new" "heuristic-not-new url=$st_url svc=$svc elapsed=${elapsed}s newness_limit=${NEWNESS}s"
        continue
      fi
      if [ -z "$FRONT_APP" ]; then
        log_once "$st_key" "focus-unknown" "focus-check-failed url=$st_url svc=$svc elapsed=${elapsed}s (frontmost app unknown -- failing closed, not treating as a handoff)"
        continue
      fi
      # F1: STRICT gate -- frontmost must equal the ONE app mapped to this
      # service (service_app), not merely "anything other than Brave".
      # "!= Brave" is true of cmd-tabbing to Slack, Finder, anything -- and
      # an independent validation pass reproduced that closing a document
      # the user was actively reading, seconds after tabbing away to reply
      # to a Slack message. "== the mapped app" is the actual claim the
      # user's rule makes (the desktop app stole focus) and costs nothing
      # on the true positive -- see top-of-file comment for the analysis.
      mapped_app="$(service_app "$svc")"
      if [ "$FRONT_APP" != "$mapped_app" ]; then
        log_once "$st_key" "no-handoff" "heuristic-no-handoff url=$st_url svc=$svc front=$FRONT_APP expected=$mapped_app elapsed=${elapsed}s (mapped app not frontmost -- not treated as a handoff)"
        continue
      fi
    fi

    # F6: the heuristic class has its OWN dry-run switch, independent of
    # DRY_RUN -- see DRY_RUN_HEURISTIC in the CONFIG block for why.
    if [ "$class" = "heuristic" ]; then
      effective_dry_run="$DRY_RUN_HEURISTIC"
    else
      effective_dry_run="$DRY_RUN"
    fi

    if [ "$effective_dry_run" = 1 ]; then
      if [ "$class" = "heuristic" ]; then
        log_once "$st_key" "would-close" "WOULD CLOSE url=$st_url svc=$svc class=$class front=$FRONT_APP elapsed=${elapsed}s"
      else
        log_once "$st_key" "would-close" "WOULD CLOSE url=$st_url svc=$svc class=$class elapsed=${elapsed}s"
      fi
    else
      printf '%s\n' "$st_url" >> "$TO_CLOSE"
    fi
  done < "$STATE"
fi

mv "$NEW_VERDICT_FILE" "$VERDICT_FILE"

# --- actually close (live mode only): second, separate osascript call ---
# Enumeration (above) and closing (here) are two different osascript calls,
# so the tab set can have changed in between -- this is why closing matches
# on the tab's URL AT CLOSE TIME (never a remembered index or a stale
# snapshot). Within each window, tabs are visited in reverse index order so
# that closing a higher-indexed tab never invalidates the index of a
# lower-indexed one still to be checked. F9: WINDOWS are also visited in
# reverse order, for the identical reason -- closing a window's last tab
# closes the window itself, which shifts every later window's index the
# same way closing a tab shifts later tab indices. Forward window iteration
# could address the wrong window (or raise an Apple Event error) after an
# earlier window in the list disappeared out from under it.
#
# TO_CLOSE only ever contains URLs whose class already cleared its OWN
# dry-run switch (DRY_RUN for url-class, DRY_RUN_HEURISTIC for heuristic --
# see F6 in the close-decision loop above), so no DRY_RUN check is needed
# here: an empty TO_CLOSE is itself sufficient proof nothing is armed.
if [ -s "$TO_CLOSE" ]; then
  set --
  while IFS= read -r u; do
    [ -n "$u" ] && set -- "$@" "$u"
  done < "$TO_CLOSE"

  if [ "$#" -gt 0 ]; then
    CLOSE_RESULT="$(osascript - "$@" 2>>"$LOG" <<APPLESCRIPT
on run argv
  set US to (character id 31)
  set resultOut to ""
  tell application "$BROWSER"
    repeat with wi from (count of windows) to 1 by -1
      set w to window wi
      set tabCount to count of tabs of w
      repeat with i from tabCount to 1 by -1
        set thisTab to tab i of w
        set thisURL to URL of thisTab
        set isMatch to false
        repeat with target in argv
          if thisURL is (target as text) then
            set isMatch to true
            exit repeat
          end if
        end repeat
        if isMatch then
          set isLast to ((count of tabs of w) is 1)
          close thisTab
          set resultOut to resultOut & thisURL & US & (isLast as text) & linefeed
        end if
      end repeat
    end repeat
  end tell
  return resultOut
end run
APPLESCRIPT
)"
    printf '%s\n' "$CLOSE_RESULT" | while IFS= read -r r_line; do
      [ -z "$r_line" ] && continue
      r_url="${r_line%%"$US"*}"
      r_last="${r_line#*"$US"}"
      if [ "$r_last" = "true" ]; then
        log "closed [last-tab-in-window] url=$r_url"
      else
        log "closed url=$r_url"
      fi
    done
  fi
fi

rm -f "$TO_CLOSE"
