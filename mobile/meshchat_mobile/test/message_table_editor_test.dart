import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/widgets/message_table_editor.dart';

void main() {
  testWidgets('range edits and clipboard matrices survive saving on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    List? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('Open'),
              onPressed: () async {
                result = await showDialog<List>(
                  context: context,
                  builder: (_) => const MessageTableEditor(),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final target = find.byKey(const ValueKey('table-cell-1-0'));
    final rect = tester.getRect(target);
    for (final point in [
      rect.topLeft + const Offset(3, 3),
      rect.bottomRight - const Offset(3, 3),
      rect.center,
    ]) {
      await tester.tap(find.byKey(const ValueKey('table-cell-0-0')));
      await tester.pump();
      await tester.tapAt(point);
      await tester.pump();
      expect(find.text('A2'), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('table-cell-0-0')));
    await tester.pump();
    await tester.tap(find.byTooltip('Select range'));
    await tester.tap(find.byKey(const ValueKey('table-cell-1-1')));
    await tester.pump();
    expect(find.text('A1:B2'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('table-cell-input')),
      'Shared',
    );
    await tester.pump();
    expect(find.text('Shared'), findsNWidgets(5));
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => call.method == 'Clipboard.getData'
              ? {'text': 'A\tB\nC\tD'}
              : null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.tap(find.byTooltip('Table actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Insert'));
    await tester.pumpAndSettle();
    expect(result, [
      ['A', 'B', ''],
      ['C', 'D', ''],
      ['', '', ''],
    ]);
    expect(tester.takeException(), isNull);
  });
}
