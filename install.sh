#!/usr/bin/env bash
#
# This installation is destructive, as it removes exisitng files/directories.
# Use at your own risk.

# just to make sure we know where home is
: ${HOME=~}

# make sure you clone the submodules (vim)
git submodule update --init

# helper function
link_and_backup()
{
	original=$1
	target=$2

	if [ -h $target ]; then
		mv $target $target.`date +%s`.backup
	elif [ -d $target ]; then
		mv $target $target.`date +%s`.backup
	fi

	ln -s $original $target
	echo "Linked $original to $target"
}

# wire up the dotfiles
for name in *; do
	case "$name" in
		README.md|install.sh|install-programs.sh|osx|ssh|config|LaunchAgents|sublime|vim|Brewfile|.git*)
			# Skip these files/directories
			;;
		*)
			link_and_backup "$PWD/$name" "$HOME/.$name"
			;;
	esac
done

# some os specific stuff
if [ "Darwin" = "$(uname -s)" ]; then
	# install osx defaults
	sh install-programs.sh
	sh osx
fi

# some vim stuff
mkdir -p $HOME/.vim/swap
mkdir -p $HOME/.vim/backup
mkdir -p $HOME/.vim/undo
mkdir -p $HOME/.vim/cache
