import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/services/native_licenses.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // `LicenseRegistry` is a global; clear it between tests so each case
    // sees only the entries it registers itself.
    LicenseRegistry.reset();
    resetNativeLicenseRegistrationForTests();
  });

  group('registerNativeLicenses', () {
    test('emits Oboe and Opus entries with their package labels', () async {
      final bundle = _StubAssetBundle({
        oboeLicenseAsset: 'OBOE LICENSE TEXT — Apache-2.0',
        opusLicenseAsset: 'OPUS LICENSE TEXT — BSD-3-Clause',
      });
      await registerNativeLicenses(bundle: bundle);

      final entries = await LicenseRegistry.licenses.toList();
      // The native licenses we just registered live alongside any other
      // entries Flutter has collected on this binding (auto-discovered Dart
      // packages, etc.). Filter to ours rather than asserting on length.
      final oboe = entries.firstWhere((e) => e.packages.contains('Oboe'));
      final opus = entries.firstWhere((e) => e.packages.contains('Opus'));

      expect(oboe.paragraphs.map((p) => p.text).join(' '),
          contains('OBOE LICENSE TEXT'));
      expect(opus.paragraphs.map((p) => p.text).join(' '),
          contains('OPUS LICENSE TEXT'));
    });

    test('is idempotent — repeat calls do not re-register', () async {
      final bundle = _StubAssetBundle({
        oboeLicenseAsset: 'OBOE',
        opusLicenseAsset: 'OPUS',
      });
      await registerNativeLicenses(bundle: bundle);
      await registerNativeLicenses(bundle: bundle);

      final entries = await LicenseRegistry.licenses.toList();
      final oboeCount = entries.where((e) => e.packages.contains('Oboe')).length;
      final opusCount = entries.where((e) => e.packages.contains('Opus')).length;
      expect(oboeCount, 1);
      expect(opusCount, 1);
    });

    testWidgets('asset paths declared in pubspec resolve at runtime',
        (tester) async {
      // Loads the real bundled assets through the test binding. If pubspec
      // forgot to list them under `flutter.assets`, this throws.
      final oboe = await rootBundle.loadString(oboeLicenseAsset);
      final opus = await rootBundle.loadString(opusLicenseAsset);
      expect(oboe, contains('Apache License'));
      expect(opus, contains('Xiph'));
    });
  });
}

class _StubAssetBundle extends CachingAssetBundle {
  _StubAssetBundle(this._strings);
  final Map<String, String> _strings;

  @override
  Future<ByteData> load(String key) async {
    final s = _strings[key];
    if (s == null) {
      throw FlutterError('asset $key not found in stub');
    }
    return ByteData.view(Uint8List.fromList(utf8.encode(s)).buffer);
  }
}
