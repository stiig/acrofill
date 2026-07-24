# frozen_string_literal: true

module Acrofill
  # Builds the /AP /N appearance stream (a Form XObject) for a filled
  # text-field widget, honouring the field's /DA string and /Q alignment.
  class Appearance
    PADDING = 2.0
    ASCENT = 0.718 # Helvetica cap-height-ish ascent, em fractions
    DESCENT = 0.207
    # Colour-setting operators allowed in a /DA string, and their operand counts.
    COLOR_OP_ARITY = { 'g' => 1, 'rg' => 3, 'k' => 4 }.freeze

    def initialize(doc, acroform)
      @doc = doc
      @acroform = acroform
    end

    # Returns a Reference to the new appearance XObject, or nil when the
    # widget geometry is unusable.
    def build(field_node, widget, value, multiline: false)
      rect = normalized_rect(widget[:Rect] || @doc.inherited_value(field_node, :Rect))
      return nil unless rect

      width = rect[2] - rect[0]
      height = rect[3] - rect[1]
      return nil if width <= 0 || height <= 0

      font_name, size, color_ops = parse_da(field_node)
      base_font = base_font_for(font_name)
      align = @doc.inherited_value(field_node, :Q) || @acroform[:Q] || 0

      body =
        if multiline
          size = 12.0 if size <= 0
          size = size.clamp(2.0, 144.0)
          multiline_body(value, base_font, size, width, height, align)
        else
          text = printable_text(value)
          size = [height * 0.66, 12.0].min if size.zero?
          size = shrink_to_fit(text, base_font, size, width)
          ty = [(height - (size * (ASCENT - DESCENT))) / 2.0, size * DESCENT].max
          "#{fmt(line_x(text, base_font, size, width, align))} #{fmt(ty)} Td\n" \
            "(#{escape_literal(text)}) Tj\n"
        end

      content = +"/Tx BMC\nq\nBT\n"
      content << "#{color_ops}\n" unless color_ops.empty?
      content << "/#{font_name} #{fmt(size)} Tf\n"
      content << body
      content << "ET\nQ\nEMC\n"

      dict = {
        Type: :XObject,
        Subtype: :Form,
        FormType: 1,
        BBox: [0, 0, width, height],
        Resources: { Font: { font_name.to_sym => font_ref(font_name) } }
      }
      @doc.add(StreamObject.new(dict, content.b))
    end

    private

    def fmt(num)
      Serializer.format_number(num.to_f)
    end

    def line_x(text, base_font, size, width, align)
      text_width = Metrics.string_width(text, base_font, size)
      case align
      when 1 then [(width - text_width) / 2.0, PADDING].max
      when 2 then [width - PADDING - text_width, PADDING].max
      else PADDING
      end
    end

    # Greedy word wrap, top-down, honouring explicit line breaks. Lines
    # that would fall below the box are clipped by the BBox.
    def multiline_body(value, base_font, size, width, height, align)
      max_width = width - (2 * PADDING)
      lines = value.to_s.split(/\r\n|[\r\n]/).flat_map do |paragraph|
        wrap_line(printable_text(paragraph), base_font, size, max_width)
      end

      leading = size * 1.15
      first_y = height - PADDING - (size * ASCENT)
      body = "#{fmt(leading)} TL\n"
      previous_x = 0.0
      lines.each_with_index do |line, index|
        x = line_x(line, base_font, size, width, align)
        body << "#{fmt(x - previous_x)} #{index.zero? ? fmt(first_y) : '0'} Td\n"
        body << "(#{escape_literal(line)}) Tj\nT*\n"
        previous_x = x
      end
      body
    end

    # Greedy wrap. Line and space widths are accumulated incrementally so
    # the cost is O(total characters), not O(words * line-length).
    def wrap_line(text, base_font, size, max_width)
      space = Metrics.string_width(' ', base_font, size)
      lines = ['']
      widths = [0.0]
      text.split.each do |word|
        word_width = Metrics.string_width(word, base_font, size)
        if lines.last.empty?
          lines[-1] = word
          widths[-1] = word_width
        elsif widths.last + space + word_width <= max_width
          lines[-1] = "#{lines.last} #{word}"
          widths[-1] += space + word_width
        else
          lines << word
          widths << word_width
        end
      end
      lines
    end

    def normalized_rect(rect)
      rect = @doc.deref(rect)
      return nil unless rect.is_a?(Array) && rect.size == 4

      xs = [rect[0].to_f, rect[2].to_f].sort
      ys = [rect[1].to_f, rect[3].to_f].sort
      [xs[0], ys[0], xs[1], ys[1]]
    end

    # /DA is e.g. "/Helv 8 Tf 0 g": font + size around Tf, plus a colour.
    # The /DA string is template-controlled and copied into the generated
    # appearance stream, so the font name and colour operators are both
    # sanitized here — otherwise a crafted /DA could inject arbitrary
    # content operators (e.g. rectangle fills) into the output.
    def parse_da(field_node)
      da = @doc.deref(@doc.inherited_value(field_node, :DA)) || @doc.deref(@acroform[:DA]) || '/Helv 0 Tf 0 g'
      return ['Helv', 0.0, '0 g'] unless da.is_a?(String)

      tokens = da.split
      tf = tokens.index('Tf')
      return ['Helv', 0.0, '0 g'] unless tf && tf >= 2

      font = sanitize_font(tokens[tf - 2].to_s.delete_prefix('/'))
      size = tokens[tf - 1].to_f
      color = safe_color_ops(tokens[0...(tf - 2)] + tokens[(tf + 1)..])
      [font, size, color]
    end

    # Only a name made of PDF-regular characters may be written as /Name.
    def sanitize_font(name)
      Serializer::REGULAR_NAME.match?(name) ? name : 'Helv'
    end

    # Keep only well-formed colour-setting operators (g / rg / k) with the
    # right count of numeric operands immediately before them; drop anything
    # else the /DA might carry.
    def safe_color_ops(tokens)
      ops = []
      tokens.each_with_index do |tok, i|
        arity = COLOR_OP_ARITY[tok]
        next unless arity

        operands = tokens[[i - arity, 0].max...i]
        next unless operands.size == arity && operands.all? { |o| o =~ /\A-?\d*\.?\d+\z/ }

        ops << "#{operands.join(' ')} #{tok}"
      end
      ops.empty? ? '0 g' : ops.join(' ')
    end

    # Fixed sizes that overflow the box are scaled down so the whole value
    # stays visible (Acrobat-style best-fit; pdftk would clip instead).
    def shrink_to_fit(text, base_font, size, width)
      max_width = width - (2 * PADDING)
      text_width = Metrics.string_width(text, base_font, size)
      size *= max_width / text_width if text_width > max_width && text_width.positive?
      size.clamp(2.0, 144.0)
    end

    # The font resource dictionary from /AcroForm /DR /Font, or {} when the
    # template supplies a malformed (non-dictionary) /DR or /Font.
    def dr_fonts
      dr = @doc.deref(@acroform[:DR])
      return {} unless dr.is_a?(Hash)

      fonts = @doc.deref(dr[:Font])
      fonts.is_a?(Hash) ? fonts : {}
    end

    def base_font_for(resource_name)
      font = @doc.deref(dr_fonts[resource_name.to_sym])
      base = font.is_a?(Hash) ? font[:BaseFont].to_s : ''
      base.sub(/\A[A-Z]{6}\+/, '')
    end

    def font_ref(resource_name)
      entry = dr_fonts[resource_name.to_sym]
      return @doc.ref_for(entry) if entry

      # Font not present in /DR: register a plain Helvetica.
      @doc.add(Type: :Font, Subtype: :Type1, BaseFont: :Helvetica, Encoding: :WinAnsiEncoding)
    end

    def printable_text(value)
      value.to_s.gsub(/[[:space:]]+/, ' ').strip
           .encode('Windows-1252', invalid: :replace, undef: :replace, replace: '?')
    end

    def escape_literal(text)
      text.b
          .gsub(/[\\()]/) { |ch| "\\#{ch}" }
          .gsub(/[\x00-\x1F]/) { |ch| format('\\%03o', ch.ord) }
    end
  end
end
