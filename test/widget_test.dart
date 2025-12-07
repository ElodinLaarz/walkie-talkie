import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/main.dart';
import 'package:hive/hive.dart';
import 'dart:io';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    final path = Directory.systemTemp.path;
    Hive.init(path);

    // Build our app and trigger a frame.
    await tester.pumpWidget(const WalkieTalkieApp());

    // Verify that the app starts
    expect(find.text('No devices connected'), findsOneWidget);
  });
}
