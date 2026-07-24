# frozen_string_literal: true

require 'timeout'

# Regression tests for the DoS hardening: the two recursive walks
# (Document#each_page and Form#collect_fields) must terminate on cyclic
# and on exponentially-shared (billion-laughs) object graphs, since the
# PDF template is untrusted input.
RSpec.describe 'malicious template hardening' do
  around do |example|
    Dir.mktmpdir('acrofill-sec') do |dir|
      @dir = dir
      example.run
    end
  end

  def build(objects)
    RawPdf.write(@dir, objects, name: 'evil.pdf')
  end

  def within_budget(&block)
    Timeout.timeout(10, &block)
  end

  it 'terminates on a self-referential /Pages tree (cycle)' do
    # obj2 is a Pages node whose Kids point back to itself.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [2 0 R] /Count 1 >>',
                   '<< /Fields [] >>'
                 ])
    expect { within_budget { Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), {}, flatten: true) } }
      .not_to raise_error
  end

  it 'terminates on a cyclic field /Kids graph' do
    # Field 4 has a subfield 5; field 5 references 4 back as its kid.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [] /Count 0 >>',
                   '<< /Fields [4 0 R] >>',
                   '<< /T (a) /Kids [5 0 R] >>',
                   '<< /T (b) /Kids [4 0 R] >>'
                 ])
    expect { within_budget { Acrofill.field_names(path) } }.not_to raise_error
  end

  it 'does not amplify exponentially on a shared (DAG) /Pages tree' do
    # 30 Pages levels, each referencing the next twice. Without a visited
    # set this is 2**30 (~1e9) visits; with one it is ~30.
    depth = 30
    objects = ['<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>', nil, '<< /Fields [] >>']
    (0...depth).each do |level|
      obj_num = 4 + level
      child = level == depth - 1 ? '' : "/Kids [#{obj_num + 1} 0 R #{obj_num + 1} 0 R]"
      objects << "<< /Type /Pages #{child} /Count 1 >>"
    end
    objects[1] = '<< /Type /Pages /Kids [4 0 R 4 0 R] /Count 1 >>'
    path = build(objects)

    expect { within_budget { Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), {}, flatten: true) } }
      .not_to raise_error
  end

  it 'does not blow up quadratically on a huge multiline value' do
    # Wide box so nothing wraps: the old O(words^2) path took ~20s at 8k
    # words; the incremental path stays well under the budget.
    objects = [
      '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
      '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
      '<< /Fields [5 0 R] /DA (/Helv 10 Tf 0 g) >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
      '<< /Type /Annot /Subtype /Widget /FT /Tx /T (notes) /Ff 4096 ' \
      '/Rect [0 0 100000000 200] /DA (/Helv 10 Tf 0 g) >>'
    ]
    path = build(objects)
    value = (['word'] * 8000).join(' ')
    within_budget do
      Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), { 'notes' => value })
    end
  end

  it 'survives a non-finite real number in a reachable object' do
    big = "1#{'0' * 400}.0" # parsed as Float::INFINITY by pdf-reader
    path = build([
                   "<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R /Junk #{big} >>",
                   '<< /Type /Pages /Kids [] /Count 0 >>',
                   '<< /Fields [] >>'
                 ])
    expect { Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), {}, flatten: true) }
      .not_to raise_error
  end

  it 'does not inject content operators from a crafted /DA string' do
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
                   '<< /Fields [5 0 R] /DA (/Helv 0 Tf 0 g) >>',
                   '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Tx /T (x) /Rect [10 10 200 40] ' \
                   '/DA (/Helv 10 Tf 1 0 0 rg 0 0 500 500 re f) >>'
                 ])
    Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), { 'x' => 'hello' })

    reader = PDF::Reader.new(File.join(@dir, 'o.pdf'))
    ap = nil
    reader.objects.each do |_ref, obj|
      ap = obj if obj.is_a?(PDF::Reader::Stream) && obj.data.include?('hello')
    end
    expect(ap.data).not_to include('re f') # rectangle-fill operator dropped
    expect(ap.data).not_to include('0 0 500 500')
  end

  it 'caps recursion in the serializer instead of overflowing the stack' do
    # Build the nesting as Ruby objects (bypassing pdf-reader's own parser)
    # to exercise Serializer's depth guard directly.
    deep = 0
    5000.times { deep = [deep] }
    expect { Acrofill::Serializer.new({}).serialize(deep) }
      .to raise_error(Acrofill::Error, /nesting/)
  end

  it 'treats a mistyped /AP on a button field as no states, not a crash' do
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [] /Count 0 >>',
                   '<< /Fields [4 0 R] >>',
                   '<< /Type /Annot /Subtype /Widget /FT /Btn /T (b) /Rect [0 0 12 12] /AP [1 2 3] >>'
                 ])
    expect { Acrofill.fields(path) }.not_to raise_error
    expect { Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), { 'b' => 'Yes' }) }
      .not_to raise_error
  end

  it 'surfaces only Acrofill::Error for an encrypted/undecryptable document' do
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R >>',
                   '<< /Type /Pages /Kids [] /Count 0 >>'
                 ])
    # Splice an /Encrypt entry into the trailer.
    raw = File.binread(path).sub('/Root 1 0 R', '/Root 1 0 R /Encrypt 2 0 R')
    File.binwrite(path, raw)
    expect { Acrofill.field_names(path) }.to raise_error(Acrofill::Error)
  end

  it 'wraps arbitrary pdf-reader parse failures as Acrofill::Error' do
    path = File.join(@dir, 'garbage.pdf')
    File.binwrite(path, "%PDF-1.4\nnot a real pdf at all\n%%EOF")
    expect { Acrofill.field_names(path) }.to raise_error(Acrofill::Error)
  end

  it 'wraps a parser stack overflow from deeply nested objects as Acrofill::Error' do
    # pdf-reader's recursive-descent parser overflows the Ruby stack on
    # this input; the parse boundary must convert that SystemStackError.
    nested = ('[' * 10_000) + (']' * 10_000)
    path = build([
                   "<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R /Junk #{nested} >>",
                   '<< /Type /Pages /Kids [] /Count 0 >>',
                   '<< /Fields [] >>'
                 ])
    expect { within_budget { Acrofill.field_names(path) } }.to raise_error(Acrofill::Error)
  end

  it 'wraps lazy parse failures from a corrupt object body as Acrofill::Error' do
    # The xref and trailer are valid, so ObjectHash.new succeeds; the
    # corrupt body only surfaces when objects are materialized later.
    path = build([
                   '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
                   '<< /Type /Pages /Kids [] /Count 0 >>',
                   '<< /Broken >]>'
                 ])
    expect { Acrofill.field_names(path) }.to raise_error(Acrofill::Error)
  end

  it 'walks a deep linear /Pages chain without overflowing the stack' do
    depth = 6000
    objects = ['<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
               '<< /Type /Pages /Kids [4 0 R] /Count 0 >>',
               '<< /Fields [] >>']
    (0...depth).each do |level|
      obj_num = 4 + level
      kids = level == depth - 1 ? '[]' : "[#{obj_num + 1} 0 R]"
      objects << "<< /Type /Pages /Kids #{kids} /Count 0 >>"
    end
    path = build(objects)
    expect { within_budget { Acrofill.fill_form(path, File.join(@dir, 'o.pdf'), {}, flatten: true) } }
      .not_to raise_error
  end

  it 'walks a deep linear field /Kids chain without overflowing the stack' do
    depth = 6000
    objects = ['<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
               '<< /Type /Pages /Kids [] /Count 0 >>',
               '<< /Fields [4 0 R] >>']
    (0...depth).each do |level|
      obj_num = 4 + level
      kids = level == depth - 1 ? '' : "/Kids [#{obj_num + 1} 0 R]"
      objects << "<< /T (f#{level}) #{kids} >>"
    end
    path = build(objects)
    expect { within_budget { Acrofill.field_names(path) } }.not_to raise_error
  end
end
