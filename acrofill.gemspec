# frozen_string_literal: true

require_relative 'lib/acrofill/version'

Gem::Specification.new do |spec|
  spec.name = 'acrofill'
  spec.version = Acrofill::VERSION
  spec.summary = 'Pure-Ruby PDF form (AcroForm) filling and flattening'
  spec.description = 'Fills PDF form fields (text, checkbox, radio, choice) in-process and ' \
                     'optionally flattens the result into static page content. An MIT-licensed, ' \
                     'no-dependencies-on-binaries alternative to the pdftk fill_form pipeline.'
  spec.authors = ['stiig']
  spec.license = 'MIT'
  spec.homepage = 'https://github.com/stiig/acrofill'
  spec.metadata = {
    'homepage_uri' => spec.homepage,
    'source_code_uri' => "#{spec.homepage}/tree/main",
    'changelog_uri' => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'bug_tracker_uri' => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }
  spec.required_ruby_version = '>= 3.2'

  spec.files = Dir['lib/**/*.rb'] + ['README.md', 'CHANGELOG.md', 'LICENSE.txt']
  spec.require_paths = ['lib']

  spec.add_dependency 'pdf-reader', '~> 2.4'
end
