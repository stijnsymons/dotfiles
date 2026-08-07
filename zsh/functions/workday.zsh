# workday: reconstruct daily first/last manual-activity times for the past N days.
#
# Signal: terminal login sessions from `last` (every terminal tab / herdr pane
# login + boot/reboot/shutdown), unioned with zsh EXTENDED_HISTORY timestamps
# (every command run, dense within an already-open session — `last` only sees
# a session's open/close, not what happens inside it). History timestamps only
# exist from whenever EXTENDED_HISTORY was enabled onward; older lines have no
# ': EPOCH:' prefix and are silently ignored.
#
# Columns: DATE FIRST LAST SPAN_HOURS SAMPLES. Days with no terminal activity
# (e.g. days off) are omitted.
#
# Usage: workday [days]           aligned table with header (default 31 days)
#        workday [days] -t         raw TSV, no header (for piping / parsing)
#        workday [days] -g         one activity-per-hour histogram per day
#                                  (small multiples sharing one hour axis)

# Internal: emit one "YYYY-MM-DD<TAB>HH:MM" line per activity measurement.
# Reads now/cutoff/year/histfile from its caller via zsh dynamic scoping. Kept a
# separate function (not a `samples=$(...)` capture) on purpose: in interactive
# shells without INTERACTIVE_COMMENTS a `#` inside $(...) isn't a comment, so a
# `)` in a comment would prematurely close the substitution. Comments are safe
# in a function body, so the pipeline lives here.
_workday_samples() {
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
  done

  # 1b) zsh EXTENDED_HISTORY: every timestamped command as an activity sample
  #     (lines are ': EPOCH:DURATION;command'; older, pre-EXTENDED_HISTORY
  #     lines lack this prefix and don't match). Enabling EXTENDED_HISTORY
  #     backfills every pre-existing line with the *same* epoch (the moment
  #     of the rewrite) rather than its real run time — a real command is
  #     never issued 20+ times in one literal second, so drop epochs that
  #     pile up that heavily as backfill artefacts, not activity.
  [[ -r $histfile ]] || return
  awk -F';' '
    /^: [0-9]+:/ { n=$1; sub(/^: /,"",n); sub(/:.*/,"",n); c[n]++; idx++; a[idx]=n }
    END { for (i=1;i<=idx;i++) if (c[a[i]] <= 20) print a[i] }
  ' "$histfile" | \
  while read -r ep; do
    (( ep < cutoff || ep > now )) && continue
    printf '%s\t%s\n' "$(date -r "$ep" '+%Y-%m-%d')" "$(date -r "$ep" '+%H:%M')"
  done
}

workday() {
  emulate -L zsh
  local tsv=0 graph=0 days=31 a
  for a in "$@"; do
    case $a in
      -t|--tsv)   tsv=1 ;;
      -g|--graph) graph=1 ;;
      <->) days=$a ;;
    esac
  done
  local now cutoff year histfile
  now=$(date +%s); cutoff=$(( now - days*86400 )); year=$(date +%Y)
  histfile=${HISTFILE:-~/.zsh_history}

  if (( graph )); then
    # Small multiples: one histogram per day. Every day shares the same X-axis —
    # normalised from the earliest active hour to the latest across the whole
    # window — so columns line up for comparison. Each day's bars are scaled to
    # that day's own peak (its caption states the count), Y being the number of
    # measurements in the hour. Sub-cell block glyphs give 1/8-row resolution.
    _workday_samples | awk -F'\t' '
      $2 ~ /^[0-9][0-9]:/ {
        d=$1; h=substr($2,1,2)+0; key=d SUBSEP h
        cnt[key]++; dtot[d]++
        if (!(d in seen)) { seen[d]=1; days[++nd]=d }
        if (gminh=="" || h<gminh) gminh=h
        if (gmaxh=="" || h>gmaxh) gmaxh=h
        if (cnt[key] > dpeak[d]) { dpeak[d]=cnt[key]; dpeakh[d]=h }
        if (cnt[key] > gmax) gmax=cnt[key]
      }
      END {
        if (nd==0) { print "workday: no activity samples in range"; exit }
        # chronological order (YYYY-MM-DD sorts lexically)
        for (i=1;i<=nd;i++) for (j=i+1;j<=nd;j++) if (days[j]<days[i]) { t=days[i];days[i]=days[j];days[j]=t }
        split(" |▁|▂|▃|▄|▅|▆|▇|█", B, "|")     # B[k+1] = k eighths filled (B[1]=blank)
        H=6
        w=length(gmax "")                       # left gutter fixed to the global peak so every day aligns
        # shared hour axis, printed once
        printf "%*s", w+2, ""
        for (h=gminh; h<=gmaxh; h++) printf "%02d ", h
        printf "\n"
        for (i=1;i<=nd;i++) {
          d=days[i]; pk=dpeak[d]
          printf "%s — %d samples, peak %d at %02dh\n", d, dtot[d], pk, dpeakh[d]
          for (r=H; r>=1; r--) {
            printf "%*s ┤", w, (r==H?pk:"")
            for (h=gminh; h<=gmaxh; h++) {
              c=((d SUBSEP h) in cnt)?cnt[d,h]:0
              eig=(pk>0)?int(c/pk*H*8+0.5):0
              if (c>0 && eig==0) eig=1            # never hide a nonzero hour
              k=eig-(r-1)*8; if(k<0)k=0; if(k>8)k=8
              printf "%s%s ", B[k+1], B[k+1]
            }
            printf "\n"
          }
          printf "%*s ┼", w, 0
          for (h=gminh; h<=gmaxh; h++) printf "───"
          printf "\n\n"
        }
      }'
    return
  fi

  {
    (( tsv )) || print 'DATE\tFIRST\tLAST\tSPAN_HOURS\tSAMPLES'
    # bucket by day → earliest/latest (HH:MM sorts lexically), span, sample count
    _workday_samples | awk -F'\t' '
      $2 ~ /^[0-9][0-9]:/ { d=$1; t=$2; n[d]++
        if ((d in f)==0 || t<f[d]) f[d]=t
        if ((d in l)==0 || t>l[d]) l[d]=t }
      END { for (d in f) {
              split(f[d],a,":"); split(l[d],b,":")
              span=((b[1]*60+b[2])-(a[1]*60+a[2]))/60
              printf "%s\t%s\t%s\t%.1f\t%d\n", d, f[d], l[d], span, n[d]
      } }' | sort
  } | if (( tsv )); then cat; else column -t -s $'\t'; fi
}
