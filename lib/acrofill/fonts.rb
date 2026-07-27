# frozen_string_literal: true

module Acrofill
  # The form's /DR /Font dictionary: the metrics a widget's /DA font resource
  # actually implies, and the reference to put in a generated appearance's
  # /Resources.
  #
  # Real templates embed their own faces, and those font dictionaries carry
  # their own /Widths and /FontDescriptor. The appearance stream is drawn
  # with that very font, so it has to be measured with it too — laying an
  # embedded face out against standard-14 tables misplaces every centered or
  # right-aligned value. pdftk reads the dictionary; these are the same rules,
  # measured against pdftk-java 3.3.3 (see benchmark/geometry_diff.rb):
  #
  #   widths     /Widths + /FirstChar, else the standard-14 table
  #   ascender   /FontDescriptor /Ascent, else standard-14 AFM, else 800
  #   FontBBox   /FontDescriptor /FontBBox, else standard-14 AFM, else 900/-200
  #   codes      /Encoding /Differences remap the value's bytes
  #
  # The standard-14 fallbacks apply only to a BaseFont that literally names
  # one of the fourteen; a face merely *resembling* one (ArialMT and friends)
  # gets pdftk's generic defaults vertically, while its widths still fall back
  # to the closest standard table, there being nothing better to measure with.
  class Fonts
    DEFAULT_ASCENDER = 800
    DEFAULT_DESCENDER = -200
    DEFAULT_BBOX_TOP = 900
    DEFAULT_BBOX_BOTTOM = -200
    # A code outside /FirstChar../LastChar draws as zero-width: pdftk does
    # not consult /MissingWidth (verified — setting it changes nothing).
    OUT_OF_RANGE_WIDTH = 0
    SUBSET_PREFIX = /\A[A-Z]{6}\+/

    def initialize(doc, acroform)
      @doc = doc
      @acroform = acroform
      @metrics = {}
      @references = {}
    end

    # Metrics::Font for the font a /DA string names.
    def metrics(resource_name)
      key = resource_name.to_sym
      @metrics[key] ||= build(@doc.deref(dr_fonts[key]))
    end

    # Indirect reference to that font, for the appearance /Resources. Fonts
    # absent from /DR share one registered Helvetica; a /DR font stored as a
    # direct dictionary is promoted to an indirect object once, not once per
    # widget.
    def reference(resource_name)
      key = resource_name.to_sym
      @references[key] ||=
        begin
          found = dr_fonts[key]
          found ? @doc.ref_for(found) : fallback
        end
    end

    private

    def dr_fonts
      @dr_fonts ||=
        begin
          dr = @doc.deref(@acroform[:DR])
          fonts = dr.is_a?(Hash) ? @doc.deref(dr[:Font]) : nil
          fonts.is_a?(Hash) ? fonts : {}
        end
    end

    def fallback
      @fallback ||=
        @doc.add(Type: :Font, Subtype: :Type1, BaseFont: :Helvetica, Encoding: :WinAnsiEncoding)
    end

    def build(dict)
      return Metrics.font_for('') unless dict.is_a?(Hash)

      name = base_font_name(dict)
      standard = Metrics.standard_font(name)
      ascender, descender, top, bottom = vertical(dict, standard)
      Metrics::Font.new(widths(dict) || Metrics.widths_for(name),
                        ascender, descender, top, bottom,
                        Metrics.remap_for(differences(dict))).freeze
    end

    # /Differences is a flat array where an integer restarts the code
    # counter and each following name takes the next code (PDF 32000
    # §9.6.6.1).
    def differences(dict)
      encoding = @doc.deref(dict[:Encoding])
      return {} unless encoding.is_a?(Hash)

      entries = @doc.deref(encoding[:Differences])
      return {} unless entries.is_a?(Array)

      code = nil
      entries.each_with_object({}) do |raw, result|
        item = @doc.deref(raw)
        case item
        when Integer then code = item
        when Symbol
          next unless code&.between?(0, 255)

          result[code] = item # a glyph name, matching Metrics::WIN_ANSI_GLYPHS
          code += 1
        end
      end
    end

    def base_font_name(dict)
      @doc.deref(dict[:BaseFont]).to_s.sub(SUBSET_PREFIX, '')
    end

    # The font's own glyph widths, laid out the way Metrics tables are
    # (index = code - 32), or nil when the dictionary does not supply usable
    # ones. Only the codes acrofill can emit are read, so a /Widths array of
    # any declared length costs the same.
    def widths(dict)
      first = @doc.deref(dict[:FirstChar])
      declared = @doc.deref(dict[:Widths])
      return nil unless first.is_a?(Integer) && declared.is_a?(Array)

      low = [Metrics::FIRST_CODE - first, 0].max
      high = [Metrics::LAST_CODE - first, declared.size - 1].min
      return nil if high < low

      table = Array.new(Metrics::LAST_CODE - Metrics::FIRST_CODE + 1, OUT_OF_RANGE_WIDTH)
      (low..high).each do |index|
        width = number(declared[index])
        table[first + index - Metrics::FIRST_CODE] = width if width
      end
      table
    end

    def vertical(dict, standard)
      descriptor = @doc.deref(dict[:FontDescriptor])
      descriptor = {} unless descriptor.is_a?(Hash)
      bottom, top = font_bbox(descriptor)
      [
        number(descriptor[:Ascent]) || standard&.ascender || DEFAULT_ASCENDER,
        number(descriptor[:Descent]) || standard&.descender || DEFAULT_DESCENDER,
        top || standard&.bbox_top || DEFAULT_BBOX_TOP,
        bottom || standard&.bbox_bottom || DEFAULT_BBOX_BOTTOM
      ]
    end

    # [lower y, upper y] of /FontBBox, or [nil, nil] when it is unusable.
    def font_bbox(descriptor)
      box = @doc.deref(descriptor[:FontBBox])
      return [nil, nil] unless box.is_a?(Array) && box.size == 4

      [number(box[1]), number(box[3])]
    end

    # Font dictionaries are template data: every scalar may be indirect, and
    # a non-finite one would poison the geometry it feeds.
    def number(raw)
      value = @doc.deref(raw)
      return nil unless value.is_a?(Numeric)

      value = value.to_f
      value.finite? ? value : nil
    end
  end
end
