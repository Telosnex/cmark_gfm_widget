import 'package:cmark_gfm_dart/cmark_gfm_dart.dart';
import 'package:flutter/widgets.dart';

import '../theme/cmark_theme.dart';

/// Lays out sibling blocks with [spacing] between them and none after the
/// last one. [nodes] are the blocks' nodes, in the same order as
/// [children]; with heading or lead-in spacing in [theme], each gap is
/// [CmarkThemeData.spacingBetween].
///
/// Without that spacing, this is a [Column] with [spacing]. With it, every
/// gap is a [SizedBox] between two blocks, so that the blocks keep their
/// positions in the column when a heading streams in.
Widget spacedBlockColumn({
  required CmarkThemeData theme,
  required List<Widget> children,
  required List<CmarkNode?>? nodes,
  required double spacing,
}) {
  assert(nodes == null || nodes.length == children.length);
  if (nodes == null || !theme.hasNodeSpacing) {
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
            height: theme.spacingBetween(nodes[i - 1], nodes[i], spacing),
          ),
        children[i],
      ],
    ],
  );
}
