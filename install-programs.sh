#!/bin/bash

# Homebrew
echo "Installing Homebrew"
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

## Let Homebrew install the rest
echo "Installing bundle for installing latest dumped Brewfile"
brew tap Homebrew/bundle
brew bundle --file=Brewfile
# Work laptop also gets the work-only extras (set N5_WORK_LAPTOP=1 in zshrc.private)
[[ -f "$HOME/dotfiles/zshrc.private" ]] && source "$HOME/dotfiles/zshrc.private"
if [[ -n "$N5_WORK_LAPTOP" && -f Brewfile.work ]]; then
  echo "Installing Brewfile.work (work-only extras)"
  brew bundle --file=Brewfile.work
fi

## install VIM Plug Manager
curl -fLo ~/.vim/autoload/plug.vim --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

## Symlink config files from dotfiles/config to ~/.config
DOTFILES_DIR="$HOME/dotfiles"

for file in "$DOTFILES_DIR/config"/**/*; do
  if [ -f "$file" ]; then
    relative_path="${file#$DOTFILES_DIR/config/}"
    target="$HOME/.config/$relative_path"
    target_dir="$(dirname "$target")"

    mkdir -p "$target_dir"

    if [ -e "$target" ] && [ ! -L "$target" ]; then
      mv "$target" "$target.old"
      echo "Backed up $target to $target.old"
    fi

    ln -sf "$file" "$target"
    echo "Created symlink: $target -> $file"
  fi
done
