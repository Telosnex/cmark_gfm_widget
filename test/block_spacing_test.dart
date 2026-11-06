import 'package:cmark_gfm_widget/cmark_gfm_widget.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_snap_fork/material.dart';

// Block spacing goes between blocks. No block adds space after itself, so
// the last block of a document, quote or list item ends at its content.

const _spacing = 10.0;
const _listItemSpacing = 6.0;
const _listItemBlockSpacing = 4.0;
const _before = 20.0;
const _after = 3.0;

CmarkThemeData _theme({bool headingSpacing = false}) {
  final base = CmarkThemeData.fallback(Typography.englishLike2021);
  return base.copyWith(
    blockSpacing: _spacing,
    headingSpacingBefore: headingSpacing ? _before : null,
    headingSpacingAfter: headingSpacing ? _after : null,
    listItemSpacing: _listItemSpacing,
    listItemBlockSpacing: headingSpacing ? _listItemBlockSpacing : null,
    blockQuotePadding: EdgeInsets.zero,
    codeBlockPadding: EdgeInsets.zero,
    orderedListBulletTextStyle: base.paragraphTextStyle,
    unorderedListBulletTextStyle: base.paragraphTextStyle,
  );
}

Future<double> _pumpHeight(
  WidgetTester tester,
  String markdown, {
  bool selectable = false,
  bool headingSpacing = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CmarkTheme(
            data: _theme(headingSpacing: headingSpacing),
            child: CmarkMarkdownColumn(
              data: markdown,
              selectable: selectable,
            ),
          ),
        ),
      ),
    ),
  );
  return tester.getSize(find.byType(CmarkMarkdownColumn)).height;
}

/// Height of the one paragraph whose text is exactly [text].
double _textHeight(WidgetTester tester, String text) {
  final matches = tester.allRenderObjects
      .whereType<RenderParagraph>()
      .where((p) => p.text.toPlainText() == text)
      .toSet()
      .toList();
  expect(matches, hasLength(1), reason: 'one paragraph with "$text"');
  return matches.single.size.height;
}

/// Sum of the heights of the paragraphs with [texts].
double _textsHeight(WidgetTester tester, List<String> texts) =>
    texts.map((t) => _textHeight(tester, t)).reduce((a, b) => a + b);

void main() {
  for (final selectable in [false, true]) {
    group('selectable: $selectable', () {
      testWidgets('one paragraph adds no space', (tester) async {
        final height =
            await _pumpHeight(tester, 'alpha', selectable: selectable);
        expect(height, _textHeight(tester, 'alpha'));
      });

      testWidgets('spacing goes only between top-level blocks', (tester) async {
        final height = await _pumpHeight(
          tester,
          'alpha\n\n# beta\n\ngamma',
          selectable: selectable,
        );
        expect(
          height,
          _textHeight(tester, 'alpha') +
              _textHeight(tester, 'beta') +
              _textHeight(tester, 'gamma') +
              2 * _spacing,
        );
      });

      testWidgets('one code block adds no space', (tester) async {
        final height =
            await _pumpHeight(tester, '```\ncode\n```', selectable: selectable);
        expect(height, _textHeight(tester, 'code'));
      });

      testWidgets('one table adds no space', (tester) async {
        final height = await _pumpHeight(
          tester,
          '| h |\n| - |\n| c |',
          selectable: selectable,
        );
        final table = tester.renderObject<RenderBox>(find.byType(Table));
        // The table renderer puts 4 dp above a table with a header row.
        expect(height, table.size.height + 4);
      });

      testWidgets('one thematic break adds no space', (tester) async {
        final height = await _pumpHeight(tester, '---', selectable: selectable);
        final theme = _theme();
        expect(
          height,
          theme.thematicBreakThickness + theme.thematicBreakVerticalPadding,
        );
      });

      testWidgets('a quote has spacing between its blocks, not after them',
          (tester) async {
        final height = await _pumpHeight(
          tester,
          '> alpha\n>\n> beta',
          selectable: selectable,
        );
        expect(
          height,
          _textHeight(tester, 'alpha') + _textHeight(tester, 'beta') + _spacing,
        );
      });

      testWidgets('a loose list has item spacing between items, not after',
          (tester) async {
        final height = await _pumpHeight(
          tester,
          '- alpha\n\n- beta',
          selectable: selectable,
        );
        expect(
          height,
          _textHeight(tester, 'alpha') +
              _textHeight(tester, 'beta') +
              _listItemSpacing,
        );
      });

      testWidgets('a list item adds no space after its last block',
          (tester) async {
        final height = await _pumpHeight(
          tester,
          '- alpha\n\n  ```\n  code\n  ```',
          selectable: selectable,
        );
        // listItemBlockSpacing is 0 by default.
        expect(
          height,
          _textHeight(tester, 'alpha') + _textHeight(tester, 'code'),
        );
      });
    });

    group('heading spacing, selectable: $selectable', () {
      Future<double> pump(WidgetTester tester, String markdown) => _pumpHeight(
            tester,
            markdown,
            selectable: selectable,
            headingSpacing: true,
          );

      testWidgets('goes above and below a heading', (tester) async {
        final height = await pump(tester, 'alpha\n\n# beta\n\ngamma');
        expect(
          height,
          _textsHeight(tester, ['alpha', 'beta', 'gamma']) + _before + _after,
        );
      });

      testWidgets('a first heading has no space above it', (tester) async {
        final height = await pump(tester, '# alpha\n\nbeta');
        expect(height, _textsHeight(tester, ['alpha', 'beta']) + _after);
      });

      testWidgets('a last heading has no space below it', (tester) async {
        final height = await pump(tester, 'alpha\n\n# beta');
        expect(height, _textsHeight(tester, ['alpha', 'beta']) + _before);
      });

      testWidgets('two headings take the larger space', (tester) async {
        final height = await pump(tester, '# alpha\n## beta');
        expect(height, _textsHeight(tester, ['alpha', 'beta']) + _before);
      });

      testWidgets('other blocks keep block spacing', (tester) async {
        final height = await pump(tester, 'alpha\n\nbeta');
        expect(height, _textsHeight(tester, ['alpha', 'beta']) + _spacing);
      });

      testWidgets('applies in a quote', (tester) async {
        final height = await pump(tester, '> alpha\n>\n> # beta\n>\n> gamma');
        expect(
          height,
          _textsHeight(tester, ['alpha', 'beta', 'gamma']) + _before + _after,
        );
      });

      testWidgets('applies in a list item', (tester) async {
        final height = await pump(tester, '- alpha\n\n  # beta\n\n  gamma');
        expect(
          height,
          _textsHeight(tester, ['alpha', 'beta', 'gamma']) + _before + _after,
        );
      });

      testWidgets('list items keep list item block spacing', (tester) async {
        final height = await pump(tester, '- alpha\n\n  beta');
        expect(
          height,
          _textsHeight(tester, ['alpha', 'beta']) + _listItemBlockSpacing,
        );
      });
    });
  }

  testWidgets('CmarkBlockColumn without nodes uses block spacing', (
    tester,
  ) async {
    final theme = _theme(headingSpacing: true);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: CmarkBlockColumn(
            theme: theme,
            children: const [
              SizedBox(height: 7, width: 1),
              SizedBox(height: 7, width: 1),
            ],
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(CmarkBlockColumn)).height, 14 + _spacing);
  });

  test('spacingBetween', () {
    final theme = _theme(headingSpacing: true);
    final doc = ParserController().parse('a\n\n# h\n\nb').blocks.toList();
    final (paragraph, heading) = (doc[0], doc[1]);
    expect(theme.spacingBetween(paragraph, heading, 1), _before);
    expect(theme.spacingBetween(heading, paragraph, 1), _after);
    expect(theme.spacingBetween(paragraph, paragraph, 1), 1);
    expect(theme.spacingBetween(null, null, 1), 1);
    final unset = _theme();
    expect(unset.spacingBetween(paragraph, heading, 1), 1);
    expect(unset.hasHeadingSpacing, isFalse);
  });

  test('spacingBetween a lead-in and the block it introduces', () {
    final theme = _theme().copyWith(leadInSpacing: 2);
    double gap(String markdown) {
      final b = ParserController().parse(markdown).blocks.toList();
      return theme.spacingBetween(b[0], b[1], 1);
    }

    expect(gap('Options:\n\n- a'), 2);
    expect(gap('**Options:**\n\n- a'), 2);
    expect(gap('Run:\n\n```\nx\n```'), 2);
    expect(gap('Here:\n\n| a |\n| - |\n| b |'), 2);
    // Not a lead-in, or not a block it introduces.
    expect(gap('Done.\n\n- a'), 1);
    expect(gap('Next:\n\nmore text'), 1);
    expect(gap('`a:`\n\n- b'), 1);
    expect(gap('# Options:\n\n- a'), 1);
    expect(theme.hasNodeSpacing, isTrue);
    expect(_theme().hasNodeSpacing, isFalse);
  });

  testWidgets('a lead-in has leadInSpacing before its list', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CmarkTheme(
            data: _theme().copyWith(leadInSpacing: 2),
            child: const CmarkMarkdownColumn(data: 'Options:\n\n- alpha'),
          ),
        ),
      ),
    );
    final lead = _rect(tester, 'Options:');
    final item = _rect(tester, 'alpha');
    expect(item.top - lead.bottom, 2);
  });

  group('in a tight list item', () {
    Future<double> gap(
        WidgetTester tester, String md, String a, String b) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CmarkTheme(
              data: _theme(headingSpacing: true).copyWith(leadInSpacing: 2),
              child: CmarkMarkdownColumn(data: md),
            ),
          ),
        ),
      );
      return _rect(tester, b).top - _rect(tester, a).bottom;
    }

    testWidgets('a sublist sits right under its text', (tester) async {
      expect(await gap(tester, '- parent\n  - child', 'parent', 'child'), 0);
      expect(await gap(tester, '- run:\n  - child', 'run:', 'child'), 0);
    });

    testWidgets('the next item sits right under a sublist', (tester) async {
      const md = '- parent\n  - child\n- next';
      expect(await gap(tester, md, 'child', 'next'), 0);
    });

    testWidgets('a code block keeps its spacing', (tester) async {
      const md = '- run:\n  ```\n  code\n  ```';
      expect(await gap(tester, md, 'run:', 'code'), greaterThan(0));
    });
  });

  group('in a loose list item', () {
    Future<double> gap(
        WidgetTester tester, String md, String a, String b) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CmarkTheme(
              data: _theme(headingSpacing: true).copyWith(leadInSpacing: 2),
              child: CmarkMarkdownColumn(data: md),
            ),
          ),
        ),
      );
      return _rect(tester, b).top - _rect(tester, a).bottom;
    }

    final t = _theme(headingSpacing: true);

    testWidgets('a sublist sits right under its text', (tester) async {
      const md = '- parent\n  - child\n\n- next';
      expect(await gap(tester, md, 'parent', 'child'), 0);
      expect(await gap(tester, '- run:\n\n  - child', 'run:', 'child'), 0);
    });

    testWidgets('items keep listItemSpacing', (tester) async {
      const md = '- parent\n  - child\n\n- next';
      expect(await gap(tester, md, 'child', 'next'), t.listItemSpacing);
    });

    testWidgets('text after a sublist keeps listItemBlockSpacing', (
      tester,
    ) async {
      const md = '- parent\n\n  - child\n\n  more\n\n- next';
      expect(await gap(tester, md, 'child', 'more'), t.listItemBlockSpacing);
    });

    testWidgets('two paragraphs keep listItemBlockSpacing', (tester) async {
      const md = '- one\n\n  two\n\n- next';
      expect(await gap(tester, md, 'one', 'two'), t.listItemBlockSpacing);
    });
  });
}

Rect _rect(WidgetTester tester, String text) {
  final paragraph = tester.allRenderObjects
      .whereType<RenderParagraph>()
      .firstWhere((p) => p.text.toPlainText() == text);
  return paragraph.localToGlobal(Offset.zero) & paragraph.size;
}
