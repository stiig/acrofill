# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.1] - 2026-07-27

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
- `Acrofill.new(path, flatten: true)` now applies that option to every
  `#fill_form` call, matching the `PdfForms.new` shape it mirrors. Options
  given to the constructor were accepted and discarded, so the drop-in path
  shipped interactive documents where flattened ones were asked for.
- `Template#fill_form` refuses a destination equal to its own source instead
  of overwriting the template in place. The argument order is the reverse of
  `Filler#fill_form`, and since `Template` never re-reads the file the
  corruption stayed invisible for the life of the process.
- A widget whose `/Rect` is inherited from its parent field is now stamped
  when flattening. The value was filled, then dropped from the output.
- Fields sharing one fully-qualified name but not one `/FT` are each filled
  through their own type's path. A checkbox sharing a name with a text field
  had its `/AP` state dictionary overwritten with a text appearance.
- Checkbox values are matched case-insensitively, so `"off"`, `"No"` and `0`
  uncheck rather than falling through and ticking the box. A state the
  template itself names still wins.
- Field names that are neither UTF-16BE nor UTF-8 are decoded rather than
  scrubbed. Every accented byte became U+FFFD, renaming the field to
  something no caller could pass back in.
- Glyph widths are measured in the font's own code space, so a `/Encoding`
  that moves a glyph onto a code below 32 measures that glyph instead of
  charging the average width. Multiline wrapping likewise runs before
  encoding, so a font that moves the space glyph off code 32 still wraps.
- Font names are no longer read as width classes by substring alone:
  `MonotypeCorsiva` is proportional, `Blackadder-ITC` is not bold, while
  `Arial-Black` and `CourierNewPSMT` still classify as before.
- `/DA` colour operands on opposite sides of the `Tf` triple are no longer
  joined, which could fuse tokens that were never adjacent into a valid
  looking operator and repaint the value.
- A negative `/DA` size is treated as "fit the box", like zero, instead of
  rendering at the 2pt floor on single-line fields but 12pt on multiline.
- Flattening drops an annotation reference that resolves to nothing (it
  serialized as a bare `null` in `/Annots`), honours an indirect `/Subtype`,
  refuses a degenerate `/Rect` that would produce a singular matrix, and
  survives a `/Matrix` whose finite entries multiply out of range.
- A `/DR` font entry that is not a font dictionary no longer reaches the
  generated appearance's `/Resources`, where it left `/Tf` pointing at a
  non-font object.
- A page's `/Resources` reached through `/Parent` is copied before the stamp
  `/XObject` is added, so pages sharing that node are left alone.
- `File.binwrite` failures surface as `Acrofill::Error`, the error the public
  API documents, rather than a bare `Errno`.

### Changed

- `Acrofill::Metrics` exposes `.remap_for` (the `/Differences` code table)
  and `Metrics::Font#width_of`; `Acrofill::Document` exposes
  `#normalized_box`. These replace private copies that `Fonts`, `Appearance`
  and `Flattener` each carried.
- `Metrics.string_width` takes a 256-entry code-space table (from the new
  `Metrics.build_font`) rather than a `/Widths`-shaped one indexed from code
  32. Passing a `BaseFont` name still works.
- The release workflow runs the specs and RuboCop before publishing; a tag
  push matched no trigger in the CI workflow, so the gem could be pushed
  with no test run behind it.

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

[Unreleased]: https://github.com/stiig/acrofill/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/stiig/acrofill/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/stiig/acrofill/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/stiig/acrofill/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/stiig/acrofill/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/stiig/acrofill/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/stiig/acrofill/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/stiig/acrofill/releases/tag/v0.1.0
