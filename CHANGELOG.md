## 1.0.2

- Up and Down move the caret in a text field inside a `SelectionArea`. Before,
  the region's override of the vertical caret action threw a type error, so
  the keys did nothing.

## 1.0.1

- Requires highlight_fork 1.1.0. Code blocks parse in about half the time.

## 1.0.0

- First stable release. Requires cmark_gfm_dart, highlight_fork, pixel_snap_fork and flutter_math_fork_fork 1.0.0.

## 0.4.2

- A sublist now sits right under its item's text in loose lists too, so it
  groups with its own item. In a loose list, text after a sublist and other
  blocks in an item keep `listItemBlockSpacing`; items keep
  `listItemSpacing`.

## 0.4.1

- Keep full-highlight dispatch failures asynchronous so fallback parsing never
  notifies listeners during a build.
- Make completion and disposal regression tests deterministic on web and native.

## 0.4.0

- Upgrade to highlight_fork 0.8.0 and the highlight.js 11 token API.
- Rehighlight completed fenced code blocks in full, replacing provisional streaming colours.
- Inherit parent styles for nested and dotted highlight scopes.
- Add a public `highlight.dart` library with scope-run helpers and full-highlight types.
- Add a full-highlight offload hook and configurable size threshold for large code blocks.

## 0.3.5

- Remove the gap between paragraph text and a sublist in tight list items,
  including after a colon. Loose lists and other block types keep their spacing.

## 0.3.4

- Add `CmarkThemeData.leadInSpacing`, the space between a lead-in and the
  block it introduces. A lead-in is a paragraph whose text ends with ":",
  such as "To install it, run:". The block is a list, code block, table or
  math block. Unset, the gap is the container's spacing, as before.
- Add `CmarkThemeData.isLeadIn` and `.hasNodeSpacing`.

## 0.3.3

- Add `CmarkThemeData.headingSpacingBefore` and `.headingSpacingAfter`.
  They set the space above and below a heading in every container, so a
  heading can group with the text after it. Between two headings, the
  larger applies. Unset, a heading gets its container's spacing, as before.
- Add `CmarkThemeData.spacingBetween`, the space between two sibling blocks.
- Add `CmarkBlockColumn.nodes`. With it, the column uses heading spacing.
  `CmarkMarkdownColumn` passes it.

## 0.3.2

- `CmarkBlockColumn` reveals blocks in reading order. When a chunk adds more
  than one block, a block starts to fade in when the blocks before it are
  revealed, so there is one reveal position, not one per block. A reveal
  that waits does not tick, and the work per frame does not change with the
  number of blocks.
- Add `CmarkRevealOrder`, and `CmarkStreamingReveal.order` and `.index`, for
  reading order in layouts other than `CmarkBlockColumn`.
- Fix: the first line of a list item no longer stays hidden while its marker
  fades in, then appears at once.
- Add `cmarkStreamingParseLength`, and `streaming` on
  `ParserController.parse` and `.parseChunks`. While a document streams,
  they leave out an unfinished last line of only `-` or `=`. Under a
  paragraph, that line makes the paragraph a heading for one chunk, though
  it is usually the start of a list item.

## 0.3.1

- Allow pixel_snap_fork 0.2.x as well as 0.1.x.

## 0.3.0

- Add `CmarkStreamingReveal`, which fades in the text that is added to a
  block while a document streams. Per animation frame it only paints. A
  chunk that ends in the middle of a word does not restart the fade of the
  word.
- Add `CmarkBlockColumn.reveal` (`CmarkRevealOptions`). It puts a reveal
  around each block while the document streams. A column that is first built
  while not streaming has no reveals.
- Add `CmarkRevealStyle`: `lines` fades characters in reading order; `whole`
  fades the block as one unit. `CmarkRevealStyle.forNode` gives `whole` for
  tables, rules, block math and custom blocks.
- Add `BlockRenderResult.node`, the top-level block that the result shows.
- `CmarkBlockColumn` is now a `StatefulWidget`.

## 0.2.0

- **Breaking:** `CmarkThemeData.blockSpacing` and
  `CmarkThemeData.listItemBlockSpacing` are now `double`, not `EdgeInsets`.
  The value is the vertical space between two sibling blocks.
- Fix: a block no longer adds space after itself. A single block, and the
  last block of a document, quote, list item or footnote, now ends at its
  content. The same applies to `listItemSpacing` in loose lists.
- Add `CmarkBlockColumn`. It lays out the blocks from `RenderPipeline.render`
  with `blockSpacing` between them. Use it in place of a plain `Column`.
- Hidden footnote definitions (`renderFootnoteDefinitions: false`) now give
  no block, so they add no spacing.

## 0.1.0

- First release on pub.dev: a Flutter renderer for GitHub Flavored
  Markdown, powered by cmark_gfm_dart.
