# frozen_string_literal: true

# Benchmarks acrofill against the pdftk binary on your own templates,
# filling + flattening each form. Field names are discovered from the
# template; every text field is filled with a sample value. Run:
#
#   ruby benchmark/compare.rb path/to/*.pdf
#
# pdftk is invoked exactly as the pdf-forms gem does: fill_form with an FDF
# and the flatten operation. If pdftk is not on PATH, only acrofill runs.
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'acrofill'
require 'benchmark'
require 'tmpdir'

ITERATIONS = Integer(ENV.fetch('ITERATIONS', '50'))

def sample_data(template)
  Acrofill.fields(template).to_h do |field|
    value =
      case field.type
      when :Btn then (field.states.first || :Off).to_s
      else "Sample #{field.name[0, 12]}"
      end
    [field.name, value]
  end
end

def pdftk?
  @pdftk ||= system('pdftk', '--version', out: File::NULL, err: File::NULL)
end

def fdf_for(data)
  fields = data.map do |name, value|
    "<< /T (#{name.gsub(/([()\\])/, '\\\\\\1')}) /V (#{value.gsub(/([()\\])/, '\\\\\\1')}) >>"
  end.join("\n")
  "%FDF-1.2\n1 0 obj\n<< /FDF << /Fields [#{fields}] >> >>\nendobj\n" \
    "trailer\n<< /Root 1 0 R >>\n%%EOF\n"
end

def run_pdftk(template, data, out)
  Dir.mktmpdir do |dir|
    fdf = File.join(dir, 'data.fdf')
    File.binwrite(fdf, fdf_for(data))
    system('pdftk', template, 'fill_form', fdf, 'output', out, 'flatten',
           out: File::NULL, err: File::NULL)
  end
end

templates = ARGV
abort 'usage: ruby benchmark/compare.rb <template.pdf> ...' if templates.empty?

puts "iterations per form: #{ITERATIONS}"
puts "pdftk available: #{pdftk? ? `pdftk --version`.lines.first.strip : 'no'}"
puts format('%-24s %12s %12s %10s', 'form', 'acrofill', 'pdftk', 'speedup')
puts '-' * 62

totals = { acrofill: 0.0, pdftk: 0.0 }
Dir.mktmpdir do |dir|
  templates.each do |template|
    key = File.basename(template, '.pdf')
    data = sample_data(template)
    out = File.join(dir, "#{key}.pdf")

    acro = Benchmark.realtime do
      ITERATIONS.times { Acrofill.fill_form(template, out, data, flatten: true) }
    end
    totals[:acrofill] += acro
    label = "#{key} (#{data.size}f)"

    if pdftk?
      pdftk = Benchmark.realtime do
        ITERATIONS.times { run_pdftk(template, data, out) }
      end
      totals[:pdftk] += pdftk
      puts format('%-24s %10.1f ms %10.1f ms %9.1fx',
                  label, acro / ITERATIONS * 1000, pdftk / ITERATIONS * 1000, pdftk / acro)
    else
      puts format('%-24s %10.1f ms %12s %10s', label, acro / ITERATIONS * 1000, '-', '-')
    end
  end
end

puts '-' * 62
if pdftk?
  puts format('%-24s %10.1f ms %10.1f ms %9.1fx', 'TOTAL',
              totals[:acrofill] * 1000, totals[:pdftk] * 1000,
              totals[:pdftk] / totals[:acrofill])
else
  puts format('%-24s %10.1f ms', 'TOTAL', totals[:acrofill] * 1000)
end
