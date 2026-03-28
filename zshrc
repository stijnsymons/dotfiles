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

# history
export HISTSIZE=9999
export SAVEHIST=9999
export HISTFILE=~/.zsh_history
setopt HIST_IGNORE_DUPS SHARE_HISTORY HIST_REDUCE_BLANKS

#-------------------------------------------------------------------------------
# Prompt
#-------------------------------------------------------------------------------
export LSCOLORS="gxcxfxdxbxegedabagacad"
export CLICOLOR=1

eval "$(starship init zsh)"

#-------------------------------------------------------------------------------
# Zsh
#-------------------------------------------------------------------------------

# completions
if type brew &>/dev/null; then
  FPATH=$(brew --prefix)/share/zsh-completions:$FPATH
fi
autoload -Uz compinit
compinit

# plugins
source /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /opt/homebrew/share/fzf-tab/fzf-tab.zsh

# preview directories when completing cd
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls -1 --color=always $realpath'
# right arrow drills into directories
zstyle ':fzf-tab:*' continuous-trigger 'right'

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
alias ff='ag'

# git
alias g='git add . && git commit && git push'
alias gs='git status -sb'
alias gd='git diff'

#-------------------------------------------------------------------------------
# Fuzzy finder (https://github.com/junegunn/fzf)
#-------------------------------------------------------------------------------
force_color_prompt=yes
source <(fzf --zsh)

# up arrow: fzf history search on empty line, normal up otherwise
fzf-history-or-up() {
  if [[ -z "$BUFFER" ]]; then
    fzf-history-widget
  else
    zle up-line-or-history
  fi
}
zle -N fzf-history-or-up
bindkey '^[[A' fzf-history-or-up

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
ssh-add --apple-use-keychain ~/.ssh/id_rsa > /dev/null 2>&1

#-------------------------------------------------------------------------------
# Confluence
#-------------------------------------------------------------------------------
export CONFLUENCE_DOMAIN="api.atlassian.com"
export CONFLUENCE_API_PATH="/ex/confluence/9ff0c0f7-ad4b-47c6-b356-35144d98e6c8/wiki/rest/api"
export CONFLUENCE_AUTH_TYPE="basic"
export CONFLUENCE_EMAIL="stijn@novemberfive.co"
export CONFLUENCE_READ_ONLY=true # failsafe, token allows for page level write permissions
