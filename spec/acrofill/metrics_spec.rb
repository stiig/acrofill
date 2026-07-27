# frozen_string_literal: true

RSpec.describe Acrofill::Metrics do
  def width(text, font)
    described_class.string_width(text, font, 1000)
  end

  it 'measures each standard-14 cut with its own widths' do
    # Times-Bold M is 944/1000 em, Times-Roman M is 889.
    expect(width('M', 'Times-Bold')).to be_within(0.01).of(944)
    expect(width('M', 'Times-Roman')).to be_within(0.01).of(889)
    expect(width('M', 'Times-Italic')).to be_within(0.01).of(833)
  end

  it 'measures the whole Courier family as monospaced' do
    %w[Courier Courier-Bold Courier-BoldOblique].each do |font|
      expect(width('iM', font)).to be_within(0.01).of(1200)
    end
  end

  it 'gives the oblique cuts of Helvetica the upright widths' do
    expect(width('Wij', 'Helvetica-Oblique')).to eq(width('Wij', 'Helvetica'))
    expect(width('Wij', 'Helvetica-BoldOblique')).to eq(width('Wij', 'Helvetica-Bold'))
  end

  it 'classifies the PostScript names real templates carry' do
    expect(described_class.widths_for('ArialMT')).to be(described_class::WIDTHS['Helvetica'])
    expect(described_class.widths_for('Arial-BoldMT'))
      .to be(described_class::WIDTHS['Helvetica-Bold'])
    expect(described_class.widths_for('TimesNewRomanPS-BoldItalicMT'))
      .to be(described_class::WIDTHS['Times-BoldItalic'])
    expect(described_class.widths_for('CourierNewPSMT')).to be(described_class::WIDTHS['Courier'])
  end

  it 'does not mistake a sans-serif name for a serif one' do
    expect(described_class.widths_for('DejaVuSans')).to be(described_class::WIDTHS['Helvetica'])
  end

  it 'falls back to Helvetica for an unknown face' do
    expect(described_class.widths_for('SomeEmbeddedFace')).to be(described_class::WIDTHS['Helvetica'])
  end

  it 'uses WinAnsi widths, matching the encoding appearances are written in' do
    # Code 39 is quotesingle (191) under WinAnsiEncoding, not the
    # StandardEncoding quoteright (222) that appearances never emit.
    expect(width("'", 'Helvetica')).to be_within(0.01).of(191)
  end

  it 'measures Windows-1252 accented characters instead of guessing' do
    expect(width('é', 'Helvetica')).to be_within(0.01).of(width('e', 'Helvetica'))
    expect(width('W', 'Helvetica')).to be > width('é', 'Helvetica')
  end
end
