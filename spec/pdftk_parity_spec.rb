# frozen_string_literal: true

# Pins the appearance geometry against pdftk-java 3.3.3, measured field by
# field with benchmark/geometry_diff.rb. Every expected number in this file
# was read out of pdftk's own /AP stream, not computed from acrofill: these
# examples fail if a change drifts away from pdftk, which is the whole point
# of the gem being a drop-in replacement.
#
# pdftk writes its placement as `1 0 0 1 x y Tm`, acrofill as `x y Td`; both
# reduce to the same first-baseline coordinate. pdftk rounds the numbers it
# prints to two decimals, hence the 0.01 tolerances.
RSpec.describe 'pdftk geometry parity' do
  around do |example|
    Dir.mktmpdir('acrofill-parity') do |dir|
      @dir = dir
      example.run
    end
  end

  def out
    File.join(@dir, 'o.pdf')
  end

  # One text widget, +width+ x +height+, drawn in +base_font+. +font_extra+
  # is spliced into the /DR font dictionary; +descriptor+, when given, is
  # attached as its /FontDescriptor.
  def template(base_font, height: 20, width: 200, extra: '', size: 10,
               font_extra: '', descriptor: nil, subtype: 'Type1',
               encoding: '/WinAnsiEncoding')
    font = "<< /Type /Font /Subtype /#{subtype} /BaseFont /#{base_font} " \
           "/Encoding #{encoding} #{font_extra} " \
           "#{'/FontDescriptor 7 0 R' if descriptor} >>"
    objects = [
      '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
      '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
      "<< /Fields [5 0 R] /DA (/F1 #{size} Tf 0 g) /DR << /Font << /F1 6 0 R >> >> >>",
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
      '<< /Type /Annot /Subtype /Widget /FT /Tx /T (f) ' \
      "/Rect [50 100 #{50 + width} #{100 + height}] /DA (/F1 #{size} Tf 0 g) #{extra} >>",
      font
    ]
    objects << descriptor if descriptor
    @template_index = @template_index.to_i + 1
    RawPdf.write(@dir, objects, name: "t#{@template_index}.pdf")
  end

  # Every glyph the same width, as a /Widths array over the printable range.
  def uniform_widths(width)
    "/FirstChar 32 /LastChar 126 /Widths [#{Array.new(95, width).join(' ')}]"
  end

  def descriptor(entries)
    '<< /Type /FontDescriptor /FontName /CustomSans /Flags 32 /ItalicAngle 0 ' \
      "/StemV 80 #{entries} >>"
  end

  def stream
    data = nil
    PDF::Reader.new(out).objects.each do |_ref, obj|
      data = obj.data if obj.is_a?(PDF::Reader::Stream) && obj.data.include?('Tj')
    end
    data
  end

  # [x, y] of every drawn line.
  def baselines
    ContentStream.text_positions(stream).map { |x, y, _text| [x, y] }
  end

  describe 'single-line baseline' do
    # pdftk places the baseline at (height - ascender * size) / 2, reading
    # the ascender from the font's own AFM. A fixed Helvetica ascent would
    # put Times 0.18pt and Courier 0.45pt too low.
    {
      'Helvetica' => 6.41,   # ascender 718
      'Times-Roman' => 6.59, # ascender 683
      'Times-Bold' => 6.59,
      'Courier' => 6.85      # ascender 629
    }.each do |base_font, expected|
      it "matches pdftk for #{base_font} in a 20pt box" do
        Acrofill.fill_form(template(base_font), out, { 'f' => 'Hg' })
        expect(baselines.first[1]).to be_within(0.01).of(expected)
      end
    end

    # Real forms carry a /DA size taller than the field it belongs to — a
    # 12pt default in a 10.8pt-high box is common — and there pdftk stops
    # centering: it keeps the ascender inside the box and never drops the
    # baseline below the box floor. Every number measured from pdftk.
    {
      [10.8, 8] => 2.53,   # fits: centered
      [10.8, 10] => 2.07,  # descender would leave the box: floored
      [10.8, 12] => 2.18,  # ascender would leave the box: capped
      [10.8, 14] => 0.748,
      [10.8, 16] => 0.0,   # taller than the box: sits on the floor
      [20, 24] => 2.77,
      [6, 10] => 0.0
    }.each do |(height, size), expected|
      it "matches pdftk for #{size}pt text in a #{height}pt box" do
        Acrofill.fill_form(template('Helvetica', height: height, size: size), out, { 'f' => 'Hg' })
        expect(baselines.first[1]).to be_within(0.01).of(expected)
      end
    end

    it 'matches pdftk across box heights' do
      { 12 => 2.41, 40 => 16.41 }.each do |height, expected|
        Acrofill.fill_form(template('Helvetica', height: height), out, { 'f' => 'Hg' })
        expect(baselines.first[1]).to be_within(0.01).of(expected)
      end
    end
  end

  describe 'horizontal placement' do
    it 'matches pdftk for left, centered and right alignment' do
      { '' => 2.0, '/Q 1' => 82.5, '/Q 2' => 162.99 }.each do |q, expected|
        Acrofill.fill_form(template('Helvetica', extra: q), out, { 'f' => 'Hi there' })
        expect(baselines.first[0]).to be_within(0.01).of(expected)
      end
    end

    it 'matches pdftk on the WinAnsi glyphs that differ from StandardEncoding' do
      # quotesingle (191) and grave (333), not quoteright/quoteleft (222).
      Acrofill.fill_form(template('Helvetica', extra: '/Q 2'), out, { 'f' => "O'Brien's" })
      expect(baselines.first[0]).to be_within(0.01).of(158.06)

      Acrofill.fill_form(template('Helvetica', extra: '/Q 2'), out, { 'f' => '`x`' })
      expect(baselines.first[0]).to be_within(0.01).of(186.34)
    end

    it 'matches pdftk for a bold serif face' do
      Acrofill.fill_form(template('Times-Bold', width: 300, extra: '/Q 1'), out,
                         { 'f' => 'Centered Bold Serif' })
      expect(baselines.first[0]).to be_within(0.01).of(107.5)
    end
  end

  describe "the template's own font metrics" do
    # A form that embeds its face carries the metrics in the font dictionary,
    # and pdftk lays the value out with those, not with the standard-14
    # tables. Measuring "MMMMMMMMMM" right-aligned in a 300pt box turns a
    # width error straight into an x error.
    it 'measures with /Widths from the font dictionary' do
      Acrofill.fill_form(template('Helvetica', width: 300, extra: '/Q 2',
                                               font_extra: uniform_widths(1000)),
                         out, { 'f' => 'M' * 10 })
      expect(baselines.first[0]).to be_within(0.01).of(198.0) # 300 - 2 - 10 * 10pt

      Acrofill.fill_form(template('ABCDEF+CustomSans', width: 300, extra: '/Q 2',
                                                       subtype: 'TrueType', font_extra: uniform_widths(400)),
                         out, { 'f' => 'M' * 10 })
      expect(baselines.first[0]).to be_within(0.01).of(258.0) # 300 - 2 - 10 * 4pt
    end

    it 'draws codes outside /FirstChar../LastChar as zero-width' do
      # pdftk does not consult /MissingWidth: setting it changes nothing.
      letters = "/FirstChar 65 /LastChar 90 /Widths [#{Array.new(26, 500).join(' ')}]"
      Acrofill.fill_form(template('ABCDEF+CustomSans', width: 300, extra: '/Q 2',
                                                       subtype: 'TrueType', font_extra: letters),
                         out, { 'f' => 'aa' })
      expect(baselines.first[0]).to be_within(0.01).of(298.0)
    end

    it 'keeps the standard-14 ascender when only the widths are overridden' do
      Acrofill.fill_form(template('Helvetica', font_extra: uniform_widths(1000)),
                         out, { 'f' => 'Hg' })
      expect(baselines.first[1]).to be_within(0.01).of(6.41)
    end

    it 'places the baseline from /FontDescriptor /Ascent' do
      Acrofill.fill_form(template('Helvetica', descriptor: descriptor('/Ascent 900 /Descent -300')),
                         out, { 'f' => 'Hg' })
      expect(baselines.first[1]).to be_within(0.01).of(5.5) # (20 - 9) / 2
    end

    it "falls back to pdftk's 0.8 ascent for a face with no metrics at all" do
      Acrofill.fill_form(template('ABCDEF+CustomSans', subtype: 'TrueType',
                                                       font_extra: uniform_widths(1000)),
                         out, { 'f' => 'Hg' })
      expect(baselines.first[1]).to be_within(0.01).of(6.0) # (20 - 8) / 2
    end
  end

  describe 'comb fields' do
    # A comb splits the box into /MaxLen cells and centers one character in
    # each; /Q chooses which run of cells the value occupies. Every x below
    # was read from pdftk (200pt box, 10pt Helvetica, so 40pt cells).
    def comb(value, cells: 5, align: '', width: 200)
      Acrofill.fill_form(
        template('Helvetica', width: width, extra: "/Ff #{1 << 24} /MaxLen #{cells} #{align}"),
        out, { 'f' => value }
      )
      baselines.map(&:first)
    end

    # pdftk prints two decimals, so each cell is compared with the same
    # 0.01 tolerance used throughout this file.
    def expect_cells(actual, expected)
      expect(actual.size).to eq(expected.size)
      actual.zip(expected).each { |got, want| expect(got).to be_within(0.01).of(want) }
    end

    it 'centers each character in its own cell' do
      expect_cells(comb('AB'), [16.66, 56.67])
      expect_cells(comb('ABCDE'), [16.66, 56.67, 96.39, 136.39, 176.66])
    end

    it 'scales the cells to /MaxLen' do
      expect_cells(comb('AB', cells: 4), [21.66, 71.67]) # 50pt cells
    end

    it 'places the value in the middle cells for /Q 1' do
      expect_cells(comb('AB', align: '/Q 1'), [56.67, 96.67])
      expect_cells(comb('ABC', align: '/Q 1'), [56.67, 96.67, 136.39])
    end

    it 'places the value in the last cells for /Q 2' do
      expect_cells(comb('AB', align: '/Q 2'), [136.66, 176.66])
    end

    it 'keeps going past the last cell when the value overflows' do
      expect(comb('ABCDEFG').size).to eq(7)
    end
  end

  describe 'font encoding' do
    it 'draws the codes the font maps the value to, not the raw bytes' do
      # /Differences puts glyph Z at code 65 and glyph A at code 90, so the
      # value "AZ" has to be written as the bytes "ZA" to draw "AZ" —
      # exactly what pdftk emits.
      Acrofill.fill_form(
        template('Helvetica',
                 encoding: '<< /Type /Encoding /BaseEncoding /WinAnsiEncoding ' \
                           '/Differences [65 /Z 90 /A] >>'),
        out, { 'f' => 'AZ' }
      )
      expect(stream).to include('(ZA) Tj')
    end

    it 'leaves the value alone when /Differences match WinAnsi anyway' do
      # Real templates ship a /Differences array that merely restates the
      # WinAnsi assignments; that must not perturb anything.
      Acrofill.fill_form(
        template('Helvetica',
                 encoding: '<< /Type /Encoding /Differences [39 /quotesingle 96 /grave] >>'),
        out, { 'f' => "a'b" }
      )
      expect(stream).to include("(a'b) Tj")
    end
  end

  describe 'multiline rows' do
    # pdftk drops the first baseline by the FontBBox top (less a 1pt offset)
    # and spaces rows by the full FontBBox extent, not by a flat multiple of
    # the point size.
    it 'matches pdftk for Helvetica' do
      Acrofill.fill_form(template('Helvetica', height: 200, extra: '/Ff 4096'), out,
                         { 'f' => 'and a much longer second line that has to wrap somewhere' })
      ys = baselines.map(&:last)
      expect(ys[0]).to be_within(0.01).of(191.69)
      expect(ys[1]).to be_within(0.01).of(180.13) # leading 11.56
    end

    it "spaces rows by the descriptor's /FontBBox" do
      wrapping = 'aa bb cc dd ee ff gg hh ii jj kk ll'
      box = descriptor('/Ascent 900 /Descent -300 /FontBBox [-200 -400 1000 950]')
      Acrofill.fill_form(template('ABCDEF+CustomSans', height: 200, width: 100, extra: '/Ff 4096',
                                                       subtype: 'TrueType', font_extra: uniform_widths(1000),
                                                       descriptor: box),
                         out, { 'f' => wrapping })
      ys = baselines.map(&:last)
      expect(ys[0]).to be_within(0.01).of(191.5)          # 200 - 9.5 + 1
      expect(ys[0] - ys[1]).to be_within(0.01).of(13.5)   # (950 + 400) / 100

      Acrofill.fill_form(template('ABCDEF+CustomSans', height: 200, width: 100, extra: '/Ff 4096',
                                                       subtype: 'TrueType', font_extra: uniform_widths(1000)),
                         out, { 'f' => wrapping })
      ys = baselines.map(&:last)
      expect(ys[0]).to be_within(0.01).of(192.0)          # default box top 900
      expect(ys[0] - ys[1]).to be_within(0.01).of(11.0)   # default extent 900..-200
    end

    it 'matches pdftk for Times-Roman, whose FontBBox is shorter' do
      Acrofill.fill_form(template('Times-Roman', height: 200, extra: '/Ff 4096'), out,
                         { 'f' => 'aaa bbb ccc ddd eee fff ggg hhh iii jjj kkk lll mmm' })
      ys = baselines.map(&:last)
      expect(ys[0]).to be_within(0.01).of(192.02)
      expect(ys[0] - ys[1]).to be_within(0.01).of(11.16) # vs 11.56 for Helvetica
    end
  end
end
