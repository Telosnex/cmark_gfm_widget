import 'package:cmark_gfm_widget/src/render/stable_table.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Widget table(Color color, {int rows = 3}) => Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: StableTable(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            children: [
              for (var y = 0; y < rows; y++)
                TableRow(
                  children: [
                    for (var x = 0; x < 3; x++)
                      Text('cell $x,$y', style: TextStyle(color: color)),
                  ],
                ),
            ],
          ),
        ),
      );

  StableRenderTable renderTable(WidgetTester tester) =>
      tester.renderObject(find.byType(StableTable));

  testWidgets('rebuild with the same cells does not relayout the table', (
    tester,
  ) async {
    await tester.pumpWidget(table(const Color(0xff000000)));
    final render = renderTable(tester);

    await tester.pumpWidget(
      table(const Color(0xffff0000)),
      phase: EnginePhase.build,
    );

    expect(render.debugNeedsLayout, isFalse);
    // The recolor still happened: it's a paint-only change in the cells.
    final paragraph = tester.renderObject<RenderParagraph>(
      find.text('cell 0,0'),
    );
    expect(paragraph.text.style!.color, const Color(0xffff0000));
  });

  testWidgets('a plain Table relayouts on the same rebuild', (tester) async {
    // Documents the Flutter behavior StableTable exists to avoid. If this
    // starts failing, Flutter fixed it and StableTable can go.
    Widget plain(Color color) => Directionality(
          textDirection: TextDirection.ltr,
          child: Table(
            children: [
              TableRow(
                children: [Text('cell', style: TextStyle(color: color))],
              ),
            ],
          ),
        );
    await tester.pumpWidget(plain(const Color(0xff000000)));
    final render = tester.renderObject<RenderTable>(find.byType(Table));

    await tester.pumpWidget(
      plain(const Color(0xffff0000)),
      phase: EnginePhase.build,
    );

    expect(render.debugNeedsLayout, isTrue);
  });

  testWidgets('adding and removing rows still lays out', (tester) async {
    await tester.pumpWidget(table(const Color(0xff000000)));
    final render = renderTable(tester);
    final height = render.size.height;

    await tester.pumpWidget(table(const Color(0xff000000), rows: 5));
    expect(render.rows, 5);
    expect(render.size.height, greaterThan(height));
    expect(find.text('cell 2,4'), findsOneWidget);

    await tester.pumpWidget(table(const Color(0xff000000), rows: 2));
    expect(render.rows, 2);
    expect(render.size.height, lessThan(height));
  });

  testWidgets('a cell whose size changes still relayouts the table', (
    tester,
  ) async {
    Widget sized(double width) => Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: StableTable(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              children: [
                TableRow(children: [SizedBox(width: width, height: 10)]),
              ],
            ),
          ),
        );
    await tester.pumpWidget(sized(50));
    expect(renderTable(tester).size.width, 50);

    await tester.pumpWidget(sized(120));
    expect(renderTable(tester).size.width, 120);
  });

  testWidgets('swapping a cell for a different widget type relayouts', (
    tester,
  ) async {
    Widget withCell(Widget cell) => Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: StableTable(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              children: [
                TableRow(children: [cell]),
              ],
            ),
          ),
        );
    await tester.pumpWidget(withCell(const SizedBox(width: 40, height: 10)));
    await tester.pumpWidget(
      withCell(const ColoredBox(
        color: Color(0xff00ff00),
        child: SizedBox(width: 90, height: 10),
      )),
    );
    expect(renderTable(tester).size.width, 90);
    expect(find.byType(ColoredBox), findsOneWidget);
  });
}
