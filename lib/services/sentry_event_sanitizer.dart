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

// Matches a Bluetooth MAC address (six colon- or hyphen-separated hex pairs).
// The control plane and audio service interpolate `$endpointId` (a BT MAC)
// into log messages, exception strings, and breadcrumb data. A MAC is a
// stable per-device identifier and must not reach Sentry.
final _macAddressRegex = RegExp(
  r'\b[0-9A-F]{2}([:-][0-9A-F]{2}){5}\b',
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
  if (_macAddressRegex.hasMatch(result)) {
    result = result.replaceAll(_macAddressRegex, '[MAC_REDACTED]');
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

// Rebuild a stack frame with PII-redacted `vars`. SentryStackFrame exposes
// `vars` as an unmodifiable view (no setter) in sentry 9.x, so we have to
// reconstruct the frame to update them. Filenames / line numbers / function
// names / etc. are copied through verbatim.
SentryStackFrame _scrubFrame(SentryStackFrame f) {
  if (f.vars.isEmpty) return f;
  final redacted = _redactDeep(f.vars) as Map<String, dynamic>;
  return SentryStackFrame(
    absPath: f.absPath,
    fileName: f.fileName,
    function: f.function,
    module: f.module,
    lineNo: f.lineNo,
    colNo: f.colNo,
    contextLine: f.contextLine,
    inApp: f.inApp,
    package: f.package,
    native: f.native,
    platform: f.platform,
    imageAddr: f.imageAddr,
    symbolAddr: f.symbolAddr,
    instructionAddr: f.instructionAddr,
    rawFunction: f.rawFunction,
    stackStart: f.stackStart,
    symbol: f.symbol,
    framesOmitted: f.framesOmitted,
    preContext: f.preContext,
    postContext: f.postContext,
    vars: redacted,
  );
}

SentryStackTrace? _scrubStackTrace(SentryStackTrace? st) {
  if (st == null) return null;
  final scrubbed = [for (final f in st.frames) _scrubFrame(f)];
  // `registers` is a Map<String, String> CPU register snapshot used for
  // native (NDK) crashes. Empty for Dart-only crashes, but on native it can
  // contain memory addresses or stringified pointers that match our MAC
  // regex by coincidence; scrub each value through the message redactor.
  final registers = st.registers;
  final scrubbedRegisters = registers.isEmpty
      ? null
      : <String, String>{
          for (final e in registers.entries)
            e.key: _isPiiKey(e.key) ? '[REDACTED]' : _redactMessage(e.value),
        };
  return SentryStackTrace(
    frames: scrubbed,
    registers: scrubbedRegisters,
    lang: st.lang,
    snapshot: st.snapshot,
  );
}

void _scrubException(SentryException ex) {
  final value = ex.value;
  if (value != null) ex.value = _redactMessage(value);
  ex.stackTrace = _scrubStackTrace(ex.stackTrace);
}

void _scrubThread(SentryThread t) {
  t.stacktrace = _scrubStackTrace(t.stacktrace);
}

void _scrubMessage(SentryMessage m) {
  // In sentry 9.x, `formatted` is non-nullable on SentryMessage and
  // `template` is the nullable raw form supplied to captureMessage.
  m.formatted = _redactMessage(m.formatted);
  final template = m.template;
  if (template != null) m.template = _redactMessage(template);
  final params = m.params;
  if (params != null) {
    // Use the deep redactor so structured params (Map / List) are scrubbed,
    // not just String values. Sentry coerces non-strings to strings on
    // serialization, so a Map<String, dynamic> with a peerId key would
    // otherwise be stringified verbatim before reaching beforeSend's reach.
    m.params = [for (final p in params) _redactDeep(p)];
  }
}

SentryRequest _scrubRequest(SentryRequest r) {
  final url = r.url;
  if (url != null) r.url = _redactMessage(url);
  final qs = r.queryString;
  if (qs != null) r.queryString = _redactMessage(qs);
  final cookies = r.cookies;
  if (cookies != null) r.cookies = _redactMessage(cookies);
  // headers is exposed as an unmodifiable view; assign through the setter
  // to replace the underlying map with the redacted version.
  final headers = r.headers;
  if (headers.isNotEmpty) {
    r.headers = <String, String>{
      for (final e in headers.entries)
        e.key: _isPiiKey(e.key) ? '[REDACTED]' : _redactMessage(e.value),
    };
  }
  // r.data is final in sentry 9.x. Use copyWith so every shape (Map, List,
  // String, primitive) flows through _redactDeep — mutating in place via
  // clear()/addAll() would skip non-Map payloads entirely and throw on an
  // immutable Map.
  final data = r.data;
  if (data != null) {
    return r.copyWith(data: _redactDeep(data));
  }
  return r;
}

/// Sanitizes Sentry events to remove PII before they are sent.
///
/// Redacts display names, peer IDs, and Bluetooth MAC addresses from every
/// load-bearing field of the event: contexts, tags, breadcrumbs, top-level
/// `message`, `exceptions` (including stack-frame `vars`), `threads`, `user`,
/// `request`, `extra`, `fingerprint`, and `transaction`.
///
/// Peer IDs are intentionally stripped even though they are random UUIDs:
/// the privacy-first stance (and the Play Store Data Safety declaration)
/// promises no app-controlled identifiers reach Sentry. Sentry's own
/// SDK-generated session identifiers cover crash-frequency diagnostics
/// without exposing an app-level identifier.
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
    if (msg != null) {
      final redacted = _redactMessage(msg);
      if (redacted != msg) crumb.message = redacted;
    }

    final data = crumb.data;
    if (data != null) {
      crumb.data = <String, dynamic>{
        for (final e in data.entries)
          e.key: _isPiiKey(e.key) ? '[REDACTED]' : _redactDeep(e.value),
      };
    }
  }

  // Top-level message — captureMessage payloads land here. Without this,
  // any free-form Sentry.captureMessage with interpolated identifiers
  // bypasses the breadcrumb redactor entirely.
  final message = event.message;
  if (message != null) _scrubMessage(message);

  // Exception messages and stack-frame locals can both carry interpolated
  // identifiers. Without scrubbing here, a thrown
  // `Exception('Failed for ${displayName}')` would be transmitted verbatim.
  for (final ex in event.exceptions ?? const <SentryException>[]) {
    _scrubException(ex);
  }

  // Thread stack frames carry the same risk as exception frames.
  for (final t in event.threads ?? const <SentryThread>[]) {
    _scrubThread(t);
  }

  // User PII. Drop the entire SentryUser block — the app has no accounts,
  // and Sentry's server can resolve `ipAddress = "{{auto}}"` to the device's
  // public IP. Field-by-field scrubbing leaks anything we forgot to enumerate
  // (arbitrary `data` keys, future SDK fields), so null the whole thing.
  // SDK-generated session identifiers still cover crash-frequency.
  if (event.user != null) {
    event.user = null;
  }

  // Request — irrelevant in this app today (no HTTP), but defensive against
  // future code that uses `Sentry.configureScope((s) => s.setRequest(...))`.
  final request = event.request;
  if (request != null) event.request = _scrubRequest(request);

  // Extra — arbitrary key/value attached via Sentry.captureEvent / scopes.
  // setExtra is deprecated in favor of structured contexts but the field is
  // still serialized, so a peerId / displayName nested in extra would
  // otherwise bypass every other gate. Strip PII keys outright; deep-redact
  // remaining values.
  final extra = event.extra;
  if (extra != null && extra.isNotEmpty) {
    event.extra = <String, dynamic>{
      for (final e in extra.entries)
        e.key: _isPiiKey(e.key) ? '[REDACTED]' : _redactDeep(e.value),
    };
  }

  // Fingerprint is a list of user-controlled strings; we don't set it
  // ourselves but Sentry SDK / integrations can. Scrub each entry.
  final fingerprint = event.fingerprint;
  if (fingerprint != null) {
    final redacted = [for (final f in fingerprint) _redactMessage(f)];
    event.fingerprint = redacted;
  }

  // Transaction name can carry path-style identifiers (e.g. /room/<peerId>).
  final transaction = event.transaction;
  if (transaction != null) {
    event.transaction = _redactMessage(transaction);
  }

  return event;
}
