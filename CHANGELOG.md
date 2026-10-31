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
