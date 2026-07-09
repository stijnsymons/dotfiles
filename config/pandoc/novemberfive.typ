// November Five branded pandoc → typst template for md2pdf (default theme).
// Palette + type mirror novemberfive.co: Space Grotesk headings, Inter body,
// DM Mono code, signature red accent on near-black / off-white.

#let horizontalrule = align(center)[#line(length: 40%, stroke: 0.5pt + rgb("#d8d8d8"))]

// keep the bits pandoc's rendered body relies on
#show terms.item: it => block(breakable: false)[
  #text(weight: "bold")[#it.term] #block(inset: (left: 1.5em, top: -0.4em))[#it.description]
]
#show figure.where(kind: table): set figure.caption(position: top)
#show figure.where(kind: image): set figure.caption(position: bottom)
// figures (incl. pandoc-wrapped tables) must break so long tables flow across pages
#show figure: set block(breakable: true)

$if(highlighting-definitions)$
$highlighting-definitions$
$endif$

// ---------------------------------------------------------------- palette ---
#let ink   = rgb("#141414")   // body text / headings
#let brand = rgb("#ff4545")   // signature N5 red
#let rule  = rgb("#ededed")   // hairlines
#let soft  = rgb("#f5f5f7")   // block fills

// ------------------------------------------------------- page & typography ---
#set page(paper: "a4", margin: (x: 2.2cm, top: 2cm, bottom: 2cm), numbering: "1")
#set text(font: "Inter", size: 10pt, fill: ink,
          lang: "$if(lang)$$lang$$else$en$endif$")
#set par(leading: 0.7em, spacing: 1.1em, justify: false)
#show link: set text(fill: brand)

// headings: Space Grotesk, near-black, red accent under H1
#show heading: set text(font: "Space Grotesk", fill: ink)
#show heading.where(level: 2): set block(above: 1.5em, below: 0.6em)
#show heading.where(level: 3): set block(above: 1.2em, below: 0.5em)
#show heading.where(level: 1): it => block(above: 0.2em, below: 0.9em)[
  #text(size: 20pt, weight: "bold")[#it.body]
  #v(-0.3em)
  #line(length: 100%, stroke: 1pt + brand)
]
#show heading.where(level: 2): set text(size: 14pt, weight: "bold")
#show heading.where(level: 3): set text(size: 11.5pt, weight: "medium")

// blockquotes: soft panel with the red edge
#show quote.where(block: true): it => block(
  width: 100%, fill: soft, radius: 3pt,
  inset: (left: 1em, rest: 0.7em), stroke: (left: 2.5pt + brand),
)[#it.body]

// code: DM Mono. Inline is a breakable chip with zero-width breaks so long
// SNAKE_CASE.identifiers wrap inside table cells instead of overprinting.
#show raw: set text(font: "DM Mono", size: 8.5pt)
#show raw.where(block: false): it => {
  let s = it.text
  for c in (".", "_", "-", "/") { s = s.replace(c, c + "\u{200B}") }
  highlight(fill: soft, radius: 2pt, extent: 1.5pt,
            text(font: "DM Mono", size: 0.88em, s))
}
#show raw.where(block: true): block.with(fill: soft, inset: 10pt, radius: 3pt, width: 100%)

// tables: quiet header band with a red underline accent, hairline rows
#set table(
  inset: (x: 8pt, y: 6pt),
  stroke: (_, y) => if y == 0 { (bottom: 1pt + brand) } else { (bottom: 0.4pt + rule) },
  fill: (_, y) => if y == 0 { soft },
)
#show table.cell.where(y: 0): set text(font: "Space Grotesk", weight: "bold", fill: ink)

// --------------------------------------------------------- title / status ---
$if(status)$
#align(right)[#box(fill: rgb("#fff4f5"), inset: (x: 7pt, y: 3pt), radius: 3pt)[
  #text(font: "Space Grotesk", size: 8pt, weight: "bold", fill: brand)[$status$]
]]
$endif$
$if(title)$
#block(below: 0.6em)[#text(font: "Space Grotesk", size: 24pt, weight: "bold", fill: ink)[$title$]]
$endif$
$if(date)$
#text(size: 9pt, fill: rgb("#14141480"))[$date$]
#v(0.5em)
$endif$

$body$
