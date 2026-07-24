# frozen_string_literal: true

require 'pdf-reader'

module Acrofill
  # A new stream object created by acrofill (appearance streams, stamped
  # content). +raw+ holds the final, already-encoded stream bytes.
  StreamObject = Struct.new(:dict, :raw)

  # In-memory object store for a parsed PDF. All indirect objects are
  # materialized once via pdf-reader (which transparently handles xref
  # streams and object streams), then mutated in place before writing.
  class Document
    attr_reader :objects, :trailer

    def initialize(path)
      hash = load_object_hash(path)
      raise Error, 'encrypted PDFs are not supported' if hash.trailer[:Encrypt]

      @objects = {}
      @max_oid = 0
      hash.each do |ref, obj|
        @objects[ref.id] = obj
        @max_oid = ref.id if ref.id > @max_oid
      end
      @trailer = hash.trailer.slice(:Root, :Info, :ID)
      raise Error, 'PDF has no document catalog' unless @trailer[:Root]
    end

    # A serialized copy of the pristine object graph; see Template.
    def snapshot
      Marshal.dump([@objects, @trailer, @max_oid])
    end

    # Rebuilds a Document from a snapshot produced by #snapshot. Restoring
    # deep-copies every object, so mutations never leak between fills.
    # Snapshots are an internal format: only feed this data produced by
    # #snapshot in the same process (Marshal is not safe on foreign input).
    def self.restore(snapshot)
      doc = allocate
      # Snapshots are produced by #snapshot in the same process and never
      # accepted from external input, so Marshal here is not a deserialization
      # boundary (see Template docs).
      doc.send(:restore_state, *Marshal.load(snapshot)) # rubocop:disable Security/MarshalLoad
      doc
    end

    private

    def restore_state(objects, trailer, max_oid)
      @objects = objects
      @trailer = trailer
      @max_oid = max_oid
    end

    # The parse boundary for untrusted input: pdf-reader (and the decryptors
    # it calls) can raise a wide assortment of errors on crafted files, so
    # everything is normalized to a single Acrofill::Error type.
    def load_object_hash(path)
      PDF::Reader::ObjectHash.new(path)
    rescue PDF::Reader::EncryptedPDFError => e
      raise Error, "encrypted PDFs are not supported (#{e.message})"
    rescue StandardError => e
      raise Error, "could not parse PDF (#{e.class}: #{e.message})"
    end

    public

    # Follows reference chains (ref -> ref -> value is legal PDF), with a
    # hop cap so a reference cycle cannot loop forever.
    def deref(obj)
      hops = 0
      while obj.is_a?(PDF::Reader::Reference)
        return nil if (hops += 1) > 16

        obj = @objects[obj.id]
      end
      obj
    end

    # Adds a new indirect object and returns a reference to it.
    def add(obj)
      @max_oid += 1
      @objects[@max_oid] = obj
      PDF::Reader::Reference.new(@max_oid, 0)
    end

    # Wraps a direct object into an indirect one; passes references through.
    def ref_for(obj)
      obj.is_a?(PDF::Reader::Reference) ? obj : add(obj)
    end

    def root
      deref(@trailer[:Root])
    end

    def each_page(node = root[:Pages], seen = {}, &block)
      dict = deref(node)
      return unless dict.is_a?(Hash)

      # Guard against cyclic and shared (billion-laughs) /Pages trees: a
      # node reachable more than once is walked only the first time.
      if node.is_a?(PDF::Reader::Reference)
        return if seen[node.id]

        seen[node.id] = true
      end

      case dict[:Type]
      when :Pages
        (deref(dict[:Kids]) || []).each { |kid| each_page(kid, seen, &block) }
      when :Page
        yield dict
      end
    end

    # Resolves an attribute inheritable through the /Parent chain
    # (field attributes like /FT, /DA, /Q or page attributes).
    def inherited_value(node, key)
      seen = 0
      while node.is_a?(Hash)
        return node[key] if node.key?(key)
        return nil if (seen += 1) > 64 # cycle guard

        node = deref(node[:Parent])
      end
      nil
    end
  end
end
