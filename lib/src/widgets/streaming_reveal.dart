import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cmark_gfm_dart/cmark_gfm_dart.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// How a [CmarkStreamingReveal] shows new content.
enum CmarkRevealStyle {
  /// Characters fade in one after another, in reading order. Lines below the
  /// newest shown line are hidden.
  lines,

  /// The whole block fades in at once. For blocks whose parts are not in
  /// reading order, such as tables, or that have no text, such as rules and
  /// block math.
  whole;

  /// The style for a top-level block of type [node].
  ///
  /// Tables, rules, block math and custom blocks use [whole]. Other blocks,
  /// and a null [node], use [lines].
  static CmarkRevealStyle forNode(CmarkNode? node) {
    final type = node?.type;
    if (type == CmarkNodeType.table ||
        type == CmarkNodeType.thematicBreak ||
        type == CmarkNodeType.mathBlock ||
        type == CmarkNodeType.customBlock) {
      return whole;
    }
    return lines;
  }
}

/// Settings for revealing streamed blocks in a `CmarkBlockColumn`.
@immutable
class CmarkRevealOptions {
  const CmarkRevealOptions({
    required this.streaming,
    this.styles = const [],
    this.fadeDuration = CmarkStreamingReveal.defaultFadeDuration,
    this.catchUpDuration = CmarkStreamingReveal.defaultCatchUpDuration,
    this.minCharactersPerSecond =
        CmarkStreamingReveal.defaultMinCharactersPerSecond,
  });

  /// Whether the document is streaming now. See
  /// [CmarkStreamingReveal.streaming].
  final bool streaming;

  /// The style of each child, by index. A child without an entry uses
  /// [CmarkRevealStyle.lines]. See [CmarkRevealStyle.forNode].
  final List<CmarkRevealStyle> styles;

  /// See [CmarkStreamingReveal.fadeDuration].
  final Duration fadeDuration;

  /// See [CmarkStreamingReveal.catchUpDuration].
  final Duration catchUpDuration;

  /// See [CmarkStreamingReveal.minCharactersPerSecond].
  final double minCharactersPerSecond;

  /// The style for the child at [index].
  CmarkRevealStyle styleAt(int index) =>
      index < styles.length ? styles[index] : CmarkRevealStyle.lines;
}

/// Fades in the content that is added to [child] while a document streams.
///
/// Put one around each top-level block. The reveal does not change the
/// block's widgets: after layout it finds the text of the block, and paint
/// hides the text that is not revealed yet. A reveal position follows the
/// end of the text, and each character fades in over [fadeDuration] after
/// the position passes it. Thus a chunk that ends in the middle of a word
/// does not restart the fade of that word, and shown text never gets dimmer.
///
/// Per animation frame, the reveal only paints: it does not build or lay out
/// the block. When all text is opaque, it paints [child] with no extra
/// layers.
///
/// The reveal keeps its state while [child] changes, so give it a key or a
/// position that stays the same while a block grows. Do not key it by
/// content.
class CmarkStreamingReveal extends StatefulWidget {
  const CmarkStreamingReveal({
    super.key,
    required this.streaming,
    required this.child,
    this.animateIn = true,
    this.style = CmarkRevealStyle.lines,
    this.fadeDuration = defaultFadeDuration,
    this.catchUpDuration = defaultCatchUpDuration,
    this.minCharactersPerSecond = defaultMinCharactersPerSecond,
  });

  static const defaultFadeDuration = Duration(milliseconds: 280);
  static const defaultCatchUpDuration = Duration(milliseconds: 180);
  static const defaultMinCharactersPerSecond = 90.0;

  /// Whether the document is streaming now.
  ///
  /// Content that is added while this is false is shown at once. A reveal
  /// that is in progress when this becomes false finishes, at twice the
  /// speed.
  final bool streaming;

  /// Whether the content that [child] has when the reveal is first laid out
  /// is revealed. If false, that content is shown at once. Only the first
  /// value is used.
  final bool animateIn;

  /// How new content appears.
  final CmarkRevealStyle style;

  /// How long one character, or a [CmarkRevealStyle.whole] block, takes to
  /// go from clear to opaque.
  final Duration fadeDuration;

  /// The reveal position closes its distance to the end of the text in about
  /// this time. This makes bursty chunks appear at an even speed.
  final Duration catchUpDuration;

  /// The lowest speed of the reveal position.
  final double minCharactersPerSecond;

  final Widget child;

  @override
  State<CmarkStreamingReveal> createState() => _CmarkStreamingRevealState();
}

/// Called on each paint of a reveal with its position, the position before
/// which all text is opaque, and the text length.
@visibleForTesting
void Function(double head, double tail, int target)? debugCmarkRevealPaint;

double _seconds(Duration d) => d.inMicroseconds / 1e6;

/// The current frame's time. Ticks, layout and paint in one frame then agree
/// on "now", and the reveal follows test time.
double _now() => _seconds(SchedulerBinding.instance.currentFrameTimeStamp);

class _CmarkStreamingRevealState extends State<CmarkStreamingReveal>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _RevealModel _model = _RevealModel();
  double _lastTick = 0;

  @override
  void initState() {
    super.initState();
    _model
      ..snapNextLayout = !widget.animateIn || !widget.streaming
      ..onNeedsTicking = _ensureTicking;
    _sync();
  }

  @override
  void didUpdateWidget(CmarkStreamingReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    _model
      ..streaming = widget.streaming
      ..fadeSeconds = math.max(1e-3, _seconds(widget.fadeDuration));
  }

  void _ensureTicking() {
    if (!_ticker.isActive && mounted) {
      _lastTick = _now();
      _ticker.start();
    }
  }

  void _tick(Duration _) {
    final now = _now();
    final dt = (now - _lastTick).clamp(0.0, 0.1);
    _lastTick = now;
    final m = _model;
    // Record the position at the last tick, so the history shows it standing
    // still until then, not moving since the last sample.
    m.record(now - dt);
    final backlog = m.target - m.head;
    if (backlog > 0) {
      var catchUp = math.max(1e-3, _seconds(widget.catchUpDuration));
      if (!widget.streaming) catchUp /= 2;
      final speed = math.max(widget.minCharactersPerSecond, backlog / catchUp);
      m.head = math.min(m.target.toDouble(), m.head + speed * dt);
    }
    m.record(now);
    if (m.tailAt(now) >= m.target) _ticker.stop();
    m.notifyListeners();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _Reveal(model: _model, style: widget.style, child: widget.child);
  }
}

/// The reveal position over time.
///
/// Positions are in characters of the block's text: the text of each
/// [RenderParagraph] in it, in paint order. A [CmarkRevealStyle.whole] block
/// has one character.
class _RevealModel extends ChangeNotifier {
  /// The reveal position. Text at or after it is not shown.
  double head = 0;

  /// The length of the block's text at the last layout.
  int target = 0;

  bool streaming = true;
  bool snapNextLayout = false;
  double fadeSeconds = 0.28;
  VoidCallback? onNeedsTicking;

  /// (time, head) samples, oldest first. One sample at or before
  /// now - fadeSeconds is kept for interpolation.
  final Queue<(double, double)> _history = Queue()..add((-1e9, 0));

  void record(double now) {
    final last = _history.last;
    if (now <= last.$1) return;
    if (last.$2 != head || now - last.$1 > 0.05) {
      _history.add((now, head));
    }
    final horizon = now - fadeSeconds;
    while (_history.length > 1 && _history.elementAt(1).$1 <= horizon) {
      _history.removeFirst();
    }
  }

  /// The position the head had fadeSeconds before [now]. Text before it is
  /// opaque.
  double tailAt(double now) {
    final t = now - fadeSeconds;
    (double, double)? prev;
    for (final s in _history) {
      if (s.$1 > t) {
        if (prev == null) return s.$2;
        final span = s.$1 - prev.$1;
        final k = span <= 0 ? 1.0 : ((t - prev.$1) / span).clamp(0.0, 1.0);
        return prev.$2 + (s.$2 - prev.$2) * k;
      }
      prev = s;
    }
    return head;
  }

  /// The alpha of the text at [pos]: the time since the head passed it, as a
  /// fraction of fadeSeconds.
  double alphaAt(double pos, double now) {
    if (pos >= head) return 0;
    (double, double)? prev;
    for (final s in _history) {
      if (s.$2 > pos) {
        if (prev == null) return 1;
        final span = s.$2 - prev.$2;
        final k = span <= 0 ? 1.0 : ((pos - prev.$2) / span).clamp(0.0, 1.0);
        final passed = prev.$1 + (s.$1 - prev.$1) * k;
        return ((now - passed) / fadeSeconds).clamp(0.0, 1.0);
      }
      prev = s;
    }
    if (prev == null) return 1;
    return ((now - prev.$1) / fadeSeconds).clamp(0.0, 1.0);
  }

  /// Shows all text before [value] at once.
  void snapTo(double value) {
    head = value;
    _history
      ..clear()
      ..add((-1e9, value));
  }

  @override
  // Called by the reveal state, which is not a subclass.
  // ignore: unnecessary_overrides
  void notifyListeners() => super.notifyListeners();
}

class _Reveal extends SingleChildRenderObjectWidget {
  const _Reveal({required this.model, required this.style, super.child});

  final _RevealModel model;
  final CmarkRevealStyle style;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderReveal(model, style);

  @override
  void updateRenderObject(BuildContext context, _RenderReveal renderObject) {
    renderObject
      ..model = model
      ..style = style;
  }
}

class _Para {
  _Para(this.paragraph, this.start, this.length);

  final RenderParagraph paragraph;
  final int start;
  final int length;
}

/// The fade on one line, in the reveal's coordinates.
class _Band {
  _Band(this.rect, this.xs, this.alphas, this.leftAlpha);

  final Rect rect;

  /// Increasing x positions and the alpha at each. Right of the last x, the
  /// line is clear.
  final List<double> xs;
  final List<double> alphas;

  /// The alpha left of xs.first: earlier text on the same line.
  final double leftAlpha;
}

class _RenderReveal extends RenderProxyBox {
  _RenderReveal(this._model, this._style);

  /// More lines than this in the fade (a very large chunk) show the oldest
  /// ones as opaque.
  static const _maxBands = 8;

  _RevealModel _model;
  CmarkRevealStyle _style;

  /// True when the block is revealed as one unit: [CmarkRevealStyle.whole],
  /// or a block with no text or with right-to-left text.
  bool _asWhole = false;
  List<_Para> _paras = const [];

  final LayerHandle<ClipRectLayer> _clip = LayerHandle<ClipRectLayer>();
  final List<LayerHandle<ShaderMaskLayer>> _bands = [
    for (var i = 0; i < _maxBands; i++) LayerHandle<ShaderMaskLayer>(),
  ];
  final LayerHandle<OpacityLayer> _opacity = LayerHandle<OpacityLayer>();

  set model(_RevealModel value) {
    if (identical(value, _model)) return;
    if (attached) {
      _model.removeListener(markNeedsPaint);
      value.addListener(markNeedsPaint);
    }
    _model = value;
    markNeedsLayout();
  }

  set style(CmarkRevealStyle value) {
    if (value == _style) return;
    _style = value;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _model.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _model.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void performLayout() {
    super.performLayout();
    final paras = <_Para>[];
    var total = 0;
    var rtl = false;
    void visit(RenderObject o) {
      if (o is RenderParagraph) {
        // A WidgetSpan is one placeholder character. The paragraph paints its
        // children, so they are not visited.
        final length = o.text.toPlainText(includeSemanticsLabels: false).length;
        paras.add(_Para(o, total, length));
        total += length;
        if (o.textDirection == TextDirection.rtl) rtl = true;
        return;
      }
      o.visitChildren(visit);
    }

    final c = child;
    if (c != null) visit(c);
    _asWhole = _style == CmarkRevealStyle.whole || paras.isEmpty || rtl;
    _paras = _asWhole ? const [] : paras;
    final target = _asWhole ? 1 : total;

    final m = _model;
    final now = _now();
    if (m.snapNextLayout || !m.streaming) {
      // Not streaming: show new content at once, unless a reveal is still
      // finishing.
      if (m.snapNextLayout || m.tailAt(now) >= m.target) {
        m.snapTo(target.toDouble());
      }
      m.snapNextLayout = false;
    }
    if (m.head > target) m.snapTo(target.toDouble());
    m.target = target;
    if (m.tailAt(now) < target) m.onNeedsTicking?.call();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final c = child;
    if (c == null) return;
    final m = _model;
    final head = m.head;
    final now = _now();
    final tail = math.min(m.tailAt(now), head);
    debugCmarkRevealPaint?.call(head, tail, m.target);
    if (tail >= m.target) {
      _clearLayers();
      context.paintChild(c, offset);
      return;
    }
    if (_asWhole) {
      _clip.layer = null;
      for (final b in _bands) {
        b.layer = null;
      }
      final alpha = m.alphaAt(0.5, now);
      _opacity.layer = context.pushOpacity(
        offset,
        (255 * alpha).round(),
        (ctx, o) => ctx.paintChild(c, o),
        oldLayer: _opacity.layer,
      );
      return;
    }
    _opacity.layer = null;
    _paintLines(context, offset, c, head, tail, now);
  }

  void _paintLines(
    PaintingContext context,
    Offset offset,
    RenderBox c,
    double head,
    double tail,
    double now,
  ) {
    final m = _model;
    final w = size.width;
    final bands = <_Band>[];
    double clipBottom = 0;

    for (final para in _paras) {
      final pStart = para.start.toDouble();
      final pEnd = (para.start + para.length).toDouble();
      final p = para.paragraph;
      if (!p.hasSize || !p.attached) continue;
      final toThis = p.getTransformTo(this);
      if (pEnd <= tail) {
        // Opaque paragraph.
        final bottom =
            MatrixUtils.transformPoint(toThis, Offset(0, p.size.height)).dy;
        clipBottom = math.max(clipBottom, bottom);
        continue;
      }
      if (pStart >= head) break;
      final from = math.max(tail, pStart) - pStart;
      final to = math.min(head, pEnd) - pStart;

      Offset caret(double local, {bool upstream = false}) {
        final i = local.floor().clamp(0, para.length);
        final frac = local - i;
        final a = p.getOffsetForCaret(
          TextPosition(
            offset: i,
            affinity: upstream && frac == 0
                ? TextAffinity.upstream
                : TextAffinity.downstream,
          ),
          Rect.zero,
        );
        if (frac == 0 || i >= para.length) return a;
        final b = p.getOffsetForCaret(
          TextPosition(offset: i + 1, affinity: TextAffinity.upstream),
          Rect.zero,
        );
        return (b.dy - a.dy).abs() < 0.5 ? Offset.lerp(a, b, frac)! : a;
      }

      final boxes = p.getBoxesForSelection(
        TextSelection(
          baseOffset: from.floor(),
          extentOffset: math.min(para.length, to.ceil()),
        ),
        // Full line height, so the clip does not cut descenders.
        boxHeightStyle: ui.BoxHeightStyle.max,
      );
      final lines = <Rect>[];
      for (final box in boxes) {
        final r = box.toRect();
        final i = lines.indexWhere(
          (l) => (l.top - r.top).abs() < 1 && (l.bottom - r.bottom).abs() < 1,
        );
        if (i < 0) {
          lines.add(r);
        } else {
          lines[i] = lines[i].expandToInclude(r);
        }
      }
      lines.sort((x, y) => x.top.compareTo(y.top));
      final cFrom = caret(from);
      final cTo = caret(to, upstream: true);
      if (lines.isEmpty) {
        // Nothing is fading on this line, but the text after the head on it
        // must stay hidden. The box of the character before the head gives
        // the full line height.
        final i = from.floor();
        final previous = i > 0
            ? p.getBoxesForSelection(
                TextSelection(baseOffset: i - 1, extentOffset: i),
                boxHeightStyle: ui.BoxHeightStyle.max,
              )
            : const <TextBox>[];
        final h = p.getFullHeightForCaret(TextPosition(offset: i));
        final line = previous.isEmpty
            ? Rect.fromLTWH(cFrom.dx, cFrom.dy, 0, h)
            : previous.last.toRect();
        lines.add(Rect.fromLTRB(cFrom.dx, line.top, cFrom.dx, line.bottom));
      }
      // Lines above the first fading line are opaque.
      clipBottom = math.max(
        clipBottom,
        MatrixUtils.transformPoint(toThis, Offset(0, lines.first.top)).dy,
      );
      for (var li = 0; li < lines.length; li++) {
        final l = lines[li];
        final first = li == 0;
        final last = li == lines.length - 1;
        final mid = l.center.dy;
        final lx0 = first ? math.max(l.left, cFrom.dx) : l.left;
        var lx1 =
            last && (cTo.dy - l.top).abs() < l.height / 2 ? cTo.dx : l.right;
        if (lx1 < lx0) lx1 = lx0;
        final pos0 = first
            ? from
            : p
                .getPositionForOffset(Offset(l.left + 0.5, mid))
                .offset
                .toDouble();
        final pos1 = last
            ? to
            : p.getPositionForOffset(Offset(l.right - 0.5, mid)).offset + 1.0;
        final tl = MatrixUtils.transformPoint(toThis, Offset(lx0, l.top));
        final br = MatrixUtils.transformPoint(toThis, Offset(lx1, l.bottom));
        final rect = Rect.fromLTRB(0, tl.dy, w, br.dy);
        // Sample the alpha of the characters along the line. The caret maps a
        // position to x. Keep the xs increasing.
        const samples = 8;
        final xs = <double>[];
        final alphas = <double>[];
        for (var k = 0; k <= samples; k++) {
          final pos = pos0 + (pos1 - pos0) * k / samples;
          var x = k == 0
              ? lx0
              : k == samples
                  ? lx1
                  : caret(pos).dx.clamp(lx0, lx1);
          x = MatrixUtils.transformPoint(toThis, Offset(x, l.top)).dx;
          if (xs.isNotEmpty && x < xs.last) x = xs.last;
          xs.add(x);
          alphas.add(m.alphaAt(pStart + math.min(pos, pos1 - 1e-6), now));
        }
        bands.add(_Band(rect, xs, alphas, first ? 1 : alphas.first));
        clipBottom = math.max(clipBottom, rect.bottom);
      }
    }
    final shown = bands.length > _maxBands
        ? bands.sublist(bands.length - _maxBands)
        : bands;

    Shader shaderFor(_Band b) {
      // A glyph's edge goes about a pixel past its caret position, so the
      // pixel column at a character boundary has parts of two glyphs. It
      // gets the alpha of the earlier glyph, so a shown glyph's edge does not
      // get dimmer when the next character arrives.
      const edge = 1.0;
      double f(double x) => (x / w).clamp(0.0, 1.0);
      Color white(double a) => Color.fromRGBO(255, 255, 255, a);
      final colors = <Color>[white(b.leftAlpha), white(b.leftAlpha)];
      final stops = <double>[f(b.xs.first), f(b.xs.first + edge)];
      for (var i = 0; i < b.xs.length; i++) {
        colors.add(white(b.alphas[i]));
        stops.add(math.max(stops.last, f(b.xs[i] + edge)));
      }
      colors.add(const Color(0x00FFFFFF));
      stops.add(math.min(1.0, stops.last + 0.5 / w));
      return LinearGradient(colors: colors, stops: stops)
          .createShader(Offset.zero & b.rect.size);
    }

    void paintBands(PaintingContext ctx, Offset o, int i) {
      if (i >= shown.length) {
        ctx.paintChild(c, o);
        return;
      }
      final b = shown[i];
      final layer = (_bands[i].layer ?? ShaderMaskLayer())
        ..shader = shaderFor(b)
        ..maskRect = b.rect.shift(o)
        ..blendMode = BlendMode.dstIn;
      _bands[i].layer = layer;
      ctx.pushLayer(layer, (ctx2, o2) => paintBands(ctx2, o2, i + 1), o);
    }

    for (var i = shown.length; i < _maxBands; i++) {
      _bands[i].layer = null;
    }
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      // Lines below the head's line are not shown yet.
      Rect.fromLTRB(0, 0, w, clipBottom),
      (ctx, o) => paintBands(ctx, o, 0),
      oldLayer: _clip.layer,
    );
  }

  void _clearLayers() {
    _clip.layer = null;
    _opacity.layer = null;
    for (final b in _bands) {
      b.layer = null;
    }
  }

  @override
  void dispose() {
    _clearLayers();
    super.dispose();
  }
}
