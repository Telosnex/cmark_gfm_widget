# ADR 001 — One render object for a code block
Status: ACCEPTED (implemented in 1.1.0)

## 1. Problem

A code block of N lines costs O(N) to open and O(N) for each hit test, even
when the screen shows 50 lines. In debug builds, the first build costs O(N²).

The code block renderer (`_buildHighlightedCodeBlock` in
`lib/src/render/block_renderers.dart`) makes one `RichText` (or `Text.rich`)
per line. With selection on, each line also gets a `SourceAwareWidget`. All
lines are children of one `Column`. The block is one item of the enclosing
list, so the list cannot skip lines that are not on screen.

Measured case: the LLM Ledger entry screen of the Telosnex app shows a Claude
request (`test-results/slowOpus.txt`) as one `js` code block. The block has
21,666 lines and 2.34 M characters. The longest line has 32,509 characters.

| Measurement | Value | Source |
|---|---:|---|
| CPU in `_debugUltimatePreviousSiblingOf` (debug `Flex` assert) | 51% of 3.79 s | profile `dart_devtools_2026-11-15_09_02_18.060.json` |
| Text layout of all lines (`RenderParagraph.performLayout`) | about 455 ms | profile `dart_devtools_2026-11-15_08_56_13.662.json` |
| `RenderFlex.hitTestChildren` | about 146 ms | same profile |
| First frame, 21,666 lines, debug widget test | 7,404 ms | scratch test, flat `Column` |
| First frame, same lines in groups of 64 | 874 ms | scratch test |

Highlighting is not the cost. highlight_fork 1.1.0 does not show in either
profile.

The per-line design has a purpose. Commit `3899a1c` made it so that a
streamed chunk lays out only the changed last line: the adapter returns
identical `TextSpan` instances for unchanged lines. The fix must keep that.

## 2. Requirements

| ID | Requirement | Source | Hardness |
|----|-------------|--------|----------|
| R1 | Opening a code block lays out at most the visible lines plus a fixed margin, for any N. | founder | hard |
| R2 | A hit test on a code block is O(1) in N. | founder | hard |
| R3 | Colors are the same as today: one highlight parse of the whole block. No split of the text before highlighting. | founder | hard |
| R4 | A streamed chunk lays out only the lines whose span changed. | founder | hard |
| R5 | Selection can span the whole block. Copy gives the selected source text, with empty lines and line breaks kept. | founder | hard |
| R6 | The block reports its full width, so the horizontal scroll of the app (`MarkdownPre`) keeps working. | platform | hard |
| R7 | The streaming fade (`CmarkStreamingReveal`) works on code blocks as it does today. | founder | hard |
| R8 | One code path for all code blocks, on native, dart2js and dart2wasm. No size threshold. | founder | hard |
| R9 | A screen reader can read the code that is on screen. | platform | hard |
| R10 | The code font is monospace. | assumed | soft |
| R11 | Line heights are all equal, also for lines with emoji or other fallback fonts. | assumed | soft |

## 3. Decisions

```
D1: A code block is one leaf render object, RenderCodeBlock. It keeps the
    lines as data (the List<TextSpan> from HighlightAdapter), not as child
    widgets.
    Because: R1, R2, R8
    Instead of: line widgets in groups of 64 (still O(N) layout and build,
    fixes only the debug assert); a sliver per line (cannot nest in a
    message item, which is a box in SuperSliverList).
```

```
D2: Every line has the same height. The line style forces the strut
    (forceStrutHeight: true) from codeBlockTextStyle. The line height comes
    from one layout of the line "0". Line i is at y = i * lineHeight.
    Because: R1, R2, R11
    Instead of: measured heights per line (needs layout of every line, or
    estimates and scroll-offset corrections; re_editor commit 04b240d shows
    that correction loop can freeze an app).
```

```
D3: The block height is lineCount * lineHeight. The block width is the
    width of the longest line. For a run of ASCII text, the width is the
    character count times the advance of that run's style. Each distinct
    style is measured once. A line with any non-ASCII character gets a real
    layout for its width, and the width is cached by span identity.
    Because: R1, R4, R6, R10
    Instead of: width from the lines laid out so far (re_editor; the width
    changes while the user scrolls).
```

```
D4: The advance check: if one style gives different advances for "i" and
    "W", the font is not monospace. Then every line gets a real layout for
    its width, once, when its span changes. Painting stays virtual.
    Because: R6, R10
    Instead of: refusing proportional fonts (the app does not control every
    theme).
```

```
D5: The visible rect is this box intersected with every ancestor
    RenderAbstractViewport and the root view, in local coordinates. Paint
    draws the visible rect plus one visible extent on each side (the
    painted rect). After every frame, a post-frame callback checks whether
    the visible rect left the painted rect, and calls markNeedsPaint if so.
    Because: R1
    Instead of: Canvas.getLocalClipBounds (the block is under a
    RepaintBoundary, so the canvas clip is the block's own bounds);
    listeners on ancestor ScrollPositions (they miss the box moving when
    content above it changes size; the post-frame check covers scrolling
    and that, and the margin of one visible extent hides the one-frame
    delay); a repaint on every scroll tick.
```

```
D6: Lines are laid out during paint, only for lines in the painted rect.
    Each line is a TextPainter with the forced strut, cached by (line
    index, identical span). The paint cache keeps at most 512 painters and
    disposes the least recently used. Text queries for lines that are not
    painted (the streaming fade, selection edges) use a second cache of 32,
    so they do not push out painted lines.
    Because: R1, R4
    Instead of: ParagraphBuilder per line (TextPainter gives the caret,
    box, word and position queries that selection and the fade need); a
    cache keyed by TextSpan equality (re_editor; equality walks the span
    tree).
```

```
D7: A line longer than 4,096 characters is laid out in pieces of 4,096
    characters, only for pieces that intersect the painted rect. Piece
    boundaries move back to a grapheme boundary. This applies only to a line
    whose width came from the ASCII rule of D3, so x of a piece is its first
    column times the advance.
    Because: R1
    Instead of: one layout of the whole long line (32,509 characters in the
    measured case); truncation of long lines (re_editor; loses text, fails
    R5).
```

```
D8: RenderCodeBlock is one Selectable for the whole block. A selection
    edge maps to a line by y / lineHeight, and to a column by layout of that
    line only. The selection is (line, column) to (line, column).
    getSelectedContent returns the shown text of that range (a tab is the
    spaces that are shown, as before), joined with "\n", with no layout.
    Select-all lays out only the two edge lines, for the handles. A drag
    beside the block selects to the start or end of the line at that
    height. A triple click selects one line.
    Because: R1, R5
    Instead of: a Selectable per line (needs a registered object per line,
    which is O(N) again).
```

```
D9: Copy uses one DisplayedTextFragment for the block, with the line breaks
    already in its text. One SourceAwareWidget with the code block node
    wraps the block; the serializer needs no change.
    MarkdownSourceAttachment.codeLine is deprecated and no longer set.
    Because: R5
    Instead of: one fragment per selected line (O(selected lines) objects
    for a select-all of 21,666 lines).
```

```
D10: CmarkStreamingReveal reads text through a private interface,
     _RevealText: caret offset, boxes for a range, position for an offset,
     and line height. A paragraph and one code line each implement it. A
     code block gives the fade only its lines from just before the tail to
     just after the head, at most the fade's band limit plus two.
     Because: R7, R1
     Instead of: CmarkRevealStyle.whole for code blocks (visible change in
     streaming).
```

```
D11: Semantics: one node with the text of the lines in the painted rect.
     It updates when the painted rect changes.
     Because: R9, R1
     Instead of: a label with the whole block (2.3 MB string in the
     semantics tree); no semantics (re_editor; fails R9).
```

## 4. Invariants

```
I1: Building and painting a block of N lines lays out at most
    visibleLines + 2 * viewportLines + 2 paragraphs.
    If violated: the hang comes back, in proportion to N.
    Pinned by: test/code_block_render_object_test.dart (planned), counts
    layouts for N = 50 and N = 50,000 with a debug counter.
```

```
I2: An appended chunk that changes only the last line lays out at most one
    paragraph and does not lay out the block again unless lineCount or the
    width changes.
    If violated: streaming becomes O(N) per chunk.
    Pinned by: test/code_block_streaming_test.dart (extend).
```

```
I3: The block's size equals (lineCount * lineHeight, maxLineWidth) and does
    not change when the user scrolls.
    If violated: scroll jumps, and the horizontal scrollbar changes length.
    Pinned by: planned test that scrolls a 10,000-line block and checks size.
```

```
I4: Copy of a select-all returns the block's code text exactly, for a text
    with empty lines, tabs, emoji, combining marks and right-to-left text.
    If violated: users get wrong code on paste.
    Pinned by: planned test against the source literal.
```

```
I5: Colors of every line equal the colors of the current per-line renderer
    for the same input.
    If violated: R3 fails.
    Pinned by: planned test that compares the spans given to RenderCodeBlock
    with HighlightAdapter.buildLines output; existing goldens.
```

```
I6: A hit test does not visit lines.
    If violated: R2 fails.
    Pinned by: planned test with a debug counter.
```

## 5. Formats & names

| Name | Kind | Note |
|---|---|---|
| `CodeBlockLines` | `LeafRenderObjectWidget` | Exported, so apps and tests can find code text. Takes `lines`, `style`, `textScaler`, `selectable`. |
| `RenderCodeBlock` | `RenderBox` with `Selectable`, `SelectionRegistrant` | Not exported. |
| `_RevealText` | private interface in `streaming_reveal.dart` | A paragraph or one code line, for the fade. |
| `MarkdownSourceAttachment.codeLine` | field | `@Deprecated`. Removed in the next major version. |
| `_maxCachedPainters` | constant | 512 |
| `_maxQueryPainters` | constant | 32 |
| `RenderCodeBlock.linePieceLength` | constant | 4,096 characters |

## 6. Non-goals

```
NG1: Line wrapping in code blocks.
     Reopens when: a product requirement asks for wrapped code.
```

```
NG2: Pieces for long non-ASCII lines (D7 covers only ASCII-width lines).
     Reopens when: a profile shows layout of one non-ASCII line above 16 ms.
```

```
NG3: Virtual layout for other block types (paragraphs, tables).
     Reopens when: a profile shows another block type above 16 ms per frame.
```

```
NG4: Editing.
     Reopens when: never in this package.
```

## 7. Risks

1. **Copy changes.** Users paste code from conversations. A copy that loses
   a line break, an empty line or a tab is a silent data error. I4 pins it.
   This is the highest risk because users do not notice it at once.
2. **Selection behavior in the forked `SelectableRegion`.** The fork sorts
   selectables and groups them by `RenderParagraph` (`groupRect` near line
   3180 of `lib/src/flutter/selectable_region.dart`). A non-paragraph
   selectable can sort or group wrong. `_RenderInlineMathSelectable` is an
   existing non-paragraph selectable and shows the pattern.
3. **Public API.** `codeLine` is exported. A removal breaks callers, so it
   is deprecated first (D9).
4. **Tests that find code text by widget.** Four package test files and some
   app tests find code lines as `RichText` or `Text`. They must change to a
   finder on `CodeBlockLines`.
5. **Goldens.** D2 forces the strut on code lines. Lines with emoji can get
   a different height, so some goldens change.
6. **Scroll listening.** A missed ancestor scrollable gives blank lines on
   screen. The view bounds in D5 limit the damage: the block paints at most
   the screen.

## 8. Workplan

1. Add debug counters for paragraph layouts and hit-test line visits. Write
   the I1, I3 and I6 tests against the current renderer. Record the failing
   numbers.
2. Write `RenderCodeBlock` with size (D2, D3, D4) and paint (D5, D6). No
   selection. Use it only when `context.selectable` is false.
3. Make I1, I3, I5 and I6 pass. Run the package goldens. Review the changed
   goldens by eye.
4. Add D7 (long-line pieces). Add a test with a 40,000-character line.
5. Add `_RevealText` (D10). Move `_RenderReveal` to it. Run the reveal tests
   with no other change.
6. Add the `Selectable` (D8) and the copy fragment (D9). Write I4. Test
   drag selection, select-all, word selection and keyboard extension in a
   long block inside a scroll view.
7. Use `RenderCodeBlock` for selectable blocks too. Delete the per-line
   path. Deprecate `codeLine`.
8. Add semantics (D11) and a semantics test.
9. Update the four package test files. Run all package tests on the VM and
   in Chrome (dart2js and dart2wasm).
10. In the Telosnex app, point cmark_gfm_widget at the local checkout. Run
    the affected tests. Open the ledger entry for `slowOpus.txt` in debug and
    in release, and record the first frame time and a profile.
11. Release a minor version of cmark_gfm_widget. Repin the app.

──────── non-normative ────────

## A. Alternatives & notes

- **Chunk the text before rendering** (ledger only). Rejected by R3 and R8:
  a chunk boundary inside a block comment or a multi-line string changes
  colors, and only one screen gets the fix.
- **Line widgets in groups of 64.** Measured: debug first frame 7,404 ms to
  874 ms, hit tests near zero. Rejected by R1: release still lays out all
  2.34 M characters. It is a possible stopgap before this ADR ships.
- **One paragraph for the whole block** (before commit `3899a1c`). Rejected
  by R1 and R4: it lays out all text, and again on every chunk.
- **A sliver document.** Rejected by R8: message items are boxes, so a
  sliver code block cannot nest in a conversation.
- **re_editor** (`~/dev/re-editor`). Its `_CodeFieldRender` is the model for
  D1, D2 and D6. Differences: it owns its scroll position (we cannot, D5),
  it computes width from the shown lines (D3), it keys its cache by span
  equality and never trims it (D6), it truncates long lines (D7), its
  selection is a custom overlay, not `Selectable` (D8), and it has no
  semantics (D11).

## B. Results

Telosnex app, debug widget test, `slowOpus.txt` in the LLM Ledger layout
(21,666 lines), cmark_gfm_widget 1.0.3 against this change:

| Measurement | 1.0.3 | 1.1.0 |
|---|---:|---:|
| First frame | 7,866 ms | 810 ms |
| Frame after the final highlight arrives | 1,549 ms | 11 ms |
| 20 hit tests | 64 ms | 7 ms |
| Frame after a 20,000 px scroll | 273 ms | 38 ms |

Most of the remaining first frame is the highlight parse of 2.3 MB.

## C. Revision history

- 2026-11-15: First draft, after the LLM Ledger hang with `slowOpus.txt`.
- 2026-11-15: Implemented. D5 uses a post-frame check, not scroll
  listeners. D6 uses TextPainter and a second cache for queries. D8 and D9
  record copy and drag details. D10 uses a private per-line interface.
