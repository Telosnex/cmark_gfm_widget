import 'package:cmark_gfm_dart/cmark_gfm_dart.dart';
import 'package:flutter/widgets.dart';

import '../theme/cmark_theme.dart';

/// Lays out sibling blocks with [spacing] between them and none after the
/// last one. [nodes] are the blocks' nodes, in the same order as
/// [children]; with heading or lead-in spacing in [theme], each gap is
/// [CmarkThemeData.spacingBetween].
///
/// With [tight] set, the blocks are those of a list item, and [tight] is
/// whether its list is tight. A sublist sits right under the text of its
/// item in any list, so the sublist groups with its own item rather than
/// floating between two. In a tight list, text after a sublist also sits
/// right under it; in a loose list, it keeps [spacing], as the author
/// started a new paragraph. Other blocks, such as a code block, keep their
/// spacing.
///
/// Without node or list item spacing, this is a [Column] with [spacing]. With
/// it, every gap is a [SizedBox] between two blocks, so that the blocks
/// keep their positions in the column when a heading streams in.
Widget spacedBlockColumn({
  required CmarkThemeData theme,
  required List<Widget> children,
  required List<CmarkNode?>? nodes,
  required double spacing,
  bool? tight,
}) {
  assert(nodes == null || nodes.length == children.length);
  if (nodes == null || !(theme.hasNodeSpacing || tight != null)) {
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
            height: _isAttached(nodes[i - 1], nodes[i], tight)
                ? 0
                : theme.spacingBetween(nodes[i - 1], nodes[i], spacing),
          ),
        children[i],
      ],
    ],
  );
}

/// Whether [below] sits right under [above] in a list item; see
/// [spacedBlockColumn]. [tight] is null outside list items.
bool _isAttached(CmarkNode? above, CmarkNode? below, bool? tight) {
  if (tight == null) return false;
  final a = above?.type;
  final b = below?.type;
  if (a == CmarkNodeType.paragraph && b == CmarkNodeType.list) return true;
  return tight && a == CmarkNodeType.list && b == CmarkNodeType.paragraph;
}
