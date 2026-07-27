# frozen_string_literal: true

module Acrofill
  # A pre-parsed, reusable template. Parsing is the dominant cost of a
  # fill (tokenizing and inflating the whole file); Template pays it once
  # and restores a pristine object graph from a Marshal snapshot for each
  # subsequent fill — measured at 7-8x faster per fill on real forms.
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
      @source = absolute(path)
      @snapshot = Document.new(path).snapshot
    end

    def fill_form(destination, data = {}, options = {})
      # Template#fill_form takes the destination first; Filler#fill_form
      # takes the template first. Passing the template here is the natural
      # slip, and since Template never re-reads the file the overwrite would
      # go unnoticed until another consumer opened the corrupted template.
      if @source && absolute(destination) == @source
        raise Error, 'destination is the template itself; ' \
                     'Template#fill_form takes (destination, data, options)'
      end

      Filler.new.apply(Document.restore(@snapshot), destination, data, options)
    end

    # Field metadata without touching disk again.
    def fields
      Form.new(Document.restore(@snapshot)).fields
    end

    def field_names
      fields.map(&:name)
    end

    private

    # The path +input+ names, resolved so that "form.pdf" and "./form.pdf"
    # compare equal, or nil when it is not a path at all (an IO, say).
    # Pure string work: nothing here touches the filesystem.
    def absolute(input)
      path = input.respond_to?(:to_path) ? input.to_path : input
      File.expand_path(path) if path.is_a?(String)
    end
  end
end
