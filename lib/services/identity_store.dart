import 'dart:math';

import 'package:hive/hive.dart';

/// Persisted user identity that survives app restarts.
///
/// Carries two independent things:
///   * `displayName` — what other people on a frequency see, picked during
///     onboarding, editable via the rename sheet.
///   * `peerId` — a stable per-install UUID v4 used by the wire protocol
///     to route messages and tag voice frames. Generated lazily on first
///     read, never changes once created, completely decoupled from the
///     display name (renames don't perturb it).
abstract class IdentityStore {
  /// Returns the persisted display name, or `null` if onboarding has not
  /// completed.
  Future<String?> getDisplayName();

  /// Persists the display name. The value is trimmed; an empty string is
  /// treated as a clear and removes the persisted name.
  Future<void> setDisplayName(String value);

  /// Returns the persisted peerId, generating a fresh UUID v4 on first
  /// call and persisting it before returning. Idempotent for the install
  /// lifetime — the same id is returned on every subsequent call across
  /// app restarts.
  Future<String> getPeerId();
}

/// Hive-backed [IdentityStore] keyed in a single string box.
class HiveIdentityStore implements IdentityStore {
  static const String _boxName = 'identity';
  static const String _displayNameKey = 'displayName';
  static const String _peerIdKey = 'peerId';

  Box<String>? _box;

  Future<Box<String>> _open() async {
    final existing = _box;
    if (existing != null && existing.isOpen) return existing;
    final box = await Hive.openBox<String>(_boxName);
    _box = box;
    return box;
  }

  @override
  Future<String?> getDisplayName() async {
    final box = await _open();
    final raw = box.get(_displayNameKey);
    if (raw == null) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  Future<void> setDisplayName(String value) async {
    final box = await _open();
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      await box.delete(_displayNameKey);
    } else {
      await box.put(_displayNameKey, trimmed);
    }
  }

  @override
  Future<String> getPeerId() async {
    final box = await _open();
    final existing = box.get(_peerIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final fresh = _generateUuidV4();
    await box.put(_peerIdKey, fresh);
    return fresh;
  }
}

/// Generates a UUID v4 string in canonical `8-4-4-4-12` hex form using
/// `Random.secure()`. Avoids pulling in the `uuid` package for ~15 lines
/// of work; the format follows RFC 4122 §4.4 (random bits with the
/// version nibble pinned to 4 and the variant top bits to `10`).
String _generateUuidV4() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  // Version 4 (random) marker.
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  // RFC 4122 variant marker (10xx).
  bytes[8] = (bytes[8] & 0x3F) | 0x80;

  String segment(int from, int to) {
    final sb = StringBuffer();
    for (var i = from; i < to; i++) {
      sb.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  return '${segment(0, 4)}-${segment(4, 6)}-${segment(6, 8)}-'
      '${segment(8, 10)}-${segment(10, 16)}';
}
