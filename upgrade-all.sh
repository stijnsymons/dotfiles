#!/bin/zsh
#
# Upgrade brew, global npm packages, and N5 tool repos.
# Invalidates MOTD caches so the next shell shows fresh counts.
#

YELLOW=$'\033[1;33m'
GREEN=$'\033[1;32m'
RED=$'\033[1;31m'
DIM=$'\033[2m'
RESET=$'\033[0m'

section() { printf "\n${YELLOW}▸ %s${RESET}\n" "$1"; }
warn()    { printf "${RED}✗${RESET} %s\n" "$1"; }

section "Homebrew"
brew update

# herdr upgrades can break live sessions (client/server compat) — never
# upgrade it silently; ask, and hold it back via a temporary pin on "no".
if brew outdated --quiet | grep -qx herdr; then
  printf "${YELLOW}⚠ %s — upgrading may break running herdr sessions${RESET}\n" \
    "$(brew outdated --verbose | grep '^herdr')"
  if read -q "REPLY?Upgrade herdr too? [y/N] "; then
    printf "\n"
    brew upgrade
  else
    printf "\n"
    brew pin herdr >/dev/null
    brew upgrade
    brew unpin herdr >/dev/null
    printf "${DIM}herdr held back — run 'brew upgrade herdr' when your sessions can take a restart${RESET}\n"
  fi
else
  brew upgrade
fi
brew cleanup

# First exec of a freshly-written binary blocks ~1-3s while Aikido/macOS
# scan+verify it; pre-warm the runtimes starship probes so that tax is paid
# here and not at the next shell prompt (starship WARN: command timed out).
section "warm first-exec caches"
for bin in node deno python3 go rustc; do
  if command -v "$bin" >/dev/null; then
    { "$bin" --version >/dev/null 2>&1 || "$bin" version >/dev/null 2>&1; } &
  fi
done
wait

section "npm (global)"
npm update -g

section "N5 tools"
for repo in ~/code/brain ~/code/skills ~/code/claude-statusline ~/code/superpowers ~/code/fzf-git.sh; do
  if [[ -d "$repo/.git" ]]; then
    printf "${DIM}— %s${RESET}\n" "$repo"
    git -C "$repo" pull --ff-only || warn "pull failed in $repo"
  else
    warn "not a git repo: $repo"
  fi
done

# Invalidate MOTD caches so the next shell startup shows fresh counts
rm -f ~/.cache/dotfiles/brew ~/.cache/dotfiles/npm ~/.cache/dotfiles/n5

printf "\n${GREEN}✓ all done${RESET}\n"
