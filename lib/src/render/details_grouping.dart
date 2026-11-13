import 'package:cmark_gfm_dart/cmark_gfm_dart.dart';

// Pairs `<details>` and `</details>` HTML blocks, so the blocks between them
// can show as one collapsible section, as on GitHub.
//
// CommonMark makes `<details>`, `<summary>` and `</details>` at the start of
// a line into HTML blocks, and parses the Markdown between them as usual
// blocks. Nothing in the parse tree pairs them. [groupDetails] does that for
// a list of sibling blocks.

/// An item in the result of [groupDetails].
sealed class DetailsItem {}

/// A block that is not part of a `<details>` tag.
final class DetailsBlockItem extends DetailsItem {
  DetailsBlockItem(this.node);

  final CmarkNode node;
}

/// A `<details>` section and the blocks in it.
final class DetailsGroupItem extends DetailsItem {
  DetailsGroupItem(this.opener, this.indexInOpener, this.initiallyOpen);

  /// The HTML block with the `<details>` tag.
  final CmarkNode opener;

  /// Which `<details>` tag of [opener] this is: 0 for the first. One HTML
  /// block can hold more than one tag, such as `<details><details>`.
  final int indexInOpener;

  /// Whether the tag has the `open` attribute.
  final bool initiallyOpen;

  /// The text of the `<summary>` tag, or null if there is none.
  String? summaryText;

  /// The blocks in the section, in document order.
  final List<DetailsItem> children = [];

  /// The HTML block with the matching `</details>` tag. Null while the tag
  /// has not arrived: then the section runs to the end of the blocks.
  CmarkNode? closer;
}

/// Groups [nodes], which are siblings in document order.
///
/// An HTML block that holds only `<details>`, `<summary>…</summary>` and
/// `</details>` tags gives no item of its own. A `<details>` tag starts a
/// group, and the blocks after it go in the group until the matching
/// `</details>`. A group with no `</details>` runs to the end of [nodes], as
/// in a browser. A `</details>` with no open group is left out.
///
/// Other HTML blocks stay blocks. For example, when a `<summary>` line is
/// followed by text with no blank line between, CommonMark makes them one
/// HTML block, and the block shows as text, as on GitHub.
List<DetailsItem> groupDetails(Iterable<CmarkNode> nodes) {
  final top = <DetailsItem>[];
  final stack = <DetailsGroupItem>[];
  for (final node in nodes) {
    final tags = _parseDetailsTags(node);
    if (tags == null || !_canApply(tags, stack.length)) {
      (stack.isEmpty ? top : stack.last.children).add(DetailsBlockItem(node));
      continue;
    }
    var opens = 0;
    for (final tag in tags) {
      switch (tag) {
        case _Open(:final open):
          final group = DetailsGroupItem(node, opens++, open);
          (stack.isEmpty ? top : stack.last.children).add(group);
          stack.add(group);
        case _Summary(:final text):
          stack.last.summaryText ??= text;
        case _Close():
          if (stack.isNotEmpty) stack.removeLast().closer = node;
      }
    }
  }
  return top;
}

/// Whether [tags] make sense with [depth] groups open: a `<summary>` needs
/// an open group.
bool _canApply(List<_Tag> tags, int depth) {
  for (final tag in tags) {
    switch (tag) {
      case _Open():
        depth++;
      case _Summary():
        if (depth == 0) return false;
      case _Close():
        if (depth > 0) depth--;
    }
  }
  return true;
}

sealed class _Tag {}

final class _Open extends _Tag {
  _Open(this.open);

  final bool open;
}

final class _Summary extends _Tag {
  _Summary(this.text);

  final String? text;
}

final class _Close extends _Tag {}

final _tagPattern = RegExp(
  r'\s+'
  r'|<details(\s[^>]*)?>'
  r'|</details\s*>'
  r'|<summary(?:\s[^>]*)?>([\s\S]*?)</summary\s*>',
  caseSensitive: false,
);

final _openAttribute = RegExp(
  r'(?:^|\s)open(?:\s|=|/|$)',
  caseSensitive: false,
);

/// The tags in [node], or null if it is not an HTML block of only
/// `<details>`, `<summary>` and `</details>` tags.
List<_Tag>? _parseDetailsTags(CmarkNode node) {
  if (node.type != CmarkNodeType.htmlBlock) return null;
  final text = node.contentString;
  final tags = <_Tag>[];
  var i = 0;
  while (i < text.length) {
    final match = _tagPattern.matchAsPrefix(text, i);
    if (match == null) return null;
    final source = match.group(0)!;
    if (source.startsWith('</')) {
      tags.add(_Close());
    } else if (source.startsWith('<')) {
      final details = source[1] == 'd' || source[1] == 'D';
      tags.add(
        details
            ? _Open(_openAttribute.hasMatch(match.group(1) ?? ''))
            : _Summary(_summaryText(match.group(2)!)),
      );
    }
    i = match.end;
  }
  return tags.isEmpty ? null : tags;
}

final _anyTag = RegExp(r'<[^>]*>');
final _whitespace = RegExp(r'\s+');
final _entity = RegExp(r'&(amp|lt|gt|quot|apos|nbsp|#39);');

/// The plain text of a `<summary>` tag's content: tags are left out, common
/// entities are decoded, and whitespace is collapsed. Null when empty.
String? _summaryText(String html) {
  final text = html
      .replaceAll(_anyTag, '')
      .replaceAllMapped(
        _entity,
        (m) => switch (m.group(1)) {
          'amp' => '&',
          'lt' => '<',
          'gt' => '>',
          'quot' => '"',
          'apos' || '#39' => "'",
          _ => ' ',
        },
      )
      .replaceAll(_whitespace, ' ')
      .trim();
  return text.isEmpty ? null : text;
}
