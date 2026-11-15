import 'package:cmark_gfm_widget/src/render/code_block_lines.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// Invariants of doc/ADR_001_CODE_BLOCK_RENDER_OBJECT.md.

const _style = TextStyle(fontFamily: 'monospace', fontSize: 14);

List<TextSpan> _lines(int count, {String Function(int)? text}) => [
      for (var i = 0; i < count; i++)
        TextSpan(
          style: _style,
          children: [
            TextSpan(text: text?.call(i) ?? 'final value$i = '),
            const TextSpan(
                text: '42;', style: TextStyle(color: Color(0xFFFF0000))),
          ],
        ),
    ];

Widget _scroll(List<TextSpan> lines, {ScrollController? controller}) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: SingleChildScrollView(
        controller: controller,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: CodeBlockLines(lines: lines, style: _style),
        ),
      ),
    );

RenderCodeBlock _render(WidgetTester tester) =>
    tester.renderObject<RenderCodeBlock>(find.byType(CodeBlockLines));

void main() {
  setUp(() => RenderCodeBlock.debugLineLayouts = 0);

  testWidgets('I1: layouts do not grow with the line count', (tester) async {
    await tester.pumpWidget(_scroll(_lines(50)));
    final small = RenderCodeBlock.debugLineLayouts;

    RenderCodeBlock.debugLineLayouts = 0;
    await tester.pumpWidget(_scroll(_lines(50000)));
    final large = RenderCodeBlock.debugLineLayouts;

    final render = _render(tester);
    // 600 px viewport: visible lines plus one viewport above and below.
    final bound = (3 * 600 / render.lineHeight).ceil() + 2;
    expect(small, 50);
    expect(large, lessThanOrEqualTo(bound));
  });

  testWidgets('I2: an appended line lays out one line', (tester) async {
    final lines = _lines(20);
    await tester.pumpWidget(_scroll(lines));
    RenderCodeBlock.debugLineLayouts = 0;
    final appended = [...lines, ..._lines(1, text: (_) => 'x')];
    await tester.pumpWidget(_scroll(appended));
    expect(RenderCodeBlock.debugLineLayouts, 1);
  });

  testWidgets('I3: size is exact and does not change on scroll',
      (tester) async {
    final controller = ScrollController();
    final lines = _lines(10000, text: (i) => i == 7000 ? 'w' * 300 : 'a');
    await tester.pumpWidget(_scroll(lines, controller: controller));
    final render = _render(tester);
    final size = render.size;
    expect(size.height, 10000 * render.lineHeight);
    final longest = TextPainter(
      text: lines[7000],
      textDirection: TextDirection.ltr,
    )..layout();
    expect(size.width, closeTo(longest.width, 1));
    longest.dispose();

    controller.jumpTo(controller.position.maxScrollExtent / 2);
    await tester.pump();
    await tester.pump();
    expect(render.size, size);
  });

  testWidgets('scrolling paints lines that were not on screen', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(_scroll(_lines(50000), controller: controller));
    final render = _render(tester);
    RenderCodeBlock.debugLineLayouts = 0;
    controller.jumpTo(25000 * render.lineHeight);
    await tester.pump();
    // The post-frame check sees the visible rect left the painted rect.
    await tester.pump();
    expect(RenderCodeBlock.debugLineLayouts, greaterThan(0));
    expect(
      RenderCodeBlock.debugLineLayouts,
      lessThanOrEqualTo((3 * 600 / render.lineHeight).ceil() + 2),
    );
  });

  testWidgets('I6: hit test is constant in the line count', (tester) async {
    await tester.pumpWidget(_scroll(_lines(50000)));
    final result = HitTestResult();
    tester.binding
        .hitTestInView(result, const Offset(5, 5), tester.view.viewId);
    expect(
      result.path.map((e) => e.target).whereType<RenderCodeBlock>(),
      hasLength(1),
    );
    // A leaf: no child is visited.
    expect(_render(tester).debugDescribeChildren(), isEmpty);
  });

  testWidgets('a long ASCII line is laid out only in visible pieces',
      (tester) async {
    final lines = _lines(3, text: (i) => i == 1 ? 'x' * 40000 : 'a');
    await tester.pumpWidget(_scroll(lines));
    final render = _render(tester);
    // Width from the advance, without layout of the long line.
    final probe = TextPainter(
      text: const TextSpan(text: 'xxxxxxxxxx', style: _style),
      textDirection: TextDirection.ltr,
    )..layout();
    expect(render.size.width, closeTo(probe.width * 4000 + _redWidth(), 2));
    probe.dispose();
    // Lines 0 and 2, plus the pieces of line 1 within 3 x 800 px.
    final pieceWidth =
        render.size.width / 40000 * RenderCodeBlock.linePieceLength;
    expect(
      RenderCodeBlock.debugLineLayouts,
      lessThanOrEqualTo(2 + (3 * 800 / pieceWidth).ceil() + 1),
    );
  });

  testWidgets('non-ASCII lines get a real width', (tester) async {
    final lines = [
      const TextSpan(text: 'ab', style: _style),
      const TextSpan(text: '漢字漢字漢字', style: _style),
    ];
    await tester.pumpWidget(_scroll(lines));
    final painter = TextPainter(
      text: lines[1],
      textDirection: TextDirection.ltr,
    )..layout();
    expect(_render(tester).size.width, closeTo(painter.width, 1));
    painter.dispose();
  });

  testWidgets('lines with fallback glyphs keep the line height',
      (tester) async {
    await tester.pumpWidget(
      _scroll(const [
        TextSpan(text: 'a', style: _style),
        TextSpan(text: 'a 😀', style: _style),
      ]),
    );
    final render = _render(tester);
    expect(render.size.height, 2 * render.lineHeight);
  });

  testWidgets('D11: semantics give the painted lines and follow scrolling',
      (tester) async {
    final handle = tester.ensureSemantics();
    final controller = ScrollController();
    await tester.pumpWidget(
      _scroll(_lines(5000, text: (i) => 'row$i '), controller: controller),
    );
    String label() => tester
        .getSemantics(find.byType(CodeBlockLines))
        .getSemanticsData()
        .label;
    expect(label(), startsWith('row0 42;\nrow1 42;'));
    expect(label(), isNot(contains('row4999 ')));
    final render = _render(tester);
    controller.jumpTo(4000 * render.lineHeight);
    await tester.pump();
    await tester.pump();
    expect(label(), contains('row4000 42;'));
    expect(label(), isNot(contains('row0 ')));
    handle.dispose();
  });
}

double _redWidth() {
  final painter = TextPainter(
    text: const TextSpan(text: '42;', style: _style),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}
