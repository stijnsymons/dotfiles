#!/usr/bin/env bash
# herdr session template — recreates the workspace layout captured 2026-08-07.
#
# WHAT IT DOES: rebuilds all 13 spaces (incl. panes/tabs, git worktrees by branch,
# and a resuming `claude -r` in the spaces that had an agent).
#
# RUN IT ON A FRESH SESSION — not your current one, or you'll duplicate every space:
#     herdr --session work            # attach/create a separate named session
#     ~/dotfiles/config/herdr/session-template.sh
#
# Worktrees are opened by branch from the vbrb-0010 repo; the branches must already
# exist (all worktree dirs live on disk and survive reboots — herdr reattaches).
# Claude history is NOT restored (herdr can't) — `-r` resumes the most recent
# session per cwd, which may show claude's resume picker.
set -uo pipefail

command -v herdr >/dev/null || { echo "herdr not found on PATH"; exit 1; }
command -v jq    >/dev/null || { echo "jq is required"; exit 1; }
herdr status server >/dev/null 2>&1 || { echo "herdr server not running"; exit 1; }

VBRB="$HOME/code/vbrb-0010-partner-in-benefits"    # worktree source repo
DRIVE="$HOME/My Drive"                             # personal Google Drive

if [[ "${1:-}" != "--yes" ]]; then
  read -rp "This creates 13 herdr spaces in the CURRENT session. Continue? [y/N] " ans
  [[ "$ans" == [yY]* ]] || { echo "aborted"; exit 0; }
fi

# --- helpers (JSON paths verified against herdr 0.7.5) ------------------------
WS=""; P0=""   # set by create_ws / open_wt: workspace id + its root pane id

create_ws() {  # <cwd> <label>
  local j; j=$(herdr workspace create --cwd "$1" --label "$2" --no-focus)
  WS=$(jq -r '.result.workspace.workspace_id' <<<"$j")
  P0=$(jq -r '.result.root_pane.pane_id'     <<<"$j")
}
open_wt() {    # <branch> <label>  — open a git worktree of $VBRB by branch
  local j; j=$(herdr worktree open --cwd "$VBRB" --branch "$1" --label "$2" --no-focus)
  WS=$(jq -r '.result.workspace.workspace_id' <<<"$j")
  P0=$(jq -r '.result.root_pane.pane_id'     <<<"$j")
}
split_pane() { # <pane> [cwd] [dir]  -> echoes new pane id
  local a=(pane split "$1" --direction "${3:-down}" --no-focus)
  [[ -n "${2:-}" ]] && a+=(--cwd "$2")
  herdr "${a[@]}" | jq -r '.result.pane.pane_id'
}
add_tab() {    # <workspace> <cwd> <label>  -> echoes new tab's root pane id
  herdr tab create --workspace "$1" --cwd "$2" --label "$3" --no-focus | jq -r '.result.root_pane.pane_id'
}
run_claude() { herdr pane run "$1" 'command claude -r --enable-auto-mode'; }   # resume claude in a pane

# --- spaces ------------------------------------------------------------------
# 1. caffeinate
create_ws "$HOME/code/caffeinate" "caffeinate"

# 2. dotfiles (claude)
create_ws "$HOME/dotfiles" "dotfiles";                     run_claude "$P0"

# 3. assistant — claude + a plain shell pane
create_ws "$HOME/code/assistant" "assistant";              run_claude "$P0"
split_pane "$P0" >/dev/null

# 4. Thoughts
create_ws "$DRIVE/Thoughts" "Thoughts"

# 5. skills
create_ws "$HOME/code/skills" "skills"

# 6. vbrb-0010 (main checkout, claude)
create_ws "$VBRB" "vbrb-0010-partner-in-benefits";         run_claude "$P0"

# 7. vbrb-0010-pib-study (claude, deep cwd)
create_ws "$HOME/code/vbrb-0010/vbrb-0010-pib-study/legacy-application" "vbrb-0010-pib-study"
run_claude "$P0"

# 8. vbrb-0001 — tab "project" (plain) + tab "docs" (claude)
create_ws "$HOME/code/vbrb-0001" "vbrb-0001"
herdr tab rename "${WS}:t1" project >/dev/null
dp=$(add_tab "$WS" "$HOME/code/vbrb-0001/vbrb-0001-docs" "docs"); run_claude "$dp"

# 9. identity (detached worktree checkout living in ~/code, plain)
create_ws "$HOME/code/vbrb-0010-partner-in-benefits-identity" "identity"

# 10. feature-eval (worktree; pane sits in docs/eval inside it)
open_wt "feature/eval" "feature-eval"
herdr pane run "$P0" 'cd docs/eval'

# 11. docs-docs-fixes (worktree, claude + a plain shell pane)
open_wt "docs/guarantee-type-add-life" "docs-docs-fixes";  run_claude "$P0"
split_pane "$P0" >/dev/null

# 12. docs-time-sink (worktree)
open_wt "docs/time-sink" "docs-time-sink"

# 13. docs-dbt-pipeline (worktree)
open_wt "feature/dbt-pipeline" "docs-dbt-pipeline"

echo "✓ recreated 13 spaces"
