# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/stiig/acrofill/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/stiig/acrofill/releases/tag/v0.1.0
