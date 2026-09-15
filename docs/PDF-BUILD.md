# PDF Build Handoff — `bash-mastery-linux` Complete Documentation

How to regenerate `bash-mastery-linux-complete.pdf` from this repository, and
everything that is non-obvious about doing it. Written from the working build,
not from memory: every number below was measured on the shipped artifact.

This build deliberately shares its design system with `bash-mastery-devops`,
so the two documents look like one family. If you change the look here,
change it there too, or state plainly that they have diverged.

**Current artifact:** 168 A4 pages · dark full bleed · 91 clickable internal
links · 33 PDF bookmarks · 26 sections rendered from 26 files in the repo.

---

## 0. What the build is

One PDF containing the whole repository's prose: the root README, the
curriculum, the lab guide, all twenty day lessons, CONTRIBUTING, the
engineering handoff and the licence.

**Nothing in the PDF is hand-written.** Every section is rendered from a file
in the repo, and every number on the cover and in the per-day banners is
measured from the repo at build time. If a README changes, re-running the
build reproduces the PDF with the change in it. There is no manual copy to
keep in sync. Preserve this property — it is the whole point of the design.

There is no capstone in this curriculum, so there is no capstone section. The
back matter is CONTRIBUTING, the handoff and the licence.

---

## 1. Environment (verify it, do not trust it)

| Tool | State | Used for |
|---|---|---|
| `chromium` | present | HTML -> PDF (the renderer) |
| `pdftoppm`, `pdftotext`, `pdfinfo`, `pdffonts` (poppler) | present | rasterising + text extraction for QA |
| `pypdf` | present | page merge, outline, metadata |
| `reportlab` | present | dark backdrop + page numbers |
| `Pillow` | present | pixel QA |
| `weasyprint`, `wkhtmltopdf`, `pandoc` | absent | — |
| `markdown`, `mistune`, `pygments` | absent | — |

No network. `pip install` fails — and note that **pip exits 0 while printing
`ERROR: No matching distribution found`**, so its exit status is not
trustworthy. Verify a package by importing it, never by pip's return code.

Because `markdown` and `pygments` are missing, the markdown converter and the
bash highlighter are both hand-written here. That is deliberate.

### Path trap that will waste your time

`/data` is really `/vercel/sandbox/data`. Python is fine with `/data/...`, but
**external programs need the real path**:

- `PYTHONPATH=/data/pdfbuild` silently fails; `PYTHONPATH=/vercel/sandbox/data/pdfbuild` works.
- Chromium's `file://` URL and `--print-to-pdf` must use `/vercel/sandbox/data/...`.

### The sandbox is wiped without warning

This working directory has been lost sixteen times mid-task. Two consequences:

- Keep the nine scripts small and regenerable, and re-read this document
  before rebuilding rather than trusting a remembered detail.
- A released PDF is enough on its own for text QA and outline repair (§11), so
  keep the delivered file, not just the sources.

---

## 2. Files

All under `/data/pdfbuild/`.

| File | Role |
|---|---|
| `hl.py` | bash / ini / yaml / output highlighter; `COLORS` is the palette source of truth |
| `md.py` | markdown -> HTML, including repo-link -> in-PDF anchor resolution |
| `template.py` | the entire CSS design system (`BASE_CSS`) |
| `build.py` | section table, cover, contents, phase pages -> `doc.html` |
| `pagemap.py` | resolves each section -> its real printed page |
| `stamp.py` | dark backdrop, page numbers, bookmark tree, metadata |
| `qa.py` | the gate. Must print `QA PASSED` |
| `colour_audit.py` | palette coverage measurement at 150 dpi |
| `edge_check.py` | full-bleed verification |

Generated: `doc.html`, `out.pdf` (Chromium output), `pagemap.json`,
`pagemap.prev`, `bash-mastery-linux-complete.pdf`, `qa.log`.

`build.py` sets the repo root:

    REPO = "/data/final/bash-mastery-linux"

Point that at the current checkout. It is the only path that changes between runs.

---

## 3. The pipeline, and why it runs twice

    build.py     26 markdown sources          -> doc.html
    chromium     doc.html                     -> out.pdf
    pagemap.py   out.pdf                      -> pagemap.json
    build.py     pagemap.json                 -> doc.html  (contents now has real page numbers)
    chromium     doc.html                     -> out.pdf
    stamp.py     out.pdf + pagemap.json       -> bash-mastery-linux-complete.pdf
    qa.py        final PDF                    -> QA PASSED / QA FAILED

**Why two passes.** The contents page has to print real page numbers, but page
numbers only exist after layout. Render once without them, read where every
section actually landed, then render again with those numbers baked in.

Writing the numbers in can itself change pagination, so the loop repeats until
`pagemap.json` matches the previous pass and prints `pagemap: STABLE`. In
practice it converges on iteration 2. If it never settles, something is
oscillating; do not ship it.

### How page numbers are resolved

Each section prints its repo-relative source path in a small monospace line
under its heading (`.srcpath`, e.g. `days/day07/README.md`). `pagemap.py`
extracts text per page and looks for that marker. Two rules are load bearing
and both were learned the hard way:

1. **The marker must appear within the first 220 whitespace-squeezed
   characters of the page.** Day prose mentions `docs/HANDOFF.md` in passing;
   without the top-of-page rule the handoff resolved to page 37 instead of its
   real opener, and the contents printed that wrong number.
2. **Sections resolve in document order**, with the floor set just below the
   previous hit. A resolver that scans the whole document per section will
   happily match backwards.

Phase dividers have no repo file of their own, so they print the untransformed
marker `docs/curriculum.md#phase-N`. Compare squeezed text: the CSS applies
`text-transform` and `letter-spacing`, so exact string matching against the
rendered page fails. That mistake produced `UNRESOLVED phase-1 .. phase-4`.

The marker is load bearing for the contents page, the bookmarks **and** the QA
gate. Do not remove the `.srcpath` line.

---

## 4. The section table

`build.py` defines `ALL_SECTIONS = FRONT + day_entries() + BACK` — 26 tuples of
`(anchor, repo-relative path, badge, editorial title or None, mode)`.

**FRONT**

    ('overview',   'README.md',          'Overview', 'Repository overview')
    ('curriculum', 'docs/curriculum.md', 'Map',      'Curriculum — twenty days')
    ('lab',        'lab/README.md',      'Lab',      'The lab')

**Days** — `day_entries()` generates `day01`..`day20` from
`days/dayNN/README.md`, badge `Day NN`, title taken from the file's own H1.

**BACK**

    ('contributing', 'CONTRIBUTING.md',   'Appendix', 'Contributing')
    ('handoff',      'docs/HANDOFF.md',   'Appendix', 'Engineering handoff')
    ('license',      'LICENSE',           'Appendix', 'License', 'plain')

**Front and back matter need those editorial titles.** Their H1s repeat the
project name, so without an override pages 1, 2, 4 and the licence opener all
printed `Bash Mastery: Linux` as their section title, and the QA check
"document title only on the cover" failed on four pages.

`LICENSE` uses `mode='plain'`: it is not markdown and is rendered as one
preformatted block.

**PHASES** — copied verbatim from `docs/curriculum.md`; they drive the four
dividers and the bookmark tree:

    Phase 1  The host                                    days 01-05
    Phase 2  The network                                 days 06-10
    Phase 3  Hardening and configuration management      days 11-15
    Phase 4  Production operations                       days 16-20

**Do not invent taglines or subtitles anywhere in this build.** Every string
either comes from a repo file or is a structural label like `Overview`.

### Numbers measured from the repo

`count_checks()` reads each `days/dayNN/verify.sh` and counts the repo's own
verify helpers:

- `vl_check` — automatic, affects the exit status → **179 total**
- `vl_manual` — judgement call, printed as `YOU` → **37 total**

Those two names are the contract. An earlier counter looked for `check ` and
`judge ` and silently returned zero for every day, because `\bcheck` does not
match inside `vl_check`. If a banner ever reads 0, suspect the regex before the
repo. The cover also prints 20 days, 125 `.sh` files and 3 machines, all
counted at build time.

Per-day counts, for reference: 01 4/1, 02 5/1, 03 4/2, 04 5/2, 05 5/2, 06 5/2,
07 5/2, 08 5/2, 09 5/2, 10 7/2, 11 5/1, 12 5/2, 13 7/2, 14 6/2, 15 9/2,
16 12/2, 17 19/2, 18 22/2, 19 22/2, 20 22/2.

### Cross-reference links

`PATH_TO_ANCHOR` maps every repo path to its anchor and `build_linkmap()`
expands each target into every spelling a markdown link might use — bare,
leading slash, `./`-prefixed, trailing slash, and the directory form for
`README.md`. `md.resolve_link()` also resolves relative links against the
linking file's directory, so `../day07/README.md` inside a day README becomes a
real in-PDF jump. This is where most of the 91 clickable links come from.

---

## 5. Design system (`template.py`)

This is the part that makes it look like the devops document. If you only read
one section before editing CSS, read this one.

### Page geometry

    @page { size: A4; margin: 14mm 0 16mm 0; }
    body  { padding: 0 15mm; }

Side margin is **0** in `@page`, and the 15mm side inset comes from `body`
padding instead. That is what keeps the sheet dark to the left and right edges
(§6). The vertical margin stays because it reserves the band the stamped page
number sits in.

### Palette (`hl.COLORS`)

| Token | Hex |
|---|---|
| comment | `#6b7280` *(italic)* |
| keyword | `#5E9FE8` |
| builtin | `#BF8EDA` |
| var | `#72BC8F` |
| string | `#DE9255` |
| number | `#AE81FF` |
| operator | `#E97366` |
| output | `#72BC8F` |

Surfaces: page `#191919`, panels `#202020` / `#141414`, inline code `#2a2a2a`,
rules `#2f2f2f` and `#262626`, body text `#e8e8e8`, muted `#9aa0a6`, faint
`#6b7280`, accent `#5E9FE8`.

**The CSS colour rules are generated from that dict**, so a class and its
colour cannot drift apart. `qa.py` asserts every `hl-*` class the highlighter
emits has a matching CSS rule. Keep both properties. Code is never
grey-on-grey; colourised code is a requirement of this document.

### The elements that carry the look

| Element | Rule |
|---|---|
| Section opener | badge pill (`#1d2a3b` on accent, uppercase, 7.4pt) inline with a 19pt white title, then a hairline rule, then the `.srcpath` marker |
| H2 inside a section | 12.4pt bold with an accent dot bullet (`h3::before`), never a full-width rule |
| H3 and below | 10.6pt bold, no bullet |
| Callouts | warm amber panel `#241d15` with a `#8a6a3a` left border — not a blue or grey box |
| Tables | no header fill; uppercase muted 7.4pt header with a rule under it, hairline row separators, transparent body |
| Key/value panels | a headerless markdown table renders as `table.meta`, first column muted |
| Code | `#202020` panel, 1px `#2f2f2f` border, 5px radius, 8.6pt/1.5 |
| Cover | gradient logo mark, brand line, 170px hero panel, accent eyebrow, 39pt title, four bordered stat cards, rule, chip row, repo name at the right |
| Contents | 19pt title + rule, accent uppercase group labels, mono day number, **dotted leader**, mono page number |
| Phase divider | vertically centred: accent kicker, 29pt title, day range, then that phase's five days with leaders |
| Per-day banner | `.daynote`, muted with an accent left border, printing the measured check counts |

Two details are easy to get wrong and both were wrong once here:

- Contents entries are links, so they inherit `a.xref` accent colour and print
  **blue**. `.toc-t` must override the colour back to `#e8e8e8`; only the group
  labels are accent coloured.
- Contents and phase rows already print the day number in the mono column, so
  strip the `Day NN —` prefix from the title (`build.short()`), or every line
  says it twice.

Body 10.5pt/1.6. Code 8.6pt/1.5. Tables 8.8pt. Mono stack
`Consolas, Menlo, Liberation Mono`.

---

## 6. Full bleed — the hard part

**Chromium paints the html/body background over the page *area* only.** Any
`@page` margin renders as white paper regardless of what the CSS says.

**Sides — CSS.** Zero the `@page` side margin and move the inset to `body`
padding so it repeats on every page.

**Top and bottom — not possible in CSS.** A `position: fixed` div with negative
offsets does not reach the vertical margins; Chromium clips fixed elements to
the page area. It looks plausible because a *small* negative offset does
render — that is the trap.

**Top and bottom — PDF level.** `stamp.py` paints a dark rectangle *underneath*
each rendered page; those margin bands are transparent, not white, in
Chromium's output, so the rectangle shows through:

    bg.setFillColorRGB(0x19/255.0, 0x19/255.0, 0x19/255.0)
    bg.rect(-2, -2, w + 4, h + 4, stroke=0, fill=1)
    page.merge_page(PdfReader(bgbuf).pages[0], over=False)

- **`over=False`** puts the fill underneath the content *and* keeps `page` as
  the base object, which preserves Chromium's link annotations. Merge the other
  way round and all 91 clickable links silently vanish.
- **The 2pt overscan.** An exact `w x h` rect leaves a hairline of bare paper:
  the page is 594.96 x 841.92 pt and rasterises to fractional pixels, so the
  final partial row falls outside the fill. Viewers clip to the mediabox, so
  painting past it is safe.

`edge_check.py` verifies this at 100 dpi and is wired into the gate. It
**ignores the outermost 1px ring**: `pdftoppm` blends the edge against its own
image padding, so that ring reads light even on a perfect PDF. A white sliver
at the right edge of a raster is almost always this artefact, not the PDF.

---

## 7. No running header or footer

Do not add a CSS running footer: Chromium does not reliably pin a fixed element
to the foot of a printed page, and it paints through the body text.

Render with **`--no-pdf-header-footer`**. The similarly named
`--print-to-pdf-no-header` is **silently ignored** by this Chromium; with it,
every page printed the date, the document `<title>`, the `file:///` source URL
and `41/187` in the margins. The symptom in QA was
`FAIL title only on the cover [1, 2, 3, ... 187]` — the check was right and the
flag was wrong. `qa.py` now also fails on any `file:///` in the text.

Page numbers are stamped onto the PDF in `stamp.py`, which is exact. CSS
`counter(page)` only works inside `@page` margin boxes, which Chromium does not
support.

---

## 8. Page numbers, outline, metadata (`stamp.py`)

- Page number: Helvetica 8pt, `RGB(0.50,0.50,0.50)`,
  `drawRightString(w - 42.5, 19.8, str(n))`. Skipped on the cover.
- Outline: `Cover`, `Contents`, the three FRONT sections, one parent per phase
  with its five days nested, then `Reference` with the three BACK sections
  nested. 33 entries.
- **Bookmark labels use the section title, never the badge.** Labelling from
  the kicker produced three back-matter entries all reading `Reference`, which
  makes the sidebar useless. `qa.py` now fails on duplicate labels and on
  kicker words used as labels.
- Metadata: `/Title`, `/Subject`, `/Author`, `/Creator`, `/Keywords`.

`Helvetica` is a standard-14 font and is not embedded; it is used only for the
page numbers. Everything else (Liberation Sans/Bold, Consolas, Noto Color
Emoji) is embedded and subset. That is acceptable, and `pdffonts` will show it.

---

## 9. Pagination control — what Chromium honours

| Rule | Works? |
|---|---|
| `break-before: page` (`.section`, `.toc`, `.phase`) | yes |
| `break-inside: avoid` (tables, code blocks, callouts) | yes |
| `break-after: avoid` (headings) | yes |
| `break-before: avoid` / `break-after: avoid` on a paragraph | **no — silently ignored** |

Long code blocks get `.code-wrap.tall { break-inside: auto; }` so they split
rather than leave a huge hole.

### The widow page — worked example

Day 06 ended with its one-line `Next up: Day 07 ...` paragraph alone on page
50 (9 words), which the gate caught as `FAIL no nearly-empty page [50]`.

Do not fix a thin page by writing prose into the PDF, and do not reach for
`break-before: avoid` — it is ignored. Measure instead: rasterise the previous
page and find the last content row. Page 49 ran to pixel 1140 of 1170, i.e.
**over** its content box, so the overflow was real and needed a few reclaimed
pixels, not a nudge. Tightening table cell padding from 5.5px to 4.5px
reclaims ~2px per row and took the document from 181 pages to 173 with no thin
pages. Scoped tightening of only the last table in a section is also available
(`.section > table:last-of-type`) when a global change is too blunt.

**Rasterise and measure before changing any CSS.** Every guess costs a full
rebuild.

---

## 10. The QA gate (`qa.py`)

Run it after every build. It exits non-zero and prints `QA FAILED` with a list.
Current clean run:

    pages: 168 · links: 91 · bookmarks: 33
    QA PASSED (168 pages, 33 bookmarks, 91 links)

**Hard failures**

- page count outside 90..210
- fewer than 25 internal links, fewer than 30 bookmarks
- duplicate bookmark labels, or a badge word used as a label
- any section not opening on the page `pagemap.json` claims (top-of-page match)
- any phase divider unresolved
- a back-matter contents line printing the wrong page (this caught
  `Engineering handoff 37` and `License 140` when the real pages were 129 and 173)
- any `dayNN` missing from the page map, or the CI day matrix incomplete
- any page after the cover with fewer than 12 words
- the document title printed on any page after the cover
- `file:///` anywhere in the text (Chromium header/footer leakage)
- NUL bytes in `doc.html`; raw ``` fences, raw `**`, or `{{` placeholders in the text
- a highlighter class with no CSS rule
- **missing look markup**: badges, contents leaders, cover stat cards, logo,
  hero, chips, phase dividers, xref style. This is what stops a silent
  regression back to the unstyled layout.
- a palette colour absent from the sampled pages, or any white page margin

**Also worth checking by eye:** the printed page count against the previous
run, since a layout regression that adds or drops a page still passes.

### Two guards that lied

- **The colour audit's sample lied.** A fixed nine-page sample from the front
  half reported `num` and `str` missing, which looks exactly like "code was
  never colourised". Measured across the document, `num` appears on 4 and `str`
  on 3 of 14 evenly spaced pages. `colour_audit.py` now samples with a stride of 5
  over the whole PDF; a stride of 12 still skipped every `num` page. `var` and `out` stay on the ignore list: this repo quotes
  everything, so `$VAR` sits inside a string token.
- **Low-dpi exact matching lies.** At 8.6pt nearly every glyph pixel is an
  antialiased blend, so exact RGB matching finds almost nothing. Sample at
  150 dpi with `TOL = 26`.

The pattern behind both: **when a check fails, verify the measurement before
changing the PDF** — and a check that goes quiet after an unrelated change is
equally suspicious. Also: a check must not measure a side effect of the checks
above it.

---

## 11. Repairing a released PDF without the repo

If the sandbox is wiped and only the delivered PDF survives, text QA and the
bookmark tree can still be fixed. `fix_outline.py` re-locates every section by
its `.srcpath` marker near the top of the page (the same rule as `pagemap.py`),
reads the day titles back out of the rendered pages, and rebuilds the outline:

    writer = PdfWriter(clone_from=PDF)
    del writer._root_object["/Outlines"]
    writer._outline = None
    # ... add_outline_item(...) again, then re-write metadata

Verify afterwards that the page count, the link count and the metadata are
unchanged — a clone that drops annotations is the usual failure.

---

## 12. Traps that cost real time

**Bold across a line break printed as `**`.** A list item wrapped over two
source lines was split into two items, so `**bold` and `bold**` never met. The
converter now takes lazy continuation lines into the same `<li>`. Any raw `**`
in `pdftotext` output means the block structure is wrong, not the emphasis
regex.

**Nested inline markdown -> NUL bytes.** `md.py` stashes code spans as
`\x00N\x00` placeholders before parsing emphasis. Bold-wrapping a code span
nests one placeholder inside another, so a single restore pass leaves raw NUL
bytes in the HTML — which zeroes every highlight count and makes `grep` report
`binary file matches`. Restore in a loop while `\x00` remains; `qa.py` fails on
any NUL byte.

**Measuring emptiness after going dark.** The thin-page heuristic must use text,
not dark pixels: once the sheet is dark edge to edge, a pixel-based check calls
*every* page empty, and while the margins were white it called them content.

**Tooling gotchas.** `computer.writeFile` rejects literal tabs and has
no-opped silently; `editFile` can report success while the change is absent —
re-grep. A python heredoc whose triple-quoted block ends with `"` raises
`SyntaxError: unterminated string literal`. Chromium prints harmless SODA and
dbus warnings; `pdftoppm` prints a harmless font-type mismatch warning.

**Never edit `doc.html` by hand.** It is generated; the next build overwrites it.

---

## 13. Reproduce end to end

    cd /data/pdfbuild
    export PYTHONPATH=/vercel/sandbox/data/pdfbuild

    render() {
      timeout 300 chromium --headless=new --no-sandbox --disable-gpu \
        --disable-dev-shm-usage --no-pdf-header-footer \
        --run-all-compositor-stages-before-draw --virtual-time-budget=60000 \
        --print-to-pdf=/vercel/sandbox/data/pdfbuild/out.pdf \
        "file:///vercel/sandbox/data/pdfbuild/doc.html"
    }

    rm -f pagemap.json pagemap.prev
    for i in 1 2 3 4; do
      cp -f pagemap.json pagemap.prev 2>/dev/null || true
      if [ -f pagemap.json ]; then python3 build.py pagemap.json; else python3 build.py; fi
      render
      python3 pagemap.py
      diff -q pagemap.json pagemap.prev >/dev/null 2>&1 && { echo STABLE; break; }
    done

    python3 stamp.py
    timeout 1800 python3 qa.py | tee qa.log

Expect `doc.html written: 26 sections, 179 auto / 37 judgement`,
`resolved 30/30`, `pagemap: STABLE (168 pages)`, `QA PASSED`.

---

## 14. Checklist before shipping

- [ ] `resolved 30/30` — no unresolved sections or phases
- [ ] page map `STABLE`
- [ ] `QA PASSED`, exit 0
- [ ] page count matches what you tell the reader
- [ ] `links: 91` — merge order in `stamp.py` is easy to break
- [ ] `edge check: worst light-pixel count 0`
- [ ] bookmark sidebar opened and read: 33 entries, no duplicates, days nested
- [ ] contents numbers spot-checked against the page map, **including the back matter**
- [ ] cover, contents, a phase divider and one day page rasterised and looked at
- [ ] `pdftotext` scanned for ``` , `**` , `](` , `&amp;` , `file:///` , `{{`
- [ ] `pdffonts`: everything embedded except Helvetica for the page numbers

**Never declare the build done without rasterising pages.** Text extraction
alone hid an overlapping footer for several builds.

### Released state

168 pages. Front matter 3 / 7 / 12. Phase openers 14, 42, 66, 91. Days 15, 20,
25, 30, 36, 43, 48, 53, 58, 62, 67, 72, 77, 82, 87, 92, 96, 101, 105, 111.
CONTRIBUTING 120, handoff 124, licence 168. Built from repo `d2b157f`
(155 tracked files, `docs/HANDOFF.md` 2398 lines).

---

## 15. Possible improvements

- Assert the page count in `qa.py` once the layout settles, instead of only
  printing it.
- The highlighter covers bash, ini, yaml and command output. Another language
  needs another `hl_*` function plus a palette entry.
- The cover chip list in `build.py CHIPS` is hand-maintained; everything else
  on the cover is measured.
- `stamp.py` and `build.py` both define `short()`. Collapse them if you touch
  either.
