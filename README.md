# cmark_gfm_widget

A lightweight Flutter Markdown renderer built on top of
[`cmark_gfm_dart`](https://github.com/Telosnex/cmark_gfm_dart). It parses GitHub Flavored Markdown using the
streaming CommonMark parser and renders content as a `Column` of Flutter
widgets composed from `InlineSpan`s.

## Features

- Pure Dart parsing with `cmark_gfm`
- Direct `InlineSpan` rendering (no intermediary `SpanNode` tree)
- Column-based layout ready for wrapping in scroll views
- Stable node identifiers for efficient keyed rebuilds
- Basic support for GitHub Flavored Markdown (headings, lists, tables,
  block quotes, code blocks, strikethrough, etc.)
- Optional selectable text output
- Optional fade-in of streamed text that costs no build or layout per frame
- Syntax highlighting powered by `highlight`/`flutter_highlight` with
  cached span generation

## Getting Started

Add the package as a dependency (path or git) and render Markdown using the
high-level widget:

```dart
final controller = ParserController();

SingleChildScrollView(
  child: CmarkMarkdownColumn(
    data: markdownSource,
    controller: controller,
    padding: const EdgeInsets.all(16),
  ),
);
```

If you need selectable text:

```dart
SelectableCmarkMarkdownColumn(
  data: markdownSource,
  controller: controller,
);
```

You can also parse once and reuse a snapshot:

```dart
final snapshot = controller.parse(markdownSource);

CmarkMarkdownColumn(
  snapshot: snapshot,
);
```

## Streaming

While a document streams, only its last blocks change. Give
`RenderPipeline.render` a `BlockRenderCache`, and blocks that did not change
keep their widget instances, so Flutter does not build or lay them out again.
Set `RenderOptions.repaintBoundaries` so that they are not painted again either.

```dart
final cache = BlockRenderCache(); // One per document, kept across updates.

final blocks = const RenderPipeline().render(
  snapshot,
  theme,
  const RenderOptions(repaintBoundaries: true),
  cache: cache,
);
```

The cache compares each block's node with `CmarkNode.contentEquals`. Builders
in `RenderOptions` are not called for a block that keeps its widget, so their
output must depend only on the node and on the `cacheKey` argument.
`CmarkMarkdownColumn` uses a cache.

### Fading in streamed text

Give `CmarkBlockColumn` a `CmarkRevealOptions`, and text that arrives while
the document streams fades in, character by character:

```dart
CmarkBlockColumn(
  theme: theme,
  reveal: CmarkRevealOptions(
    streaming: isStreaming,
    styles: [for (final b in blocks) CmarkRevealStyle.forNode(b.node)],
  ),
  children: [for (final b in blocks) b.widget],
)
```

Each block gets a `CmarkStreamingReveal`, by its index. The reveal does not
change the block's widgets: per frame it only paints, with one mask layer for
each line that is fading. Use it with `repaintBoundaries`, so that a frame of
the fade paints no text again.

- The blocks fade in in reading order. When a chunk adds more than one block,
  a block starts when the blocks before it are revealed. To do the same
  outside the column, give your reveals one `CmarkRevealOrder` and each its
  block's index.
- A chunk that ends in the middle of a word does not restart the fade of that
  word, and shown text never gets dimmer.
- Text that arrives while `streaming` is false is shown at once. A fade in
  progress when streaming ends finishes.
- A column that is first built while not streaming has no reveals, so
  finished documents cost nothing extra.
- Tables, rules and block math fade in as one unit
  (`CmarkRevealStyle.whole`). So do blocks with right-to-left text.

## Selection and copying

Ordinary Copy (and selection-change callbacks) returns selected displayed text,
not reconstructed Markdown. It does not add list numbers, backticks, heading
prefixes, emphasis markers, or link destinations to partial selections.

Selected visible list markers, paragraph boundaries, code line breaks, and math
text alternatives are retained. Multiple table cells use tabs and newlines.
Select All changes the selected extent, not the copy format; `SelectionScope`
can limit it to one message. Applications should use their source data or table
metadata for explicit Markdown/export actions.

## Theming

Wrap any subtree with `CmarkTheme` to override styles or provide a custom
`CmarkThemeData` instance directly to the widget:

```dart
import 'package:flutter_highlight/themes/a11y-light.dart';

CmarkMarkdownColumn(
  data: markdownSource,
  theme: CmarkThemeData.fallback(Theme.of(context).textTheme).copyWith(
    paragraphTextStyle: Theme.of(context).textTheme.bodyLarge!,
    codeHighlightTheme: CodeHighlightTheme(
      theme: a11yLightTheme,
      autoDetectLanguage: false,
      defaultLanguage: 'dart',
    ),
  ),
);
```

## Roadmap

- Custom renderer registration API
- Streaming updates with minimal diff application
- Code block syntax highlighting helpers

## License

MIT
