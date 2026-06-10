import 'package:flutter/widgets.dart';

/// Sentinel passed in for an `AppLocalizations` placeholder so the call-site
/// can split the rendered string and apply a different style to the slot
/// where the value would have been.
///
/// U+E000 sits in the Private Use Area — translators won't accidentally type
/// it and ICU MessageFormat does not assign it any meaning.
const String _kSentinel = '';

/// Renders a localized template that has exactly one placeholder (typically a
/// frequency) where that placeholder needs a different `TextStyle` than the
/// surrounding copy.
///
/// Usage:
///
///     Text.rich(TextSpan(children: styledTemplate(
///       template: l10n.discoveryRecentRowHostFreq, // String Function(String)
///       value: '92.5',
///       valueStyle: kMonoStyle,
///     )));
///
/// Why a sentinel: the gen-l10n bindings interpolate the placeholder before
/// returning the string, so we cannot inspect the raw `{freq}` token. Passing
/// a Private-Use-Area code point that won't appear in any translation gives
/// us a deterministic split point in any locale.
List<InlineSpan> styledTemplate({
  required String Function(String) template,
  required String value,
  required TextStyle? valueStyle,
  TextStyle? surroundingStyle,
}) {
  final rendered = template(_kSentinel);
  final parts = rendered.split(_kSentinel);
  // A rendered string with no sentinel means the template dropped its
  // placeholder (a translation that omits `{freq}`, or a function that ignores
  // its argument). `split` would then yield a single part and `value` — a
  // load-bearing frequency — would be silently dropped from the UI. Catch the
  // broken template in debug, and in release still append `value` so the
  // frequency is never lost.
  if (parts.length < 2) {
    assert(
      false,
      'styledTemplate: rendered string contains no placeholder sentinel — '
      'the template dropped its argument. Rendered: "$rendered"',
    );
    return [
      if (rendered.isNotEmpty) TextSpan(text: rendered, style: surroundingStyle),
      TextSpan(text: value, style: valueStyle),
    ];
  }
  final spans = <InlineSpan>[];
  for (var i = 0; i < parts.length; i++) {
    if (parts[i].isNotEmpty) {
      spans.add(TextSpan(text: parts[i], style: surroundingStyle));
    }
    if (i < parts.length - 1) {
      spans.add(TextSpan(text: value, style: valueStyle));
    }
  }
  return spans;
}
