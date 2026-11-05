import 'dart:async';
import 'dart:convert';

import 'package:cmark_gfm_widget/cmark_gfm_widget.dart';
import 'package:cmark_gfm_widget/src/highlight/highlight_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_snap_fork/material.dart';

const _base = TextStyle();
const _theme = {'title.function': TextStyle(color: Color(0xFF123456))};

HighlightedCodeLines _build(HighlightAdapter adapter, String code,
        {Object? blockKey, bool complete = true}) =>
    adapter.buildLines(
      code: code,
      baseStyle: _base,
      theme: _theme,
      autoDetectLanguage: false,
      language: 'javascript',
      fallbackStyle: _base,
      tabSize: 2,
      complete: complete,
      blockKey: blockKey,
    );

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('public scope runs are lossless and JSON serializable', () {
    const code = 'const x = `hello \${world}`;\r\n\t';
    final runs = highlightScopeRuns(code, 'javascript');
    expect(runs.map((run) => run[0]).join(), code);
    expect(jsonDecode(jsonEncode(runs)), runs);
    expect(runs.every((run) => run.length == 2), isTrue);
    expect(highlightScopeRuns(code, 'unknown-language'), [
      [code, '']
    ]);
    expect(highlightScopeRuns('', 'javascript'), isEmpty);
  });

  test('hook is used at and above threshold, not below or while streaming',
      () async {
    final calls = <String>[];
    final adapter = HighlightAdapter(
      highlightOffloadThreshold: 12,
      highlightOffload: (code, language) async {
        expect(language, 'javascript');
        calls.add(code);
        return highlightScopeRuns(code, language);
      },
    );
    addTearDown(adapter.dispose);
    _build(adapter, 'hello\n()');
    _build(adapter, 'const x = 1;'); // Exactly 12 UTF-16 code units.
    _build(adapter, 'const xx = 1;');
    _build(adapter, 'const streaming = 1;', complete: false);
    expect(calls, ['const x = 1;', 'const xx = 1;']);
    await _flush();
  });

  test('threshold zero always offloads, including empty input', () async {
    final calls = <String>[];
    final adapter = HighlightAdapter(
      highlightOffloadThreshold: 0,
      highlightOffload: (code, language) async {
        calls.add(code);
        return highlightScopeRuns(code, language);
      },
    );
    addTearDown(adapter.dispose);
    _build(adapter, 'x');
    _build(adapter, '');
    expect(calls, ['x', '']);
    await _flush();
  });

  test('null threshold always parses synchronously', () {
    final adapter = HighlightAdapter(
      highlightOffloadThreshold: null,
      highlightOffload: (_, __) => throw StateError('must not run'),
    );
    addTearDown(adapter.dispose);
    var notifications = 0;
    adapter.addListener(() => notifications++);
    _build(adapter, '${'const x = 1;\n' * 200}hello\n()');
    expect(notifications, 0);
  });

  for (final synchronousThrow in [true, false]) {
    test(
        'hook ${synchronousThrow ? 'throw' : 'failed future'} falls back to sync',
        () async {
      final adapter = HighlightAdapter(
        highlightOffloadThreshold: 0,
        highlightOffload: (_, __) {
          if (synchronousThrow) throw StateError('worker failed');
          return Future.error(StateError('worker failed'));
        },
      );
      final sync = HighlightAdapter(highlightOffloadThreshold: null);
      addTearDown(adapter.dispose);
      addTearDown(sync.dispose);
      var notifications = 0;
      adapter.addListener(() => notifications++);
      const code = 'hello\n()';
      _build(adapter, code);
      await _flush();
      expect(notifications, 1);
      expect(_build(adapter, code).lines, _build(sync, code).lines);
    });
  }

  for (final action in ['replace', 'release', 'dispose']) {
    test('stale hook result discarded on $action', () async {
      final pending = Completer<HighlightScopeRuns>();
      var calls = 0;
      final adapter = HighlightAdapter(
        highlightOffloadThreshold: 0,
        highlightOffload: (_, __) {
          calls++;
          return pending.future;
        },
      );
      var notifications = 0;
      adapter.addListener(() => notifications++);
      final block = Object();
      _build(adapter, 'hello\n()', blockKey: block);
      if (action == 'replace') {
        _build(adapter, 'replacement', blockKey: block, complete: false);
      } else if (action == 'release') {
        adapter.releaseBlock(block);
      } else {
        adapter.dispose();
      }
      pending.complete(highlightScopeRuns('hello\n()', 'javascript'));
      await _flush();
      expect(notifications, 0);
      if (action != 'dispose') {
        // The provisional cache entry must also have been invalidated.
        _build(adapter, 'hello\n()', blockKey: block);
        expect(calls, 2);
        await _flush();
        adapter.dispose();
      }
    });
  }

  test('theme copyWith preserves or explicitly disables threshold', () {
    final config = CodeHighlightTheme(
      highlightOffload: (code, language) async =>
          highlightScopeRuns(code, language),
      highlightOffloadThreshold: 0,
    );
    expect(config.copyWith().highlightOffloadThreshold, 0);
    expect(config.copyWith().highlightOffload, same(config.highlightOffload));
    expect(
        config
            .copyWith(highlightOffloadThreshold: null)
            .highlightOffloadThreshold,
        isNull);
  });
}
