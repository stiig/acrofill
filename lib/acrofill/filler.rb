# frozen_string_literal: true

module Acrofill
  # Public entry point, signature-compatible with PdfForms#fill_form:
  #
  #   Acrofill.new.fill_form(template, output, { 'Field' => 'value' }, flatten: true)
  #
  # Note: PdfForms-specific options (data_format:, utf8_fields:, ...) are
  # accepted and ignored — acrofill needs no FDF and is always UTF-aware.
  class Filler
    # Accepts and ignores a pdftk path argument for drop-in compatibility.
    def initialize(*); end

    def fill_form(template, destination, data = {}, options = {})
      apply(Document.new(template), destination, data, options)
    end

    # Field metadata (name, type, current value, checkbox/radio states)
    # without modifying the document.
    def fields(template)
      Form.new(Document.new(template)).fields
    end

    # Fully-qualified names of all fillable fields.
    def field_names(template)
      fields(template).map(&:name)
    end

    # Shared fill pipeline, also driven by Template with a restored
    # document. Values are normalized to valid UTF-8 up front so that a
    # mis-encoded input degrades (replacement character) instead of
    # leaking a raw Encoding error from deep inside the appearance code.
    def apply(doc, destination, data, options)
      form = Form.new(doc)
      data.each do |name, value|
        form.fill(normalize(name), normalize(value))
      end
      form.flatten! if options[:flatten] || options['flatten']
      File.binwrite(destination, Writer.new(doc).render)
      destination
    end

    private

    def normalize(value)
      return '' if value.nil?

      value.to_s.encode('UTF-8', invalid: :replace, undef: :replace).scrub
    end
  end
end
