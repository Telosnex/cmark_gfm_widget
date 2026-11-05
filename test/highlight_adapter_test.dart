import 'dart:async';

import 'package:cmark_gfm_widget/src/highlight/highlight_adapter.dart';
import 'package:highlight_fork/highlight.dart' as hi;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

const _theme = <String, TextStyle>{
  'root': TextStyle(color: Color(0xFFABB2BF)),
  'keyword': TextStyle(color: Color(0xFFC678DD)),
  'string': TextStyle(color: Color(0xFF98C379)),
  'comment': TextStyle(color: Color(0xFF5C6370), fontStyle: FontStyle.italic),
  'number': TextStyle(color: Color(0xFFD19A66)),
  'title': TextStyle(color: Color(0xFF61AFEF)),
  'built_in': TextStyle(color: Color(0xFFE6C07B)),
  'tag': TextStyle(color: Color(0xFFE06C75)),
  'name': TextStyle(color: Color(0xFF56B6C2)),
  'attr': TextStyle(color: Color(0xFFBE5046)),
};

const _base = TextStyle(fontFamily: 'monospace', fontSize: 14);

HighlightedCodeLines _build(
  HighlightAdapter adapter,
  String code,
  String? language, {
  bool complete = false,
  Object? blockKey,
}) {
  return adapter.buildLines(
    code: code,
    baseStyle: _base,
    theme: _theme,
    autoDetectLanguage: false,
    language: language,
    fallbackStyle: _base,
    tabSize: 2,
    complete: complete,
    blockKey: blockKey,
  );
}

/// Flattens line spans into comparable (text, style) runs per line.
List<List<(String, TextStyle?)>> _flatten(HighlightedCodeLines highlighted) {
  List<(String, TextStyle?)> flattenSpan(InlineSpan span) {
    final runs = <(String, TextStyle?)>[];
    span.visitChildren((child) {
      if (child is TextSpan && child.text != null && child.text!.isNotEmpty) {
        runs.add((child.text!, child.style));
      }
      return true;
    });
    return runs;
  }

  return highlighted.lines.map(flattenSpan).toList();
}

String _plainText(HighlightedCodeLines highlighted) {
  return highlighted.lines.map((line) => line.toPlainText()).join('\n');
}

/// Streams [code] into [adapter] in chunks of [chunkSize], returning the
/// final result.
HighlightedCodeLines _stream(
  HighlightAdapter adapter,
  String code,
  String? language, {
  int chunkSize = 3,
}) {
  HighlightedCodeLines? result;
  for (var end = 1; end <= code.length; end += chunkSize) {
    final upper = end > code.length ? code.length : end;
    result = _build(adapter, code.substring(0, upper), language);
  }
  // Ensure the final full text was built.
  result = _build(adapter, code, language);
  return result;
}

/// Compare effective styles per character, independent of token run boundaries.
List<(String, TextStyle?)> _characters(HighlightedCodeLines value) => [
      for (final line in _flatten(value)) ...[
        for (final (text, style) in line)
          for (final character in text.split('')) (character, style),
        ('\n', null),
      ],
    ];

List<(String, TextStyle?)> _fullParseCharacters(String code, String language) {
  hi.ensureInitialized();
  final base = _base.merge(_theme['root']);
  final result = <(String, TextStyle?)>[];
  void visit(hi.DataNode node, TextStyle inherited) {
    final scope = node.scope;
    TextStyle? tokenStyle;
    if (scope != null) {
      var name = scope;
      while (true) {
        tokenStyle = _theme[name];
        if (tokenStyle != null || !name.contains('.')) break;
        name = name.substring(0, name.lastIndexOf('.'));
      }
    }
    final style = tokenStyle == null ? inherited : inherited.merge(tokenStyle);
    for (final child in node.children) {
      if (child is String) {
        for (final character in child.split('')) {
          result.add((character, character == '\n' ? null : style));
        }
      } else if (child is hi.DataNode) {
        visit(child, style);
      }
    }
  }

  visit(hi.hljs.highlight(code, language: language).emitter.root, base);
  result.add(('\n', null));
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const dartCode = '''
/// Doc comment.
class Foo {
  /* multi
     line
     comment */
  final String bar = "hello \${world}";

  int add(int a, int b) {
    // line comment
    return a + b + 42;
  }
}''';

  const pythonCode = '''
def greet(name):
    """Docstring
    spanning lines."""
    total = 1 + 2.5
    return f"hello {name}"''';

  const jsCode = '''
const x = `template
spanning \${lines}`;
// trailing comment
function f() { return /re.?gex/; }''';

  const xmlCode = '''
<root attr="value">
  <!-- comment
       spanning lines -->
  <child>text</child>
</root>''';

  group('HighlightAdapter incremental highlighting', () {
    test('cross-line lookahead keeps provisional colors but loses no text', () {
      final adapter = HighlightAdapter();
      final partial = _build(adapter, 'hello\n(', 'javascript');
      const code = 'hello\n()';
      final completed = _build(adapter, code, 'javascript');

      expect(_plainText(completed), code);
      expect(identical(partial.lines.first, completed.lines.first), isTrue);
      expect(_flatten(completed).first.single.$2?.color,
          isNot(_theme['title']!.color));

      // A full parse can see the next line and retroactively classify hello.
      // Stable incremental lines deliberately do not promise that equivalence.
      final full = hi.hljs.highlight(code, language: 'javascript');
      expect(full.toHtml(),
          contains('<span class="hljs-title function_">hello</span>'));
    });

    test('unknown and absent languages remain unhighlighted', () {
      for (final language in <String?>['no-such-language', null]) {
        final result =
            _build(HighlightAdapter(), 'const value = "text";', language);
        expect(_flatten(result).single, hasLength(1));
        expect(_flatten(result).single.single.$2, result.baseStyle);
      }
    });

    test('modern dotted scopes fall back to their theme ancestor', () {
      final result =
          _build(HighlightAdapter(), 'function greet() {}', 'javascript');
      final titleRun = _flatten(result).single.singleWhere(
            (run) => run.$1 == 'greet',
          );
      expect(titleRun.$2?.color, _theme['title']!.color);
    });

    test('unthemed nested scopes inherit their enclosing theme color', () {
      // `${name}` is a `subst` scope (unthemed) inside a themed `string`.
      final result = _build(
        HighlightAdapter(),
        r'const s = `hi ${name}!`;',
        'javascript',
      );
      final runs = _flatten(result).single;
      final subst = runs.singleWhere((run) => run.$1.contains('name'));
      expect(subst.$2?.color, _theme['string']!.color);
      // Top-level plain text keeps the theme root color.
      final plain = runs.firstWhere((run) => run.$1.contains('s ='));
      expect(plain.$2?.color, _theme['root']!.color);
    });

    test('exact dotted theme scopes take precedence over ancestor styles', () {
      final result = HighlightAdapter().buildLines(
        code: 'function greet() {}',
        baseStyle: _base,
        theme: {
          ..._theme,
          'title.function': const TextStyle(color: Color(0xFF123456)),
        },
        autoDetectLanguage: false,
        language: 'javascript',
        fallbackStyle: _base,
        tabSize: 2,
      );
      final titleRun = _flatten(result).single.singleWhere(
            (run) => run.$1 == 'greet',
          );
      expect(titleRun.$2?.color, const Color(0xFF123456));
    });

    test('embedded languages retain their token styles', () {
      const code = '<script>const value = "hello";</script>';
      final result = _build(HighlightAdapter(), code, 'xml');
      expect(_plainText(result), code);
      final stringRun = _flatten(result).single.singleWhere(
            (run) => run.$1 == '"hello"',
          );
      expect(stringRun.$2?.color, _theme['string']!.color);
    });

    for (final (name, code, language) in [
      ('dart', dartCode, 'dart'),
      ('python', pythonCode, 'python'),
      ('javascript', jsCode, 'javascript'),
      ('xml', xmlCode, 'xml'),
      ('plaintext', dartCode, 'plaintext'),
      ('unknown language', dartCode, 'no-such-language'),
      ('null language', dartCode, null),
    ]) {
      test('streamed output matches one-shot output ($name)', () {
        final streamed = _stream(HighlightAdapter(), code, language);
        final oneShot = _build(HighlightAdapter(), code, language);

        expect(_plainText(streamed), code);
        expect(_plainText(oneShot), code);
        expect(_flatten(streamed), _flatten(oneShot));
      });
    }

    test('completed line spans are identical instances across appends', () {
      final adapter = HighlightAdapter();
      final first = _build(adapter, 'void main() {\n  print("hi");', 'dart');
      final second =
          _build(adapter, 'void main() {\n  print("hi");\n}', 'dart');
      final third =
          _build(adapter, 'void main() {\n  print("hi");\n}\n// done', 'dart');

      // Line 0 completed in the first build and must stay the same instance.
      expect(identical(first.lines[0], second.lines[0]), isTrue);
      expect(identical(second.lines[0], third.lines[0]), isTrue);
      // Line 1 completed in the second build.
      expect(identical(second.lines[1], third.lines[1]), isTrue);
      // Line 2 completed in the third build.
      expect(identical(second.lines[2], third.lines[2]), isFalse);
    });

    test('multi-line constructs keep continuation state across chunks', () {
      final adapter = HighlightAdapter();
      // Stream so the comment opener and closer arrive in separate builds.
      _build(adapter, '/* comment\n', 'dart');
      final result =
          _build(adapter, '/* comment\nstill comment\n*/ final x = 1;', 'dart');

      // The second line is inside the block comment and must be styled as one.
      final secondLineRuns = _flatten(result)[1];
      expect(secondLineRuns, hasLength(1));
      expect(secondLineRuns.single.$2?.color, _theme['comment']!.color);
    });

    test('non-append edits fall back to a correct full parse', () {
      final adapter = HighlightAdapter();
      _build(adapter, 'final a = 1;\nfinal b = 2;\n', 'dart');
      // Rewrite history: not an append of the previous text.
      const edited = 'const x = "y";\nconst z = 3;';
      final result = _build(adapter, edited, 'dart');
      final oneShot = _build(HighlightAdapter(), edited, 'dart');

      expect(_plainText(result), edited);
      expect(_flatten(result), _flatten(oneShot));
    });

    test('empty and whitespace-only code render a single empty line', () {
      final adapter = HighlightAdapter();
      expect(_build(adapter, '', 'dart').lines, hasLength(1));
      expect(_build(adapter, '\n\n', 'dart').lines, hasLength(1));
    });

    test('trailing whitespace after newline becomes its own line', () {
      final adapter = HighlightAdapter();
      final result = _build(adapter, 'a\n  ', 'dart');
      expect(result.lines, hasLength(2));
      expect(result.lines[0].toPlainText(), 'a');
      expect(result.lines[1].toPlainText(), '  ');
    });

    test('exact repeats are served from cache with identical instances', () {
      final adapter = HighlightAdapter();
      const code = 'final a = 1;\nfinal b = 2;';
      final first = _build(adapter, code, 'dart');
      final second = _build(adapter, code, 'dart');
      expect(identical(first, second), isTrue);
    });

    test('lines never contain newline characters', () {
      final result = _stream(HighlightAdapter(), dartCode, 'dart');
      for (final line in result.lines) {
        expect(line.toPlainText().contains('\n'), isFalse);
      }
    });
  });

  group('HighlightAdapter finalization', () {
    test('completion corrects JS lookahead and preserves unaffected lines', () {
      final adapter = HighlightAdapter();
      const code = 'const stable = 1;\nhello\n()';
      final provisional = _stream(adapter, code, 'javascript');
      final finalized = _build(adapter, code, 'javascript', complete: true);
      final fresh =
          _build(HighlightAdapter(), code, 'javascript', complete: true);

      expect(_characters(finalized), _fullParseCharacters(code, 'javascript'));
      expect(_characters(finalized), _characters(fresh));
      expect(_characters(provisional), isNot(_characters(finalized)));
      expect(identical(provisional.lines[0], finalized.lines[0]), isTrue);
      expect(identical(provisional.lines[1], finalized.lines[1]), isFalse);
      expect(_plainText(finalized), code);
      expect(
          identical(
              finalized, _build(adapter, code, 'javascript', complete: true)),
          isTrue);
    });

    for (final (name, language, code) in [
      ('YAML block scalar', 'yaml', 'message: |\n  hello\n  world\nnext: true'),
      ('JSX embedded markup', 'javascript', '<Tag>\n</Tag>'),
      ('JS cross-line call', 'javascript', 'hello\n()'),
    ]) {
      test('$name finalizes to the actual whole-text parse', () {
        final adapter = HighlightAdapter();
        final provisional = _stream(adapter, code, language, chunkSize: 1);
        final finalized = _build(adapter, code, language, complete: true);
        expect(_plainText(finalized), code);
        // The YAML scalar and cross-line call require recoloring. JSX may
        // already agree, but still exercises the requested full-parse path.
        if (language != 'javascript' || code == 'hello\n()') {
          expect(_characters(provisional), isNot(_characters(finalized)));
        }
        expect(_characters(finalized), _fullParseCharacters(code, language));
      });
    }

    test('no-change finalization reuses every line instance', () {
      final adapter = HighlightAdapter();
      const code = 'const x = 1;\nconst y = "hello";';
      final provisional = _build(adapter, code, 'javascript');
      final finalized = _build(adapter, code, 'javascript', complete: true);
      expect(_characters(finalized), _characters(provisional));
      for (var i = 0; i < provisional.lines.length; i++) {
        expect(identical(provisional.lines[i], finalized.lines[i]), isTrue);
      }
    });

    test('never-streamed complete blocks use whole-text lookahead', () {
      const code = 'hello\n()';
      final finalized =
          _build(HighlightAdapter(), code, 'javascript', complete: true);
      expect(_characters(finalized), _fullParseCharacters(code, 'javascript'));
      expect(
          _flatten(finalized).first.single.$2?.color, _theme['title']!.color);
    });

    test('append retains corrected JS completed-line span instances', () {
      final adapter = HighlightAdapter();
      const initial = 'hello\n()';
      final provisional = _stream(adapter, initial, 'javascript');
      final finalized = _build(adapter, initial, 'javascript', complete: true);
      expect(_characters(provisional), isNot(_characters(finalized)));
      const appended = '$initial\nconst answer = 42;';
      final streamed = _build(adapter, appended, 'javascript');
      expect(_plainText(streamed), appended);
      expect(identical(streamed.lines[0], finalized.lines[0]), isTrue);
      expect(
          _characters(streamed), _fullParseCharacters(appended, 'javascript'));
    });

    test('append after finalization resumes the incremental continuation', () {
      final adapter = HighlightAdapter();
      const initial = '/* comment\nstill comment';
      _build(adapter, initial, 'javascript');
      _build(adapter, initial, 'javascript', complete: true);
      const appended = '$initial\n*/ const answer = 42;';
      final streamed = _build(adapter, appended, 'javascript');
      expect(_plainText(streamed), appended);
      expect(_flatten(streamed)[1].single.$2?.color, _theme['comment']!.color);
      final finalized = _build(adapter, appended, 'javascript', complete: true);
      expect(
          _characters(finalized), _fullParseCharacters(appended, 'javascript'));
    });

    test(
        'large finalization returns provisional spans then notifies correction',
        () async {
      final adapter = HighlightAdapter();
      addTearDown(adapter.dispose);
      final code = '${'const stable = 1;\n' * 300}hello\n()';
      expect(code.length,
          greaterThan(HighlightAdapter.asyncFinalizationThreshold));
      final provisional = _build(adapter, code, 'javascript');
      final notification = Completer<void>();
      adapter.addListener(() {
        if (!notification.isCompleted) notification.complete();
      });
      final initial = _build(adapter, code, 'javascript', complete: true);
      expect(_characters(initial), _characters(provisional));
      await notification.future.timeout(const Duration(seconds: 30));
      final corrected = _build(adapter, code, 'javascript', complete: true);
      expect(_characters(corrected), _fullParseCharacters(code, 'javascript'));
      expect(_characters(initial), isNot(_characters(corrected)));
      expect(identical(initial.lines.first, corrected.lines.first), isTrue);
    });

    test('replaced and released block requests discard in-flight results',
        () async {
      final adapter = HighlightAdapter();
      addTearDown(adapter.dispose);
      final block = Object();
      final code = '${'const stable = 1;\n' * 300}hello\n()';
      var notifications = 0;
      adapter.addListener(() => notifications++);
      _build(adapter, code, 'javascript', complete: true, blockKey: block);
      _build(adapter, 'const replacement = 2;', 'javascript', blockKey: block);
      // A second request verifies disposal independently of text replacement.
      final released = Object();
      _build(adapter, '$code;', 'javascript',
          complete: true, blockKey: released);
      adapter.releaseBlock(released);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(notifications, 0);
      expect(
          _plainText(_build(adapter, 'const replacement = 2;', 'javascript',
              blockKey: block)),
          'const replacement = 2;');
    });

    test('adapter disposal safely drops a pending async correction', () async {
      final adapter = HighlightAdapter();
      final code = '${'const stable = 1;\n' * 300}hello\n()';
      var notifications = 0;
      adapter.addListener(() => notifications++);
      _build(adapter, code, 'javascript', complete: true, blockKey: Object());
      adapter.dispose();
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(notifications, 0);
    });
  });
}
