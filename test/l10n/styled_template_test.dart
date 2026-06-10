import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/l10n/styled_template.dart';

void main() {
  const valueStyle = TextStyle(fontWeight: FontWeight.bold);
  const surroundingStyle = TextStyle(fontStyle: FontStyle.italic);

  group('styledTemplate', () {
    test('single placeholder produces prefix + value + suffix spans', () {
      // Simulates a template like "Join {freq} now".
      String template(String s) => 'Join $s now';
      final spans = styledTemplate(
        template: template,
        value: '92.5',
        valueStyle: valueStyle,
        surroundingStyle: surroundingStyle,
      );
      expect(spans.length, 3);
      expect((spans[0] as TextSpan).text, 'Join ');
      expect((spans[0] as TextSpan).style, surroundingStyle);
      expect((spans[1] as TextSpan).text, '92.5');
      expect((spans[1] as TextSpan).style, valueStyle);
      expect((spans[2] as TextSpan).text, ' now');
      expect((spans[2] as TextSpan).style, surroundingStyle);
    });

    test('placeholder at start: value span comes first', () {
      String template(String s) => '${s}MHz';
      final spans = styledTemplate(
        template: template,
        value: '101',
        valueStyle: valueStyle,
      );
      // Empty prefix part is dropped; only value + suffix.
      expect(spans.length, 2);
      expect((spans[0] as TextSpan).text, '101');
      expect((spans[1] as TextSpan).text, 'MHz');
    });

    test('placeholder at end: value span comes last', () {
      String template(String s) => 'Freq: $s';
      final spans = styledTemplate(
        template: template,
        value: '107.9',
        valueStyle: valueStyle,
      );
      // Empty suffix part is dropped; only prefix + value.
      expect(spans.length, 2);
      expect((spans[0] as TextSpan).text, 'Freq: ');
      expect((spans[1] as TextSpan).text, '107.9');
    });

    test('surrounding style is null when not provided', () {
      String template(String s) => 'a${s}b';
      final spans = styledTemplate(
        template: template,
        value: 'X',
        valueStyle: valueStyle,
      );
      expect((spans[0] as TextSpan).style, isNull);
    });

    test('empty surrounding text parts are omitted', () {
      // Template with no text around the placeholder.
      String template(String s) => s;
      final spans = styledTemplate(
        template: template,
        value: '88',
        valueStyle: valueStyle,
      );
      expect(spans.length, 1);
      expect((spans[0] as TextSpan).text, '88');
    });

    test('template that drops the placeholder asserts in debug', () {
      // A translation that omits {freq}, or a function that ignores its
      // argument, renders no sentinel. Asserts are enabled under `flutter
      // test`, so the broken template must surface as an AssertionError rather
      // than silently dropping the value.
      String template(String s) => 'Join now';
      expect(
        () => styledTemplate(
          template: template,
          value: '92.5',
          valueStyle: valueStyle,
        ),
        throwsAssertionError,
      );
    });

    test('value is inserted only once for single placeholder', () {
      String template(String s) => 'before${s}after';
      final spans = styledTemplate(
        template: template,
        value: 'VAL',
        valueStyle: valueStyle,
      );
      final valueSpans = spans
          .whereType<TextSpan>()
          .where((s) => s.text == 'VAL')
          .toList();
      expect(valueSpans.length, 1);
    });
  });
}
