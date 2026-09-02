# shellcheck shell=bash
# The flock in detail, one row per agent: state glyph in the state's colour,
# the tab title, and the directory it works in. Clicking a row focuses that
# agent in herdr. Rows are ordered most-urgent first (blocked, working, done,
# idle, unknown) so the reason the sheep turned red is always the top row.
#
# HERDR_AGENT_JSON (env) is the same fixture hook plugins/herdr.sh has.
card_rows() {
  local list sep pane status title cwd glyph color
  list="${HERDR_AGENT_JSON:-$(herdr agent list 2>/dev/null)}"
  [ -n "$list" ] || { printf '󰳆\t%s\therdr is not running\n' "$FG_DIM"; return; }

  # US-separated for the same reason the meeting card is: a tab is IFS
  # whitespace, so read would collapse an empty field and shift the title into
  # the wrong column. Titles are card_text'd on top of that.
  sep=$'\037'
  while IFS="$sep" read -r pane status title cwd; do
    [ -n "$pane" ] || continue
    # The pane id lands in a click_script, so it gets the eid treatment:
    # whitelist the characters a real one ("w1:p1") is made of.
    pane="$(printf '%s' "$pane" | tr -cd 'A-Za-z0-9:_-')"
    case "$status" in
      blocked) glyph='󰀦' color="$RED" ;;
      working) glyph='󰜎' color="$BLUE" ;;
      done)    glyph='󰄬' color="$GREEN" ;;
      idle)    glyph='󰒲' color="$FG_DIM" ;;
      *)       glyph='󰋗' color="$ORANGE" ;;
    esac
    printf '%s\t%s\t%s  ·  %s\t%s\n' "$glyph" "$color" \
      "$(card_text "$title")" "$(card_text "${cwd##*/}")" \
      "herdr agent focus $pane"
  done <<<"$(printf '%s' "$list" | jq -r --arg sep "$sep" '
      .result.agents // []
      | sort_by(.agent_status
                | if . == "blocked" then 0 elif . == "working" then 1
                  elif . == "done" then 2 elif . == "idle" then 3 else 4 end)[]
      | [.pane_id,
         .agent_status,
         ((.terminal_title_stripped // "(untitled)") | gsub("\\s+"; " ")),
         (.cwd // "")] | join($sep)' 2>/dev/null)"
}
