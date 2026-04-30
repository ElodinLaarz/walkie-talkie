// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Frequency';

  @override
  String onboardingStepIndicator(String step) {
    return '$step/03';
  }

  @override
  String get onboardingWelcomeHeadline => 'Listen and talk together,\noffline.';

  @override
  String get onboardingWelcomeBody =>
      'Frequency pairs phones over Bluetooth so nearby friends can join the same voice channel and share whatever you\'re listening to — no internet required for voice.';

  @override
  String get onboardingGetStarted => 'Get started';

  @override
  String get onboardingPermissionsEyebrow => 'STEP 2 · PERMISSIONS';

  @override
  String get onboardingPermissionsHeadline => 'Two quick permissions.';

  @override
  String get onboardingPermissionsBody =>
      'We need Bluetooth to find nearby phones, and the microphone to share your voice.';

  @override
  String get permissionBluetoothTitle => 'Bluetooth nearby devices';

  @override
  String get permissionBluetoothDescription =>
      'Discover and connect to phones and headphones';

  @override
  String get permissionMicrophoneTitle => 'Microphone';

  @override
  String get permissionMicrophoneDescription =>
      'Send your voice to the frequency';

  @override
  String get permissionBlockedDescription =>
      'Blocked — re-enable in system settings';

  @override
  String get permissionStatusAllowed => 'Allowed';

  @override
  String get permissionOpenSettings => 'Open settings';

  @override
  String get permissionAsking => 'Asking…';

  @override
  String get permissionAllow => 'Allow';

  @override
  String get onboardingContinue => 'Continue';

  @override
  String get onboardingHandleEyebrow => 'STEP 3 · YOUR HANDLE';

  @override
  String get onboardingHandleHeadline => 'What should people call you?';

  @override
  String get onboardingHandleBody =>
      'This shows up to everyone on the same frequency.';

  @override
  String get onboardingHandleHint => 'Your name';

  @override
  String get onboardingHandleFootnote => 'You can change this later.';

  @override
  String get onboardingFindFrequency => 'Find a frequency';

  @override
  String get initialsPlaceholder => '—';

  @override
  String get permissionDeniedHeadline => 'Permissions revoked';

  @override
  String get permissionDeniedExplainerBoth =>
      'Frequency needs microphone and Bluetooth to keep you on the air. Re-grant them in Settings to come back.';

  @override
  String get permissionDeniedExplainerMic =>
      'Frequency needs the microphone to send your voice. Re-grant it in Settings to come back.';

  @override
  String get permissionDeniedExplainerBluetooth =>
      'Frequency needs Bluetooth to find nearby phones. Re-grant it in Settings to come back.';

  @override
  String get permissionRetry => 'Retry';

  @override
  String get discoveryBluetoothChip => 'On';

  @override
  String get discoveryHeroEyebrowScanning => 'TUNING THE DIAL';

  @override
  String get discoveryHeroEyebrowPaused => 'DISCOVERY PAUSED';

  @override
  String get discoveryHeroEyebrowEmpty => 'NOTHING NEARBY';

  @override
  String get discoveryHeroHeadline =>
      'Phones around you,\non the same wavelength.';

  @override
  String get discoveryHeroBody =>
      'Make a Frequency to chat & listen together, or tune in to one nearby.';

  @override
  String get discoveryStartFrequency => 'Start a new Frequency';

  @override
  String get discoveryNewFreqHintPrefix =>
      'A fresh channel will be broadcast at ';

  @override
  String discoveryNewFreqUnit(String freq) {
    return '$freq MHz';
  }

  @override
  String get discoverySectionRecent => 'Recent';

  @override
  String get discoverySectionNearby => 'Nearby';

  @override
  String get discoveryScanIndicatorScanning => 'Scanning';

  @override
  String get discoveryScanIndicatorIdle => 'Idle';

  @override
  String get discoveryScanActionPause => 'Pause';

  @override
  String get discoveryScanActionScan => 'Scan';

  @override
  String get discoveryFooter =>
      'Using Bluetooth LE Audio · No internet required for voice';

  @override
  String get discoveryUnknownHost => 'Unknown Host';

  @override
  String get discoveryNearbyRowSubtitle => 'Frequency Session';

  @override
  String get discoveryNearbyRowOnPrefix => 'On ';

  @override
  String get discoveryRowSeparator => '  ·  ';

  @override
  String get discoveryTuneIn => 'Tune in';

  @override
  String get discoveryRecentRowTitle => 'Your channel';

  @override
  String get discoveryRecentRowHostPrefix => 'Host on ';

  @override
  String get discoveryRecentRowMhzSuffix => ' MHz';

  @override
  String get discoveryRecentRowResume => 'Resume';

  @override
  String get renameSheetTitle => 'Your handle';

  @override
  String get renameSheetSubtitle =>
      'Shows up to everyone on the same frequency.';

  @override
  String get renameSheetSave => 'Save';
}
