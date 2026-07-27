# frozen_string_literal: true

module Acrofill
  # Burns widget appearances into page content and removes the interactive
  # layer, like pdftk's `output ... flatten`. Every geometry value it reads
  # comes from the template, so each one is validated before use.
  class Flattener
    HIDDEN_FLAG = 2
    NOVIEW_FLAG = 32
    INVISIBLE = HIDDEN_FLAG | NOVIEW_FLAG

    def initialize(doc)
      @doc = doc
      @stamp_counter = 0
    end

    def flatten!
      @doc.each_page { |page| flatten_page(page) }
      @doc.root.delete(:AcroForm)
    end

    private

    # Annotation /F flags. Must be dereferenced before to_i: on a
    # PDF::Reader::Reference, to_i returns the object *number*.
    def annotation_flags(widget)
      flags = @doc.deref(widget[:F])
      flags.is_a?(Integer) ? flags : 0
    end

    def flatten_page(page)
      annot_refs = @doc.deref(page[:Annots])
      annot_refs = [] unless annot_refs.is_a?(Array)
      # A reference that does not resolve to a dictionary is dropped rather
      # than carried over: it has no object to renumber, so the Writer would
      # serialize it as a bare `null` inside /Annots, which is not a legal
      # annotation array.
      annots = annot_refs.filter_map do |ref|
        dict = @doc.deref(ref)
        [ref, dict] if dict.is_a?(Hash)
      end
      widgets, others = annots.partition { |_ref, dict| @doc.deref(dict[:Subtype]) == :Widget }
      return if widgets.empty?

      @pending = {}
      stamps = widgets.filter_map { |_ref, widget| stamp_operations(widget) }
      install_xobjects(page, @pending) unless @pending.empty?

      unless stamps.empty?
        derefed = @doc.deref(page[:Contents])
        contents = (derefed.is_a?(Array) ? derefed : [page[:Contents]]).compact
                                                                       .map { |stream| @doc.ref_for(stream) }
        page[:Contents] = [content_stream("q\n"), *contents,
                           content_stream("\nQ\n#{stamps.join("\n")}\n")]
      end

      remaining = others.map(&:first)
      if remaining.empty?
        page.delete(:Annots)
      else
        page[:Annots] = remaining
      end
    end

    def content_stream(bytes)
      @doc.add(StreamObject.new({}, bytes.b))
    end

    # Returns content-stream operations placing the widget's normal
    # appearance onto the page, or nil when there is nothing to draw.
    # Implements the appearance-box algorithm of PDF 32000 §12.5.5: the
    # form's /Matrix is applied to its BBox, and the resulting extent is
    # mapped onto the annotation rectangle.
    def stamp_operations(widget)
      # Flattening produces the document as it is displayed, so a widget the
      # viewer would not show is dropped rather than burned in: /F Hidden,
      # and NoView, which means "not on screen" (PDF 32000 §12.5.3). pdftk
      # stamps both, but stamping Hidden makes values the template author
      # concealed permanently visible, so parity loses here.
      return nil if annotation_flags(widget).anybits?(INVISIBLE)

      ap_ref = normal_appearance(widget)
      xobject = @doc.deref(ap_ref)
      dict = appearance_dict(xobject)
      return nil unless dict

      bbox = @doc.normalized_box(dict[:BBox])
      # /Rect is inheritable through the /Parent chain, and Appearance#build
      # honours that when it draws the value. Reading only widget[:Rect] here
      # would stamp nothing for a kid widget whose rectangle lives on the
      # parent field — filling the value and then silently dropping it.
      rect = @doc.normalized_box(@doc.inherited_value(widget, :Rect))
      return nil unless bbox && rect

      # Appearance streams are form XObjects, but /Type and /Subtype are
      # sometimes omitted; /Do requires them.
      dict[:Type] ||= :XObject
      dict[:Subtype] ||= :Form

      llx, lly, urx, ury = rect
      bx0, by0, bx1, by1 = transformed_bbox(bbox, @doc.deref(dict[:Matrix]))
      bw = bx1 - bx0
      bh = by1 - by0
      # A degenerate annotation rectangle scales to a singular matrix, which
      # PDF 32000 §8.3.3 forbids; Appearance#build rejects the same geometry.
      return nil unless positive_extent?(bw, bh) && positive_extent?(urx - llx, ury - lly)

      sx = (urx - llx) / bw
      sy = (ury - lly) / bh
      matrix = [sx, 0, 0, sy, llx - (bx0 * sx), lly - (by0 * sy)]
      return nil unless matrix.all? { |n| n.to_f.finite? }

      name = register_xobject(ap_ref)
      "q #{matrix.map { |n| Serializer.format_number(n.to_f) }.join(' ')} cm /#{name} Do Q"
    end

    # The dictionary of an appearance XObject, or nil. A /AP /N that derefs
    # to something other than a stream has no dictionary — asking a plain
    # Hash or Array for #hash would return Object#hash, an Integer.
    def appearance_dict(xobject)
      case xobject
      when StreamObject then xobject.dict
      when PDF::Reader::Stream then xobject.hash
      end
    end

    def positive_extent?(width, height)
      width.finite? && height.finite? && width.positive? && height.positive?
    end

    # Bounding box of the (already normalized) BBox corners after the
    # form's /Matrix (identity when absent or malformed).
    def transformed_bbox(bbox, matrix)
      x0, y0, x1, y1 = bbox
      matrix = matrix.map { |m| @doc.deref(m) } if matrix.is_a?(Array)
      # A non-finite entry is as malformed as a missing one: it multiplies
      # into the NaN that Array#min then raises on.
      return [x0, y0, x1, y1] unless matrix.is_a?(Array) && matrix.size == 6 &&
                                     matrix.all? { |m| m.is_a?(Numeric) && m.to_f.finite? }

      a, b, c, d, e, f = matrix.map(&:to_f)
      xs = []
      ys = []
      [[x0, y0], [x1, y0], [x0, y1], [x1, y1]].each do |x, y|
        xs << ((a * x) + (c * y) + e)
        ys << ((b * x) + (d * y) + f)
      end
      # Finite entries still multiply and add into a NaN (Infinity plus its
      # negation), which Array#min raises on rather than returning; a
      # transform that overflows is as unusable as a malformed one.
      return [x0, y0, x1, y1] unless xs.all?(&:finite?) && ys.all?(&:finite?)

      [xs.min, ys.min, xs.max, ys.max]
    end

    def normal_appearance(widget)
      ap = @doc.deref(widget[:AP])
      return nil unless ap.is_a?(Hash)

      normal = ap[:N]
      states = @doc.deref(normal)
      if states.is_a?(Hash) && !states.is_a?(PDF::Reader::Stream)
        # Pick the widget's current state; without /AS default to /Off
        # (never an arbitrary "on" appearance for an unset checkbox).
        state = @doc.deref(widget[:AS])
        state = :Off unless state.is_a?(Symbol) && states.key?(state)
        normal = states[state]
      end
      normal
    end

    # Names the stamp and records it; the page's /Resources are rewritten
    # once per page by #install_xobjects rather than once per widget.
    def register_xobject(ap_ref)
      @stamp_counter += 1
      name = :"AcrofillAP#{@stamp_counter}"
      @pending[name] = @doc.ref_for(ap_ref)
      name
    end

    # A page's /Resources (and its /XObject subdictionary) are template
    # data: anything that is not a dictionary is replaced rather than
    # indexed, which would raise TypeError on an Array or a stream. Both are
    # copied before mutation, since a /Resources reached through /Parent is
    # shared with every other page under that node.
    def install_xobjects(page, pending)
      resources = @doc.deref(page[:Resources]) || @doc.deref(@doc.inherited_value(page, :Resources))
      resources = resources.is_a?(Hash) ? resources.dup : {}
      xobjects = @doc.deref(resources[:XObject])
      xobjects = xobjects.is_a?(Hash) ? xobjects.dup : {}
      resources[:XObject] = xobjects.merge(pending)
      page[:Resources] = resources
    end
  end
end
