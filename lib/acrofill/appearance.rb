# frozen_string_literal: true

module Acrofill
  # Builds the /AP /N appearance stream (a Form XObject) for a filled
  # text-field widget, honouring the field's /DA string and /Q alignment.
  class Appearance
    PADDING = 2.0
    # pdftk offsets the first multiline row by 1pt from the box top.
    TOP_OFFSET = 1.0
    DEFAULT_SIZE = 12.0
    MIN_SIZE = 2.0
    MAX_SIZE = 144.0

    # The drawable area of one widget: its size and the field's /Q.
    Box = Struct.new(:width, :height, :align)
    # Colour-setting operators allowed in a /DA string, and their operand counts.
    COLOR_OP_ARITY = { 'g' => 1, 'rg' => 3, 'k' => 4 }.freeze
    # A plain PDF real; exponent notation is not valid PDF number syntax.
    NUMERIC_OPERAND = /\A-?\d*\.?\d+\z/

    def initialize(doc, acroform)
      @doc = doc
      @acroform = acroform
      @fonts = Fonts.new(doc, acroform)
    end

    # Returns a Reference to the new appearance XObject, or nil when the
    # widget geometry is unusable.
    def build(field_node, widget, value, multiline: false, comb: nil)
      rect = @doc.normalized_box(widget[:Rect] || @doc.inherited_value(field_node, :Rect))
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
      # Multiline wraps the raw value, so it encodes paragraph by paragraph.
      if multiline
        pt = legal_size(size <= 0 ? DEFAULT_SIZE : size)
        return [pt, multiline_body(value, font, pt, box)]
      end

      text = font.encode(printable_text(value))
      if comb
        pt = legal_size(auto_size(size, box.height))
        [pt, comb_body(text, font, pt, box, comb)]
      else
        pt = legal_size(shrink_to_fit(text, font, auto_size(size, box.height), box.width))
        [pt, single_line_body(text, font, pt, box)]
      end
    end

    # The bounds every layout branch applies to the size it settled on.
    def legal_size(size)
      size.clamp(MIN_SIZE, MAX_SIZE)
    end

    def single_line_body(text, font, size, box)
      "#{fmt(line_x(text, font, size, box))} #{fmt(baseline(box.height, font, size))} Td\n" \
        "(#{escape_literal(text)}) Tj\n"
    end

    # A /DA size of 0 means "fit the box"; acrofill caps that at 12pt.
    # Multiline uses a flat 12pt instead, which is deliberate. A negative
    # size is as meaningless as a zero one and takes the same path — the
    # multiline branch already treats the two alike, and disagreeing here
    # made one flag bit decide between a 12pt and a 2pt rendering.
    def auto_size(size, height)
      size.positive? ? size : [height * 0.66, DEFAULT_SIZE].min
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

    # +text+ is already in the font's own codes. Left alignment needs no
    # measurement, so it does not pay for one.
    def line_x(text, font, size, box)
      case box.align
      when 1 then [(box.width - font.width_of(text, size)) / 2.0, PADDING].max
      when 2 then [box.width - PADDING - font.width_of(text, size), PADDING].max
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
        x = ((first + index + 0.5) * cell) - (font.width_of(char, size) / 2.0)
        "1 0 0 1 #{fmt(x)} #{ty} Tm\n(#{escape_literal(char)}) Tj\n"
      end.join
    end

    # Greedy word wrap, top-down, honouring explicit line breaks. Lines
    # that would fall below the box are clipped by the BBox.
    def multiline_body(value, font, size, box)
      max_width = box.width - (2 * PADDING)
      # Wrapping runs on the Windows-1252 text, not on the font's codes: a
      # /Encoding that moves the space glyph off code 32 would otherwise
      # leave String#split no word boundary to find, and the whole value
      # would be emitted as one unwrapped line running past the box.
      lines = value.to_s.split(/\r\n|[\r\n]/).flat_map do |paragraph|
        wrap_line(printable_text(paragraph), font, size, max_width)
      end

      # pdftk spaces rows by the font's FontBBox extent and drops the first
      # baseline by that extent from the top of the box. A first row below
      # the box floor is clipped away by the BBox, which would leave the
      # widget blank while /V already holds the new value.
      leading = font.line_height(size)
      first_y = [box.height - font.top(size) + TOP_OFFSET, 0.0].max
      body = "#{fmt(leading)} TL\n"
      previous_x = 0.0
      lines.each_with_index do |line, index|
        encoded = font.encode(line)
        x = line_x(encoded, font, size, box)
        body << "#{fmt(x - previous_x)} #{index.zero? ? fmt(first_y) : '0'} Td\n"
        body << "(#{escape_literal(encoded)}) Tj\nT*\n"
        previous_x = x
      end
      body
    end

    # Greedy wrap over unencoded text. The running width is accumulated
    # incrementally and each line is appended to in place, so the cost is
    # O(total characters), not O(words * line-length).
    def wrap_line(text, font, size, max_width)
      space = measure(' ', font, size)
      lines = [+'']
      width = 0.0
      text.split.each do |word|
        word_width = measure(word, font, size)
        if lines.last.empty?
          lines[-1] = +word
          width = word_width
        elsif width + space + word_width <= max_width
          lines.last << ' ' << word
          width += space + word_width
        else
          lines << +word
          width = word_width
        end
      end
      lines
    end

    # Width of unencoded text in the codes the font actually draws it with.
    def measure(text, font, size)
      font.width_of(font.encode(text), size)
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
      # The two sides of the removed "font size Tf" triple are scanned
      # separately: concatenating them first makes tokens that were never
      # adjacent in the /DA look like a well-formed operator, so
      # "0.2 0.4 /Helv 12 Tf 0.6 rg" would emit "0.2 0.4 0.6 rg" and draw
      # the value in a colour the template never asked for.
      color = safe_color_ops(tokens[0...(tf - 2)], tokens[(tf + 1)..])
      [font, size_of(tokens[tf - 1]), color]
    end

    # The /DA point size, which is template data: a non-finite one would
    # poison every measurement it feeds, so it degrades to 0 — the same
    # "fit the box" request a /DA that omits a size makes.
    def size_of(token)
      size = token.to_f
      size.finite? ? size : 0.0
    end

    # Only a name made of PDF-regular characters may be written as /Name.
    def sanitize_font(name)
      Serializer::REGULAR_NAME.match?(name) ? name : 'Helv'
    end

    # Keep only well-formed colour-setting operators (g / rg / k) with the
    # right count of numeric operands immediately before them; drop anything
    # else the /DA might carry. Each segment is scanned on its own, so
    # adjacency means adjacency in the original string.
    def safe_color_ops(*segments)
      ops = segments.flat_map { |tokens| color_ops_in(tokens || []) }
      ops.empty? ? '0 g' : ops.join(' ')
    end

    def color_ops_in(tokens)
      tokens.each_with_index.filter_map do |tok, i|
        arity = COLOR_OP_ARITY[tok]
        # `i >= arity` keeps the fixed-length slice below in bounds: a
        # negative start would wrap around to the end of the array.
        next unless arity && i >= arity

        operands = tokens[i - arity, arity]
        next unless operands.all? { |o| NUMERIC_OPERAND.match?(o) }

        "#{operands.join(' ')} #{tok}"
      end
    end

    # Fixed sizes that overflow the box are scaled down so the whole value
    # stays visible (Acrobat-style best-fit; pdftk would clip instead).
    def shrink_to_fit(text, font, size, width)
      max_width = width - (2 * PADDING)
      text_width = font.width_of(text, size)
      return size unless text_width > max_width && text_width.positive?

      # The ratio is applied to +size+, never `size * max_width` first: a
      # large /DA size makes that product overflow to Infinity, and
      # Infinity / Infinity is a NaN that no later clamp can recover from.
      size * (max_width / text_width)
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
