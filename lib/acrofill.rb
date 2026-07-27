# frozen_string_literal: true

require_relative 'acrofill/version'
require_relative 'acrofill/document'
require_relative 'acrofill/metrics'
require_relative 'acrofill/serializer'
require_relative 'acrofill/writer'
require_relative 'acrofill/appearance'
require_relative 'acrofill/flattener'
require_relative 'acrofill/form'
require_relative 'acrofill/filler'
require_relative 'acrofill/template'

module Acrofill
  class Error < StandardError; end

  # Mirrors the PdfForms.new(pdftk_path) constructor shape.
  def self.new(*)
    Filler.new(*)
  end

  def self.fill_form(template, destination, data = {}, options = {})
    Filler.new.fill_form(template, destination, data, options)
  end

  def self.fields(template)
    Filler.new.fields(template)
  end

  def self.field_names(template)
    Filler.new.field_names(template)
  end
end
