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
brew update && brew upgrade && brew cleanup

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
