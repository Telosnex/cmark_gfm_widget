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
    this.selectable = false,
  });

  final List<TextSpan> lines;
  final TextStyle style;
  final TextScaler textScaler;

  /// Whether the lines join the enclosing [SelectionContainer].
  final bool selectable;

  SelectionRegistrar? _registrar(BuildContext context) =>
      selectable ? SelectionContainer.maybeOf(context) : null;

  static Color _selectionColor(BuildContext context) =>
      DefaultSelectionStyle.of(context).selectionColor ??
      DefaultSelectionStyle.defaultColor;

  @override
  RenderCodeBlock createRenderObject(BuildContext context) => RenderCodeBlock(
        lines: lines,
        style: style,
        textScaler: textScaler,
        textDirection: Directionality.of(context),
        devicePixelRatio: PixelSnap.of(context).devicePixelRatio,
        selectionColor: _selectionColor(context),
      )..registrar = _registrar(context);

  @override
  void updateRenderObject(BuildContext context, RenderCodeBlock renderObject) {
    // Metrics first: the lines setter measures with them.
    renderObject
      ..style = style
      ..textScaler = textScaler
      ..textDirection = Directionality.of(context)
      ..devicePixelRatio = PixelSnap.of(context).devicePixelRatio
      ..lines = lines
      ..selectionColor = _selectionColor(context)
      ..registrar = _registrar(context);
  }
}

/// See [CodeBlockLines].
class RenderCodeBlock extends RenderBox with Selectable, SelectionRegistrant {
  RenderCodeBlock({
    required List<TextSpan> lines,
    required TextStyle style,
    required TextScaler textScaler,
    required TextDirection textDirection,
    required double devicePixelRatio,
    Color selectionColor = const Color(0x6633B5E5),
  })  : _lines = lines,
        _style = style,
        _textScaler = textScaler,
        _textDirection = textDirection,
        _devicePixelRatio = devicePixelRatio,
        _selectionColor = selectionColor {
    _resetMetrics();
    _geometry = ValueNotifier(_geometryNow());
    _geometry.addListener(markNeedsPaint);
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
    _clampSelection();
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
    _updateSemanticsRange(painted);
    _paintHandles(context, offset);
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
    _paintSelection(canvas, offset, first, last);
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
    // Unregister first: a container that the block leaves can still push
    // handle layers to its selectables.
    registrar = null;
    _disposed = true;
    _clearPainters();
    super.dispose();
    _geometry.dispose();
  }

  // ---------------------------------------------------------------------
  // Selection (ADR D8). A position is an offset in the block's text with a
  // "\n" between lines: line i starts at lineStart(i) + i. The selection is
  // [_base, _extent], in either order. Only lines at the selection edges and
  // on screen are laid out.

  Color _selectionColor;
  Color get selectionColor => _selectionColor;
  set selectionColor(Color value) {
    if (value == _selectionColor) return;
    _selectionColor = value;
    if (_geometry.value.hasSelection) markNeedsPaint();
  }

  late final ValueNotifier<SelectionGeometry> _geometry;
  bool _disposed = false;
  int? _base;
  int? _extent;
  LayerLink? _startHandle;
  LayerLink? _endHandle;

  int _contentStart(int line) => _starts[line] + line;

  @override
  int get contentLength =>
      _lines.isEmpty ? 0 : _starts.last + _lines.length - 1;

  // The line that contains [offset]; at a line break, the line before it.
  int _lineOf(int offset) {
    var low = 0;
    var high = _lines.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (_contentStart(mid) <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  String _lineText(int line) =>
      _lines[line].toPlainText(includeSemanticsLabels: false);

  double _lineX(int line) =>
      _textDirection == TextDirection.rtl ? size.width - _widths[line] : 0;

  // True when [line] is measured without layout and uses pieces.
  bool _isPieced(int line) => _piecesOf(line) != null;

  double _xOf(int line, int column) {
    final double x;
    if (column <= 0) {
      x = 0;
    } else if (column >= _lengths[line]) {
      x = _widths[line];
    } else if (_isPieced(line)) {
      x = _xsAt(_lines[line], [column]).single;
    } else {
      x = _painterFor(line, 0, query: true)
          .getOffsetForCaret(TextPosition(offset: column), Rect.zero)
          .dx;
    }
    return _lineX(line) + x;
  }

  int _columnAt(int line, double x) {
    final local = x - _lineX(line);
    final length = _lengths[line];
    if (length == 0) return 0;
    if (_isPieced(line)) {
      final pieces = _piecesOf(line)!;
      // The piece that holds x, then its characters by advance.
      var piece = 0;
      while (piece + 1 < pieces.xs.length && pieces.xs[piece + 1] <= local) {
        piece++;
      }
      final start = pieces.starts[piece];
      final end = math.min(length, start + linePieceLength);
      final xs = _xsAt(_lines[line], [for (var c = start; c < end; c++) c]);
      for (var i = 0; i < xs.length; i++) {
        final right = i + 1 < xs.length ? xs[i + 1] : _widths[line];
        if (local < (xs[i] + right) / 2) return start + i;
      }
      return end;
    }
    return _painterFor(line, 0, query: true)
        .getPositionForOffset(Offset(local, _lineHeight / 2))
        .offset
        .clamp(0, length);
  }

  // The word at [column] of [line], in columns.
  TextRange _wordAt(int line, int column) {
    final length = _lengths[line];
    if (length == 0) return const TextRange.collapsed(0);
    final at = math.min(column, length - 1);
    if (_isPieced(line)) {
      final text = _lineText(line);
      bool isWord(int unit) =>
          (unit >= 0x30 && unit <= 0x39) ||
          (unit >= 0x41 && unit <= 0x5a) ||
          (unit >= 0x61 && unit <= 0x7a) ||
          unit == 0x5f;
      final word = isWord(text.codeUnitAt(at));
      var start = at;
      var end = at + 1;
      while (start > 0 && isWord(text.codeUnitAt(start - 1)) == word) {
        start--;
      }
      while (end < length && isWord(text.codeUnitAt(end)) == word) {
        end++;
      }
      return TextRange(start: start, end: end);
    }
    final range = _painterFor(line, 0, query: true)
        .getWordBoundary(TextPosition(offset: at));
    return TextRange(
      start: range.start.clamp(0, length),
      end: range.end.clamp(0, length),
    );
  }

  int _offsetAtLocal(Offset local) {
    if (_lines.isEmpty || local.dy < 0) return 0;
    if (local.dy >= _contentHeight) return contentLength;
    final line = (local.dy / _lineHeight).floor().clamp(0, _lines.length - 1);
    return _contentStart(line) + _columnAt(line, local.dx);
  }

  void _clampSelection() {
    final length = contentLength;
    if (_lines.isEmpty) {
      _base = _extent = null;
    } else {
      if (_base != null) _base = math.min(_base!, length);
      if (_extent != null) _extent = math.min(_extent!, length);
    }
    _updateGeometry();
  }

  @override
  SelectionGeometry get value => _geometry.value;

  @override
  void addListener(VoidCallback listener) => _geometry.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _geometry.removeListener(listener);

  @override
  List<Rect> get boundingBoxes => [Offset.zero & size];

  void _updateGeometry() {
    final next = _geometryNow();
    if (next != _geometry.value) _geometry.value = next;
  }

  SelectionGeometry _geometryNow() {
    final base = _base;
    final extent = _extent;
    if (base == null || extent == null || _lines.isEmpty || !hasSize) {
      return SelectionGeometry(
        status: SelectionStatus.none,
        hasContent: _lines.isNotEmpty,
      );
    }
    final reversed = base > extent;
    final collapsed = base == extent;
    SelectionPoint point(int offset, TextSelectionHandleType type) {
      final line = _lineOf(offset);
      final column = offset - _contentStart(line);
      return SelectionPoint(
        localPosition: Offset(_xOf(line, column), (line + 1) * _lineHeight),
        lineHeight: _lineHeight,
        handleType: type,
      );
    }

    final startType = collapsed
        ? TextSelectionHandleType.collapsed
        : (reversed
            ? TextSelectionHandleType.right
            : TextSelectionHandleType.left);
    final endType = collapsed
        ? TextSelectionHandleType.collapsed
        : (reversed
            ? TextSelectionHandleType.left
            : TextSelectionHandleType.right);
    // Rects of the edge lines only: one rect per selected line would be
    // O(lines) for a select-all.
    final firstLine = _lineOf(math.min(base, extent));
    final lastLine = _lineOf(math.max(base, extent));
    return SelectionGeometry(
      status:
          collapsed ? SelectionStatus.collapsed : SelectionStatus.uncollapsed,
      hasContent: true,
      startSelectionPoint: point(base, startType),
      endSelectionPoint: point(extent, endType),
      selectionRects: [
        ..._selectionRects(firstLine),
        if (lastLine != firstLine) ..._selectionRects(lastLine),
      ],
    );
  }

  // The selected part of [line], or nothing.
  List<Rect> _selectionRects(int line) {
    final base = _base;
    final extent = _extent;
    if (base == null || extent == null || base == extent) return const [];
    final start = math.min(base, extent);
    final end = math.max(base, extent);
    final lineStart = _contentStart(line);
    final lineEnd = lineStart + _lengths[line];
    if (end < lineStart || start > lineEnd) return const [];
    var left = _xOf(line, math.max(start, lineStart) - lineStart);
    var right = _xOf(line, math.min(end, lineEnd) - lineStart);
    if (left > right) (left, right) = (right, left);
    // A selected line break shows as a narrow box after the text.
    if (end > lineEnd) right += _lineHeight / 4;
    if (right <= left) return const [];
    return [
      Rect.fromLTRB(left, line * _lineHeight, right, (line + 1) * _lineHeight),
    ];
  }

  void _paintSelection(Canvas canvas, Offset offset, int first, int last) {
    final base = _base;
    final extent = _extent;
    if (base == null || extent == null || base == extent) return;
    final from = math.max(first, _lineOf(math.min(base, extent)));
    final to = math.min(last - 1, _lineOf(math.max(base, extent)));
    final paint = Paint()..color = _selectionColor;
    for (var line = from; line <= to; line++) {
      for (final rect in _selectionRects(line)) {
        canvas.drawRect(rect.shift(offset), paint);
      }
    }
  }

  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {
    if (_disposed) return;
    if (startHandle == _startHandle && endHandle == _endHandle) return;
    _startHandle = startHandle;
    _endHandle = endHandle;
    markNeedsPaint();
  }

  void _paintHandles(PaintingContext context, Offset offset) {
    void push(LayerLink? link, SelectionPoint? point) {
      if (link == null || point == null) return;
      context.pushLayer(
        LeaderLayer(link: link, offset: offset + point.localPosition),
        (context, offset) {},
        Offset.zero,
      );
    }

    push(_startHandle, _geometry.value.startSelectionPoint);
    push(_endHandle, _geometry.value.endSelectionPoint);
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    if (_lines.isEmpty) return SelectionResult.none;
    var result = SelectionResult.none;
    switch (event.type) {
      case SelectionEventType.startEdgeUpdate:
      case SelectionEventType.endEdgeUpdate:
        result = _updateEdge(event as SelectionEdgeUpdateEvent);
      case SelectionEventType.clear:
        _base = _extent = null;
      case SelectionEventType.selectAll:
        _base = 0;
        _extent = contentLength;
      case SelectionEventType.selectWord:
        result = _selectAt(
          (event as SelectWordSelectionEvent).globalPosition,
          TextGranularity.word,
        );
      case SelectionEventType.selectParagraph:
        result = _selectAt(
          (event as SelectParagraphSelectionEvent).globalPosition,
          TextGranularity.line,
        );
      case SelectionEventType.granularlyExtendSelection:
        result = _extendGranularly(event as GranularlyExtendSelectionEvent);
      case SelectionEventType.directionallyExtendSelection:
        result =
            _extendDirectionally(event as DirectionallyExtendSelectionEvent);
    }
    _updateGeometry();
    return result;
  }

  // The range of [granularity] around [offset].
  TextRange _unitAt(int offset, TextGranularity granularity) {
    final line = _lineOf(offset);
    final start = _contentStart(line);
    switch (granularity) {
      case TextGranularity.character:
        return TextRange.collapsed(offset);
      case TextGranularity.word:
        final word = _wordAt(line, offset - start);
        return TextRange(start: start + word.start, end: start + word.end);
      case TextGranularity.line:
      case TextGranularity.paragraph:
        return TextRange(start: start, end: start + _lengths[line]);
      case TextGranularity.document:
        return TextRange(start: 0, end: contentLength);
    }
  }

  SelectionResult _updateEdge(SelectionEdgeUpdateEvent event) {
    final rect = Offset.zero & size;
    final local = globalToLocal(event.globalPosition);
    // Beside the block, a point selects to its own line's start or end, as
    // in an editor. SelectionUtils.adjustDragOffset would take the block's
    // corner, as for a paragraph.
    var offset = _offsetAtLocal(local);
    final isEnd = event.type == SelectionEventType.endEdgeUpdate;
    if (event.granularity != TextGranularity.character &&
        rect.contains(local)) {
      final unit = _unitAt(offset, event.granularity);
      final other = isEnd ? _base : _extent;
      final forward = other == null || other <= offset;
      offset = forward ? unit.end : unit.start;
      // Keep the whole unit at the other edge selected.
      if (other != null) {
        final otherUnit = _unitAt(other, event.granularity);
        final otherOffset = forward ? otherUnit.start : otherUnit.end;
        if (isEnd) {
          _base = otherOffset;
        } else {
          _extent = otherOffset;
        }
      }
    }
    if (isEnd) {
      _extent = offset;
      _base ??= offset;
    } else {
      _base = offset;
      _extent ??= offset;
    }
    if (local.dy < 0) return SelectionResult.previous;
    if (local.dy >= size.height) return SelectionResult.next;
    return SelectionResult.end;
  }

  SelectionResult _selectAt(Offset globalPosition, TextGranularity unit) {
    final rect = Offset.zero & size;
    final local = globalToLocal(globalPosition);
    if (!rect.contains(local)) {
      return SelectionUtils.getResultBasedOnRect(rect, local);
    }
    final range = _unitAt(_offsetAtLocal(local), unit);
    _base = range.start;
    _extent = range.end;
    return SelectionResult.end;
  }

  SelectionResult _extendGranularly(GranularlyExtendSelectionEvent event) {
    final length = contentLength;
    if (_base == null || _extent == null) {
      _base = _extent = event.forward ? 0 : length;
    }
    final current = event.isEnd ? _extent! : _base!;
    final line = _lineOf(current);
    final lineStart = _contentStart(line);
    final lineEnd = lineStart + _lengths[line];
    final int next;
    switch (event.granularity) {
      case TextGranularity.character:
        next = (current + (event.forward ? 1 : -1)).clamp(0, length);
      case TextGranularity.word:
        if (event.forward) {
          next = current >= lineEnd
              ? math.min(length, current + 1)
              : _unitAt(current, TextGranularity.word).end;
        } else {
          next = current <= lineStart
              ? math.max(0, current - 1)
              : _unitAt(current - 1, TextGranularity.word).start;
        }
      case TextGranularity.line:
      case TextGranularity.paragraph:
        if (event.forward) {
          next = current < lineEnd
              ? lineEnd
              : (line + 1 < _lines.length
                  ? _contentStart(line + 1) + _lengths[line + 1]
                  : length);
        } else {
          next = current > lineStart
              ? lineStart
              : (line > 0 ? _contentStart(line - 1) : 0);
        }
      case TextGranularity.document:
        next = event.forward ? length : 0;
    }
    var result = SelectionResult.end;
    if (next == current &&
        ((event.forward && current == length) ||
            (!event.forward && current == 0))) {
      result = event.forward ? SelectionResult.next : SelectionResult.previous;
    }
    if (event.isEnd) {
      _extent = next;
    } else {
      _base = next;
    }
    return result;
  }

  SelectionResult _extendDirectionally(
    DirectionallyExtendSelectionEvent event,
  ) {
    final length = contentLength;
    final x = globalToLocal(Offset(event.dx, 0)).dx;
    final last = _lines.length - 1;
    int at(int line) => _contentStart(line) + _columnAt(line, x);
    var result = SelectionResult.end;
    final int next;
    switch (event.direction) {
      case SelectionExtendDirection.previousLine:
        _base ??= length;
        _extent ??= length;
        final line = _lineOf(event.isEnd ? _extent! : _base!);
        if (line == 0) {
          next = 0;
          result = SelectionResult.previous;
        } else {
          next = at(line - 1);
        }
      case SelectionExtendDirection.nextLine:
        _base ??= 0;
        _extent ??= 0;
        final line = _lineOf(event.isEnd ? _extent! : _base!);
        if (line == last) {
          next = length;
          result = SelectionResult.next;
        } else {
          next = at(line + 1);
        }
      case SelectionExtendDirection.forward:
        // The selection enters from before this block.
        _base ??= 0;
        _extent ??= 0;
        next = at(0);
      case SelectionExtendDirection.backward:
        // The selection enters from after this block.
        _base ??= length;
        _extent ??= length;
        next = at(last);
    }
    if (event.isEnd) {
      _extent = next;
    } else {
      _base = next;
    }
    return result;
  }

  @override
  SelectedContent? getSelectedContent() {
    final base = _base;
    final extent = _extent;
    if (base == null || extent == null || base == extent) return null;
    final start = math.min(base, extent);
    final end = math.max(base, extent);
    final first = _lineOf(start);
    final last = _lineOf(end);
    final buffer = StringBuffer();
    for (var line = first; line <= last; line++) {
      final lineStart = _contentStart(line);
      final text = _lineText(line);
      final from = math.max(start, lineStart) - lineStart;
      final to = math.min(end, lineStart + text.length) - lineStart;
      if (line > first) buffer.write('\n');
      if (from < to) buffer.write(text.substring(from, to));
    }
    // The selection can end on the line break after the last line's text.
    if (end > _contentStart(last) + _lengths[last]) buffer.write('\n');
    return SelectedContent(plainText: buffer.toString());
  }

  @override
  SelectedContentRange? getSelection() {
    final base = _base;
    final extent = _extent;
    if (base == null || extent == null) return null;
    return SelectedContentRange(startOffset: base, endOffset: extent);
  }

  // ---------------------------------------------------------------------
  // Semantics (ADR D11): the text of the painted lines.

  int _semanticsFirst = 0;
  int _semanticsLast = 0;

  void _updateSemanticsRange(Rect painted) {
    final count = _lines.length;
    final first = (painted.top / _lineHeight).floor().clamp(0, count);
    final last = (painted.bottom / _lineHeight).ceil().clamp(0, count);
    if (first == _semanticsFirst && last == _semanticsLast) return;
    _semanticsFirst = first;
    _semanticsLast = last;
    // Semantics are flushed after paint, in the same frame.
    markNeedsSemanticsUpdate();
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    final last = math.min(_semanticsLast, _lines.length);
    config
      ..isSemanticBoundary = true
      ..textDirection = _textDirection
      ..label = [
        for (var line = _semanticsFirst; line < last; line++) _lineText(line),
      ].join('\n');
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
