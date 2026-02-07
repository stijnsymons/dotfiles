# Dotfiles

## About

you can use this as a template, I recommend you fork it though and tweak it for yourself :)
change `dotfiles/gitmodules` to contain your credentials instead of mine

## Install

* fork this repo
* clone this repo to your machine
	
		$ cd
		$ git clone <yourusername>/dotfiles

* change credentials in `dotfiles/gitmodules`
* run install 
		
		$ cd ~/dotfiles
		$ ./install.sh

**install.sh does delete files without taking backups !!**

## LaunchAgents

- for LaunchAgents do:
  ln -s ~/dotfiles/LaunchAgents/com.local.KeyRemapping.plist ~/Library/LaunchAgents/com.local.KeyRemapping.plist

  this does keyboard remapping, btw the paragraph sign is called `non_us_backslash` - go figure
  more info: https://hidutil-generator.netlify.app/
