#!/usr/bin/env bash
# Shared CPU / memory readings for the cpu+mem items and their card.
#
# The item used to sample with `top -l 2 -n 0 -s 1`, which sleeps a second
# between the two samples: 1.70s wall / 0.68s CPU per call on a 10s tick, the
# single most expensive recurring subprocess in the config. Its own card never
# paid that - it summed `ps` instead, ~24ms - so the two could and did disagree
# about the same number. One definition here, used by both, so they agree by
# construction.
#
# The trade is real but small: ps reports each process's decayed average rather
# than an instantaneous delta, so the reading lags a burst by a few seconds.
# That is the reading the card has always shown.
#
# Sourced, not executed. Nothing else needs to be sourced first.

# Memoised per run, not across ticks: every tick is a fresh process, so this
# only saves the second sysctl when one script calls cpu_pct twice. Export it
# from the environment to skip the spawn entirely.
SYS_NCPU="${SYS_NCPU:-}"

# cpu_pct -> whole-number percent of total CPU capacity in use
cpu_pct() {
  [ -n "$SYS_NCPU" ] || SYS_NCPU="$(sysctl -n hw.ncpu 2>/dev/null)"
  case "$SYS_NCPU" in ''|*[!0-9]*|0) SYS_NCPU=1 ;; esac
  # ps counts per-core, so a fully loaded 10-core machine sums to ~1000. Capped
  # at 100: over-100% is meaningless in a percentage label, and check.sh asserts
  # the 0-100 range.
  #
  # No rows means ps failed, not that the machine is idle - print nothing, so a
  # broken sample reads as absent rather than as a confident 0%.
  ps -A -o %cpu= | awk -v n="$SYS_NCPU" '{s+=$1} END {if (NR==0) exit 1; p=s/n; if (p>100) p=100; printf "%.0f", p}'
}

# mem_pct -> whole-number percent of memory in use.
# memory_pressure reports free %, so used = 100 - free.
mem_pct() {
  memory_pressure 2>/dev/null | awk '/free percentage/ {gsub("%","",$NF); printf "%.0f", 100-$NF}'
}
