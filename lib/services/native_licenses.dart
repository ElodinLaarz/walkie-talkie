import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// Registers third-party licenses for vendored native code with Flutter's
/// [LicenseRegistry] so they appear in the in-app `LicensePage` alongside
/// the auto-collected Dart-package licenses.
///
/// Pure Dart dependencies declared in `pubspec.yaml` are picked up by Flutter
/// automatically — `LicenseRegistry` walks the package metadata. Vendored
/// native code is invisible to that mechanism, so we have to register it
/// ourselves: Oboe (Apache-2.0) ships under `android/app/src/main/cpp/oboe/`
/// and Opus (BSD-3-Clause) is a git submodule at `android/app/src/main/cpp/opus`.
/// Their license texts are bundled as Flutter assets under `assets/licenses/`
/// so the runtime doesn't depend on the C++ source tree being checked out
/// (the Opus submodule isn't always populated, e.g. on CI shallow clones).
///
/// Idempotent: a private flag prevents duplicate registrations if the helper
/// is invoked more than once during hot reload or in tests that share a
/// binding with `main()`.
@visibleForTesting
const oboeLicenseAsset = 'assets/licenses/oboe-LICENSE.txt';

@visibleForTesting
const opusLicenseAsset = 'assets/licenses/opus-COPYING.txt';

bool _registered = false;

/// Resets the idempotency flag. Test-only — production code calls
/// [registerNativeLicenses] exactly once from `main()`.
@visibleForTesting
void resetNativeLicenseRegistrationForTests() {
  _registered = false;
}

/// Registers the Oboe and Opus license texts with [LicenseRegistry].
///
/// Call once during app startup, before the first frame. Safe to invoke
/// multiple times — only the first call has any effect. The optional
/// [bundle] parameter is for tests; production reads from [rootBundle].
///
/// Synchronous: this function only hands [LicenseRegistry] a closure to
/// invoke later. The asset reads happen lazily inside that closure, when
/// the LicensePage is first opened — they don't block startup.
void registerNativeLicenses({AssetBundle? bundle}) {
  if (_registered) return;
  _registered = true;

  final assets = bundle ?? rootBundle;

  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ['Oboe'],
      await assets.loadString(oboeLicenseAsset),
    );
    yield LicenseEntryWithLineBreaks(
      const ['Opus'],
      await assets.loadString(opusLicenseAsset),
    );
  });
}
