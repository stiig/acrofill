# frozen_string_literal: true

module Acrofill
  # Glyph widths (1/1000 em) for the standard-14 text fonts, indexed by
  # WinAnsiEncoding code minus 32 (appearance streams are written as
  # Windows-1252 bytes against a /WinAnsiEncoding font, so the byte emitted
  # is the byte measured). Extracted from Adobe AFM metrics.
  #
  # Only six width tables are stored: the oblique cuts of Helvetica have the
  # same widths as the upright face, and the whole Courier family is
  # monospaced. Vertical metrics (ascender, descender, FontBBox extent) are
  # per cut, since they differ where widths do not.
  module Metrics
    DEFAULT_WIDTH = 556
    COURIER_WIDTH = 600
    FIRST_CODE = 32
    LAST_CODE = 255
    WINDOWS_1252 = Encoding::Windows_1252

    # The standard-14 text cuts, indexed by bold + 2 * italic per family.
    CUTS = {
      helvetica: %w[Helvetica Helvetica-Bold Helvetica-Oblique Helvetica-BoldOblique].freeze,
      times: %w[Times-Roman Times-Bold Times-Italic Times-BoldItalic].freeze,
      courier: %w[Courier Courier-Bold Courier-Oblique Courier-BoldOblique].freeze
    }.freeze
    # Family and weight hints for BaseFont names outside the standard 14.
    SERIF = /times|roman|serif|georgia|garamond/
    SANS = /sans/
    FIXED = /courier|mono/
    BOLD = /bold|black|heavy/
    ITALIC = /italic|oblique/

    TABLES = {
      'Helvetica' => [
        278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, 556,
        556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, 1015, 667,
        667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, 667, 778, 722,
        667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, 333, 556, 556, 500,
        556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500, 278,
        556, 500, 722, 500, 500, 500, 334, 260, 334, 584, nil, 556, nil, 222, 556, 333, 1000,
        556, 556, 333, 1000, 667, 333, 1000, nil, 611, nil, nil, 222, 222, 333, 333, 350, 556,
        1000, 333, 1000, 500, 333, 944, nil, 500, 667, 278, 333, 556, 556, 556, 556, 260, 556,
        333, 737, 370, 556, 584, 333, 737, 333, 400, 584, 333, 333, 333, 556, 537, 278, 333,
        333, 365, 556, 834, 834, 834, 611, 667, 667, 667, 667, 667, 667, 1000, 722, 667, 667,
        667, 667, 278, 278, 278, 278, 722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722,
        722, 722, 667, 667, 611, 556, 556, 556, 556, 556, 556, 889, 500, 556, 556, 556, 556,
        278, 278, 278, 278, 556, 556, 556, 556, 556, 556, 556, 584, 611, 556, 556, 556, 556,
        500, 556, 500
      ].freeze,
      'Helvetica-Bold' => [
        278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278, 556,
        556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611, 975, 722,
        722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778, 667, 778, 722,
        667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556, 333, 556, 611, 556,
        611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611, 611, 611, 389, 556, 333,
        611, 556, 778, 556, 556, 500, 389, 280, 389, 584, nil, 556, nil, 278, 556, 500, 1000,
        556, 556, 333, 1000, 667, 333, 1000, nil, 611, nil, nil, 278, 278, 500, 500, 350, 556,
        1000, 333, 1000, 556, 333, 944, nil, 500, 667, 278, 333, 556, 556, 556, 556, 280, 556,
        333, 737, 370, 556, 584, 333, 737, 333, 400, 584, 333, 333, 333, 611, 556, 278, 333,
        333, 365, 556, 834, 834, 834, 611, 722, 722, 722, 722, 722, 722, 1000, 722, 667, 667,
        667, 667, 278, 278, 278, 278, 722, 722, 778, 778, 778, 778, 778, 584, 778, 722, 722,
        722, 722, 667, 667, 611, 556, 556, 556, 556, 556, 556, 889, 556, 556, 556, 556, 556,
        278, 278, 278, 278, 611, 611, 611, 611, 611, 611, 611, 584, 611, 611, 611, 611, 611,
        556, 611, 556
      ].freeze,
      'Times-Roman' => [
        250, 333, 408, 500, 500, 833, 778, 180, 333, 333, 500, 564, 250, 333, 250, 278, 500,
        500, 500, 500, 500, 500, 500, 500, 500, 500, 278, 278, 564, 564, 564, 444, 921, 722,
        667, 667, 722, 611, 556, 722, 722, 333, 389, 722, 611, 889, 722, 722, 556, 722, 667,
        556, 611, 722, 722, 944, 722, 722, 611, 333, 278, 333, 469, 500, 333, 444, 500, 444,
        500, 444, 333, 500, 500, 278, 278, 500, 278, 778, 500, 500, 500, 500, 333, 389, 278,
        500, 500, 722, 500, 500, 444, 480, 200, 480, 541, nil, 500, nil, 333, 500, 444, 1000,
        500, 500, 333, 1000, 556, 333, 889, nil, 611, nil, nil, 333, 333, 444, 444, 350, 500,
        1000, 333, 980, 389, 333, 722, nil, 444, 722, 250, 333, 500, 500, 500, 500, 200, 500,
        333, 760, 276, 500, 564, 333, 760, 333, 400, 564, 300, 300, 333, 500, 453, 250, 333,
        300, 310, 500, 750, 750, 750, 444, 722, 722, 722, 722, 722, 722, 889, 667, 611, 611,
        611, 611, 333, 333, 333, 333, 722, 722, 722, 722, 722, 722, 722, 564, 722, 722, 722,
        722, 722, 722, 556, 500, 444, 444, 444, 444, 444, 444, 667, 444, 444, 444, 444, 444,
        278, 278, 278, 278, 500, 500, 500, 500, 500, 500, 500, 564, 500, 500, 500, 500, 500,
        500, 500, 500
      ].freeze,
      'Times-Bold' => [
        250, 333, 555, 500, 500, 1000, 833, 278, 333, 333, 500, 570, 250, 333, 250, 278, 500,
        500, 500, 500, 500, 500, 500, 500, 500, 500, 333, 333, 570, 570, 570, 500, 930, 722,
        667, 722, 722, 667, 611, 778, 778, 389, 500, 778, 667, 944, 722, 778, 611, 778, 722,
        556, 667, 722, 722, 1000, 722, 722, 667, 333, 278, 333, 581, 500, 333, 500, 556, 444,
        556, 444, 333, 500, 556, 278, 333, 556, 278, 833, 556, 500, 556, 556, 444, 389, 333,
        556, 500, 722, 500, 500, 444, 394, 220, 394, 520, nil, 500, nil, 333, 500, 500, 1000,
        500, 500, 333, 1000, 556, 333, 1000, nil, 667, nil, nil, 333, 333, 500, 500, 350, 500,
        1000, 333, 1000, 389, 333, 722, nil, 444, 722, 250, 333, 500, 500, 500, 500, 220, 500,
        333, 747, 300, 500, 570, 333, 747, 333, 400, 570, 300, 300, 333, 556, 540, 250, 333,
        300, 330, 500, 750, 750, 750, 500, 722, 722, 722, 722, 722, 722, 1000, 722, 667, 667,
        667, 667, 389, 389, 389, 389, 722, 722, 778, 778, 778, 778, 778, 570, 778, 722, 722,
        722, 722, 722, 611, 556, 500, 500, 500, 500, 500, 500, 722, 444, 444, 444, 444, 444,
        278, 278, 278, 278, 500, 556, 500, 500, 500, 500, 500, 570, 500, 556, 556, 556, 556,
        500, 556, 500
      ].freeze,
      'Times-Italic' => [
        250, 333, 420, 500, 500, 833, 778, 214, 333, 333, 500, 675, 250, 333, 250, 278, 500,
        500, 500, 500, 500, 500, 500, 500, 500, 500, 333, 333, 675, 675, 675, 500, 920, 611,
        611, 667, 722, 611, 611, 722, 722, 333, 444, 667, 556, 833, 667, 722, 611, 722, 611,
        500, 556, 722, 611, 833, 611, 556, 556, 389, 278, 389, 422, 500, 333, 500, 500, 444,
        500, 444, 278, 500, 500, 278, 278, 444, 278, 722, 500, 500, 500, 500, 389, 389, 278,
        500, 444, 667, 444, 444, 389, 400, 275, 400, 541, nil, 500, nil, 333, 500, 556, 889,
        500, 500, 333, 1000, 500, 333, 944, nil, 556, nil, nil, 333, 333, 556, 556, 350, 500,
        889, 333, 980, 389, 333, 667, nil, 389, 556, 250, 389, 500, 500, 500, 500, 275, 500,
        333, 760, 276, 500, 675, 333, 760, 333, 400, 675, 300, 300, 333, 500, 523, 250, 333,
        300, 310, 500, 750, 750, 750, 500, 611, 611, 611, 611, 611, 611, 889, 667, 611, 611,
        611, 611, 333, 333, 333, 333, 722, 667, 722, 722, 722, 722, 722, 675, 722, 722, 722,
        722, 722, 556, 611, 500, 500, 500, 500, 500, 500, 500, 667, 444, 444, 444, 444, 444,
        278, 278, 278, 278, 500, 500, 500, 500, 500, 500, 500, 675, 500, 500, 500, 500, 500,
        444, 500, 444
      ].freeze,
      'Times-BoldItalic' => [
        250, 389, 555, 500, 500, 833, 778, 278, 333, 333, 500, 570, 250, 333, 250, 278, 500,
        500, 500, 500, 500, 500, 500, 500, 500, 500, 333, 333, 570, 570, 570, 500, 832, 667,
        667, 667, 722, 667, 667, 722, 778, 389, 500, 667, 611, 889, 722, 722, 611, 722, 667,
        556, 611, 722, 667, 889, 667, 611, 611, 333, 278, 333, 570, 500, 333, 500, 500, 444,
        500, 444, 333, 500, 556, 278, 278, 500, 278, 778, 556, 500, 500, 500, 389, 389, 278,
        556, 444, 667, 500, 444, 389, 348, 220, 348, 570, nil, 500, nil, 333, 500, 500, 1000,
        500, 500, 333, 1000, 556, 333, 944, nil, 611, nil, nil, 333, 333, 500, 500, 350, 500,
        1000, 333, 1000, 389, 333, 722, nil, 389, 611, 250, 389, 500, 500, 500, 500, 220, 500,
        333, 747, 266, 500, 606, 333, 747, 333, 400, 570, 300, 300, 333, 576, 500, 250, 333,
        300, 300, 500, 750, 750, 750, 500, 667, 667, 667, 667, 667, 667, 944, 667, 667, 667,
        667, 667, 389, 389, 389, 389, 722, 722, 722, 722, 722, 722, 722, 570, 722, 722, 722,
        722, 722, 611, 611, 500, 500, 500, 500, 500, 500, 500, 722, 444, 444, 444, 444, 444,
        278, 278, 278, 278, 500, 556, 500, 500, 500, 500, 500, 570, 500, 556, 556, 556, 556,
        444, 500, 444
      ].freeze,
      'Courier' => Array.new(LAST_CODE - FIRST_CODE + 1, COURIER_WIDTH).freeze
    }.freeze

    # Cuts that share a width table with another cut.
    WIDTHS = TABLES.merge(
      'Helvetica-Oblique' => TABLES['Helvetica'],
      'Helvetica-BoldOblique' => TABLES['Helvetica-Bold'],
      'Courier-Bold' => TABLES['Courier'],
      'Courier-Oblique' => TABLES['Courier'],
      'Courier-BoldOblique' => TABLES['Courier']
    ).freeze

    # [ascender, descender, FontBBox top, FontBBox bottom] in 1/1000 em,
    # from the same Adobe AFM data as the widths. pdftk places baselines
    # from the ascender and spaces multiline rows by the FontBBox extent,
    # so these drive vertical geometry.
    VERTICAL = {
      'Helvetica' => [718, -207, 931, -225].freeze,
      'Helvetica-Bold' => [718, -207, 962, -228].freeze,
      'Helvetica-Oblique' => [718, -207, 931, -225].freeze,
      'Helvetica-BoldOblique' => [718, -207, 962, -228].freeze,
      'Times-Roman' => [683, -217, 898, -218].freeze,
      'Times-Bold' => [683, -217, 935, -218].freeze,
      'Times-Italic' => [683, -217, 883, -217].freeze,
      'Times-BoldItalic' => [683, -217, 921, -218].freeze,
      'Courier' => [629, -157, 805, -250].freeze,
      'Courier-Bold' => [629, -157, 801, -250].freeze,
      'Courier-Oblique' => [629, -157, 805, -250].freeze,
      'Courier-BoldOblique' => [629, -157, 801, -250].freeze
    }.freeze

    # Everything the appearance code needs about one resolved face.
    Font = Struct.new(:widths, :ascender, :descender, :bbox_top, :bbox_bottom) do
      def ascent(size) = ascender * size / 1000.0

      def descent(size) = -descender * size / 1000.0

      # Distance from the box top to the first baseline, and between rows.
      def top(size) = bbox_top * size / 1000.0

      def line_height(size) = (bbox_top - bbox_bottom) * size / 1000.0
    end

    FONTS = VERTICAL.to_h do |name, (asc, desc, top, bottom)|
      [name, Font.new(WIDTHS[name], asc, desc, top, bottom).freeze]
    end.freeze

    # Width of +str+ at +size+ points. +widths+ is a table from #widths_for,
    # or a BaseFont name (resolved here, at the cost of the lookup).
    def self.string_width(str, widths, size)
      widths = widths_for(widths) unless widths.is_a?(Array)
      str = to_win_ansi(str)
      units = str.each_byte.sum do |code|
        (code >= FIRST_CODE && widths[code - FIRST_CODE]) || DEFAULT_WIDTH
      end
      units * size / 1000.0
    end

    # Metrics for a BaseFont name. Standard-14 names resolve directly;
    # anything else (ArialMT, TimesNewRomanPS-BoldMT, a template's embedded
    # face) is classified by family and weight, which is far closer than
    # treating everything as Helvetica.
    def self.font_for(base_font)
      FONTS.fetch(canonical_name(base_font))
    end

    def self.widths_for(base_font)
      font_for(base_font).widths
    end

    # Metrics for a name that *is* one of the standard 14, or nil. Unlike
    # #font_for this does not classify: a template's own face only inherits
    # standard-14 vertical metrics when it actually names one.
    def self.standard_font(base_font)
      FONTS[base_font.to_s]
    end

    # Maps any BaseFont name onto one of the twelve standard-14 text cuts.
    def self.canonical_name(base_font)
      name = base_font.to_s
      return name if FONTS.key?(name)

      lower = name.downcase
      family = if FIXED.match?(lower) then :courier
               elsif serif?(lower) then :times
               else :helvetica
               end
      CUTS[family][weight_index(lower)]
    end

    def self.serif?(lower)
      SERIF.match?(lower) && !SANS.match?(lower)
    end

    def self.weight_index(lower)
      (BOLD.match?(lower) ? 1 : 0) + (ITALIC.match?(lower) ? 2 : 0)
    end

    # Appearance text is already Windows-1252; anything else is converted so
    # that measuring and rendering agree byte for byte.
    def self.to_win_ansi(str)
      return str if str.encoding == WINDOWS_1252

      str.encode(WINDOWS_1252, invalid: :replace, undef: :replace, replace: '?')
    end

    private_class_method :serif?, :weight_index, :to_win_ansi
  end
end
