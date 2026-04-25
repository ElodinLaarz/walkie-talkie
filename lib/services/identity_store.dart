import 'package:hive/hive.dart';

/// Persisted user identity that survives app restarts.
///
/// Today this is just the display name picked during onboarding. The interface
/// exists so the app shell and tests can swap implementations without touching
/// Hive directly.
abstract class IdentityStore {
  /// Returns the persisted display name, or `null` if onboarding has not
  /// completed.
  Future<String?> getDisplayName();

  /// Persists the display name. The value is trimmed; an empty string is
  /// treated as a clear and removes the persisted name.
  Future<void> setDisplayName(String value);
}

/// Hive-backed [IdentityStore] keyed in a single string box.
class HiveIdentityStore implements IdentityStore {
  static const String _boxName = 'identity';
  static const String _displayNameKey = 'displayName';

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
}
