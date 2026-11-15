// Selection and copy in a code block: one Selectable for the whole block
// (docs/ADR_001_CODE_BLOCK_RENDER_OBJECT.md, D8, D9, I4).
import 'package:cmark_gfm_widget/cmark_gfm_widget.dart';
import 'package:cmark_gfm_widget/src/render/code_block_lines.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' hide SelectionArea;

void main() {
  String? copied;
  setUp(() {
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Widget harness(String markdown) {
    final snapshot = ParserController().parse(markdown);
    final theme = CmarkThemeData.fallback(ThemeData().textTheme);
    final widgets = const RenderPipeline().buildWidgets(
      snapshot,
      theme,
      RenderOptions(
        selectable: true,
        codeBlockWrapper: (child, _) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: child,
        ),
      ),
    );
    return MaterialApp(
      home: Scaffold(
        body: SelectionArea(
          child: SingleChildScrollView(
            child: SizedBox(
              width: 760,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: widgets,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> shortcut(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pump();
  }

  RenderCodeBlock block(WidgetTester tester) =>
      tester.renderObject<RenderCodeBlock>(find.byType(CodeBlockLines));

  // Global position of [column] on [line] of the block.
  Offset at(WidgetTester tester, int line, double x) {
    final render = block(tester);
    return render.localToGlobal(
      Offset(x, (line + 0.5) * render.lineHeight),
    );
  }

  Future<void> selectAllAndCopy(WidgetTester tester) async {
    await tester.tapAt(at(tester, 0, 2));
    await shortcut(tester, LogicalKeyboardKey.keyA);
    await shortcut(tester, LogicalKeyboardKey.keyC);
  }

  testWidgets('I4: select-all copies the code exactly', (tester) async {
    const code = 'first\n\n  indented\n\n\nemoji 😀 and e\u0301\n'
        'שלום עולם\nlast';
    await tester.pumpWidget(harness('```\n$code\n```'));
    await tester.pumpAndSettle();
    await selectAllAndCopy(tester);
    expect(copied, code);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('tabs copy as the spaces that are shown', (tester) async {
    await tester.pumpWidget(harness('```\na\tb\n```'));
    await tester.pumpAndSettle();
    await selectAllAndCopy(tester);
    expect(copied, 'a  b');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('text around a code block keeps its separators', (tester) async {
    await tester.pumpWidget(harness('Before.\n\n```\nx\n\ny\n```\n\nAfter.'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await shortcut(tester, LogicalKeyboardKey.keyA);
    await shortcut(tester, LogicalKeyboardKey.keyC);
    expect(copied, 'Before.\n\nx\n\ny\n\nAfter.');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('select-all and copy of a long block lay out no line',
      (tester) async {
    final code = List.generate(50000, (i) => 'line $i').join('\n');
    await tester.pumpWidget(harness('```\n$code\n```'));
    await tester.pumpAndSettle();
    await tester.tapAt(at(tester, 0, 2));
    await tester.pump(const Duration(seconds: 1));
    RenderCodeBlock.debugLineLayouts = 0;
    await shortcut(tester, LogicalKeyboardKey.keyA);
    await shortcut(tester, LogicalKeyboardKey.keyC);
    expect(copied, code);
    // Only the lines at the edges of the selection, for its handles.
    expect(RenderCodeBlock.debugLineLayouts, lessThanOrEqualTo(2));
  });

  testWidgets('a drag selects across lines', (tester) async {
    await tester.pumpWidget(
      harness('```\nalpha beta\ngamma delta\nepsilon\n```'),
    );
    await tester.pumpAndSettle();
    final render = block(tester);
    final advance = render.size.width / 'gamma delta'.length;
    final gesture = await tester.startGesture(
      at(tester, 0, 6.2 * advance),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(at(tester, 2, 3.2 * advance));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await shortcut(tester, LogicalKeyboardKey.keyC);
    expect(copied, 'beta\ngamma delta\neps');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a double click selects a word', (tester) async {
    await tester.pumpWidget(harness('```\nfinal value = 42;\n```'));
    await tester.pumpAndSettle();
    final render = block(tester);
    final advance = render.size.width / 'final value = 42;'.length;
    final position = at(tester, 0, 8.5 * advance);
    final gesture = await tester.startGesture(
      position,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.down(position);
    await gesture.up();
    await tester.pump();
    await shortcut(tester, LogicalKeyboardKey.keyC);
    expect(copied, 'value');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('keyboard extension moves by character, word and line',
      (tester) async {
    await tester.pumpWidget(harness('```\nab cd\nef\n```'));
    await tester.pumpAndSettle();
    final render = block(tester);
    String? selected() => render.getSelectedContent()?.plainText;
    render.dispatchSelectionEvent(
      SelectionEdgeUpdateEvent.forStart(globalPosition: at(tester, 0, 0)),
    );
    render.dispatchSelectionEvent(
      SelectionEdgeUpdateEvent.forEnd(globalPosition: at(tester, 0, 0)),
    );
    SelectionResult extend(TextGranularity granularity, bool forward) =>
        render.dispatchSelectionEvent(
          GranularlyExtendSelectionEvent(
            forward: forward,
            isEnd: true,
            granularity: granularity,
          ),
        );
    extend(TextGranularity.character, true);
    expect(selected(), 'a');
    extend(TextGranularity.word, true);
    expect(selected(), 'ab');
    extend(TextGranularity.line, true);
    expect(selected(), 'ab cd');
    extend(TextGranularity.character, true);
    expect(selected(), 'ab cd\n');
    extend(TextGranularity.line, true);
    expect(selected(), 'ab cd\nef');
    expect(extend(TextGranularity.character, true), SelectionResult.next);
    expect(extend(TextGranularity.document, false), SelectionResult.end);
    expect(render.getSelectedContent(), isNull);
  });

  testWidgets('selection of a block scrolled far down paints on screen',
      (tester) async {
    final code = List.generate(5000, (i) => 'line $i').join('\n');
    await tester.pumpWidget(harness('```\n$code\n```'));
    await tester.pumpAndSettle();
    final render = block(tester);
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    scrollable.position.jumpTo(3000 * render.lineHeight);
    await tester.pump();
    await tester.pump();
    final y = render.globalToLocal(const Offset(0, 100)).dy;
    final line = (y / render.lineHeight).floor();
    final gesture = await tester.startGesture(
      at(tester, line, 1),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(at(tester, line + 1, 1000));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await shortcut(tester, LogicalKeyboardKey.keyC);
    expect(copied, 'line $line\nline ${line + 1}');
    await tester.pump(const Duration(seconds: 1));
  });
}
