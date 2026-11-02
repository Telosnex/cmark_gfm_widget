import 'dart:math' as math;

/// The length of the start of [text] to parse while [text] streams.
///
/// It leaves out a last line that has no newline yet and has only `-` or
/// only `=` characters, after any spaces, tabs and `>` quote markers. Under a
/// paragraph, such a line makes the paragraph a heading. While a reply
/// streams, the line is usually the start of a list item, such as `- Next`,
/// so the paragraph would show as a heading for one chunk. When more text
/// arrives on the line, or its newline arrives, the line is parsed.
///
/// A line ends at `\n` or `\r`, as in CommonMark. The first line of [text]
/// is not left out: no block is before it. A line that is left out may not
/// be an underline, for example in a code block. Then it shows one chunk
/// later.
///
/// Parse all of [text] when the stream ends.
int cmarkStreamingParseLength(String text) {
  final lineStart =
      math.max(text.lastIndexOf('\n'), text.lastIndexOf('\r')) + 1;
  if (lineStart == 0) return text.length;
  int? mark;
  for (var i = lineStart; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x20 || c == 0x09) continue; // space, tab
    if (c == 0x3E && mark == null) continue; // '>' before the mark
    if ((c == 0x2D || c == 0x3D) && (mark == null || mark == c)) {
      mark = c; // '-' or '='
      continue;
    }
    return text.length;
  }
  return mark == null ? text.length : lineStart;
}
