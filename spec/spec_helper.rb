# frozen_string_literal: true

require 'acrofill'
require 'tmpdir'
require_relative 'support/fixture_pdf'

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
end
