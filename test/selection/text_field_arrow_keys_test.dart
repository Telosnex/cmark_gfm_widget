import 'package:cmark_gfm_widget/cmark_gfm_widget.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' hide SelectionArea;

void main() {
  // A SelectableRegion overrides the caret-movement actions of text fields
  // inside it. Each override must hand the key back to the field.
  testWidgets('arrow keys move the caret in a text field inside SelectionArea',
      (tester) async {
    final controller = TextEditingController(text: 'abc\ndef');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: TextField(controller: controller, maxLines: null),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    controller.selection = const TextSelection.collapsed(offset: 5);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 4));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 5));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 1));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 5));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();
    expect(
      controller.selection,
      const TextSelection(baseOffset: 5, extentOffset: 1),
    );
  }, variant: TargetPlatformVariant.all());

  // The word, line, document, and select-all keys each go through their own
  // region action. The keys differ between Apple and other platforms.
  // Text: 'one two' (0-7), newline (7), 'three four' (8-18).
  testWidgets(
      'word, line, and document keys move the caret in a text field '
      'inside SelectionArea', (tester) async {
    final controller = await _pumpField(tester, 'one two\nthree four');
    final apple = switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.macOS => true,
      _ => false,
    };
    // Apple: Option moves by word, Cmd by line or document.
    // Others: Ctrl moves by word, Alt by line or document.
    final wordMods =
        apple ? [LogicalKeyboardKey.alt] : [LogicalKeyboardKey.control];
    final lineMods =
        apple ? [LogicalKeyboardKey.meta] : [LogicalKeyboardKey.alt];
    const shift = LogicalKeyboardKey.shift;

    controller.selection = const TextSelection.collapsed(offset: 13);
    await tester.pump();

    // ExtendSelectionToNextWordBoundaryIntent.
    await _press(tester, LogicalKeyboardKey.arrowLeft, wordMods);
    expect(_offsets(controller), (8, 8));

    // Apple: ExtendSelectionToNextWordBoundaryOrCaretLocationIntent.
    // Others: ExtendSelectionToNextWordBoundaryIntent, extending.
    await _press(tester, LogicalKeyboardKey.arrowRight, [...wordMods, shift]);
    expect(_offsets(controller), (8, 13));

    // ExtendSelectionToLineBreakIntent.
    await _press(tester, LogicalKeyboardKey.arrowRight, lineMods);
    expect(_offsets(controller), (18, 18));

    // Apple: ExpandSelectionToLineBreakIntent.
    // Others: ExtendSelectionToLineBreakIntent, extending.
    await _press(tester, LogicalKeyboardKey.arrowLeft, [...lineMods, shift]);
    expect(_offsets(controller), (18, 8));

    // ExtendSelectionToDocumentBoundaryIntent.
    await _press(tester, LogicalKeyboardKey.arrowUp, lineMods);
    expect(_offsets(controller), (0, 0));

    // Apple: ExpandSelectionToDocumentBoundaryIntent.
    // Others: ExtendSelectionToDocumentBoundaryIntent, extending.
    await _press(tester, LogicalKeyboardKey.arrowDown, [...lineMods, shift]);
    expect(_offsets(controller), (0, 18));

    controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.pump();

    // SelectAllTextIntent.
    await _press(
      tester,
      LogicalKeyboardKey.keyA,
      [if (apple) LogicalKeyboardKey.meta else LogicalKeyboardKey.control],
    );
    expect(_offsets(controller), (0, 18));
  }, variant: TargetPlatformVariant.all());
}

Future<TextEditingController> _pumpField(
  WidgetTester tester,
  String text,
) async {
  final controller = TextEditingController(text: text);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SelectionArea(
          child: TextField(controller: controller, maxLines: null),
        ),
      ),
    ),
  );
  await tester.tap(find.byType(TextField));
  await tester.pump();
  return controller;
}

Future<void> _press(
  WidgetTester tester,
  LogicalKeyboardKey key,
  List<LogicalKeyboardKey> modifiers,
) async {
  for (final modifier in modifiers) {
    await tester.sendKeyDownEvent(modifier);
  }
  await tester.sendKeyEvent(key);
  for (final modifier in modifiers.reversed) {
    await tester.sendKeyUpEvent(modifier);
  }
  await tester.pump();
}

/// (base, extent). The caret affinity at a line end isn't under test.
(int, int) _offsets(TextEditingController controller) =>
    (controller.selection.baseOffset, controller.selection.extentOffset);
