// Modern, simple pandoc → typst template for md2pdf.
// Replaces pandoc's default (Computer-Modern / LaTeX-y) look with a clean,
// contemporary document: humanist serif body, sans headings, light tables.

#let horizontalrule = align(center)[#line(length: 40%, stroke: 0.5pt + luma(190))]

// keep the bits pandoc's rendered body relies on
#show terms.item: it => block(breakable: false)[
  #text(weight: "bold")[#it.term] #block(inset: (left: 1.5em, top: -0.4em))[#it.description]
]
#show figure.where(kind: table): set figure.caption(position: top)
#show figure.where(kind: image): set figure.caption(position: bottom)

$if(highlighting-definitions)$
$highlighting-definitions$
$endif$

// ---------------------------------------------------------------- palette ---
#let ink   = rgb("#1f2933")   // body text
#let brand = rgb("#16324f")   // headings / accents
#let rule  = rgb("#e2e6ea")   // hairlines
#let soft  = rgb("#f6f8fa")   // block fills

// ------------------------------------------------------- page & typography ---
#set page(paper: "a4", margin: (x: 2.2cm, top: 2cm, bottom: 2cm), numbering: "1")
#set text(font: "Charter", size: 10.5pt, fill: ink,
          lang: "$if(lang)$$lang$$else$en$endif$")
#set par(leading: 0.72em, spacing: 1.15em, justify: false)
#show link: set text(fill: rgb("#2563eb"))

// headings: sans, restrained accent, comfortable rhythm
#show heading: set text(font: "Helvetica Neue", fill: brand)
#show heading.where(level: 2): set block(above: 1.5em, below: 0.6em)
#show heading.where(level: 3): set block(above: 1.2em, below: 0.5em)
#show heading.where(level: 1): it => block(above: 0.2em, below: 0.9em)[
  #text(size: 19pt, weight: "bold")[#it.body]
  #v(-0.35em)
  #line(length: 100%, stroke: 0.7pt + brand)
]
#show heading.where(level: 2): set text(size: 14pt, weight: "bold")
#show heading.where(level: 3): set text(size: 11.5pt, weight: "bold")

// blockquotes: soft panel with an accent edge
#show quote.where(block: true): it => block(
  width: 100%, fill: soft, radius: 3pt,
  inset: (left: 1em, rest: 0.7em), stroke: (left: 2.5pt + brand),
)[#it.body]

// code: subtle background, mono
#show raw: set text(font: "Menlo", size: 9pt)
#show raw.where(block: false): box.with(fill: rgb("#eef1f4"), inset: (x: 3pt), outset: (y: 3pt), radius: 2pt)
#show raw.where(block: true): block.with(fill: soft, inset: 10pt, radius: 3pt, width: 100%)

// tables: hairline rows, quiet header band
#set table(
  inset: (x: 8pt, y: 6pt),
  stroke: (_, y) => (bottom: 0.4pt + rule),
  fill: (_, y) => if y == 0 { rgb("#eef2f6") },
)
#show table.cell.where(y: 0): set text(weight: "bold", fill: brand)

// --------------------------------------------------------- title / status ---
$if(status)$
#align(right)[#box(fill: rgb("#fde68a"), inset: (x: 7pt, y: 2pt), radius: 3pt)[
  #text(font: "Helvetica Neue", size: 8pt, weight: "bold", fill: rgb("#7c5e10"))[$status$]
]]
$endif$
$if(title)$
#block(below: 0.6em)[#text(font: "Helvetica Neue", size: 22pt, weight: "bold", fill: brand)[$title$]]
$endif$
$if(date)$
#text(size: 9pt, fill: luma(120))[$date$]
#v(0.5em)
$endif$

$body$
