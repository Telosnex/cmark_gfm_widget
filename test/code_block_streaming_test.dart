import 'package:cmark_gfm_widget/cmark_gfm_widget.dart';
import 'package:cmark_gfm_widget/src/render/code_block_lines.dart';
import 'package:material_ui/material_ui.dart' hide SelectionArea;
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_snap_fork/material.dart' as ps;

void main() {
  Widget wrap(String markdown) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CmarkMarkdownColumn(data: markdown),
        ),
      ),
    );
  }

  Finder codeBlockFinder() => find.byWidgetPredicate(
        (widget) => widget is RepaintBoundary && widget.child is ps.Container,
      );

  List<TextSpan> codeLines(WidgetTester tester) =>
      tester.widget<CodeBlockLines>(find.byType(CodeBlockLines)).lines;

  testWidgets('code block has one span per line', (tester) async {
    await tester.pumpWidget(wrap('```dart\nfinal a = 1;\nfinal b = 2;\n```'));
    expect(codeLines(tester), hasLength(2));
  });

  testWidgets('blank lines occupy the same height as text lines',
      (tester) async {
    await tester.pumpWidget(wrap('```\na\n\nb\n```'));
    final withBlank = tester.getSize(codeBlockFinder().first);

    await tester.pumpWidget(wrap('```\na\nx\nb\n```'));
    final withoutBlank = tester.getSize(codeBlockFinder().first);

    expect(withBlank.height, withoutBlank.height);
  });

  testWidgets('streaming appends keep earlier line spans identical',
      (tester) async {
    await tester.pumpWidget(wrap('```dart\nfinal a = 1;\nfinal b = 2;\n```'));
    final before = codeLines(tester);
    expect(before, hasLength(2));

    // Simulate a streamed chunk that completes line 2 and starts line 3.
    await tester.pumpWidget(
      wrap('```dart\nfinal a = 1;\nfinal b = 2;\nfinal c =\n```'),
    );
    final after = codeLines(tester);
    expect(after, hasLength(3));

    // Line 1 completed before the first frame: an identical span instance
    // means RenderCodeBlock reuses its width and its layout.
    expect(identical(before[0], after[0]), isTrue);
  });
}
