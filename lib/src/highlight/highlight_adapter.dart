import 'dart:collection';
import 'dart:isolate';

import 'scope_runs.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:highlight_fork/highlight.dart' as hi;
import 'package:pixel_snap_fork/material.dart';

/// Highlighted code, as one [TextSpan] per display line.
///
/// Line spans are stable across streaming appends: while code streams in and
/// only grows, previously produced line spans are returned as *identical
/// instances*. Rendering each line in its own `RichText` therefore lets
/// `RenderParagraph` skip layout entirely for unchanged lines, which is what
/// makes long streaming code blocks O(1) per appended chunk instead of O(n).
class HighlightedCodeLines {
  const HighlightedCodeLines({required this.lines, required this.baseStyle});

  /// One span per display line. Line spans never contain newline characters.
  final List<TextSpan> lines;

  /// The effective base style (theme `root` merged over the given base style).
  final TextStyle baseStyle;
}

/// Converts code into highlighted [TextSpan]s using package:highlight.
///
/// Two layers of caching:
///
/// 1. An exact-result LRU cache, which serves rebuilds where the code did not
///    change (e.g. unrelated widget rebuilds).
/// 2. Incremental *stream states* keyed by highlight configuration. Streamed
///    code blocks are append-only, so completed lines are highlighted exactly
///    once using the parser-continuation API
///    (`Highlight.highlight` with an opaque continuation), and only the trailing
///    partial line is re-highlighted per append. Without this, every streamed chunk
///    re-parses the entire code block, which is quadratic over the stream.
///
/// Incremental parsing preserves open multiline constructs, but a grammar that
/// looks ahead across a completed line boundary can differ from a whole-text
/// parse (for example, JavaScript `hello\n()` classifies `hello` as a function
/// only when the following line is available). Completed line styles are
/// provisional but stable during streaming. On completion one whole-text parse
/// corrects lookahead-dependent colors, preserving identical spans for unchanged
/// lines. Large corrections run in an isolate (or at idle on web) and notify
/// listeners when ready; until then the provisional result remains visible.
/// Both paths retain the display policy: parse tab/CRLF-normalized, right-trimmed
/// source, then preserve trailing spaces unhighlighted and omit final newlines.
class HighlightAdapter extends ChangeNotifier {
  HighlightAdapter({
    this.maxCacheEntries = 128,
    this.maxStreamStates = 8,
    this.highlightOffload,
    this.highlightOffloadThreshold = asyncFinalizationThreshold,
  }) : assert(highlightOffloadThreshold == null ||
            highlightOffloadThreshold >= 0) {
    hi.ensureInitialized();
  }

  /// Blocks at or above this UTF-16 length finalize off the current frame.
  /// Tuned from highlight_fork/tool/full_parse_results.md: 4 KiB already costs
  /// ~6 ms native JIT p95 and ~3.9 ms WASM, leaving too little frame headroom.
  static const int asyncFinalizationThreshold = 2048;

  /// Optional worker hook. Null retains the native isolate/web idle fallback.
  /// Errors fall back to synchronous parsing.
  final HighlightOffload? highlightOffload;

  /// Minimum normalized UTF-16 length to offload a completed block.
  /// Defaults to 2048; zero always offloads; null always parses synchronously.
  /// Auto-detection remains synchronous regardless of this value.
  final int? highlightOffloadThreshold;

  final int maxCacheEntries;

  /// Maximum number of concurrently tracked streaming code blocks.
  final int maxStreamStates;

  final LinkedHashMap<_CacheKey, HighlightedCodeLines> _cache = LinkedHashMap();
  final List<_StreamState> _streamStates = [];
  final Map<Object, _CacheKey> _activeRequests = {};
  final Set<_CacheKey> _pending = {};
  bool _disposed = false;

  /// Invalidates in-flight corrections when a code block leaves the tree.
  void releaseBlock(Object blockKey) => _activeRequests.remove(blockKey);

  @override
  void dispose() {
    _disposed = true;
    _activeRequests.clear();
    super.dispose();
  }

  /// Builds provisional incremental lines unless [complete] is true. Complete
  /// blocks receive a whole-text parse; expensive corrections notify listeners
  /// asynchronously. Widgets should provide a stable [blockKey] and call
  /// [releaseBlock] on disposal so obsolete corrections are discarded.
  /// [offload] overrides both constructor settings for this request, allowing a
  /// shared adapter to honor per-renderer configuration. A null threshold in
  /// this record disables offloading; a null hook uses the built-in fallback.
  HighlightedCodeLines buildLines({
    required String code,
    required TextStyle baseStyle,
    required Map<String, TextStyle> theme,
    required bool autoDetectLanguage,
    required String? language,
    required TextStyle? fallbackStyle,
    required int tabSize,
    bool complete = false,
    Object? blockKey,
    ({HighlightOffload? hook, int? threshold})? offload,
  }) {
    final normalized = _normalizeTabs(code.replaceAll('\r\n', '\n'), tabSize);
    final trimmed = normalized.trimRight();
    final trailing = normalized.substring(trimmed.length);

    final themeHash = _themeHash(theme);
    final key = _CacheKey(
      code: trimmed,
      complete: complete,
      trailing: trailing,
      language: language,
      autoDetect: autoDetectLanguage,
      themeHash: themeHash,
      baseStyleHash: baseStyle.hashCode,
      fallbackHash: fallbackStyle?.hashCode ?? 0,
      tabSize: tabSize,
    );

    if (blockKey != null) _activeRequests[blockKey] = key;
    final cached = _cache.remove(key);
    if (cached != null) {
      // Re-insert to approximate LRU semantics.
      _cache[key] = cached;
      return cached;
    }

    final effectiveBase =
        theme['root'] != null ? baseStyle.merge(theme['root']) : baseStyle;
    final styles = _SpanStyles(
      base: effectiveBase,
      theme: theme,
      fallback: fallbackStyle ?? baseStyle,
    );

    // Full parsing never replaces the streaming continuation. A block that
    // grows again after finalization can resume incrementally.
    var previous = _cache[_CacheKey(
      code: trimmed,
      trailing: trailing,
      language: language,
      autoDetect: autoDetectLanguage,
      themeHash: themeHash,
      baseStyleHash: baseStyle.hashCode,
      fallbackHash: fallbackStyle?.hashCode ?? 0,
      tabSize: tabSize,
      complete: false,
    )];
    if (complete && previous == null) {
      var longest = -1;
      for (final entry in _cache.entries) {
        if (entry.key.sameConfiguration(key) &&
            trimmed.startsWith(entry.key.code) &&
            entry.key.code.length > longest) {
          previous = entry.value;
          longest = entry.key.code.length;
        }
      }
    }
    final configHash = Object.hash(
      language,
      themeHash,
      baseStyle.hashCode,
      fallbackStyle?.hashCode ?? 0,
      tabSize,
    );
    final threshold =
        offload == null ? highlightOffloadThreshold : offload.threshold;
    final hook = offload == null ? highlightOffload : offload.hook;
    final defer = complete &&
        !autoDetectLanguage &&
        threshold != null &&
        trimmed.length >= threshold;
    final List<TextSpan> lines;
    if (autoDetectLanguage) {
      lines = _autoDetectLines(trimmed, styles);
    } else if (complete && !defer) {
      lines = _fullLines(
          highlightScopeRuns(trimmed, language ?? ''), trimmed, styles);
    } else {
      lines = _incrementalLines(trimmed, language, configHash, styles);
    }

    _appendTrailingWhitespace(lines, trailing, effectiveBase);

    if (lines.isEmpty) {
      lines.add(TextSpan(text: '', style: effectiveBase));
    }

    if (complete && previous != null) _reuseLines(lines, previous.lines);
    if (complete && !defer && !autoDetectLanguage) {
      _adoptFinalLines(configHash, trimmed, lines);
    }
    final result = HighlightedCodeLines(
      lines: List<TextSpan>.unmodifiable(lines),
      baseStyle: effectiveBase,
    );
    _cache[key] = result;
    if (_cache.length > maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    if (defer && _pending.add(key)) {
      _finalizeAsync(
        key,
        trimmed,
        trailing,
        language,
        styles,
        result,
        tracked: blockKey != null,
        configHash: configHash,
        hook: hook,
      );
    }
    return result;
  }

  Future<void> _finalizeAsync(
    _CacheKey key,
    String text,
    String trailing,
    String? language,
    _SpanStyles styles,
    HighlightedCodeLines provisional, {
    required bool tracked,
    required int configHash,
    required HighlightOffload? hook,
  }) async {
    try {
      HighlightScopeRuns runs;
      try {
        // Dispatch itself can throw (for example, a missing scheduler binding).
        // Always cross an async boundary before fallback or notification.
        runs = await Future<HighlightScopeRuns>.sync(() {
          if (hook != null) return hook(text, language ?? '');
          if (kIsWeb) {
            return SchedulerBinding.instance.scheduleTask(
              () => highlightScopeRuns(text, language ?? ''),
              Priority.idle,
            );
          }
          return _highlightInIsolate(text, language ?? '');
        });
      } catch (_) {
        if (_disposed || (tracked && !_activeRequests.containsValue(key))) {
          if (identical(_cache[key], provisional)) _cache.remove(key);
          return;
        }
        runs = highlightScopeRuns(text, language ?? '');
      }
      if (_disposed || (tracked && !_activeRequests.containsValue(key))) {
        // Do not leave an uncorrected complete result masquerading as final in
        // the cache if the same block/configuration is requested again later.
        if (identical(_cache[key], provisional)) _cache.remove(key);
        return;
      }
      final lines = _fullLines(runs, text, styles);
      _appendTrailingWhitespace(lines, trailing, styles.base);
      if (lines.isEmpty) lines.add(TextSpan(text: '', style: styles.base));
      _reuseLines(lines, provisional.lines);
      _adoptFinalLines(configHash, text, lines);
      _cache[key] = HighlightedCodeLines(
        lines: List.unmodifiable(lines),
        baseStyle: styles.base,
      );
      if (_cache.length > maxCacheEntries) _cache.remove(_cache.keys.first);
      notifyListeners();
    } finally {
      _pending.remove(key);
    }
  }

  List<TextSpan> _fullLines(
    HighlightScopeRuns scopedRuns,
    String text,
    _SpanStyles styles,
  ) {
    if (text.isEmpty) return [];
    final runs = scopedRuns.map((run) {
      var style = styles.base;
      for (final scope in run[1].split(' ').where((s) => s.isNotEmpty)) {
        style = _resolveStyle(style, scope, styles);
      }
      return _Run(run[0], style);
    }).toList();
    return _splitRunsIntoLines(runs)
        .map((line) => _lineSpan(line, styles.base))
        .toList();
  }

  // Retain corrected completed lines if a prematurely finalized block grows
  // again. The parser continuation itself remains valid and unchanged.
  void _adoptFinalLines(int configHash, String text, List<TextSpan> lines) {
    for (final state in _streamStates) {
      if (state.configHash == configHash && text.startsWith(state.prefix)) {
        for (var i = 0; i < state.lineSpans.length && i < lines.length; i++) {
          state.lineSpans[i] = lines[i];
        }
      }
    }
  }

  void _reuseLines(List<TextSpan> lines, List<TextSpan> previous) {
    for (var i = 0; i < lines.length && i < previous.length; i++) {
      if (lines[i] == previous[i]) lines[i] = previous[i];
    }
  }

  /// Incrementally highlights [trimmed], reusing a matching stream state when
  /// the code is an append-only extension of previously highlighted code.
  List<TextSpan> _incrementalLines(
    String trimmed,
    String? language,
    int configHash,
    _SpanStyles styles,
  ) {
    if (trimmed.isEmpty) {
      return <TextSpan>[];
    }

    // `trimmed` never ends with '\n' (trimRight), so the tail line is always
    // non-empty and `completed` always ends at a line boundary.
    final lastNewline = trimmed.lastIndexOf('\n');
    final completed =
        lastNewline == -1 ? '' : trimmed.substring(0, lastNewline + 1);
    final tail = trimmed.substring(lastNewline + 1);

    var state = _findState(configHash, trimmed);
    if (state == null) {
      state = _StreamState(configHash);
      _streamStates.add(state);
      if (_streamStates.length > maxStreamStates) {
        _streamStates.removeAt(0);
      }
    }

    // The matched state's prefix ends at a line boundary and is a prefix of
    // `trimmed`, so it is always a prefix of `completed` as well.
    if (completed.length > state.prefix.length) {
      final delta = completed.substring(state.prefix.length);
      if (!_extendState(state, delta, language, styles)) {
        // Continuation could not reproduce the source; rebuild from scratch.
        state.reset();
        if (!_extendState(state, completed, language, styles)) {
          state.reset();
          _extendStatePlain(state, completed, styles.base);
        }
      }
    }

    return <TextSpan>[
      ...state.lineSpans,
      if (tail.isNotEmpty)
        _tailLineSpan(tail, language, state.continuation, styles),
    ];
  }

  /// Finds the stream state with the longest prefix of [trimmed], if any.
  _StreamState? _findState(int configHash, String trimmed) {
    _StreamState? best;
    var bestIndex = -1;
    for (var index = 0; index < _streamStates.length; index += 1) {
      final state = _streamStates[index];
      if (state.configHash != configHash) {
        continue;
      }
      if (!trimmed.startsWith(state.prefix)) {
        continue;
      }
      if (best == null || state.prefix.length > best.prefix.length) {
        best = state;
        bestIndex = index;
      }
    }
    if (best != null) {
      // Move to the end to approximate LRU semantics.
      _streamStates
        ..removeAt(bestIndex)
        ..add(best);
    }
    return best;
  }

  /// Parses [source] (which always ends with '\n') as a continuation of
  /// [state], appending one span per completed line. Returns false when the
  /// parse fails or does not losslessly reproduce [source].
  bool _extendState(
    _StreamState state,
    String source,
    String? language,
    _SpanStyles styles,
  ) {
    assert(source.endsWith('\n'), 'extend chunks must end at a line boundary');
    if (language == null || !hi.hljs.hasLanguage(language)) {
      _extendStatePlain(state, source, styles.base);
      return true;
    }
    final hi.HighlightResult result;
    try {
      result = hi.hljs.highlight(
        source,
        language: language,
        continuation: state.continuation,
      );
    } catch (_) {
      return false;
    }

    final runs = _flattenNodes(result.emitter.root, styles);
    if (runs.map((run) => run.text).join() != source) {
      return false;
    }

    final lineRuns = _splitRunsIntoLines(runs);
    // `source` ends with '\n', producing an empty trailing segment; drop it.
    lineRuns.removeLast();
    for (final line in lineRuns) {
      state.lineSpans.add(_lineSpan(line, styles.base));
    }
    state.prefix += source;
    state.continuation = result.continuation;
    return true;
  }

  /// Fallback: appends unhighlighted lines for [source] (ends with '\n').
  void _extendStatePlain(_StreamState state, String source, TextStyle base) {
    final segments = source.split('\n')..removeLast();
    for (final segment in segments) {
      state.lineSpans.add(TextSpan(text: segment, style: base));
    }
    state.prefix += source;
    state.continuation = null;
  }

  /// Highlights the trailing partial line. Does not mutate stream state:
  /// the tail is re-highlighted on every append until its line completes.
  TextSpan _tailLineSpan(
    String tail,
    String? language,
    hi.HighlightContinuation? continuation,
    _SpanStyles styles,
  ) {
    if (language == null || !hi.hljs.hasLanguage(language)) {
      return TextSpan(text: tail, style: styles.base);
    }
    try {
      final result = hi.hljs.highlight(
        tail,
        language: language,
        continuation: continuation,
      );
      final runs = _flattenNodes(result.emitter.root, styles);
      if (runs.map((run) => run.text).join() == tail) {
        return _lineSpan(runs, styles.base);
      }
    } catch (_) {
      // Fall through to plain text.
    }
    return TextSpan(text: tail, style: styles.base);
  }

  /// Whole-text parse with language auto-detection (non-incremental).
  List<TextSpan> _autoDetectLines(String trimmed, _SpanStyles styles) {
    if (trimmed.isEmpty) {
      return <TextSpan>[];
    }
    try {
      final result = hi.hljs.highlightAuto(trimmed);
      final runs = _flattenNodes(result.emitter.root, styles);
      if (runs.map((run) => run.text).join() == trimmed) {
        return _splitRunsIntoLines(runs)
            .map((line) => _lineSpan(line, styles.base))
            .toList();
      }
    } catch (_) {
      // Fall through to plain text.
    }
    return trimmed
        .split('\n')
        .map((line) => TextSpan(text: line, style: styles.base))
        .toList();
  }

  /// Preserves trailing whitespace that isn't purely newlines, matching the
  /// previous behavior of appending it unhighlighted. Trailing whitespace
  /// segments after a newline become their own (blank) display lines.
  void _appendTrailingWhitespace(
    List<TextSpan> lines,
    String trailing,
    TextStyle base,
  ) {
    if (trailing.isEmpty) {
      return;
    }
    final hasNonNewline = trailing.codeUnits.any(
      (unit) => unit != 0x0A && unit != 0x0D,
    );
    if (!hasNonNewline) {
      return;
    }
    final segments = trailing.replaceAll('\r', '').split('\n');
    final first = segments.removeAt(0);
    if (first.isNotEmpty) {
      if (lines.isEmpty) {
        lines.add(TextSpan(text: first, style: base));
      } else {
        final last = lines.removeLast();
        lines.add(
          TextSpan(
            style: base,
            children: [last, TextSpan(text: first, style: base)],
          ),
        );
      }
    }
    for (final segment in segments) {
      lines.add(TextSpan(text: segment, style: base));
    }
  }

  /// Flattens a highlight token tree into style-resolved text runs.
  List<_Run> _flattenNodes(hi.DataNode root, _SpanStyles styles) {
    final runs = <_Run>[];
    _appendRuns(root, styles.base, styles, runs);
    return runs;
  }

  void _appendRuns(
    hi.DataNode node,
    TextStyle parentStyle,
    _SpanStyles styles,
    List<_Run> out,
  ) {
    final style = _resolveStyle(parentStyle, node.scope, styles);
    for (final child in node.children) {
      if (child is String) {
        if (child.isNotEmpty) {
          out.add(_Run(child, style));
        }
      } else if (child is hi.DataNode) {
        _appendRuns(child, style, styles, out);
      }
    }
  }

  TextStyle _resolveStyle(
    TextStyle parent,
    String? className,
    _SpanStyles styles,
  ) {
    if (className == null || className.startsWith('language:')) {
      return parent;
    }
    // Modern grammars use hierarchical scopes such as title.function and
    // variable.language. Prefer exact styles, then the nearest ancestor so
    // existing themes with only title/variable remain useful.
    var scope = className;
    while (true) {
      final themed = styles.theme[scope];
      if (themed != null) {
        return parent.merge(themed);
      }
      final dot = scope.lastIndexOf('.');
      if (dot == -1) break;
      scope = scope.substring(0, dot);
    }
    // Unthemed scopes nested inside a themed one (e.g. string interpolation
    // `subst` inside `string`) keep the enclosing colour, as in browser
    // highlight.js CSS. Only top-level unthemed scopes use the fallback.
    if (identical(parent, styles.base)) return parent.merge(styles.fallback);
    return parent;
  }

  /// Splits runs at newlines into per-line run lists. A trailing '\n'
  /// produces a final empty line entry.
  List<List<_Run>> _splitRunsIntoLines(List<_Run> runs) {
    final lines = <List<_Run>>[<_Run>[]];
    for (final run in runs) {
      var text = run.text;
      while (true) {
        final newline = text.indexOf('\n');
        if (newline == -1) {
          if (text.isNotEmpty) {
            lines.last.add(_Run(text, run.style));
          }
          break;
        }
        if (newline > 0) {
          lines.last.add(_Run(text.substring(0, newline), run.style));
        }
        lines.add(<_Run>[]);
        text = text.substring(newline + 1);
      }
    }
    return lines;
  }

  /// Builds a single-line span, merging adjacent runs with equal styles.
  TextSpan _lineSpan(List<_Run> runs, TextStyle base) {
    if (runs.isEmpty) {
      return TextSpan(text: '', style: base);
    }
    final children = <TextSpan>[];
    var pendingText = StringBuffer(runs.first.text);
    var pendingStyle = runs.first.style;
    for (var index = 1; index < runs.length; index += 1) {
      final run = runs[index];
      if (identical(run.style, pendingStyle) || run.style == pendingStyle) {
        pendingText.write(run.text);
      } else {
        children
            .add(TextSpan(text: pendingText.toString(), style: pendingStyle));
        pendingText = StringBuffer(run.text);
        pendingStyle = run.style;
      }
    }
    children.add(TextSpan(text: pendingText.toString(), style: pendingStyle));
    if (children.length == 1) {
      return children.first;
    }
    return TextSpan(style: base, children: children);
  }

  int _themeHash(Map<String, TextStyle> theme) {
    if (theme.isEmpty) {
      return 0;
    }
    final keys = theme.keys.toList()..sort();
    return Object.hashAll(
      keys.map((key) => Object.hash(key, theme[key]?.hashCode ?? 0)),
    );
  }

  String _normalizeTabs(String input, int tabSize) {
    if (!input.contains('\t') || tabSize <= 0) {
      return input;
    }
    final replacement = ' ' * tabSize;
    return input.replaceAll('\t', replacement);
  }
}

class _SpanStyles {
  const _SpanStyles({
    required this.base,
    required this.theme,
    required this.fallback,
  });

  final TextStyle base;
  final Map<String, TextStyle> theme;
  final TextStyle fallback;
}

class _Run {
  const _Run(this.text, this.style);

  final String text;
  final TextStyle style;
}

/// Incremental highlight state for one streaming code block.
class _StreamState {
  _StreamState(this.configHash);

  final int configHash;

  /// Text highlighted so far. Empty, or ends with '\n' (a line boundary).
  String prefix = '';

  /// One span per completed line in [prefix].
  final List<TextSpan> lineSpans = [];

  /// Parser state after [prefix]; input to the next continuation parse.
  hi.HighlightContinuation? continuation;

  void reset() {
    prefix = '';
    lineSpans.clear();
    continuation = null;
  }
}

class _CacheKey {
  const _CacheKey({
    required this.code,
    required this.complete,
    required this.trailing,
    required this.language,
    required this.autoDetect,
    required this.themeHash,
    required this.baseStyleHash,
    required this.fallbackHash,
    required this.tabSize,
  });

  final String code;
  final bool complete;
  final String trailing;
  final String? language;
  final bool autoDetect;
  final int themeHash;
  final int baseStyleHash;
  final int fallbackHash;
  final int tabSize;

  bool sameConfiguration(_CacheKey other) =>
      language == other.language &&
      autoDetect == other.autoDetect &&
      themeHash == other.themeHash &&
      baseStyleHash == other.baseStyleHash &&
      fallbackHash == other.fallbackHash &&
      tabSize == other.tabSize;

  @override
  int get hashCode => Object.hash(
        code,
        complete,
        trailing,
        language,
        autoDetect,
        themeHash,
        baseStyleHash,
        fallbackHash,
        tabSize,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _CacheKey) return false;
    return complete == other.complete &&
        code == other.code &&
        trailing == other.trailing &&
        language == other.language &&
        autoDetect == other.autoDetect &&
        themeHash == other.themeHash &&
        baseStyleHash == other.baseStyleHash &&
        fallbackHash == other.fallbackHash &&
        tabSize == other.tabSize;
  }
}

Future<HighlightScopeRuns> _highlightInIsolate(String text, String language) =>
    Isolate.run(() => highlightScopeRuns(text, language));
