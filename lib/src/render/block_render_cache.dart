import 'package:cmark_gfm_dart/cmark_gfm_dart.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';

import '../parser/document_snapshot.dart';
import '../theme/cmark_theme.dart';
import 'block_renderers.dart' show BlockRenderResult;
import 'details_grouping.dart';
import 'render_pipeline.dart' show RenderOptions, RenderPipeline;

/// Keeps the widgets from the last [RenderPipeline.render] call, so blocks
/// that did not change keep their widget instances.
///
/// Flutter does not rebuild a child whose widget is the same instance as in
/// the last frame. While a document streams, only its last blocks change, so
/// the other blocks skip rendering, building and layout.
///
/// A block keeps its widget when it has the same ID as a block of the last
/// render, its node has the same content ([CmarkNode.contentEquals]), and it
/// gets the same leading spans. The cache is cleared when the theme or the
/// render's `cacheKey` changes.
///
/// The blocks in a `<details>` section are cached one by one, as top-level
/// blocks are. The section keeps its widget when its blocks all kept
/// theirs.
///
/// Builders in [RenderOptions] are not called for a block that keeps its
/// widget. Their output must depend only on the node they get and on values
/// in `cacheKey`. A builder that needs changing data, such as footnote
/// sources that stream in, can return a widget that reads the data from an
/// [InheritedWidget].
class BlockRenderCache {
  CmarkThemeData? _theme;
  Object? _key;
  Map<String, _CachedBlock> _blocks = const {};
  Map<String, _CachedDetails> _details = const {};

  /// Removes all rendered blocks.
  void clear() {
    _blocks = const {};
    _details = const {};
  }
}

class _CachedBlock {
  const _CachedBlock(this.node, this.leadingSpans, this.result, this.complete);

  final CmarkNode node;
  final List<InlineSpan> leadingSpans;
  final BlockRenderResult result;
  final bool complete;
}

class _CachedDetails {
  const _CachedDetails(this.parts, this.result);

  final DetailsRenderParts parts;
  final BlockRenderResult result;
}

/// A `<details>` section for [renderTopLevelBlocks] to build.
class DetailsRenderParts {
  const DetailsRenderParts({
    required this.opener,
    required this.summaryText,
    required this.initiallyOpen,
    required this.isComplete,
    required this.leadingSpans,
    required this.children,
  });

  /// The HTML block with the `<details>` tag.
  final CmarkNode opener;
  final String? summaryText;
  final bool initiallyOpen;
  final bool isComplete;

  /// Spans to show before the summary.
  final List<InlineSpan> leadingSpans;

  /// The rendered blocks in the section, with the ID and node of each.
  final List<BlockRenderResult> children;

  /// Whether a section built from [other] looks the same as one built from
  /// these parts.
  bool sameAs(DetailsRenderParts other) {
    if (summaryText != other.summaryText ||
        initiallyOpen != other.initiallyOpen ||
        isComplete != other.isComplete ||
        !listEquals(leadingSpans, other.leadingSpans) ||
        children.length != other.children.length) {
      return false;
    }
    for (var i = 0; i < children.length; i++) {
      final a = children[i];
      final b = other.children[i];
      if (a.id != b.id || !identical(a.widget, b.widget)) return false;
    }
    return true;
  }
}

/// Renders each top-level block of [snapshot] with [renderBlock], and keeps
/// the results of blocks that [cache] already has.
///
/// [renderBlock] gets the block and the leading spans for it, and returns
/// null for a block that shows nothing. Only the first shown block gets
/// [leadingSpans].
///
/// With [renderDetails], `<details>` sections are grouped (see
/// [groupDetails]), and each section is one result, which
/// [renderDetails] builds. Its ID and node are those of the `<details>`
/// HTML block.
List<BlockRenderResult> renderTopLevelBlocks(
  DocumentSnapshot snapshot,
  List<InlineSpan> leadingSpans, {
  required CmarkThemeData theme,
  required BlockRenderCache? cache,
  required Object? cacheKey,
  required Widget? Function(CmarkNode block, List<InlineSpan> leadingSpans)
      renderBlock,
  Widget Function(DetailsRenderParts parts)? renderDetails,
}) {
  var previous = const <String, _CachedBlock>{};
  var previousDetails = const <String, _CachedDetails>{};
  if (cache != null &&
      identical(theme, cache._theme) &&
      cacheKey == cache._key) {
    previous = cache._blocks;
    previousDetails = cache._details;
  }
  final next = <String, _CachedBlock>{};
  final nextDetails = <String, _CachedDetails>{};
  final streaming = snapshot.streamingEndLine != null;
  var remainingLeadingSpans = leadingSpans;
  var unnamed = 0;

  String idOf(CmarkNode block) =>
      DocumentSnapshot.metadataFor(block)?.id ?? 'block-${unnamed++}';

  BlockRenderResult? renderSingle(CmarkNode block) {
    final id = idOf(block);
    // A block that is last while streaming can still get content that its
    // renderer shows differently, such as the end of a `<details>` section
    // in a list item.
    final complete =
        snapshot.isBlockComplete(block) && !(streaming && block.next == null);
    var entry = previous[id];
    if (entry == null ||
        entry.complete != complete ||
        !listEquals(entry.leadingSpans, remainingLeadingSpans) ||
        !entry.node.contentEquals(block)) {
      final widget = renderBlock(block, remainingLeadingSpans);
      if (widget == null) return null;
      entry = _CachedBlock(
        block,
        remainingLeadingSpans,
        BlockRenderResult(id: id, widget: widget, node: block),
        complete,
      );
    }
    // Leading spans only go to the first shown block.
    remainingLeadingSpans = const [];
    next[id] = entry;
    return entry.result;
  }

  BlockRenderResult? renderItem(DetailsItem item) {
    switch (item) {
      case DetailsBlockItem(:final node):
        return renderSingle(node);
      case DetailsGroupItem():
        final openerId = idOf(item.opener);
        final id = item.indexInOpener == 0
            ? openerId
            : '$openerId~${item.indexInOpener}';
        // The summary is shown first, so it gets the leading spans.
        final spans = remainingLeadingSpans;
        remainingLeadingSpans = const [];
        final children = <BlockRenderResult>[];
        for (final child in item.children) {
          final result = renderItem(child);
          if (result != null) children.add(result);
        }
        final parts = DetailsRenderParts(
          opener: item.opener,
          summaryText: item.summaryText,
          initiallyOpen: item.initiallyOpen,
          isComplete: item.closer != null || !streaming,
          leadingSpans: spans,
          children: children,
        );
        var entry = previousDetails[id];
        if (entry == null || !entry.parts.sameAs(parts)) {
          entry = _CachedDetails(
            parts,
            BlockRenderResult(
              id: id,
              widget: renderDetails!(parts),
              node: item.opener,
            ),
          );
        }
        nextDetails[id] = entry;
        return entry.result;
    }
  }

  final results = <BlockRenderResult>[];
  if (renderDetails == null) {
    for (final block in snapshot.blocks) {
      final result = renderSingle(block);
      if (result != null) results.add(result);
    }
  } else {
    for (final item in groupDetails(snapshot.blocks)) {
      final result = renderItem(item);
      if (result != null) results.add(result);
    }
  }

  if (cache != null) {
    cache
      .._theme = theme
      .._key = cacheKey
      .._blocks = next
      .._details = nextDetails;
  }
  return results;
}
