# frozen_string_literal: true

require 'pdf-reader'

RSpec.describe Acrofill do
  around do |example|
    Dir.mktmpdir('acrofill') do |dir|
      @dir = dir
      example.run
    end
  end

  let(:template) { FixturePdf.write(@dir) }
  let(:output) { File.join(@dir, 'out.pdf') }

  def reader
    PDF::Reader.new(output)
  end

  def acroform(rdr = reader)
    root = rdr.objects.deref(rdr.objects.trailer[:Root])
    rdr.objects.deref(root[:AcroForm])
  end

  def appearance_streams
    streams = []
    reader.objects.each do |_ref, obj|
      streams << obj.data if obj.is_a?(PDF::Reader::Stream) && obj.data.include?('Tj')
    end
    streams
  end

  describe '.fill_form' do
    it 'fills text fields and flattens them into page content' do
      described_class.fill_form(
        template, output,
        { 'name' => 'Jane Roe', 'amount' => '1500.00', 'week.0' => '01/03/2026' },
        flatten: true
      )

      text = reader.pages.first.text
      expect(text).to include('Jane Roe', '1500.00', '01/03/2026')
      expect(acroform).to be_nil
    end

    it 'keeps the interactive form when not flattening' do
      described_class.fill_form(template, output, { 'name' => 'Jane' })

      expect(acroform).to be_a(Hash)
      fields = reader.objects.deref(acroform[:Fields])
      name_field = fields.map { |f| reader.objects.deref(f) }
                         .find { |f| f[:T] == 'name' }
      expect(name_field[:V]).to eq('Jane')
      expect(name_field[:AP]).not_to be_nil
    end

    it 'silently ignores unknown field names like pdftk' do
      expect do
        described_class.fill_form(template, output, { 'nope' => 'x' }, flatten: true)
      end.not_to raise_error
      expect(File).to exist(output)
    end

    it 'coerces non-string values and treats nil as empty' do
      described_class.fill_form(
        template, output, { 'amount' => 1500, 'name' => nil }, flatten: true
      )
      expect(reader.pages.first.text).to include('1500')
    end

    it 'stores non-ASCII values as UTF-16BE text strings' do
      described_class.fill_form(template, output, { 'name' => 'Žaneta' })

      fields = reader.objects.deref(acroform[:Fields])
      name_field = fields.map { |f| reader.objects.deref(f) }
                         .find { |f| f[:T] == 'name' }
      expect(name_field[:V].dup.force_encoding('BINARY'))
        .to start_with("\xFE\xFF".b)
    end

    it 'escapes parentheses and backslashes in appearances' do
      described_class.fill_form(template, output, { 'name' => 'A (B) \\ C' }, flatten: true)
      expect(reader.pages.first.text).to include('A (B) \\ C')
    end

    it 'raises on documents without an AcroForm' do
      plain = FixturePdf.write(@dir, acroform: false)
      expect do
        described_class.fill_form(plain, output, { 'name' => 'x' })
      end.to raise_error(Acrofill::Error, /AcroForm/)
    end

    it 'produces output parseable in a fill -> fill round trip' do
      described_class.fill_form(template, output, { 'name' => 'First' })
      second = File.join(@dir, 'second.pdf')
      described_class.fill_form(output, second, { 'amount' => '2' }, flatten: true)
      expect(PDF::Reader.new(second).pages.first.text).to include('First', '2')
    end
  end

  describe 'review regressions' do
    def build_pdf(objects)
      out = +"%PDF-1.4\n"
      offsets = objects.each_with_index.map do |body, idx|
        offset = out.bytesize
        out << "#{idx + 1} 0 obj\n#{body}\nendobj\n"
        offset
      end
      xref = out.bytesize
      out << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
      offsets.each { |o| out << format("%010d 00000 n \n", o) }
      out << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
      path = File.join(@dir, 'review.pdf')
      File.binwrite(path, out.b)
      path
    end

    it 'fills every occurrence of a duplicated fully-qualified name' do
      # Two root fields named "ssn" (e.g. the same value repeated per page).
      path = build_pdf([
                         '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                         '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                         '<< /Fields [5 0 R 6 0 R] /DA (/Helv 10 Tf 0 g) >>',
                         '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R 6 0 R] >>',
                         '<< /Type /Annot /Subtype /Widget /FT /Tx /T (ssn) /Rect [10 700 200 720] >>',
                         '<< /Type /Annot /Subtype /Widget /FT /Tx /T (ssn) /Rect [10 100 200 120] >>'
                       ])
      described_class.fill_form(path, output, { 'ssn' => '123-45-6789' }, flatten: true)

      text = PDF::Reader.new(output).pages.first.text
      expect(text.scan('123-45-6789').size).to eq(2)
    end

    it 'honours an indirect /F flag instead of misreading the object number' do
      # /F is a reference to object 7, whose value 0 means "visible" —
      # but 7 & 2 != 0 would wrongly mark it hidden if read as an id.
      path = build_pdf([
                         '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                         '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                         '<< /Fields [5 0 R] /DA (/Helv 10 Tf 0 g) >>',
                         '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                         '<< /Type /Annot /Subtype /Widget /FT /Tx /T (v) /F 7 0 R /Rect [10 700 200 720] >>',
                         "<< /Length 0 >>\nstream\nendstream",
                         '0'
                       ])
      described_class.fill_form(path, output, { 'v' => 'VISIBLE' }, flatten: true)
      expect(PDF::Reader.new(output).pages.first.text).to include('VISIBLE')
    end

    it 'degrades instead of raising on invalid UTF-16 field names' do
      path = build_pdf([
                         '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                         '<< /Type /Pages /Kids [] /Count 0 >>',
                         '<< /Fields [4 0 R] >>',
                         '<< /FT /Tx /T <FEFFD800> /Rect [0 0 10 10] >>'
                       ])
      expect { described_class.fields(path) }.not_to raise_error
    end

    it 'accepts values in foreign or broken encodings without raising' do
      described_class.fill_form(
        template, output,
        { 'name' => "caf\xE9".b, 'amount' => 'wide'.encode('UTF-16LE') }
      )
      expect(File).to exist(output)
    end

    it 'keeps comma font names from /DA instead of falling back to Helvetica' do
      path = build_pdf([
                         '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                         '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                         '<< /Fields [5 0 R] /DA (/Helv 0 Tf 0 g) ' \
                         '/DR << /Font << /Arial,Bold 6 0 R >> >> >>',
                         '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                         '<< /Type /Annot /Subtype /Widget /FT /Tx /T (n) ' \
                         '/Rect [10 700 200 720] /DA (/Arial,Bold 10 Tf 0 g) >>',
                         '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>'
                       ])
      described_class.fill_form(path, output, { 'n' => 'Bold Text' })
      stream = appearance_streams.first
      expect(stream).to include('/Arial,Bold 10 Tf')
    end
  end

  describe Acrofill::Template do
    it 'fills repeatedly from one parse with no state leaking between fills' do
      tpl = described_class.new(template)
      first = File.join(@dir, 'first.pdf')
      second = File.join(@dir, 'second.pdf')

      tpl.fill_form(first, { 'name' => 'Jane' }, flatten: true)
      tpl.fill_form(second, { 'amount' => '42' }, flatten: true)

      first_text = PDF::Reader.new(first).pages.first.text
      second_text = PDF::Reader.new(second).pages.first.text
      expect(first_text).to include('Jane')
      expect(second_text).to include('42')
      expect(second_text).not_to include('Jane') # no bleed from the first fill
    end

    it 'produces byte-identical output to the one-shot API' do
      tpl = described_class.new(template)
      via_template = File.join(@dir, 'tpl.pdf')
      one_shot = File.join(@dir, 'once.pdf')
      data = { 'name' => 'Same Input', 'agree' => 'Yes' }

      tpl.fill_form(via_template, data, flatten: true)
      Acrofill.fill_form(template, one_shot, data, flatten: true)

      expect(File.binread(via_template)).to eq(File.binread(one_shot))
    end

    it 'lists fields without re-reading the file' do
      tpl = described_class.new(template)
      File.delete(template)
      expect(tpl.field_names).to include('name', 'agree', 'week.0')
    end

    it 'reports pristine field values even after fills' do
      tpl = described_class.new(template)
      tpl.fill_form(File.join(@dir, 'filled.pdf'), { 'name' => 'Jane' })

      name = tpl.fields.find { |f| f.name == 'name' }
      expect(name.value).to be_nil # the snapshot is never mutated by a fill
    end
  end

  describe '.fields' do
    it 'lists every terminal field with type and states' do
      listed = described_class.fields(template)
      # Plain Ruby on purpose — index_by is ActiveSupport and this gem
      # must run without Rails.
      by_name = listed.to_h { |f| [f.name, f] }

      expect(by_name.keys).to contain_exactly(
        'name', 'amount', 'auto', 'week.0', 'agree', 'color', 'notes'
      )
      expect(by_name['name'].type).to eq(:Tx)
      expect(by_name['agree'].type).to eq(:Btn)
      expect(by_name['agree'].states).to eq([:Yes])
      expect(by_name['color'].states).to contain_exactly(:Red, :Blue)
    end
  end

  describe 'checkbox and radio fields' do
    def field(rdr, name)
      fields = rdr.objects.deref(acroform(rdr)[:Fields])
      fields.map { |f| rdr.objects.deref(f) }.find { |f| f[:T] == name }
    end

    it 'checks a checkbox via its state name and via truthy values' do
      described_class.fill_form(template, output, { 'agree' => 'Yes' })
      rdr = reader
      expect(field(rdr, 'agree')[:V]).to eq(:Yes)
      expect(field(rdr, 'agree')[:AS]).to eq(:Yes)
    end

    it 'checks a single-state checkbox with any non-off value' do
      described_class.fill_form(template, output, { 'agree' => 'X' })
      expect(field(reader, 'agree')[:V]).to eq(:Yes)
    end

    it 'unchecks with Off and empty values' do
      described_class.fill_form(template, output, { 'agree' => 'Off' })
      expect(field(reader, 'agree')[:V]).to eq(:Off)
    end

    it 'selects a radio state and updates only the matching kid widget' do
      described_class.fill_form(template, output, { 'color' => 'Blue' })
      rdr = reader
      color = field(rdr, 'color')
      kids = rdr.objects.deref(color[:Kids]).map { |k| rdr.objects.deref(k) }
      expect(color[:V]).to eq(:Blue)
      # Plain Ruby on purpose — pluck is ActiveSupport.
      expect(kids.map { |k| k[:AS] }).to eq(%i[Off Blue])
    end

    it 'ignores ambiguous truthy values for multi-state groups' do
      described_class.fill_form(template, output, { 'color' => 'X' })
      expect(field(reader, 'color')[:V]).to be_nil
    end

    it 'flattens the selected state appearance onto the page' do
      described_class.fill_form(template, output, { 'agree' => 'Yes' }, flatten: true)
      expect(acroform).to be_nil
    end
  end

  describe 'multiline fields' do
    it 'wraps long values across lines honouring explicit breaks' do
      described_class.fill_form(
        template, output,
        { 'notes' => "first paragraph with several words repeated words\nsecond" }
      )

      stream = appearance_streams.first
      expect(stream.scan('Tj').size).to be > 1
      expect(stream).to include('TL')
      expect(stream).to include('(second)')
    end

    it 'breaks lines at the last word that still fits the box' do
      # The "notes" widget is 200pt wide, so 196pt of usable text at 10pt
      # Helvetica. This pins the break point: measuring words with anything
      # other than the real glyph widths moves it by a word.
      described_class.fill_form(
        template, output,
        { 'notes' => 'and a much longer second line that has to wrap somewhere' }
      )

      lines = appearance_streams.first.scan(/\((.*)\) Tj/).flatten
      expect(lines).to eq(['and a much longer second line that has to', 'wrap somewhere'])
    end
  end

  describe 'appearance layout' do
    it 'centers /Q 1 fields and left-aligns /Q 0 fields' do
      described_class.fill_form(template, output, { 'name' => 'Hi', 'amount' => 'Hi' })

      tds = appearance_streams.map { |s| s[/^([\d.]+) [\d.]+ Td/, 1].to_f }.sort
      expect(tds.first).to eq(2.0)      # left padding
      expect(tds.last).to be > 90       # centered in a 200pt-wide box
    end

    it 'shrinks oversized values to fit the field width' do
      described_class.fill_form(template, output, { 'name' => 'W' * 100 })

      size = appearance_streams.first[%r{/Helv ([\d.]+) Tf}, 1].to_f
      expect(size).to be < 10
      expect(size).to be >= 2
    end

    it 'uses auto font size for 0 Tf default appearances' do
      described_class.fill_form(template, output, { 'auto' => 'Hello' })

      size = appearance_streams.first[%r{/Helv ([\d.]+) Tf}, 1].to_f
      expect(size).to be_between(4, 13)
    end

    it 'right-aligns /Q 2 fields' do
      path = RawPdf.write(@dir, [
                            '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                            '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                            '<< /Fields [5 0 R] /DA (/Helv 10 Tf 0 g) >>',
                            '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                            '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) ' \
                            '/Rect [0 0 200 20] /DA (/Helv 10 Tf 0 g) /Q 2 >>'
                          ])
      described_class.fill_form(path, output, { 'x' => 'Hi' })

      x = appearance_streams.first[/^([\d.]+) [\d.-]+ Td/, 1].to_f
      # 200 - 2 (padding) - width("Hi" at 10pt Helvetica, 9.44pt) = 188.56
      expect(x).to be_within(0.5).of(188.56)
    end

    it 'centers each wrapped line independently for /Q 1 multiline fields' do
      path = RawPdf.write(@dir, [
                            '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                            '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                            '<< /Fields [5 0 R] /DA (/Helv 10 Tf 0 g) >>',
                            '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                            '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) ' \
                            '/Rect [0 0 200 100] /DA (/Helv 10 Tf 0 g) /Ff 4096 /Q 1 >>'
                          ])
      described_class.fill_form(path, output, { 'x' => "aa bbbb\ncc" })

      stream = appearance_streams.first
      # First line "aa bbbb" is 36.14pt wide: centered x = (200 - 36.14) / 2.
      expect(stream[/^([\d.]+) [\d.-]+ Td/, 1].to_f).to be_within(0.5).of(81.93)
      # Second line "cc" is 10pt wide: its Td is relative, x = 95 - 81.93.
      expect(stream[/^([\d.-]+) 0 Td/, 1].to_f).to be_within(0.5).of(13.07)
    end
  end

  describe 'flattening' do
    def all_stream_data(path)
      data = +''
      PDF::Reader.new(path).objects.each do |_ref, obj|
        data << obj.data << "\n" if obj.is_a?(PDF::Reader::Stream)
      end
      data
    end

    it 'maps the appearance /Matrix into the stamp transform' do
      ap_content = "0 0 m S\n"
      path = RawPdf.write(@dir, [
                            '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                            '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                            '<< /Fields [] >>',
                            '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                            '<< /Type /Annot /Subtype /Widget /Rect [100 100 120 120] /AP << /N 6 0 R >> >>',
                            '<< /Type /XObject /Subtype /Form /BBox [0 0 10 10] /Matrix [2 0 0 2 0 0] ' \
                            "/Length #{ap_content.bytesize} >>\nstream\n#{ap_content}endstream"
                          ])
      described_class.fill_form(path, output, {}, flatten: true)

      # /Matrix doubles the 10x10 BBox to a 20-unit extent, which exactly
      # fills the 20-unit /Rect: unit scale, translated to (100, 100).
      # Ignoring the /Matrix would produce "2 0 0 2 100 100 cm" instead.
      expect(all_stream_data(output)).to include('q 1 0 0 1 100 100 cm /AcrofillAP1 Do Q')
    end

    it 'stamps the selected checkbox state and drops unselected appearances' do
      check_ops = '2 2 m 10 10 l' # the /Yes appearance drawing in the fixture

      described_class.fill_form(template, output, { 'agree' => 'Yes' }, flatten: true)
      expect(all_stream_data(output)).to include(check_ops)

      unchecked = File.join(@dir, 'unchecked.pdf')
      described_class.fill_form(template, unchecked, {}, flatten: true)
      expect(all_stream_data(unchecked)).not_to include(check_ops)
    end

    it 'drops the orphaned form field objects from the output' do
      described_class.fill_form(template, output, { 'name' => 'Jane' }, flatten: true)

      leftover_fields = []
      reader.objects.each do |_ref, obj|
        leftover_fields << obj if obj.is_a?(Hash) && obj[:T]
      end
      expect(leftover_fields).to be_empty
    end
  end

  describe Acrofill::Serializer do
    subject(:serializer) { described_class.new({}) }

    it 'never emits numbers with a trailing decimal point' do
      expect(serializer.serialize(1.0000000000000007)).to eq('1')
      expect(serializer.serialize(0.5)).to eq('0.5')
      expect(serializer.serialize(-2.25)).to eq('-2.25')
      expect(serializer.serialize(21.36)).to eq('21.36')
    end

    it 'escapes irregular characters in names' do
      expect(serializer.serialize(:'A B#C')).to eq('/A#20B#23C')
    end

    it 'writes strings as hex' do
      expect(serializer.serialize('AB')).to eq('<4142>')
    end
  end
end
