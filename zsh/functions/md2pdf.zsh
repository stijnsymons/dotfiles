# md2pdf: Markdown → PDF with mermaid diagrams, images & tables.
# Uses pandoc + mermaid-filter (renders ```mermaid via headless Chrome) + typst engine.
md2pdf() {
  emulate -L zsh
  local in=$1
  if [[ -z $in || ! -f $in ]]; then
    print -u2 "usage: md2pdf <file.md> [out.pdf]"; return 1
  fi
  local out=${2:-${in:r}.pdf}
  # mermaid-filter's bundled puppeteer needs a real browser; point it at one.
  local chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  [[ -x $chrome ]] || { print -u2 "md2pdf: Google Chrome not found (needed for mermaid rendering)"; return 1 }
  # modern typst template (falls back to pandoc default if missing)
  local tmpl="$HOME/dotfiles/config/pandoc/modern.typ"
  local -a targs; [[ -f $tmpl ]] && targs=(--template "$tmpl")
  PUPPETEER_EXECUTABLE_PATH=$chrome \
    pandoc "$in" --filter mermaid-filter --pdf-engine=typst "${targs[@]}" -o "$out" && print "→ $out"
  rm -f mermaid-filter.err   # stray log mermaid-filter drops in cwd
}
