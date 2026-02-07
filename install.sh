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
# excluding bashrc, bashprofile and osx for osx only systems
for name in *; do
	if [ "$name" != "README.md" ]; then
	if [ "$name" != "install.sh" ]; then
	if [ "$name" != "osx" ]; then
	if [ "$name" != "ssh" ]; then
		link_and_backup $PWD/$name $HOME/.$name
	fi;fi;fi;fi;fi
done
for name in *; do
	case "$name" in
		README.md|install.sh|osx|ssh|.git*)
			# Skip these files
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

# setup ssh config file for appstrakt on mac's only (avoids servers and vagrants)
if [ -f $HOME/.ssh/config ]; then
    cat "$PWD/ssh/config" >> $HOME/.ssh/config
else
    if [ ! -d $HOME/.ssh ]; then
        mkdir -p $HOME/.ssh
    fi
    ln -s  $PWD/ssh/config $HOME/.ssh/config
fi

# some vim stuff
mkdir -p $HOME/.vim/swap
mkdir -p $HOME/.vim/backup
mkdir -p $HOME/.vim/undo
mkdir -p $HOME/.vim/cache
