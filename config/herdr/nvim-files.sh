#!/bin/sh
# Launched by nvim-find.sh inside the freshly split herdr pane.
#
# This exists as a separate file for one reason: `herdr pane run` does not exec
# its argv, it re-joins it into a single line and TYPES it into the pane's
# shell. Any quoting we pass is lost on the way, so
#   nvim -c 'lua vim.schedule(function() Snacks.picker.files() end)'
# arrives unquoted and zsh dies with "parse error near `end'". Keeping the
# payload in a file means the line herdr types is a bare path with no quotes,
# parens or spaces to survive.
exec nvim -c 'lua vim.schedule(function() Snacks.picker.files() end)'
