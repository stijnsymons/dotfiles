#!/bin/sh
# Follow the macOS appearance and keep Claude Code's theme in step with it.
#
# Ghostty, herdr, yazi and vim all follow the system (or the terminal they are
# in) by themselves -- see config/ghostty/config, config/herdr/config.toml,
# config/yazi/theme.toml and vimrc. Claude Code is the only one that cannot,
# so keeping it in sync is all this agent does.
#
# Edge-triggered, like audio-autoswitch.sh: it writes only on an actual
# light<->dark transition, so a theme you pick by hand survives until the
# system appearance next changes.
#
# Driven by com.local.ThemeAutoSwitch.plist (polls every 10 minutes).

SETTINGS="$HOME/.claude/settings.json"
STATE="/tmp/.theme-autoswitch.$(id -u)"   # /tmp is cleared at boot -> fresh state

command -v jq >/dev/null 2>&1 || exit 0
[ -f "$SETTINGS" ] || exit 0

if defaults read -g AppleInterfaceStyle 2>/dev/null | grep -qi dark; then
  mode=dark
else
  mode=light
fi

# only act on the transition
if [ -f "$STATE" ] && [ "`cat "$STATE" 2>/dev/null`" = "$mode" ]; then
  exit 0
fi
printf '%s' "$mode" > "$STATE"

current="`jq -r '.theme // \"light\"' "$SETTINGS"`"

# preserve whichever variant is in use: light-daltonized <-> dark-daltonized,
# light-ansi <-> dark-ansi, and so on.
suffix="${current#light}"
suffix="${suffix#dark}"
want="$mode$suffix"

[ "$current" = "$want" ] && exit 0

# resolve a symlink so we rewrite the real file rather than replacing the link
target="$SETTINGS"
if [ -L "$target" ]; then
  link="`readlink "$target"`"
  case "$link" in
    /*) target="$link" ;;
    *)  target="`dirname "$SETTINGS"`/$link" ;;
  esac
fi

# atomic, and 0600 because settings.json holds more than just the theme
tmp="`mktemp "$target.XXXXXX"`" || exit 0
if jq --arg t "$want" '.theme = $t' "$target" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
  chmod 600 "$tmp"
  mv "$tmp" "$target"
else
  rm -f "$tmp"
fi
