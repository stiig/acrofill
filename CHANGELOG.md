# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/stiig/acrofill/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/stiig/acrofill/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/stiig/acrofill/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/stiig/acrofill/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/stiig/acrofill/releases/tag/v0.1.0
