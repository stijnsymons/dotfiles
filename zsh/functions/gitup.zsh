# gitup: git pull every repo below a directory, one result line each.
#
# Grew out of `for d in $(fd --max-depth=1 -t d); do cd $d; git pull; cd -; done`,
# which works until something in it does not: a `cd` that fails leaves the loop
# running in the wrong directory, a repo with no upstream prints a four-line
# lecture, and a name with a space in it splits into two arguments. This keeps
# the shape and fixes those.
#
#   gitup                 # repos directly below the current directory
#   gitup ~/code          # ... below ~/code
#   gitup -d 2 ~/code     # ... and one level deeper (client/product layouts)
#   gitup -m              # allow merge commits instead of refusing to diverge
gitup() {
  emulate -L zsh
  setopt local_options no_nomatch

  local root=. depth=1 merge=0
  while (( $# )); do
    case "$1" in
      -d|--depth) depth=$2; shift 2 ;;
      -m|--merge) merge=1; shift ;;
      -h|--help)
        print "usage: gitup [-d depth] [-m|--merge] [dir]"
        print "  -d  how many levels below dir to look for repos (default 1)"
        print "  -m  pull with a merge; without it a diverged repo is reported, not merged"
        return 0 ;;
      -*) print -u2 "gitup: unknown flag '$1'"; return 1 ;;
      *)  root=$1; shift ;;
    esac
  done

  (( $+commands[fd] )) || { print -u2 "gitup: needs fd"; return 1 }
  [[ -d $root ]] || { print -u2 "gitup: not a directory: $root"; return 1 }

  local RST=$'\e[0m' GRN=$'\e[32m' YLW=$'\e[33m' RED=$'\e[31m' DIM=$'\e[2m' BLD=$'\e[1m' CYN=$'\e[36m'
  # Colour is decoration, so drop it the moment this is piped or redirected -
  # otherwise the escapes end up in whatever is reading.
  local tty=1
  if [[ ! -t 1 ]]; then tty=0; RST= GRN= YLW= RED= DIM= BLD= CYN=; fi

  # Find repos by their .git rather than by listing directories and testing each:
  # it is one pass, and it is what makes -d work at all. .git is matched as both
  # a directory and a file, because a worktree or submodule checkout has a file.
  # -H because it is hidden, -I so a stray ignore rule cannot hide a repo.
  local rootabs=${root:A}
  local -a gitdirs
  gitdirs=( ${(f)"$(fd -H -I --absolute-path --max-depth $((depth + 1)) '^\.git$' $rootabs 2>/dev/null)"} )

  local -a repos names
  local g d
  for g in $gitdirs; do
    d=${g:h}
    # A .git inside a repo's own storage (module checkouts) is not a checkout to
    # pull, so require a work tree.
    [[ $(git -C $d rev-parse --is-inside-work-tree 2>/dev/null) == true ]] || continue
    repos+=( $d )
    names+=( ${d#$rootabs/} )
  done

  if (( ! $#repos )); then
    print "${DIM}gitup: no repos below ${rootabs}${RST}"
    return 0
  fi

  # Column width so branches line up regardless of name length.
  local n w=0
  for n in $names; do (( $#n > w )) && w=$#n; done

  print "${BLD}gitup${RST} ${CYN}${rootabs}${RST} ${DIM}· $#repos repo$( (( $#repos == 1 )) || print -n s ) · depth ${depth}${RST}"

  local i=0 updated=0 current=0 skipped=0 failed=0
  local start=$SECONDS
  # All declared once: a second `local` on a name already in scope makes zsh's
  # typeset print it, which leaks stray "ahead=0" lines into the report.
  local name branch upstream before after count out rc flag
  local ahead behind why ln maxw
  local -a lines
  for i in {1..$#repos}; do
    d=$repos[i]; name=$names[i]

    branch=$(git -C $d symbolic-ref --quiet --short HEAD 2>/dev/null)
    upstream=$(git -C $d rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)

    # Dirty is annotated, never a reason to skip: a pull that would clobber
    # uncommitted work is refused by git itself and lands in the failed branch
    # with git's own reason, which is more useful than a guess made here.
    flag=
    [[ -n $(git -C $d status --porcelain 2>/dev/null) ]] && flag=" ${YLW}●${RST}"

    # Nothing to pull onto or into - say so instead of letting git explain it
    # four lines at a time, once per repo.
    if [[ -z $branch ]]; then
      printf '  %s⊘%s %-*s %s%s%s\n' "$YLW" "$RST" $w "$name" "$DIM" "detached HEAD" "$RST"
      (( skipped++ )); continue
    fi
    if [[ -z $upstream ]]; then
      printf '  %s⊘%s %-*s %s%s%s\n' "$YLW" "$RST" $w "$name" "$DIM" "no upstream" "$RST"
      (( skipped++ )); continue
    fi

    (( tty )) && printf '  %s⟳ %s%s' "$DIM" "$name" "$RST"

    before=$(git -C $d rev-parse HEAD 2>/dev/null)
    # --ff-only by default: this runs unattended over many repos, and the worst
    # outcome is not "did not pull" but a half-finished merge left in a repo the
    # user is not looking at. -m opts into the merge.
    if (( merge )); then
      out=$(git -C $d pull --no-rebase 2>&1); rc=$?
    else
      out=$(git -C $d pull --ff-only 2>&1); rc=$?
    fi
    after=$(git -C $d rev-parse HEAD 2>/dev/null)

    (( tty )) && printf '\r\e[2K'

    if (( rc == 0 )); then
      if [[ $before == $after ]]; then
        printf '  %s·%s %-*s %s%-14s%s %sup to date%s%s\n' \
               "$DIM" "$RST" $w "$name" "$DIM" "$branch" "$RST" "$DIM" "$RST" "$flag"
        (( current++ ))
      else
        count=$(git -C $d rev-list --count "$before..$after" 2>/dev/null)
        printf '  %s✔%s %-*s %s%-14s%s %s+%s%s %s%s..%s%s%s\n' \
               "$GRN" "$RST" $w "$name" "$DIM" "$branch" "$RST" \
               "$GRN" "${count:-?}" "$RST" "$DIM" "${before:0:7}" "${after:0:7}" "$RST" "$flag"
        (( updated++ ))
      fi
    else
      # A non-zero pull is not automatically an ERROR. With --ff-only, the two
      # commonest ones are git declining on purpose - the repo diverged, or the
      # work tree is dirty - and painting those red across twenty repos trains
      # you to ignore the colour that is supposed to mean "look at this". So
      # classify from the repo's actual state rather than by grepping the
      # message, and keep red for things that are genuinely broken (no network,
      # no such remote, bad credentials).
      ahead=$(git -C $d rev-list --count "${upstream}..HEAD" 2>/dev/null)
      behind=$(git -C $d rev-list --count "HEAD..${upstream}" 2>/dev/null)
      if (( ${ahead:-0} > 0 && ${behind:-0} > 0 )); then
        printf '  %s⊘%s %-*s %s%-14s%s %sdiverged +%s/-%s%s %s(-m to merge)%s\n' \
               "$YLW" "$RST" $w "$name" "$DIM" "$branch" "$RST" \
               "$YLW" "$ahead" "$behind" "$RST" "$DIM" "$RST"
        (( skipped++ ))
      elif [[ -n $flag ]]; then
        printf '  %s⊘%s %-*s %s%-14s%s %sdirty, not pulled%s %s(%s behind)%s\n' \
               "$YLW" "$RST" $w "$name" "$DIM" "$branch" "$RST" \
               "$YLW" "$RST" "$DIM" "${behind:-?}" "$RST"
        (( skipped++ ))
      else
        # git explains itself over many lines, most of them hints. Prefer the
        # fatal/error line; fall back to the first line that says anything.
        lines=( ${(f)out} )
        why=
        for ln in $lines; do
          [[ -z ${ln//[[:space:]]/} || $ln == hint:* || $ln == From\ * ]] && continue
          why=$ln; break
        done
        for ln in $lines; do
          [[ $ln == fatal:* || $ln == error:* ]] && { why=$ln; break }
        done
        # Keep the line on one line; the full text is still a `git -C <dir> pull` away.
        maxw=$(( ${COLUMNS:-100} - w - 24 ))
        (( maxw < 20 )) && maxw=20
        (( $#why > maxw )) && why="${why[1,maxw-1]}…"
        printf '  %s✖%s %-*s %s%-14s%s %s%s%s\n' \
               "$RED" "$RST" $w "$name" "$DIM" "$branch" "$RST" "$RED" "${why:-pull failed}" "$RST"
        (( failed++ ))
      fi
    fi
  done

  local took=$(( SECONDS - start ))
  local -a bits
  (( updated )) && bits+=( "${GRN}${updated} updated${RST}" )
  (( current )) && bits+=( "${DIM}${current} up to date${RST}" )
  (( skipped )) && bits+=( "${YLW}${skipped} skipped${RST}" )
  (( failed  )) && bits+=( "${RED}${failed} failed${RST}" )
  print "${DIM}──${RST} ${(j: · :)bits} ${DIM}· ${took}s${RST}"

  (( failed == 0 ))
}
