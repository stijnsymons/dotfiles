# Dotfiles

## Structure

- `zshrc` — shell config (sourced via symlink at `~/.zshrc`)
- `zshrc.private` — private env vars, API tokens (git-ignored)
- `gitconfig` / `gitignore` — global git configuration
- `vimrc` / `vim/` — vim configuration and plugins
- `config/` — app configs symlinked into `~/.config/` (ghostty, yazi, etc.)
- `Brewfile` — Homebrew packages, casks, and VS Code extensions
- `osx` — macOS defaults script
- `inputrc` — readline config (bash only)
- `LaunchAgents/` — macOS launch agents (e.g. key remapping)

## Install

```bash
cd ~
git clone <your-fork>/dotfiles
cd dotfiles
./install.sh
```

`install.sh` symlinks dotfiles into `~`, runs `install-programs.sh` (Homebrew + app configs), and applies macOS defaults.

**Warning: install.sh overwrites existing files — back up first.**

## LaunchAgents

Symlink manually:

```bash
ln -s ~/dotfiles/LaunchAgents/com.local.KeyRemapping.plist ~/Library/LaunchAgents/
```

Key remapping reference: https://hidutil-generator.netlify.app/
