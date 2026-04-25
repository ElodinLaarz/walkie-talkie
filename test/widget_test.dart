import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/main.dart';
import 'package:hive/hive.dart';
import 'dart:io';

void main() {
  testWidgets('App smoke test — onboarding welcome appears', (
    WidgetTester tester,
  ) async {
    final path = Directory.systemTemp.path;
    Hive.init(path);

    await tester.pumpWidget(const WalkieTalkieApp());
    await tester.pump();

    expect(find.text('Frequency'), findsOneWidget);
    expect(find.text('Get started'), findsOneWidget);
  });
}
