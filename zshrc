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
export HISTSIZE=999999
export SAVEHIST=999999
export HISTFILE=~/.zsh_history
setopt HIST_IGNORE_DUPS SHARE_HISTORY HIST_REDUCE_BLANKS HIST_IGNORE_SPACE HIST_FIND_NO_DUPS HIST_EXPIRE_DUPS_FIRST

#-------------------------------------------------------------------------------
# Prompt
#-------------------------------------------------------------------------------
export LSCOLORS="gxcxfxdxbxegedabagacad"
export CLICOLOR=1
export EZA_COLORS="reset:ur=0:uw=0:ux=0:ue=0:gr=0:gw=0:gx=0:tr=0:tw=0:tx=0:su=0:sf=0:xa=0"

eval "$(starship init zsh)"

#-------------------------------------------------------------------------------
# Homebrew (Apple Silicon → /opt/homebrew, Intel → /usr/local)
#-------------------------------------------------------------------------------
if [[ -x /opt/homebrew/bin/brew ]]; then
  BREW_PREFIX=/opt/homebrew
elif [[ -x /usr/local/bin/brew ]]; then
  BREW_PREFIX=/usr/local
fi
[[ -n $BREW_PREFIX ]] && eval "$($BREW_PREFIX/bin/brew shellenv)"

#-------------------------------------------------------------------------------
# Zsh
#-------------------------------------------------------------------------------

# treat /, ., - as word boundaries so opt-backspace nibbles path segments
WORDCHARS='*?_~=&;!#$%^(){}<>'

# completions
FPATH=$BREW_PREFIX/share/zsh/site-functions:$FPATH
autoload -Uz compinit
if [[ -n ~/.zcompdump(#qN.mh+24) ]]; then
  compinit
else
  compinit -C
fi

# plugins
[[ -r $BREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && source $BREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh
[[ -r $BREW_PREFIX/share/fzf-tab/fzf-tab.zsh ]] && source $BREW_PREFIX/share/fzf-tab/fzf-tab.zsh

# preview directories when completing cd
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always --icons $realpath'
# right arrow drills into directories
zstyle ':fzf-tab:*' continuous-trigger 'right'

#-------------------------------------------------------------------------------
# Path
#-------------------------------------------------------------------------------
export PATH=/usr/local/bin:~/bin:/usr/local/sbin:~/.cargo/bin:$HOME/.local/bin:$PATH

#-------------------------------------------------------------------------------
# Source private configuration if it exists
#-------------------------------------------------------------------------------
[ -f ~/dotfiles/zshrc.private ] && source ~/dotfiles/zshrc.private

#-------------------------------------------------------------------------------
# Aliases
#-------------------------------------------------------------------------------

# shell
alias ls='eza'           # learn eza
alias l='eza -lAF --icons=auto'
alias ll='eza -lAF --icons=auto'
alias tree='eza --tree --icons=auto'
alias cat='bat --paging=never'
alias dig='doggo'        # learn to use doggo
# claude: fzf picker — reconnect to existing session (default) or start new
claude() {
  local choice
  choice=$(printf 'reconnect\nnew' | fzf --prompt='Claude: ' --height=4 --reverse --no-info) || return
  case "$choice" in
    reconnect) command claude -r --enable-auto-mode "$@" ;;
    new)       command claude --enable-auto-mode "$@" ;;
  esac
}
alias pib='cd ~/code/vbrb-0010/vbrb-0010-pib-study/docs;claude;cd -'
alias pre='cd ~/code/vbrb-0001/rule-engine/docs/policy-v3;claude;cd -'

# brewctl: fzf-driven brew wrapper, profile-aware (Apple Silicon = personal, Intel = work)
brewctl() {
  local dotfiles=~/dotfiles
  local base=$dotfiles/Brewfile
  local work=$dotfiles/Brewfile.work
  local is_work=0; [[ ! -d /opt/homebrew ]] && is_work=1

  local action=${1:-}
  if [[ -z $action ]]; then
    action=$(printf 'upgrade\ninstall\ndump\nedit\nshow-extras\ndiff' \
      | fzf --prompt='brewctl: ' --height=8 --reverse --no-info) || return
  fi

  case "$action" in
    upgrade)
      brew update && brew upgrade && brew cleanup
      ;;
    install)
      brew bundle --file="$base"
      (( is_work )) && [[ -f $work ]] && brew bundle --file="$work"
      ;;
    dump)
      if (( is_work )); then
        local tmp=$(mktemp)
        brew bundle dump --file="$tmp" --force
        comm -23 <(sort -u "$tmp") <(sort -u "$base") > "$work"
        rm -f "$tmp"
        print "wrote work-only delta → $work ($(wc -l < $work | tr -d ' ') lines)"
      else
        brew bundle dump --file="$base" --force
        print "wrote personal baseline → $base"
      fi
      ;;
    edit)
      if (( is_work )); then
        local pick
        pick=$(printf 'Brewfile\nBrewfile.work' \
          | fzf --prompt='edit: ' --height=4 --reverse --no-info) || return
        ${EDITOR:-vim} "$dotfiles/$pick"
      else
        ${EDITOR:-vim} "$base"
      fi
      ;;
    show-extras)
      [[ -f $work ]] && bat --paging=never "$work" || print "no $work yet"
      ;;
    diff)
      local tmp tracked
      tmp=$(mktemp); tracked=$(mktemp)
      brew bundle dump --file="$tmp" --force
      cat "$base" > "$tracked"
      (( is_work )) && [[ -f $work ]] && cat "$work" >> "$tracked"
      print "── installed but untracked ──"
      comm -23 <(sort -u "$tmp") <(sort -u "$tracked")
      rm -f "$tmp" "$tracked"
      ;;
    *) print -u2 "brewctl: unknown action '$action'"; return 1 ;;
  esac
}

alias y='yazi'
alias top='btop'
alias upgrade='~/dotfiles/upgrade-all.sh'

# git
alias g='git add . && git commit && git push'
alias gs='git status -sb'
alias gd='git diff'

#-------------------------------------------------------------------------------
# Fuzzy finder (https://github.com/junegunn/fzf)
#-------------------------------------------------------------------------------
force_color_prompt=yes
source <(fzf --zsh)
eval "$(zoxide init zsh)"

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
ssh-add -l &>/dev/null || ssh-add --apple-use-keychain ~/.ssh/id_rsa 2>/dev/null

#-------------------------------------------------------------------------------
# Confluence
#-------------------------------------------------------------------------------
export CONFLUENCE_DOMAIN="api.atlassian.com"
export CONFLUENCE_API_PATH="/ex/confluence/9ff0c0f7-ad4b-47c6-b356-35144d98e6c8/wiki/rest/api"
export CONFLUENCE_AUTH_TYPE="basic"
export CONFLUENCE_EMAIL="stijn@novemberfive.co"
export CONFLUENCE_READ_ONLY=true # failsafe, token allows for page level write permissions

#-------------------------------------------------------------------------------
# Syntax highlighting (must be last)
#-------------------------------------------------------------------------------
[[ -r $BREW_PREFIX/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && source $BREW_PREFIX/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

#-------------------------------------------------------------------------------
# MOTD (one-line: brew · uptime · cpu · mem · last login)
# Suppress default "Last login:" line via ~/.hushlogin
#-------------------------------------------------------------------------------
[[ $- == *i* && -z $MOTD_SHOWN ]] && {
  source ~/dotfiles/motd.sh
  export MOTD_SHOWN=1
}
