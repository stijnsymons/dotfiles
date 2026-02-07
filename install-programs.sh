#!/bin/bash

# Homebrew
echo "Installing Homebrew"
ruby -e "$(curl -fsSL https://raw.github.com/Homebrew/homebrew/go/install)"

## Let Homebrew install the rest
echo "Installing bundle for installing latest dumped Brewfile"
brew tap Homebrew/bundle
brew bundle

## install VIM Plug Manager
curl -fLo ~/.vim/autoload/plug.vim --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

## this runs through the dotfiles/local config folder, and for each file found, creates a symbolic link in ~/.config with the same path.
## additionally when the file in ~/.config already exists, it backs the file up as <original-filename>.old to avoid loosing the original
DOTFILES_DIR="$HOME/dotfiles"

for file in "$DOTFILES_DIR/local/config"/**/*; do
  if [ -f "$file" ]; then
    # Get the relative path from dotfiles/local/config
    relative_path="${file#$DOTFILES_DIR/local/config/}"
    target="$HOME/.config/$relative_path"
    target_dir="$(dirname "$target")"

    # Create target directory if it doesn't exist
    mkdir -p "$target_dir"

    # Backup existing file if it exists and is not already a symlink
    if [ -e "$target" ] && [ ! -L "$target" ]; then
      mv "$target" "$target.old"
      echo "Backed up $target to $target.old"
    fi

    # Create symbolic link
    ln -sf "$file" "$target"
    echo "Created symlink: $target -> $file"
  fi
done
