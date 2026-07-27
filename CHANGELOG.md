# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- A `/Rect` or `/BBox` whose corners are not four finite numbers, or whose
  width or height overflows, is now refused as unusable geometry (no
  appearance, `/AP` dropped) rather than laid out against. Subtracting two
  infinite corners produced a NaN extent that every `<= 0` guard silently
  passed, so the widget either raised `ArgumentError` out of
  `Acrofill.fill_form` or was drawn into a box that serialized to
  `[0 0 0 0]` — blank, while `/V` already held the new value.
- A non-finite `/Matrix` on an appearance stream is treated as the identity,
  the way a missing or otherwise malformed one already was. Flattening a
  widget whose form XObject carried one raised `ArgumentError`.
- A non-finite point size in a `/DA` string degrades to "fit the box", the
  way a `/DA` with no size already does, rather than raising. A finite but
  enormous one no longer overflows while being scaled down to fit.

### Changed

- `Acrofill::Metrics` exposes `.remap_for` (the `/Differences` code table)
  and `Metrics::Font#width_of`; `Acrofill::Document` exposes
  `#normalized_box`. These replace private copies that `Fonts`, `Appearance`
  and `Flattener` each carried.

## [0.4.0] - 2026-07-27

### Added

- Comb fields (`/Ff` bit 25 with `/MaxLen`) lay each character out centered
  in its own cell, `/Q` choosing which run of cells the value occupies,
  matching pdftk cell for cell. They previously rendered as plain text.

### Fixed

- A value is now written in the codes its font actually draws it with. A
  `/DR` font whose `/Encoding` carries a `/Differences` array moves glyphs
  to other codes; writing the raw bytes drew whatever glyph happened to sit
  there — a font mapping "A" to code 90 rendered "AZ" as "ZA". Widths
  follow the emitted code, so measurement and rendering stay in step.

### Changed

- Flattening no longer stamps widgets a viewer would not display: `/F`
  Hidden (bit 2) was already dropped, and NoView (bit 6, "not on screen",
  PDF 32000 §12.5.3) now is too. pdftk stamps both, but burning in a
  widget the template author concealed makes hidden values permanently
  visible, so parity loses here. Widgets that are merely non-printing are
  still stamped: they are what the viewer shows.

## [0.3.0] - 2026-07-27

### Fixed

- Single-line baselines now match pdftk when the text is taller than the
  field, which real forms hit routinely (a 12pt `/DA` in a 10.8pt-high box
  is common). Centering is bounded on both sides: the ascender is kept
  inside the box and the baseline never drops below the box floor. This was
  the last geometry difference on a 551-field sample of real templates.
- Text is now measured with the metrics of the font it is actually drawn
  with. A template that embeds its own face declares `/Widths` and a
  `/FontDescriptor`, and those were ignored in favour of standard-14
  tables — which put centered and right-aligned values as much as tens of
  points away from where pdftk puts them (43pt on a 300pt-wide field in
  one measured case). `/Widths` now drives glyph widths, `/FontDescriptor`
  `/Ascent` the baseline and its `/FontBBox` the multiline row spacing,
  falling back to the standard-14 tables only when the dictionary is
  silent. This is the layout most real-world forms hit, since almost all
  of them embed a subset face.

### Changed

- Vertical geometry is now font-aware and matches pdftk-java 3.3.3 exactly.
  Baselines are placed from the font's own AFM ascender instead of a fixed
  Helvetica value (Times sat 0.18pt low, Courier 0.45pt), and multiline rows
  are spaced by the font's `FontBBox` extent with pdftk's 1pt top offset
  instead of a flat `1.15 * size` leading.
- `Acrofill::Metrics` exposes `.font_for`, returning widths plus ascender,
  descender and `FontBBox` for one of the twelve standard-14 text cuts.
  Vertical metrics are stored per cut, since Courier-Bold and Times-Italic
  differ there even where their widths do not.
- Font resolution moved out of `Appearance` into `Acrofill::Fonts`, which
  owns the `/DR /Font` dictionary: metrics for a `/DA` resource name and
  the reference a generated appearance points at.

### Added

- `benchmark/geometry_diff.rb` compares acrofill's appearance streams with
  pdftk's field by field on your own templates.
- `spec/pdftk_parity_spec.rb` pins alignment, baseline and multiline row
  geometry — for standard-14 faces, template-supplied metrics, and text
  taller than its field — to numbers measured from pdftk's own output.

### Known differences from pdftk

- Auto-sized fields (`0 Tf`): pdftk picks a font-dependent size that fills
  the box (16.33pt in a 20pt box for Helvetica, and 20.73pt — taller than
  the box — for Courier), with a hard 4pt floor. Acrofill keeps its own
  `min(height * 0.66, 12pt)` and is not going to reproduce that.
- Values too wide for the field: acrofill shrinks the font to fit, pdftk
  keeps the size and clips.
- Non-ASCII values: pdftk writes UTF-8 bytes into a `/WinAnsiEncoding`
  font, which renders as mojibake; acrofill writes Windows-1252, so the
  text is correct and the measured width differs accordingly.

## [0.2.0] - 2026-07-27

### Fixed

- Pages whose `/Type` entry is missing are no longer skipped: flattening
  such a document silently produced an unflattened file.
- A widget whose appearance cannot be regenerated (degenerate `/Rect`)
  now has its `/AP` dropped instead of keeping the appearance of the
  *previous* value while `/V` already holds the new one.
- A page `/Resources` or `/Resources /XObject` that is not a dictionary
  no longer raises `TypeError` while flattening, and a `/Root` that is
  missing or not a dictionary raises `Acrofill::Error` instead of
  `NoMethodError`.
- Filling a field whose fully-qualified name is shared by several field
  dictionaries no longer depends on the return value of the first fill.

### Changed

- Text metrics now cover all standard-14 text cuts (Times bold/italic,
  the Courier family, the oblique Helvetica cuts) over the full
  WinAnsiEncoding range instead of ASCII-only Helvetica/Courier/
  Times-Roman, so accented characters and bold or serif faces are
  measured rather than approximated. Widths are WinAnsi-correct: `'`
  measured 222 (StandardEncoding `quoteright`) where appearances
  actually emit `quotesingle`.
- Unknown `/BaseFont` names (`ArialMT`, `TimesNewRomanPS-BoldMT`, subset
  faces) are classified by family and weight instead of all falling back
  to Helvetica.
- One fallback Helvetica font object is now shared by every generated
  appearance; a 50-field form previously wrote 50 identical font
  dictionaries.
- Flattening moved out of `Form` into its own `Acrofill::Flattener`.

## [0.1.2] - 2026-07-24

### Added

- Expanded regression coverage: `/Q 2` right alignment, per-line multiline
  centering, flatten geometry with a non-identity `/Matrix`, checkbox
  state stamping, pushbutton and signature fields, deep hierarchical
  names, reference-cycle guards, and `Template` snapshot isolation.
  No library code changes.

## [0.1.1] - 2026-07-24

### Fixed

- Parse failures from lazily materialized objects and parser stack
  overflows on deeply nested objects now raise `Acrofill::Error` instead
  of leaking `PDF::Reader::MalformedPDFError` or `SystemStackError`.
- The page-tree and field-tree walks are iterative, so deep linear
  `/Pages` or `/Kids` chains no longer overflow the stack.
- Indirect references are dereferenced where they were previously assumed
  direct: field `/V` in metadata, `/Rect` and `/BBox` corner values,
  `/Matrix` elements, and the `/Q` alignment value.
- A checkbox/radio whose on state is literally named `no` or `false` can
  now be checked: an exact state-name match takes precedence over the
  false-ish uncheck heuristic.

### Changed

- Single-line appearance baseline placement now matches pdftk exactly:
  `ty = (h - ascent * size) / 2`.
- Required Ruby version raised from `>= 3.0` to `>= 3.2` (3.0/3.1 are EOL
  and untested in CI).

## [0.1.0] - 2026-07-24

### Added

- Initial release: pure-Ruby AcroForm filling and flattening.
- Text fields (`/Tx`): hierarchical names, inherited `/DA`, `/Q` alignment,
  auto font size, shrink-to-fit, multiline word wrapping.
- Checkboxes and radio groups (`/Btn`) via `/V` + `/AS` state selection.
- Choice fields (`/Ch`).
- Flattening of visible widget appearances into page content.
- `Acrofill::Template` for parse-once, fill-many workloads.
- `PdfForms`-compatible entry points (`Acrofill.new`, `fill_form`, `fields`,
  `field_names`).

[Unreleased]: https://github.com/stiig/acrofill/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/stiig/acrofill/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/stiig/acrofill/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/stiig/acrofill/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/stiig/acrofill/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/stiig/acrofill/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/stiig/acrofill/releases/tag/v0.1.0
