# frozen_string_literal: true

module Acrofill
  # The interactive form of a document: field lookup by fully-qualified
  # name, value filling with appearance regeneration, and flattening.
  class Form
    MULTILINE_FLAG = 1 << 12
    PUSHBUTTON_FLAG = 1 << 16

    Field = Struct.new(:name, :type, :value, :states, keyword_init: true)

    def initialize(doc)
      @doc = doc
      @acroform = doc.deref(doc.root[:AcroForm])
      raise Error, 'document has no AcroForm' unless @acroform.is_a?(Hash)

      @appearance = Appearance.new(doc, @acroform)
      # name => array of { node:, widgets: } groups. Several field dicts may
      # share one fully-qualified name (PDF 32000 §12.7.3.2 treats them as a
      # single logical field, e.g. "SSN" repeated on every page) — filling
      # must update all of them.
      @fields = Hash.new { |h, k| h[k] = [] }
      roots = doc.deref(@acroform[:Fields])
      collect_fields(roots.is_a?(Array) ? roots : [])
    end

    # Metadata for every logical field, in document order.
    def fields
      @fields.map do |name, groups|
        type = field_type(groups.first[:node])
        Field.new(
          name: name,
          type: type,
          value: decode_text_string(@doc.deref(groups.first[:node][:V])),
          states: type == :Btn ? on_states(all_widgets(groups)) : nil
        )
      end
    end

    # Sets the field value and rebuilds widget appearances. Unknown names
    # are ignored (returns false), matching pdftk's fill_form behaviour.
    def fill(name, value)
      groups = @fields.fetch(name, [])
      return false if groups.empty?

      case field_type(groups.first[:node])
      when :Btn then fill_button(groups, value)
      when :Tx, :Ch, nil then fill_text_groups(groups, value)
      else false # signatures and unknown types are left untouched
      end
    end

    # Stamps every visible widget appearance into its page's content and
    # removes the interactive layer, like pdftk's `output ... flatten`.
    def flatten!
      Flattener.new(@doc).flatten!
    end

    private

    def all_widgets(groups)
      groups.flat_map { |group| group[:widgets] }
    end

    def field_type(node)
      type = @doc.inherited_value(node, :FT)
      type.is_a?(Symbol) ? type : nil
    end

    # /Ff is an integer bit set; coerce defensively since malformed input
    # can supply a non-integer here (Array#to_i does not exist).
    def field_flags(node)
      flags = @doc.deref(@doc.inherited_value(node, :Ff))
      flags.is_a?(Integer) ? flags : 0
    end

    # Every group sharing this name is filled, so the walk must not
    # short-circuit on the first one.
    def fill_text_groups(groups, value)
      groups.each { |group| fill_text(group, value) }
      true
    end

    def fill_text(group, value)
      node = group[:node]
      node[:V] = pdf_text_string(value)
      node.delete(:RV)
      node.delete(:I)
      multiline = field_flags(node).anybits?(MULTILINE_FLAG)
      group[:widgets].each do |widget|
        widget.delete(:AS)
        ap_ref = @appearance.build(node, widget, value, multiline: multiline) unless value.empty?
        # An unusable geometry yields no appearance; dropping /AP is still
        # required, or the widget would keep rendering the *previous* value
        # while /V already holds the new one.
        if ap_ref
          widget[:AP] = { N: ap_ref }
        else
          widget.delete(:AP)
        end
      end
      true
    end

    # Checkboxes and radio groups carry per-state appearance streams, so
    # filling only selects a state: /V on the field, /AS on each widget.
    # The value may be a state name ("Yes"), or anything non-empty when the
    # group has a single on state. Empty, "Off" or false-ish unchecks —
    # unless the value exactly names an on state (a checkbox whose state is
    # literally called "no" must remain checkable).
    def fill_button(groups, value)
      widgets = all_widgets(groups)
      states = on_states(widgets)
      # Match against the state names already present in the template
      # rather than interning the untrusted value (avoids unbounded
      # symbol creation from attacker-controlled field values).
      named = states.find { |s| s.to_s == value }
      state =
        if named
          named
        elsif ['', 'Off', 'false', 'no'].include?(value)
          :Off
        elsif states.size == 1
          states.first
        else
          return false
        end

      filled = false
      groups.each do |group|
        node = group[:node]
        next if field_flags(node).anybits?(PUSHBUTTON_FLAG)

        node[:V] = state
        group[:widgets].each do |widget|
          widget[:AS] = widget_states(widget).include?(state) ? state : :Off
        end
        filled = true
      end
      filled
    end

    def on_states(widgets)
      widgets.flat_map { |widget| widget_states(widget) }.uniq - [:Off]
    end

    def widget_states(widget)
      ap = @doc.deref(widget[:AP])
      return [] unless ap.is_a?(Hash)

      normal = @doc.deref(ap[:N])
      normal.is_a?(Hash) && !normal.is_a?(PDF::Reader::Stream) ? normal.keys : []
    end

    # Guard against cyclic and shared /Kids graphs: a field node reachable
    # more than once is expanded only the first time.
    def visited?(ref, seen)
      return false unless ref.is_a?(PDF::Reader::Reference)
      return true if seen[ref.id]

      seen[ref.id] = true
      false
    end

    # Depth-first, document-order walk over the field tree. Iterative with
    # an explicit stack of [ref, prefix] pairs (a deep linear /Kids chain
    # must not overflow the Ruby stack), with a visited set against cycles
    # and shared nodes.
    def collect_fields(roots)
      seen = {}
      stack = roots.reverse.map { |ref| [ref, nil] }
      until stack.empty?
        ref, prefix = stack.pop
        next if visited?(ref, seen)

        node = @doc.deref(ref)
        next unless node.is_a?(Hash)

        name = [prefix, decode_name(node[:T])].compact.join('.')
        subfields, widgets = partition_kids(node)

        if subfields.any?
          # Descend only into the named subfields; a stray bare widget mixed
          # into the same /Kids must not register itself under this name.
          stack.concat(subfields.map { |kid, _dict| [kid, name] }.reverse)
        else
          widget_dicts = widgets.map(&:last)
          widget_dicts = [node] if widget_dicts.empty? && node[:Rect]
          @fields[name] << { node: node, widgets: widget_dicts } unless name.empty?
        end
      end
    end

    # Splits a node's /Kids into named subfields and bare widgets, dropping
    # anything that does not deref to a dictionary.
    def partition_kids(node)
      child_refs = @doc.deref(node[:Kids])
      child_refs = [] unless child_refs.is_a?(Array)
      child_refs.map { |kid| [kid, @doc.deref(kid)] }
                .select { |_kid, dict| dict.is_a?(Hash) }
                .partition { |_kid, dict| dict.key?(:T) }
    end

    def decode_name(raw)
      decode_text_string(@doc.deref(raw))
    end

    # PDF text strings are UTF-16BE (with BOM) or PDFDoc/Latin-ish; both are
    # template-controlled, so decoding failures degrade instead of raising.
    def decode_text_string(raw)
      return raw unless raw.is_a?(String)

      if raw.start_with?("\xFE\xFF".b)
        raw.byteslice(2..).force_encoding('UTF-16BE')
           .encode('UTF-8', invalid: :replace, undef: :replace)
      else
        raw.dup.force_encoding('UTF-8').scrub
      end
    end

    def pdf_text_string(value)
      return value.b if value.ascii_only?

      "\xFE\xFF".b + value.encode('UTF-16BE').b
    end
  end
end
