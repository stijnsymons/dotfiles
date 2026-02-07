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
