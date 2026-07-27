# frozen_string_literal: true

require 'timeout'

# Regression tests for the DoS hardening: the two recursive walks
# (Document#each_page and Form#collect_fields) must terminate on cyclic
# and on exponentially-shared (billion-laughs) object graphs, since the
# PDF template is untrusted input.
RSpec.describe 'malicious template hardening' do
  around do |example|
    Dir.mktmpdir('acrofill-sec') do |dir|
      @dir = dir
      example.run
    end
  end

  def build(objects)
    RawPdf.write(@dir, objects, name: 'evil.pdf')
  end

  def within_budget(&block)
    Timeout.timeout(10, &block)
  end

  # The text every generated appearance stream draws, so a spec can tell
  # "no appearance was built" from "one was built against nonsense".
  def drawn_values(path)
    PDF::Reader.new(path).objects.filter_map do |_ref, obj|
      obj.data[/\((.*)\) Tj/, 1] if obj.is_a?(PDF::Reader::Stream)
    end
  end

  it 'terminates on a self-referential /Pages tree (cycle)' do
    # obj2 is a Pages node whose Kids point back to itself.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [2 0 R] /Count 1 >>',
                   '<< /Fields [] >>'
                 ])
    expect { within_budget { Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), {}, flatten: true) } }
      .not_to raise_error
  end

  it 'terminates on a cyclic field /Kids graph' do
    # Field 4 has a subfield 5; field 5 references 4 back as its kid.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [] /Count 0 >>',
                   '<< /Fields [4 0 R] >>',
                   '<< /T (a) /Kids [5 0 R] >>',
                   '<< /T (b) /Kids [4 0 R] >>'
                 ])
    expect { within_budget { Acrofill.field_names(path) } }.not_to raise_error
  end

  it 'does not amplify exponentially on a shared (DAG) /Pages tree' do
    # 30 Pages levels, each referencing the next twice. Without a visited
    # set this is 2**30 (~1e9) visits; with one it is ~30.
    depth = 30
    objects = ['<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>', nil, '<< /Fields [] >>']
    (0...depth).each do |level|
      obj_num = 4 + level
      child = level == depth - 1 ? '' : "/Kids [#{obj_num + 1} 0 R #{obj_num + 1} 0 R]"
      objects << "<< /Type /Pages #{child} /Count 1 >>"
    end
    objects[1] = '<< /Type /Pages /Kids [4 0 R 4 0 R] /Count 1 >>'
    path = build(objects)

    expect { within_budget { Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), {}, flatten: true) } }
      .not_to raise_error
  end

  it 'does not blow up quadratically on a huge multiline value' do
    # Wide box so nothing wraps: the old O(words^2) path took ~20s at 8k
    # words; the incremental path stays well under the budget.
    objects = [
      '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
      '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
      '<< /Fields [5 0 R] /DA (/Helv 10 Tf 0 g) >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
      '<< /Type /Annot /Subtype /Widget /FT /Tx /T (notes) /Ff 4096 ' \
      '/Rect [0 0 100000000 200] /DA (/Helv 10 Tf 0 g) >>'
    ]
    path = build(objects)
    value = (['word'] * 8000).join(' ')
    within_budget do
      Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), { 'notes' => value })
    end
  end

  it 'survives a non-finite real number in a reachable object' do
    big = "1#{'0' * 400}.0" # parsed as Float::INFINITY by pdf-reader
    path = build([
                   "<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R /Junk #{big} >>",
                   '<< /Type /Pages /Kids [] /Count 0 >>',
                   '<< /Fields [] >>'
                 ])
    expect { Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), {}, flatten: true) }
      .not_to raise_error
  end

  it 'does not inject content operators from a crafted /DA string' do
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] /DA (/Helv 0 Tf 0 g) >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) /Rect [10 10 200 40] ' \
                   '/DA (/Helv 10 Tf 1 0 0 rg 0 0 500 500 re f) >>'
                 ])
    Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), { 'x' => 'hello' })

    reader = PDF::Reader.new(File.join(@dir, 'o.pdf'))
    ap = nil
    reader.objects.each do |_ref, obj|
      ap = obj if obj.is_a?(PDF::Reader::Stream) && obj.data.include?('hello')
    end
    expect(ap.data).not_to include('re f') # rectangle-fill operator dropped
    expect(ap.data).not_to include('0 0 500 500')
  end

  it 'caps recursion in the serializer instead of overflowing the stack' do
    # Build the nesting as Ruby objects (bypassing pdf-reader's own parser)
    # to exercise Serializer's depth guard directly.
    deep = 0
    5000.times { deep = [deep] }
    expect { Acrofill::Serializer.new({}).serialize(deep) }
      .to raise_error(Acrofill::Error, /nesting/)
  end

  it 'treats a mistyped /AP on a button field as no states, not a crash' do
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [] /Count 0 >>',
                   '<< /Fields [4 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Btn /T (b) /Rect [0 0 12 12] /AP [1 2 3] >>'
                 ])
    expect { Acrofill.fields(path) }.not_to raise_error
    expect { Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), { 'b' => 'Yes' }) }
      .not_to raise_error
  end

  it 'ignores mistyped font metrics instead of laying out against them' do
    # /Widths, /FirstChar and /FontDescriptor all come from the template, so
    # each is validated before it reaches the geometry.
    [
      '/FirstChar 32 /Widths 7 0 R',                    # not an array
      '/FirstChar (x) /Widths [500 500]',               # /FirstChar not an integer
      '/Widths [500 500]',                              # no /FirstChar
      '/FirstChar 32 /Widths []',                       # empty
      '/FirstChar 32 /Widths [(a) (b) null]',           # non-numeric entries
      "/FirstChar 32 /Widths [1#{'0' * 400}.0 500]",    # non-finite
      '/FontDescriptor [1 2 3]',                        # not a dictionary
      '/FontDescriptor << /Ascent (tall) /FontBBox [1 2] >>',
      "/FontDescriptor << /Ascent 1#{'0' * 400}.0 >>"   # non-finite ascent
    ].each do |font_entries|
      path = build([
                     '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                     '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                     '<< /Fields [5 0 R] /DA (/F1 10 Tf 0 g) /DR << /Font << /F1 6 0 R >> >> >>',
                     '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                     '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) /Rect [0 0 200 20] /Q 1 ' \
                     '/DA (/F1 10 Tf 0 g) >>',
                     "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica #{font_entries} >>",
                     '<< /Not /AnArray >>'
                   ])
      expect { Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), { 'x' => 'hi' }) }
        .not_to raise_error, "raised for #{font_entries}"
    end
  end

  it 'ignores a mistyped /Encoding or /MaxLen instead of laying out with it' do
    [
      ['/Encoding << /Differences 7 0 R >>', ''],                    # not an array
      ['/Encoding << /Differences [(a) /A 3.5 /B] >>', ''],          # junk entries
      ['/Encoding << /Differences [/A /B] >>', ''],                  # no starting code
      ['/Encoding << /Differences [999 /A] >>', ''],                 # code out of range
      ['/Encoding [1 2 3]', ''],                                     # not a dictionary
      ['', "/Ff #{1 << 24}"],                                        # comb without /MaxLen
      ['', "/Ff #{1 << 24} /MaxLen 0"],                              # zero cells
      ['', "/Ff #{1 << 24} /MaxLen (five)"],                         # /MaxLen not a number
      ['', "/Ff #{1 << 24} /MaxLen -3"]                              # negative
    ].each do |font_entries, widget_entries|
      path = build([
                     '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                     '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                     '<< /Fields [5 0 R] /DA (/F1 10 Tf 0 g) /DR << /Font << /F1 6 0 R >> >> >>',
                     '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                     '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) /Rect [0 0 200 20] ' \
                     "/DA (/F1 10 Tf 0 g) #{widget_entries} >>",
                     "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica #{font_entries} >>",
                     '<< /Not /AnArray >>'
                   ])
      expect { Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), { 'x' => 'hi' }) }
        .not_to raise_error, "raised for #{font_entries} #{widget_entries}"
    end
  end

  # Geometry arrives as template numbers too, and an unusable one has to be
  # refused outright: a NaN or infinite extent passes every `<= 0` guard, so
  # it reaches the layout and either raises or silently lays the value out
  # against nonsense. Either way the widget must end up with no /AP, which
  # is the same degrade an unusable /Rect has always taken.
  it 'refuses unusable widget geometry instead of laying out against it' do
    infinite = "1#{'0' * 400}.0" # parsed as Float::INFINITY by pdf-reader
    enormous = "1#{'0' * 308}"   # finite, but the extent overflows
    [
      "[0 #{infinite} 200 #{infinite}]",              # non-finite corner
      "[#{infinite} 0 #{infinite} 20]",               # non-finite corner, x
      "[-#{enormous} -#{enormous} #{enormous} #{enormous}]" # extent overflows
    ].each do |rect|
      path = build([
                     '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                     '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                     '<< /Fields [5 0 R] >>',
                     '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                     '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) /Q 1 ' \
                     "/Rect #{rect} /DA (/Helv 10 Tf 0 g) >>"
                   ])
      out = File.join(@dir, 'o.pdf')
      expect { Acrofill.fill_form(path, out, { 'x' => 'hello' }) }
        .not_to raise_error, "raised for /Rect #{rect}"
      expect(drawn_values(out)).to be_empty, "laid out against /Rect #{rect}"
    end
  end

  it 'refuses a non-finite /DA point size instead of measuring with it' do
    # String#to_f happily yields Infinity, and every width it scales then
    # collapses to a NaN that no clamp can recover from.
    ["/Helv 1#{'0' * 400} Tf 0 g", "/Helv 1#{'0' * 307} Tf 0 g"].each do |da|
      path = build([
                     '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                     '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                     '<< /Fields [5 0 R] >>',
                     '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                     '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) ' \
                     "/Rect [10 10 210 40] /DA (#{da}) >>"
                   ])
      out = File.join(@dir, 'o.pdf')
      expect { Acrofill.fill_form(path, out, { 'x' => 'hello world' }) }
        .not_to raise_error, "raised for /DA (#{da})"
      expect(drawn_values(out)).not_to be_empty, "dropped the value for /DA (#{da})"
    end
  end

  it 'treats a non-finite /Matrix on an appearance as the identity' do
    # The corners are fine here; it is the matrix they are pushed through
    # that overflows, and Array#min raises on the NaN that falls out.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Btn /T (b) /Rect [0 0 20 20] /AS /Yes ' \
                   '/AP << /N << /Yes 6 0 R >> >> >>',
                   "<< /BBox [0 0 20 20] /Matrix [1#{'0' * 400} 0 0 1 0 0] /Length 0 >>\n" \
                   "stream\nendstream"
                 ])
    expect { Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), {}, flatten: true) }
      .not_to raise_error
  end

  it 'reads only the emittable slice of an enormous /Widths array' do
    # A declared range of a million glyphs must not cost a million steps.
    widths = "[#{Array.new(20_000, 500).join(' ')}]"
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] /DA (/F1 10 Tf 0 g) /DR << /Font << /F1 6 0 R >> >> >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) /Rect [0 0 200 20] ' \
                   '/DA (/F1 10 Tf 0 g) >>',
                   "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 32 /Widths #{widths} >>"
                 ])
    expect { within_budget { Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), { 'x' => 'hi' }) } }
      .not_to raise_error
  end

  it 'replaces a mistyped /Resources dictionary instead of indexing it' do
    # Indexing an Array with a Symbol raises TypeError; the flatten path
    # must treat a non-dictionary /Resources as absent.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] ' \
                   '/Resources [1 2 3] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Btn /T (b) /Rect [0 0 20 20] /AS /Yes ' \
                   '/AP << /N << /Yes 6 0 R >> >> >>',
                   "<< /BBox [0 0 20 20] /Length 0 >>\nstream\nendstream"
                 ])
    expect { Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), {}, flatten: true) }
      .not_to raise_error
  end

  it 'replaces a mistyped /XObject subdictionary instead of indexing it' do
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] ' \
                   '/Resources << /XObject 7 0 R >> >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Btn /T (b) /Rect [0 0 20 20] /AS /Yes ' \
                   '/AP << /N << /Yes 6 0 R >> >> >>',
                   "<< /BBox [0 0 20 20] /Length 0 >>\nstream\nendstream",
                   '[1 2 3]'
                 ])
    expect { Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), {}, flatten: true) }
      .not_to raise_error
  end

  it 'raises Acrofill::Error when /Root points at a missing object' do
    path = build(['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [] /Count 0 >>'])
    File.binwrite(path, File.binread(path).sub('/Root 1 0 R', '/Root 99 0 R'))
    expect { Acrofill.field_names(path) }.to raise_error(Acrofill::Error, /catalog/)
  end

  it 'raises Acrofill::Error when /Root is not a dictionary' do
    path = build(['42', '<< /Type /Pages /Kids [] /Count 0 >>'])
    expect { Acrofill.field_names(path) }.to raise_error(Acrofill::Error, /catalog/)
  end

  it 'surfaces only Acrofill::Error for an encrypted/undecryptable document' do
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R >>',
                   '<< /Type /Pages /Kids [] /Count 0 >>'
                 ])
    # Splice an /Encrypt entry into the trailer.
    raw = File.binread(path).sub('/Root 1 0 R', '/Root 1 0 R /Encrypt 2 0 R')
    File.binwrite(path, raw)
    expect { Acrofill.field_names(path) }.to raise_error(Acrofill::Error)
  end

  it 'wraps arbitrary pdf-reader parse failures as Acrofill::Error' do
    path = File.join(@dir, 'garbage.pdf')
    File.binwrite(path, "%PDF-1.4\nnot a real pdf at all\n%%EOF")
    expect { Acrofill.field_names(path) }.to raise_error(Acrofill::Error)
  end

  it 'wraps a parser stack overflow from deeply nested objects as Acrofill::Error' do
    # pdf-reader's recursive-descent parser overflows the Ruby stack on
    # this input; the parse boundary must convert that SystemStackError.
    nested = ('[' * 10_000) + (']' * 10_000)
    path = build([
                   "<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R /Junk #{nested} >>",
                   '<< /Type /Pages /Kids [] /Count 0 >>',
                   '<< /Fields [] >>'
                 ])
    expect { within_budget { Acrofill.field_names(path) } }.to raise_error(Acrofill::Error)
  end

  it 'wraps lazy parse failures from a corrupt object body as Acrofill::Error' do
    # The xref and trailer are valid, so ObjectHash.new succeeds; the
    # corrupt body only surfaces when objects are materialized later.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [] /Count 0 >>',
                   '<< /Broken >]>'
                 ])
    expect { Acrofill.field_names(path) }.to raise_error(Acrofill::Error)
  end

  it 'gives up on an indirect-reference cycle instead of looping' do
    # /V resolves 5 -> 6 -> 5 -> ...; deref's hop cap must break the loop.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [] /Count 0 >>',
                   '<< /Fields [4 0 R] >>',
                   '<< /FT /Tx /T (x) /Rect [0 0 10 10] /V 5 0 R >>',
                   '6 0 R',
                   '5 0 R'
                 ])
    fields = nil
    within_budget { fields = Acrofill.fields(path) }
    expect(fields.first.value).to be_nil
  end

  it 'terminates on a cyclic /Parent inheritance chain' do
    # Field 4 inherits through 5, which points back to 4; the cycle guard
    # in inherited_value must stop the /FT lookup.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [] /Count 0 >>',
                   '<< /Fields [4 0 R] >>',
                   '<< /T (x) /Rect [0 0 10 10] /Parent 5 0 R >>',
                   '<< /Parent 4 0 R >>'
                 ])
    expect { within_budget { Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), { 'x' => 'v' }) } }
      .not_to raise_error
  end

  it 'walks a deep linear /Pages chain without overflowing the stack' do
    depth = 6000
    objects = ['<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
               '<< /Type /Pages /Kids [4 0 R] /Count 0 >>',
               '<< /Fields [] >>']
    (0...depth).each do |level|
      obj_num = 4 + level
      kids = level == depth - 1 ? '[]' : "[#{obj_num + 1} 0 R]"
      objects << "<< /Type /Pages /Kids #{kids} /Count 0 >>"
    end
    path = build(objects)
    expect { within_budget { Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), {}, flatten: true) } }
      .not_to raise_error
  end

  it 'walks a deep linear field /Kids chain without overflowing the stack' do
    depth = 6000
    objects = ['<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
               '<< /Type /Pages /Kids [] /Count 0 >>',
               '<< /Fields [4 0 R] >>']
    (0...depth).each do |level|
      obj_num = 4 + level
      kids = level == depth - 1 ? '' : "/Kids [#{obj_num + 1} 0 R]"
      objects << "<< /T (f#{level}) #{kids} >>"
    end
    path = build(objects)
    expect { within_budget { Acrofill.field_names(path) } }.not_to raise_error
  end
end
