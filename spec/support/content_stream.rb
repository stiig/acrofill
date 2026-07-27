# frozen_string_literal: true

require 'strscan'

# Reduces a PDF content stream to the text it draws and where. pdftk places
# each run with an absolute `1 0 0 1 x y Tm` while acrofill uses a relative
# `x y Td` plus `T*`; both are resolved here to the same absolute
# coordinates, which is what makes the two comparable.
#
# Shared by spec/pdftk_parity_spec.rb and benchmark/geometry_diff.rb: the
# numbers pinned in the spec were measured with the benchmark, so the two
# have to read a stream the same way.
module ContentStream
  NUMBER = /-?[\d.]+/
  TEXT_MATRIX = /(#{NUMBER})\s+(#{NUMBER})\s+(#{NUMBER})\s+(#{NUMBER})\s+(#{NUMBER})\s+(#{NUMBER})\s+Tm/
  OFFSET = /(#{NUMBER})\s+(#{NUMBER})\s+(Td|TD)/
  LEADING = /(#{NUMBER})\s+TL/
  SHOW_TEXT = /\(((?:[^()\\]|\\.)*)\)\s*Tj/
  # The a b c d of a Tm that only translates. Compared numerically, so a
  # producer writing `1.0 0.0 0.0 1.0` reads the same as `1 0 0 1`.
  UNSCALED = [1.0, 0.0, 0.0, 1.0].freeze

  module_function

  # [[x, y, text], ...] in stream order.
  def text_positions(stream)
    scanner = StringScanner.new(stream)
    x = 0.0
    y = 0.0
    leading = 0.0
    # Whether the pen position is still one this reader can account for.
    placed = true
    positions = []
    until scanner.eos?
      if scanner.scan(TEXT_MATRIX)
        # Only an unscaled matrix puts text where its e/f say. A scaled or
        # skewed Tm moves the glyphs without moving e/f, so its runs are
        # dropped rather than reported at a coordinate that was never
        # checked — a stale one could sit inside a pinned tolerance and pass.
        placed = (1..4).map { |group| scanner[group].to_f } == UNSCALED
        if placed
          x = scanner[5].to_f
          y = scanner[6].to_f
        end
      elsif scanner.scan(OFFSET)
        # `tx ty TD` is `-ty TL` and then `tx ty Td` (PDF 32000 §9.4.2), so
        # it sets the leading every following T* moves by.
        leading = -scanner[2].to_f if scanner[3] == 'TD'
        x += scanner[1].to_f
        y += scanner[2].to_f
      elsif scanner.scan(LEADING)
        leading = scanner[1].to_f
      elsif scanner.scan('T*')
        y -= leading
      elsif scanner.scan(SHOW_TEXT)
        positions << [x, y, scanner[1]] if placed
      else
        scanner.getch
      end
    end
    positions
  end
end
