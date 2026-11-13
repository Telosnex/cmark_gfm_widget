import 'package:cmark_gfm_dart/cmark_gfm_dart.dart';
import 'package:cmark_gfm_widget/cmark_gfm_widget.dart';
import 'package:cmark_gfm_widget/src/render/details_grouping.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' hide SelectionArea;

Finder findRichTextContaining(String text) =>
    find.textContaining(text, findRichText: true);

// The shape of the reply in TEL-2846: a table in a section, with the
// `</details>` right after a paragraph.
const _reply = '''
Everything else follows the rules. Full list:

<details><summary>All Main models</summary>

Default level marked with *.

| Model | Level | Skill |
|---|---|---|
| Claude Opus 5.5 | Low | 0.495 |
| | Medium* | 0.721 |

"Anchor (assumed)" means the run does not say which level it used.
</details>

If none of these values bother you, I'll wire it in next.
''';

final _theme = CmarkThemeData.fallback(ThemeData().textTheme);

List<DetailsItem> _group(String markdown) =>
    groupDetails(ParserController().parse(markdown).blocks);

/// A description of [items], such as `P [details(Title): P TABLE] P`.
String _shape(List<DetailsItem> items) => items.map((item) {
      return switch (item) {
        DetailsBlockItem(:final node) => switch (node.type) {
            CmarkNodeType.paragraph => 'P',
            CmarkNodeType.table => 'TABLE',
            CmarkNodeType.htmlBlock => 'HTML',
            CmarkNodeType.list => 'LIST',
            CmarkNodeType.codeBlock => 'CODE',
            _ => node.type.name,
          },
        DetailsGroupItem() => '[details(${item.summaryText})'
            '${item.initiallyOpen ? ' open' : ''}'
            '${item.closer == null ? ' unclosed' : ''}'
            ': ${_shape(item.children)}]',
      };
    }).join(' ');

Widget _app(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// Renders [markdown] with [options] into a column, as an app does.
Widget _column(
  DocumentSnapshot snapshot, {
  RenderOptions options = const RenderOptions(selectable: true),
  BlockRenderCache? cache,
}) {
  final results = const RenderPipeline().render(
    snapshot,
    _theme,
    options,
    cache: cache,
  );
  return CmarkBlockColumn(
    theme: _theme,
    nodes: [for (final r in results) r.node],
    children: [
      for (final r in results)
        KeyedSubtree(key: ValueKey<String>(r.id), child: r.widget),
    ],
  );
}

void main() {
  group('groupDetails', () {
    test('groups the TEL-2846 reply', () {
      expect(
        _shape(_group(_reply)),
        'P [details(All Main models): P TABLE P] P',
      );
    });

    test('a </details> right after a table ends the table', () {
      final items = _group(
        '<details><summary>T</summary>\n\n'
        '| a |\n|---|\n| 1 |\n</details>\n\nAfter',
      );
      expect(_shape(items), '[details(T): TABLE] P');
      final table =
          (items.first as DetailsGroupItem).children.single as DetailsBlockItem;
      var rows = 0;
      for (var r = table.node.firstChild; r != null; r = r.next) {
        rows++;
      }
      expect(rows, 2);
    });

    test('nests sections and handles tags that share a block', () {
      expect(
        _shape(
          _group(
            '<details>\n<summary>Outer</summary>\n\nA\n\n'
            '<details><summary>Inner</summary>\n\nB\n\n'
            '</details>\n</details>\n<details><summary>Next</summary>\n\n'
            'C\n\n</details>',
          ),
        ),
        '[details(Outer): P [details(Inner): P]] [details(Next): P]',
      );
    });

    test('takes a summary from its own block', () {
      expect(
        _shape(_group('<details>\n\n<summary>Late</summary>\n\nA')),
        '[details(Late) unclosed: P]',
      );
    });

    test('reads the open attribute, tags in the summary and entities', () {
      expect(
        _shape(
          _group(
            '<details open>\n<summary> <b>R&amp;D</b>\n notes </summary>\n\nA',
          ),
        ),
        '[details(R&D notes) open unclosed: P]',
      );
      expect(
        _shape(_group('<details opener>\n\nA')),
        '[details(null) unclosed: P]',
      );
    });

    test('leaves out a stray </details>', () {
      expect(_shape(_group('A\n\n</details>\n\nB')), 'P P');
    });

    test('keeps other HTML blocks as blocks', () {
      expect(_shape(_group('<summary>Alone</summary>\n\nA')), 'HTML P');
      expect(_shape(_group('<div>\nx\n</div>')), 'HTML');
      // With no blank line after the summary, CommonMark makes one HTML
      // block of the summary and the text. It shows as text, as on GitHub.
      expect(
        _shape(_group('<details><summary>T</summary>\nBody\n</details>')),
        'HTML',
      );
    });

    test('groups the blocks of a list item and a block quote', () {
      final doc = ParserController().parse(
        '- Item\n\n  <details><summary>In list</summary>\n\n  A\n\n'
        '  </details>\n\n> <details><summary>In quote</summary>\n>\n> B',
      );
      final item = doc.blocks.first.firstChild!;
      expect(
        _shape(groupDetails(_children(item))),
        'P [details(In list): P]',
      );
      final quote = doc.blocks.last;
      expect(
        _shape(groupDetails(_children(quote))),
        '[details(In quote) unclosed: P]',
      );
    });
  });

  group('rendering', () {
    testWidgets('shows a closed section that opens and closes on tap',
        (tester) async {
      await tester.pumpWidget(
        _app(
          SelectionArea(child: _column(ParserController().parse(_reply))),
        ),
      );
      expect(findRichTextContaining('All Main models'), findsOneWidget);
      expect(findRichTextContaining('<details'), findsNothing);
      expect(findRichTextContaining('</details'), findsNothing);
      expect(findRichTextContaining('Default level'), findsNothing);
      expect(findRichTextContaining('wire it in next'), findsOneWidget);

      await tester.tap(findRichTextContaining('All Main models'));
      await tester.pump();
      expect(findRichTextContaining('Default level'), findsOneWidget);
      expect(findRichTextContaining('Claude Opus 5.5'), findsOneWidget);

      await tester.tap(findRichTextContaining('All Main models'));
      await tester.pump();
      expect(findRichTextContaining('Default level'), findsNothing);
    });

    testWidgets('starts open with the open attribute', (tester) async {
      await tester.pumpWidget(
        _app(
          _column(
            ParserController().parse(
              '<details open><summary>Shown</summary>\n\nBody\n\n</details>',
            ),
          ),
        ),
      );
      expect(findRichTextContaining('Body'), findsOneWidget);
    });

    testWidgets('a section in a list item opens', (tester) async {
      await tester.pumpWidget(
        _app(
          _column(
            ParserController().parse(
              '- Item\n\n  <details><summary>Nested</summary>\n\n  Inside\n\n'
              '  </details>',
            ),
          ),
        ),
      );
      expect(findRichTextContaining('Inside'), findsNothing);
      await tester.tap(findRichTextContaining('Nested'));
      await tester.pump();
      expect(findRichTextContaining('Inside'), findsOneWidget);
    });

    testWidgets('a builder gets the parts', (tester) async {
      final calls = <CmarkDetailsData>[];
      final options = RenderOptions(
        selectable: true,
        detailsBuilder: (context, data) {
          calls.add(data);
          return Column(children: [data.summary, data.body]);
        },
      );
      final controller = ParserController();
      await tester.pumpWidget(
        _app(
          _column(
            controller.parse(
              '<details><summary>S</summary>\n\nBody',
              streaming: true,
            ),
            options: options,
          ),
        ),
      );
      expect(calls.last.summaryText, 'S');
      expect(calls.last.initiallyOpen, isFalse);
      expect(calls.last.isComplete, isFalse);
      expect(findRichTextContaining('Body'), findsOneWidget);

      await tester.pumpWidget(
        _app(
          _column(
            controller.parse(
              '<details><summary>S</summary>\n\nBody\n</details>\n',
              streaming: true,
            ),
            options: options,
          ),
        ),
      );
      expect(calls.last.isComplete, isTrue);
    });

    testWidgets('copy includes the summary and the open body', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(
        _app(
          SelectionArea(
            child: _column(
              ParserController().parse(
                'Before\n\n<details><summary>Title</summary>\n\nInside\n\n'
                '</details>\n\nAfter',
              ),
            ),
          ),
        ),
      );
      await tester.tap(findRichTextContaining('Title'));
      await tester.pump();

      Future<void> selectAllAndCopy() async {
        await tester.tap(findRichTextContaining('Before'));
        await tester.pump();
        for (final key in [LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyC]) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
          await tester.sendKeyEvent(key);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
          await tester.pump();
        }
      }

      await selectAllAndCopy();
      expect(copied, 'Before\n\nTitle\n\nInside\n\nAfter');

      // Closed, the body is not built, so it is not copied.
      await tester.tap(findRichTextContaining('Title'));
      await tester.pump();
      await selectAllAndCopy();
      expect(copied, 'Before\n\nTitle\n\nAfter');
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  group('streaming', () {
    test('no update shows a raw details tag', () {
      final controller = ParserController();
      final text = '$_reply\n<details>\n<summary>Second</summary>\n\nMore\n'
          '</details>\n';
      for (var end = 1; end <= text.length; end++) {
        final snapshot =
            controller.parse(text.substring(0, end), streaming: true);
        void check(List<DetailsItem> items) {
          for (final item in items) {
            switch (item) {
              case DetailsBlockItem(:final node):
                final source = node.type == CmarkNodeType.htmlBlock
                    ? node.contentString
                    : node.firstChild?.contentString ?? '';
                expect(
                  source,
                  isNot(contains(RegExp('</?(det|sum)'))),
                  reason: text.substring(0, end),
                );
              case DetailsGroupItem():
                check(item.children);
            }
          }
        }

        check(groupDetails(snapshot.blocks));
      }
    });

    test('blocks in a section keep their cached widgets', () {
      final controller = ParserController();
      final cache = BlockRenderCache();
      const options = RenderOptions(selectable: true);
      List<BlockRenderResult> render(String text) =>
          const RenderPipeline().render(
            controller.parse(text, streaming: true),
            _theme,
            options,
            cache: cache,
          );
      const head = '<details><summary>T</summary>\n\nFirst\n\n';
      final a = render('${head}Sec');
      final b = render('${head}Second');
      final aBody = _bodyBlocks(a.single.widget);
      final bBody = _bodyBlocks(b.single.widget);
      expect(a.single.id, b.single.id);
      expect(identical(aBody.first, bBody.first), isTrue);
      expect(identical(aBody.last, bBody.last), isFalse);

      // Text after the section does not rebuild it.
      final closed = render('${head}Second\n\n</details>\n\nAfter\n');
      final more = render('${head}Second\n\n</details>\n\nAfter more\n');
      expect(identical(closed.first.widget, more.first.widget), isTrue);
    });

    testWidgets('an open section stays open while it streams and ends',
        (tester) async {
      final controller = ParserController();
      final cache = BlockRenderCache();
      Future<void> pump(String text, {bool streaming = true}) =>
          tester.pumpWidget(
            _app(
              _column(
                controller.parse(text, streaming: streaming),
                cache: cache,
              ),
            ),
          );
      const head = '<details><summary>T</summary>\n\n';
      await pump('${head}One');
      await tester.tap(findRichTextContaining('T'));
      await tester.pump();
      expect(findRichTextContaining('One'), findsOneWidget);
      await pump('${head}One\n\nTwo');
      await pump('${head}One\n\nTwo\n\n</details>\n\nAfter');
      await pump('${head}One\n\nTwo\n\n</details>\n\nAfter', streaming: false);
      expect(findRichTextContaining('Two'), findsOneWidget);
    });
  });
}

Iterable<CmarkNode> _children(CmarkNode node) sync* {
  for (var c = node.firstChild; c != null; c = c.next) {
    yield c;
  }
}

/// The block widgets in the body of a section widget from the renderer.
List<Widget> _bodyBlocks(Widget section) {
  final data = (section as dynamic).data as CmarkDetailsData;
  final column = data.body as Column;
  return [
    for (final child in column.children)
      if (child is KeyedSubtree) child.child,
  ];
}
