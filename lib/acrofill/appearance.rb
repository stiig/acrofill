# frozen_string_literal: true

module Acrofill
  # Builds the /AP /N appearance stream (a Form XObject) for a filled
  # text-field widget, honouring the field's /DA string and /Q alignment.
  class Appearance
    PADDING = 2.0
    # pdftk offsets the first multiline row by 1pt from the box top.
    TOP_OFFSET = 1.0
    # Colour-setting operators allowed in a /DA string, and their operand counts.
    COLOR_OP_ARITY = { 'g' => 1, 'rg' => 3, 'k' => 4 }.freeze

    def initialize(doc, acroform)
      @doc = doc
      @acroform = acroform
      @fonts = Fonts.new(doc, acroform)
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
      font = @fonts.metrics(font_name)
      align = alignment(field_node)

      body =
        if multiline
          size = 12.0 if size <= 0
          size = size.clamp(2.0, 144.0)
          multiline_body(value, font, size, width, height, align)
        else
          text = printable_text(value)
          size = [height * 0.66, 12.0].min if size.zero?
          size = shrink_to_fit(text, font, size, width)
          "#{fmt(line_x(text, font, size, width, align))} #{fmt(baseline(height, font, size))} Td\n" \
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
        Resources: { Font: { font_name.to_sym => @fonts.reference(font_name) } }
      }
      @doc.add(StreamObject.new(dict, content.b))
    end

    private

    def fmt(num)
      Serializer.format_number(num.to_f)
    end

    # Where pdftk puts a single line's baseline: the ascent box centered in
    # the field, but never so low that the descender leaves the box, never so
    # high that the ascender does, and never below the box floor. The last
    # two only bind when the text is taller than the field it sits in, which
    # real forms do hit — a 12pt /DA in a 10.8pt-high field is common.
    def baseline(height, font, size)
      ascent = font.ascent(size)
      highest = height - ascent # baseline putting the ascender at the box top
      return 0.0 if highest <= 0 # the glyphs are taller than the box

      [highest / 2.0, font.descent(size)].max.clamp(0.0, highest)
    end

    # /Q (0 left, 1 center, 2 right), inheritable and possibly indirect.
    def alignment(field_node)
      align = @doc.deref(@doc.inherited_value(field_node, :Q) || @acroform[:Q])
      align.is_a?(Integer) ? align : 0
    end

    def line_x(text, font, size, width, align)
      text_width = Metrics.string_width(text, font.widths, size)
      case align
      when 1 then [(width - text_width) / 2.0, PADDING].max
      when 2 then [width - PADDING - text_width, PADDING].max
      else PADDING
      end
    end

    # Greedy word wrap, top-down, honouring explicit line breaks. Lines
    # that would fall below the box are clipped by the BBox.
    def multiline_body(value, font, size, width, height, align)
      max_width = width - (2 * PADDING)
      lines = value.to_s.split(/\r\n|[\r\n]/).flat_map do |paragraph|
        wrap_line(printable_text(paragraph), font, size, max_width)
      end

      # pdftk spaces rows by the font's FontBBox extent and drops the first
      # baseline by that extent from the top of the box.
      leading = font.line_height(size)
      first_y = height - font.top(size) + TOP_OFFSET
      body = "#{fmt(leading)} TL\n"
      previous_x = 0.0
      lines.each_with_index do |line, index|
        x = line_x(line, font, size, width, align)
        body << "#{fmt(x - previous_x)} #{index.zero? ? fmt(first_y) : '0'} Td\n"
        body << "(#{escape_literal(line)}) Tj\nT*\n"
        previous_x = x
      end
      body
    end

    # Greedy wrap. Line and space widths are accumulated incrementally so
    # the cost is O(total characters), not O(words * line-length).
    def wrap_line(text, font, size, max_width)
      space = Metrics.string_width(' ', font.widths, size)
      lines = ['']
      so_far = [0.0]
      text.split.each do |word|
        word_width = Metrics.string_width(word, font.widths, size)
        if lines.last.empty?
          lines[-1] = word
          so_far[-1] = word_width
        elsif so_far.last + space + word_width <= max_width
          lines[-1] = "#{lines.last} #{word}"
          so_far[-1] += space + word_width
        else
          lines << word
          so_far << word_width
        end
      end
      lines
    end

    # Array entries may legally be indirect objects, so each corner is
    # dereferenced; a rect that is not four numbers is unusable.
    def normalized_rect(rect)
      rect = @doc.deref(rect)
      return nil unless rect.is_a?(Array) && rect.size == 4

      nums = rect.map { |n| @doc.deref(n) }
      return nil unless nums.all?(Numeric)

      xs = [nums[0].to_f, nums[2].to_f].sort
      ys = [nums[1].to_f, nums[3].to_f].sort
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
    def shrink_to_fit(text, font, size, width)
      max_width = width - (2 * PADDING)
      text_width = Metrics.string_width(text, font.widths, size)
      size *= max_width / text_width if text_width > max_width && text_width.positive?
      size.clamp(2.0, 144.0)
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
