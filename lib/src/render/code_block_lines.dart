import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:pixel_snap_fork/pixel_snap.dart';

/// The lines of a code block, laid out and painted only where they are
/// visible. See docs/ADR_001_CODE_BLOCK_RENDER_OBJECT.md.
///
/// [lines] holds one span per line, without line breaks. Every line has the
/// same height: the strut of [style] is forced.
class CodeBlockLines extends LeafRenderObjectWidget {
  const CodeBlockLines({
    super.key,
    required this.lines,
    required this.style,
    this.textScaler = TextScaler.noScaling,
  });

  final List<TextSpan> lines;
  final TextStyle style;
  final TextScaler textScaler;

  @override
  RenderCodeBlock createRenderObject(BuildContext context) => RenderCodeBlock(
        lines: lines,
        style: style,
        textScaler: textScaler,
        textDirection: Directionality.of(context),
        devicePixelRatio: PixelSnap.of(context).devicePixelRatio,
      );

  @override
  void updateRenderObject(BuildContext context, RenderCodeBlock renderObject) {
    // Metrics first: the lines setter measures with them.
    renderObject
      ..style = style
      ..textScaler = textScaler
      ..textDirection = Directionality.of(context)
      ..devicePixelRatio = PixelSnap.of(context).devicePixelRatio
      ..lines = lines;
  }
}

/// See [CodeBlockLines].
class RenderCodeBlock extends RenderBox {
  RenderCodeBlock({
    required List<TextSpan> lines,
    required TextStyle style,
    required TextScaler textScaler,
    required TextDirection textDirection,
    required double devicePixelRatio,
  })  : _lines = lines,
        _style = style,
        _textScaler = textScaler,
        _textDirection = textDirection,
        _devicePixelRatio = devicePixelRatio {
    _resetMetrics();
  }

  /// Number of line or piece layouts. Tests use it to check that only
  /// visible lines are laid out.
  static int debugLineLayouts = 0;

  /// Lines longer than this are laid out in pieces of this many characters.
  static const int linePieceLength = 4096;

  static const int _maxCachedPainters = 512;

  // Lines that text queries (the streaming fade) need but paint does not.
  // A separate cache, so they do not push out painted lines.
  static const int _maxQueryPainters = 32;

  // Piece index bits in a cache key. Keys stay below 2^53 for dart2js.
  static const int _pieceKeyFactor = 1 << 20;

  List<TextSpan> _lines;
  TextStyle _style;
  TextScaler _textScaler;
  TextDirection _textDirection;
  double _devicePixelRatio;

  late double _lineHeight;
  late StrutStyle _strut;

  // Width of each line, and the span it was measured for.
  List<double> _widths = const [];
  List<TextSpan> _measured = const [];

  // Plain text length of each line, and the offset where each line starts
  // in the concatenated text (no line breaks). _starts has lines + 1 items.
  List<int> _lengths = const [];
  List<int> _starts = const [0];
  double _maxWidth = 0;

  // Per style: the advance of one ASCII character, or null for a
  // proportional font.
  final Map<TextStyle?, double?> _advances = {};

  // Laid-out lines and pieces, most recently used last.
  final LinkedHashMap<int, _CachedPainter> _painters = LinkedHashMap();
  final LinkedHashMap<int, _CachedPainter> _queryPainters = LinkedHashMap();

  // Lines whose pieces start at these x positions; null for a whole line.
  final Map<int, _Pieces> _pieces = {};

  Rect _paintedRect = Rect.zero;
  bool _checkScheduled = false;

  List<TextSpan> get lines => _lines;
  set lines(List<TextSpan> value) {
    if (identical(value, _lines)) return;
    final oldCount = _lines.length;
    final oldMax = _maxWidth;
    _lines = value;
    _measureWidths();
    if (value.length != oldCount || _maxWidth != oldMax) {
      markNeedsLayout();
    } else {
      markNeedsPaint();
    }
  }

  TextStyle get style => _style;
  set style(TextStyle value) {
    if (value == _style) return;
    _style = value;
    _resetMetrics();
  }

  TextScaler get textScaler => _textScaler;
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _resetMetrics();
  }

  TextDirection get textDirection => _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    _resetMetrics();
  }

  double get devicePixelRatio => _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    _resetMetrics();
  }

  /// The height of every line, in logical pixels.
  double get lineHeight => _lineHeight;

  void _resetMetrics() {
    _clearPainters();
    _advances.clear();
    _strut = StrutStyle.fromTextStyle(_style, forceStrutHeight: true);
    final probe = _newPainter(TextSpan(text: '0', style: _style));
    _lineHeight = _ceilToPixel(probe.height);
    probe.dispose();
    _widths = const [];
    _measured = const [];
    _lengths = const [];
    _measureWidths();
    markNeedsLayout();
  }

  double _ceilToPixel(double value) =>
      (value * _devicePixelRatio - 1e-6).ceilToDouble() / _devicePixelRatio;

  TextPainter _newPainter(TextSpan span) => TextPainter(
        text: span,
        textDirection: _textDirection,
        textScaler: _textScaler,
        strutStyle: _strut,
      )..layout();

  // Measures lines whose span is not identical to the one measured before.
  // O(lines) identity checks; layout only for changed non-ASCII lines.
  void _measureWidths() {
    final count = _lines.length;
    final widths = List<double>.filled(count, 0);
    final lengths = List<int>.filled(count, 0);
    final starts = List<int>.filled(count + 1, 0);
    final measured = List<TextSpan>.of(_lines);
    var maxWidth = 0.0;
    for (var i = 0; i < count; i++) {
      final span = _lines[i];
      final double width;
      if (i < _measured.length && identical(_measured[i], span)) {
        width = _widths[i];
        lengths[i] = _lengths[i];
      } else {
        width = _asciiWidth(span) ?? _layoutWidth(span);
        lengths[i] = _plainLength(span);
        _pieces.remove(i);
      }
      widths[i] = width;
      starts[i + 1] = starts[i] + lengths[i];
      if (width > maxWidth) maxWidth = width;
    }
    _widths = widths;
    _measured = measured;
    _lengths = lengths;
    _starts = starts;
    _maxWidth = _ceilToPixel(maxWidth);
  }

  double _layoutWidth(TextSpan span) {
    assert(() {
      debugLineLayouts++;
      return true;
    }());
    final painter = _newPainter(span);
    final width = painter.width;
    painter.dispose();
    return width;
  }

  // The width of a line of printable ASCII in monospace styles, without
  // layout. Null if the line has other characters or a proportional style.
  double? _asciiWidth(TextSpan span) {
    var width = 0.0;
    var ok = true;
    void visit(InlineSpan node, TextStyle? parentStyle) {
      if (!ok) return;
      if (node is! TextSpan) {
        ok = false;
        return;
      }
      final nodeStyle = node.style;
      final style = parentStyle == null
          ? nodeStyle
          : (nodeStyle == null ? parentStyle : parentStyle.merge(nodeStyle));
      final text = node.text;
      if (text != null && text.isNotEmpty) {
        for (var i = 0; i < text.length; i++) {
          final unit = text.codeUnitAt(i);
          if (unit < 0x20 || unit > 0x7e) {
            ok = false;
            return;
          }
        }
        final advance = _advanceOf(style);
        if (advance == null) {
          ok = false;
          return;
        }
        width += text.length * advance;
      }
      final children = node.children;
      if (children != null) {
        for (final child in children) {
          visit(child, style);
        }
      }
    }

    visit(span, null);
    return ok ? width : null;
  }

  double? _advanceOf(TextStyle? style) {
    if (_advances.containsKey(style)) return _advances[style];
    const probeLength = 64;
    double widthOf(String char) {
      final painter = TextPainter(
        text: TextSpan(text: char * probeLength, style: style),
        textDirection: TextDirection.ltr,
        textScaler: _textScaler,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final narrow = widthOf('i');
    final wide = widthOf('W');
    final advance = (wide - narrow).abs() < 0.5 ? wide / probeLength : null;
    _advances[style] = advance;
    return advance;
  }

  /// Length of the text of all lines, without line breaks.
  int get plainLength => _starts.last;

  /// Offset of [line]'s first character in [plainLength] terms.
  int lineStart(int line) => _starts[line];

  /// Plain text length of [line].
  int lineLength(int line) => _lengths[line];

  /// The first line that contains [offset], or that starts at it; the last
  /// line for the end of the text. Binary search, O(log lines).
  int lineAtOffset(int offset) {
    var low = 0;
    var high = _lengths.length - 1;
    if (high < 0) return 0;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_starts[mid] + _lengths[mid] > offset ||
          (_lengths[mid] == 0 && _starts[mid] >= offset)) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    return low;
  }

  /// The laid-out text of [line], in the line's own coordinates. Its top
  /// left is at (0, line * lineHeight) for left-to-right text.
  TextPainter linePainter(int line) => _painterFor(line, 0, query: true);

  @override
  double computeMinIntrinsicWidth(double height) => _maxWidth;

  @override
  double computeMaxIntrinsicWidth(double height) => _maxWidth;

  @override
  double computeMinIntrinsicHeight(double width) => _contentHeight;

  @override
  double computeMaxIntrinsicHeight(double width) => _contentHeight;

  double get _contentHeight => _lines.length * _lineHeight;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      constraints.constrain(Size(_maxWidth, _contentHeight));

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    if (_lines.isEmpty) return null;
    final painter = _painterFor(0, 0);
    return painter.computeDistanceToActualBaseline(baseline);
  }

  @override
  void performLayout() {
    size = computeDryLayout(constraints);
  }

  @override
  bool hitTestSelf(Offset position) => true;

  bool get _overflows =>
      size.width < _maxWidth - 1e-6 || size.height < _contentHeight - 1e-6;

  // The part of this box inside the view and every ancestor viewport.
  Rect _visibleRect() {
    var rect = Offset.zero & size;
    for (RenderObject? node = parent; node != null; node = node.parent) {
      if (node is RenderAbstractViewport) {
        final box = node as RenderBox;
        rect = rect.intersect(_toLocal(box, Offset.zero & box.size));
        if (rect.isEmpty) return Rect.zero;
      }
    }
    final root = owner?.rootNode;
    if (root is RenderView) {
      rect = rect.intersect(_toLocal(null, Offset.zero & root.size));
    }
    return rect.isEmpty ? Rect.zero : rect;
  }

  Rect _toLocal(RenderObject? ancestor, Rect rect) {
    final transform = getTransformTo(ancestor);
    if (transform.determinant() == 0) return Rect.zero;
    return MatrixUtils.inverseTransformRect(transform, rect);
  }

  // The visible rect plus one visible extent on each side.
  Rect _paintRectFor(Rect visible) {
    if (visible.isEmpty) return Rect.zero;
    return Rect.fromLTRB(
      visible.left - visible.width,
      visible.top - visible.height,
      visible.right + visible.width,
      visible.bottom + visible.height,
    ).intersect(Offset.zero & size);
  }

  static bool _covers(Rect outer, Rect inner) =>
      inner.left >= outer.left &&
      inner.top >= outer.top &&
      inner.right <= outer.right &&
      inner.bottom <= outer.bottom;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _scheduleVisibilityCheck();
  }

  // After each frame, repaints if the visible rect left the painted rect.
  // This catches scrolling and the box moving when content around it
  // changes size, after both are laid out.
  void _scheduleVisibilityCheck() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!attached) return;
      _scheduleVisibilityCheck();
      if (!hasSize) return;
      if (_covers(_paintedRect, Offset.zero & size)) return;
      final visible = _visibleRect();
      if (!visible.isEmpty && !_covers(_paintedRect, visible)) {
        markNeedsPaint();
      }
    }, debugLabel: 'RenderCodeBlock.visibility');
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final painted = _paintRectFor(_visibleRect());
    _paintedRect = painted;
    if (painted.isEmpty || _lines.isEmpty) return;
    if (_overflows) {
      context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        (context, offset) => _paintLines(context.canvas, offset, painted),
      );
    } else {
      _paintLines(context.canvas, offset, painted);
    }
  }

  void _paintLines(Canvas canvas, Offset offset, Rect painted) {
    final count = _lines.length;
    final first = (painted.top / _lineHeight).floor().clamp(0, count);
    final last = (painted.bottom / _lineHeight).ceil().clamp(0, count);
    for (var line = first; line < last; line++) {
      final y = offset.dy + line * _lineHeight;
      final pieces = _piecesOf(line);
      if (pieces == null) {
        final painter = _painterFor(line, 0);
        final x = _textDirection == TextDirection.rtl
            ? size.width - painter.width
            : 0.0;
        painter.paint(canvas, Offset(offset.dx + x, y));
        continue;
      }
      for (var piece = 0; piece < pieces.starts.length; piece++) {
        final left = pieces.xs[piece];
        final right =
            piece + 1 < pieces.xs.length ? pieces.xs[piece + 1] : _widths[line];
        if (right < painted.left || left > painted.right) continue;
        _painterFor(line, piece + 1).paint(canvas, Offset(offset.dx + left, y));
      }
    }
  }

  // The pieces of a long ASCII line, or null to lay out the whole line.
  _Pieces? _piecesOf(int line) {
    final cached = _pieces[line];
    if (cached != null) return cached.starts.isEmpty ? null : cached;
    final span = _lines[line];
    final length = _plainLength(span);
    if (length <= linePieceLength ||
        _textDirection != TextDirection.ltr ||
        _asciiWidth(span) == null) {
      _pieces[line] = const _Pieces([], []);
      return null;
    }
    final starts = <int>[
      for (var start = 0; start < length; start += linePieceLength) start,
    ];
    final xs = _xsAt(span, starts);
    return _pieces[line] = _Pieces(starts, xs);
  }

  // The x of each character offset in a monospace ASCII line.
  List<double> _xsAt(TextSpan span, List<int> offsets) {
    final xs = <double>[];
    var position = 0;
    var x = 0.0;
    var next = 0;
    void visit(InlineSpan node, TextStyle? parentStyle) {
      final textSpan = node as TextSpan;
      final nodeStyle = textSpan.style;
      final style = parentStyle == null
          ? nodeStyle
          : (nodeStyle == null ? parentStyle : parentStyle.merge(nodeStyle));
      final text = textSpan.text;
      if (text != null && text.isNotEmpty) {
        final advance = _advanceOf(style)!;
        while (
            next < offsets.length && offsets[next] < position + text.length) {
          xs.add(x + (offsets[next] - position) * advance);
          next++;
        }
        position += text.length;
        x += text.length * advance;
      }
      for (final child in textSpan.children ?? const <InlineSpan>[]) {
        visit(child, style);
      }
    }

    visit(span, null);
    return xs;
  }

  TextPainter _painterFor(int line, int piece, {bool query = false}) {
    final key = line * _pieceKeyFactor + piece;
    final span = _lines[line];
    final painted = _painters[key];
    if (query && painted != null && identical(painted.span, span)) {
      return painted.painter;
    }
    final cache = query ? _queryPainters : _painters;
    final cached = cache.remove(key);
    if (cached != null && identical(cached.span, span)) {
      cache[key] = cached;
      return cached.painter;
    }
    cached?.painter.dispose();
    final TextSpan laidOut;
    if (piece == 0) {
      laidOut = span;
    } else {
      final start = _pieces[line]!.starts[piece - 1];
      laidOut = _slice(span, start, start + linePieceLength);
    }
    assert(() {
      debugLineLayouts++;
      return true;
    }());
    final painter = _newPainter(laidOut);
    cache[key] = _CachedPainter(span, painter);
    final max = query ? _maxQueryPainters : _maxCachedPainters;
    while (cache.length > max) {
      cache.remove(cache.keys.first)!.painter.dispose();
    }
    return painter;
  }

  void _clearPainters() {
    for (final cached in [..._painters.values, ..._queryPainters.values]) {
      cached.painter.dispose();
    }
    _painters.clear();
    _queryPainters.clear();
    _pieces.clear();
  }

  @override
  void dispose() {
    _clearPainters();
    super.dispose();
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(IntProperty('lines', _lines.length))
      ..add(DoubleProperty('lineHeight', _lineHeight))
      ..add(DoubleProperty('maxWidth', _maxWidth));
  }
}

class _CachedPainter {
  _CachedPainter(this.span, this.painter);

  final TextSpan span;
  final TextPainter painter;
}

class _Pieces {
  const _Pieces(this.starts, this.xs);

  final List<int> starts;
  final List<double> xs;
}

int _plainLength(InlineSpan span) {
  var length = 0;
  span.visitChildren((node) {
    if (node is TextSpan) length += node.text?.length ?? 0;
    return true;
  });
  return length;
}

// The characters [start, end) of [span], with the same styles.
TextSpan _slice(TextSpan span, int start, int end) {
  var position = 0;
  TextSpan? visit(TextSpan node) {
    final text = node.text ?? '';
    final textStart = position;
    position += text.length;
    final from = math.max(start, textStart) - textStart;
    final to = math.min(end, textStart + text.length) - textStart;
    final slicedText = from < to ? text.substring(from, to) : null;
    final children = <InlineSpan>[];
    for (final child in node.children ?? const <InlineSpan>[]) {
      if (position >= end) break;
      final sliced = visit(child as TextSpan);
      if (sliced != null) children.add(sliced);
    }
    if (slicedText == null && children.isEmpty) return null;
    return TextSpan(
      text: slicedText,
      style: node.style,
      children: children.isEmpty ? null : children,
    );
  }

  return visit(span) ?? TextSpan(style: span.style);
}
