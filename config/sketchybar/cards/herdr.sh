# shellcheck shell=bash
# The flock in detail, grouped the way herdr itself is organised: one block per
# WORKSPACE, not one flat row per agent. A workspace is the unit you actually
# switch to, so "vbrb-0001 has two agents and one of them wants you" is the
# sentence the card should say - the old flat list said it nine times over and
# left you to reassemble it.
#
# Verbatim from a real flock, at HERDR_ROW_W=58:
#
#   󰳆 Herdr  ·  1 working                9 agents · 8 workspaces
#     ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
#   󰝥 dotfiles                                         1 working
#   󰜎   Review omniwm keybindings and Karabiner setup    working
#   󰝥 vbrb-0001                                           2 idle
#   󰉋   vbrb-0001 · vbrb-0001-docs
#   󰒲   Plan healthcare 2.0 feature flagging architecture   idle
#   󰒲   Draft email about BO employee impersonation featu…  idle
#   󰝦 No agent  ·  Thoughts · skills · vbrb-0010-…  6 workspaces
#
# Clicking an agent row focuses that agent - preserved verbatim from the flat
# card this replaces, muscle memory and all. Clicking a group row focuses that
# workspace, which is new and is the same gesture one level up.
#
# WHAT THIS MEDIUM CANNOT DO, and what was done instead. A popup row is one
# sketchybar item with one icon and one label in one monospace font, so:
#
#   * There is no right-alignment. The right-hand column is space padding to a
#     fixed pitch (HERDR_ROW_W), computed in jq because jq's `length` counts
#     CODEPOINTS - bash's ${#} and macOS awk's length() both count bytes, and a
#     title with a single "…" or an accented character in it would shear the
#     whole column by two cells. Every row is padded to the same width, which
#     also pins the popup's width so it does not resize between renders.
#
#   * There is no font weight and NO ROW TEXT COLOUR. card.sh sets icon.color
#     per row and nothing else; label.color comes from sketchybarrc's --default
#     and is $FG for every row of every card. So the third field of a row tints
#     the GLYPH only, and all the state colour in this card lives in the glyph.
#     The reference's dimmed repo sub-line and dimmed stopped group are the two
#     things that cannot be reproduced. The colours below are nonetheless the
#     ones the rows WANT - if card.sh ever grows a label.color="$COLOR" this
#     card gets its hierarchy with no edit here.
#
#   * There is no indent guide. Sub-rows are two leading spaces, and those
#     survive because card.sh reads rows with IFS=$'\t': a space is then not an
#     IFS character at all, so `read` does not strip it.
#
#   * Every glyph must come from the same width class or the label column shears
#     row to row - sketchybar lays the label out after the icon, so a narrower
#     icon slides that row's text left. Measured in HackNerdFont-Bold (the icon
#     font popup rows inherit from --default): U+0020 and every U+F0xxx Material
#     Design glyph used here all advance 1233/2048 em. Mixing in a non-Nerd
#     glyph, or an emoji, would break that and is why the "empty" marker is
#     md-circle_outline rather than a "-".
#
# ┈ is U+2508, Box Drawing, and it was checked rather than assumed: claude.sh
# records a box-drawing glyph that rendered as tofu, so the cmap of the actual
# label font (FiraMonoNerdFont-Regular.otf) was read - U+2508 is present at the
# 600/1000 monospace advance, as are ·, … and the Block Elements.
#
# ACTIONS. card.sh clears any action containing ; | & $ ` \ < > ( ) or a tab,
# silently, so what jq emits as a row's fourth field is an ID and never a
# command - the command is assembled from it down in the render loop, after the
# id has been whitelisted with no space in the class. Doing it the other way
# round does not work and looks like it does: see the note on emit().
#
# SPEED. 38ms for a nine-agent flock against the live socket, 19ms of that the
# socket call and 19ms one jq, measured over 20 runs. The card this replaces
# took 248ms for the same flock - it ran card_text (a printf|tr pipeline) twice
# per row plus a tr per pane id, so ~27 processes on a click path where the old
# comment above claimed the cost was the socket. It was not. This one spawns
# two, and none per row.
#
# HERDR_SNAPSHOT_JSON / HERDR_AGENT_JSON (env) are the fixture hooks. Both
# shapes are accepted by the same jq: `herdr api snapshot` wraps its payload in
# .result.snapshot and carries workspaces, `herdr agent list` puts agents at
# .result and carries none. The agent-list shape still renders - it just falls
# back to "Workspace w1" for a group name, because there is nowhere else to get
# a label from and inventing one is not on the table.

# ellipsize() in plugins/fit.sh measures with ${#text} and cuts with
# ${text:0:n}, both of which count BYTES unless the shell is in a UTF-8 locale -
# and under launchd it is not (`launchctl getenv LANG` is empty). This card's
# rows are built to HERDR_ROW_W and the "…" it appends is three bytes, so a row
# that is 58 characters would measure 60+ and get cut by card.sh's MAX_CHARS on
# top of the truncation jq already did - taking the right-hand status column
# off the end of exactly the rows that needed it most. Same fix, same reason and
# same wording as cards/claude.sh; see the long note there.
export LC_ALL=en_US.UTF-8

# The column pitch, in characters. Deliberately under card.sh's MAX_CHARS of 64
# so ellipsize() is a no-op on every row this card emits - the truncation is
# done here, where the right-hand column can be protected, rather than there,
# where it cannot. 58 leaves 45 characters for an agent's title once the two
# spaces of indent and the widest status word ("needs you") are taken out, which
# is enough for the median Claude Code tab title.
HERDR_ROW_W=58

card_rows() {
  local max snap raw line kind text id action glyph color
  local n cut i j da dg de
  local sep=$'\037'

  # The budget is read rather than assumed, and it needs to be a large one.
  # A group costs one row plus one per agent plus, when the workspace label does
  # not already name every directory in it, one more: the flock on this machine
  # is 9 agents in 8 workspaces and renders as 24 rows. card_rows_max wants 28
  # for that with headroom - at the default 8 this card shows two workspaces.
  #
  # Overflow is ANNOUNCED rather than absorbed. card.sh truncates with a bare
  # `break`, which is exactly the silent tail-loss check.sh is written to catch,
  # so this function cuts to its own budget and spends the last row saying what
  # it cut. See the tail.
  max="$(card_rows_max herdr)"
  case "$max" in ''|*[!0-9]*) max=8 ;; esac

  # One socket round trip, not two: `herdr api snapshot` returns agents AND
  # workspaces in a single reply, and the call is ~45ms on the CLICK path where
  # it is felt. Asking `agent list` and `workspace list` separately would double
  # that for data that has to be consistent with itself anyway.
  snap="${HERDR_SNAPSHOT_JSON:-${HERDR_AGENT_JSON:-$(herdr api snapshot 2>/dev/null)}}"
  if [ -z "$snap" ]; then
    printf '󰳆\t%s\therdr is not running\t\n' "$FG_DIM"
    return
  fi

  # The whole layout in one jq. Not tidiness: jq is the only tool in this
  # pipeline that measures strings in codepoints, and every space count below
  # depends on that (see the note above about bash and awk counting bytes).
  # It is also one process instead of a loop of them on the click path.
  raw="$(printf '%s' "$snap" | jq -r --arg US "$sep" --argjson W "$HERDR_ROW_W" '
    def sp($n): if $n > 0 then (" " * $n) else "" end;
    # Truncate to $n CELLS, ellipsis included in the budget. Returns "" rather
    # than a bare "…" when there is no room at all: a lone ellipsis in a column
    # reads as a rendering fault, an empty column reads as "nothing to say".
    def clip($n): if $n < 2 then ""
                  elif (length > $n) then (.[0:($n - 1)] + "…")
                  else . end;
    # Control characters are stripped, not escaped. A tab in a terminal title
    # would shift every later field of the row (card.sh reads with IFS=$"\t"),
    # and the US separator this jq joins on would do the same one level up.
    #
    # explode/implode, NOT a gsub over a character class, and this cost an hour:
    # jq regexes are Oniguruma, which does not accept \uXXXX - it takes \x{...}.
    # A class written as "[\\u0000-\\u001f\\u007f]" does not fail, it parses as
    # the literal characters u,0,1,f,7 plus the range 0-u, i.e. every digit,
    # every capital and a-u. Every title on the card came out as the four
    # letters that happened to fall outside it ("v w w y") and every workspace
    # label came out empty, which then fell back to "Workspace 1". Working on
    # codepoints has no escaping to get wrong.
    def tidy: (. // "" | tostring)
              | explode | map(if . < 32 or . == 127 then 32 else . end) | implode
              | gsub(" +"; " ")
              | sub("^ +"; "") | sub(" +$"; "");
    # Most urgent first, everywhere: groups, agents within a group, and the
    # header count. The old flat card ordered this way and the reason holds -
    # the reason the sheep in the bar turned red must be the top row, not the
    # row you scroll to. Unknown sorts last because it is the absence of a
    # state rather than a state.
    def rank: {"blocked":0,"working":1,"done":2,"idle":3}[.] // 4;
    # herdr says "blocked"; the card says "needs you". The bar item and check.sh
    # keep the herdr vocabulary because they are counting states - this is
    # prose, and "blocked" reads as "something is wrong with it" rather than
    # "it is waiting for you to answer", which is what it means.
    def word: {"blocked":"needs you","working":"working",
               "done":"done","idle":"idle"}[.] // "unknown";
    # The fake right-alignment. Pads to exactly $W so every row is the same
    # width and the popup cannot resize between renders. The LEFT side is what
    # gets clipped when the two do not fit - the status word on the right is
    # short, fixed and the whole point of the column.
    # Two spaces of gutter, not one: with one, a clipped left column ends in "…"
    # immediately followed by the status word and the two read as a single run
    # of text ("...Keda an… idle"). Two is the narrowest gap that still parses
    # as a column boundary at 12pt.
    def lr($l; $r):
      ($r | clip($W - 4)) as $R
      | ($l | clip($W - ($R | length) - 2)) as $L
      | $L + sp($W - ($L | length) - ($R | length)) + $R;
    # The fourth field is an ID, never a command. The command is assembled in
    # bash from the row kind, because an id is the only part of it that comes
    # from herdr and therefore the only part that needs washing - and washing a
    # whole command line cannot work: the whitelist has to keep spaces for
    # "herdr agent focus " to survive, and a pane_id of "w2:p1; rm -rf /" then
    # washes to "w2:p1 rm -rf " and is passed to herdr as three extra arguments,
    # with card.sh none the wiser because no metacharacter is left in it.
    def emit($k; $t; $id): [$k, $t, $id] | join($US);

    (.result.snapshot // .result // .) as $s
    # workspace_id is DERIVED when it is absent rather than required, and that
    # is not defensiveness: check.sh drives this card with a fixture that has
    # only pane_id, and requiring the field made every fixture agent vanish -
    # the card rendered "no agents" over a flock of four and looked correct.
    # A pane_id is "<workspace>:<pane>" in every reply herdr sends, so the
    # prefix is the workspace whether or not the field came along with it.
    | [ ($s.agents // [])[]
        | select(.pane_id != null)
        | .workspace_id = (.workspace_id // (.pane_id | split(":")[0])) ] as $agents
    | ($s.workspaces // []) as $wss
    | ($wss | map({key: .workspace_id, value: .}) | from_entries) as $wmap

    # One record per workspace that has at least one agent.
    | ( $agents
        | group_by(.workspace_id)
        | map( sort_by(.agent_status | rank) as $mem
             | $mem[0].workspace_id as $wid
             | ($wmap[$wid] // {}) as $w
             | { wid: $wid,
                 name: ( ($w.label | tidy) as $l
                         | if $l != "" then $l
                           elif ($w.number != null) then "Workspace \($w.number)"
                           else "Workspace \($wid)" end ),
                 num: ($w.number // 9999),
                 st: $mem[0].agent_status,
                 mem: $mem,
                 # The repo sub-line from the reference. Built from the cwd of
                 # each agent plus the worktree repo of the workspace, because
                 # a linked worktree
                 # is labelled with the BRANCH directory ("docs-identity") and
                 # the repo it belongs to appears nowhere else on the card -
                 # which is exactly the thing that tells four similarly named
                 # worktree workspaces apart.
                 repos: ( ( [ $mem[] | (.cwd // "") | split("/") | last
                              | select(. != null and . != "") ]
                            + [ $w.worktree.repo_name // empty ] )
                          | map(tidy) | unique ) } )
        | sort_by([(.st | rank), .num]) ) as $groups

    # Workspaces herdr knows about that have no agent in them at all. The
    # reference gives each one a "stopped / nothing saved" block; they are
    # collapsed to a single row here because there are routinely six of them on
    # this machine and six near-identical rows would cost more of the budget
    # than the whole rest of the card. Named rather than merely counted, so the
    # row still answers "which ones".
    | [ $wss[] | select([.workspace_id] - [$agents[].workspace_id] | length > 0) ] as $bare

    | ($agents | length) as $nA
    | ($groups | length) as $nG

    # Everything below is one comma-joined stream of rows, and it has to be
    # parenthesised: `EXPR as $x | A, B` binds the whole comma list to the
    # binding, but `EXPR as $x , A` is a syntax error, and jq reports it as an
    # unhelpful "syntax error, unexpected ','" fifty lines from here.
    | (
    # --- header ---------------------------------------------------------------
    # Left says what state the flock is in, right says how big it is. The left
    # clause names the single most urgent state present rather than all five:
    # the bar item already carries the full five-digit breakdown, and a header
    # that spells out "1 needs you · 2 working · 3 done · 4 idle" leaves no room
    # for the size on the right.
      ( ( if $nA == 0 then "Herdr  ·  no agents"
          else ([$agents[].agent_status] | sort_by(rank) | .[0]) as $top
               | ($agents | map(select(.agent_status == $top)) | length) as $c
               | "Herdr  ·  \($c) \($top | word)"
          end ) as $L
        | ( if $nA == 0 then "\($wss | length) workspaces"
            else "\($nA) agent\(if $nA == 1 then "" else "s" end) · \($nG) workspace\(if $nG == 1 then "" else "s" end)"
            end ) as $R
        | emit("header"; lr($L; $R); "") )
    , emit("rule"; ("┈" * $W); "")

    # --- one block per workspace ----------------------------------------------
    , ( $groups[]
        | . as $g
        | ($g.mem | length) as $n
        | ($g.mem | map(select(.agent_status == $g.st)) | length) as $c
        | (
            emit("g." + $g.st;
                 lr($g.name;
                    if $c == $n then "\($n) \($g.st | word)"
                    else "\($c) \($g.st | word) · \($n) agents" end);
                 $g.wid)
        # The repo line is emitted only when it says something the group name
        # does not. Most workspaces here are labelled with their repo, so an
        # unconditional sub-line would be a row of pure restatement per group -
        # and rows are the scarcest thing this card has.
          , ( select(($g.repos | length) > 0 and $g.repos != [$g.name])
              | emit("repo"; ("  " + ($g.repos | join(" · ")) | clip($W)); "") )
          , ( $g.mem[]
              | emit("a." + .agent_status;
                     lr("  " + ( (.terminal_title_stripped // .terminal_title) | tidy
                                 | if . == "" then "(untitled)" else . end );
                        (.agent_status | word));
                     .pane_id) )
          ) )

    # --- the workspaces with nothing in them ----------------------------------
    , ( select(($bare | length) > 0)
        | emit("empty";
               # Unlabelled workspaces are named, not skipped. Dropping them
               # left the row listing two names beside a count of three, which
               # reads as a bug in the count rather than as a missing label.
               lr("No agent  ·  " + ([$bare[]
                                      | (.label | tidy) as $l
                                      | if $l != "" then $l
                                        elif .number != null then "Workspace \(.number)"
                                        else "Workspace \(.workspace_id)" end]
                                     | join(" · "));
                  "\($bare | length) workspace\(if ($bare | length) == 1 then "" else "s" end)");
               "") )
    )
  ' 2>/dev/null)"

  # A reply that arrived but would not parse is a different fact from no reply
  # at all, and it gets its own words. Guessing "not running" here would send
  # you looking at a server that is up.
  if [ -z "$raw" ]; then
    printf '󰳆\t%s\therdr sent a reply this card could not read\t\n' "$ORANGE"
    return
  fi

  # Buffered rather than streamed straight to stdout, because the overflow
  # notice at the bottom has to know what it is standing in for, and that is
  # only knowable once every row exists. An array, filled a line at a time:
  # launchd hands this config bash 3.2, which has no mapfile.
  local rows=()
  while IFS= read -r line; do
    [ -n "$line" ] && rows+=("$line")
  done <<HERDRROWS
$raw
HERDRROWS
  n=${#rows[@]}
  [ "$n" -gt 0 ] || { printf '󰳆\t%s\therdr is not running\t\n' "$FG_DIM"; return; }

  cut=$n
  if [ "$n" -gt "$max" ]; then
    # Keep one row back for the notice, then walk the cut UP the list until the
    # first dropped row starts a group. Cutting anywhere else leaves a group
    # header, or a header and a repo line, standing over the agents that were
    # supposed to be underneath them - a block that says "3 agents" above two
    # rows is worse than a block that is honestly absent.
    cut=$(( max - 1 ))
    while [ "$cut" -gt 1 ]; do
      case "${rows[$cut]}" in g.*|empty*) break ;; esac
      cut=$(( cut - 1 ))
    done
  fi

  i=0
  while [ "$i" -lt "$cut" ]; do
    IFS="$sep" read -r kind text id <<HERDRROW
${rows[$i]}
HERDRROW
    i=$(( i + 1 ))
    [ -n "$text" ] || continue
    case "$kind" in
      header)    glyph='󰳆'; color="$VIOLET" ;;
      # A space, not an empty field. A tab is IFS whitespace, so an empty first
      # field does not read back as empty - it shifts the colour into the glyph
      # and the text into the colour, and card.sh then drops the row for having
      # no text. Costs nothing: U+0020 in the icon font advances 1233 like every
      # Material Design glyph here, so the label column does not move.
      rule)      glyph=' '; color="$SEPARATOR" ;;
      repo)      glyph='󰉋'; color="$FG_DIM" ;;
      empty)     glyph='󰝦'; color="$FG_DIM" ;;
      g.blocked) glyph='󰝥'; color="$RED" ;;
      g.working) glyph='󰝥'; color="$BLUE" ;;
      g.done)    glyph='󰝥'; color="$GREEN" ;;
      g.idle)    glyph='󰝥'; color="$FG_DIM" ;;
      g.*)       glyph='󰝥'; color="$ORANGE" ;;
      a.blocked) glyph='󰀦'; color="$RED" ;;
      a.working) glyph='󰜎'; color="$BLUE" ;;
      a.done)    glyph='󰄬'; color="$GREEN" ;;
      a.idle)    glyph='󰒲'; color="$FG_DIM" ;;
      a.*)       glyph='󰋗'; color="$ORANGE" ;;
      *)         glyph=' '; color="$FG" ;;
    esac
    # The id lands in a click_script, so it gets the eid treatment: whitelist
    # the characters a real one is made of and let everything else fall out.
    # NO SPACE in the whitelist - that is the whole reason the command is built
    # here rather than in jq. A real pane_id is also not w<digits>: herdr
    # numbers workspaces in base 36, and this machine is running w1, wB, wF, wQ,
    # wS and wV, so the class has to be alphanumeric or every double-digit
    # workspace loses its click.
    case "$id" in
      *[!A-Za-z0-9:_-]*) id="$(printf '%s' "$id" | tr -cd 'A-Za-z0-9:_-')" ;;
    esac
    action=''
    if [ -n "$id" ]; then
      case "$kind" in
        # Preserved verbatim from the flat card this replaces - a row click has
        # always focused its agent and the muscle memory is worth more than the
        # redesign. The group row focusing its workspace is new, and is the same
        # gesture one level up.
        a.*) action="herdr agent focus $id" ;;
        g.*) action="herdr workspace focus $id" ;;
      esac
    fi
    printf '%s\t%s\t%s\t%s\n' "$glyph" "$color" "$text" "$action"
  done

  # The overflow notice. card.sh truncates with a bare `break`, so without this
  # row the tail of the flock would simply not be on the card and nothing would
  # say so - the exact silent-truncation failure check.sh is written to catch.
  # Orange, because a card that cannot show you everything is a state worth
  # noticing rather than a footnote.
  if [ "$cut" -lt "$n" ]; then
    # Counted by kind rather than as a row total, because a row is not a unit
    # anyone cares about: three dropped rows can be one workspace. The "empty"
    # row is counted separately and NOT as one workspace - it stands for six of
    # them on this machine, and folding it into $dg would under-report by five.
    da=0; dg=0; de=0; j=$cut
    while [ "$j" -lt "$n" ]; do
      case "${rows[$j]}" in
        a.*)     da=$(( da + 1 )) ;;
        g.*)     dg=$(( dg + 1 )) ;;
        empty*)  de=1 ;;
      esac
      j=$(( j + 1 ))
    done
    # Deliberately ASCII apart from the leading indent: this string is the one
    # row on the card whose width is computed in bash rather than jq, and ${#}
    # counts bytes. Keeping it to characters that are one byte each means the
    # 58-column budget cannot be overrun by a multibyte separator.
    local sa='s' sg='s'
    [ "$da" -eq 1 ] && sa=''
    [ "$dg" -eq 1 ] && sg=''
    if [ "$da" -gt 0 ] || [ "$dg" -gt 0 ]; then
      if [ "$de" -eq 1 ]; then
        text="$(printf '  +%d agent%s, %d workspace%s and the empty ones hidden' \
                       "$da" "$sa" "$dg" "$sg")"
      else
        text="$(printf '  +%d agent%s in %d more workspace%s are hidden' \
                       "$da" "$sa" "$dg" "$sg")"
      fi
    else
      text='  The workspaces with no agent are hidden'
    fi
    printf '󰇘\t%s\t%s\t\n' "$ORANGE" "$text"
  fi
}
