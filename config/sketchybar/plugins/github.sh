#!/usr/bin/env bash
# GitHub for the bar: the number of open PRs waiting on YOUR review, and the
# cache behind the popup's three sections (orgs, recently-pushed repos, review
# requests).
#
#   github.sh              bar tick - dispatch the card, refresh the cache, paint
#   github.sh --refresh    fetch now, ignore the tick, print nothing
#   github.sh --print      dump the cache to stdout (debugging; no secret in it)
#
# WHY THE ITEM FETCHES AND THE CARD DOES NOT. Every other card in this config
# reads something local - a file, ipconfig, a cached calendar - and can afford
# to build itself on the click. This one talks to api.github.com, and four
# round trips over hotel wifi is several seconds of a popup that is already on
# screen and empty. So the tick owns the network and the card owns nothing but
# a jq over $GITHUB_CACHE. plugins/claude_usage.sh + cards/claude.sh set the
# pattern, including the reason the two TTLs are different numbers.
#
# ---------------------------------------------------------------------------
# THE TRANSPORT IS THE gh CLI. DO NOT "FIX" IT TO curl - THAT WAS TRIED, IT
# WORKED, AND IT WAS DELIBERATELY REMOVED.
#
# gh owns the three things a hand-rolled HTTP client has to keep owning
# forever: the credential (keychain, token refresh, SSO), pagination, and the
# REST API version. None of those are interesting problems and all of them
# rot. So gh is the transport, and this file is a shape-and-cache layer over
# `gh api` and nothing else.
#
# THE gh TLS BLOCK IS OVER as of 2026-09-07. `gh api user` returns the login and
# `github.sh --refresh` classifies ok (2 orgs, 5 repos, 0 review requests), so the
# widget is live again and needed no code change - it was always correct, just
# idle behind a failure it named accurately. The account is `stijnsymons`.
#
# The rest of this block is kept as HISTORY, not as a description of today. It
# cost a long diagnosis and the failure can return the moment the endpoint agent
# is reconfigured or a new machine is enrolled, so the vocabulary below and the
# measured dead ends stay where the next person will find them.
#
# WHAT WAS BROKEN. Aikido's endpoint agent terminates TLS and re-signs
# api.github.com with its own root. It publishes that root into per-runtime PEM
# bundles - which is why curl, python and node are all fine - but NOT into the
# macOS System keychain. gh is a Go binary and Go on darwin verifies through
# Security.framework, so it never sees the root and every single call dies:
#
#   Get "https://api.github.com/user": tls: failed to verify certificate:
#   x509: “Aikido Endpoint Protection Root CA” certificate is not trusted
#   ... OSStatus -26276
#
# THE SYMPTOM IF IT RETURNS: a yellow GitHub glyph on the bar and a card whose
# second row reads "gh verifies via the System keychain · Aikido root absent".
# That is this, it is not a bug in this file, and it is not an auth problem -
# `GH_TOKEN=<a valid PAT> gh api user` fails identically. Go cannot complete a
# TLS handshake with GitHub on this machine AT ALL.
#
# THINGS THAT DO NOT FIX IT, ALL MEASURED:
#   SSL_CERT_FILE / CURL_CA_BUNDLE pointing at Aikido's bundle - Go on darwin
#     ignores both and goes to Security.framework regardless. These were in
#     this file for the curl era; they are gone because they were never doing
#     anything for gh.
#   GODEBUG=x509usefallbackroots=1 - swaps macOS verification for Go's bundled
#     Mozilla root set, which by definition cannot contain a private
#     interception root. Strictly worse.
#   A PAT - see above. Not an auth problem.
#
# THE ONLY FIX was the Aikido root landing in the System keychain - an MDM
# matter, and that is how it cleared. While it was broken the widget was correct
# and idle: it named the exact failure on the card instead of rendering as an
# empty list, which is the entire reason the failure vocabulary below exists and
# why that vocabulary is worth keeping now that the common path is green.
# ---------------------------------------------------------------------------
#
# gh AND jq ARE ON $PATH BECAUSE colors.sh PUT THEM THERE. launchd hands the
# bar no login shell; gh lives in /opt/homebrew/bin, which colors.sh prepends,
# and without that repair both `gh` and `jq` are missing and every payload here
# fails to build.
set -u

source "$CONFIG_DIR/colors.sh"

# Hover dispatch first, and before anything that can touch the network: this
# same script is the handler for the routine tick AND for mouse.exited, and the
# mouse.exited branch is an exec. Refreshing first would pay for four API calls
# and then throw the process away. Same ordering, same reason, as wifi.sh.
if [ -n "${NAME:-}" ] && command -v card_dispatch >/dev/null 2>&1; then
  card_dispatch github
fi

# Kept in step with cards/github.sh, which declares the same default. Two
# declarations rather than a shared file because the card is SOURCED by card.sh
# and this is EXECUTED by sketchybar - there is no process they share.
GITHUB_CACHE="${SB_GITHUB_CACHE:-$SB_CACHE_DIR/github.json}"

# --- gh's environment, pinned rather than inherited --------------------------
# gh reads its credential from $GH_CONFIG_DIR, and failing that from
# $XDG_CONFIG_HOME/gh or $HOME/.config/gh (`gh help environment`). So gh needs
# HOME, and under launchd that is a fair thing to worry about.
#
# IT IS SET, and this is provable without a single call: colors.sh - which this
# file has already sourced, under `set -u` - dereferences $HOME twice, once for
# the PATH repair and once for $SB_CACHE_DIR. An unset HOME would have aborted
# every plugin on the bar at that line, and ~/.cache/sketchybar is written by
# half a dozen of them every tick. So no defensive HOME repair here: it would
# be code that can never run, which is worse than no code.
#
# These three are set because their defaults are wrong for a headless tick:
#   the update notifier makes its own network call and prints to the same
#   stderr the classifier below reads, so a "a new release of gh is available"
#   banner would be indistinguishable from an API error;
#   the prompter would block forever on a stdin nobody is attached to;
#   colour would only ever appear if something forced a TTY, and would corrupt
#   the JSON body if it did.
export GH_NO_UPDATE_NOTIFIER=1
export GH_PROMPT_DISABLED=1
export NO_COLOR=1

# How long one call may take before it is killed. gh has NO timeout flag - see
# `gh api --help`, there is no --timeout and no --max-time - so the watchdog is
# coreutils timeout(1), the same way plugins/meeting_fetch.sh wraps gws. Stock
# macOS ships no timeout, so its absence costs the watchdog and not the
# feature. Four calls, so the worst case for a whole tick is ~32s - long, but
# this runs detached on a 600s timer and nothing waits on it. What matters is
# that it is finite: a black-holed connection (captive portal, VPN half up)
# would otherwise park the process forever and a new one would join it every
# ten minutes.
GITHUB_TIMEOUT=8
GITHUB_TMO="$(command -v timeout || true)"

# How many of each the card can draw. These are the row budget - see the
# arithmetic in cards/github.sh - not a preference, so changing one here means
# changing card_rows_max() in colors.sh too.
#
# Three orgs, not four, and the fourth row of that section is not missing: the
# card draws your personal namespace as the first row of the org list, because
# /user/orgs does not include it and half of what you own lives there.
GITHUB_ORG_MAX=3
GITHUB_REPO_MAX=5
GITHUB_PR_MAX=5

# Review requests are fetched deeper than they are drawn, but the count the
# card prints comes from the search API's own total_count and is therefore
# exact regardless of this number. Twenty is just headroom for a future row.
GITHUB_PR_SCAN=20

# WHAT "TOP REPOSITORIES" MEANS HERE: most recently pushed to, across every
# owner you can see - your own account and every org you are a member of.
#
# The alternatives were considered and are worse for a status bar:
#   - Most starred is a frozen list. Nearly everything you touch is a private
#     client repo with zero stars, so the ranking would be noise over a
#     constant and would not change from one month to the next. A row that
#     never changes is a row you stop reading.
#   - Most frequently worked in has no cheap source. The events API is
#     public-only and lossy; the honest local version means walking ~/code for
#     git dirs and reading reflogs, i.e. a filesystem crawl on a timer for a
#     five-row list.
#   - Recently pushed answers the question the bar is for - "what is moving" -
#     it changes daily, and the API sorts it server-side for free.
#
# Configurable because it is one substitution. Valid values are the ones
# /user/repos accepts for `sort`: pushed (default), updated, created,
# full_name. There is deliberately no "stars": the endpoint does not offer it,
# and faking it client-side means pulling 100 repos a tick to rank five.
GITHUB_REPO_SORT="${SB_GITHUB_REPO_SORT:-pushed}"
case "$GITHUB_REPO_SORT" in
  pushed|updated|created|full_name) ;;
  *) GITHUB_REPO_SORT=pushed ;;
esac

# --- transport ---------------------------------------------------------------
# `gh api <rest-path>` AND NOT `gh repo list --json` / `gh search prs --json`,
# and that is a considered choice rather than inertia. The high-level commands
# are GraphQL underneath and rename every field on the way out:
#
#   gh repo list --json  -> nameWithOwner, url, isPrivate, pushedAt
#   REST /user/repos     -> full_name, html_url, private, pushed_at
#   gh search prs --json -> repository{}, isDraft, url, and NO total count
#   REST /search/issues  -> repository_url, draft, html_url, total_count
#
# Adopting them means rewriting the shaping jq below and the reader in
# cards/github.sh for zero behavioural gain. Worse, `gh repo list [<owner>]`
# only lists repos OWNED by the owner you name - it cannot span "mine plus
# every org I am in", which is the whole point of section two - and
# `gh search prs` drops total_count, which is what makes the review heading say
# "5 of 23" instead of silently stopping at five. `gh api` keeps the REST
# response shape, so gh is doing the auth and the versioning and nothing above
# this line had to change.
#
# NO --paginate ANYWHERE, deliberately, and it is not an oversight:
#   /user/orgs   asks for 100 in one page. Nobody is in 101 orgs, and .length
#                is then the exact total the heading needs.
#   /user/repos  asks for exactly the five it draws, sorted SERVER-side across
#                the whole set. --paginate would walk every repo you can see -
#                hundreds of requests - to then throw all but five away.
#   /search/*    returns an OBJECT, and --paginate emits one JSON document per
#                page, so the body would stop being parseable by a single jq.
#                total_count already gives the real number in one request.
#
# THE RESULT COMES BACK IN GLOBALS AND NOT ON STDOUT, AND THAT IS NOT A STYLE
# CHOICE. The obvious form - `out="$(gh_call ...)"` - runs the function in a
# COMMAND SUBSTITUTION, which is a subshell, so every status assignment inside
# it is discarded and the caller reads back the initial 0. That bug was in this
# file and it was silent and total: with every call reporting success the fetch
# took the ok branch for all four sections, cached four empty arrays as though
# GitHub had genuinely answered "nothing", and the card rendered an unreachable
# API as a user with no orgs, no repositories and nothing to review - i.e. as
# the one thing this widget is built never to do.
GH_OUT=""     # response body, gh's stdout
GH_RC=0       # gh's exit code, or 124 when timeout(1) killed it
GH_ERR=""     # gh's own message, folded to one line, for the card's detail row

gh_call() { # gh_call <rest-path> [extra gh api args...]
  local of ef
  of="$(mktemp "${TMPDIR:-/tmp}/sb-github-body.XXXXXX")" || return 1
  ef="$(mktemp "${TMPDIR:-/tmp}/sb-github-err.XXXXXX")"  || { rm -f "$of"; return 1; }
  GH_OUT=""; GH_RC=0; GH_ERR=""

  # No -H Accept and no -H X-GitHub-Api-Version: gh sends both, and pinning the
  # version is exactly the maintenance this conversion was done to hand back.
  #
  # No --include either, though it would hand us the HTTP status line instead
  # of the prose gh_classify() has to match. It was rejected because it puts
  # headers in front of the body on the SUCCESS path too, so the happy path
  # would grow a split-on-blank-line that has to be right every tick to buy
  # precision on a path that only runs when something is already wrong.
  #
  # Unquoted on purpose - the ${x:+...} has to word-split into two argv
  # entries, and collapses to nothing when coreutils is not installed. Same
  # form as plugins/meeting_fetch.sh.
  # shellcheck disable=SC2086
  ${GITHUB_TMO:+"$GITHUB_TMO" "$GITHUB_TIMEOUT"} \
    gh api "$@" >"$of" 2>"$ef" || GH_RC=$?

  GH_OUT="$(cat "$of" 2>/dev/null)"
  # Folded to one line: it ends up in a JSON string the card prints as a single
  # row, and a multi-line message would arrive with escaped newlines that the
  # row renders as literal backslash-n.
  GH_ERR="$(tr '\n\t' '  ' < "$ef" 2>/dev/null)"
  rm -f "$of" "$ef"
  return "$GH_RC"
}

# gh_classify -> one token naming why the last gh_call did not succeed. This is
# the vocabulary the whole widget speaks; cards/github.sh turns each token into
# one sentence and one colour.
#
# THE POINT OF THIS FUNCTION IS THAT "not authenticated" AND "no PRs to review"
# MUST NEVER RENDER THE SAME. They are both an empty list as far as the data is
# concerned. The media card in this config already taught us what happens when
# a failure is allowed to look like an absence: you stop trusting the widget,
# and then you stop looking at it.
#
# gh reports failure as an English sentence on stderr and an exit code that is
# 1 for almost everything (`gh help exit-codes`: 0 ok, 1 anything, 2 cancelled,
# 4 authentication required). So the sentence is what gets matched, and the
# ORDER OF THE ARMS IS THE CONTRACT:
#   - the cert failure first, because it has no HTTP status at all and its
#     message mentions the host, so a later network arm would swallow it;
#   - rate limiting before 403, because a rate limit IS an HTTP 403 and the two
#     need different things done about them (wait vs fix your token);
#   - the auth-required exit code last, because a 401 from the API is more
#     specific than gh's generic "you are not logged in".
gh_classify() {
  # 124 is timeout(1) saying it fired. It is not one of gh's own codes.
  [ "$GH_RC" -eq 124 ] && { printf 'timeout'; return; }

  # The Aikido MITM. Its own token because it is the one failure a user cannot
  # possibly diagnose from "network error": the network is fine, DNS resolves,
  # TCP is accepted, curl on the same host succeeds, and the thing that broke
  # is a trust store.
  case "$GH_ERR" in
    *x509*|*certificate*|*"tls:"*|*OSStatus*|*"unknown authority"*)
      printf 'tls'; return ;;
  esac
  case "$GH_ERR" in
    *"no such host"*|*"connection refused"*|*"no route to host"*|\
    *"network is unreachable"*|*"dial tcp"*)
      printf 'offline'; return ;;
    *"context deadline exceeded"*|*"i/o timeout"*|*"Client.Timeout"*)
      printf 'timeout'; return ;;
  esac

  # gh formats an API error as "<message> (HTTP <code>)" or
  # "HTTP <code>: <message> (<url>)", so the number survives in both shapes.
  case "$GH_ERR" in *"HTTP 401"*) printf 'no-auth'; return ;; esac

  # The body is checked as well as the message: on a secondary rate limit the
  # useful wording is in the JSON gh echoed, not in the one-line summary.
  case "$GH_ERR$GH_OUT" in
    *"rate limit"*|*"secondary rate"*|*"abuse detection"*)
      printf 'rate-limited'; return ;;
  esac
  case "$GH_ERR" in *"HTTP 429"*) printf 'rate-limited'; return ;; esac

  # 404 is a scope problem here, not a missing page. GitHub answers 404 for a
  # resource your credential cannot see, so on these four endpoints it means
  # read:org is missing, or the org has SSO and the token is not authorised.
  case "$GH_ERR" in *"HTTP 403"*|*"HTTP 404"*) printf 'forbidden'; return ;; esac
  case "$GH_ERR" in *"HTTP 5"*) printf 'error'; return ;; esac

  [ "$GH_RC" -eq 4 ] && { printf 'no-token'; return; }
  case "$GH_ERR" in
    *"gh auth login"*|*"authentication required"*|*"no oauth token"*|\
    *"not logged in"*)
      printf 'no-token'; return ;;
  esac
  printf 'error'
}

# gh_is_array <text> - true when the text is a JSON array.
#
# Belt and braces on every list endpoint. A zero exit from gh is not a promise
# that the body is what we asked for: a captive portal answers 200 with a login
# page. Without this the string goes to `jq --argjson`, which fails, which
# kills the whole payload for every section at once - so the check is per
# section and a bad body degrades exactly one of them. extip.sh makes the same
# shape check on its providers for the same reason.
gh_is_array() {
  [ -n "$1" ] || return 1
  printf '%s' "$1" | jq -e 'type == "array"' >/dev/null 2>&1
}

# --- the fetch ---------------------------------------------------------------
# Four calls, not one GraphQL query that could do all three sections at once.
# The GraphQL form is one request instead of four and was rejected anyway: a
# single query fails whole, so one org the token cannot see under SSO would
# take the repo list and the review requests down with it. Separate calls
# degrade one section at a time, which is what the card is built to draw. At
# 600s the difference is 24 requests an hour against a 5000/hour limit.

# github_fetch -> the whole payload on stdout as one JSON object, always.
# Never fails: a section that could not be fetched comes back with its own
# status and an empty array, and the merge below restores its previous value.
github_fetch() {
  local login orgs repos prs prs_total
  local login_st=ok orgs_st=ok repos_st=ok prs_st=ok detail=""

  # 1. Who we are. Needed because /user/orgs does NOT include your own account
  #    and the personal namespace is half the point of the section - most of
  #    what you push to on a Sunday lives under it, not under an org.
  #
  #    This is also the canary: it is the cheapest endpoint GitHub has, so the
  #    cert wall, an expired credential and a dead link all announce themselves
  #    here first and the detail row quotes THIS message.
  login=""
  gh_call user
  if [ "$GH_RC" -ne 0 ]; then
    login_st="$(gh_classify)"; detail="$GH_ERR"
  else
    login="$(printf '%s' "$GH_OUT" | jq -r '.login // ""' 2>/dev/null)"
    [ -n "$login" ] || login_st=error
  fi

  # 2. The orgs. The full page is fetched even though three rows are drawn: the
  #    shaping below keeps the TOTAL so the section heading can say
  #    "Organisations · 3 of 6" instead of stopping at three with no sign that
  #    it did. Same request either way.
  gh_call "user/orgs?per_page=100"
  orgs="$GH_OUT"
  if [ "$GH_RC" -ne 0 ] || ! gh_is_array "$orgs"; then
    orgs_st="$(gh_classify)"; [ -z "$detail" ] && detail="$GH_ERR"
    orgs='[]'
  fi

  # 3. The repositories. /user/repos and not /users/<login>/repos, and that is
  #    a correctness fix rather than a style choice: the per-user form lists
  #    repos OWNED BY that user, so it would show the personal account's side
  #    projects and none of novemberfiveco - i.e. it would omit every repo the
  #    user is actually paid to touch. (`gh repo list` has the same blind spot,
  #    which is one of the reasons this file does not use it.) The default
  #    affiliation here - owner, collaborator, organization_member - spans all
  #    of them, and `sort` is applied server-side across the whole set rather
  #    than to whatever the first page happened to contain.
  gh_call "user/repos?sort=$GITHUB_REPO_SORT&direction=desc&per_page=$GITHUB_REPO_MAX"
  repos="$GH_OUT"
  if [ "$GH_RC" -ne 0 ] || ! gh_is_array "$repos"; then
    repos_st="$(gh_classify)"; [ -z "$detail" ] && detail="$GH_ERR"
    repos='[]'
  fi

  # 4. Review requests. review-requested:@me is resolved by GitHub against the
  #    credential, so this stays correct even when call 1 above failed and we
  #    do not know our own login.
  #
  #    -X GET with -f, and not a hand-encoded query string: `gh api` switches
  #    to POST the moment a field is added, which is what -X GET is undoing,
  #    and in exchange gh does the percent-encoding of the q expression. This
  #    is the documented form - `gh api --help` ships it as an example, spelled
  #    `gh api -X GET search/issues -f q=...`.
  #
  #    sort=updated is "most recent". Worth noting the opposite order is
  #    arguably more useful for a review QUEUE - the OLDEST request is the one
  #    you are keeping somebody waiting on - and it is one substitution away if
  #    that turns out to be true in use.
  #
  #    total_count comes back with the results, so the "3 of 11" in the section
  #    heading is exact rather than capped at what we asked for.
  prs='[]'; prs_total=0
  gh_call search/issues -X GET \
    -f 'q=is:pr is:open review-requested:@me' \
    -f sort=updated -f order=desc -f "per_page=$GITHUB_PR_SCAN"
  if [ "$GH_RC" -ne 0 ]; then
    prs_st="$(gh_classify)"; [ -z "$detail" ] && detail="$GH_ERR"
  else
    prs="$(printf '%s' "$GH_OUT" | jq -c '.items // []' 2>/dev/null)"
    prs_total="$(printf '%s' "$GH_OUT" | jq -r '.total_count // 0' 2>/dev/null)"
    case "$prs_total" in ''|*[!0-9]*) prs_total=0 ;; esac
    gh_is_array "$prs" || { prs='[]'; prs_st=error; }
  fi

  # Every string field below is forced non-empty. cards/github.sh reads these
  # back as tab-separated fields and a tab is IFS WHITESPACE - bash collapses a
  # run of it, so one empty field does not read back as empty, it shifts every
  # field after it one column left and the row renders as garbage or is dropped
  # outright. cards/claude.sh documents the same trap for its own payload.
  #
  # NO APOSTROPHES ANYWHERE IN THIS jq PROGRAM. It is a single-quoted shell
  # word, so one apostrophe in a comment ends the quote and bash reports a
  # syntax error twenty lines further down at the first bare $variable.
  jq -n \
    --argjson orgs   "${orgs:-[]}" \
    --argjson repos  "${repos:-[]}" \
    --argjson prs    "${prs:-[]}" \
    --argjson prtot  "${prs_total:-0}" \
    --arg login      "$login" \
    --arg login_st   "$login_st" \
    --arg orgs_st    "$orgs_st" \
    --arg repos_st   "$repos_st" \
    --arg prs_st     "$prs_st" \
    --arg detail     "$detail" \
    --argjson now    "$(date +%s)" \
    --argjson orgmax  "$GITHUB_ORG_MAX" \
    --argjson repomax "$GITHUB_REPO_MAX" \
    --argjson prmax   "$GITHUB_PR_MAX" '
    # Free text from an API ends up in a tab-separated row. Strip the
    # separators at the source, exactly as colors.sh:card_text() does for
    # everything else on the bar.
    def clean: (. // "") | tostring | gsub("[\t\r\n]"; " ") | gsub("  +"; " ")
               | sub("^ +"; "") | sub(" +$"; "");
    def orblank($d): if (. | clean) == "" then $d else (. | clean) end;
    def ts: (. // "") | tostring | (try fromdateiso8601 catch 0);
    # The search API gives no repository object, only repository_url
    # (https://api.github.com/repos/<owner>/<name>). The short name is the last
    # segment - the same derivation gh itself does to fill in the `repository`
    # field of `gh search prs --json`, so the two agree.
    def reponame: (. // "") | tostring | split("/") | (.[-1] // "?");

    {
      at: $now,
      checked: $now,
      login:  ($login | orblank("-")),
      detail: ($detail | clean | .[0:120] | orblank("-")),
      login_status: $login_st, orgs_status: $orgs_st,
      repos_status: $repos_st, prs_status:  $prs_st,

      # The login is whitelisted rather than escaped. It is interpolated into a
      # row ACTION - an open of https://github.com/<login> - and the
      # metacharacter filter in card.sh clears an action that fails it,
      # silently, costing the row its click with no other symptom. GitHub
      # logins are [A-Za-z0-9-] by construction, so anything else here is a bug
      # or a hostile response and is dropped at the source instead.
      org_total: ($orgs | length),
      orgs: [ $orgs[] | select(.login != null)
              | { login: (.login | clean) }
              | select(.login | test("^[A-Za-z0-9][A-Za-z0-9-]*$")) ][0:$orgmax],

      repos: [ $repos[]
               | { name:    (.full_name | orblank("?")),
                   url:     (.html_url  | orblank("-")),
                   private: (.private == true),
                   at:      ((.pushed_at // .updated_at) | ts) } ][0:$repomax],

      pr_total: $prtot,
      prs: [ $prs[]
             | { repo:   (.repository_url | reponame | orblank("?")),
                 number: (.number // 0),
                 title:  (.title | orblank("(untitled)")),
                 url:    (.html_url | orblank("-")),
                 draft:  (.draft == true),
                 at:     (.updated_at | ts) } ][0:$prmax]
    }
  ' 2>/dev/null
}

# github_stamp <status> <detail> - record a verdict reached without a fetch.
# Everything already cached survives; only the verdict and the attempt time
# move. This is what makes "gh is not signed in" a state the card can name
# rather than an empty payload it has to guess at.
github_stamp() {
  local prev tmp
  prev='{}'
  [ -s "$GITHUB_CACHE" ] && prev="$(cat "$GITHUB_CACHE" 2>/dev/null)"
  case "$prev" in '') prev='{}' ;; esac
  tmp="$GITHUB_CACHE.tmp.$$"
  ( umask 077
    printf '%s' "$prev" | jq -c \
      --arg st "$1" --arg detail "$2" --argjson now "$(date +%s)" '
      { at: (.at // 0), checked: $now, status: $st, detail: $detail,
        login: (.login // "-"),
        login_status: $st, orgs_status: $st, repos_status: $st, prs_status: $st,
        orgs: (.orgs // []), org_total: (.org_total // 0),
        repos: (.repos // []),
        prs: (.prs // []), pr_total: (.pr_total // 0) }
    ' > "$tmp" 2>/dev/null ) \
    && [ -s "$tmp" ] && mv -f "$tmp" "$GITHUB_CACHE" || rm -f "$tmp"
}

# github_write - fetch, merge with what is already cached, store atomically.
github_write() {
  local fresh prev tmp worst

  # gh is a brew install and colors.sh is what puts /opt/homebrew/bin on PATH,
  # so this fires either when gh is genuinely absent or when that repair broke.
  # Named rather than folded into the generic "fetch failed", because the two
  # need completely different things done about them.
  if ! command -v gh >/dev/null 2>&1; then
    github_stamp no-gh 'the gh CLI is not on PATH'
    return
  fi

  # No credential at all, answered WITHOUT a request.
  #
  # `gh auth token` and deliberately not `gh auth status`: status VALIDATES the
  # credential over the network, so behind the cert wall above it reports "the
  # token is invalid" having never reached GitHub - measured, 0.16s - and would
  # send a perfectly well-configured user to `gh auth login` to fix a problem
  # that is not theirs. `gh auth token` reads the config and the keychain and
  # nothing else, which is exactly the question being asked here.
  #
  # The token itself goes straight to /dev/null. It is never captured, never
  # printed, never passed in argv and never written to the cache - gh is the
  # only thing in this file that ever holds it.
  if ! gh auth token >/dev/null 2>&1; then
    github_stamp no-token 'gh has no credential for github.com'
    return
  fi

  fresh="$(github_fetch)"
  [ -n "$fresh" ] || { github_stamp error 'could not build the payload'; return; }

  # The worst of the four verdicts wins the top-level status, ordered by what a
  # human would do about it: sign in again, fix the scopes, wait out the limit,
  # fix the trust store, check the network, then everything else.
  worst="$(printf '%s' "$fresh" | jq -r '
    [.login_status, .orgs_status, .repos_status, .prs_status] as $s
    | ["no-token","no-auth","forbidden","rate-limited","tls","timeout","offline","error","ok"]
    | map(select(. as $c | $s | index($c))) | .[0] // "ok"')"

  # Merge. A section that failed keeps whatever it had - stale repo names are
  # still the right repo names and their URLs still work - and `at` rolls back
  # to the previous successful fetch so the header dates the DATA rather than
  # the attempt.
  #
  # Sections that DID succeed are still written even when a sibling failed:
  # newer data is strictly better. That makes the reported age a FLOOR rather
  # than an estimate, and erring toward "older than it really is" is the safe
  # direction - it can only make the card warn when it did not have to.
  prev='{}'
  [ -s "$GITHUB_CACHE" ] && prev="$(cat "$GITHUB_CACHE" 2>/dev/null)"
  case "$prev" in '') prev='{}' ;; esac

  tmp="$GITHUB_CACHE.tmp.$$"
  # umask, not a chmod after the fact: the file names every private repo you
  # can see and every PR title waiting on you, and between a plain `>` and a
  # `chmod 600` there is a window where it is world-readable. (No credential is
  # ever in here - only what it fetched.)
  ( umask 077
    printf '%s' "$fresh" | jq -c \
      --argjson prev "$prev" --arg worst "$worst" '
      . as $new
      | .status = $worst
      | .orgs      = (if $new.orgs_status  == "ok" then $new.orgs
                      else ($prev.orgs  // []) end)
      | .org_total = (if $new.orgs_status  == "ok" then $new.org_total
                      else ($prev.org_total // 0) end)
      | .repos     = (if $new.repos_status == "ok" then $new.repos
                      else ($prev.repos // []) end)
      | .prs       = (if $new.prs_status   == "ok" then $new.prs
                      else ($prev.prs   // []) end)
      | .pr_total  = (if $new.prs_status   == "ok" then $new.pr_total
                      else ($prev.pr_total // 0) end)
      | .login     = (if $new.login == "-" then ($prev.login // "-")
                      else $new.login end)
      | .at        = (if $worst == "ok" then $new.at else ($prev.at // 0) end)
    ' > "$tmp" 2>/dev/null ) \
    && [ -s "$tmp" ] && mv -f "$tmp" "$GITHUB_CACHE" || rm -f "$tmp"
}

# --- the bar item ------------------------------------------------------------
# WHAT THE ITEM SHOWS, AND WHY IT IS A COUNT AND NOT JUST A LOGO. Two of the
# three popup sections are navigation - the orgs and the repo list have no
# state worth a permanent slot on the bar. The review queue does: it is the
# only one of the three that is somebody else waiting on you, and it is the
# reason to look at the card at all. A bare logo would be a bookmark, and a
# bookmark does not need to be on screen.
#
# Colour carries the failure, the label carries the number, and the two are
# deliberately on different channels: a red logo with no number cannot be
# mistaken for a healthy one showing a zero.
#
#   grey logo,   no label   nothing waiting on you
#   white logo,  N orange   N reviews waiting (red at 5+)
#   yellow logo, N dim      stale, unreachable, rate limited or cert-blocked -
#                           transient or environmental, the number is old
#   red logo,    no label   gh missing, not signed in, credential rejected or
#                           out of scope - needs you to do something
#
# The yellow/red split is the difference between "on a train" and "broken", and
# it matters because red is only worth having if it is rare enough to be read.
# The Aikido cert wall is YELLOW on purpose: there is nothing the user can do
# about it from this laptop, so it is environmental, not broken-by-you.
GITHUB_STALE_AFTER=1800

github_paint() {
  local at status prs age icon_color label label_color

  if [ ! -s "$GITHUB_CACHE" ]; then
    # Before the very first tick lands. Dim, unlabelled, and NOT red: nothing
    # has gone wrong yet, we simply have not asked.
    sketchybar --set "$NAME" icon.color="$FG_DIM" label="" label.drawing=off
    return
  fi

  IFS=$'\t' read -r at status prs <<GHMETA
$(jq -r '[(.at // 0), (.status // "error"), (.prs | length)] | @tsv' \
        "$GITHUB_CACHE" 2>/dev/null)
GHMETA
  case "${at:-}"  in ''|*[!0-9]*) at=0 ;; esac
  case "${prs:-}" in ''|*[!0-9]*) prs=0 ;; esac
  status="${status:-error}"

  age=$(( $(date +%s) - at ))
  # Clamped, for the same reason cards/claude.sh clamps its capture age: NTP
  # stepping the clock backwards makes a fresh fetch look like it came from the
  # future, and a negative age would fall through to "fresh" only by accident.
  [ "$age" -lt 0 ] && age=0

  label=""; label_color="$FG_DIM"; icon_color="$FG_DIM"

  case "$status" in
    ok)
      if [ "$at" -eq 0 ] || [ "$age" -gt "$GITHUB_STALE_AFTER" ]; then
        # The last fetch worked but the data predates three of them, so the
        # tick is not running - a wedged item, a reload, a laptop that slept.
        # Worth showing, because the count on screen is then answering a
        # question about half an hour ago.
        icon_color="$YELLOW"
        [ "$prs" -gt 0 ] && { label="$prs"; label_color="$FG_DIM"; }
      elif [ "$prs" -gt 0 ]; then
        icon_color="$FG"; label="$prs"
        label_color="$ORANGE"
        [ "$prs" -ge 5 ] && label_color="$RED"
      fi
      ;;
    offline|rate-limited|timeout|tls)
      icon_color="$YELLOW"
      [ "$prs" -gt 0 ] && { label="$prs"; label_color="$FG_DIM"; }
      ;;
    no-gh|no-token|no-auth|forbidden|error|*)
      icon_color="$RED"
      ;;
  esac

  if [ -n "$label" ]; then
    sketchybar --set "$NAME" icon.color="$icon_color" \
                             label="$label" label.color="$label_color" \
                             label.drawing=on
  else
    sketchybar --set "$NAME" icon.color="$icon_color" label="" label.drawing=off
  fi
}

# --- entry -------------------------------------------------------------------
case "${1:-}" in
  --refresh) github_write; exit 0 ;;
  --print)   cat "$GITHUB_CACHE" 2>/dev/null; exit 0 ;;
esac

# Refresh on the tick, unconditionally, and only on the tick.
#
# Unconditional because refreshing on a schedule and expiring on a read are
# different jobs; plugins/claude_usage.sh has the full post-mortem of what
# happens when one number is made to do both (the refresh drifts, and roughly
# one click in five lands in the gap and pays full price on the click path).
# The reader's tolerance lives in cards/github.sh and is three of these ticks,
# so under normal operation it never fires at all.
#
# $NAME is the guard. sketchybar sets it for an item script and nothing else
# does, so running this by hand to look at the paint logic does not fire four
# API calls.
[ -n "${NAME:-}" ] && github_write

# NAME is also what --set needs, so the paint is inside the same guard by
# necessity rather than by choice - a standalone run has no item to paint.
[ -n "${NAME:-}" ] && github_paint

exit 0
