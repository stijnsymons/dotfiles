# md2pdf: Markdown → PDF with mermaid diagrams, images & tables.
# Uses pandoc + mermaid-filter (renders ```mermaid via headless Chrome) + typst engine.
#   md2pdf <file.md> [out.pdf]        November Five branded theme (default)
#   md2pdf -c|--clean <file.md> …     clean/neutral theme
md2pdf() {
  emulate -L zsh
  local clean=0
  local -a pos
  local a
  for a in "$@"; do
    case $a in
      -c|--clean) clean=1 ;;
      *) pos+=("$a") ;;
    esac
  done
  local in=${pos[1]}
  if [[ -z $in || ! -f $in ]]; then
    print -u2 "usage: md2pdf [-c|--clean] <file.md> [out.pdf]"; return 1
  fi
  local out=${pos[2]:-${in:r}.pdf}
  # mermaid-filter's bundled puppeteer needs a real browser; point it at one.
  local chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  [[ -x $chrome ]] || { print -u2 "md2pdf: Google Chrome not found (needed for mermaid rendering)"; return 1 }
  # theme: N5-branded by default, neutral with --clean (falls back to pandoc default if missing)
  local tmpl="$HOME/dotfiles/config/pandoc/$( (( clean )) && print modern.typ || print novemberfive.typ )"
  local -a targs; [[ -f $tmpl ]] && targs=(--template "$tmpl")
  # Reconcile GitHub-style anchors with pandoc heading ids so typst doesn't
  # abort on internal links (e.g. GitHub drops '.' from #...-file.md anchors).
  local lua="$HOME/dotfiles/config/pandoc/fix-internal-links.lua"
  local -a largs; [[ -f $lua ]] && largs=(--lua-filter "$lua")
  PUPPETEER_EXECUTABLE_PATH=$chrome \
    pandoc "$in" --filter mermaid-filter "${largs[@]}" --pdf-engine=typst "${targs[@]}" -o "$out" && print "→ $out"
  rm -f mermaid-filter.err   # stray log mermaid-filter drops in cwd
}
