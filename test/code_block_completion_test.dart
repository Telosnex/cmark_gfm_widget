import 'dart:async';

import 'package:cmark_gfm_dart/cmark_gfm_dart.dart';
import 'package:cmark_gfm_widget/cmark_gfm_widget.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pixel_snap_fork/material.dart' as ps;

void main() {
  test('open code stays provisional at newline and CRLF boundaries', () {
    final controller = ParserController();
    for (final source in [
      '```js\nhello',
      '```js\nhello\n',
      '```js\nhello\n\n',
      '```js\r\nhello\r\n',
      '```js\rhello\r',
      '> ```js\n> hello\n',
      '    hello\n',
    ]) {
      final snapshot = controller.parse(source, streaming: true);
      var code = snapshot.root.firstChild!;
      if (code.type == CmarkNodeType.blockQuote) code = code.firstChild!;
      expect(snapshot.isCodeBlockComplete(code), isFalse, reason: source);
      expect(snapshot.isBlockComplete(snapshot.root.firstChild!), isFalse);
      final finished = controller.parse(source);
      expect(finished.isBlockComplete(finished.root.firstChild!), isTrue);
    }
  });

  test('fences and closed containers complete before document EOF', () {
    final controller = ParserController();
    for (final source in [
      '```js\nhello\n```',
      '```js\nhello\n```\n',
      '```js\r\nhello\r\n```\r\n',
      '> ```js\n> hello\n> ```\n',
      '> ```js\n> hello\n\noutside',
      '    hello\n\noutside',
    ]) {
      final snapshot = controller.parse(source, streaming: true);
      expect(snapshot.isBlockComplete(snapshot.root.firstChild!), isTrue,
          reason: source);
    }
  });

  testWidgets('finish invalidates retained block and corrects lookahead colors',
      (tester) async {
    final controller = ParserController();
    final cache = BlockRenderCache();
    const pipeline = RenderPipeline();
    final theme = CmarkThemeData.fallback(ThemeData().textTheme).copyWith(
      codeHighlightTheme: const CodeHighlightTheme(theme: {
        'root': TextStyle(color: Color(0xFF111111)),
        'title': TextStyle(color: Color(0xFFFF0000)),
        'title.function': TextStyle(color: Color(0xFFFF0000)),
      }),
    );
    const source = '```js\nhello\n()\n';
    final provisional = pipeline.render(
      controller.parse(source, streaming: true),
      theme,
      const RenderOptions(),
      cache: cache,
    );
    await tester.pumpWidget(
        MaterialApp(home: Column(children: [provisional.single.widget])));
    final before =
        tester.widgetList<ps.RichText>(find.byType(ps.RichText)).first.text;
    final finished = pipeline.render(
      controller.parse(source),
      theme,
      const RenderOptions(),
      cache: cache,
    );
    expect(
        identical(provisional.single.widget, finished.single.widget), isFalse);
    await tester.pumpWidget(
        MaterialApp(home: Column(children: [finished.single.widget])));
    final after =
        tester.widgetList<ps.RichText>(find.byType(ps.RichText)).first.text;
    expect(after.toPlainText(), before.toPlainText());
    expect(after.toStringDeep(), isNot(before.toStringDeep()));
  });
  testWidgets('large final correction rebuilds mounted cached code only',
      (tester) async {
    final controller = ParserController();
    final pending = <(String, String, Completer<HighlightScopeRuns>)>[];
    final theme = CmarkThemeData.fallback(ThemeData().textTheme).copyWith(
      codeHighlightTheme: CodeHighlightTheme(
        theme: const {
          'root': TextStyle(color: Color(0xFF222222)),
          'title': TextStyle(color: Color(0xFFFF0000)),
          'title.function': TextStyle(color: Color(0xFFFF0000)),
        },
        highlightOffload: (code, language) {
          final completion = Completer<HighlightScopeRuns>();
          pending.add((code, language, completion));
          return completion.future;
        },
      ),
    );
    final source = '```js\nhello\n()\n${'// padding\n' * 500}';
    final cache = BlockRenderCache();
    const pipeline = RenderPipeline();
    final start = pipeline.render(
      controller.parse('```js\nhello\n(', streaming: true),
      theme,
      const RenderOptions(),
      cache: cache,
    );
    await tester.pumpWidget(MaterialApp(
      home: SingleChildScrollView(child: start.single.widget),
    ));
    final results = pipeline.render(
      controller.parse(source),
      theme,
      const RenderOptions(),
      cache: cache,
    );
    await tester.pumpWidget(MaterialApp(
      home: SingleChildScrollView(child: results.single.widget),
    ));
    String firstLine() => tester
        .widgetList<ps.RichText>(find.byType(ps.RichText))
        .first
        .text
        .toStringDeep();
    final provisional = firstLine();
    // Hold the correction until provisional spans have been observed. Web idle
    // tasks can otherwise finish during pumpWidget, unlike native isolates.
    expect(pending, hasLength(1));
    final (code, language, completion) = pending.single;
    completion.complete(highlightScopeRuns(code, language));
    await tester.pump();
    expect(firstLine(), isNot(provisional));
    // No parent/pipeline render was needed to replace the provisional spans.
    expect(tester.takeException(), isNull);

    final other = pipeline.render(
      controller.parse('$source// different request\n'),
      theme,
      const RenderOptions(),
    );
    await tester.pumpWidget(MaterialApp(
      home: SingleChildScrollView(child: other.single.widget),
    ));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(pending, hasLength(2));
    final (otherCode, otherLanguage, otherCompletion) = pending.last;
    otherCompletion.complete(highlightScopeRuns(otherCode, otherLanguage));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
