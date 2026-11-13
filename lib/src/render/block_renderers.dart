import 'package:cmark_gfm_dart/cmark_gfm_dart.dart';
import 'package:cmark_gfm_widget/src/widgets/source_markdown_registry.dart';

import '../parser/document_snapshot.dart';
import 'package:flutter/gestures.dart' show GestureRecognizer;
import 'package:flutter_math_fork_fork/flutter_math.dart';
import 'package:pixel_snap_fork/material.dart';

import '../theme/cmark_theme.dart';
import '../highlight/highlight_adapter.dart';
import '../widgets/source_aware_widget.dart';
import '../widgets/details.dart';
import 'block_render_cache.dart';
import 'block_spacing.dart';
import 'details_grouping.dart';
import 'inline_renderers.dart';
import 'math_parser_settings.dart';
import 'render_pipeline.dart';

final HighlightAdapter _highlightAdapter = HighlightAdapter();

class BlockRenderResult {
  BlockRenderResult({required this.id, required this.widget, this.node});

  final String id;
  final Widget widget;

  /// The top-level block that [widget] shows.
  final CmarkNode? node;
}

typedef BlockMathWidgetBuilder = Widget Function(
  CmarkNode node,
  BlockRenderContext context,
);

class BlockRenderContext {
  BlockRenderContext({
    required this.theme,
    required this.inlineContext,
    required this.selectable,
    required this.textScaleFactor,
    required this.renderFootnoteDefinitions,
    this.leadingSpans = const [],
    required this.tableOptions,
    required this.codeBlockWrapper,
    this.detailsBuilder,
    this.mathBlockBuilder,
    this.onLinkTap,
    this.isCodeBlockComplete,
    this.streaming = false,
  });

  final bool Function(CmarkNode)? isCodeBlockComplete;

  /// Whether the block being rendered can still get content: it is the
  /// last block of a document that is streaming.
  final bool streaming;

  final CmarkThemeData theme;
  final InlineRenderContext inlineContext;
  final bool selectable;
  final double textScaleFactor;
  final bool renderFootnoteDefinitions;
  final TableRenderOptions tableOptions;
  final CodeBlockWrapperBuilder? codeBlockWrapper;
  final DetailsBuilder? detailsBuilder;
  final BlockMathWidgetBuilder? mathBlockBuilder;

  /// Optional tap handler for links (Markdown links).
  final LinkTapHandler? onLinkTap;

  /// Optional leading spans to prepend to the first text block.
  final List<InlineSpan> leadingSpans;
}

List<BlockRenderResult> renderDocumentBlocks(
  DocumentSnapshot snapshot,
  List<InlineSpan> leadingSpans,
  BlockRenderContext context, {
  BlockRenderCache? cache,
  Object? cacheKey,
  bool repaintBoundaries = false,
}) {
  final streaming = snapshot.streamingEndLine != null;
  return renderTopLevelBlocks(
    snapshot,
    leadingSpans,
    theme: context.theme,
    cache: cache,
    cacheKey: cacheKey,
    renderDetails: (parts) => _buildDetails(
      context,
      opener: parts.opener,
      summaryText: parts.summaryText,
      initiallyOpen: parts.initiallyOpen,
      isComplete: parts.isComplete,
      leadingSpans: parts.leadingSpans,
      children: [
        for (final child in parts.children)
          KeyedSubtree(key: ValueKey<String>(child.id), child: child.widget),
      ],
      nodes: [for (final child in parts.children) child.node],
      spacing: context.theme.blockSpacing,
    ),
    renderBlock: (block, leadingSpans) {
      // Pass leading spans to the first text block.
      final blockContext = BlockRenderContext(
        theme: context.theme,
        inlineContext: context.inlineContext,
        selectable: context.selectable,
        textScaleFactor: context.textScaleFactor,
        renderFootnoteDefinitions: context.renderFootnoteDefinitions,
        leadingSpans:
            leadingSpans.isNotEmpty ? leadingSpans : context.leadingSpans,
        tableOptions: context.tableOptions,
        codeBlockWrapper: context.codeBlockWrapper,
        detailsBuilder: context.detailsBuilder,
        mathBlockBuilder: context.mathBlockBuilder,
        onLinkTap: context.onLinkTap,
        isCodeBlockComplete: snapshot.isCodeBlockComplete,
        streaming: streaming && block.next == null,
      );
      final widget = _renderBlock(block, blockContext);
      if (widget == null || !repaintBoundaries) return widget;
      return RepaintBoundary(child: widget);
    },
  );
}

Widget? _renderBlock(
  CmarkNode node,
  BlockRenderContext context, {
  int listLevel = 0,
}) {
  final child = _renderBlockContent(node, context, listLevel: listLevel);
  if (child == null || !context.selectable) return child;
  // Nested list/quote paragraphs need their own identity too. A top-level
  // list attachment cannot distinguish inline continuations from new items.
  return SourceAwareWidget(
    attachment: MarkdownSourceAttachment(blockNode: node),
    child: child,
  );
}

Widget? _renderBlockContent(
  CmarkNode node,
  BlockRenderContext context, {
  int listLevel = 0,
}) {
  final theme = context.theme;
  switch (node.type) {
    case CmarkNodeType.paragraph:
      return _buildTextualBlock(node, context, style: theme.paragraphTextStyle);
    case CmarkNodeType.heading:
      return _buildTextualBlock(
        node,
        context,
        style: theme.headingTextStyle(node.headingData.level),
      );
    case CmarkNodeType.blockQuote:
      return _buildBlockQuote(node, context, listLevel: listLevel);
    case CmarkNodeType.codeBlock:
      return _buildCodeBlock(node, context);
    case CmarkNodeType.thematicBreak:
      // A rule is a visual boundary, not hidden Markdown text to copy.
      final verticalPadding =
          (theme.thematicBreakVerticalPadding / 2).clamp(0.0, double.infinity);
      final divider = Divider(
        color: theme.thematicBreakColor,
        thickness: theme.thematicBreakThickness,
        height: theme.thematicBreakThickness,
      );
      return Padding(
        padding: EdgeInsets.symmetric(vertical: verticalPadding),
        child: divider,
      );
    case CmarkNodeType.list:
      return _buildList(node, context, level: listLevel + 1);
    case CmarkNodeType.table:
      return _buildTable(node, context);
    case CmarkNodeType.htmlBlock:
      return _buildTextualBlock(
        node,
        context,
        style: theme.paragraphTextStyle,
        literal: node.content.toString(),
      );
    case CmarkNodeType.footnoteDefinition:
      return _buildFootnoteDefinition(node, context, listLevel: listLevel);
    case CmarkNodeType.mathBlock:
      return _buildMathBlock(node, context);
    case CmarkNodeType.customBlock:
      return _buildTextualBlock(
        node,
        context,
        style: theme.paragraphTextStyle,
        literal: node.customData.onEnter,
      );
    default:
      return _renderCompositeBlock(node, context, listLevel: listLevel);
  }
}

Widget? _renderCompositeBlock(
  CmarkNode node,
  BlockRenderContext context, {
  required int listLevel,
}) {
  return _childBlockColumn(
    node,
    context,
    listLevel: listLevel,
    spacing: _childBlockSpacing(context, listLevel),
  );
}

Widget _buildTextualBlock(
  CmarkNode node,
  BlockRenderContext context, {
  required TextStyle style,
  String? literal,
}) {
  // Fresh per-call sink for any link tap recognizers created while rendering
  // this block's inline content; ownership is handed to GestureRecognizerOwner
  // below so they get disposed at the right time (see
  // InlineRenderContext.withLinkRecognizerSink).
  final linkRecognizers = <GestureRecognizer>[];
  TextSpan textSpan;
  if (literal != null) {
    textSpan = TextSpan(text: literal, style: style);
  } else {
    final inlineContext = context.inlineContext.withLinkRecognizerSink(
      linkRecognizers,
    );
    final children = renderInlineChildren(node, inlineContext, style);
    if (children.isEmpty) {
      textSpan = TextSpan(text: '', style: style);
    } else {
      textSpan = TextSpan(style: style, children: children);
    }
  }

  // Prepend leading spans if provided
  final effectiveSpan = context.leadingSpans.isNotEmpty
      ? TextSpan(children: [...context.leadingSpans, textSpan])
      : textSpan;

  // Use pixel_snap's Text.rich for both selectable and non-selectable
  // SelectableRegion (from SelectionArea) makes it selectable automatically.
  // Force paragraph strut metrics so code-only lines do not let the smaller
  // monospace run determine the line box while mixed prose/code lines use the
  // full body font metrics. Keeping every textual block on the paragraph style's
  // line box makes inline code align consistently across list items.
  Widget widget = Text.rich(
    effectiveSpan,
    strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true),
    textScaler: TextScaler.linear(context.textScaleFactor),
  );

  if (linkRecognizers.isNotEmpty) {
    widget = GestureRecognizerOwner(
      recognizers: linkRecognizers,
      child: widget,
    );
  }

  return widget;
}

Widget _buildBlockQuote(
  CmarkNode node,
  BlockRenderContext context, {
  required int listLevel,
}) {
  final column = _childBlockColumn(
    node,
    context,
    listLevel: listLevel,
    spacing: _childBlockSpacing(context, listLevel),
  );
  return Container(
    decoration: BoxDecoration(
      color: context.theme.blockQuoteBackgroundColor,
      border: Border(
        left: BorderSide(color: context.theme.blockQuoteBorderColor, width: 4),
      ),
    ),
    padding: context.theme.blockQuotePadding,
    child: column ?? _blockColumn(const [], 0),
  );
}

Widget _buildCodeBlock(CmarkNode node, BlockRenderContext context) {
  Widget result = _HighlightedCodeBlock(node: node, context: context);
  final wrapper = context.codeBlockWrapper;
  if (wrapper != null) {
    result = wrapper(
      result,
      CodeBlockMetadata(
        node: node,
        info: node.codeData.info,
        literal: node.codeData.literal,
      ),
    );
  }
  return result;
}

/// Keeps the asynchronous final recoloring local to the live code block, even
/// when the enclosing top-level widget is retained by BlockRenderCache.
class _HighlightedCodeBlock extends StatefulWidget {
  const _HighlightedCodeBlock({required this.node, required this.context});

  final CmarkNode node;
  final BlockRenderContext context;

  @override
  State<_HighlightedCodeBlock> createState() => _HighlightedCodeBlockState();
}

class _HighlightedCodeBlockState extends State<_HighlightedCodeBlock> {
  final Object _blockKey = Object();

  @override
  void initState() {
    super.initState();
    _highlightAdapter.addListener(_highlightChanged);
  }

  void _highlightChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _highlightAdapter.removeListener(_highlightChanged);
    _highlightAdapter.releaseBlock(_blockKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _buildHighlightedCodeBlock(widget.node, widget.context, _blockKey);
}

Widget _buildHighlightedCodeBlock(
  CmarkNode node,
  BlockRenderContext context,
  Object blockKey,
) {
  final literal = node.codeData.literal;
  final highlightConfig = context.theme.codeHighlightTheme;
  final language = _resolveCodeBlockLanguage(
    node.codeData.info,
    highlightConfig,
  );

  // `node.codeData.literal` does not contain the Markdown code block fences.
  // Therefore, Highlight cannot auto-detect the language.
  // Therefore, we use the language from `node.codeData.info` here, and only
  // ask highlight to auto-detect if we cannot determine a language.
  final highlighted = _highlightAdapter.buildLines(
    code: literal,
    blockKey: blockKey,
    complete: context.isCodeBlockComplete?.call(node) ?? true,
    baseStyle: context.theme.codeBlockTextStyle,
    theme: highlightConfig.theme,
    // Autodetection is expensive, error-prone, and throws exceptions as a
    // regular part of its operation, resulting in prints without attribution.
    // Therefore, we rely on parsing from the fence, or just use plain text.
    autoDetectLanguage: false,
    language: language,
    fallbackStyle: context.theme.codeBlockTextStyle,
    tabSize: highlightConfig.tabSize,
    offload: (
      hook: highlightConfig.highlightOffload,
      threshold: highlightConfig.highlightOffloadThreshold,
    ),
  );

  // One widget per line, instead of one paragraph for the whole block.
  // Provisional line spans are identical instances across streaming appends
  // (see HighlightAdapter), so RenderParagraph skips layout for unchanged
  // lines and streaming costs O(1) per chunk instead of O(lines). At a closing
  // fence or document completion, one whole-text parse corrects lookahead-
  // dependent colors. Only changed lines get new spans. Large corrections
  // notify _HighlightedCodeBlock asynchronously without rebuilding its parent.
  final textScaler = TextScaler.linear(context.textScaleFactor);
  final lineWidgets = <Widget>[];
  for (final line in highlighted.lines) {
    Widget lineWidget = context.selectable
        ? Text.rich(line, softWrap: false, textScaler: textScaler)
        : RichText(text: line, softWrap: false, textScaler: textScaler);
    if (context.selectable) {
      // Empty lines have no selectable text. The line index preserves those
      // boundaries between selected lines without consulting source text.
      lineWidget = SourceAwareWidget(
        attachment: MarkdownSourceAttachment(
          blockNode: node,
          codeLine: lineWidgets.length,
        ),
        child: lineWidget,
      );
    }
    lineWidgets.add(lineWidget);
  }

  final child = lineWidgets.length == 1
      ? lineWidgets.first
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: lineWidgets,
        );

  // If we wrap in a [SingleChildScrollView], its impossible for clients to
  // do things like have the codeblock in a container that applys a "fade"
  // effect at the edges. Therefore, we do not do that here.
  //
  // RepaintBoundary keeps per-chunk streaming repaints from repainting
  // everything around the code block (and vice versa).
  Widget result = RepaintBoundary(
    child: Container(
      padding: context.theme.codeBlockPadding,
      color: context.theme.codeBlockBackgroundColor,
      child: child,
    ),
  );

  return result;
}

Widget _buildMathBlock(CmarkNode node, BlockRenderContext context) {
  final builder = context.mathBlockBuilder ?? _defaultMathBlockBuilder;
  return builder(node, context);
}

Widget _buildList(
  CmarkNode node,
  BlockRenderContext context, {
  required int level,
}) {
  final data = node.listData;
  final ordered = data.listType == CmarkListType.ordered;
  final bullets = <Widget>[];
  // Leading spans belong at the start of the document block. If they flow
  // through the regular list-item context, every item receives a copy after
  // its marker (`1. <glyph>...`). Render them once before the first marker and
  // remove them from all item-content contexts instead.
  final itemContentContext = _withoutLeadingSpans(context);
  var item = node.firstChild;
  var index = 0;
  while (item != null) {
    final itemLeadingSpans =
        index == 0 ? context.leadingSpans : const <InlineSpan>[];
    index += 1;
    // Use each item's original number (listData.start) instead of calculating
    final itemNumber = ordered ? item.listData.start : index;
    bullets.add(
      _buildListItem(
        item,
        itemContentContext,
        ordered: ordered,
        tight: data.tight,
        index: itemNumber == 0 ? index : itemNumber,
        level: level,
        leadingSpansBeforeMarker: itemLeadingSpans,
      ),
    );

    item = item.next;
  }
  return _blockColumn(bullets, data.tight ? 0 : context.theme.listItemSpacing);
}

Widget _buildListItem(
  CmarkNode item,
  BlockRenderContext context, {
  required bool ordered,
  required bool tight,
  required int index,
  required int level,
  required List<InlineSpan> leadingSpansBeforeMarker,
}) {
  final bulletText = ordered ? '$index. ' : '\u2022 ';
  final column = _childBlockColumn(
        item,
        context,
        listLevel: level,
        spacing: context.theme.listItemBlockSpacing,
        tight: tight,
      ) ??
      _blockColumn(const [], 0);

  final resolvedLevel = level < 1 ? 1 : level;

  Widget marker = Text(
    bulletText,
    style: ordered
        ? context.theme.orderedListBulletTextStyle
        : context.theme.unorderedListBulletTextStyle,
    textAlign: TextAlign.right,
  );
  if (context.selectable) {
    marker = SourceAwareWidget(
      attachment: MarkdownSourceAttachment(
        blockNode: item,
        isListMarker: true,
      ),
      child: marker,
    );
  }

  final rowChildren = <Widget>[
    if (leadingSpansBeforeMarker.isNotEmpty)
      Text.rich(
        TextSpan(
          style: context.theme.paragraphTextStyle,
          children: leadingSpansBeforeMarker,
        ),
        strutStyle: StrutStyle.fromTextStyle(
          context.theme.paragraphTextStyle,
          forceStrutHeight: true,
        ),
        textScaler: TextScaler.linear(context.textScaleFactor),
      ),
    marker,
    SizedBox(width: context.theme.listBulletGap),
  ];

  rowChildren.add(Expanded(child: column));

  return Padding(
    padding: EdgeInsets.only(
      left: ordered
          ? context.theme.orderedListIndent(resolvedLevel)
          : context.theme.unorderedListIndent(resolvedLevel),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rowChildren,
    ),
  );
}

BlockRenderContext _withoutLeadingSpans(BlockRenderContext context) {
  if (context.leadingSpans.isEmpty) return context;
  return BlockRenderContext(
    theme: context.theme,
    inlineContext: context.inlineContext,
    selectable: context.selectable,
    textScaleFactor: context.textScaleFactor,
    renderFootnoteDefinitions: context.renderFootnoteDefinitions,
    tableOptions: context.tableOptions,
    codeBlockWrapper: context.codeBlockWrapper,
    detailsBuilder: context.detailsBuilder,
    mathBlockBuilder: context.mathBlockBuilder,
    onLinkTap: context.onLinkTap,
    isCodeBlockComplete: context.isCodeBlockComplete,
    streaming: context.streaming,
  );
}

/// Builds a `<details>` section from its rendered [children].
Widget _buildDetails(
  BlockRenderContext context, {
  required CmarkNode opener,
  required String? summaryText,
  required bool initiallyOpen,
  required bool isComplete,
  required List<InlineSpan> leadingSpans,
  required List<Widget> children,
  required List<CmarkNode?> nodes,
  required double spacing,
}) {
  final style = context.theme.paragraphTextStyle.copyWith(
    fontWeight: FontWeight.w600,
  );
  final text = TextSpan(text: summaryText ?? 'Details', style: style);
  Widget summary = Text.rich(
    leadingSpans.isEmpty ? text : TextSpan(children: [...leadingSpans, text]),
    strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true),
    textScaler: TextScaler.linear(context.textScaleFactor),
  );
  if (context.selectable) {
    summary = SourceAwareWidget(
      attachment: MarkdownSourceAttachment(blockNode: opener),
      child: summary,
    );
  }
  final data = CmarkDetailsData(
    node: opener,
    summary: summary,
    body: spacedBlockColumn(
      theme: context.theme,
      children: children,
      nodes: nodes,
      spacing: spacing,
    ),
    summaryText: summaryText,
    initiallyOpen: initiallyOpen,
    isComplete: isComplete,
    theme: context.theme,
  );
  return _DetailsHost(builder: context.detailsBuilder, data: data);
}

/// Calls the app's [DetailsBuilder] with a [BuildContext], or builds the
/// default [CmarkDetails].
class _DetailsHost extends StatelessWidget {
  const _DetailsHost({required this.builder, required this.data});

  final DetailsBuilder? builder;
  final CmarkDetailsData data;

  @override
  Widget build(BuildContext context) =>
      builder?.call(context, data) ?? CmarkDetails(data: data);
}

Widget _buildTable(CmarkNode node, BlockRenderContext context) {
  final cellRows = <List<Widget>>[];
  final columnAlignments = <CmarkTableAlign>[];
  final dataRows = <List<String>>[];
  List<String>? headerRow;

  var rowNode = node.firstChild;
  var isHeaderProcessed = false;
  var maxColumns = 0;
  while (rowNode != null) {
    if (rowNode.type != CmarkNodeType.tableRow) {
      rowNode = rowNode.next;
      continue;
    }
    // Skip empty header rows (all cells have no content)
    // GFM tables require a header row. Sometimes it is odd to the LLM to include
    // labels on them, so it renders as empty. If the header cells are empty,
    // skip rendering.
    if (rowNode.tableRowData.isHeader) {
      var allEmpty = true;
      var checkCell = rowNode.firstChild;
      while (checkCell != null) {
        if (checkCell.firstChild != null) {
          allEmpty = false;
          break;
        }
        checkCell = checkCell.next;
      }
      if (allEmpty) {
        // Still collect column alignments from the header cells
        var cellNode = rowNode.firstChild;
        var columnIndex = 0;
        while (cellNode != null) {
          if (cellNode.type == CmarkNodeType.tableCell) {
            if (columnAlignments.length <= columnIndex) {
              columnAlignments.add(cellNode.tableCellData.align);
            }
            columnIndex++;
          }
          cellNode = cellNode.next;
        }
        rowNode = rowNode.next;
        continue;
      }
    }
    final cells = <Widget>[];
    final cellTexts = <String>[];
    var cellNode = rowNode.firstChild;
    var columnIndex = 0;
    while (cellNode != null) {
      if (cellNode.type != CmarkNodeType.tableCell) {
        cellNode = cellNode.next;
        continue;
      }
      if (columnAlignments.length <= columnIndex) {
        columnAlignments.add(cellNode.tableCellData.align);
      } else {
        final existing = columnAlignments[columnIndex];
        if (existing == CmarkTableAlign.none &&
            cellNode.tableCellData.align != CmarkTableAlign.none) {
          columnAlignments[columnIndex] = cellNode.tableCellData.align;
        }
      }

      final baseStyle = rowNode.tableRowData.isHeader
          ? context.theme.tableHeaderTextStyle
          : context.theme.tableBodyTextStyle;
      // Fresh per-cell sink for any link tap recognizers (see
      // InlineRenderContext.withLinkRecognizerSink / GestureRecognizerOwner).
      final cellLinkRecognizers = <GestureRecognizer>[];
      final cellChildren = renderInlineChildren(
        cellNode,
        context.inlineContext.withLinkRecognizerSink(cellLinkRecognizers),
        baseStyle,
      );
      final textSpan = TextSpan(
        style: baseStyle,
        children: cellChildren.isEmpty ? null : cellChildren,
        text: cellChildren.isEmpty ? '' : null,
      );

      final textAlign = _textAlignForCell(columnAlignments[columnIndex]);
      // Keep code-only cells on the table's prose line box. Without a forced
      // strut, the smaller monospace run defines a shorter paragraph whose
      // top is aligned with neighboring cells, so it appears too high.
      final strutStyle = StrutStyle.fromTextStyle(
        baseStyle,
        forceStrutHeight: true,
      );
      Widget alignedChild = context.selectable
          ? Text.rich(
              textSpan,
              textAlign: textAlign,
              strutStyle: strutStyle,
              textScaler: TextScaler.linear(context.textScaleFactor),
            )
          : RichText(
              text: textSpan,
              textAlign: textAlign,
              strutStyle: strutStyle,
              textScaler: TextScaler.linear(context.textScaleFactor),
            );

      if (cellLinkRecognizers.isNotEmpty) {
        alignedChild = GestureRecognizerOwner(
          recognizers: cellLinkRecognizers,
          child: alignedChild,
        );
      }

      if (context.selectable) {
        alignedChild = SourceAwareWidget(
          attachment: MarkdownSourceAttachment(
            blockNode: cellNode,
          ),
          child: alignedChild,
        );
      }

      cells.add(
        Align(
          alignment: _alignmentForCell(columnAlignments[columnIndex]),
          child: Padding(
            padding: context.theme.tableCellPadding,
            child: alignedChild,
          ),
        ),
      );
      cellTexts.add(_collectPlainText(cellNode));
      columnIndex += 1;
      cellNode = cellNode.next;
    }
    maxColumns = cells.length > maxColumns ? cells.length : maxColumns;
    cellRows.add(cells);
    if (rowNode.tableRowData.isHeader) {
      isHeaderProcessed = true;
      headerRow = cellTexts;
    } else {
      dataRows.add(cellTexts);
    }
    rowNode = rowNode.next;
  }

  if (cellRows.isEmpty) {
    return const SizedBox.shrink();
  }

  for (final cells in cellRows) {
    if (cells.length < maxColumns) {
      cells.addAll(
        List<Widget>.generate(
          maxColumns - cells.length,
          (_) => const SizedBox.shrink(),
        ),
      );
    }
  }

  final rows = cellRows.map((cells) => TableRow(children: cells)).toList();

  final defaultColumnWidth =
      context.tableOptions.defaultColumnWidth ?? const IntrinsicColumnWidth();

  final table = Table(
    defaultVerticalAlignment: TableCellVerticalAlignment.top,
    defaultColumnWidth: defaultColumnWidth,
    columnWidths: context.tableOptions.columnWidths,
    border: context.theme.tableBorder,
    children: rows,
  );

  Widget result = Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [if (isHeaderProcessed) const SizedBox(height: 4), table],
  );

  final wrapper = context.tableOptions.wrapper;
  if (wrapper != null) {
    final metadata = TableRenderMetadata(
      node: node,
      alignments: columnAlignments,
      header: headerRow,
      rows: dataRows,
    );
    final wrapperContext = TableWrapperContext(
      theme: context.theme,
      selectable: context.selectable,
      textScaleFactor: context.textScaleFactor,
    );
    result = wrapper(result, metadata, wrapperContext);
  }
  return result;
}

Widget? _buildFootnoteDefinition(
  CmarkNode node,
  BlockRenderContext context, {
  required int listLevel,
}) {
  // No widget, not an empty one: an empty block would still get spacing.
  if (!context.renderFootnoteDefinitions) return null;
  final label = node.footnoteReferenceIndex;
  final column = _childBlockColumn(
    node,
    context,
    listLevel: listLevel,
    spacing: _childBlockSpacing(context, listLevel),
  );
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('[$label]', style: context.theme.footnoteLabelTextStyle),
      const SizedBox(width: 8),
      Expanded(
        child: column ?? _blockColumn(const [], 0),
      ),
    ],
  );
}

Alignment _alignmentForCell(CmarkTableAlign align) {
  switch (align) {
    case CmarkTableAlign.center:
      return Alignment.center;
    case CmarkTableAlign.right:
      return Alignment.centerRight;
    case CmarkTableAlign.left:
    case CmarkTableAlign.none:
      return Alignment.centerLeft;
  }
}

TextAlign _textAlignForCell(CmarkTableAlign align) {
  switch (align) {
    case CmarkTableAlign.center:
      return TextAlign.center;
    case CmarkTableAlign.right:
      return TextAlign.right;
    case CmarkTableAlign.left:
    case CmarkTableAlign.none:
      return TextAlign.left;
  }
}

/// Lays out sibling blocks with [spacing] between them and none after the
/// last one.
Widget _blockColumn(List<Widget> children, double spacing) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: spacing,
    children: children,
  );
}

/// Renders the child blocks of [node] in a column, with [spacing] and the
/// theme's heading and lead-in spacing between them. [tight] is set for a
/// list item; see [spacedBlockColumn]. Null when no child shows
/// anything; callers that need a widget use an empty column, as before.
Widget? _childBlockColumn(
  CmarkNode node,
  BlockRenderContext context, {
  required int listLevel,
  required double spacing,
  bool? tight,
}) {
  final children = <Widget>[];
  final nodes = <CmarkNode>[];
  _renderChildItems(
    groupDetails(_children(node)),
    context,
    listLevel: listLevel,
    spacing: spacing,
    children: children,
    nodes: nodes,
  );
  if (children.isEmpty) return null;
  return spacedBlockColumn(
    theme: context.theme,
    children: children,
    nodes: nodes,
    spacing: spacing,
    tight: tight,
  );
}

Iterable<CmarkNode> _children(CmarkNode node) sync* {
  var child = node.firstChild;
  while (child != null) {
    yield child;
    child = child.next;
  }
}

/// Renders [items], the grouped child blocks of a container, into
/// [children] and their [nodes]. A `<details>` section's node is its
/// `<details>` HTML block.
void _renderChildItems(
  List<DetailsItem> items,
  BlockRenderContext context, {
  required int listLevel,
  required double spacing,
  required List<Widget> children,
  required List<CmarkNode> nodes,
}) {
  for (final item in items) {
    switch (item) {
      case DetailsBlockItem(:final node):
        final rendered = _renderBlock(node, context, listLevel: listLevel);
        if (rendered != null) {
          children.add(rendered);
          nodes.add(node);
        }
      case DetailsGroupItem():
        final groupChildren = <Widget>[];
        final groupNodes = <CmarkNode>[];
        _renderChildItems(
          item.children,
          context,
          listLevel: listLevel,
          spacing: spacing,
          children: groupChildren,
          nodes: groupNodes,
        );
        children.add(
          _buildDetails(
            context,
            opener: item.opener,
            summaryText: item.summaryText,
            initiallyOpen: item.initiallyOpen,
            isComplete: item.closer != null || !context.streaming,
            leadingSpans: const [],
            children: groupChildren,
            nodes: groupNodes,
            spacing: spacing,
          ),
        );
        nodes.add(item.opener);
    }
  }
}

/// Space between the child blocks of a container at [listLevel].
double _childBlockSpacing(BlockRenderContext context, int listLevel) {
  return listLevel > 0
      ? context.theme.listItemBlockSpacing
      : context.theme.blockSpacing;
}

Widget _defaultMathBlockBuilder(
  CmarkNode node,
  BlockRenderContext context,
) {
  final literal = node.mathData.literal;
  if (literal.isEmpty) {
    return const SizedBox.shrink();
  }

  Widget child = Math.tex(
    literal,
    mathStyle: MathStyle.display,
    textStyle: context.theme.paragraphTextStyle,
    settings: cmarkMathParserSettings,
    onErrorFallback: (error) => Text(
      literal,
      style: context.theme.paragraphTextStyle,
    ),
  );

  child = SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: child,
    ),
  );

  // Stack with invisible LaTeX source for copy/paste when selectable
  if (context.selectable) {
    child = Stack(
      children: [
        // Invisible text with LaTeX source - this gets selected/copied
        Positioned.fill(
          child: Text(
            literal,
            style: const TextStyle(color: Colors.transparent),
            overflow: TextOverflow.clip,
          ),
        ),
        // Visible Math widget - ignores pointer events
        IgnorePointer(child: child),
      ],
    );
  }

  return child;
}

String _collectPlainText(CmarkNode node) {
  final buffer = StringBuffer();

  void visit(CmarkNode current) {
    if (current.type == CmarkNodeType.text ||
        current.type == CmarkNodeType.code) {
      buffer.write(current.content.toString());
    } else if (current.type == CmarkNodeType.softbreak ||
        current.type == CmarkNodeType.linebreak) {
      buffer.write('\n');
    }

    var child = current.firstChild;
    while (child != null) {
      visit(child);
      child = child.next;
    }
  }

  visit(node);
  return buffer.toString();
}

/// Maps file extensions / short names that are NOT already registered as
/// highlight.js language names or aliases to the correct language identifier.
///
/// For example, the highlight package registers "mm", "objc", and "obj-c"
/// as aliases for objectivec, but does NOT register "m".
const _extensionToLanguage = <String, String>{
  'm': 'objectivec',
  'h': 'objectivec',
};

String? _resolveCodeBlockLanguage(String info, CodeHighlightTheme config) {
  final trimmed = info.trim();
  if (trimmed.isEmpty) {
    return config.defaultLanguage;
  }
  final spaceIndex = trimmed.indexOf(RegExp(r'\s'));
  final token = spaceIndex == -1 ? trimmed : trimmed.substring(0, spaceIndex);
  if (token.isEmpty) return config.defaultLanguage;
  final lower = token.toLowerCase();
  return _extensionToLanguage[lower] ?? lower;
}
