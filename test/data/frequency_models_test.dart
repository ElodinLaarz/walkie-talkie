import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/data/frequency_models.dart';

void main() {
  group('formatTime', () {
    test('renders sub-minute durations as M:SS', () {
      expect(formatTime(0), '0:00');
      expect(formatTime(7), '0:07');
      expect(formatTime(59), '0:59');
    });

    test('renders multi-minute, sub-hour durations as M:SS', () {
      expect(formatTime(60), '1:00');
      expect(formatTime(125), '2:05');
      expect(formatTime(3599), '59:59');
    });

    test(
      'renders multi-hour durations as H:MM:SS, including the actual seconds',
      // Regression for gemini-code-assist comment on PR #153: the
      // pre-fix branch hardcoded `:00` for the seconds slot whenever
      // s >= 3600, so a long podcast would always render as e.g.
      // "1:42:00" no matter where the listener was inside that minute.
      () {
        expect(formatTime(3600), '1:00:00');
        expect(formatTime(3661), '1:01:01');
        // 1h 42m 37s — same magnitude as the longest fixture in the
        // mock catalog, which is what surfaced the bug.
        expect(formatTime(6157), '1:42:37');
        expect(formatTime(7322), '2:02:02');
      },
    );
  });
}
