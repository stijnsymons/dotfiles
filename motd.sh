#!/bin/zsh
#
# One-line MOTD: upgrades · uptime · cpu · mem · last login
# Sourced from zshrc on shell startup.
#

CYAN=$'\033[0;36m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
DIM=$'\033[2m'
RESET=$'\033[0m'

_motd_cached_count() {
  # $1 = cache key, $2 = producer function (writes a single value to stdout)
  local key=$1 producer=$2
  local cache="$HOME/.cache/dotfiles/$key"
  [[ -d ${cache:h} ]] || mkdir -p "${cache:h}"
  if [[ -s "$cache" ]]; then
    local mtime
    zmodload -F zsh/stat b:zstat 2>/dev/null
    zstat -A mtime +mtime "$cache" 2>/dev/null
    if (( EPOCHSECONDS - mtime[1] < 86400 )); then
      print -r -- "$(<$cache)"
      return
    fi
  fi
  ( "$producer" > "$cache" 2>/dev/null & )
  [[ -s "$cache" ]] && print -r -- "$(<$cache)" || print -r -- "?"
}

_motd_brew_count() { brew outdated --quiet 2>/dev/null | wc -l | tr -d ' '; }

_motd_npm_count()  { npm outdated -g --parseable 2>/dev/null | wc -l | tr -d ' '; }

_motd_n5_count() {
  # Each repo with any upstream commits counts as 1.
  local count=0 repo ahead
  for repo in ~/code/brain ~/code/skills ~/code/claude-statusline; do
    [[ -d "$repo/.git" ]] || continue
    git -C "$repo" fetch --quiet 2>/dev/null
    ahead=$(git -C "$repo" rev-list HEAD..@{u} --count 2>/dev/null)
    [[ -n "$ahead" && "$ahead" != "0" ]] && (( count++ ))
  done
  print -r -- "$count"
}

_motd_uptime() {
  # "{ sec = 1715600000, usec = 0 } ..." → 1715600000 via zsh param expansion
  local boot_raw=$(sysctl -n kern.boottime 2>/dev/null)
  local boot=${${boot_raw#*sec = }%%,*}
  local diff=$(( EPOCHSECONDS - boot ))
  local d=$(( diff / 86400 ))
  local h=$(( (diff % 86400) / 3600 ))
  local m=$(( (diff % 3600) / 60 ))
  if   (( d > 0 )); then printf "%dd %dh" $d $h
  elif (( h > 0 )); then printf "%dh %dm" $h $m
  else                   printf "%dm" $m
  fi
}

_motd_last_login() {
  # second entry skips current session; fields: user tty day mon date time
  last -2 "$USER" 2>/dev/null | awk 'NR==2 && $3!="" { printf "%s %s %s %s", $3, $4, $5, $6 }'
}

_motd_num() {
  # Color a count: green when 0, yellow when >0, dim when unknown.
  local n=$1
  if   [[ "$n" == "?" ]]; then print -nr -- "${DIM}?${RESET}"
  elif [[ "$n" == "0" ]]; then print -nr -- "${GREEN}0${RESET}"
  else                         print -nr -- "${YELLOW}${n}${RESET}"
  fi
}

_motd_render() {
  # 1-min load average
  local load_raw=$(sysctl -n vm.loadavg 2>/dev/null)  # "{ 1.23 1.45 1.67 }"
  local -a load_parts=( ${=load_raw} )
  local cpu=${load_parts[2]}

  # Memory used (Activity Monitor formula: app + wired + compressed)
  # Computed via vm_stat — instant vs top's ~1s sample.
  local mem=$(vm_stat 2>/dev/null | awk '
    /page size of/ { ps = $8 }
    /Pages active/                  { gsub("\\.",""); a = $3 }
    /Pages wired down/              { gsub("\\.",""); w = $4 }
    /Pages occupied by compressor/  { gsub("\\.",""); c = $5 }
    END { printf "%.0fG", (a + w + c) * ps / 1073741824 }
  ')

  local brew=$(_motd_cached_count brew _motd_brew_count)
  local npm=$(_motd_cached_count  npm  _motd_npm_count)
  local n5=$(_motd_cached_count   n5   _motd_n5_count)

  local up=$(_motd_uptime)
  local last=$(_motd_last_login)
  local sep="${DIM} · ${RESET}"

  printf "${DIM}upgrades [${RESET}%s${DIM} brew | ${RESET}%s${DIM} npm | ${RESET}%s${DIM} n5${RESET}${DIM}]${RESET}" \
    "$(_motd_num "$brew")" "$(_motd_num "$npm")" "$(_motd_num "$n5")"
  printf "%s${DIM}up${RESET} ${CYAN}%s${RESET}%s${DIM}cpu${RESET} ${CYAN}%s${RESET}%s${DIM}mem${RESET} ${CYAN}%s${RESET}" \
    "$sep" "$up" "$sep" "$cpu" "$sep" "$mem"
  [[ -n "$last" ]] && printf "%s${DIM}last login${RESET} ${CYAN}%s${RESET}" "$sep" "$last"
  printf "\n"
}

zmodload zsh/datetime 2>/dev/null  # provides $EPOCHSECONDS (no date subshell)
_motd_render

unfunction _motd_render _motd_cached_count _motd_brew_count _motd_npm_count \
           _motd_n5_count _motd_uptime _motd_last_login _motd_num 2>/dev/null
unset CYAN GREEN YELLOW DIM RESET
