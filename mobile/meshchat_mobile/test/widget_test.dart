import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/controllers/app_controller.dart';
import 'package:meshchat_mobile/src/pages/login_page.dart';

void main() {
  testWidgets('shows the MeshChat login screen', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LoginPage(controller: AppController())),
    );
    await tester.pump();

    expect(find.text('MeshChat'), findsOneWidget);
    expect(find.text('Login or create account'), findsOneWidget);
  });
}
