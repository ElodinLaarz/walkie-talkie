import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// MaterialApp title — surfaces in OS task switcher / recents.
  ///
  /// In en, this message translates to:
  /// **'Frequency'**
  String get appTitle;

  /// Step counter in the onboarding chrome (e.g. 01/03).
  ///
  /// In en, this message translates to:
  /// **'{step}/03'**
  String onboardingStepIndicator(String step);

  /// Welcome headline on step 1 of onboarding. \n is intentional — preserves the two-line wrap.
  ///
  /// In en, this message translates to:
  /// **'Listen and talk together,\noffline.'**
  String get onboardingWelcomeHeadline;

  /// Welcome body copy on step 1 of onboarding.
  ///
  /// In en, this message translates to:
  /// **'Frequency pairs phones over Bluetooth so nearby friends can join the same voice channel and share whatever you\'re listening to — no internet required for voice.'**
  String get onboardingWelcomeBody;

  /// Primary button on step 1 of onboarding.
  ///
  /// In en, this message translates to:
  /// **'Get started'**
  String get onboardingGetStarted;

  /// All-caps eyebrow label above the permissions step heading.
  ///
  /// In en, this message translates to:
  /// **'STEP 2 · PERMISSIONS'**
  String get onboardingPermissionsEyebrow;

  /// Heading on step 2 of onboarding.
  ///
  /// In en, this message translates to:
  /// **'Two quick permissions.'**
  String get onboardingPermissionsHeadline;

  /// Body copy explaining why the two permissions are needed.
  ///
  /// In en, this message translates to:
  /// **'We need Bluetooth to find nearby phones, and the microphone to share your voice.'**
  String get onboardingPermissionsBody;

  /// Bluetooth permission row title.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth nearby devices'**
  String get permissionBluetoothTitle;

  /// Bluetooth permission row body.
  ///
  /// In en, this message translates to:
  /// **'Discover and connect to phones and headphones'**
  String get permissionBluetoothDescription;

  /// Microphone permission row title.
  ///
  /// In en, this message translates to:
  /// **'Microphone'**
  String get permissionMicrophoneTitle;

  /// Microphone permission row body.
  ///
  /// In en, this message translates to:
  /// **'Send your voice to the frequency'**
  String get permissionMicrophoneDescription;

  /// Replaces the permission row body when the OS reports permanently denied.
  ///
  /// In en, this message translates to:
  /// **'Blocked — re-enable in system settings'**
  String get permissionBlockedDescription;

  /// Trailing label on a granted permission row.
  ///
  /// In en, this message translates to:
  /// **'Allowed'**
  String get permissionStatusAllowed;

  /// Action button that deep-links to the OS app-settings page.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get permissionOpenSettings;

  /// Disabled-state label on the Allow button while a request is in flight.
  ///
  /// In en, this message translates to:
  /// **'Asking…'**
  String get permissionAsking;

  /// Default label on the permission Allow button.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get permissionAllow;

  /// Step 2 → step 3 advance button.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get onboardingContinue;

  /// All-caps eyebrow above the display-name step.
  ///
  /// In en, this message translates to:
  /// **'STEP 3 · YOUR HANDLE'**
  String get onboardingHandleEyebrow;

  /// Heading on step 3 of onboarding.
  ///
  /// In en, this message translates to:
  /// **'What should people call you?'**
  String get onboardingHandleHeadline;

  /// Body copy on step 3 of onboarding.
  ///
  /// In en, this message translates to:
  /// **'This shows up to everyone on the same frequency.'**
  String get onboardingHandleBody;

  /// Placeholder text inside the display-name TextField.
  ///
  /// In en, this message translates to:
  /// **'Your name'**
  String get onboardingHandleHint;

  /// Reassurance under the display-name field.
  ///
  /// In en, this message translates to:
  /// **'You can change this later.'**
  String get onboardingHandleFootnote;

  /// Final onboarding button — leaves onboarding for the discovery screen.
  ///
  /// In en, this message translates to:
  /// **'Find a frequency'**
  String get onboardingFindFrequency;

  /// Em-dash shown in the initials chip when the user has not entered a name yet.
  ///
  /// In en, this message translates to:
  /// **'—'**
  String get initialsPlaceholder;

  /// Headline shown after the user revokes mic / BT from system Settings while the app was running.
  ///
  /// In en, this message translates to:
  /// **'Permissions revoked'**
  String get permissionDeniedHeadline;

  /// Body copy when both microphone and Bluetooth are denied.
  ///
  /// In en, this message translates to:
  /// **'Frequency needs microphone and Bluetooth to keep you on the air. Re-grant them in Settings to come back.'**
  String get permissionDeniedExplainerBoth;

  /// Body copy when only microphone is denied.
  ///
  /// In en, this message translates to:
  /// **'Frequency needs the microphone to send your voice. Re-grant it in Settings to come back.'**
  String get permissionDeniedExplainerMic;

  /// Body copy when only Bluetooth is denied.
  ///
  /// In en, this message translates to:
  /// **'Frequency needs Bluetooth to find nearby phones. Re-grant it in Settings to come back.'**
  String get permissionDeniedExplainerBluetooth;

  /// Re-check permissions button on the denied screen.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get permissionRetry;

  /// Trailing chip in the discovery chrome — shows that BT is on.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get discoveryBluetoothChip;

  /// All-caps eyebrow above the discovery hero while actively scanning.
  ///
  /// In en, this message translates to:
  /// **'TUNING THE DIAL'**
  String get discoveryHeroEyebrowScanning;

  /// All-caps eyebrow when scanning is stopped but at least one session was found.
  ///
  /// In en, this message translates to:
  /// **'DISCOVERY PAUSED'**
  String get discoveryHeroEyebrowPaused;

  /// All-caps eyebrow when scanning is stopped and no sessions were found.
  ///
  /// In en, this message translates to:
  /// **'NOTHING NEARBY'**
  String get discoveryHeroEyebrowEmpty;

  /// Discovery hero headline. \n preserved for two-line layout.
  ///
  /// In en, this message translates to:
  /// **'Phones around you,\non the same wavelength.'**
  String get discoveryHeroHeadline;

  /// Discovery hero body copy.
  ///
  /// In en, this message translates to:
  /// **'Make a Frequency to chat & listen together, or tune in to one nearby.'**
  String get discoveryHeroBody;

  /// Primary button — host a brand-new channel.
  ///
  /// In en, this message translates to:
  /// **'Start a new Frequency'**
  String get discoveryStartFrequency;

  /// Plain-text prefix to the auto-generated MHz value under the create button. The MHz value is rendered in the mono font and not localized.
  ///
  /// In en, this message translates to:
  /// **'A fresh channel will be broadcast at '**
  String get discoveryNewFreqHintPrefix;

  /// Frequency + unit string. Mono-styled.
  ///
  /// In en, this message translates to:
  /// **'{freq} MHz'**
  String discoveryNewFreqUnit(String freq);

  /// Header above the user's recent hosted frequencies.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get discoverySectionRecent;

  /// Header above the discovered-sessions list.
  ///
  /// In en, this message translates to:
  /// **'Nearby'**
  String get discoverySectionNearby;

  /// Trailing label next to the pulse dot when actively scanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning'**
  String get discoveryScanIndicatorScanning;

  /// Trailing label when scanning is stopped.
  ///
  /// In en, this message translates to:
  /// **'Idle'**
  String get discoveryScanIndicatorIdle;

  /// Pause-scanning affordance next to the indicator.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get discoveryScanActionPause;

  /// Resume-scanning affordance next to the indicator.
  ///
  /// In en, this message translates to:
  /// **'Scan'**
  String get discoveryScanActionScan;

  /// Reassurance line at the bottom of the discovery list.
  ///
  /// In en, this message translates to:
  /// **'Using Bluetooth LE Audio · No internet required for voice'**
  String get discoveryFooter;

  /// Fallback host name when the discovered session advertised an empty name.
  ///
  /// In en, this message translates to:
  /// **'Unknown Host'**
  String get discoveryUnknownHost;

  /// Subtitle on a discovered nearby session row.
  ///
  /// In en, this message translates to:
  /// **'Frequency Session'**
  String get discoveryNearbyRowSubtitle;

  /// Prefix before the mono-styled MHz on a nearby row (the "On 92.5" half).
  ///
  /// In en, this message translates to:
  /// **'On '**
  String get discoveryNearbyRowOnPrefix;

  /// Middle-dot separator between subtitle pieces on a discovered-session row.
  ///
  /// In en, this message translates to:
  /// **'  ·  '**
  String get discoveryRowSeparator;

  /// Action button on a selected nearby session — joins as guest.
  ///
  /// In en, this message translates to:
  /// **'Tune in'**
  String get discoveryTuneIn;

  /// Title on a row in the Recent (re-host) list.
  ///
  /// In en, this message translates to:
  /// **'Your channel'**
  String get discoveryRecentRowTitle;

  /// Prefix before the mono freq on a recent-host row (e.g. "Host on 92.5 MHz").
  ///
  /// In en, this message translates to:
  /// **'Host on '**
  String get discoveryRecentRowHostPrefix;

  /// Suffix after the mono freq on a recent-host row.
  ///
  /// In en, this message translates to:
  /// **' MHz'**
  String get discoveryRecentRowMhzSuffix;

  /// Action button — re-host this previously-used freq.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get discoveryRecentRowResume;

  /// Heading inside the rename bottom sheet.
  ///
  /// In en, this message translates to:
  /// **'Your handle'**
  String get renameSheetTitle;

  /// Subhead inside the rename bottom sheet.
  ///
  /// In en, this message translates to:
  /// **'Shows up to everyone on the same frequency.'**
  String get renameSheetSubtitle;

  /// Save button inside the rename bottom sheet.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get renameSheetSave;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
