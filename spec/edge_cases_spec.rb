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
