import 'package:pixel_snap_fork/material.dart';

import '../render/render_pipeline.dart';

/// The default `<details>` section: a summary row with a chevron that opens
/// and closes the section.
///
/// It starts open when the `<details>` tag has the `open` attribute. While
/// closed, the body is not built, so it cannot be selected or copied.
///
/// A [DetailsBuilder] can return this widget, for example inside its own
/// decoration.
class CmarkDetails extends StatefulWidget {
  const CmarkDetails({super.key, required this.data});

  final CmarkDetailsData data;

  @override
  State<CmarkDetails> createState() => _CmarkDetailsState();
}

class _CmarkDetailsState extends State<CmarkDetails> {
  late bool _open = widget.data.initiallyOpen;

  void _toggle() => setState(() => _open = !_open);

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final style = data.theme.paragraphTextStyle;
    final iconSize = (style.fontSize ?? 14) * 1.25;
    const gap = 4.0;
    final header = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: Semantics(
          button: true,
          expanded: _open,
          child: Row(
            children: [
              Icon(
                _open ? Icons.expand_more : Icons.chevron_right,
                size: iconSize,
                color: style.color,
              ),
              const SizedBox(width: gap),
              Flexible(child: data.summary),
            ],
          ),
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        if (_open)
          Padding(
            padding: EdgeInsets.only(
              left: iconSize + gap,
              top: data.theme.blockSpacing,
            ),
            child: data.body,
          ),
      ],
    );
  }
}
