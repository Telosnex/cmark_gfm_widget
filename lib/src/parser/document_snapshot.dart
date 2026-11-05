import 'package:cmark_gfm_dart/cmark_gfm_dart.dart';

import 'stable_id_registry.dart';

/// Immutable representation of a parsed Markdown document.
class DocumentSnapshot {
  DocumentSnapshot._({
    required this.root,
    required this.revision,
    this.streamingEndLine,
  });

  /// Root node of the document (always of type [CmarkNodeType.document]).
  final CmarkNode root;

  /// Snapshot revision (monotonic counter assigned by the controller).
  final int revision;

  /// Last parsed source line while streaming, or null for a finished document.
  ///
  /// The parser finalizes an open code block at this line. A block closed by
  /// a fence or by its container ends before it, so it is safe to recolor.
  final int? streamingEndLine;

  bool isCodeBlockComplete(CmarkNode node) =>
      streamingEndLine == null || node.endLine < streamingEndLine!;

  /// Whether every code block inside [node] is ready for final recoloring.
  bool isBlockComplete(CmarkNode node) {
    if (streamingEndLine == null) return true;
    if (node.type == CmarkNodeType.codeBlock) return isCodeBlockComplete(node);
    var child = node.firstChild;
    while (child != null && child.type.isBlock) {
      if (!isBlockComplete(child)) return false;
      child = child.next;
    }
    return true;
  }

  /// Returns an iterable of top-level block nodes.
  Iterable<CmarkNode> get blocks sync* {
    var node = root.firstChild;
    while (node != null) {
      yield node;
      node = node.next;
    }
  }

  /// Creates a snapshot from [root], assigning stable ids via [registry].
  ///
  /// Only the root and its top-level blocks get ids: the renderer keys
  /// blocks by them and nothing reads ids of nested nodes. Giving every node
  /// an id cost a hash and a map entry per node for each streamed snapshot.
  static DocumentSnapshot fromRoot({
    required CmarkNode root,
    required StableIdRegistry registry,
    required int revision,
    int? streamingEndLine,
  }) {
    root.userData = NodeMetadata(registry.idFor(root, revision));
    var block = root.firstChild;
    while (block != null) {
      block.userData = NodeMetadata(registry.idFor(block, revision));
      block = block.next;
    }
    registry.prune(revision - 1);
    return DocumentSnapshot._(
      root: root,
      revision: revision,
      streamingEndLine: streamingEndLine,
    );
  }

  /// Returns the metadata attached to [node], if present.
  static NodeMetadata? metadataFor(CmarkNode node) {
    final data = node.userData;
    if (data is NodeMetadata) {
      return data;
    }
    return null;
  }
}
