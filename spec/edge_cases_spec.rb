# frozen_string_literal: true

# Regressions for spec-legal but unusual templates: any value in a PDF
# dictionary or array may be an indirect reference (PDF 32000 §7.3.10),
# and appearance-state names are not restricted to "Yes"-style words.
RSpec.describe 'spec-legal edge cases' do
  around do |example|
    Dir.mktmpdir('acrofill-edge') do |dir|
      @dir = dir
      example.run
    end
  end

  def build(objects)
    RawPdf.write(@dir, objects)
  end

  def out
    File.join(@dir, 'o.pdf')
  end

  def appearance_data(path, text)
    stream = nil
    PDF::Reader.new(path).objects.each do |_ref, obj|
      stream = obj if obj.is_a?(PDF::Reader::Stream) && obj.data.include?("(#{text})")
    end
    stream&.data
  end

  it 'derefs an indirect /V when reporting field values' do
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [] /Count 0 >>',
                   '<< /Fields [4 0 R] >>',
                   '<< /FT /Tx /T (name) /Rect [0 0 100 20] /V 5 0 R >>',
                   '(hello)'
                 ])
    expect(Acrofill.fields(path).first.value).to eq('hello')
  end

  it 'derefs indirect numbers inside /Rect instead of crashing' do
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] /DA (/Helv 10 Tf 0 g) >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) ' \
                   '/Rect [10 10 6 0 R 40] /DA (/Helv 10 Tf 0 g) >>',
                   '200'
                 ])
    expect { Acrofill.fill_form(path, out, { 'x' => 'hi' }, flatten: true) }.not_to raise_error
    expect(appearance_data(out, 'hi')).not_to be_nil # 190pt-wide box, appearance built
  end

  it 'honours an indirect /Q alignment value' do
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] /DA (/Helv 10 Tf 0 g) >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) /Rect [0 0 200 20] ' \
                   '/DA (/Helv 10 Tf 0 g) /Q 6 0 R >>',
                   '1'
                 ])
    Acrofill.fill_form(path, out, { 'x' => 'hi' })
    # Centered in a 200pt box: the first Td x offset is ~96pt, not the 2pt
    # left padding an ignored /Q would produce.
    x = appearance_data(out, 'hi')[/^([\d.]+) [\d.-]+ Td/, 1].to_f
    expect(x).to be > 50
  end

  it 'registers nested names and ignores stray bare widgets among subfields' do
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [] /Count 0 >>',
                   '<< /Fields [4 0 R] >>',
                   '<< /FT /Tx /T (a) /Kids [5 0 R 6 0 R] >>',
                   '<< /T (b) /Kids [7 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /Rect [0 0 10 10] >>', # no /T
                   '<< /T (c) /Rect [0 0 10 10] >>'
                 ])
    expect(Acrofill.field_names(path)).to eq(['a.b.c'])
  end

  it 'leaves pushbutton fields untouched' do
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (go) ' \
                   '/Rect [0 0 20 20] /AP << /N << /go 6 0 R >> >> >>',
                   "<< /BBox [0 0 20 20] /Length 0 >>\nstream\nendstream"
                 ])
    Acrofill.fill_form(path, out, { 'go' => 'go' })

    field = PDF::Reader::ObjectHash.new(out).values.find { |o| o.is_a?(Hash) && o[:T] == 'go' }
    expect(field[:V]).to be_nil
  end

  it 'leaves signature fields untouched' do
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [] /Count 0 >>',
                   '<< /Fields [4 0 R] >>',
                   '<< /FT /Sig /T (sig) /Rect [0 0 20 20] >>'
                 ])
    expect { Acrofill.fill_form(path, out, { 'sig' => 'not a signature' }) }.not_to raise_error

    field = PDF::Reader::ObjectHash.new(out).values.find { |o| o.is_a?(Hash) && o[:T] == 'sig' }
    expect(field[:V]).to be_nil
  end

  it 'derefs an indirect /Widths array and its indirect entries' do
    # Widths are frequently stored as a separate object, and any entry may
    # itself be indirect (PDF 32000 §7.3.10).
    entries = (Array.new(45, '500') + ['7 0 R'] + Array.new(49, '500')).join(' ')
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] /DA (/F1 10 Tf 0 g) /DR << /Font << /F1 6 0 R >> >> >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) /Rect [0 0 300 20] /Q 2 ' \
                   '/DA (/F1 10 Tf 0 g) >>',
                   '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 32 /Widths 8 0 R >>',
                   '1000', # the width of code 77 ("M"), reached indirectly
                   "[#{entries}]"
                 ])
    Acrofill.fill_form(path, out, { 'x' => 'MM' })

    # Right-aligned: 300 - 2 - 2 * 10pt, the indirect 1000 honoured. A failed
    # deref would leave the entry at zero width (298) and the neighbouring
    # direct 500 would give 288, so this pins the indirect read.
    x = appearance_data(out, 'MM')[/^([\d.]+) [\d.-]+ Td/, 1].to_f
    expect(x).to be_within(0.01).of(278.0)
  end

  it 'flattens page nodes whose /Type entry is missing' do
    # /Type is required on page-tree nodes but plenty of generators omit it;
    # skipping those pages would silently flatten nothing.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] /DA (/Helv 10 Tf 0 g) >>',
                   '<< /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>', # no /Type
                   '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) /Rect [10 10 200 40] ' \
                   '/DA (/Helv 10 Tf 0 g) >>'
                 ])
    Acrofill.fill_form(path, out, { 'x' => 'hello' }, flatten: true)

    stamped = PDF::Reader.new(out).objects.any? do |_ref, obj|
      obj.is_a?(PDF::Reader::Stream) && obj.data.include?(' Do ')
    end
    expect(stamped).to be(true)
  end

  it 'does not stamp widgets a viewer would not display' do
    # /F bit 2 is Hidden, bit 6 is NoView ("not on screen", PDF 32000
    # §12.5.3). Flattening bakes the appearance into the page, so a widget
    # the viewer hides must be dropped rather than made permanently visible.
    flags = { 'shown' => 4, 'hidden' => 2, 'noview' => 32, 'noprint' => 0 }
    refs = (0...flags.size).map { |i| "#{5 + i} 0 R" }.join(' ')
    objects = [
      '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
      '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
      "<< /Fields [#{refs}] /DA (/Helv 10 Tf 0 g) >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [#{refs}] >>"
    ]
    flags.each_with_index do |(name, flag), index|
      objects << "<< /Type /Annot /Subtype /Widget /FT /Tx /T (#{name}) /F #{flag} " \
                 "/Rect [10 #{10 + (index * 30)} 300 #{40 + (index * 30)}] /DA (/Helv 10 Tf 0 g) >>"
    end
    path = build(objects)
    Acrofill.fill_form(path, out, flags.keys.to_h { |name| [name, "value-#{name}"] }, flatten: true)

    drawn = PDF::Reader.new(out).pages.first.text
    expect(drawn).to include('value-shown', 'value-noprint')
    expect(drawn).not_to include('value-hidden')
    expect(drawn).not_to include('value-noview')
  end

  it 'drops a stale appearance when a new one cannot be built' do
    stale = 'BT (STALE) Tj ET'
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] /DA (/Helv 10 Tf 0 g) >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                   # Zero-width /Rect: no appearance can be generated for it.
                   '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) /Rect [10 10 10 40] ' \
                   '/DA (/Helv 10 Tf 0 g) /V (old) /AP << /N 6 0 R >> >>',
                   "<< /BBox [0 0 190 30] /Length #{stale.bytesize} >>\nstream\n#{stale}\nendstream"
                 ])
    Acrofill.fill_form(path, out, { 'x' => 'new' })

    objects = PDF::Reader::ObjectHash.new(out)
    field = objects.values.find { |o| o.is_a?(Hash) && o[:T] == 'x' }
    expect(field[:V]).to eq('new')
    expect(field[:AP]).to be_nil # not the appearance still showing "old"
    expect(objects.values.any? { |o| o.is_a?(PDF::Reader::Stream) && o.data.include?('STALE') })
      .to be(false)
  end

  it 'promotes a direct /DR font dictionary to one shared indirect object' do
    refs = (0...4).map { |i| "#{5 + i} 0 R" }.join(' ')
    objects = [
      '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
      '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
      "<< /Fields [#{refs}] /DA (/F1 10 Tf 0 g) /DR << /Font << /F1 " \
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >> >> >> >>',
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [#{refs}] >>"
    ]
    4.times do |i|
      objects << "<< /Type /Annot /Subtype /Widget /FT /Tx /T (f#{i}) " \
                 "/Rect [10 #{10 + (i * 30)} 200 #{40 + (i * 30)}] /DA (/F1 10 Tf 0 g) >>"
    end
    path = build(objects)
    Acrofill.fill_form(path, out, (0...4).to_h { |i| ["f#{i}", "value #{i}"] })

    fonts = PDF::Reader::ObjectHash.new(out).values.count { |o| o.is_a?(Hash) && o[:Type] == :Font }
    expect(fonts).to eq(1)
  end

  it 'registers one shared fallback font for every generated appearance' do
    objects = ['<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>', nil, nil, nil]
    refs = (0...5).map { |i| "#{5 + i} 0 R" }.join(' ')
    objects[1] = '<< /Type /Pages /Kids [4 0 R] /Count 1 >>'
    objects[2] = "<< /Fields [#{refs}] /DA (/Helv 10 Tf 0 g) >>" # no /DR
    objects[3] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [#{refs}] >>"
    5.times do |i|
      objects << "<< /Type /Annot /Subtype /Widget /FT /Tx /T (f#{i}) " \
                 "/Rect [10 #{10 + (i * 30)} 200 #{40 + (i * 30)}] /DA (/Helv 10 Tf 0 g) >>"
    end
    path = build(objects)
    Acrofill.fill_form(path, out, (0...5).to_h { |i| ["f#{i}", "value #{i}"] })

    fonts = PDF::Reader::ObjectHash.new(out).values.count { |o| o.is_a?(Hash) && o[:Type] == :Font }
    expect(fonts).to eq(1)
  end

  # A stream carrying +text+ verbatim, for values the font re-encodes.
  def stream_containing(path, text)
    found = nil
    PDF::Reader.new(path).objects.each do |_ref, obj|
      found = obj if obj.is_a?(PDF::Reader::Stream) && obj.data.include?(text)
    end
    found&.data
  end

  def page_annots(path)
    objects = PDF::Reader::ObjectHash.new(path)
    page = objects.values.find { |o| o.is_a?(Hash) && o[:Type] == :Page }
    annots = objects.deref(page[:Annots])
    (annots || []).map { |a| objects.deref(a) }
  end

  it 'stamps a widget whose rectangle lives on its parent field' do
    # /Rect is inheritable, and the appearance is built from the inherited
    # one. Reading only the widget's own /Rect when stamping filled the
    # value and then dropped it, so flattening lost data silently.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] /DA (/Helv 10 Tf 0 g) >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [6 0 R] >>',
                   '<< /FT /Tx /T (x) /Rect [10 700 300 730] /DA (/Helv 10 Tf 0 g) /Kids [6 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /Parent 5 0 R >>'
                 ])
    Acrofill.fill_form(path, out, { 'x' => 'JANE' }, flatten: true)

    expect(PDF::Reader.new(out).pages.first.text).to include('JANE')
  end

  it 'drops an annotation reference that resolves to nothing' do
    # Carrying it over would serialize as a bare `null` inside /Annots,
    # which is not a legal annotation array.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] /DA (/Helv 10 Tf 0 g) >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ' \
                   '/Annots [5 0 R 99 0 R 6 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) /Rect [10 700 300 730] ' \
                   '/DA (/Helv 10 Tf 0 g) >>',
                   '<< /Type /Annot /Subtype /Link /Rect [0 0 10 10] >>'
                 ])
    Acrofill.fill_form(path, out, { 'x' => 'hi' }, flatten: true)

    annots = page_annots(out)
    expect(annots.size).to eq(1)
    expect(annots).to all(be_a(Hash))
  end

  it 'recognizes a widget whose /Subtype is an indirect reference' do
    # Missing it left a live interactive widget in a document whose
    # /AcroForm flattening had already deleted.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] /DA (/Helv 10 Tf 0 g) >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                   '<< /Type /Annot /Subtype 6 0 R /FT /Tx /T (x) /Rect [10 700 300 730] ' \
                   '/DA (/Helv 10 Tf 0 g) >>',
                   '/Widget'
                 ])
    Acrofill.fill_form(path, out, { 'x' => 'JANE' }, flatten: true)

    expect(PDF::Reader.new(out).pages.first.text).to include('JANE')
    expect(page_annots(out)).to be_empty
  end

  it 'does not stamp through a degenerate annotation rectangle' do
    # A zero-width /Rect scales to a singular matrix, which PDF 32000
    # §8.3.3 forbids; Appearance rejects the same geometry when drawing.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] /DA (/Helv 10 Tf 0 g) >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) /Rect [50 50 50 62] ' \
                   '/DA (/Helv 10 Tf 0 g) /AP << /N 6 0 R >> >>',
                   "<< /Type /XObject /Subtype /Form /BBox [0 0 12 12] /Length 0 >>\nstream\nendstream"
                 ])
    Acrofill.fill_form(path, out, {}, flatten: true)

    expect(stream_containing(out, 'AcrofillAP')).to be_nil
  end

  it 'survives a /Matrix whose finite entries multiply out of range' do
    huge = "1#{'0' * 300}"
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] /DA (/Helv 10 Tf 0 g) >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) /Rect [10 700 300 730] ' \
                   '/DA (/Helv 10 Tf 0 g) /AP << /N 6 0 R >> >>',
                   "<< /Type /XObject /Subtype /Form /BBox [-#{huge} -#{huge} #{huge} #{huge}] " \
                   "/Matrix [#{huge} 0 #{huge} 0 0 0] /Length 0 >>\nstream\nendstream"
                 ])
    expect { Acrofill.fill_form(path, out, {}, flatten: true) }.not_to raise_error
  end

  it 'does not fuse /DA colour operands across the removed font operator' do
    # "0.2 0.4 /Helv 12 Tf 0.6 rg" carries a malformed one-operand rg.
    # Joining the two sides of the Tf triple made three numbers that were
    # never adjacent look like a valid operator, painting the value in a
    # colour the template never asked for.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] /DA (/Helv 10 Tf 0 g) >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) /Rect [10 700 300 730] ' \
                   '/DA (0.2 0.4 /Helv 12 Tf 0.6 rg) >>'
                 ])
    Acrofill.fill_form(path, out, { 'x' => 'X' })

    expect(appearance_data(out, 'X')).not_to include('0.2 0.4 0.6 rg')
  end

  it 'treats a /DA size of zero and a negative one alike' do
    # A negative size is as meaningless as a missing one; disagreeing let
    # one flag bit decide between a 12pt and a 2pt rendering.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] /DA (/Helv 10 Tf 0 g) >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) /Rect [10 700 300 720] ' \
                   '/DA (/Helv -5 Tf 0 g) >>'
                 ])
    Acrofill.fill_form(path, out, { 'x' => 'hi' })

    expect(appearance_data(out, 'hi')).to include('/Helv 12 Tf')
  end

  it 'writes a usable font into the appearance when /DR names a non-font' do
    # Measurement already degrades to standard Helvetica for such an entry;
    # writing it into /Resources anyway pointed Tf at a non-font object.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] /DA (/F1 10 Tf 0 g) /DR << /Font << /F1 42 >> >> >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) /Rect [10 700 300 730] ' \
                   '/DA (/F1 10 Tf 0 g) >>'
                 ])
    Acrofill.fill_form(path, out, { 'x' => 'hi' })

    objects = PDF::Reader::ObjectHash.new(out)
    appearance = objects.values.find do |o|
      o.is_a?(PDF::Reader::Stream) && o.data.include?('(hi) Tj')
    end
    font = objects.deref(objects.deref(appearance.hash[:Resources])[:Font])[:F1]
    expect(objects.deref(font)).to include(Type: :Font)
  end

  it 'wraps multiline text whose font draws the space glyph off code 32' do
    # /Differences [32 /bullet] moves space to code 160. Wrapping the
    # encoded bytes left String#split no word boundary, so the whole value
    # went out as one unwrapped line running past the box.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] /DA (/F1 10 Tf 0 g) /DR << /Font << /F1 6 0 R >> >> >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) /Rect [10 600 160 700] ' \
                   '/Ff 4096 /DA (/F1 10 Tf 0 g) >>',
                   '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ' \
                   '/Encoding << /Type /Encoding /Differences [32 /bullet] >> >>'
                 ])
    Acrofill.fill_form(path, out, { 'x' => 'alpha beta gamma delta epsilon zeta eta theta' })

    body = stream_containing(out, 'alpha')
    expect(body.scan(') Tj').size).to be > 1
  end

  it 'checks a button whose on state is literally named "no"' do
    blank = "<< /BBox [0 0 12 12] /Length 0 >>\nstream\nendstream"
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Btn /T (b) /Rect [0 0 12 12] /AS /Off ' \
                   '/AP << /N << /no 6 0 R /Off 7 0 R >> >> >>',
                   blank,
                   blank
                 ])
    Acrofill.fill_form(path, out, { 'b' => 'no' })
    field = PDF::Reader::ObjectHash.new(out).values.find { |o| o.is_a?(Hash) && o[:T] == 'b' }
    expect(field[:V]).to eq(:no)
    expect(field[:AS]).to eq(:no)
  end
end
