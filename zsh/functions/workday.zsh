# workday: reconstruct daily first/last manual-activity times for the past N days.
#
# Signal: terminal login sessions from `last` (every terminal tab / herdr pane
# login + boot/reboot/shutdown), which densely brackets active hours. Session
# start AND end times are used. zsh history isn't used for the past — it only
# gained timestamps (EXTENDED_HISTORY) from now on.
#
# Columns: DATE FIRST LAST SPAN_HOURS SAMPLES. Days with no terminal activity
# (e.g. days off) are omitted.
#
# Usage: workday [days]        aligned table with header (default 31 days)
#        workday [days] -t     raw TSV, no header (for piping / parsing)
workday() {
  emulate -L zsh
  local tsv=0 days=31 a
  for a in "$@"; do
    case $a in
      -t|--tsv) tsv=1 ;;
      <->) days=$a ;;
    esac
  done
  local now cutoff year
  now=$(date +%s); cutoff=$(( now - days*86400 )); year=$(date +%Y)

  {
    (( tsv )) || print 'DATE\tFIRST\tLAST\tSPAN_HOURS\tSAMPLES'
    # 1) normalise every session endpoint from `last` to "Mon DD HH:MM"
    #    (anchor on the weekday token so an optional host column doesn't shift it)
    last | awk '
      { wd=0
        for (i=1;i<=NF;i++) if ($i ~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$/) { wd=i; break }
        if (wd==0) next
        print $(wd+1), $(wd+2), $(wd+3)                       # session start
        for (j=wd+4;j<NF;j++)                                 # session end, if any
          if ($j=="-" && $(j+1) ~ /^[0-9][0-9]:[0-9][0-9]$/) { print $(wd+1), $(wd+2), $(j+1); break }
      }' | \
    # 2) parse to epoch (infer year), keep only the last N days → "YYYY-MM-DD<TAB>HH:MM"
    while read -r mon day tim; do
      ep=$(date -j -f "%b %d %H:%M %Y" "$mon $day $tim $year" +%s 2>/dev/null) || continue
      (( ep > now )) && ep=$(date -j -f "%b %d %H:%M %Y" "$mon $day $tim $((year-1))" +%s 2>/dev/null)
      (( ep < cutoff || ep > now )) && continue
      printf '%s\t%s\n' "$(date -r $ep '+%Y-%m-%d')" "$tim"
    done | \
    # 3) bucket by day → earliest/latest (HH:MM sorts lexically), span, sample count
    awk -F'\t' '
      { d=$1; t=$2; n[d]++
        if ((d in f)==0 || t<f[d]) f[d]=t
        if ((d in l)==0 || t>l[d]) l[d]=t }
      END { for (d in f) {
              split(f[d],a,":"); split(l[d],b,":")
              span=((b[1]*60+b[2])-(a[1]*60+a[2]))/60
              printf "%s\t%s\t%s\t%.1f\t%d\n", d, f[d], l[d], span, n[d]
      } }' | sort
  } | if (( tsv )); then cat; else column -t -s $'\t'; fi
}
