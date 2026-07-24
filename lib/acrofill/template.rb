# frozen_string_literal: true

module Acrofill
  # A pre-parsed, reusable template. Parsing is the dominant cost of a
  # fill (tokenizing and inflating the whole file); Template pays it once
  # and restores a pristine object graph from a Marshal snapshot for each
  # subsequent fill — roughly 50x faster than re-parsing per fill.
  #
  #   template = Acrofill::Template.new('claim_form.pdf')
  #   template.fill_form('a.pdf', { 'Name' => 'Jane' }, flatten: true)
  #   template.fill_form('b.pdf', { 'Name' => 'John' }, flatten: true)
  #
  # Instances are cheap to keep around (the snapshot is a single string,
  # comparable to the file size) and safe to share across threads: every
  # fill works on its own restored copy.
  class Template
    def initialize(path)
      doc = Document.new(path)
      @snapshot = doc.snapshot
    end

    def fill_form(destination, data = {}, options = {})
      Filler.new.apply(Document.restore(@snapshot), destination, data, options)
    end

    # Field metadata without touching disk again.
    def fields
      Form.new(Document.restore(@snapshot)).fields
    end

    def field_names
      fields.map(&:name)
    end
  end
end
