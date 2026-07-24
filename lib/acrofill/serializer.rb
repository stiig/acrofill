# frozen_string_literal: true

module Acrofill
  # Serializes Ruby values (as produced by pdf-reader) back into PDF syntax.
  # References are renumbered through the map supplied by the Writer.
  class Serializer
    # PDF "regular characters": printable ASCII minus whitespace, the
    # delimiters ( ) < > [ ] { } / % and the name-escape character #.
    REGULAR_NAME_CHAR = %r{[!-~&&[^()<>\[\]{}/%#]]}
    REGULAR_NAME = /\A#{REGULAR_NAME_CHAR.source}+\z/
    MAX_DEPTH = 200

    def self.format_number(num)
      # PDF has no syntax for infinity/NaN, and #to_i on them raises;
      # a non-finite number can only come from malformed input, so clamp.
      return '0' unless num.finite?
      return num.to_i.to_s if num == num.to_i

      format('%.5f', num).sub(/\.?0+\z/, '')
    end

    def initialize(oid_map)
      @oid_map = oid_map
    end

    def serialize(obj, depth = 0)
      # Bound recursion: a pathologically nested array/dict from malformed
      # input would otherwise overflow the stack.
      raise Error, 'object nesting too deep' if depth > MAX_DEPTH

      case obj
      when PDF::Reader::Reference
        oid = @oid_map[obj.id]
        oid ? "#{oid} 0 R" : 'null'
      when Hash then serialize_dict(obj, depth)
      when Array then "[#{obj.map { |el| serialize(el, depth + 1) }.join(' ')}]"
      when Symbol then serialize_name(obj)
      when String then serialize_string(obj)
      when Integer then obj.to_s
      when Float then self.class.format_number(obj)
      when TrueClass then 'true'
      when FalseClass then 'false'
      when NilClass then 'null'
      else
        raise Error, "cannot serialize #{obj.class}"
      end
    end

    private

    def serialize_dict(dict, depth = 0)
      inner = dict.map { |k, v| "#{serialize_name(k)} #{serialize(v, depth + 1)}" }.join(' ')
      "<< #{inner} >>"
    end

    def serialize_name(sym)
      str = sym.to_s
      return "/#{str}" if REGULAR_NAME.match?(str) # fast path: no escaping

      encoded = str.bytes.map do |byte|
        char = byte.chr
        REGULAR_NAME_CHAR.match?(char) ? char : format('#%02X', byte)
      end.join
      "/#{encoded}"
    end

    # Hex strings sidestep every escaping concern for binary payloads
    # (/ID entries, UTF-16BE values, Info metadata).
    def serialize_string(str)
      "<#{str.unpack1('H*').upcase}>"
    end
  end
end
