import 'package:cmark_gfm_dart/cmark_gfm_dart.dart';
import 'package:cmark_gfm_widget/cmark_gfm_widget.dart';
import 'package:flutter_test/flutter_test.dart';

const _item = '3. **Layout and paint** — text shaping is the most '
    'expensive part.\n';

List<CmarkNodeType> _types(DocumentSnapshot s) {
  final out = <CmarkNodeType>[];
  void visit(CmarkNode n) {
    out.add(n.type);
    for (var c = n.firstChild; c != null; c = c.next) {
      visit(c);
    }
  }

  visit(s.root);
  return out;
}

void main() {
  group('cmarkStreamingParseLength', () {
    test('leaves out an unfinished line of only - or =', () {
      for (final line in ['-', '   -', '   - ', '---', '==', '> -', '>>  =']) {
        expect(
          cmarkStreamingParseLength('Text\n$line'),
          'Text\n'.length,
          reason: line,
        );
      }
    });

    test('finds the last line after \\r\\n and \\r', () {
      expect(cmarkStreamingParseLength('Text\r\n-'), 'Text\r\n'.length);
      expect(cmarkStreamingParseLength('Text\r-'), 'Text\r'.length);
      // A line that has its \r has ended.
      expect(cmarkStreamingParseLength('Text\n-\r'), 'Text\n-\r'.length);
    });

    test('leaves out lines with tabs and lines in code blocks', () {
      // These are not underlines. They show one chunk later.
      expect(cmarkStreamingParseLength('Text\n\t-'), 'Text\n'.length);
      expect(cmarkStreamingParseLength('```\ncode\n-'), '```\ncode\n'.length);
    });

    test('keeps other lines', () {
      for (final text in [
        'Text\n- P',
        'Text\n-=',
        'Text\n=-',
        'Text\n|-',
        'Text\n',
        'Text\n   ',
        'Text\n-\n',
        '-',
        '---',
        'Text',
      ]) {
        expect(cmarkStreamingParseLength(text), text.length, reason: text);
      }
    });
  });

  test('a list item does not become a heading while its sub-item starts', () {
    final controller = ParserController();
    for (final tail in ['   -', '   - ']) {
      final streamed = _types(controller.parse(_item + tail, streaming: true));
      expect(streamed, isNot(contains(CmarkNodeType.heading)), reason: tail);
      expect(streamed, contains(CmarkNodeType.paragraph));
    }
    expect(
      _types(controller.parseChunks([_item, '   ', '-'], streaming: true)),
      isNot(contains(CmarkNodeType.heading)),
    );
    // Without streaming, the line is parsed as Markdown says.
    expect(
      _types(controller.parse('$_item   -')),
      contains(CmarkNodeType.heading),
    );
  });
}
