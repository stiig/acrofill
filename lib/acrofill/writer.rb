# frozen_string_literal: true

require 'digest/md5'

module Acrofill
  # Writes the document back out as a fresh PDF: only objects reachable from
  # the trailer are emitted, renumbered contiguously, with a classic xref
  # table. Existing streams are copied verbatim with their original filters.
  class Writer
    HEADER = "%PDF-1.6\n%\xE2\xE3\xCF\xD3\n".b

    def initialize(document)
      @doc = document
    end

    def render
      order = reachable_oids
      oid_map = order.each_with_index.to_h { |oid, idx| [oid, idx + 1] }
      serializer = Serializer.new(oid_map)

      out = HEADER.dup
      offsets = []
      order.each do |oid|
        offsets << out.bytesize
        out << "#{oid_map[oid]} 0 obj\n"
        out << serialize_object(@doc.objects[oid], serializer)
        out << "\nendobj\n"
      end

      xref_offset = out.bytesize
      out << "xref\n0 #{order.size + 1}\n0000000000 65535 f \n"
      offsets.each { |offset| out << format("%010d 00000 n \n", offset) }

      trailer = {
        Size: order.size + 1,
        Root: @doc.trailer[:Root],
        Info: @doc.trailer[:Info],
        ID: trailer_id(out)
      }.compact
      out << "trailer\n#{serializer.serialize(trailer)}\n"
      out << "startxref\n#{xref_offset}\n%%EOF\n"
      out
    end

    private

    # Preserves the original /ID pair, or derives one from the serialized
    # body so identical inputs always produce identical output bytes.
    def trailer_id(body)
      id = @doc.trailer[:ID]
      return id if id.is_a?(Array) && id.size == 2 && id.all?(String)

      digest = Digest::MD5.digest(body)
      [digest, digest]
    end

    def serialize_object(obj, serializer)
      dict, raw =
        case obj
        when PDF::Reader::Stream then [obj.hash, obj.data]
        when StreamObject then [obj.dict, obj.raw]
        else return serializer.serialize(obj)
        end

      dict = dict.merge(Length: raw.bytesize)
      "#{serializer.serialize(dict)}\nstream\n".b + raw.b + "\nendstream".b
    end

    # Breadth-first walk from the trailer; keeps original ordering stable
    # and drops everything orphaned (old xref streams, removed form fields).
    def reachable_oids
      queue = [@doc.trailer[:Root], @doc.trailer[:Info]].compact
      seen = {}
      order = []

      until queue.empty?
        current = queue.shift
        case current
        when PDF::Reader::Reference
          next if seen[current.id]

          seen[current.id] = true
          obj = @doc.objects[current.id]
          next if obj.nil?

          order << current.id
          queue << obj
        when Hash
          queue.concat(current.values)
        when Array
          queue.concat(current)
        when PDF::Reader::Stream
          queue << current.hash
        when StreamObject
          queue << current.dict
        end
      end
      order
    end
  end
end
