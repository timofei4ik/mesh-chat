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
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Login'), findsWidgets);
    expect(find.text('Register'), findsOneWidget);

    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();

    expect(find.text('Create your MeshChat account'), findsOneWidget);
    expect(find.text('@username'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
  });

  testWidgets('opens password recovery without leaving the login screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: LoginPage(controller: AppController())),
    );
    await tester.pump();

    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();

    expect(find.text('Recover account'), findsOneWidget);
    expect(find.text('Send recovery code'), findsOneWidget);
    expect(find.text('Back to login'), findsOneWidget);
  });
}
