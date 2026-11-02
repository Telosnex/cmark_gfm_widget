import 'package:cmark_gfm_dart/cmark_gfm_dart.dart';

import 'document_snapshot.dart';
import 'stable_id_registry.dart';
import 'streaming_text.dart';

/// High-level controller that coordinates parsing and snapshot creation.
class ParserController {
  ParserController({
    StableIdRegistry? registry,
    CmarkParserOptions parserOptions = const CmarkParserOptions(),
  })  : _registry = registry ?? StableIdRegistry(),
        _parserOptions = parserOptions;

  final StableIdRegistry _registry;
  final CmarkParserOptions _parserOptions;
  int _revision = 0;

  /// Parses [data] and returns a fresh [DocumentSnapshot].
  ///
  /// If [streaming], [data] is a stream that has not ended, and a last line
  /// that can change the block before it is left out. See
  /// [cmarkStreamingParseLength].
  DocumentSnapshot parse(String data, {bool streaming = false}) {
    final parser = CmarkParser(options: _parserOptions);
    parser.feed(
      streaming ? data.substring(0, cmarkStreamingParseLength(data)) : data,
    );
    final root = parser.finish();
    _revision += 1;
    return DocumentSnapshot.fromRoot(
      root: root,
      registry: _registry,
      revision: _revision,
    );
  }

  /// Parses a sequence of [chunks], useful for streaming input.
  ///
  /// If [streaming], the chunks are a stream that has not ended. See
  /// [parse].
  DocumentSnapshot parseChunks(
    Iterable<String> chunks, {
    bool streaming = false,
  }) {
    if (streaming) return parse(chunks.join(), streaming: true);
    final parser = CmarkParser(options: _parserOptions);
    for (final chunk in chunks) {
      parser.feed(chunk);
    }
    final root = parser.finish();
    _revision += 1;
    return DocumentSnapshot.fromRoot(
      root: root,
      registry: _registry,
      revision: _revision,
    );
  }
}
