#!/usr/bin/env bash
# herdr session template — recreates the workspace layout captured 2026-07-04.
#
# WHAT IT DOES: rebuilds all 12 spaces (incl. panes/tabs, git worktrees by branch,
# and a resuming `claude -r` in the spaces that had an agent).
#
# RUN IT ON A FRESH SESSION — not your current one, or you'll duplicate every space:
#     herdr --session work            # attach/create a separate named session
#     ~/dotfiles/config/herdr/session-template.sh
#
# Worktrees are opened by branch from the vbrb-0010 repo; the branches must already
# exist. Claude history is NOT restored (herdr can't) — `-r` resumes the most recent
# session per cwd, which may show claude's resume picker.
set -uo pipefail

command -v herdr >/dev/null || { echo "herdr not found on PATH"; exit 1; }
command -v jq    >/dev/null || { echo "jq is required"; exit 1; }
herdr status server >/dev/null 2>&1 || { echo "herdr server not running"; exit 1; }

VBRB="$HOME/code/vbrb-0010-partner-in-benefits"                                  # worktree source repo
DRIVE="$HOME/Library/CloudStorage/GoogleDrive-ssymons@gmail.com/My Drive"        # personal Google Drive

if [[ "${1:-}" != "--yes" ]]; then
  read -rp "This creates 12 herdr spaces in the CURRENT session. Continue? [y/N] " ans
  [[ "$ans" == [yY]* ]] || { echo "aborted"; exit 0; }
fi

# --- helpers (JSON paths verified against herdr 0.7.1) ------------------------
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
# 1. dotfiles (claude)
create_ws "$HOME/dotfiles" "dotfiles";                     run_claude "$P0"

# 2. xpeng (Google Drive)
create_ws "$DRIVE/xpeng" "xpeng"

# 3. Thoughts — 3 stacked panes, claude in each
create_ws "$DRIVE/Thoughts" "Thoughts";                    run_claude "$P0"
p=$(split_pane "$P0" "$DRIVE/_blended");                   run_claude "$p"
p=$(split_pane "$p"  "$DRIVE/_blended/_boekhouding/_2026/2026.Q2"); run_claude "$p"

# 4. skills
create_ws "$HOME/code/skills" "skills"

# 5. vbrb-0010 (main checkout)
create_ws "$VBRB" "vbrb-0010-partner-in-benefits"

# 6. guarantee-mapping (worktree)
open_wt "feature/docs-guarantee-mapping" "vbrb-0010-partner-in-benefits-guarantee-mapping"

# 7. vbrb-0001 — tab "project" (claude) + tab "docs" (claude)
create_ws "$HOME/code/vbrb-0001" "vbrb-0001"
herdr tab rename "${WS}:t1" project >/dev/null;            run_claude "$P0"
dp=$(add_tab "$WS" "$HOME/code/vbrb-0001/vbrb-0001-docs" "docs"); run_claude "$dp"

# 8. customerio (worktree) — claude + a plain shell pane
open_wt "feature/cep-vendor-selection" "vbrb-0010-partner-in-benefits-customerio"; run_claude "$P0"
split_pane "$P0" >/dev/null

# 9. identity (worktree, claude)
open_wt "feature/identity-conflict" "vbrb-0010-partner-in-benefits-identity"; run_claude "$P0"

# 10. waarborgbestanden (worktree, claude)
open_wt "feature/docs-waarborgbestanden" "feature-docs-waarborgbestanden"; run_claude "$P0"

# 11. caffeinate
create_ws "$HOME/code/caffeinate" "caffeinate"

# 12. docs-blob-storage (worktree, claude)
open_wt "feature/docs-blob-storage" "docs-blob-storage"; run_claude "$P0"

echo "✓ recreated 12 spaces"
