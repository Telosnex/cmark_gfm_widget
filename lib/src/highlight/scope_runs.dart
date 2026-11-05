import 'package:highlight_fork/highlight.dart' as hi;

/// Serializable token runs, each containing `[text, scopePath]`.
/// The scope path contains enclosing scopes separated by spaces; an empty path
/// means unscoped text. No Flutter objects cross the worker boundary.
typedef HighlightScopeRuns = List<List<String>>;

/// An optional worker-backed whole-text parser. If it throws, the adapter falls
/// back to synchronous parsing on the calling isolate.
typedef HighlightOffload = Future<HighlightScopeRuns> Function(
    String code, String language);

/// Losslessly highlights [text] without normalizing tabs, CRLF or whitespace.
/// Unknown languages and parse failures produce a single unscoped run.
/// Safe to call in a worker: the highlight runtime initializes per isolate.
HighlightScopeRuns highlightScopeRuns(String text, String language) {
  hi.ensureInitialized();
  if (text.isEmpty) return [];
  if (!hi.hljs.hasLanguage(language)) {
    return [
      [text, '']
    ];
  }
  try {
    final root = hi.hljs.highlight(text, language: language).emitter.root;
    final runs = <List<String>>[];
    void visit(hi.DataNode node, List<String> parents) {
      final scopes = [
        ...parents,
        if (node.scope != null) node.scope!,
      ];
      for (final child in node.children) {
        if (child is String && child.isNotEmpty) {
          runs.add([child, scopes.join(' ')]);
        } else if (child is hi.DataNode) {
          visit(child, scopes);
        }
      }
    }

    visit(root, []);
    if (runs.map((run) => run[0]).join() == text) return runs;
  } catch (_) {
    // Unknown grammars or parser failures remain lossless plain text.
  }
  return [
    [text, '']
  ];
}
