import 'package:cmark_gfm_dart/cmark_gfm_dart.dart';
import 'package:flutter/widgets.dart';

import '../render/block_spacing.dart';
import '../theme/cmark_theme.dart';
import 'streaming_reveal.dart';

/// Lays out the top-level blocks of a document, such as the widgets from
/// `RenderPipeline.render`.
///
/// It puts [CmarkThemeData.blockSpacing] between blocks and none after the
/// last one. With [nodes], the space around a heading or after a lead-in
/// follows the theme; see [CmarkThemeData.spacingBetween]. The renderers give
/// a block no space of its own, so use this widget, or the same spacing,
/// for any column of rendered blocks.
///
/// With [reveal], content that is added while the document streams fades in,
/// in reading order. See [CmarkStreamingReveal] and [CmarkRevealOrder].
class CmarkBlockColumn extends StatefulWidget {
  const CmarkBlockColumn({
    super.key,
    required this.theme,
    required this.children,
    this.nodes,
    this.reveal,
  }) : assert(nodes == null || nodes.length == children.length);

  /// The theme the blocks were rendered with.
  final CmarkThemeData theme;

  /// The rendered blocks, in document order.
  ///
  /// With [reveal], each block gets a [CmarkStreamingReveal] by its index.
  /// Do not key the blocks by content: a reveal keeps its state while its
  /// block's widget changes.
  final List<Widget> children;

  /// The top-level node of each of [children], such as
  /// `BlockRenderResult.node`. Without it, the theme's heading and lead-in
  /// spacing are not used: every gap is [CmarkThemeData.blockSpacing].
  final List<CmarkNode?>? nodes;

  /// Whether, and how, to fade in streamed content.
  ///
  /// A column that is first built while not streaming shows its blocks with
  /// no reveal, so that a finished document costs nothing. When
  /// [CmarkRevealOptions.streaming] becomes true, every block gets a reveal.
  /// The reveals stay after streaming ends, so that a fade in progress
  /// finishes.
  ///
  /// When the reveals are added, the blocks that are there are shown at
  /// once, except the last one, which may still be streaming. Blocks that
  /// are added later fade in.
  ///
  /// The reveals share one [CmarkRevealOrder]: a block starts to fade in
  /// when the blocks before it are revealed.
  final CmarkRevealOptions? reveal;

  @override
  State<CmarkBlockColumn> createState() => _CmarkBlockColumnState();
}

class _CmarkBlockColumnState extends State<CmarkBlockColumn> {
  final _order = CmarkRevealOrder();
  bool _revealing = false;
  bool _builtWithReveals = false;

  @override
  Widget build(BuildContext context) {
    final reveal = widget.reveal;
    if (reveal == null) {
      _revealing = false;
    } else if (reveal.streaming) {
      _revealing = true;
    }
    var children = widget.children;
    if (_revealing && reveal != null) {
      final animateAll = _builtWithReveals;
      _builtWithReveals = true;
      final last = children.length - 1;
      children = [
        for (var i = 0; i < children.length; i++)
          CmarkStreamingReveal(
            streaming: reveal.streaming,
            animateIn: animateAll || i == last,
            style: reveal.styleAt(i),
            fadeDuration: reveal.fadeDuration,
            catchUpDuration: reveal.catchUpDuration,
            minCharactersPerSecond: reveal.minCharactersPerSecond,
            order: _order,
            index: i,
            child: children[i],
          ),
      ];
    } else {
      _builtWithReveals = false;
    }
    return spacedBlockColumn(
      theme: widget.theme,
      children: children,
      nodes: widget.nodes,
      spacing: widget.theme.blockSpacing,
    );
  }
}
