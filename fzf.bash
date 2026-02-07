# Setup fzf
# ---------
if [[ ! "$PATH" == */Users/stijn/.fzf/bin* ]]; then
  export PATH="$PATH:/Users/stijn/.fzf/bin"
fi

# Man path
# --------
if [[ ! "$MANPATH" == */Users/stijn/.fzf/man* && -d "/Users/stijn/.fzf/man" ]]; then
  export MANPATH="$MANPATH:/Users/stijn/.fzf/man"
fi

# Auto-completion
# ---------------
[[ $- == *i* ]] && source "/Users/stijn/.fzf/shell/completion.bash" 2> /dev/null

# Key bindings
# ------------
source "/Users/stijn/.fzf/shell/key-bindings.bash"

