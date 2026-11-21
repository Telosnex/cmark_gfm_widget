import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A [Table] that doesn't relayout when a rebuild keeps the same cells.
///
/// Flutter's table element hands its render object the full cell list on
/// every update, and [RenderTable.setFlatChildren] then always calls
/// [RenderObject.markNeedsLayout], even when no cell moved. Table layout asks
/// every cell for its intrinsic widths, so any rebuild of a large table
/// (recoloring, an ancestor rebuilding) relays it out.
///
/// This is [Table] with that one difference. Cells that really change still
/// relayout the table themselves: they mark their parent when their size can
/// change.
class StableTable extends Table {
  StableTable({
    super.key,
    super.children,
    super.columnWidths,
    super.defaultColumnWidth,
    super.textDirection,
    super.border,
    super.defaultVerticalAlignment,
    super.textBaseline,
  });

  // Mirrors Table._rowDecorations, which is private.
  List<Decoration?>? get _rowDecorations =>
      children.any((row) => row.decoration != null)
          ? [for (final row in children) row.decoration]
          : null;

  @override
  RenderTable createRenderObject(BuildContext context) {
    assert(debugCheckHasDirectionality(context));
    return StableRenderTable(
      columns: children.isNotEmpty ? children[0].children.length : 0,
      rows: children.length,
      columnWidths: columnWidths,
      defaultColumnWidth: defaultColumnWidth,
      textDirection: textDirection ?? Directionality.of(context),
      border: border,
      rowDecorations: _rowDecorations,
      configuration: createLocalImageConfiguration(context),
      defaultVerticalAlignment: defaultVerticalAlignment,
      textBaseline: textBaseline,
    );
  }
}

/// [RenderTable] whose [setFlatChildren] does nothing when given the cells it
/// already has, in the same places.
class StableRenderTable extends RenderTable {
  StableRenderTable({
    super.columns,
    super.rows,
    super.columnWidths,
    super.defaultColumnWidth,
    required super.textDirection,
    super.border,
    super.rowDecorations,
    super.configuration,
    super.defaultVerticalAlignment,
    super.textBaseline,
  });

  @override
  void setFlatChildren(int columns, List<RenderBox?> cells) {
    if (_hasCells(columns, cells)) return;
    super.setFlatChildren(columns, cells);
  }

  /// Whether the table already holds exactly [cells], in row-major order.
  ///
  /// [visitChildren] skips empty slots, so this only matches a table with no
  /// empty slots, which is what the table element always produces.
  bool _hasCells(int columns, List<RenderBox?> cells) {
    if (columns != this.columns || cells.length != rows * columns) {
      return false;
    }
    var index = 0;
    var same = true;
    visitChildren((child) {
      if (!same) return;
      same = index < cells.length && identical(cells[index], child);
      index++;
    });
    return same && index == cells.length;
  }
}
