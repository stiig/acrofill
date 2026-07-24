# frozen_string_literal: true

# Builds a minimal, valid AcroForm PDF from scratch (classic xref,
# uncompressed streams) so the test suite ships no binary fixtures.
#
# Layout: one 612x792 page with these fields:
#   "name"    - text, left-aligned, fixed 10pt
#   "amount"  - text, centered (/Q 1), fixed 10pt
#   "auto"    - text, auto-sized (0 Tf)
#   "week.0"  - text, kid of non-terminal parent field "week"
#   "agree"   - checkbox with /Yes and /Off appearance states
#   "color"   - radio group with two kid widgets (/Red, /Blue)
#   "notes"   - multiline text (/Ff 4096)
module FixturePdf
  module_function

  def build(acroform: true)
    objects = []
    objects << '<< /Type /Catalog /Pages 2 0 R' \
               "#{' /AcroForm 4 0 R' if acroform} >>"
    objects << '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'
    objects << '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ' \
               '/Resources << /Font << /Helv 5 0 R >> >> /Contents 6 0 R ' \
               '/Annots [7 0 R 8 0 R 9 0 R 11 0 R 14 0 R 16 0 R 17 0 R 18 0 R] >>'
    objects << '<< /Fields [7 0 R 8 0 R 9 0 R 10 0 R 14 0 R 15 0 R 18 0 R] ' \
               '/DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 5 0 R >> >> >>'
    objects << '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ' \
               '/Encoding /WinAnsiEncoding >>'
    content = "0.5 w 50 700 200 20 re S\n"
    objects << "<< /Length #{content.bytesize} >>\nstream\n#{content}endstream" # 6
    objects << widget('name', '[50 700 250 720]', extra: '/DA (/Helv 10 Tf 0 g)') # 7
    objects << widget('amount', '[50 650 250 670]', extra: '/DA (/Helv 10 Tf 0 g) /Q 1') # 8
    objects << widget('auto', '[50 600 250 620]') # 9
    objects << '<< /FT /Tx /T (week) /Kids [11 0 R] >>' # 10
    objects << widget('0', '[50 550 250 570]', extra: '/Parent 10 0 R') # 11
    check = "q 1 0 0 RG 2 2 m 10 10 l S 2 10 m 10 2 l S Q\n"
    objects << '<< /BBox [0 0 12 12] /Subtype /Form /Type /XObject ' \
               "/Length #{check.bytesize} >>\nstream\n#{check}endstream" # 12
    objects << '<< /BBox [0 0 12 12] /Subtype /Form /Type /XObject ' \
               "/Length 0 >>\nstream\nendstream" # 13
    objects << '<< /Type /Annot /Subtype /Widget /FT /Btn /T (agree) ' \
               '/Rect [50 500 62 512] /AS /Off ' \
               '/AP << /N << /Yes 12 0 R /Off 13 0 R >> >> >>' # 14
    objects << '<< /FT /Btn /T (color) /Ff 32768 /Kids [16 0 R 17 0 R] >>' # 15
    objects << '<< /Type /Annot /Subtype /Widget /Parent 15 0 R ' \
               '/Rect [50 450 62 462] /AS /Off ' \
               '/AP << /N << /Red 12 0 R /Off 13 0 R >> >> >>' # 16
    objects << '<< /Type /Annot /Subtype /Widget /Parent 15 0 R ' \
               '/Rect [70 450 82 462] /AS /Off ' \
               '/AP << /N << /Blue 12 0 R /Off 13 0 R >> >> >>' # 17
    objects << widget('notes', '[300 500 500 700]',
                      extra: '/DA (/Helv 10 Tf 0 g) /Ff 4096') # 18

    render(objects)
  end

  def widget(name, rect, extra: '')
    "<< /Type /Annot /Subtype /Widget /FT /Tx /T (#{name}) " \
      "/Rect #{rect} #{extra} >>"
  end

  def render(objects)
    out = +"%PDF-1.4\n%\xE2\xE3\xCF\xD3\n"
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

  def write(dir, acroform: true)
    path = File.join(dir, acroform ? 'form.pdf' : 'plain.pdf')
    File.binwrite(path, build(acroform: acroform))
    path
  end
end
