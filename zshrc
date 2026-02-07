#-------------------------------------------------------------------------------
# Dotfiles
#-------------------------------------------------------------------------------

# Basics
: ${HOME=~}
: ${LOGNAME=$(id -un)}
: ${UNAME=$(uname)}
: ${DEFAULT_USERNAME='stijn'}

# Proper locale
: ${LANG:="en_US.UTF-8"}
: ${LANGUAGE:="en"}
: ${LC_CTYPE:="en_US.UTF-8"}
: ${LC_ALL:="en_US.UTF-8"}

# Fucking mail notifications
unset MAILCHECK

export LANG LANGUAGE LC_CTYPE LC_ALL

# editor
export EDITOR=vim

# increase history size
export HISTSIZE=9999

#-------------------------------------------------------------------------------
# Prompt
#-------------------------------------------------------------------------------
export LSCOLORS="gxcxfxdxbxegedabagacad"
export CLICOLOR=1

eval "$(starship init zsh)"

#-------------------------------------------------------------------------------
# Zsh
#-------------------------------------------------------------------------------

# load autocomplete
source /opt/homebrew/share/zsh-autocomplete/zsh-autocomplete.plugin.zsh
# Make Enter submit the command line straight from the menu
bindkey -M menuselect '\r' .accept-line
# Make Tab go straight to the menu and cycle there
bindkey '\t' menu-select "$terminfo[kcbt]" menu-select
bindkey -M menuselect '\t' menu-complete "$terminfo[kcbt]" reverse-menu-complete

if type brew &>/dev/null; then
  FPATH=$(brew --prefix)/share/zsh-completions:$FPATH

  autoload -Uz compinit
  compinit
fi

#-------------------------------------------------------------------------------
# Path
#-------------------------------------------------------------------------------
export PATH=/usr/local/bin:~/bin:/usr/local/sbin:~/.cargo/bin:$PATH

#-------------------------------------------------------------------------------
# Source private configuration if it exists
#-------------------------------------------------------------------------------
[ -f ~/dotfiles/zshrc.private ] && source ~/dotfiles/zshrc.private

#-------------------------------------------------------------------------------
# Aliases
#-------------------------------------------------------------------------------

# shell
LS_OPTIONS=""
alias l='ls -lAhF $LS_OPTIONS'
alias ll='ls -lAhF $LS_OPTIONS'
alias ff='find . -name "*" -type f | xargs grep '

# git
alias g='git add . && git commit && git push'
alias gs='git status -sb'
alias gd='git diff'

#-------------------------------------------------------------------------------
# Fuzzy finder (https://github.com/junegunn/fzf)
#-------------------------------------------------------------------------------
force_color_prompt=yes
[ -f ~/.fzf.bash ] && source ~/.fzf.bash

#-------------------------------------------------------------------------------
# Colored man pages
#-------------------------------------------------------------------------------
man() {
    env \
    LESS_TERMCAP_mb=$(printf "\e[1;31m") \
    LESS_TERMCAP_md=$(printf "\e[1;31m") \
    LESS_TERMCAP_me=$(printf "\e[0m") \
    LESS_TERMCAP_se=$(printf "\e[0m") \
    LESS_TERMCAP_so=$(printf "\e[1;44;33m") \
    LESS_TERMCAP_ue=$(printf "\e[0m") \
    LESS_TERMCAP_us=$(printf "\e[1;32m") \
    man "$@"
}

#-------------------------------------------------------------------------------
# SSH
#-------------------------------------------------------------------------------
ssh-add -K ~/.ssh/id_rsa > /dev/null 2>&1
