/// Fills the legacy FORMTEXT fields and the literal checkbox glyphs of a .docx
/// form, without Word. Written for the Camara Municipal de Coimbra forms
/// (MOD-009, MOD-012, MOD-079), whose fields carry no useful names, so both
/// fields and checkboxes are addressed by their order in the document.
///
/// usage (from agenda/core):
///   dart run tool/fill_docx_form.dart list <in.docx>
///   dart run tool/fill_docx_form.dart fill <in.docx> <out.docx> <values.txt>
///
/// values.txt, one instruction per line, '#' starts a comment:
///   text:<n>:<value>   put <value> into the nth FORMTEXT field (1-based)
///   check:<n>          turn the nth checkbox glyph into a ticked one
///
/// What this tool does NOT reach: the round SIM/NAO option buttons of the same
/// forms. Those are ActiveX controls (Forms.OptionButton.1), not glyphs: the
/// document only references them, and LibreOffice renders them from their
/// state, not from the picture stored next to them, so replacing the .wmf
/// changes nothing. Their state lives in word/activeX/activeXN.bin, as a single
/// character right before the control's caption or name inside the .bin:
/// '0' (0x30) off, '1' (0x31) on. To tick one by hand (done on 19.10.2026 for
/// MOD-012 "medidas de minimizacao do ruido: SIM" and for the MOD-079 unit
/// "m 2" and periodicidade "Dia(s)"): unzip the .docx, find which activeXN.xml
/// the w:control r:id points at in word/_rels/document.xml.rels, locate the
/// caption bytes in that .bin, set the 0x30 before it to 0x31, zip it up again
/// with [Content_Types].xml first, and convert to PDF with soffice. Always
/// compare pdftotext of the old and the new PDF afterwards: it must be
/// identical, since only the control state changed.
library;

import 'dart:io';

const _begin = '<w:fldChar w:fldCharType="begin">';
const _sep = '<w:fldChar w:fldCharType="separate"/>';
const _end = '<w:fldChar w:fldCharType="end"/>';
const _unchecked = '☐'; // the empty box the forms use
const _checked = '☒'; // box with a cross

String _esc(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// Start offsets of every FORMTEXT field, in document order.
List<int> _textFields(String xml) {
  final out = <int>[];
  var i = 0;
  while (true) {
    i = xml.indexOf(_begin, i);
    if (i < 0) break;
    final ff = xml.indexOf('</w:ffData>', i);
    if (ff > 0 && xml.substring(i, ff).contains('<w:textInput')) out.add(i);
    i += _begin.length;
  }
  return out;
}

/// Visible text just before [at], as a hint of what the field is called.
String _context(String xml, int at, {int chars = 90}) {
  final from = at - 4000 < 0 ? 0 : at - 4000;
  final before = xml.substring(from, at);
  final words = RegExp(r'<w:t[^>]*>([^<]*)</w:t>')
      .allMatches(before)
      .map((m) => m.group(1)!)
      .where((s) => s.trim().isNotEmpty && s.trim() != _unchecked)
      .toList();
  final text = words.join(' ').replaceAll(RegExp(r'\s+'), ' ');
  return text.length > chars ? text.substring(text.length - chars) : text;
}

String _fillOne(String xml, int fieldStart, String value) {
  final sep = xml.indexOf(_sep, fieldStart);
  final runClose = xml.indexOf('</w:r>', sep) + '</w:r>'.length;
  final end = xml.indexOf(_end, runClose);
  final endRun = [xml.lastIndexOf('<w:r ', end), xml.lastIndexOf('<w:r>', end)]
      .reduce((a, b) => a > b ? a : b);
  const rpr = '<w:rPr><w:rFonts w:ascii="Times New Roman" '
      'w:hAnsi="Times New Roman" w:cs="Times New Roman"/><w:noProof/></w:rPr>';
  final run = '<w:r>$rpr<w:t xml:space="preserve">${_esc(value)}</w:t></w:r>';
  return xml.replaceRange(runClose, endRun, run);
}

Future<void> main(List<String> argv) async {
  if (argv.length < 2) {
    stderr.writeln('usage: fill_docx_form.dart list <in.docx> | '
        'fill <in.docx> <out.docx> <values.txt>');
    exit(2);
  }
  final cmd = argv.first;
  final input = File(argv[1]).absolute.path;
  final work = await Directory.systemTemp.createTemp('docxfill');
  try {
    final unzip = await Process.run('unzip', ['-q', '-o', input, '-d', work.path]);
    if (unzip.exitCode != 0) throw StateError('unzip failed: ${unzip.stderr}');
    final docFile = File('${work.path}/word/document.xml');
    var xml = await docFile.readAsString();

    if (cmd == 'list') {
      final fields = _textFields(xml);
      print('${fields.length} FORMTEXT fields:');
      for (var i = 0; i < fields.length; i++) {
        print('text:${i + 1}  <- ${_context(xml, fields[i])}');
      }
      var n = 0;
      var at = 0;
      print('');
      while (true) {
        at = xml.indexOf('<w:t>$_unchecked</w:t>', at);
        if (at < 0) break;
        n++;
        print('check:$n  ${_context(xml, at, chars: 60)}  [NEXT: '
            '${_afterLabel(xml, at)}]');
        at += 1;
      }
      print('\n$n checkboxes');
      return;
    }

    if (cmd != 'fill' || argv.length < 4) {
      stderr.writeln('usage: fill <in.docx> <out.docx> <values.txt>');
      exit(2);
    }
    final out = File(argv[2]).absolute.path;
    final lines = await File(argv[3]).readAsLines();

    final texts = <int, String>{};
    final checks = <int>{};
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('text:')) {
        final rest = line.substring(5);
        final colon = rest.indexOf(':');
        texts[int.parse(rest.substring(0, colon))] = rest.substring(colon + 1);
      } else if (line.startsWith('check:')) {
        checks.add(int.parse(line.substring(6)));
      } else {
        throw StateError('cannot read instruction: $line');
      }
    }

    // Fill from the last field backwards, so earlier offsets stay valid.
    final fields = _textFields(xml);
    for (final n in texts.keys.toList()..sort((a, b) => b.compareTo(a))) {
      if (n < 1 || n > fields.length) throw StateError('no text field $n');
      xml = _fillOne(xml, fields[n - 1], texts[n]!);
    }
    // Checkboxes, also backwards.
    final boxes = <int>[];
    var at = 0;
    while (true) {
      at = xml.indexOf('<w:t>$_unchecked</w:t>', at);
      if (at < 0) break;
      boxes.add(at);
      at += 1;
    }
    for (final n in checks.toList()..sort((a, b) => b.compareTo(a))) {
      if (n < 1 || n > boxes.length) throw StateError('no checkbox $n');
      xml = xml.replaceRange(
          boxes[n - 1], boxes[n - 1] + '<w:t>$_unchecked</w:t>'.length, '<w:t>$_checked</w:t>');
    }
    await docFile.writeAsString(xml);

    final outFile = File(out);
    if (outFile.existsSync()) outFile.deleteSync();
    final zip = await Process.run('zip', ['-q', '-r', '-X', out, '.'],
        workingDirectory: work.path);
    if (zip.exitCode != 0) throw StateError('zip failed: ${zip.stderr}');
    print('wrote $out (${texts.length} fields, ${checks.length} checkboxes)');
  } finally {
    await work.delete(recursive: true);
  }
}

/// The first visible words after a checkbox, which is its label.
String _afterLabel(String xml, int at) {
  final to = at + 2000 > xml.length ? xml.length : at + 2000;
  final words = RegExp(r'<w:t[^>]*>([^<]*)</w:t>')
      .allMatches(xml.substring(at + 10, to))
      .map((m) => m.group(1)!)
      .where((s) => s.trim().isNotEmpty && s.trim() != _unchecked)
      .take(6)
      .join(' ');
  return words.replaceAll(RegExp(r'\s+'), ' ');
}
