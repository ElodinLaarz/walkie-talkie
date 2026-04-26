import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/main.dart';
import 'package:walkie_talkie/services/identity_store.dart';

class _FakeIdentityStore implements IdentityStore {
  String? _name;
  _FakeIdentityStore({String? initial}) : _name = initial;

  @override
  Future<String?> getDisplayName() async => _name;

  // Mirror HiveIdentityStore: trim, and treat empty/whitespace as a clear.
  @override
  Future<void> setDisplayName(String value) async {
    final trimmed = value.trim();
    _name = trimmed.isEmpty ? null : trimmed;
  }
}

void main() {
  testWidgets('first launch routes through onboarding', (tester) async {
    await tester.pumpWidget(WalkieTalkieApp(identityStore: _FakeIdentityStore()));
    // Boot splash → microtask flush → onboarding welcome.
    await tester.pump();
    await tester.pump();

    expect(find.text('Frequency'), findsOneWidget);
    expect(find.text('Get started'), findsOneWidget);
  });

  testWidgets(
    'subsequent launches with a persisted name skip onboarding and land on Discovery',
    (tester) async {
      await tester.pumpWidget(
        WalkieTalkieApp(identityStore: _FakeIdentityStore(initial: 'Maya')),
      );
      // Two frames: boot splash, then Discovery after the bootstrap setState.
      // Avoid pumpAndSettle — Discovery has a perpetual PulseDot animation.
      await tester.pump();
      await tester.pump();

      expect(find.text('Phones around you,\non the same wavelength.'),
          findsOneWidget);
      expect(find.text('Get started'), findsNothing);
      expect(find.text('MA'), findsOneWidget);
    },
  );
}
