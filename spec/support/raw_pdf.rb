# frozen_string_literal: true

# Minimal raw-PDF assembler for hand-crafted object graphs: +objects+ is an
# array of object body strings, 1-indexed, with object 1 as the catalog.
# Writes the file into +dir+ and returns its path.
module RawPdf
  module_function

  def write(dir, objects, name: 'raw.pdf')
    out = +"%PDF-1.4\n"
    offsets = objects.each_with_index.map do |body, idx|
      offset = out.bytesize
      out << "#{idx + 1} 0 obj\n#{body}\nendobj\n"
      offset
    end
    xref = out.bytesize
    out << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
    offsets.each { |o| out << format("%010d 00000 n \n", o) }
    out << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
    path = File.join(dir, name)
    File.binwrite(path, out.b)
    path
  end
end
