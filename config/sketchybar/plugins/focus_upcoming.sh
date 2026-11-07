#!/usr/bin/env bash
# The Focus layer of the Productive timer widget: a checklist section of this ISO
# week's Focus note in Obsidian, shared by the sketchybar panel and the herdr.app
# mod so both show (and tick) the same lines. The section defaults to "## Upcoming"
# but any heading works, so the same engine drives "Upcoming", "Actions" and
# "Past actions" (the renderers call it once per section).
#
#   focus_upcoming.sh [section] [week]                     print {week,path,section,missing,items:[...]}
#   focus_upcoming.sh toggle <line> <raw> [section] [week] flip [ ] <-> [x] on that item
#
#   section  heading title (default "Upcoming"), matched at any level, case-insensitive
#   week     YYYY-Www (default: this week, or $FOCUS_WEEK) - the switcher passes other weeks here
#   line     1-based file line number (what the UI got from the listing)
#   raw      the line exactly as listed, minus the line ending; also the staleness check
#   missing  null | "note" | "section" - UI shows "No Focus note for <week>" when set
#
# Seams: FOCUS_NOTE=<file> (test a fixture), FOCUS_WEEK=<YYYY-Www>, FOCUS_DIR,
# FOCUS_SECTION=<title> (default for the section when no positional one is given).
#
# The note lives on Google Drive and Obsidian edits it at the same time as we do,
# so a click carries the line's text, not just its number: the toggle only writes
# where that text still is (same line, else the one unique line equal to it in the
# section) and refuses otherwise - ticking the wrong task is worse than a no-op.
# The write is a temp file in the same dir + mv, so Drive never syncs a half file,
# and perl works on bytes so a CRLF note or a missing final newline survives.
#
# Items are "- [ ]", "+ [ ]" (and "* [ ]") lines under the section heading up to the
# next heading. Exit codes of toggle: 0 toggled, 1 stale/ambiguous/missing, 2 usage.

set -u
# A positional week (2nd arg when listing, 5th when toggling) overrides $FOCUS_WEEK;
# the week switcher passes it so the whole note points at the chosen week.
if [ "${1:-}" = toggle ]; then WEEK_ARG="${5:-}"; else WEEK_ARG="${2:-}"; fi
WEEK="${WEEK_ARG:-${FOCUS_WEEK:-$(date +%G-W%V)}}"
DIR="${FOCUS_DIR:-$HOME/Library/CloudStorage/GoogleDrive-ssymons@gmail.com/My Drive/Thoughts/Notes}"
NOTE="${FOCUS_NOTE:-$DIR/$WEEK.md}"

# Shared by both halves: the section walk. Prints "<line>\t<raw>" per item;
# raw has no \r. Exit 3 when there is no heading matching $SEC.
items() {
  SEC="$SECTION" perl -ne '
    s/\r?\n\z//;
    if (/^#{1,6}\s+\Q$ENV{SEC}\E\s*$/i) { $in = 1; $seen = 1; next }
    if ($in && /^#{1,6}\s/) { $in = 0 }   # a heading, not a "#tag" line
    print "$.\t$_\n" if $in && /^[-+*] \[[ xX]\] /;
    END { exit($seen ? 0 : 3) }' "$NOTE"
}

if [ "${1:-}" = toggle ]; then
  { [ $# -ge 3 ] && [ $# -le 5 ]; } || { echo "usage: $0 toggle <line> <raw> [section] [week]" >&2; exit 2; }
  SECTION="${4:-${FOCUS_SECTION:-Upcoming}}"
  [ -f "$NOTE" ] || exit 1
  TMP="$(mktemp "$NOTE.XXXXXX")" || exit 1
  # Candidates are items whose raw equals the one clicked; the clicked line wins
  # if it is one, else a single candidate, else nothing is written.
  if OUT="$(LINE="$2" RAW="$3" SEC="$SECTION" perl -e '
      undef $/; open my $f, "<:raw", $ARGV[0] or exit 1; my $t = <$f>; close $f;
      my @l = split /(?<=\n)/, $t; my ($in, @c);
      for my $i (0 .. $#l) {
        (my $s = $l[$i]) =~ s/\r?\n\z//;
        if ($s =~ /^#{1,6}\s+\Q$ENV{SEC}\E\s*$/i) { $in = 1; next }
        $in = 0 if $in && $s =~ /^#{1,6}\s/;
        push @c, $i if $in && $s =~ /^[-+*] \[[ xX]\] / && $s eq $ENV{RAW};
      }
      # The clicked line already holds this text in the other state: someone (Obsidian) ticked it first.
      # Falling back to an identical twin elsewhere would tick the wrong task, so refuse.
      if (defined(my $cl = $l[$ENV{LINE} - 1])) { (my $x = $cl) =~ s/\r?\n\z//; (my $y = $ENV{RAW}) =~ s/^(. \[)([ xX])/$1 . ($2 eq " " ? "x" : " ")/e; exit 1 if $x eq $y; }
      my $at = (grep { $_ == $ENV{LINE} - 1 } @c) ? $ENV{LINE} - 1 : (@c == 1 ? $c[0] : -1);
      exit 1 if $at < 0;
      $l[$at] =~ s/^([-+*] \[)([ xX])(\])/$1 . ($2 eq " " ? "x" : " ") . $3/e;
      open my $o, ">:raw", $ARGV[1] or exit 1; print $o @l; close $o or exit 1;
      my ($n) = $l[$at] =~ /^[-+*] \[(.)\]/; print $n eq "x" ? "checked\n" : "unchecked\n";
    ' "$NOTE" "$TMP")"; then
    # Keep the note's mode (mktemp is 0600), then swap it in.
    chmod "$(stat -f %Lp "$NOTE")" "$TMP" && mv "$TMP" "$NOTE" && echo "$OUT" && exit 0
  fi
  rm -f "$TMP"; exit 1
fi

SECTION="${1:-${FOCUS_SECTION:-Upcoming}}"
if [ ! -f "$NOTE" ]; then
  jq -n --arg w "$WEEK" --arg p "$NOTE" --arg s "$SECTION" '{week:$w,path:$p,section:$s,missing:"note",items:[]}'; exit 0
fi
MISSING=null
ITEMS="$(items)" || MISSING='"section"'
# raw -> checked + display text: marker dropped, [[a|b]] -> b, [[a]] -> a, **x** -> x.
printf '%s' "$ITEMS" | jq -Rn --arg w "$WEEK" --arg p "$NOTE" --arg s "$SECTION" --argjson m "$MISSING" '
  {week:$w, path:$p, section:$s, missing:$m, items:[inputs | select(length>0) | capture("^(?<line>[0-9]+)\t(?<raw>.*)$")
    | {line:(.line|tonumber), checked:(.raw|test("^. \\[[xX]\\]")), raw,
       text:(.raw | sub("^[-+*] \\[.\\] +";"") | gsub("\\[\\[(?<t>[^\\]|]*\\|)?(?<a>[^\\]]*)\\]\\]";.a) | gsub("\\*\\*(?<b>.*?)\\*\\*";.b))}]}'
