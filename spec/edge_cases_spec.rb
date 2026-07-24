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
