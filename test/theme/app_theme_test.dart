import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/theme/app_theme.dart';

void main() {
  group('AppTheme', () {
    test('light + dark themes attach FrequencyTheme extensions', () {
      final light = AppTheme.light();
      final dark = AppTheme.dark();
      expect(light.extension<FrequencyTheme>(), isNotNull);
      expect(dark.extension<FrequencyTheme>(), isNotNull);
    });

    testWidgets('FrequencyTheme.of pulls the extension from context', (
      tester,
    ) async {
      late FrequencyTheme captured;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (ctx) {
              captured = FrequencyTheme.of(ctx);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(captured, isNotNull);
    });
  });

  group('FrequencyTheme lerp + copyWith', () {
    test('copyWith returns a new instance with the same colors', () {
      final orig = AppTheme.light().extension<FrequencyTheme>()!;
      final copy = orig.copyWith();
      expect(identical(orig, copy), isFalse);
      expect(copy.colors, orig.colors);
    });

    test('copyWith with override returns the override', () {
      final orig = AppTheme.light().extension<FrequencyTheme>()!;
      final dark = AppTheme.dark().extension<FrequencyTheme>()!;
      final overridden = orig.copyWith(colors: dark.colors);
      expect(overridden.colors, dark.colors);
    });

    test('lerp returns this when other is not a FrequencyTheme', () {
      final orig = AppTheme.light().extension<FrequencyTheme>()!;
      expect(identical(orig.lerp(null, 0.5), orig), isTrue);
    });

    test('lerp with t < 0.5 returns this', () {
      final orig = AppTheme.light().extension<FrequencyTheme>()!;
      final dark = AppTheme.dark().extension<FrequencyTheme>()!;
      expect(identical(orig.lerp(dark, 0.0), orig), isTrue);
      expect(identical(orig.lerp(dark, 0.49), orig), isTrue);
    });

    test('lerp with t >= 0.5 returns other', () {
      final orig = AppTheme.light().extension<FrequencyTheme>()!;
      final dark = AppTheme.dark().extension<FrequencyTheme>()!;
      expect(identical(orig.lerp(dark, 0.5), dark), isTrue);
      expect(identical(orig.lerp(dark, 1.0), dark), isTrue);
    });
  });
}
