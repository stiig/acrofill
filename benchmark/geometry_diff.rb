# frozen_string_literal: true

# Compares acrofill's generated appearances against pdftk's, field by field,
# on your own templates. Where benchmark/compare.rb measures speed, this
# measures agreement: for every text field it reports the baseline position,
# the font size and the text of each drawn line from both tools.
#
#   ruby benchmark/geometry_diff.rb path/to/form.pdf ...
#
# pdftk writes placement as `1 0 0 1 x y Tm` and acrofill as `x y Td`; both
# are reduced to absolute coordinates here. pdftk prints numbers rounded to
# two decimals, so treat deltas under 0.01pt as agreement.
#
# The expectations in spec/pdftk_parity_spec.rb were produced with this
# script against pdftk-java 3.3.3; re-run it after touching Metrics or
# Appearance to confirm nothing drifted.
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'acrofill'
require 'tmpdir'
# Shared with spec/pdftk_parity_spec.rb so the benchmark that produced the
# pinned numbers and the spec that checks them read a stream identically.
require_relative '../spec/support/content_stream'

TOLERANCE = 0.01

def pdftk?
  @pdftk ||= system('pdftk', '--version', out: File::NULL, err: File::NULL)
end

def escape(str)
  str.gsub(/([()\\])/, '\\\\\1')
end

def fdf_for(data)
  fields = data.map { |name, value| "<< /T (#{escape(name)}) /V (#{escape(value)}) >>" }
  "%FDF-1.2\n1 0 obj\n<< /FDF << /Fields [#{fields.join("\n")}] >> >>\nendobj\n" \
    "trailer\n<< /Root 1 0 R >>\n%%EOF\n"
end

def run_pdftk(template, data, out)
  Dir.mktmpdir do |dir|
    fdf = File.join(dir, 'data.fdf')
    File.binwrite(fdf, fdf_for(data))
    system('pdftk', template, 'fill_form', fdf, 'output', out, out: File::NULL, err: File::NULL)
  end
end

# Fully-qualified field name, so a kid widget is reported as "week.0"
# rather than as the bare "0" its own /T carries.
def qualified_name(objects, node)
  parts = []
  16.times do
    break unless node.is_a?(Hash)

    part = objects.deref(node[:T])
    parts.unshift(part.to_s) if part
    node = objects.deref(node[:Parent])
  end
  parts.join('.')
end

# field name => { size:, lines: }
def appearances(path)
  objects = PDF::Reader::ObjectHash.new(path)
  result = {}
  objects.each do |_ref, obj|
    next unless obj.is_a?(Hash) && obj[:T] && obj[:AP]

    ap = objects.deref(obj[:AP])
    normal = ap.is_a?(Hash) ? objects.deref(ap[:N]) : nil
    next unless normal.is_a?(PDF::Reader::Stream)

    stream = normal.unfiltered_data
    result[qualified_name(objects, obj)] = {
      size: stream[%r{/\S+\s+([\d.]+)\s+Tf}, 1].to_f,
      lines: ContentStream.text_positions(stream)
    }
  end
  result
end

# The value every text field is filled with. Keep it short enough to fit:
# a value wider than its field triggers the one big deliberate difference
# (acrofill shrinks to fit, pdftk keeps the size and clips), which then
# swamps every other signal. VALUE=... to override.
SAMPLE = ENV.fetch('VALUE', 'Test')

def sample_data(template)
  Acrofill.fields(template).filter_map do |field|
    next if field.type == :Btn

    [field.name, SAMPLE]
  end.to_h
end

# One drawn line side by side; marks disagreement beyond TOLERANCE.
def report_line(label, index, them, ours)
  if them.nil? || ours.nil?
    puts format('  %-22s %-3s %s', label, index, them ? 'pdftk only' : 'acrofill only')
    return
  end

  dx = ours[0] - them[0]
  dy = ours[1] - them[1]
  agree = dx.abs <= TOLERANCE && dy.abs <= TOLERANCE && ours[2] == them[2]
  puts format('%s %-22s %-3s pdftk x=%-9.2f y=%-9.2f | acrofill x=%-9.2f y=%-9.2f | dx=%+.3f dy=%+.3f',
              agree ? ' ' : '*', label, index, them[0], them[1], ours[0], ours[1], dx, dy)
  puts format('  %-26s text pdftk=%p acrofill=%p', '', them[2], ours[2]) if ours[2] != them[2]
end

def report_field(name, mine, theirs)
  label = name[0, 22]
  our_lines = mine&.dig(:lines) || []
  their_lines = theirs&.dig(:lines) || []
  [our_lines.size, their_lines.size].max.times do |i|
    report_line(i.zero? ? label : '', i, their_lines[i], our_lines[i])
  end
  return unless mine && theirs && (mine[:size] - theirs[:size]).abs > TOLERANCE

  puts format('* %-22s     font size pdftk=%s acrofill=%s', label, theirs[:size], mine[:size])
end

templates = ARGV
abort 'usage: ruby benchmark/geometry_diff.rb <template.pdf> ...' if templates.empty?
abort 'pdftk not on PATH — nothing to compare against' unless pdftk?

puts "pdftk: #{`pdftk --version`.lines.first.strip}"
puts "acrofill: #{Acrofill::VERSION}"
puts "value: #{SAMPLE.inspect}"
puts "lines marked * differ by more than #{TOLERANCE}pt or draw different text\n\n"

templates.each do |template|
  data = sample_data(template)
  Dir.mktmpdir do |dir|
    mine = File.join(dir, 'acrofill.pdf')
    theirs = File.join(dir, 'pdftk.pdf')
    Acrofill.fill_form(template, mine, data)
    run_pdftk(template, data, theirs)

    a = appearances(mine)
    b = appearances(theirs)
    puts "== #{File.basename(template)} (#{data.size} text fields)"
    (a.keys | b.keys).sort.each { |name| report_field(name, a[name], b[name]) }
    puts
  end
end
