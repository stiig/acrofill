# Acrofill

Pure-Ruby PDF form (AcroForm) filling and flattening. No pdftk, no Java,
no native extensions — drop it into any Ruby or Rails project and fill
PDF templates in-process.

```ruby
Acrofill.fill_form('template.pdf', 'out.pdf',
                   { 'Full Name' => 'Jane Roe', 'agree' => 'Yes' },
                   flatten: true)
```

Parsing is delegated to [pdf-reader](https://github.com/yob/pdf-reader)
(MIT), which handles classic and cross-reference-stream PDFs, object
streams, and every standard filter. Acrofill adds the write side: field
value setting, appearance-stream generation, checkbox/radio state
selection, flattening, and a full document serializer.

## Why

The usual Ruby answer to "fill this PDF form" is the `pdf-forms` gem,
which shells out to [pdftk](https://gitlab.com/pdftk-java/pdftk) — a
Java application you must install on every machine and container, and
pay a JVM start-up for on every call. The main in-process alternative,
HexaPDF, is AGPL/commercial. Acrofill is MIT-licensed and fills a form
in a few milliseconds in-process.

## Installation

```ruby
# Gemfile
gem 'acrofill'
```

## Usage

```ruby
require 'acrofill'

# Discover fields in a template
Acrofill.field_names('form.pdf')
# => ["Full Name", "amount", "agree", "color", "notes"]

Acrofill.fields('form.pdf').map { |f| [f.name, f.type, f.states] }
# => [["Full Name", :Tx, nil], ["agree", :Btn, [:Yes]], ["color", :Btn, [:Red, :Blue]], ...]

# Fill: text fields take strings, checkboxes/radios take a state name
Acrofill.fill_form('form.pdf', 'out.pdf', {
  'Full Name' => 'Jane Roe',
  'agree' => 'Yes',        # checkbox: state name, or anything truthy
  'color' => 'Blue',       # radio group: state name
  'notes' => "line one\nline two" # multiline fields wrap automatically
})

# Flatten: burn values into page content and drop the interactive form
Acrofill.fill_form('form.pdf', 'out.pdf', data, flatten: true)

# Filling the same template many times (the typical server pattern)?
# Parse it once — each subsequent fill skips parsing entirely (~3-8x
# faster per fill) and works on its own copy, so it is thread-safe:
template = Acrofill::Template.new('form.pdf')
template.fill_form('out1.pdf', { 'Full Name' => 'Jane' }, flatten: true)
template.fill_form('out2.pdf', { 'Full Name' => 'John' }, flatten: true)
```

### Drop-in for pdf-forms

`Acrofill.new` accepts (and ignores) a pdftk path, so most `PdfForms`
call sites work unchanged:

```ruby
filler = Acrofill.new                    # was: PdfForms.new('/usr/bin/pdftk')
filler.fill_form(tpl, out, data, flatten: true)
```

Unknown field names are silently ignored, matching pdftk.

### Geometry parity

Filled text lands where pdftk puts it: across four real-world
government claim forms — 551 filled widgets — every appearance agrees with
pdftk-java 3.3.3 to the two decimals it prints, except where acrofill
deliberately differs (below). `spec/pdftk_parity_spec.rb` pins that
placement against numbers read out of pdftk's own appearance streams —
alignment, baselines for Helvetica/Times/Courier across box heights, text
taller than its field, multiline row spacing, and the widths, ascent and
`FontBBox` a template's own font dictionary supplies. Check it against
your own templates with:

```bash
ruby benchmark/geometry_diff.rb path/to/form.pdf
```

Flattened output was checked the same way: on those four forms every
stamped fragment lands where pdftk stamps it, bar the fields covered by the
deliberate differences below.

Four differences are deliberate: acrofill shrinks an overlong value to fit
where pdftk clips it; it writes Windows-1252 for non-ASCII values where
pdftk emits UTF-8 bytes into a WinAnsi font (which renders as mojibake); it
caps auto-sized (`0 Tf`) text at 12pt where pdftk scales it to fill the box;
and it drops widgets flagged Hidden or NoView when flattening instead of
burning them into the page. See the changelog for the measured numbers.

## Performance

Because Acrofill runs in-process, it avoids the JVM (or C++ process)
start-up that dominates a `pdftk` subprocess call — the exact pattern a
web app hits when it fills one form per request. Filling **and
flattening** three real-world government claim forms, 50 iterations
each, on an Apple M-series laptop against `pdftk-java` 3.3.3:

| Form                       | acrofill | pdftk (java) | speedup |
|----------------------------|---------:|-------------:|--------:|
| form A (124 fields, 3 pp)  | 49 ms    | 192 ms       | 3.9×    |
| form B (53 fields, 2 pp)   | 16 ms    | 124 ms       | 7.6×    |
| form C (187 fields, 2 pp)  | 47 ms    | 154 ms       | 3.3×    |
| **weighted total**         |          |              | **4.2×**|

Reproduce with your own templates — the benchmark discovers each form's
fields automatically:

```bash
ruby benchmark/compare.rb path/to/*.pdf   # ITERATIONS=50 by default
```

### Self-contained synthetic benchmark

`benchmark/synthetic.rb` needs no templates — it generates a form with a
configurable number of text fields and reports three variants. Because
`pdftk` (a CLI) has no server mode, the JVM boots on every call; to be
fair we also measure that start-up cost separately and subtract it, so
**pdftk warm** models the marginal PDF-processing cost with the runtime
already hot (a lower bound on any long-lived-pdftk setup):

```
$ FIELDS=30 ruby benchmark/synthetic.rb
variant                        ms/fill vs acrofill
acrofill (in-process)             3.4       1.0×
acrofill (cached template)        1.1       0.3×
pdftk cold (subprocess)         122.3      36.0×
pdftk warm (JVM excluded)        90.6      26.6×
(measured pdftk start-up overhead: ~32 ms/call)
```

Even discounting JVM start-up entirely, Acrofill is ~13–29× faster on
synthetic forms (the multiplier shrinks as field count grows: ~29× at 30
fields, ~13× at 80). The gap is largest on simple forms — exactly the
common case — and start-up is a real per-request cost for any `pdftk`-CLI
integration. The `pdftk warm` figure is a conservative estimate: `pdftk
--version` loads fewer classes than an actual fill, so true warm cost is
somewhat higher than shown.

Parsing dominates a one-shot fill (~86% of the time on a real 3-page
form), which is what `Acrofill::Template` eliminates: on the 124-field
form above a one-shot fill takes ~47 ms while a cached-template fill
takes ~6 ms — against pdftk's ~192 ms for the same job.

## Security

The PDF **template** is treated as untrusted input (the typical
"upload a PDF and fill it" case), and so are field names and values.
Acrofill is pure Ruby with no `eval`/`system`/native calls in its hot
path, so the worst an input can do is cause an exception — never memory
corruption or code execution. Specifically it defends against:

- **Cyclic, exponentially-shared and deeply nested object graphs** — the
  page tree and field tree walkers are iterative and carry visited-sets,
  so a `/Pages` or `/Kids` cycle, a "billion laughs" DAG, or a
  thousands-deep linear chain terminates in O(objects) instead of hanging
  or overflowing the stack.
- **Content-stream injection via `/DA`** — the template's default
  appearance string is sanitized: the font name must be a regular PDF
  name and only well-formed colour operators (`g`/`rg`/`k`) are copied
  into generated appearances. Field **values** are always written as
  escaped literals / hex strings, never as operators.
- **Malformed scalars and mistyped structure** — non-finite reals, deeply
  nested arrays, a `/Resources` that is not a dictionary, a `/Root` that
  points nowhere: each is clamped, replaced or rejected rather than
  raising a `TypeError`/`NoMethodError` out of the middle of a fill.
- **Encrypted / unparseable input** — rejected up front; every failure
  at the parse boundary surfaces as `Acrofill::Error` (including lazy
  per-object parse errors and parser stack overflow on pathologically
  nested objects), so callers only ever rescue one error type.

## Feature matrix

Supported:

- Text fields (`/Tx`) — hierarchical names (`parent.kid`), inherited
  `/DA`, alignment via `/Q` (left/center/right), auto font size (`0 Tf`),
  shrink-to-fit for overflowing values, multiline fields (`/Ff` bit 13)
  with word wrapping, and text measured with the metrics of the font it is
  drawn with: a template's own `/Widths` and `/FontDescriptor` when the
  face carries them (as embedded subsets do), otherwise WinAnsi tables for
  all standard-14 cuts — widths, ascender and `FontBBox`, so baselines and
  row spacing follow the actual face. A `/BaseFont` naming no standard cut
  (`ArialMT`, `TimesNewRomanPS-BoldMT`) is classified by family and weight
  rather than all measured as Helvetica.
- Checkboxes and radio groups (`/Btn`) — state selection via `/V`+`/AS`
  using the template's own appearance states.
- Comb fields (`/Ff` bit 25) — one character centered per `/MaxLen` cell.
- Choice fields (`/Ch`) — value set and rendered like text.
- Flattening — every visible widget appearance is stamped into the page
  content; widget annotations and the AcroForm dictionary are removed.
- Values in any encoding (stored as UTF-16BE when needed; appearances
  render the Windows-1252 subset).

Not supported (rejected or ignored, never a hard crash):

- Encrypted documents (raise `Acrofill::Error`), XFA forms, digital
  signatures, JavaScript actions.
- Push buttons; rich text (`/RV`) is dropped on fill.
- Glyphs outside Windows-1252 in generated appearances (stored values
  keep full Unicode; unrenderable glyphs appear as `?`).

## Development

```bash
bundle install
bundle exec rake spec
```

The test suite generates its fixture PDFs from scratch — the repository
contains no binary files.

## License

MIT. See LICENSE.txt.
