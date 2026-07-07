# brewctl: fzf-driven brew wrapper, profile-aware (set N5_WORK_LAPTOP=1 in zshrc.private on work machines)
brewctl() {
  local dotfiles=~/dotfiles
  local base=$dotfiles/Brewfile
  local work=$dotfiles/Brewfile.work
  local is_work=0; [[ -n $N5_WORK_LAPTOP ]] && is_work=1

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
