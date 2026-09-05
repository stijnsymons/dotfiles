# shellcheck shell=bash
# GitHub in three sections: the namespaces you belong to, the repositories that
# moved most recently, and the pull requests waiting on your review.
#
# THIS FILE NEVER TOUCHES THE NETWORK, AND THAT IS THE WHOLE DESIGN. It is
# sourced by plugins/card.sh on the click, in front of a popup that is already
# on screen, so anything slower than one jq over a local file is dead air the
# user is looking at. plugins/github.sh owns the four API calls on its own 600s
# tick and leaves the answer in $GITHUB_CACHE; this reads it and nothing else.
# cards/claude.sh set the pattern and plugins/claude_usage.sh records why the
# two TTLs are different numbers.
#
# THE CARD WILL SAY WHY IT IS EMPTY. Several of the states this thing can be in
# - gh not signed in, a rejected credential, a TLS proxy in the way, and
# genuinely nothing to review - all produce an empty list, and they must not
# look alike. Each gets its own glyph, its own colour and its own sentence. The
# media card in this config is the reason that is written down: a failure that
# renders as an absence stops being noticed, and then the widget stops being
# trusted.
#
# THE STATE IT IS IN TODAY IS `tls`, and that is expected rather than a bug.
# plugins/github.sh talks to GitHub through the gh CLI; gh is a Go binary and
# Go on darwin verifies TLS through the System keychain, which does not carry
# Aikido's interception root. The transport note at the top of that file has
# the whole story. The two rows this card draws for it are the only thing
# standing between the next reader and a genuine mystery, so their wording is
# load-bearing - see github_remedy() below.
#
# ROW BUDGET: 19, and card_rows_max() in colors.sh must carry a github arm
# saying so. The arithmetic, worst case:
#     1  provenance header
#     1  the reason row, present only when something is wrong
#     1  divider - Organisations
#     4  personal namespace + 3 orgs
#     1  divider - Recently pushed
#     5  repositories
#     1  divider - Needs your review
#     5  pull requests
#   = 19
# The three dividers are LABELLED, which is what keeps this at 19 rather than
# 22: a plain rule plus a separate heading row per section would be six rows of
# chrome instead of three. The caps (3 orgs, 5 repos, 5 PRs) are enforced by
# plugins/github.sh when it writes the cache AND again by the loops below, so a
# fourth org cannot arrive at render time and silently push the last PR off the
# bottom - which is the one failure card.sh cannot report.

# ellipsize() in plugins/fit.sh measures with ${#text} and cuts with
# ${text:0:n}, and both count BYTES unless the shell is in a UTF-8 locale.
# Under launchd it is not - the bar inherits no LANG at all - so every row here
# would be measured at three bytes per box-drawing character, and the section
# dividers, which are nothing but box-drawing characters, would be cut to a
# third of their length and given an ellipsis. cards/claude.sh has the full
# measurement; the fix is the same line and it has to be an export, because the
# ellipsize() call that needs it happens in card.sh AFTER this file is sourced.
export LC_ALL=en_US.UTF-8

# Kept in step with plugins/github.sh, which declares the same default. Two
# declarations rather than one shared file because the plugin is EXECUTED by
# sketchybar and this is SOURCED by card.sh - they share no process.
GITHUB_CACHE="${SB_GITHUB_CACHE:-$SB_CACHE_DIR/github.json}"

# How old a payload a READER will accept before it says so. Three of the
# plugin's 600s ticks, and deliberately not one or two: the tick refreshes
# unconditionally, so in normal operation the file is never older than 600s and
# this threshold never fires. It exists for the case where the tick stopped -
# a reload, a wedged item, a laptop that slept - and setting it at or just
# above the tick interval is the mistake plugins/claude_usage.sh documents in
# full: writer and reader then race, and a click landing in the gap gets a card
# marked stale for no reason.
GITHUB_STALE_AFTER=1800

# The card's own caps. They must not exceed what plugins/github.sh stores, and
# together with the header, the reason row and the dividers they must not
# exceed the 19 in card_rows_max().
GITHUB_ORG_ROWS=3
GITHUB_REPO_ROWS=5
GITHUB_PR_ROWS=5

# Divider width in characters. The popup sizes itself to its widest row, and at
# 12pt FiraMono the content rows run to a little over this - so a rule of this
# length spans the card without being the row that decides how wide it is.
# Shorter and the sections stop reading as separated; longer and every card is
# as wide as its dividers regardless of what is in it.
GITHUB_RULE_W=52

# "2h" / "3d" / "now". One unit, rounded down, and never "0m" - a push forty
# seconds ago is "now", not a broken clock. Same ladder as
# cards/claude.sh:claude_ago(), minus the word "ago", because these are
# column-aligned suffixes rather than sentences.
github_ago() { # github_ago <epoch>
  local s
  [ "${1:-0}" -gt 0 ] 2>/dev/null || { printf '—'; return; }
  s=$(( $(date +%s) - $1 ))
  [ "$s" -lt 0 ] && s=0
  if   [ "$s" -ge 604800 ]; then printf '%dw' $(( s / 604800 ))
  elif [ "$s" -ge 86400 ];  then printf '%dd' $(( s / 86400 ))
  elif [ "$s" -ge 3600 ];   then printf '%dh' $(( s / 3600 ))
  elif [ "$s" -ge 120 ];    then printf '%dm' $(( s / 60 ))
  else                           printf 'now'; fi
}

# The same, in words, for the header. "captured 4m ago" reads as a sentence;
# the suffix form above does not.
github_ago_words() { # github_ago_words <epoch>
  local s
  [ "${1:-0}" -gt 0 ] 2>/dev/null || { printf 'never fetched'; return; }
  s=$(( $(date +%s) - $1 ))
  [ "$s" -lt 0 ] && s=0
  if   [ "$s" -ge 86400 ]; then printf '%dd ago' $(( s / 86400 ))
  elif [ "$s" -ge 3600 ];  then printf '%dh ago' $(( s / 3600 ))
  elif [ "$s" -ge 120 ];   then printf '%dm ago' $(( s / 60 ))
  else                          printf 'just now'; fi
}

# A labelled rule: "──  Recently pushed  ─────────────────".
#
# The glyph field is a SINGLE SPACE and not empty, and that is load-bearing
# rather than cosmetic. card.sh reads rows with IFS=$'\t'; a tab is IFS
# whitespace, so bash collapses a run of it and an empty first field does not
# read back as empty - it shifts the colour into the glyph and the text into
# the colour, and card.sh then drops the row for having no text. The card would
# simply have no dividers and nothing would say why. cards/claude.sh hit this
# with its chart rows.
#
# U+2500 rather than an em dash: it is a box-drawing character, so it joins up
# into a continuous rule at any size, and it is present in both Hack Nerd Font
# (which paints the glyph column) and FiraMono Nerd Font (which paints the
# label) - checked against the installed font files, not assumed.
github_rule() { # github_rule <label>
  local label="$1" pad n
  label="──  ${label}  "
  n=$(( GITHUB_RULE_W - ${#label} ))
  [ "$n" -lt 2 ] && n=2
  pad=''
  # Braced expansion. `pad="$pad─"` looks equivalent and is not: in a UTF-8
  # locale bash reads the box character's bytes as part of the parameter name,
  # goes looking for a variable called "pad─", and under card.sh:set -u aborts
  # the whole card. cards/claude.sh documents the same trap in its bar renderer.
  while [ "$n" -gt 0 ]; do pad="${pad}─"; n=$(( n - 1 )); done
  printf ' \t%s\t%s\n' "$SEPARATOR" "${label}${pad}"
}

# A GitHub URL, or nothing. Every row action here is `open '<url>'` and card.sh
# clears - silently - any action containing one of `; | & $ \` \ < > ( )` or a
# tab, which costs the row its click and leaves no other trace. The URLs come
# from the API rather than from us, so they are checked rather than trusted:
# the whitelist below admits exactly what a github.com profile/repo/PR URL can
# contain and nothing the filter would reject. A URL that fails it yields an
# empty action, and card.sh renders the row with its text and no click, which
# is the right degrade.
github_url() { # github_url <url>
  case "$1" in
    https://github.com/*)
      case "$1" in
        *[!A-Za-z0-9:/._~#-]*) printf '' ;;
        *) printf '%s' "$1" ;;
      esac ;;
    *) printf '' ;;
  esac
}

# github_action <url> -> the click_script for a row, or empty.
github_action() {
  local u; u="$(github_url "$1")"
  [ -n "$u" ] && printf "open '%s'" "$u"
}

# Human wording for a status token. One place, so "no token" cannot be phrased
# two different ways on the same card. The vocabulary is
# plugins/github.sh:gh_classify().
github_why() { # github_why <status>
  case "$1" in
    no-gh)        printf 'gh CLI not found' ;;
    no-token)     printf 'gh not signed in' ;;
    no-auth)      printf 'credential rejected' ;;
    forbidden)    printf 'credential lacks access' ;;
    rate-limited) printf 'API rate limit reached' ;;
    tls)          printf 'certificate not trusted' ;;
    timeout)      printf 'GitHub timed out' ;;
    offline)      printf 'github.com unreachable' ;;
    error)        printf 'fetch failed' ;;
    *)            printf '%s' "$1" ;;
  esac
}

# The row under the header, present only when something is wrong. It carries
# the REMEDY, which the header cannot: the header has to fit a login and an
# age, and "what do I do about it" is the more useful of the two things a
# broken widget can tell you.
#
# The tls wording is the one that had to be exact, and it names the SYSTEM
# KEYCHAIN rather than the network. Behind Aikido's MITM the link is fine - DNS
# resolves, TCP connects, curl on the same host reaches api.github.com - and
# only gh fails, because Go on darwin verifies through Security.framework and
# Aikido publishes its root everywhere except there. A row saying "network
# error" would send the reader hunting for a problem that does not exist;
# naming the trust store points straight at the one thing that has to change,
# which is an MDM change and not a change to this widget.
github_remedy() { # github_remedy <status> <detail>
  case "$1" in
    no-gh)
      printf '󰀨\t%s\tgh is missing from PATH  ·  brew install gh\n' "$FG_DIM" ;;
    no-token)
      printf '󰀋\t%s\tRun gh auth login  ·  scopes repo, read:org\n' "$FG_DIM" ;;
    no-auth)
      printf '󰀋\t%s\tGitHub rejected the credential  ·  expired or revoked\n' "$FG_DIM" ;;
    forbidden)
      printf '󰌾\t%s\tgh auth refresh -s read:org  ·  and SSO authorise\n' "$FG_DIM" ;;
    rate-limited)
      printf '󰔟\t%s\tBacking off  ·  retries on the next tick\n' "$FG_DIM" ;;
    tls)
      printf '󰌾\t%s\tgh verifies via the System keychain  ·  Aikido root absent\n' "$FG_DIM" ;;
    timeout|offline)
      printf '󰅤\t%s\tShowing the last successful fetch\n' "$FG_DIM" ;;
    *)
      # Only here does gh's own message get a row. It is the case with no known
      # remedy, so the most useful thing to show is what actually came back
      # rather than a guess at what it meant.
      if [ "${2:--}" != '-' ] && [ -n "${2:-}" ]; then
        printf '󰀨\t%s\t%s\n' "$FG_DIM" "$(card_text "$2")"
      else
        printf '󰀨\t%s\tNo further detail\n' "$FG_DIM"
      fi ;;
  esac
}

card_rows() {
  local at checked status login detail org_total pr_total
  local orgs_st repos_st prs_st
  local kind a b c d rest age header_tint header n have
  local name url ts num title draft tint

  # --- nothing on disk at all -------------------------------------------------
  # The window between the config loading and the item's first tick. Not an
  # error, and it must not be painted as one: nothing has failed, we have
  # simply not asked yet.
  if [ ! -s "$GITHUB_CACHE" ]; then
    printf '󰊤\t%s\tGitHub\n' "$FG_DIM"
    printf '󰔟\t%s\tNo data yet  ·  fetching on the next tick\n' "$FG_DIM"
    return
  fi

  # One jq for the whole card, emitting a keyed TSV stream. Not one jq per
  # section: this runs on the click path and four jq spawns is four process
  # creations for a file under 4KB. cards/claude.sh makes the same trade for
  # the same reason.
  #
  # Every emitted field is forced non-empty by plugins/github.sh when it writes
  # the cache - see the IFS-collapse note on github_rule() above for what an
  # empty one does to these reads.
  local stream
  stream="$(jq -r '
    def d($v; $f): ($v // $f) | tostring;
    "META\t\(d(.at;0))\t\(d(.checked;0))\t\(d(.status;"error"))\t\(d(.login;"-"))",
    "ST\t\(d(.orgs_status;"error"))\t\(d(.repos_status;"error"))\t\(d(.prs_status;"error"))",
    "N\t\(d(.org_total;0))\t\(d(.pr_total;0))",
    "DETAIL\t\(d(.detail;"-"))",
    (.orgs[]?  | "ORG\t\(.login)"),
    (.repos[]? | "REPO\t\(.name)\t\(.url)\t\(.at)\t\(if .private then "1" else "0" end)"),
    (.prs[]?   | "PR\t\(.repo)\t\(.number)\t\(.url)\t\(.at)\t\(if .draft then "1" else "0" end)\t\(.title)")
  ' "$GITHUB_CACHE" 2>/dev/null)"

  # A cache that exists but will not parse. Truncated by a crash mid-write, or
  # written by a jq that failed. Distinct from every other state on the card,
  # because the fix is different: delete the file, do not go and re-auth.
  if [ -z "$stream" ]; then
    printf '󰀨\t%s\tGitHub  ·  cache unreadable\n' "$RED"
    printf '󰋗\t%s\tDelete %s and wait one tick\n' "$FG_DIM" "$GITHUB_CACHE"
    return
  fi

  at=0; checked=0; status=error; login='-'
  orgs_st=error; repos_st=error; prs_st=error
  org_total=0; pr_total=0; detail='-'

  # Several passes over the same string. The metadata has to be complete before
  # the first row is printed - the header carries the verdict for the whole
  # card - and the alternative, buffering the section rows, means either an
  # array per section under bash 3.2 or a temp file. Re-walking forty lines is
  # cheaper than both.
  while IFS=$'\t' read -r kind a b c d rest; do
    case "$kind" in
      META)   at="$a"; checked="$b"; status="$c"; login="$d" ;;
      ST)     orgs_st="$a"; repos_st="$b"; prs_st="$c" ;;
      N)      org_total="$a"; pr_total="$b" ;;
      DETAIL) detail="$a" ;;
    esac
  done <<GHMETA
$stream
GHMETA

  case "$at"        in ''|*[!0-9]*) at=0 ;; esac
  case "$checked"   in ''|*[!0-9]*) checked=0 ;; esac
  case "$org_total" in ''|*[!0-9]*) org_total=0 ;; esac
  case "$pr_total"  in ''|*[!0-9]*) pr_total=0 ;; esac

  # --- row 1: provenance ------------------------------------------------------
  # A whole row for "where these numbers came from and how old they are",
  # because every row under it is only safe to read once this one is. Stated,
  # never implied by an absence.
  age=$(( $(date +%s) - at ))
  [ "$age" -lt 0 ] && age=0   # clock skew, not staleness - see cards/claude.sh
  header="GitHub"
  [ "$login" != '-' ] && header="GitHub  ·  $login"

  if [ "$status" = ok ] && [ "$at" -gt 0 ] && [ "$age" -le "$GITHUB_STALE_AFTER" ]; then
    header_tint="$VIOLET"
    header="$header  ·  $(github_ago_words "$at")"
  elif [ "$status" = ok ]; then
    # The fetch says it worked but the data predates three ticks, so the tick
    # is not running. The lists are still drawn: unlike a usage percentage, a
    # repository name does not decay - the URL still opens the right page - so
    # hiding them would cost the navigation and buy nothing. Only the review
    # count is genuinely time-sensitive, and the word "stale" is what stops it
    # being read as current.
    header_tint="$ORANGE"
    header="$header  ·  $(github_ago_words "$at")  ·  stale"
  else
    case "$status" in
      no-gh|no-token|no-auth|forbidden) header_tint="$RED" ;;
      # tls included: nothing the user can do from this laptop, so it is
      # environmental (yellow) and not broken-by-you (red). Same split as
      # github_paint() in the plugin.
      *)                                header_tint="$YELLOW" ;;
    esac
    header="$header  ·  $(github_why "$status")"
  fi
  printf '󰊤\t%s\t%s\n' "$header_tint" "$(card_text "$header")"

  # --- row 2: the remedy, when there is something to remedy -------------------
  [ "$status" = ok ] || github_remedy "$status" "$detail"

  # --- when there is nothing cached to fall back on ---------------------------
  # A broken fetch with an empty cache would otherwise draw three dividers over
  # three "unavailable" rows, which is five rows of chrome saying what row 1
  # and row 2 already said. The sections earn their space only when they have
  # something in them. With ANY cached content they are drawn in full, however
  # old, because a working link to a repo is worth more than the freshness of
  # the label on it.
  have=0
  case "$stream" in *"$(printf '\nORG\t')"*|"ORG"$'\t'*) have=1 ;; esac
  case "$stream" in *"$(printf '\nREPO\t')"*) have=1 ;; esac
  case "$stream" in *"$(printf '\nPR\t')"*)   have=1 ;; esac
  [ "$login" != '-' ] && have=1
  if [ "$status" != ok ] && [ "$have" -eq 0 ]; then
    return
  fi

  # --- section 1: organisations -----------------------------------------------
  if [ "$org_total" -gt "$GITHUB_ORG_ROWS" ]; then
    github_rule "Organisations · $GITHUB_ORG_ROWS of $org_total"
  else
    github_rule "Organisations"
  fi

  # The personal namespace is first and is not an org. /user/orgs does not
  # return it, so it is synthesised here from the login - and only when the
  # login is known, because a row pointing at github.com/- is worse than no
  # row. A different glyph from the org rows: the two are different kinds of
  # place and the card should not have to explain that in words.
  n=0
  if [ "$login" != '-' ]; then
    printf '󰀉\t%s\t%s  ·  personal\t%s\n' "$BLUE" "$(card_text "$login")" \
           "$(github_action "https://github.com/$login")"
    n=$(( n + 1 ))
  fi

  while IFS=$'\t' read -r kind a rest; do
    [ "$kind" = ORG ] || continue
    [ "$n" -gt "$GITHUB_ORG_ROWS" ] && break
    printf '󰦑\t%s\t%s\t%s\n' "$BLUE" "$(card_text "$a")" \
           "$(github_action "https://github.com/$a")"
    n=$(( n + 1 ))
  done <<GHORGS
$stream
GHORGS

  # Nothing at all in the section, and WHICH of the two reasons it is matters:
  # a failed fetch is a yellow alert naming the reason, an empty answer is a
  # dim statement of fact. Rendering both as blank is the failure this card is
  # built to avoid.
  if [ "$n" -eq 0 ]; then
    if [ "$orgs_st" != ok ]; then
      printf '󰀨\t%s\tOrganisations unavailable  ·  %s\n' "$YELLOW" "$(github_why "$orgs_st")"
    else
      printf '󰋗\t%s\tNo organisations\n' "$FG_DIM"
    fi
  fi

  # --- section 2: repositories ------------------------------------------------
  # The heading names the ordering rather than saying "Top", because "top" does
  # not mean anything on its own and this is configurable - see
  # $SB_GITHUB_REPO_SORT in plugins/github.sh.
  github_rule "Recently pushed"
  n=0
  while IFS=$'\t' read -r kind name url ts a rest; do
    [ "$kind" = REPO ] || continue
    [ "$n" -ge "$GITHUB_REPO_ROWS" ] && break
    case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
    # Truncated HERE and not by card.sh:ellipsize(). The age suffix is the
    # second most useful thing on the row and it is at the right-hand end, so
    # letting a 60-character monorepo name run into the 64-char cap would cut
    # off the very thing that makes the ordering legible. Name first, capped,
    # suffix always survives.
    printf '󰳏\t%s\t%s  ·  %s\t%s\n' "$AQUA" \
           "$(ellipsize "$(card_text "$name")" 46)" "$(github_ago "$ts")" \
           "$(github_action "$url")"
    n=$(( n + 1 ))
  done <<GHREPOS
$stream
GHREPOS
  if [ "$n" -eq 0 ]; then
    if [ "$repos_st" != ok ]; then
      printf '󰀨\t%s\tRepositories unavailable  ·  %s\n' "$YELLOW" "$(github_why "$repos_st")"
    else
      printf '󰋗\t%s\tNo repositories\n' "$FG_DIM"
    fi
  fi

  # --- section 3: review requests ---------------------------------------------
  # The total is the search API total_count, so it is the real number and not
  # the size of the page we asked for - "5 of 23" is exact.
  if [ "$pr_total" -gt "$GITHUB_PR_ROWS" ]; then
    github_rule "Needs your review · $GITHUB_PR_ROWS of $pr_total"
  else
    github_rule "Needs your review"
  fi
  n=0
  while IFS=$'\t' read -r kind name num url ts draft title; do
    [ "$kind" = PR ] || continue
    [ "$n" -ge "$GITHUB_PR_ROWS" ] && break
    case "$ts"  in ''|*[!0-9]*) ts=0 ;; esac
    case "$num" in ''|*[!0-9]*) num=0 ;; esac
    # A draft is dimmed rather than dropped. Being asked to review a draft is
    # still being asked, so hiding it would be lying about the queue - but it
    # is not the thing to open first, and colour is the cheapest way to say so
    # without spending characters on the word "draft".
    tint="$ORANGE"; [ "$draft" = 1 ] && tint="$FG_DIM"
    # The short repo name, not owner/repo. Owner is nearly always one of the
    # names in the section two above, and spending fifteen characters repeating
    # "novemberfiveco/" on every row costs the title the room it needs to be
    # recognisable - and the title is the only field that tells you whether to
    # click.
    #
    # 16 + 1 + 5 + 2 + 38 = 62, against card.sh:MAX_CHARS of 64. Both caps are
    # applied here rather than left to card.sh, because card.sh cuts from the
    # right - so an over-long repo name would eat the title first and leave a
    # row that is all breadcrumb and no subject.
    printf '󰓂\t%s\t%s#%s  %s\t%s\n' "$tint" \
           "$(ellipsize "$(card_text "$name")" 16)" "$num" \
           "$(ellipsize "$(card_text "$title")" 38)" \
           "$(github_action "$url")"
    n=$(( n + 1 ))
  done <<GHPRS
$stream
GHPRS
  if [ "$n" -eq 0 ]; then
    if [ "$prs_st" != ok ]; then
      printf '󰀨\t%s\tReview requests unavailable  ·  %s\n' "$YELLOW" "$(github_why "$prs_st")"
    else
      # Green, and a tick, and it says what it means. This is the one empty
      # section on the card that is GOOD NEWS, and it is also the one most
      # easily confused with a broken fetch - which is exactly why it gets the
      # most distinct treatment of any row here.
      printf '󰄴\t%s\tNothing needs your review\n' "$GREEN"
    fi
  fi

  # There is deliberately no "open github.com" row and no refresh row. The
  # first is what the org rows already are; the second would be a button that
  # takes several seconds to do something invisible, on a card that closes the
  # moment any row is clicked.
}
