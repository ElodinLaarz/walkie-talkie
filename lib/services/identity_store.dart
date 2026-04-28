import 'package:hive/hive.dart';

import '../protocol/uuid.dart';

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

  /// Single-flight cache for `getPeerId`. The first caller starts the
  /// get-or-create; every concurrent caller awaits the same future, so all
  /// callers in the same session see the same id even on a fresh install.
  Future<String>? _peerIdFuture;

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
  Future<String> getPeerId() => _peerIdFuture ??= _readOrCreatePeerId();

  Future<String> _readOrCreatePeerId() async {
    final box = await _open();
    final existing = box.get(_peerIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final fresh = generateUuidV4();
    await box.put(_peerIdKey, fresh);
    return fresh;
  }
}
