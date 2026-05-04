import 'package:sentry_flutter/sentry_flutter.dart';

// Matches any key/field that is a display-name identifier.
final _displayNameKeyRegex = RegExp(r'display[_ ]?name', caseSensitive: false);

// Matches display-name assignments in free-form text: colon, equals, or
// JSON-style ("key":"value") separators; optional surrounding quotes.
final _displayNameMessageRegex = RegExp(
  r'"?display[_ ]?name"?\s*[:=]\s*"?[^,;"{}]+',
  caseSensitive: false,
);

// Matches any key/field that is a peer-id identifier.
final _peerIdKeyRegex = RegExp(r'peer[_\s]?id', caseSensitive: false);

// Matches peer-id assignments in free-form text: colon, equals, or
// JSON-style ("key":"value") separators; optional surrounding quotes.
final _peerIdMessageRegex = RegExp(
  r'"?peer[_\s]?id"?\s*[:=]\s*"?[^,;"{}]+',
  caseSensitive: false,
);

bool _isPiiKey(String key) =>
    _displayNameKeyRegex.hasMatch(key) || _peerIdKeyRegex.hasMatch(key);

String _redactMessage(String msg) {
  var result = msg;
  if (_displayNameMessageRegex.hasMatch(result)) {
    result = result.replaceAll(
      _displayNameMessageRegex,
      'displayName: [REDACTED]',
    );
  }
  if (_peerIdMessageRegex.hasMatch(result)) {
    result = result.replaceAll(_peerIdMessageRegex, 'peerId: [REDACTED]');
  }
  return result;
}

// Recursively redacts PII from nested Map/List/String payloads so that values
// like {'room': {'peerId': 'abc'}} are sanitized even when the outer key is
// not itself a PII indicator.
dynamic _redactDeep(dynamic value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final e in value.entries)
        if (e.key is String)
          (e.key as String): _isPiiKey(e.key as String)
              ? '[REDACTED]'
              : _redactDeep(e.value),
    };
  }
  if (value is List) {
    return [for (final item in value) _redactDeep(item)];
  }
  if (value is String) {
    return _redactMessage(value);
  }
  return value;
}

/// Sanitizes Sentry events to remove PII before they are sent.
///
/// Redacts display names and peer IDs from contexts, tags, and breadcrumbs.
/// Peer IDs are intentionally stripped even though they are random UUIDs: the
/// privacy-first stance (and the Play Store Data Safety declaration) promises
/// no app-controlled identifiers reach Sentry. Sentry's own SDK-generated
/// session identifiers cover crash-frequency diagnostics without exposing an
/// app-level identifier.
SentryEvent? sanitizeSentryEvent(SentryEvent event) {
  // Strip PII-keyed context entries; deep-scan remaining values for nested PII.
  event.contexts.removeWhere((key, _) => _isPiiKey(key));
  for (final key in event.contexts.keys.toList()) {
    final val = event.contexts[key];
    if (val is Map || val is List || val is String) {
      event.contexts[key] = _redactDeep(val);
    }
  }

  // Strip PII-keyed tags.
  final tags = event.tags;
  if (tags != null && tags.keys.any(_isPiiKey)) {
    event.tags = Map.fromEntries(tags.entries.where((e) => !_isPiiKey(e.key)));
  }

  // Redact breadcrumbs in-place (Breadcrumb is mutable in sentry 9.x).
  for (final crumb in event.breadcrumbs ?? const []) {
    final msg = crumb.message;
    if (msg != null &&
        (_displayNameMessageRegex.hasMatch(msg) ||
            _peerIdMessageRegex.hasMatch(msg))) {
      crumb.message = _redactMessage(msg);
    }

    final data = crumb.data;
    if (data != null) {
      crumb.data = <String, dynamic>{
        for (final e in data.entries)
          e.key: _isPiiKey(e.key) ? '[REDACTED]' : _redactDeep(e.value),
      };
    }
  }

  return event;
}
