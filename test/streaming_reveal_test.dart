// The streaming reveal: per-character fades that never restart, and the
// column rules for which blocks animate.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cmark_gfm_widget/cmark_gfm_widget.dart';
import 'package:cmark_gfm_widget/src/widgets/streaming_reveal.dart'
    show debugCmarkRevealPaint;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _sentence = 'When an assistant streams a reply, the client receives '
    'many small chunks per second. Each chunk is usually a few characters: '
    'a word, part of a word, or punctuation.';

const _frame = Duration(milliseconds: 16);

late CmarkThemeData _theme;

void main() {
  setUpAll(() async {
    final bytes =
        File('test/fonts/JetBrainsMono-Regular.ttf').readAsBytesSync();
    final loader = FontLoader('Mono')
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    final base = CmarkThemeData.fallback(Typography.englishLike2021);
    _theme = base.copyWith(
      paragraphTextStyle: base.paragraphTextStyle.copyWith(
        fontFamily: 'Mono',
        fontSize: 16,
        color: const Color(0xFF000000),
      ),
    );
  });

  tearDown(() => debugCmarkRevealPaint = null);

  group('CmarkStreamingReveal', () {
    testWidgets('head and tail only move forward; tail trails head',
        (tester) async {
      final log = <(double, double)>[];
      debugCmarkRevealPaint = (h, t, _) => log.add((h, t));
      await tester.pumpWidget(_doc('When', streaming: true));
      for (final t in _chunks()) {
        await tester.pumpWidget(_doc(t, streaming: true));
        await _pumpFrames(tester, 4);
      }
      await _pumpFrames(tester, 60);
      expect(log, isNotEmpty);
      for (var i = 1; i < log.length; i++) {
        expect(log[i].$1, greaterThanOrEqualTo(log[i - 1].$1));
        expect(log[i].$2, greaterThanOrEqualTo(log[i - 1].$2 - 1e-9));
        expect(log[i].$2, lessThanOrEqualTo(log[i].$1));
      }
    });

    testWidgets('shown text never gets dimmer when more text arrives',
        (tester) async {
      // One line, so no word moves to the next line: that is layout, not the
      // fade.
      const w = 2000.0;
      tester.view
        ..physicalSize = const Size(w, 400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        _doc('When an', streaming: true, shotKey: key, width: w),
      );
      await _pumpFrames(tester, 60);
      var previous = await _shot(tester, key);
      var frames = 0;
      for (final t in _chunks().where((c) => c.length > 'When an'.length)) {
        await tester.pumpWidget(
          _doc(t, streaming: true, shotKey: key, width: w),
        );
        // A long pause after "characte" covers the end of a fade.
        final pause = t.endsWith('characte') ? 30 : 3;
        for (var i = 0; i < pause; i++) {
          final now = await _shot(tester, key);
          frames++;
          // A pixel column where two glyphs meet has parts of both, so allow
          // a seam up to 2 px wide. The bug this guards against ("woodchuck"
          // fading again when "chuck" arrived) dimmed whole words.
          final columns = <int>{};
          for (var p = 3; p < now.length; p += 4) {
            if (previous[p] - now[p] > 2) columns.add((p ~/ 4) % w.toInt());
          }
          if (columns.isNotEmpty) {
            final lo = columns.reduce((a, b) => a < b ? a : b);
            final hi = columns.reduce((a, b) => a > b ? a : b);
            expect(hi - lo, lessThanOrEqualTo(1),
                reason: '"$t" frame $i: shown ink dimmed in columns $lo..$hi');
          }
          previous = now;
          await tester.pump(_frame);
        }
      }
      expect(frames, greaterThan(100));
    });

    testWidgets('a chunk fades in gradually, with no pop at the end',
        (tester) async {
      final key = GlobalKey();
      const before = 'Each chunk is usually a few ';
      await tester.pumpWidget(_doc(before, streaming: true, shotKey: key));
      await _pumpFrames(tester, 60);
      final base = await _shot(tester, key);
      await tester.pumpWidget(
        _doc('${before}characte', streaming: true, shotKey: key),
      );
      final steps = <int>[];
      var previous = _newInk(await _shot(tester, key), base);
      for (var i = 0; i < 40; i++) {
        await tester.pump(_frame);
        final ink = _newInk(await _shot(tester, key), base);
        steps.add(ink - previous);
        previous = ink;
      }
      final total = steps.fold<int>(0, (a, b) => a + b);
      expect(total, greaterThan(0));
      for (final s in steps) {
        expect(s, greaterThanOrEqualTo(0), reason: 'steps: $steps');
        expect(s, lessThan(total * 0.15), reason: 'steps: $steps');
      }
      expect(steps.skip(30).every((s) => s == 0), isTrue,
          reason: 'the fade ends within about 0.5 s; steps: $steps');
    });

    testWidgets('a reveal in progress finishes after streaming ends',
        (tester) async {
      final log = <(double, double, int)>[];
      debugCmarkRevealPaint = (h, t, n) => log.add((h, t, n));
      await tester.pumpWidget(_doc('Hello', streaming: true));
      await tester.pumpWidget(_doc('Hello there, world', streaming: true));
      await tester.pump(_frame);
      await tester.pumpWidget(_doc('Hello there, world', streaming: false));
      expect(log.last.$2, lessThan(log.last.$3), reason: 'still fading');
      await _pumpFrames(tester, 60);
      expect(log.last.$2, log.last.$3.toDouble());
      expect(tester.binding.hasScheduledFrame, isFalse,
          reason: 'the ticker stops when the fade ends');
    });

    testWidgets('text added while not streaming is shown at once',
        (tester) async {
      final log = <(double, double, int)>[];
      await tester.pumpWidget(_doc('Hello', streaming: true));
      await _pumpFrames(tester, 60);
      await tester.pumpWidget(_doc('Hello', streaming: false));
      debugCmarkRevealPaint = (h, t, n) => log.add((h, t, n));
      await tester.pumpWidget(_doc('Hello there', streaming: false));
      expect(log.single.$2, log.single.$3.toDouble());
    });

    testWidgets('a whole block fades in as one unit', (tester) async {
      final log = <(double, double, int)>[];
      await tester.pumpWidget(_doc('Intro', streaming: true));
      await _pumpFrames(tester, 60);
      debugCmarkRevealPaint = (h, t, n) => log.add((h, t, n));
      await tester.pumpWidget(
        _doc('Intro\n\n| a | b |\n| - | - |\n| 1 | 2 |', streaming: true),
      );
      await tester.pump(_frame);
      await tester.pump(_frame);
      final layers = _layersOf<OpacityLayer>(tester);
      expect(layers, isNotEmpty);
      expect(layers.last.alpha, inExclusiveRange(0, 255));
      expect(log.where((e) => e.$3 == 1), isNotEmpty);
    });
  });

  group('CmarkBlockColumn', () {
    testWidgets('a column built while not streaming has no reveals',
        (tester) async {
      await tester.pumpWidget(_doc('One\n\nTwo', streaming: false));
      expect(find.byType(CmarkStreamingReveal), findsNothing);
    });

    testWidgets(
        'blocks there when the reveals are added are shown at once, '
        'except the last', (tester) async {
      final log = <(double, double, int)>[];
      debugCmarkRevealPaint = (h, t, n) => log.add((h, t, n));
      await tester.pumpWidget(
        _doc('First block.\n\nSecond block.\n\nThird', streaming: true),
      );
      expect(find.byType(CmarkStreamingReveal), findsNWidgets(3));
      // One paint per block on the first frame, in order.
      expect(log, hasLength(3));
      expect(log[0].$2, log[0].$3.toDouble());
      expect(log[1].$2, log[1].$3.toDouble());
      expect(log[2].$1, 0, reason: 'the last block starts hidden');
    });

    testWidgets('a block added later fades in, and the reveal keeps state',
        (tester) async {
      await tester.pumpWidget(_doc('First block.', streaming: true));
      await _pumpFrames(tester, 60);
      final firstState = tester.state(find.byType(CmarkStreamingReveal));
      final log = <(double, double, int)>[];
      debugCmarkRevealPaint = (h, t, n) => log.add((h, t, n));
      await tester.pumpWidget(
        _doc('First block.\n\nSecond', streaming: true),
      );
      expect(
        tester.state(find.byType(CmarkStreamingReveal).first),
        same(firstState),
      );
      // The new block's reveal paints after the first one's.
      expect(log.last.$1, 0);
      expect(log.last.$3, 'Second'.length);
    });

    testWidgets('reveals stay after streaming ends', (tester) async {
      await tester.pumpWidget(_doc('One\n\nTwo', streaming: true));
      await tester.pumpWidget(_doc('One\n\nTwo', streaming: false));
      expect(find.byType(CmarkStreamingReveal), findsNWidgets(2));
    });

    testWidgets('BlockRenderResult gives the node, for the reveal style',
        (tester) async {
      final results = const RenderPipeline().render(
        ParserController().parse('Hi\n\n---\n\n| a |\n| - |\n| 1 |'),
        _theme,
        const RenderOptions(),
      );
      expect(
        [for (final r in results) CmarkRevealStyle.forNode(r.node)],
        [
          CmarkRevealStyle.lines,
          CmarkRevealStyle.whole,
          CmarkRevealStyle.whole,
        ],
      );
    });
  });
}

List<String> _chunks() {
  final out = <String>{};
  var i = 0;
  var k = 0;
  while (i < _sentence.length) {
    i = (i + 2 + (k++ * 7919) % 5).clamp(0, _sentence.length);
    out.add(_sentence.substring(0, i));
  }
  out.add(_sentence.substring(0, _sentence.indexOf('characte') + 8));
  return out.toList()..sort((a, b) => a.length.compareTo(b.length));
}

Future<void> _pumpFrames(WidgetTester tester, int n) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(_frame);
  }
}

/// Sum of alpha over pixels that were clear in [base].
int _newInk(Uint8List now, Uint8List base) {
  var sum = 0;
  for (var p = 3; p < now.length; p += 4) {
    if (base[p] == 0) sum += now[p];
  }
  return sum;
}

Future<Uint8List> _shot(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late Uint8List bytes;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
        .buffer
        .asUint8List();
  });
  return bytes;
}

List<T> _layersOf<T extends Layer>(WidgetTester tester) {
  final out = <T>[];
  void visit(Layer? layer) {
    while (layer != null) {
      if (layer is T) out.add(layer);
      if (layer is ContainerLayer) visit(layer.firstChild);
      layer = layer.nextSibling;
    }
  }

  visit(tester.binding.renderViews.first.debugLayer);
  return out;
}

Widget _doc(
  String text, {
  required bool streaming,
  GlobalKey? shotKey,
  double width = 600,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: RepaintBoundary(
        key: shotKey,
        // A fixed size, so snapshots of different frames line up.
        child: SizedBox(
          width: width,
          height: 200,
          child: _StreamedDoc(text: text, streaming: streaming),
        ),
      ),
    ),
  );
}

/// A streamed document as an app shows it: one cache for the whole stream,
/// so blocks that did not change keep their widgets.
class _StreamedDoc extends StatefulWidget {
  const _StreamedDoc({required this.text, required this.streaming});

  final String text;
  final bool streaming;

  @override
  State<_StreamedDoc> createState() => _StreamedDocState();
}

class _StreamedDocState extends State<_StreamedDoc> {
  final _controller = ParserController();
  final _cache = BlockRenderCache();

  @override
  Widget build(BuildContext context) {
    final results = const RenderPipeline().render(
      _controller.parse(widget.text),
      _theme,
      const RenderOptions(repaintBoundaries: true),
      cache: _cache,
    );
    return CmarkBlockColumn(
      theme: _theme,
      reveal: CmarkRevealOptions(
        streaming: widget.streaming,
        styles: [for (final r in results) CmarkRevealStyle.forNode(r.node)],
      ),
      children: [for (final r in results) r.widget],
    );
  }
}
