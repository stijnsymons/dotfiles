#!/bin/sh
# Put one value on the clipboard, for a card row's click action.
#
#   copy.sh <text>
#
# A HELPER RATHER THAN AN INLINE PIPE, and that is the whole reason this file
# exists. card.sh sanitises every action before handing it to sh and clears any
# that contains ; | & $ ` \ < > ( ) or a tab - so the obvious
# `printf '%s' 1.2.3.4 | pbcopy` written straight into a row would be dropped on
# the pipe, and the row would silently lose its click and just close the card.
# A path plus a quoted argument is exactly the shape that survives that filter;
# see the case statement in plugins/card.sh.
#
# The caller expands $CONFIG_DIR itself, so the action string carries a literal
# path and no dollar sign - another character the sanitiser rejects.
set -u

# Card clicks reach here through sketchybar's shell, which inherits the bar's
# minimal PATH. pbcopy is in /usr/bin and would resolve today, but the bar has
# already been bitten once by an empty PATH (see bin/focus-or-open.sh), and a
# clipboard action that fails does so invisibly - there is nothing on screen to
# show it did not take.
PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
export PATH

[ "$#" -ge 1 ] || { printf 'usage: copy.sh <text>\n' >&2; exit 2; }

# printf, not echo: an address is copied to be pasted somewhere that cares, and
# a trailing newline is a real difference in a config file or a terminal.
printf '%s' "$1" | pbcopy
