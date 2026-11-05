import 'package:cmark_gfm_dart/cmark_gfm_dart.dart';
import 'package:flutter/widgets.dart';

import '../theme/cmark_theme.dart';

/// Lays out sibling blocks with [spacing] between them and none after the
/// last one. [nodes] are the blocks' nodes, in the same order as
/// [children]; with heading or lead-in spacing in [theme], each gap is
/// [CmarkThemeData.spacingBetween].
///
/// With [tight], the blocks are those of an item in a tight list. As in a
/// browser, its text then has no space above or below a list: a sublist
/// sits right under the text of its item. Other blocks, such as a code
/// block, keep their spacing.
///
/// Without node or tight spacing, this is a [Column] with [spacing]. With
/// it, every gap is a [SizedBox] between two blocks, so that the blocks
/// keep their positions in the column when a heading streams in.
Widget spacedBlockColumn({
  required CmarkThemeData theme,
  required List<Widget> children,
  required List<CmarkNode?>? nodes,
  required double spacing,
  bool tight = false,
}) {
  assert(nodes == null || nodes.length == children.length);
  if (nodes == null || !(theme.hasNodeSpacing || tight)) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: spacing,
      children: children,
    );
  }
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0)
          SizedBox(
            height: tight && _isTightPair(nodes[i - 1], nodes[i])
                ? 0
                : theme.spacingBetween(nodes[i - 1], nodes[i], spacing),
          ),
        children[i],
      ],
    ],
  );
}

/// Whether one of [above] and [below] is a paragraph and the other a list,
/// so in a tight list item they have no space between them.
bool _isTightPair(CmarkNode? above, CmarkNode? below) {
  final types = {above?.type, below?.type};
  return types.length == 2 &&
      types.contains(CmarkNodeType.paragraph) &&
      types.contains(CmarkNodeType.list);
}
