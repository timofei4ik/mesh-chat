import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/pages/document_scanner_page.dart';

void main() {
  testWidgets('document scanner fits a phone screen and exposes import tools', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(themeMode: ThemeMode.dark, home: DocumentScannerPage()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Document scanner'), findsOneWidget);
    expect(find.text('Add the first page'), findsOneWidget);
    expect(find.text('Choose photos'), findsOneWidget);
    expect(find.byTooltip('Scan with camera'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a selected photo opens preloaded in original mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pixel = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DocumentScannerPage(
          photoEditor: true,
          initialImages: [ScannerImageInput(name: 'photo.png', bytes: pixel)],
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();

    expect(find.text('Photo editor'), findsOneWidget);
    expect(find.text('Original'), findsOneWidget);
    expect(find.text('Send image'), findsOneWidget);
    expect(find.text('Add the first page'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
