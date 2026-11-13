import 'dart:math' as math;

/// The length of the start of [text] to parse while [text] streams.
///
/// It leaves out a last line that has no newline yet and is one of these,
/// after any spaces, tabs and `>` quote markers:
///
/// - Only `-` or only `=` characters. Under a paragraph, such a line makes
///   the paragraph a heading. While a reply streams, the line is usually the
///   start of a list item, such as `- Next`, so the paragraph would show as a
///   heading for one chunk. The first line of [text] is not left out for
///   this: no block is before it.
/// - A `<details>`, `<summary>` or `</details>` tag, or the start of one,
///   such as `<det`. The renderer shows these tags as a collapsible section,
///   so the line would show as raw HTML for a few chunks. This applies to the
///   first line too.
///
/// When more text arrives on the line, or its newline arrives, the line is
/// parsed. A line that is left out may not be what it looks like, for
/// example in a code block. Then it shows when its newline arrives.
///
/// Parse all of [text] when the stream ends.
int cmarkStreamingParseLength(String text) {
  final lineStart =
      math.max(text.lastIndexOf('\n'), text.lastIndexOf('\r')) + 1;
  int? mark;
  for (var i = lineStart; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x20 || c == 0x09) continue; // space, tab
    if (c == 0x3E && mark == null) continue; // '>' before the mark
    if (c == 0x3C && mark == null) {
      // '<'
      return _isDetailsTagLine(text, i) ? lineStart : text.length;
    }
    if (lineStart == 0) return text.length;
    if ((c == 0x2D || c == 0x3D) && (mark == null || mark == c)) {
      mark = c; // '-' or '='
      continue;
    }
    return text.length;
  }
  return mark == null ? text.length : lineStart;
}

const _detailsTags = ['<details', '</details', '<summary'];

/// Whether the rest of [text] from [start] is a details tag, or the start
/// of one. A tag name must end there or be followed by a space, `>` or `/`.
bool _isDetailsTagLine(String text, int start) {
  final rest = text.substring(start).toLowerCase();
  for (final tag in _detailsTags) {
    if (rest.length <= tag.length) {
      if (tag.startsWith(rest)) return true;
      continue;
    }
    if (!rest.startsWith(tag)) continue;
    final next = rest.codeUnitAt(tag.length);
    // space, tab, '>' or '/'
    if (next == 0x20 || next == 0x09 || next == 0x3E || next == 0x2F) {
      return true;
    }
  }
  return false;
}
