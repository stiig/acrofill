# frozen_string_literal: true

module Acrofill
  # Builds the /AP /N appearance stream (a Form XObject) for a filled
  # text-field widget, honouring the field's /DA string and /Q alignment.
  class Appearance
    PADDING = 2.0
    # pdftk offsets the first multiline row by 1pt from the box top.
    TOP_OFFSET = 1.0

    # The drawable area of one widget: its size and the field's /Q.
    Box = Struct.new(:width, :height, :align)
    # Colour-setting operators allowed in a /DA string, and their operand counts.
    COLOR_OP_ARITY = { 'g' => 1, 'rg' => 3, 'k' => 4 }.freeze

    def initialize(doc, acroform)
      @doc = doc
      @acroform = acroform
      @fonts = Fonts.new(doc, acroform)
    end

    # Returns a Reference to the new appearance XObject, or nil when the
    # widget geometry is unusable.
    def build(field_node, widget, value, multiline: false, comb: nil)
      rect = normalized_rect(widget[:Rect] || @doc.inherited_value(field_node, :Rect))
      return nil unless rect

      box = Box.new(rect[2] - rect[0], rect[3] - rect[1], alignment(field_node))
      return nil if box.width <= 0 || box.height <= 0

      font_name, size, color_ops = parse_da(field_node)
      font = @fonts.metrics(font_name)
      size, body = draw(value, font, size, box, multiline: multiline, comb: comb)

      @doc.add(StreamObject.new(appearance_dict(font_name, box),
                                content(font_name, size, color_ops, body).b))
    end

    private

    def fmt(num)
      Serializer.format_number(num.to_f)
    end

    # The operators drawing +value+, and the point size they were laid out
    # at — auto-sizing and shrink-to-fit both adjust the /DA size.
    def draw(value, font, size, box, multiline:, comb:)
      if multiline
        size = (size <= 0 ? 12.0 : size).clamp(2.0, 144.0)
        [size, multiline_body(value, font, size, box)]
      elsif comb
        size = auto_size(size, box.height).clamp(2.0, 144.0)
        [size, comb_body(font.encode(printable_text(value)), font, size, box, comb)]
      else
        text = font.encode(printable_text(value))
        size = shrink_to_fit(text, font, auto_size(size, box.height), box.width)
        [size, "#{fmt(line_x(text, font, size, box))} #{fmt(baseline(box.height, font, size))} Td\n" \
               "(#{escape_literal(text)}) Tj\n"]
      end
    end

    # A /DA size of 0 means "fit the box"; acrofill caps that at 12pt.
    def auto_size(size, height)
      size.zero? ? [height * 0.66, 12.0].min : size
    end

    def content(font_name, size, color_ops, body)
      stream = +"/Tx BMC\nq\nBT\n"
      stream << "#{color_ops}\n" unless color_ops.empty?
      stream << "/#{font_name} #{fmt(size)} Tf\n"
      stream << body
      stream << "ET\nQ\nEMC\n"
    end

    def appearance_dict(font_name, box)
      {
        Type: :XObject,
        Subtype: :Form,
        FormType: 1,
        BBox: [0, 0, box.width, box.height],
        Resources: { Font: { font_name.to_sym => @fonts.reference(font_name) } }
      }
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

    def line_x(text, font, size, box)
      text_width = Metrics.string_width(text, font.widths, size)
      case box.align
      when 1 then [(box.width - text_width) / 2.0, PADDING].max
      when 2 then [box.width - PADDING - text_width, PADDING].max
      else PADDING
      end
    end

    # A comb field divides its box into /MaxLen equal cells and centers one
    # character in each; /Q picks the run of cells the value occupies. Each
    # glyph is positioned absolutely, the way pdftk writes it.
    def comb_body(text, font, size, box, cells)
      cell = box.width / cells.to_f
      chars = text.chars
      first = case box.align
              when 1 then [(cells - chars.size) / 2, 0].max
              when 2 then [cells - chars.size, 0].max
              else 0
              end
      ty = fmt(baseline(box.height, font, size))
      chars.each_with_index.map do |char, index|
        x = ((first + index + 0.5) * cell) - (Metrics.string_width(char, font.widths, size) / 2.0)
        "1 0 0 1 #{fmt(x)} #{ty} Tm\n(#{escape_literal(char)}) Tj\n"
      end.join
    end

    # Greedy word wrap, top-down, honouring explicit line breaks. Lines
    # that would fall below the box are clipped by the BBox.
    def multiline_body(value, font, size, box)
      max_width = box.width - (2 * PADDING)
      lines = value.to_s.split(/\r\n|[\r\n]/).flat_map do |paragraph|
        wrap_line(font.encode(printable_text(paragraph)), font, size, max_width)
      end

      # pdftk spaces rows by the font's FontBBox extent and drops the first
      # baseline by that extent from the top of the box.
      leading = font.line_height(size)
      first_y = box.height - font.top(size) + TOP_OFFSET
      body = "#{fmt(leading)} TL\n"
      previous_x = 0.0
      lines.each_with_index do |line, index|
        x = line_x(line, font, size, box)
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
