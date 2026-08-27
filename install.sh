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

	# already linked where we want it, leave it alone. without this, every
	# re-run backs up a perfectly good symlink and the backups pile up.
	if [ "`readlink "$target"`" = "$original" ]; then
		return
	fi

	if [ -h "$target" ] || [ -e "$target" ]; then
		mv "$target" "$target.`date +%s`.backup"
	fi

	ln -s "$original" "$target"
	echo "Linked $original to $target"
}

# The §/± -> Escape remap is only wanted on the Intel MacBook Pro. This asks
# for positive proof of Intel: anything we cannot confirm (a sysctl that is
# unavailable, Rosetta reporting x86_64, some future model) falls through to
# "no", so the remap is never silently enabled on the wrong machine.
is_intel_macbook_pro()
{
	# apple silicon, including under rosetta where uname says x86_64
	[ "`sysctl -n hw.optional.arm64 2>/dev/null`" = "1" ] && return 1

	[ "`uname -m`" = "x86_64" ] || return 1

	# every intel MBP reports MacBookProN,N. apple silicon reports Mac14,x
	# and up, so this also rules out the M1/M2 machines that kept the old
	# MacBookPro17,1 / 18,x identifiers.
	case "`sysctl -n hw.model 2>/dev/null`" in
		MacBookPro*) return 0 ;;
	esac

	return 1
}

# wire up the dotfiles
for name in *; do
	case "$name" in
		README.md|install.sh|install-programs.sh|osx|ssh|config|LaunchAgents|Brewfile|.git*)
			# Skip these files/directories
			;;
		*)
			link_and_backup "$PWD/$name" "$HOME/.$name"
			;;
	esac
done

# wire up the ~/.config tree. linked per file rather than per directory, so
# apps keep their own state alongside ours (zed/themes, zed/prompts, ...)
find config -type f ! -name '.DS_Store' | while read -r file; do
	target="$HOME/.$file"
	mkdir -p "`dirname "$target"`"
	link_and_backup "$PWD/$file" "$target"
done

# wire up the launch agents. launchd reads ~/Library/LaunchAgents and nowhere
# else, so these cannot go through the dot-prefixed loop above.
mkdir -p "$HOME/Library/LaunchAgents"
for plist in LaunchAgents/*.plist; do
	name="`basename "$plist"`"
	label="${name%.plist}"
	target="$HOME/Library/LaunchAgents/$name"

	if [ "$label" = "com.local.KeyRemapping" ] && ! is_intel_macbook_pro; then
		echo "Skipping $label (not an Intel MacBook Pro)"
		# do not leave a previous machine's copy loaded
		launchctl bootout "gui/`id -u`/$label" 2>/dev/null
		rm -f "$target"
		continue
	fi

	link_and_backup "$PWD/$plist" "$target"

	# reload so an edited plist takes effect on re-run
	launchctl bootout "gui/`id -u`/$label" 2>/dev/null
	if launchctl bootstrap "gui/`id -u`" "$target" 2>/dev/null; then
		echo "Loaded $label"
	else
		echo "Could not load $label (try: launchctl bootstrap gui/`id -u` $target)"
	fi
done

# restore yazi flavors/plugins pinned in config/yazi/package.toml
if command -v ya >/dev/null 2>&1; then
	ya pkg install >/dev/null 2>&1 && echo "Restored yazi packages"
fi

# some os specific stuff
if [ "Darwin" = "$(uname -s)" ]; then
	# install osx defaults
	sh install-programs.sh
	sh osx
fi

# some vim stuff
mkdir -p $HOME/.vim/{swap,backup,undo,cache}
