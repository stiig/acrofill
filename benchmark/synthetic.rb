# frozen_string_literal: true

# Self-contained benchmark on a synthetically generated form — no external
# templates. It builds a one-page PDF with a configurable number of text
# fields, then compares:
#
#   * acrofill            in-process fill + flatten
#   * pdftk (cold)        one subprocess per fill — what a web app pays
#   * pdftk (warm)        cold time minus measured JVM/process start-up, i.e.
#                         the marginal PDF-processing cost with the runtime
#                         already hot (what a hypothetical long-lived pdftk
#                         server would approach)
#
# Usage:  ruby benchmark/synthetic.rb            # 30 fields, 100 iters
#         FIELDS=80 ITERATIONS=200 ruby benchmark/synthetic.rb
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'acrofill'
require 'benchmark'
require 'tmpdir'

FIELDS = Integer(ENV.fetch('FIELDS', '30'))
ITERATIONS = Integer(ENV.fetch('ITERATIONS', '100'))
STARTUP_SAMPLES = Integer(ENV.fetch('STARTUP_SAMPLES', '20'))

# --- synthetic template ----------------------------------------------------

def synthetic_pdf(field_count)
  objects = []
  annots = (0...field_count).map { |i| "#{6 + i} 0 R" }.join(' ')
  fields = annots
  objects << '<< /Type /Catalog /Pages 2 0 R /AcroForm 4 0 R >>'
  objects << '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'
  objects << '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ' \
             '/Resources << /Font << /Helv 5 0 R >> >> /Contents 5 0 R ' \
             "/Annots [#{annots}] >>"
  objects << "<< /Fields [#{fields}] /DA (/Helv 0 Tf 0 g) " \
             '/DR << /Font << /Helv 5 0 R >> >> >>'
  objects << '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ' \
             '/Encoding /WinAnsiEncoding >>'
  field_count.times do |i|
    y = 740 - ((i % 40) * 18)
    x = 50 + ((i / 40) * 280)
    objects << "<< /Type /Annot /Subtype /Widget /FT /Tx /T (field_#{i}) " \
               "/Rect [#{x} #{y} #{x + 250} #{y + 14}] /DA (/Helv 10 Tf 0 g) >>"
  end
  assemble(objects)
end

def assemble(objects)
  out = +"%PDF-1.4\n"
  offsets = objects.each_with_index.map do |body, idx|
    offset = out.bytesize
    out << "#{idx + 1} 0 obj\n#{body}\nendobj\n"
    offset
  end
  xref = out.bytesize
  out << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
  offsets.each { |offset| out << format("%010d 00000 n \n", offset) }
  out << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\n"
  out << "startxref\n#{xref}\n%%EOF\n"
  out.b
end

def fdf_for(data)
  fields = data.map { |name, value| "<< /T (#{name}) /V (#{value}) >>" }.join("\n")
  "%FDF-1.2\n1 0 obj\n<< /FDF << /Fields [#{fields}] >> >>\nendobj\n" \
    "trailer\n<< /Root 1 0 R >>\n%%EOF\n"
end

def pdftk?
  @pdftk ||= system('pdftk', '--version', out: File::NULL, err: File::NULL)
end

# Average cost of merely starting pdftk (JVM boot + class load), by running
# its cheapest no-op operation. Subtracted from cold time to model "warm".
def pdftk_startup_cost(samples)
  times = Array.new(samples) do
    Benchmark.realtime { system('pdftk', '--version', out: File::NULL, err: File::NULL) }
  end
  times.sort[samples / 2] # median, to shrug off scheduler noise
end

# --- run -------------------------------------------------------------------

data = (0...FIELDS).to_h { |i| ["field_#{i}", "value #{i}"] }

Dir.mktmpdir do |dir|
  template = File.join(dir, 'synthetic.pdf')
  File.binwrite(template, synthetic_pdf(FIELDS))
  out = File.join(dir, 'out.pdf')
  fdf = File.join(dir, 'data.fdf')
  File.binwrite(fdf, fdf_for(data))

  puts "synthetic form: #{FIELDS} text fields, 1 page"
  puts "iterations: #{ITERATIONS}"

  acro = Benchmark.realtime do
    ITERATIONS.times { Acrofill.fill_form(template, out, data, flatten: true) }
  end
  acro_ms = acro / ITERATIONS * 1000

  cached = Acrofill::Template.new(template)
  tpl = Benchmark.realtime do
    ITERATIONS.times { cached.fill_form(out, data, flatten: true) }
  end
  tpl_ms = tpl / ITERATIONS * 1000

  unless pdftk?
    puts format('acrofill:            %.2f ms/fill', acro_ms)
    puts 'pdftk not on PATH — skipping comparison'
    next
  end

  startup = pdftk_startup_cost(STARTUP_SAMPLES)
  cold = Benchmark.realtime do
    ITERATIONS.times do
      system('pdftk', template, 'fill_form', fdf, 'output', out, 'flatten',
             out: File::NULL, err: File::NULL)
    end
  end
  cold_ms = cold / ITERATIONS * 1000
  warm_ms = [cold_ms - (startup * 1000), 0.0].max

  puts
  puts format('%-26s %10s %10s', 'variant', 'ms/fill', 'vs acrofill')
  puts '-' * 48
  puts format('%-26s %10.2f %10s', 'acrofill (in-process)', acro_ms, '1.0x')
  puts format('%-26s %10.2f %9.2fx', 'acrofill (cached template)', tpl_ms, tpl_ms / acro_ms)
  puts format('%-26s %10.2f %9.1fx', 'pdftk cold (subprocess)', cold_ms, cold_ms / acro_ms)
  puts format('%-26s %10.2f %9.1fx', 'pdftk warm (JVM excluded)', warm_ms, warm_ms / acro_ms)
  puts '-' * 48
  puts format('measured pdftk start-up overhead: %.1f ms/call', startup * 1000)
end
