import 'package:sentry_flutter/sentry_flutter.dart';

// Matches any key/field containing a display-name identifier, regardless of
// separator (camelCase, snake_case, or space-separated).
final _piiKeyRegex = RegExp(r'display[_ ]?name', caseSensitive: false);

// Matches "display_?name: <value>" in free-form text, capturing through the
// next comma or semicolon so multi-word values are fully redacted.
final _piiMessageRegex = RegExp(
  r'display[_ ]?name[:\s]*[^,;]+',
  caseSensitive: false,
);

// Matches any key/field containing a peer-id identifier.
final _peerIdKeyRegex = RegExp(r'peer[_\s]?id', caseSensitive: false);

// Matches "peer_?id: <value>" in free-form text.
final _peerIdMessageRegex = RegExp(
  r'peer[_\s]?id[:\s]*[^,;]+',
  caseSensitive: false,
);

bool _isPiiKey(String key) =>
    _piiKeyRegex.hasMatch(key) || _peerIdKeyRegex.hasMatch(key);

String _redactMessage(String msg) {
  var result = msg;
  if (_piiMessageRegex.hasMatch(result)) {
    result = result.replaceAll(_piiMessageRegex, 'displayName: [REDACTED]');
  }
  if (_peerIdMessageRegex.hasMatch(result)) {
    result = result.replaceAll(_peerIdMessageRegex, 'peerId: [REDACTED]');
  }
  return result;
}

/// Sanitizes Sentry events to remove PII before they are sent.
///
/// Redacts display names and peer IDs from contexts, tags, and breadcrumbs.
/// Peer IDs are intentionally stripped even though they are random UUIDs: the
/// privacy-first stance (and the Play Store Data Safety declaration) promises
/// no app-controlled identifiers reach Sentry. Sentry's own per-install
/// session ID covers "this install crashed N times" diagnostics without
/// exposing an app-level identifier.
SentryEvent? sanitizeSentryEvent(SentryEvent event) {
  // Strip PII-keyed context entries (Contexts is mutable in sentry 9.x).
  event.contexts.removeWhere((key, _) => _isPiiKey(key));

  // Strip PII-keyed tags.
  final tags = event.tags;
  if (tags != null && tags.keys.any(_isPiiKey)) {
    event.tags = Map.fromEntries(tags.entries.where((e) => !_isPiiKey(e.key)));
  }

  // Redact breadcrumbs in-place (Breadcrumb is mutable in sentry 9.x).
  for (final crumb in event.breadcrumbs ?? const []) {
    final msg = crumb.message;
    if (msg != null &&
        (_piiMessageRegex.hasMatch(msg) || _peerIdMessageRegex.hasMatch(msg))) {
      crumb.message = _redactMessage(msg);
    }

    final data = crumb.data;
    if (data != null && data.keys.any(_isPiiKey)) {
      crumb.data = <String, dynamic>{
        for (final e in data.entries)
          e.key: _isPiiKey(e.key) ? '[REDACTED]' : e.value,
      };
    }
  }

  return event;
}
