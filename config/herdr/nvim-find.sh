#!/bin/sh
# Open a vertical split and drop straight into neovim's file picker.
#
# Bound from config.toml as type = "shell" rather than type = "pane": a "pane"
# command opens herdr's own temporary pane and gives no control over the split
# direction, and "vertical" is the whole point here. So we drive the two CLI
# calls ourselves - split, then run - which also lets the new pane inherit the
# source pane's cwd, so the picker opens in the project you were already in.
#
# The picker is snacks.nvim (LazyVim's default since v14). Telescope is NOT
# installed here, despite the commented reference in lua/plugins/example.lua.
# vim.schedule defers the call until the UI is up; calling it straight from -c
# can race with startup.
#
# Usage: nvim-find.sh [pane-id]     (no argument = the focused pane)

set -e

# herdr runs `type = "shell"` bindings DETACHED, with a bare login-less
# environment - PATH is roughly /usr/bin:/bin, so `herdr` and `jq` in
# /opt/homebrew/bin are simply not found and the whole thing fails silently
# (stderr goes nowhere from a detached process). Both prefixes so this works on
# Apple Silicon and Intel.
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

# Detached means no stderr to look at, so leave a breadcrumb when it fails.
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/herdr/nvim-find.log"
mkdir -p "$(dirname "$LOG")"
fail() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; exit 1; }

# Resolve the pane to split. NOT `--current`: that flag reads HERDR_PANE_ID
# from the environment, and a detached `type = "shell"` binding does not run
# inside a pane, so it has none ("--current requires HERDR_PANE_ID"). `herdr
# pane current` answers the same question server-side, from the focused pane,
# and works with no environment at all.
if [ -n "${1:-}" ]; then
  TARGET="$1"
else
  TARGET="$(herdr pane current 2>/dev/null | jq -r '.result.pane.pane_id // empty')"
  [ -n "$TARGET" ] || fail "no focused pane to split"
fi

PANE="$(herdr pane split "$TARGET" --direction right --focus 2>/dev/null \
        | jq -r '.result.pane.pane_id // empty')"

[ -n "$PANE" ] || fail "could not create a split (herdr on PATH? $(command -v herdr))"

# Give the new pane's shell a moment to come up. `pane run` types into it, and
# typing at a shell that is still initialising loses the first character(s) -
# which showed up as a mangled "dnvim ...".
sleep 1

# Absolute: the new pane has its own cwd, so a relative path would not
# resolve there.
HERE="$(cd "$(dirname "$0")" && pwd)"

herdr pane run "$PANE" "$HERE/nvim-files.sh"
