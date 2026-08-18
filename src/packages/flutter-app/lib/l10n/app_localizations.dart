import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
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
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es')
  ];

  /// Product name. Not translated — it is a brand name.
  ///
  /// In en, this message translates to:
  /// **'Anemos'**
  String get appTitle;

  /// Label of the language dropdown in account settings.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageSectionTitle;

  /// Name of the English language, shown in its own language.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// Name of the Spanish language, shown in its own language.
  ///
  /// In en, this message translates to:
  /// **'Español'**
  String get languageSpanish;

  /// Explains that switching language does not retranslate existing saved content.
  ///
  /// In en, this message translates to:
  /// **'Trips and notes you already saved stay in the language they were written in.'**
  String get languageChangeNote;

  /// Tooltip of the app-bar globe button that opens the language menu.
  ///
  /// In en, this message translates to:
  /// **'Change language'**
  String get languageMenuTooltip;

  /// Header of the merged appearance + language group in account settings.
  ///
  /// In en, this message translates to:
  /// **'Appearance & language'**
  String get appearanceLanguageSectionTitle;

  /// Label of the light/dark appearance dropdown in account settings.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearanceSectionTitle;

  /// Appearance option that follows the OS light/dark preference.
  ///
  /// In en, this message translates to:
  /// **'Use device setting'**
  String get appearanceSystem;

  /// Appearance option that forces the light theme.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get appearanceLight;

  /// Appearance option that forces the dark theme.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get appearanceDark;

  /// No description provided for @commonSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get commonSave;

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @commonDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get commonDelete;

  /// No description provided for @commonRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get commonRetry;

  /// No description provided for @commonClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get commonClose;

  /// No description provided for @commonBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get commonBack;

  /// No description provided for @commonNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get commonNext;

  /// No description provided for @commonDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get commonDone;

  /// No description provided for @commonSeeAll.
  ///
  /// In en, this message translates to:
  /// **'See all'**
  String get commonSeeAll;

  /// Destination summary for a trip with exactly two hub cities.
  ///
  /// In en, this message translates to:
  /// **'{first} & {second}'**
  String citiesTwo(String first, String second);

  /// Destination summary for a trip with more than two hub cities; count is how many are not named.
  ///
  /// In en, this message translates to:
  /// **'{first} & {second} +{count} more'**
  String citiesMore(String first, String second, int count);

  /// No description provided for @prefsTitle.
  ///
  /// In en, this message translates to:
  /// **'Travel profile'**
  String get prefsTitle;

  /// No description provided for @prefsBudget.
  ///
  /// In en, this message translates to:
  /// **'Budget'**
  String get prefsBudget;

  /// No description provided for @prefsPace.
  ///
  /// In en, this message translates to:
  /// **'Pace'**
  String get prefsPace;

  /// No description provided for @prefsInterests.
  ///
  /// In en, this message translates to:
  /// **'Interests'**
  String get prefsInterests;

  /// No description provided for @prefsAddInterest.
  ///
  /// In en, this message translates to:
  /// **'Add an interest'**
  String get prefsAddInterest;

  /// No description provided for @prefsHomeAirport.
  ///
  /// In en, this message translates to:
  /// **'Home airport'**
  String get prefsHomeAirport;

  /// No description provided for @prefsHomeAirportHelp.
  ///
  /// In en, this message translates to:
  /// **'Used as the default origin when planning flights.'**
  String get prefsHomeAirportHelp;

  /// Shown under the home airport field when the traveler typed something but never chose a suggestion, so there is no airport to save.
  ///
  /// In en, this message translates to:
  /// **'Pick an airport from the list, or clear the field.'**
  String get prefsHomeAirportPickOne;

  /// No description provided for @prefsProfileNotes.
  ///
  /// In en, this message translates to:
  /// **'Profile notes'**
  String get prefsProfileNotes;

  /// No description provided for @prefsProfileNotesHelp.
  ///
  /// In en, this message translates to:
  /// **'Your AI agent keeps these notes as it learns about you. Edit or clear them anytime.'**
  String get prefsProfileNotesHelp;

  /// No description provided for @prefsProfileNotesHint.
  ///
  /// In en, this message translates to:
  /// **'Nothing noted yet — the agent adds to this as you plan trips.'**
  String get prefsProfileNotesHint;

  /// No description provided for @prefsSaved.
  ///
  /// In en, this message translates to:
  /// **'Preferences saved'**
  String get prefsSaved;

  /// No description provided for @prefsSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save preferences'**
  String get prefsSaveFailed;

  /// No description provided for @prefsLoadErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load your travel profile'**
  String get prefsLoadErrorTitle;

  /// No description provided for @prefsLoadErrorMessage.
  ///
  /// In en, this message translates to:
  /// **'Check your connection and try again.'**
  String get prefsLoadErrorMessage;

  /// Budget level option shown on a chip; the stored API value stays 'budget'.
  ///
  /// In en, this message translates to:
  /// **'budget'**
  String get prefsBudgetLow;

  /// No description provided for @prefsBudgetMid.
  ///
  /// In en, this message translates to:
  /// **'mid'**
  String get prefsBudgetMid;

  /// No description provided for @prefsBudgetLuxury.
  ///
  /// In en, this message translates to:
  /// **'luxury'**
  String get prefsBudgetLuxury;

  /// No description provided for @prefsWorkStyle.
  ///
  /// In en, this message translates to:
  /// **'Work & travel'**
  String get prefsWorkStyle;

  /// No description provided for @prefsWorkStyleNomad.
  ///
  /// In en, this message translates to:
  /// **'yes — I work as I travel'**
  String get prefsWorkStyleNomad;

  /// No description provided for @prefsWorkStyleWorkation.
  ///
  /// In en, this message translates to:
  /// **'sometimes'**
  String get prefsWorkStyleWorkation;

  /// No description provided for @prefsWorkStyleLeisure.
  ///
  /// In en, this message translates to:
  /// **'no — trips are time off'**
  String get prefsWorkStyleLeisure;

  /// No description provided for @prefsCompanions.
  ///
  /// In en, this message translates to:
  /// **'Who you travel with'**
  String get prefsCompanions;

  /// No description provided for @prefsFitnessRoutine.
  ///
  /// In en, this message translates to:
  /// **'Working out'**
  String get prefsFitnessRoutine;

  /// No description provided for @prefsFitnessRoutineHelp.
  ///
  /// In en, this message translates to:
  /// **'Used to pick stays near a gym or a place to run, and to leave you the time.'**
  String get prefsFitnessRoutineHelp;

  /// Fitness routine option shown on a chip; the stored API value stays 'gym'.
  ///
  /// In en, this message translates to:
  /// **'gym access'**
  String get prefsFitnessGym;

  /// No description provided for @prefsFitnessRunning.
  ///
  /// In en, this message translates to:
  /// **'running routes'**
  String get prefsFitnessRunning;

  /// No description provided for @prefsFitnessBoth.
  ///
  /// In en, this message translates to:
  /// **'both'**
  String get prefsFitnessBoth;

  /// No description provided for @prefsFitnessNone.
  ///
  /// In en, this message translates to:
  /// **'not a factor'**
  String get prefsFitnessNone;

  /// No description provided for @prefsOutdoorIntensity.
  ///
  /// In en, this message translates to:
  /// **'Outdoor days'**
  String get prefsOutdoorIntensity;

  /// No description provided for @prefsOutdoorIntensityHelp.
  ///
  /// In en, this message translates to:
  /// **'How hard you want hikes and other active outings to be.'**
  String get prefsOutdoorIntensityHelp;

  /// Outdoor intensity option shown on a chip; the stored API value stays 'easy'.
  ///
  /// In en, this message translates to:
  /// **'easy — walks and viewpoints'**
  String get prefsOutdoorEasy;

  /// No description provided for @prefsOutdoorModerate.
  ///
  /// In en, this message translates to:
  /// **'moderate — half-day hikes'**
  String get prefsOutdoorModerate;

  /// No description provided for @prefsOutdoorChallenging.
  ///
  /// In en, this message translates to:
  /// **'challenging — long and steep'**
  String get prefsOutdoorChallenging;

  /// No description provided for @prefsBaggage.
  ///
  /// In en, this message translates to:
  /// **'What you fly with'**
  String get prefsBaggage;

  /// No description provided for @prefsBaggageHelp.
  ///
  /// In en, this message translates to:
  /// **'Flight prices are quoted with this bag included, so the cheapest option really is the cheapest.'**
  String get prefsBaggageHelp;

  /// Trip pace option shown on a chip; the stored API value stays 'relaxed'.
  ///
  /// In en, this message translates to:
  /// **'relaxed'**
  String get prefsPaceRelaxed;

  /// No description provided for @prefsPaceBalanced.
  ///
  /// In en, this message translates to:
  /// **'balanced'**
  String get prefsPaceBalanced;

  /// No description provided for @prefsPacePacked.
  ///
  /// In en, this message translates to:
  /// **'packed'**
  String get prefsPacePacked;

  /// Suggested interest chip; the stored API value stays 'museums'.
  ///
  /// In en, this message translates to:
  /// **'museums'**
  String get prefsInterestMuseums;

  /// No description provided for @prefsInterestFood.
  ///
  /// In en, this message translates to:
  /// **'food'**
  String get prefsInterestFood;

  /// No description provided for @prefsInterestNightlife.
  ///
  /// In en, this message translates to:
  /// **'nightlife'**
  String get prefsInterestNightlife;

  /// No description provided for @prefsInterestNature.
  ///
  /// In en, this message translates to:
  /// **'nature'**
  String get prefsInterestNature;

  /// No description provided for @prefsInterestHistory.
  ///
  /// In en, this message translates to:
  /// **'history'**
  String get prefsInterestHistory;

  /// No description provided for @prefsInterestArt.
  ///
  /// In en, this message translates to:
  /// **'art'**
  String get prefsInterestArt;

  /// No description provided for @prefsInterestShopping.
  ///
  /// In en, this message translates to:
  /// **'shopping'**
  String get prefsInterestShopping;

  /// No description provided for @prefsInterestOutdoors.
  ///
  /// In en, this message translates to:
  /// **'outdoors'**
  String get prefsInterestOutdoors;

  /// No description provided for @prefsInterestBeaches.
  ///
  /// In en, this message translates to:
  /// **'beaches'**
  String get prefsInterestBeaches;

  /// No description provided for @prefsInterestArchitecture.
  ///
  /// In en, this message translates to:
  /// **'architecture'**
  String get prefsInterestArchitecture;

  /// No description provided for @prefsInterestLiveMusic.
  ///
  /// In en, this message translates to:
  /// **'live music'**
  String get prefsInterestLiveMusic;

  /// No description provided for @prefsInterestBars.
  ///
  /// In en, this message translates to:
  /// **'bars'**
  String get prefsInterestBars;

  /// No description provided for @prefsInterestTheater.
  ///
  /// In en, this message translates to:
  /// **'theater'**
  String get prefsInterestTheater;

  /// No description provided for @prefsInterestFestivals.
  ///
  /// In en, this message translates to:
  /// **'festivals'**
  String get prefsInterestFestivals;

  /// No description provided for @prefsInterestLocalMarkets.
  ///
  /// In en, this message translates to:
  /// **'local markets'**
  String get prefsInterestLocalMarkets;

  /// No description provided for @prefsInterestStreetFood.
  ///
  /// In en, this message translates to:
  /// **'street food'**
  String get prefsInterestStreetFood;

  /// No description provided for @prefsInterestCoffee.
  ///
  /// In en, this message translates to:
  /// **'coffee'**
  String get prefsInterestCoffee;

  /// No description provided for @prefsInterestWine.
  ///
  /// In en, this message translates to:
  /// **'wine'**
  String get prefsInterestWine;

  /// No description provided for @prefsInterestCraftBeer.
  ///
  /// In en, this message translates to:
  /// **'craft beer'**
  String get prefsInterestCraftBeer;

  /// No description provided for @prefsInterestFineDining.
  ///
  /// In en, this message translates to:
  /// **'fine dining'**
  String get prefsInterestFineDining;

  /// No description provided for @prefsInterestHiking.
  ///
  /// In en, this message translates to:
  /// **'hiking'**
  String get prefsInterestHiking;

  /// No description provided for @prefsInterestWildlife.
  ///
  /// In en, this message translates to:
  /// **'wildlife'**
  String get prefsInterestWildlife;

  /// No description provided for @prefsInterestWaterSports.
  ///
  /// In en, this message translates to:
  /// **'water sports'**
  String get prefsInterestWaterSports;

  /// No description provided for @prefsInterestSkiing.
  ///
  /// In en, this message translates to:
  /// **'skiing'**
  String get prefsInterestSkiing;

  /// No description provided for @prefsInterestCycling.
  ///
  /// In en, this message translates to:
  /// **'cycling'**
  String get prefsInterestCycling;

  /// No description provided for @prefsInterestClimbing.
  ///
  /// In en, this message translates to:
  /// **'climbing'**
  String get prefsInterestClimbing;

  /// No description provided for @prefsInterestNationalParks.
  ///
  /// In en, this message translates to:
  /// **'national parks'**
  String get prefsInterestNationalParks;

  /// No description provided for @prefsInterestRoadTrips.
  ///
  /// In en, this message translates to:
  /// **'road trips'**
  String get prefsInterestRoadTrips;

  /// No description provided for @prefsInterestPhotography.
  ///
  /// In en, this message translates to:
  /// **'photography'**
  String get prefsInterestPhotography;

  /// No description provided for @prefsInterestStreetArt.
  ///
  /// In en, this message translates to:
  /// **'street art'**
  String get prefsInterestStreetArt;

  /// No description provided for @prefsInterestWellness.
  ///
  /// In en, this message translates to:
  /// **'wellness'**
  String get prefsInterestWellness;

  /// No description provided for @prefsInterestSpas.
  ///
  /// In en, this message translates to:
  /// **'spas'**
  String get prefsInterestSpas;

  /// No description provided for @prefsInterestSportsEvents.
  ///
  /// In en, this message translates to:
  /// **'sports events'**
  String get prefsInterestSportsEvents;

  /// No description provided for @ssoContinueWithGoogle.
  ///
  /// In en, this message translates to:
  /// **'Continue with Google'**
  String get ssoContinueWithGoogle;

  /// No description provided for @ssoContinueWithApple.
  ///
  /// In en, this message translates to:
  /// **'Continue with Apple'**
  String get ssoContinueWithApple;

  /// No description provided for @ssoDividerOr.
  ///
  /// In en, this message translates to:
  /// **'or'**
  String get ssoDividerOr;

  /// No description provided for @authWelcomeBack.
  ///
  /// In en, this message translates to:
  /// **'Welcome back'**
  String get authWelcomeBack;

  /// No description provided for @authCreateAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'Create your account'**
  String get authCreateAccountTitle;

  /// No description provided for @authEmailLabel.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get authEmailLabel;

  /// No description provided for @authEmailRequired.
  ///
  /// In en, this message translates to:
  /// **'Email is required'**
  String get authEmailRequired;

  /// No description provided for @authEmailInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid email'**
  String get authEmailInvalid;

  /// No description provided for @authPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get authPasswordLabel;

  /// No description provided for @authPasswordRequired.
  ///
  /// In en, this message translates to:
  /// **'Password is required'**
  String get authPasswordRequired;

  /// No description provided for @authPasswordTooShort.
  ///
  /// In en, this message translates to:
  /// **'Password must be at least 8 characters'**
  String get authPasswordTooShort;

  /// No description provided for @authDisplayNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Display name (optional)'**
  String get authDisplayNameLabel;

  /// No description provided for @authSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get authSignIn;

  /// No description provided for @authCreateAccount.
  ///
  /// In en, this message translates to:
  /// **'Create account'**
  String get authCreateAccount;

  /// No description provided for @authNoAccountPrompt.
  ///
  /// In en, this message translates to:
  /// **'Don\'t have an account? Sign up'**
  String get authNoAccountPrompt;

  /// No description provided for @authHaveAccountPrompt.
  ///
  /// In en, this message translates to:
  /// **'Already have an account? Sign in'**
  String get authHaveAccountPrompt;

  /// No description provided for @authForgotPassword.
  ///
  /// In en, this message translates to:
  /// **'Forgot password?'**
  String get authForgotPassword;

  /// No description provided for @authPasswordUpdatedSnack.
  ///
  /// In en, this message translates to:
  /// **'Password updated — sign in with your new password'**
  String get authPasswordUpdatedSnack;

  /// No description provided for @authResetDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset your password'**
  String get authResetDialogTitle;

  /// No description provided for @authResetDialogBody.
  ///
  /// In en, this message translates to:
  /// **'We\'ll email you a reset code if this address has an account.'**
  String get authResetDialogBody;

  /// No description provided for @authSending.
  ///
  /// In en, this message translates to:
  /// **'Sending…'**
  String get authSending;

  /// No description provided for @authSendCode.
  ///
  /// In en, this message translates to:
  /// **'Send code'**
  String get authSendCode;

  /// No description provided for @authEnterCodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter your reset code'**
  String get authEnterCodeTitle;

  /// No description provided for @authEnterCodeBody.
  ///
  /// In en, this message translates to:
  /// **'Check your inbox for the code we just sent.'**
  String get authEnterCodeBody;

  /// No description provided for @authResetCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Reset code'**
  String get authResetCodeLabel;

  /// No description provided for @authNewPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'New password'**
  String get authNewPasswordLabel;

  /// No description provided for @authCodeRequired.
  ///
  /// In en, this message translates to:
  /// **'Paste the code from the email'**
  String get authCodeRequired;

  /// No description provided for @authSaving.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get authSaving;

  /// No description provided for @authSetNewPassword.
  ///
  /// In en, this message translates to:
  /// **'Set new password'**
  String get authSetNewPassword;

  /// No description provided for @authErrorInvalidCredentials.
  ///
  /// In en, this message translates to:
  /// **'Wrong email or password.'**
  String get authErrorInvalidCredentials;

  /// No description provided for @authErrorEmailTaken.
  ///
  /// In en, this message translates to:
  /// **'That email already has an account — try signing in instead.'**
  String get authErrorEmailTaken;

  /// No description provided for @authErrorBadResetCode.
  ///
  /// In en, this message translates to:
  /// **'That code didn\'t match — check it or request a new one.'**
  String get authErrorBadResetCode;

  /// No description provided for @resetAppBarTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset password'**
  String get resetAppBarTitle;

  /// No description provided for @resetSuccessTitle.
  ///
  /// In en, this message translates to:
  /// **'Password updated'**
  String get resetSuccessTitle;

  /// No description provided for @resetSuccessBody.
  ///
  /// In en, this message translates to:
  /// **'Sign in with your new password. Any other sessions were signed out.'**
  String get resetSuccessBody;

  /// No description provided for @resetSignInButton.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get resetSignInButton;

  /// No description provided for @resetChooseTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose a new password'**
  String get resetChooseTitle;

  /// No description provided for @resetNewPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'New password'**
  String get resetNewPasswordLabel;

  /// No description provided for @resetPasswordRequired.
  ///
  /// In en, this message translates to:
  /// **'Password is required'**
  String get resetPasswordRequired;

  /// No description provided for @resetPasswordTooShort.
  ///
  /// In en, this message translates to:
  /// **'Password must be at least 8 characters'**
  String get resetPasswordTooShort;

  /// No description provided for @resetConfirmLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirm new password'**
  String get resetConfirmLabel;

  /// No description provided for @resetConfirmRequired.
  ///
  /// In en, this message translates to:
  /// **'Confirm your new password'**
  String get resetConfirmRequired;

  /// No description provided for @resetPasswordsMismatch.
  ///
  /// In en, this message translates to:
  /// **'Passwords don\'t match'**
  String get resetPasswordsMismatch;

  /// No description provided for @resetSetNewPassword.
  ///
  /// In en, this message translates to:
  /// **'Set new password'**
  String get resetSetNewPassword;

  /// No description provided for @landingSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get landingSignIn;

  /// No description provided for @landingHeroHeadline.
  ///
  /// In en, this message translates to:
  /// **'Where to next?'**
  String get landingHeroHeadline;

  /// No description provided for @landingHeroSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Your AI travel companion — describe the trip you want and get a full day-by-day itinerary with routes, places, and flights.'**
  String get landingHeroSubtitle;

  /// No description provided for @landingPromptHint.
  ///
  /// In en, this message translates to:
  /// **'Describe your trip…'**
  String get landingPromptHint;

  /// No description provided for @landingPromptSubmit.
  ///
  /// In en, this message translates to:
  /// **'Start planning'**
  String get landingPromptSubmit;

  /// No description provided for @landingHaveAccount.
  ///
  /// In en, this message translates to:
  /// **'I already have an account'**
  String get landingHaveAccount;

  /// No description provided for @landingGetStarted.
  ///
  /// In en, this message translates to:
  /// **'Get started'**
  String get landingGetStarted;

  /// No description provided for @landingFeaturesTitle.
  ///
  /// In en, this message translates to:
  /// **'Everything you need to plan the trip'**
  String get landingFeaturesTitle;

  /// No description provided for @landingFeatureChatTitle.
  ///
  /// In en, this message translates to:
  /// **'AI itinerary chat'**
  String get landingFeatureChatTitle;

  /// No description provided for @landingFeatureChatDescription.
  ///
  /// In en, this message translates to:
  /// **'Describe the trip you want and get a day-by-day plan you can refine in conversation.'**
  String get landingFeatureChatDescription;

  /// No description provided for @landingFeatureFlightsTitle.
  ///
  /// In en, this message translates to:
  /// **'Live flight search'**
  String get landingFeatureFlightsTitle;

  /// No description provided for @landingFeatureFlightsDescription.
  ///
  /// In en, this message translates to:
  /// **'Real fares ranked by cost, time, or balance — with your baggage counted in the price.'**
  String get landingFeatureFlightsDescription;

  /// No description provided for @landingFeatureStaysTitle.
  ///
  /// In en, this message translates to:
  /// **'Hotels with real rates'**
  String get landingFeatureStaysTitle;

  /// No description provided for @landingFeatureStaysDescription.
  ///
  /// In en, this message translates to:
  /// **'Nightly prices for your dates, from hotels to vacation rentals.'**
  String get landingFeatureStaysDescription;

  /// No description provided for @landingFeatureEventsTitle.
  ///
  /// In en, this message translates to:
  /// **'What\'s on when you\'re there'**
  String get landingFeatureEventsTitle;

  /// No description provided for @landingFeatureEventsDescription.
  ///
  /// In en, this message translates to:
  /// **'Concerts, games, and local events, looked up live for your travel dates.'**
  String get landingFeatureEventsDescription;

  /// No description provided for @landingFeatureBudgetTitle.
  ///
  /// In en, this message translates to:
  /// **'Budget that keeps up'**
  String get landingFeatureBudgetTitle;

  /// No description provided for @landingFeatureBudgetDescription.
  ///
  /// In en, this message translates to:
  /// **'Planned vs. paid, daily food estimates, and every booking in one place.'**
  String get landingFeatureBudgetDescription;

  /// No description provided for @landingFeatureMapTitle.
  ///
  /// In en, this message translates to:
  /// **'Maps & smart routes'**
  String get landingFeatureMapTitle;

  /// No description provided for @landingFeatureMapDescription.
  ///
  /// In en, this message translates to:
  /// **'Every stop pinned, with day-by-day routes optimized so you walk less and see more.'**
  String get landingFeatureMapDescription;

  /// No description provided for @landingDestinationsTitle.
  ///
  /// In en, this message translates to:
  /// **'Need inspiration?'**
  String get landingDestinationsTitle;

  /// No description provided for @landingDestinationsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Tap a destination to start planning it.'**
  String get landingDestinationsSubtitle;

  /// No description provided for @landingHowTitle.
  ///
  /// In en, this message translates to:
  /// **'How it works'**
  String get landingHowTitle;

  /// No description provided for @landingHowStep1Title.
  ///
  /// In en, this message translates to:
  /// **'Describe your trip'**
  String get landingHowStep1Title;

  /// No description provided for @landingHowStep1Body.
  ///
  /// In en, this message translates to:
  /// **'Tell Anemos where, when, and what you love — in your own words.'**
  String get landingHowStep1Body;

  /// No description provided for @landingHowStep2Title.
  ///
  /// In en, this message translates to:
  /// **'Get a real plan'**
  String get landingHowStep2Title;

  /// No description provided for @landingHowStep2Body.
  ///
  /// In en, this message translates to:
  /// **'A day-by-day itinerary with flights, stays, and places — built in seconds.'**
  String get landingHowStep2Body;

  /// No description provided for @landingHowStep3Title.
  ///
  /// In en, this message translates to:
  /// **'Refine and go'**
  String get landingHowStep3Title;

  /// No description provided for @landingHowStep3Body.
  ///
  /// In en, this message translates to:
  /// **'Adjust anything in chat, track your budget, and book when you\'re ready.'**
  String get landingHowStep3Body;

  /// No description provided for @landingCtaTitle.
  ///
  /// In en, this message translates to:
  /// **'Your next trip starts with a sentence.'**
  String get landingCtaTitle;

  /// No description provided for @landingCopyright.
  ///
  /// In en, this message translates to:
  /// **'© 2026 Golden Tempo LLC'**
  String get landingCopyright;

  /// No description provided for @verifyTitle.
  ///
  /// In en, this message translates to:
  /// **'Verify email'**
  String get verifyTitle;

  /// No description provided for @verifyChecking.
  ///
  /// In en, this message translates to:
  /// **'Confirming your email…'**
  String get verifyChecking;

  /// No description provided for @verifySuccessTitle.
  ///
  /// In en, this message translates to:
  /// **'Email verified ✓'**
  String get verifySuccessTitle;

  /// No description provided for @verifySuccessBody.
  ///
  /// In en, this message translates to:
  /// **'You\'re all set — thanks for confirming your address.'**
  String get verifySuccessBody;

  /// No description provided for @verifyLinkExpiredTitle.
  ///
  /// In en, this message translates to:
  /// **'Link expired or already used'**
  String get verifyLinkExpiredTitle;

  /// No description provided for @verifyLinkExpiredBody.
  ///
  /// In en, this message translates to:
  /// **'Request a new verification email from your account.'**
  String get verifyLinkExpiredBody;

  /// No description provided for @verifyContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get verifyContinue;

  /// No description provided for @ssoTitle.
  ///
  /// In en, this message translates to:
  /// **'Signing you in'**
  String get ssoTitle;

  /// No description provided for @ssoFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign-in didn\'t complete'**
  String get ssoFailedTitle;

  /// No description provided for @ssoErrorCancelled.
  ///
  /// In en, this message translates to:
  /// **'Sign-in was cancelled or failed. Please try again.'**
  String get ssoErrorCancelled;

  /// No description provided for @ssoErrorExpired.
  ///
  /// In en, this message translates to:
  /// **'This sign-in link expired. Please try again.'**
  String get ssoErrorExpired;

  /// No description provided for @ssoBackToSignIn.
  ///
  /// In en, this message translates to:
  /// **'Back to sign in'**
  String get ssoBackToSignIn;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsProfileSection.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get settingsProfileSection;

  /// No description provided for @settingsDisplayName.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get settingsDisplayName;

  /// No description provided for @settingsSaveName.
  ///
  /// In en, this message translates to:
  /// **'Save name'**
  String get settingsSaveName;

  /// No description provided for @settingsNameUpdated.
  ///
  /// In en, this message translates to:
  /// **'Name updated'**
  String get settingsNameUpdated;

  /// No description provided for @settingsPasswordSection.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get settingsPasswordSection;

  /// No description provided for @settingsCurrentPassword.
  ///
  /// In en, this message translates to:
  /// **'Current password'**
  String get settingsCurrentPassword;

  /// No description provided for @settingsNewPassword.
  ///
  /// In en, this message translates to:
  /// **'New password (8+ characters)'**
  String get settingsNewPassword;

  /// No description provided for @settingsChangePassword.
  ///
  /// In en, this message translates to:
  /// **'Change password'**
  String get settingsChangePassword;

  /// No description provided for @settingsPasswordChanged.
  ///
  /// In en, this message translates to:
  /// **'Password changed — other devices were signed out'**
  String get settingsPasswordChanged;

  /// No description provided for @settingsSessionsSection.
  ///
  /// In en, this message translates to:
  /// **'Sessions'**
  String get settingsSessionsSection;

  /// No description provided for @settingsSessionsHelp.
  ///
  /// In en, this message translates to:
  /// **'Signs you out on every device, including this one.'**
  String get settingsSessionsHelp;

  /// No description provided for @settingsSignOutEverywhere.
  ///
  /// In en, this message translates to:
  /// **'Sign out everywhere'**
  String get settingsSignOutEverywhere;

  /// No description provided for @settingsSignOutEverywhereTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign out everywhere?'**
  String get settingsSignOutEverywhereTitle;

  /// No description provided for @settingsSignOutEverywhereBody.
  ///
  /// In en, this message translates to:
  /// **'This signs you out on every device, including this one.'**
  String get settingsSignOutEverywhereBody;

  /// No description provided for @settingsEmailPrefsSection.
  ///
  /// In en, this message translates to:
  /// **'Email preferences'**
  String get settingsEmailPrefsSection;

  /// No description provided for @settingsTripReminders.
  ///
  /// In en, this message translates to:
  /// **'Trip reminders'**
  String get settingsTripReminders;

  /// No description provided for @settingsTripRemindersSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Nudges about upcoming trips and things left to book.'**
  String get settingsTripRemindersSubtitle;

  /// No description provided for @settingsWeeklyIdeas.
  ///
  /// In en, this message translates to:
  /// **'Weekly planning ideas'**
  String get settingsWeeklyIdeas;

  /// No description provided for @settingsWeeklyIdeasSubtitle.
  ///
  /// In en, this message translates to:
  /// **'A weekly email with destination ideas and inspiration.'**
  String get settingsWeeklyIdeasSubtitle;

  /// No description provided for @settingsEmailPrefsUpdated.
  ///
  /// In en, this message translates to:
  /// **'Email preferences updated'**
  String get settingsEmailPrefsUpdated;

  /// No description provided for @settingsLegalSection.
  ///
  /// In en, this message translates to:
  /// **'Legal'**
  String get settingsLegalSection;

  /// No description provided for @settingsPrivacyPolicy.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get settingsPrivacyPolicy;

  /// No description provided for @settingsTermsOfService.
  ///
  /// In en, this message translates to:
  /// **'Terms of Service'**
  String get settingsTermsOfService;

  /// No description provided for @settingsDangerZoneSection.
  ///
  /// In en, this message translates to:
  /// **'Danger zone'**
  String get settingsDangerZoneSection;

  /// No description provided for @settingsDeleteAccount.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
  String get settingsDeleteAccount;

  /// No description provided for @settingsDeleteAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete account?'**
  String get settingsDeleteAccountTitle;

  /// No description provided for @settingsDeleteAccountBody.
  ///
  /// In en, this message translates to:
  /// **'This permanently deletes your account, trips and preferences. There is no undo.'**
  String get settingsDeleteAccountBody;

  /// No description provided for @settingsConfirmPassword.
  ///
  /// In en, this message translates to:
  /// **'Confirm your password'**
  String get settingsConfirmPassword;

  /// No description provided for @settingsDeleteForever.
  ///
  /// In en, this message translates to:
  /// **'Delete forever'**
  String get settingsDeleteForever;

  /// No description provided for @quizTitle.
  ///
  /// In en, this message translates to:
  /// **'Set up your travel profile'**
  String get quizTitle;

  /// No description provided for @quizSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get quizSkip;

  /// No description provided for @quizFinish.
  ///
  /// In en, this message translates to:
  /// **'Finish'**
  String get quizFinish;

  /// No description provided for @quizStyleTitle.
  ///
  /// In en, this message translates to:
  /// **'What\'s your travel style?'**
  String get quizStyleTitle;

  /// No description provided for @quizStyleSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Helps the planner match stays and activities to you.'**
  String get quizStyleSubtitle;

  /// No description provided for @quizWorkStyleTitle.
  ///
  /// In en, this message translates to:
  /// **'Do you work while you travel?'**
  String get quizWorkStyleTitle;

  /// No description provided for @quizWorkStyleSubtitle.
  ///
  /// In en, this message translates to:
  /// **'So the planner can balance wifi-ready stays and work time with exploring.'**
  String get quizWorkStyleSubtitle;

  /// No description provided for @quizInterestsTitle.
  ///
  /// In en, this message translates to:
  /// **'What do you love doing on a trip?'**
  String get quizInterestsTitle;

  /// No description provided for @quizInterestsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Pick as many as you like.'**
  String get quizInterestsSubtitle;

  /// No description provided for @quizActiveTitle.
  ///
  /// In en, this message translates to:
  /// **'How active are your trips?'**
  String get quizActiveTitle;

  /// No description provided for @quizActiveSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Both optional — they shape where you stay and how hard the outdoor days get.'**
  String get quizActiveSubtitle;

  /// No description provided for @quizCompanionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Who do you usually travel with?'**
  String get quizCompanionsTitle;

  /// No description provided for @quizCompanionSolo.
  ///
  /// In en, this message translates to:
  /// **'solo'**
  String get quizCompanionSolo;

  /// No description provided for @quizCompanionPartner.
  ///
  /// In en, this message translates to:
  /// **'partner'**
  String get quizCompanionPartner;

  /// No description provided for @quizCompanionFriends.
  ///
  /// In en, this message translates to:
  /// **'friends'**
  String get quizCompanionFriends;

  /// No description provided for @quizCompanionFamily.
  ///
  /// In en, this message translates to:
  /// **'family with kids'**
  String get quizCompanionFamily;

  /// No description provided for @quizCompanionVaries.
  ///
  /// In en, this message translates to:
  /// **'it varies'**
  String get quizCompanionVaries;

  /// No description provided for @quizHomeAirportTitle.
  ///
  /// In en, this message translates to:
  /// **'Where do you fly from?'**
  String get quizHomeAirportTitle;

  /// No description provided for @quizBaggageTitle.
  ///
  /// In en, this message translates to:
  /// **'What do you fly with?'**
  String get quizBaggageTitle;

  /// No description provided for @quizBaggageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'So the fares you\'re shown already include your bag fees.'**
  String get quizBaggageSubtitle;

  /// No description provided for @quizTripsTitle.
  ///
  /// In en, this message translates to:
  /// **'Any trips you\'re dreaming about?'**
  String get quizTripsTitle;

  /// No description provided for @quizTripsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Places, seasons, occasions — the planner will keep them in mind.'**
  String get quizTripsSubtitle;

  /// No description provided for @quizTripsHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Japan for cherry blossom season, a Greek island hop next summer…'**
  String get quizTripsHint;

  /// No description provided for @quizSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save your answers — try again, or skip for now.'**
  String get quizSaveFailed;

  /// No description provided for @quizProfileUpdated.
  ///
  /// In en, this message translates to:
  /// **'Travel profile updated'**
  String get quizProfileUpdated;

  /// Visible and screen-reader progress caption under the quiz step dots.
  ///
  /// In en, this message translates to:
  /// **'Step {n} of {total}'**
  String quizStepOf(int n, int total);

  /// No description provided for @quizLoadErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load your travel profile'**
  String get quizLoadErrorTitle;

  /// No description provided for @quizLoadErrorBody.
  ///
  /// In en, this message translates to:
  /// **'Your saved answers couldn\'t be loaded, so the quiz can\'t start yet. Check your connection and try again.'**
  String get quizLoadErrorBody;

  /// No description provided for @bookingCardEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get bookingCardEdit;

  /// No description provided for @bookingCardRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get bookingCardRemove;

  /// No description provided for @bookingCardBooked.
  ///
  /// In en, this message translates to:
  /// **'Booked'**
  String get bookingCardBooked;

  /// No description provided for @bookingCardOpenIn.
  ///
  /// In en, this message translates to:
  /// **'Open in {provider}'**
  String bookingCardOpenIn(String provider);

  /// No description provided for @bookingCardOpenSearch.
  ///
  /// In en, this message translates to:
  /// **'Open search'**
  String get bookingCardOpenSearch;

  /// No description provided for @bookingCardOpenSearchShort.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get bookingCardOpenSearchShort;

  /// No description provided for @calendarAddTo.
  ///
  /// In en, this message translates to:
  /// **'Add to calendar'**
  String get calendarAddTo;

  /// No description provided for @calendarGoogle.
  ///
  /// In en, this message translates to:
  /// **'Google Calendar'**
  String get calendarGoogle;

  /// No description provided for @calendarApple.
  ///
  /// In en, this message translates to:
  /// **'Apple Calendar (.ics)'**
  String get calendarApple;

  /// No description provided for @calendarExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not export the event: {error}'**
  String calendarExportFailed(String error);

  /// No description provided for @bookingsAddStay.
  ///
  /// In en, this message translates to:
  /// **'Add stay'**
  String get bookingsAddStay;

  /// No description provided for @bookingsAddTransport.
  ///
  /// In en, this message translates to:
  /// **'Add transport'**
  String get bookingsAddTransport;

  /// No description provided for @bookingsAddBooking.
  ///
  /// In en, this message translates to:
  /// **'Add booking'**
  String get bookingsAddBooking;

  /// No description provided for @bookingsMenuStay.
  ///
  /// In en, this message translates to:
  /// **'Stay'**
  String get bookingsMenuStay;

  /// No description provided for @bookingsMenuTransport.
  ///
  /// In en, this message translates to:
  /// **'Transport'**
  String get bookingsMenuTransport;

  /// No description provided for @bookingsMenuOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get bookingsMenuOther;

  /// No description provided for @tripOtherBookings.
  ///
  /// In en, this message translates to:
  /// **'Other bookings'**
  String get tripOtherBookings;

  /// No description provided for @bookingRowAddDetails.
  ///
  /// In en, this message translates to:
  /// **'Add details…'**
  String get bookingRowAddDetails;

  /// No description provided for @bookingRowOptions.
  ///
  /// In en, this message translates to:
  /// **'Booking options'**
  String get bookingRowOptions;

  /// No description provided for @bookingRowModeTooltip.
  ///
  /// In en, this message translates to:
  /// **'Change transport mode'**
  String get bookingRowModeTooltip;

  /// Date line for a transport leg that lands on a later calendar day than it leaves — an overnight flight, red-eye, night train or overnight ferry. Both values are already-formatted short dates.
  ///
  /// In en, this message translates to:
  /// **'{depart} → {arrive}'**
  String bookingRowDepartArrive(String depart, String arrive);

  /// Date line for a transport leg whose departure day is not known — the app knows only the day the traveler lands, so it says that rather than implying a departure date.
  ///
  /// In en, this message translates to:
  /// **'Arrives {date}'**
  String bookingRowArrivesOn(String date);

  /// No description provided for @bookingsOpenListing.
  ///
  /// In en, this message translates to:
  /// **'Open listing'**
  String get bookingsOpenListing;

  /// No description provided for @bookingsEditStay.
  ///
  /// In en, this message translates to:
  /// **'Edit stay'**
  String get bookingsEditStay;

  /// No description provided for @bookingsRemoveStay.
  ///
  /// In en, this message translates to:
  /// **'Remove stay'**
  String get bookingsRemoveStay;

  /// No description provided for @bookingsOpenBooking.
  ///
  /// In en, this message translates to:
  /// **'Open booking'**
  String get bookingsOpenBooking;

  /// No description provided for @bookingsEditTransport.
  ///
  /// In en, this message translates to:
  /// **'Edit transport'**
  String get bookingsEditTransport;

  /// No description provided for @bookingsRemoveTransport.
  ///
  /// In en, this message translates to:
  /// **'Remove transport'**
  String get bookingsRemoveTransport;

  /// No description provided for @bookingsAddAStay.
  ///
  /// In en, this message translates to:
  /// **'Add a stay'**
  String get bookingsAddAStay;

  /// No description provided for @bookingsStayNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name *'**
  String get bookingsStayNameLabel;

  /// No description provided for @bookingsStayProviderLabel.
  ///
  /// In en, this message translates to:
  /// **'Provider (Airbnb, Booking.com, …)'**
  String get bookingsStayProviderLabel;

  /// No description provided for @bookingsStayUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Listing URL'**
  String get bookingsStayUrlLabel;

  /// No description provided for @bookingsStayAddressLabel.
  ///
  /// In en, this message translates to:
  /// **'Address'**
  String get bookingsStayAddressLabel;

  /// No description provided for @bookingsCheckInOut.
  ///
  /// In en, this message translates to:
  /// **'Check-in / check-out'**
  String get bookingsCheckInOut;

  /// No description provided for @bookingsPriceNoteLabel.
  ///
  /// In en, this message translates to:
  /// **'Price note (e.g. €120/night)'**
  String get bookingsPriceNoteLabel;

  /// No description provided for @bookingsSegmentFromLabel.
  ///
  /// In en, this message translates to:
  /// **'From *'**
  String get bookingsSegmentFromLabel;

  /// No description provided for @bookingsSegmentToLabel.
  ///
  /// In en, this message translates to:
  /// **'To *'**
  String get bookingsSegmentToLabel;

  /// Under the read-only From/To of a leg the itinerary derives: its endpoints come from the trip's airports or its cities, not from this form.
  ///
  /// In en, this message translates to:
  /// **'Set by the trip.'**
  String get bookingsSegmentEndpointsFromTrip;

  /// No description provided for @bookingsDepartureDate.
  ///
  /// In en, this message translates to:
  /// **'Departure date'**
  String get bookingsDepartureDate;

  /// Optional arrival-date picker on the transport sheet. Only worth filling in for a leg that lands on a later calendar day than it leaves.
  ///
  /// In en, this message translates to:
  /// **'Arrival date (if it lands the next day)'**
  String get bookingsArrivalDate;

  /// No description provided for @bookingsSegmentProviderLabel.
  ///
  /// In en, this message translates to:
  /// **'Provider / carrier'**
  String get bookingsSegmentProviderLabel;

  /// No description provided for @bookingsSegmentUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Booking URL'**
  String get bookingsSegmentUrlLabel;

  /// No description provided for @bookingsNotesLabel.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get bookingsNotesLabel;

  /// No description provided for @bookingsModeFlight.
  ///
  /// In en, this message translates to:
  /// **'flight'**
  String get bookingsModeFlight;

  /// No description provided for @bookingsModeTrain.
  ///
  /// In en, this message translates to:
  /// **'train'**
  String get bookingsModeTrain;

  /// No description provided for @bookingsModeBus.
  ///
  /// In en, this message translates to:
  /// **'bus'**
  String get bookingsModeBus;

  /// No description provided for @bookingsModeCar.
  ///
  /// In en, this message translates to:
  /// **'car'**
  String get bookingsModeCar;

  /// No description provided for @bookingsModeFerry.
  ///
  /// In en, this message translates to:
  /// **'ferry'**
  String get bookingsModeFerry;

  /// No description provided for @bookingsModeOther.
  ///
  /// In en, this message translates to:
  /// **'other'**
  String get bookingsModeOther;

  /// No description provided for @budgetTitle.
  ///
  /// In en, this message translates to:
  /// **'Budget'**
  String get budgetTitle;

  /// No description provided for @budgetSummarySpent.
  ///
  /// In en, this message translates to:
  /// **'{amount} spent'**
  String budgetSummarySpent(String amount);

  /// No description provided for @budgetSummaryNoTarget.
  ///
  /// In en, this message translates to:
  /// **'no target'**
  String get budgetSummaryNoTarget;

  /// No description provided for @budgetPromptTitle.
  ///
  /// In en, this message translates to:
  /// **'Add to budget?'**
  String get budgetPromptTitle;

  /// No description provided for @budgetPromptSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get budgetPromptSkip;

  /// No description provided for @budgetPromptAmountLabel.
  ///
  /// In en, this message translates to:
  /// **'Amount ({currency})'**
  String budgetPromptAmountLabel(String currency);

  /// No description provided for @budgetPromptAdded.
  ///
  /// In en, this message translates to:
  /// **'{amount} added to Budget'**
  String budgetPromptAdded(String amount);

  /// No description provided for @budgetPromptLimitReached.
  ///
  /// In en, this message translates to:
  /// **'Expense limit reached — remove one in Budget first'**
  String get budgetPromptLimitReached;

  /// No description provided for @budgetEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No budget yet'**
  String get budgetEmptyTitle;

  /// No description provided for @budgetEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Set a target above, or add expenses below to track your spending.'**
  String get budgetEmptyMessage;

  /// No description provided for @budgetTargetSet.
  ///
  /// In en, this message translates to:
  /// **'Target: {amount} ({currency})'**
  String budgetTargetSet(String amount, String currency);

  /// No description provided for @budgetNoTarget.
  ///
  /// In en, this message translates to:
  /// **'No target set — tracking spend only'**
  String get budgetNoTarget;

  /// No description provided for @budgetEditExpenseTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit expense'**
  String get budgetEditExpenseTitle;

  /// No description provided for @budgetSetTargetTitle.
  ///
  /// In en, this message translates to:
  /// **'Set budget target'**
  String get budgetSetTargetTitle;

  /// No description provided for @budgetCategoryLabel.
  ///
  /// In en, this message translates to:
  /// **'Category'**
  String get budgetCategoryLabel;

  /// No description provided for @budgetGroupBy.
  ///
  /// In en, this message translates to:
  /// **'Group by'**
  String get budgetGroupBy;

  /// No description provided for @budgetGroupByCategory.
  ///
  /// In en, this message translates to:
  /// **'Category'**
  String get budgetGroupByCategory;

  /// No description provided for @budgetGroupByCity.
  ///
  /// In en, this message translates to:
  /// **'City'**
  String get budgetGroupByCity;

  /// No description provided for @budgetGroupRestOfTrip.
  ///
  /// In en, this message translates to:
  /// **'Rest of trip'**
  String get budgetGroupRestOfTrip;

  /// No description provided for @budgetCityLabel.
  ///
  /// In en, this message translates to:
  /// **'City'**
  String get budgetCityLabel;

  /// No description provided for @budgetCityNone.
  ///
  /// In en, this message translates to:
  /// **'No city'**
  String get budgetCityNone;

  /// No description provided for @budgetCityPlanLocked.
  ///
  /// In en, this message translates to:
  /// **'This is {city}\'s daily plan — its city can\'t be changed.'**
  String budgetCityPlanLocked(String city);

  /// No description provided for @budgetLabelField.
  ///
  /// In en, this message translates to:
  /// **'Label'**
  String get budgetLabelField;

  /// No description provided for @budgetAmount.
  ///
  /// In en, this message translates to:
  /// **'Amount'**
  String get budgetAmount;

  /// No description provided for @budgetCurrencyLabel.
  ///
  /// In en, this message translates to:
  /// **'Currency'**
  String get budgetCurrencyLabel;

  /// No description provided for @budgetTargetLabel.
  ///
  /// In en, this message translates to:
  /// **'Target'**
  String get budgetTargetLabel;

  /// No description provided for @budgetTargetHint.
  ///
  /// In en, this message translates to:
  /// **'Leave blank for none'**
  String get budgetTargetHint;

  /// No description provided for @budgetTargetHelp.
  ///
  /// In en, this message translates to:
  /// **'Leave the target blank to just track spending.'**
  String get budgetTargetHelp;

  /// No description provided for @budgetExpenseOptions.
  ///
  /// In en, this message translates to:
  /// **'Expense options'**
  String get budgetExpenseOptions;

  /// No description provided for @budgetMenuEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get budgetMenuEdit;

  /// No description provided for @budgetTotalSpent.
  ///
  /// In en, this message translates to:
  /// **'Total spent'**
  String get budgetTotalSpent;

  /// No description provided for @budgetRemaining.
  ///
  /// In en, this message translates to:
  /// **'Remaining'**
  String get budgetRemaining;

  /// No description provided for @budgetAddHint.
  ///
  /// In en, this message translates to:
  /// **'Add an expense…'**
  String get budgetAddHint;

  /// No description provided for @budgetAddExpenseTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add expense'**
  String get budgetAddExpenseTooltip;

  /// No description provided for @budgetCategoryFlights.
  ///
  /// In en, this message translates to:
  /// **'Flights'**
  String get budgetCategoryFlights;

  /// No description provided for @budgetCategoryLodging.
  ///
  /// In en, this message translates to:
  /// **'Lodging'**
  String get budgetCategoryLodging;

  /// No description provided for @budgetCategoryFood.
  ///
  /// In en, this message translates to:
  /// **'Food'**
  String get budgetCategoryFood;

  /// No description provided for @budgetCategoryActivities.
  ///
  /// In en, this message translates to:
  /// **'Activities'**
  String get budgetCategoryActivities;

  /// No description provided for @budgetCategoryTransport.
  ///
  /// In en, this message translates to:
  /// **'Transport'**
  String get budgetCategoryTransport;

  /// No description provided for @budgetCategoryShopping.
  ///
  /// In en, this message translates to:
  /// **'Shopping'**
  String get budgetCategoryShopping;

  /// No description provided for @budgetCategoryGeneral.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get budgetCategoryGeneral;

  /// No description provided for @budgetPlanAddAs.
  ///
  /// In en, this message translates to:
  /// **'Add as'**
  String get budgetPlanAddAs;

  /// No description provided for @budgetPlanStatePlanned.
  ///
  /// In en, this message translates to:
  /// **'Planned'**
  String get budgetPlanStatePlanned;

  /// No description provided for @budgetPlanStatePaid.
  ///
  /// In en, this message translates to:
  /// **'Paid'**
  String get budgetPlanStatePaid;

  /// No description provided for @budgetPlanRowBothSemantics.
  ///
  /// In en, this message translates to:
  /// **'Planned {planned}, paid {paid}'**
  String budgetPlanRowBothSemantics(String planned, String paid);

  /// No description provided for @budgetPlanTotalPlanned.
  ///
  /// In en, this message translates to:
  /// **'Total planned'**
  String get budgetPlanTotalPlanned;

  /// No description provided for @budgetPlanProjected.
  ///
  /// In en, this message translates to:
  /// **'Projected {amount}'**
  String budgetPlanProjected(String amount);

  /// No description provided for @budgetPlanOverTargetBy.
  ///
  /// In en, this message translates to:
  /// **'{amount} over target'**
  String budgetPlanOverTargetBy(String amount);

  /// No description provided for @budgetPlanVsPlan.
  ///
  /// In en, this message translates to:
  /// **'Vs plan'**
  String get budgetPlanVsPlan;

  /// No description provided for @budgetPlanDeltaOver.
  ///
  /// In en, this message translates to:
  /// **'{amount} over'**
  String budgetPlanDeltaOver(String amount);

  /// No description provided for @budgetPlanDeltaUnder.
  ///
  /// In en, this message translates to:
  /// **'{amount} under'**
  String budgetPlanDeltaUnder(String amount);

  /// No description provided for @budgetPlanDeltaOnPlan.
  ///
  /// In en, this message translates to:
  /// **'On plan'**
  String get budgetPlanDeltaOnPlan;

  /// No description provided for @budgetPlanMarkPaid.
  ///
  /// In en, this message translates to:
  /// **'Mark as paid'**
  String get budgetPlanMarkPaid;

  /// No description provided for @budgetPlanMarkPlanned.
  ///
  /// In en, this message translates to:
  /// **'Mark as planned'**
  String get budgetPlanMarkPlanned;

  /// No description provided for @budgetPlanPaidAmountLabel.
  ///
  /// In en, this message translates to:
  /// **'Paid ({currency})'**
  String budgetPlanPaidAmountLabel(String currency);

  /// No description provided for @budgetPlanPlannedAmountLabel.
  ///
  /// In en, this message translates to:
  /// **'Planned ({currency})'**
  String budgetPlanPlannedAmountLabel(String currency);

  /// No description provided for @budgetPlanPlannedHelper.
  ///
  /// In en, this message translates to:
  /// **'Planned {amount}'**
  String budgetPlanPlannedHelper(String amount);

  /// No description provided for @budgetPlanAmountsHelp.
  ///
  /// In en, this message translates to:
  /// **'Fill in what you plan to spend, what you paid, or both.'**
  String get budgetPlanAmountsHelp;

  /// No description provided for @budgetPlanMovedBack.
  ///
  /// In en, this message translates to:
  /// **'{label} moved back to planned'**
  String budgetPlanMovedBack(String label);

  /// No description provided for @budgetPlanGroupHasPlanned.
  ///
  /// In en, this message translates to:
  /// **'Includes planned amounts'**
  String get budgetPlanGroupHasPlanned;

  /// No description provided for @budgetPlanAutoLocked.
  ///
  /// In en, this message translates to:
  /// **'From a booking — un-book it to remove'**
  String get budgetPlanAutoLocked;

  /// No description provided for @budgetDailyTitle.
  ///
  /// In en, this message translates to:
  /// **'Daily food & drink'**
  String get budgetDailyTitle;

  /// No description provided for @budgetDailySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Typical local prices, per person — an estimate, not a quote.'**
  String get budgetDailySubtitle;

  /// No description provided for @budgetDailyRate.
  ///
  /// In en, this message translates to:
  /// **'{amount}/person/day'**
  String budgetDailyRate(String amount);

  /// No description provided for @budgetDailyNights.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 night} other{{count} nights}}'**
  String budgetDailyNights(int count);

  /// No description provided for @budgetDailyAdd.
  ///
  /// In en, this message translates to:
  /// **'Add to plan'**
  String get budgetDailyAdd;

  /// No description provided for @budgetDailyInPlan.
  ///
  /// In en, this message translates to:
  /// **'In your plan · {amount}'**
  String budgetDailyInPlan(String amount);

  /// No description provided for @budgetDailyAdded.
  ///
  /// In en, this message translates to:
  /// **'{city} food & drink added to your plan'**
  String budgetDailyAdded(String city);

  /// No description provided for @budgetDailyExpenseLabel.
  ///
  /// In en, this message translates to:
  /// **'Food & drink · {city}'**
  String budgetDailyExpenseLabel(String city);

  /// No description provided for @budgetDailyTravelers.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 traveler} other{{count} travelers}}'**
  String budgetDailyTravelers(int count);

  /// No description provided for @budgetDailyTravelersAdd.
  ///
  /// In en, this message translates to:
  /// **'One more traveler'**
  String get budgetDailyTravelersAdd;

  /// No description provided for @budgetDailyTravelersRemove.
  ///
  /// In en, this message translates to:
  /// **'One fewer traveler'**
  String get budgetDailyTravelersRemove;

  /// No description provided for @budgetDailyTierLabel.
  ///
  /// In en, this message translates to:
  /// **'Spending level'**
  String get budgetDailyTierLabel;

  /// No description provided for @budgetDailyTierBudget.
  ///
  /// In en, this message translates to:
  /// **'Budget'**
  String get budgetDailyTierBudget;

  /// No description provided for @budgetDailyTierMid.
  ///
  /// In en, this message translates to:
  /// **'Mid-range'**
  String get budgetDailyTierMid;

  /// No description provided for @budgetDailyTierLuxury.
  ///
  /// In en, this message translates to:
  /// **'Splurge'**
  String get budgetDailyTierLuxury;

  /// No description provided for @budgetDailyTierFromProfile.
  ///
  /// In en, this message translates to:
  /// **'From your saved budget level'**
  String get budgetDailyTierFromProfile;

  /// No description provided for @checklistTitle.
  ///
  /// In en, this message translates to:
  /// **'Packing & prep'**
  String get checklistTitle;

  /// No description provided for @checklistSummary.
  ///
  /// In en, this message translates to:
  /// **'{total, plural, =0{No items yet} other{{checked} of {total} packed}}'**
  String checklistSummary(int checked, int total);

  /// No description provided for @checklistEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing packed yet'**
  String get checklistEmptyTitle;

  /// No description provided for @checklistEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Add items below, or ask the AI assistant to help build your list.'**
  String get checklistEmptyMessage;

  /// No description provided for @checklistEditItemTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit item'**
  String get checklistEditItemTitle;

  /// No description provided for @checklistItemLabel.
  ///
  /// In en, this message translates to:
  /// **'Item'**
  String get checklistItemLabel;

  /// No description provided for @checklistItemOptions.
  ///
  /// In en, this message translates to:
  /// **'Item options'**
  String get checklistItemOptions;

  /// No description provided for @checklistMenuEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get checklistMenuEdit;

  /// No description provided for @checklistAddHint.
  ///
  /// In en, this message translates to:
  /// **'Add an item…'**
  String get checklistAddHint;

  /// No description provided for @checklistAddItemTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add item'**
  String get checklistAddItemTooltip;

  /// No description provided for @checklistCategoryDocuments.
  ///
  /// In en, this message translates to:
  /// **'Documents'**
  String get checklistCategoryDocuments;

  /// No description provided for @checklistCategoryClothing.
  ///
  /// In en, this message translates to:
  /// **'Clothing'**
  String get checklistCategoryClothing;

  /// No description provided for @checklistCategoryElectronics.
  ///
  /// In en, this message translates to:
  /// **'Electronics'**
  String get checklistCategoryElectronics;

  /// No description provided for @checklistCategoryHealth.
  ///
  /// In en, this message translates to:
  /// **'Health'**
  String get checklistCategoryHealth;

  /// No description provided for @checklistCategoryGeneral.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get checklistCategoryGeneral;

  /// No description provided for @itemDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Add place'**
  String get itemDialogTitle;

  /// No description provided for @itemDialogSearchLabel.
  ///
  /// In en, this message translates to:
  /// **'Search for a place'**
  String get itemDialogSearchLabel;

  /// No description provided for @itemDialogSearchHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Pastéis de Belém, Lisbon'**
  String get itemDialogSearchHint;

  /// No description provided for @itemDialogPickDifferent.
  ///
  /// In en, this message translates to:
  /// **'Pick a different place'**
  String get itemDialogPickDifferent;

  /// No description provided for @itemDialogAddManually.
  ///
  /// In en, this message translates to:
  /// **'Can\'t find it? Add manually'**
  String get itemDialogAddManually;

  /// No description provided for @itemDialogPlaceNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Place name'**
  String get itemDialogPlaceNameLabel;

  /// No description provided for @itemDialogSearchInstead.
  ///
  /// In en, this message translates to:
  /// **'Search places instead'**
  String get itemDialogSearchInstead;

  /// No description provided for @itemDialogDayLabel.
  ///
  /// In en, this message translates to:
  /// **'Day'**
  String get itemDialogDayLabel;

  /// No description provided for @itemDialogUnscheduled.
  ///
  /// In en, this message translates to:
  /// **'Unscheduled'**
  String get itemDialogUnscheduled;

  /// No description provided for @itemDialogDayN.
  ///
  /// In en, this message translates to:
  /// **'Day {day}'**
  String itemDialogDayN(int day);

  /// No description provided for @itemDialogNewDay.
  ///
  /// In en, this message translates to:
  /// **'New day ({day})'**
  String itemDialogNewDay(int day);

  /// No description provided for @itemDialogTimeOfDayLabel.
  ///
  /// In en, this message translates to:
  /// **'Time of day'**
  String get itemDialogTimeOfDayLabel;

  /// No description provided for @itemDialogTimeAny.
  ///
  /// In en, this message translates to:
  /// **'Any'**
  String get itemDialogTimeAny;

  /// No description provided for @itemDialogTimeMorning.
  ///
  /// In en, this message translates to:
  /// **'Morning'**
  String get itemDialogTimeMorning;

  /// No description provided for @itemDialogTimeAfternoon.
  ///
  /// In en, this message translates to:
  /// **'Afternoon'**
  String get itemDialogTimeAfternoon;

  /// No description provided for @itemDialogTimeEvening.
  ///
  /// In en, this message translates to:
  /// **'Evening'**
  String get itemDialogTimeEvening;

  /// No description provided for @itemDialogCategoryAttraction.
  ///
  /// In en, this message translates to:
  /// **'Attraction'**
  String get itemDialogCategoryAttraction;

  /// No description provided for @itemDialogCategoryRestaurant.
  ///
  /// In en, this message translates to:
  /// **'Restaurant'**
  String get itemDialogCategoryRestaurant;

  /// No description provided for @itemDialogAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get itemDialogAdd;

  /// No description provided for @itemDialogNoResults.
  ///
  /// In en, this message translates to:
  /// **'No places found — try a different search, or add the place manually.'**
  String get itemDialogNoResults;

  /// No description provided for @itemDialogSearchUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Search unavailable — add the place manually below.'**
  String get itemDialogSearchUnavailable;

  /// No description provided for @itemDialogErrorEnterName.
  ///
  /// In en, this message translates to:
  /// **'Enter a name for the place.'**
  String get itemDialogErrorEnterName;

  /// No description provided for @itemDialogErrorPickPlace.
  ///
  /// In en, this message translates to:
  /// **'Pick a place first.'**
  String get itemDialogErrorPickPlace;

  /// No description provided for @itemDialogErrorAddFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not add the place: {error}'**
  String itemDialogErrorAddFailed(String error);

  /// No description provided for @commonOffline.
  ///
  /// In en, this message translates to:
  /// **'You\'re offline — reconnect to make changes.'**
  String get commonOffline;

  /// No description provided for @commonGenericError.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Try again.'**
  String get commonGenericError;

  /// No description provided for @tripTitleFallback.
  ///
  /// In en, this message translates to:
  /// **'Trip'**
  String get tripTitleFallback;

  /// No description provided for @tripOtherPlaces.
  ///
  /// In en, this message translates to:
  /// **'Other places'**
  String get tripOtherPlaces;

  /// No description provided for @tripOfflineGuard.
  ///
  /// In en, this message translates to:
  /// **'You\'re offline — reconnect to make changes.'**
  String get tripOfflineGuard;

  /// No description provided for @tripUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Update failed: {error}'**
  String tripUpdateFailed(String error);

  /// No description provided for @tripDeleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Delete failed: {error}'**
  String tripDeleteFailed(String error);

  /// No description provided for @tripReorderFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not reorder: {error}'**
  String tripReorderFailed(String error);

  /// No description provided for @tripLeaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not remove trip: {error}'**
  String tripLeaveFailed(String error);

  /// No description provided for @tripAddStayFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not add stay: {error}'**
  String tripAddStayFailed(String error);

  /// No description provided for @tripRemoveStayFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not remove stay: {error}'**
  String tripRemoveStayFailed(String error);

  /// No description provided for @tripUpdateStayFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update stay: {error}'**
  String tripUpdateStayFailed(String error);

  /// No description provided for @tripAddTransportFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not add transport: {error}'**
  String tripAddTransportFailed(String error);

  /// No description provided for @tripRemoveTransportFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not remove transport: {error}'**
  String tripRemoveTransportFailed(String error);

  /// No description provided for @tripUpdateTransportFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update transport: {error}'**
  String tripUpdateTransportFailed(String error);

  /// No description provided for @tripShareLinkFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not create share link: {error}'**
  String tripShareLinkFailed(String error);

  /// No description provided for @tripPrintExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open the printable view: {error}'**
  String tripPrintExportFailed(String error);

  /// No description provided for @tripCalendarExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not export the calendar: {error}'**
  String tripCalendarExportFailed(String error);

  /// No description provided for @tripEventExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not export the event: {error}'**
  String tripEventExportFailed(String error);

  /// No description provided for @tripSharingOffFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not turn off sharing: {error}'**
  String tripSharingOffFailed(String error);

  /// No description provided for @tripInviteFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not create invite: {error}'**
  String tripInviteFailed(String error);

  /// No description provided for @tripRemoveItemFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not remove {name}: {error}'**
  String tripRemoveItemFailed(String name, String error);

  /// No description provided for @tripRestoreItemFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not restore {name}: {error}'**
  String tripRestoreItemFailed(String name, String error);

  /// No description provided for @tripUpdateItemFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update {name}: {error}'**
  String tripUpdateItemFailed(String name, String error);

  /// No description provided for @tripMoveItemFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not move item: {error}'**
  String tripMoveItemFailed(String error);

  /// No description provided for @tripUpdateBookingFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update booking: {error}'**
  String tripUpdateBookingFailed(String error);

  /// No description provided for @tripUndoFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not undo: {error}'**
  String tripUndoFailed(String error);

  /// No description provided for @tripAddPackingFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not add packing item: {error}'**
  String tripAddPackingFailed(String error);

  /// No description provided for @tripLoadBudgetFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load budget: {error}'**
  String tripLoadBudgetFailed(String error);

  /// No description provided for @tripUpdateBudgetFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update budget: {error}'**
  String tripUpdateBudgetFailed(String error);

  /// No description provided for @tripSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Save failed: {error}'**
  String tripSaveFailed(String error);

  /// No description provided for @tripOpenLinkFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open link'**
  String get tripOpenLinkFailed;

  /// No description provided for @tripFerrySearchFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open ferry search'**
  String get tripFerrySearchFailed;

  /// No description provided for @tripLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load this trip'**
  String get tripLoadFailed;

  /// No description provided for @tripEditDetails.
  ///
  /// In en, this message translates to:
  /// **'Edit trip details'**
  String get tripEditDetails;

  /// No description provided for @tripDetailsNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get tripDetailsNameLabel;

  /// No description provided for @tripDetailsNameRequired.
  ///
  /// In en, this message translates to:
  /// **'A trip needs a name'**
  String get tripDetailsNameRequired;

  /// No description provided for @tripDetailsDescriptionLabel.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get tripDetailsDescriptionLabel;

  /// No description provided for @tripDetailsDescriptionHint.
  ///
  /// In en, this message translates to:
  /// **'Ten days circling Sicily — Palermo\'s markets, the temples at Agrigento, then Catania.'**
  String get tripDetailsDescriptionHint;

  /// No description provided for @tripDetailsDescriptionHelp.
  ///
  /// In en, this message translates to:
  /// **'Shown under the title on this trip. Leave it empty to remove it.'**
  String get tripDetailsDescriptionHelp;

  /// No description provided for @tripDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete trip?'**
  String get tripDeleteTitle;

  /// No description provided for @tripDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'This cannot be undone.'**
  String get tripDeleteBody;

  /// No description provided for @tripLeaveTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove from my trips?'**
  String get tripLeaveTitle;

  /// No description provided for @tripLeaveBody.
  ///
  /// In en, this message translates to:
  /// **'You\'ll lose access until you\'re invited again. The trip itself is not deleted.'**
  String get tripLeaveBody;

  /// No description provided for @tripRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get tripRemove;

  /// No description provided for @tripUndo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get tripUndo;

  /// No description provided for @tripAssistantLabel.
  ///
  /// In en, this message translates to:
  /// **'Trip assistant'**
  String get tripAssistantLabel;

  /// No description provided for @tripRefiningSection.
  ///
  /// In en, this message translates to:
  /// **'Refining {section}'**
  String tripRefiningSection(String section);

  /// No description provided for @tripRefineCity.
  ///
  /// In en, this message translates to:
  /// **'Refine {city}'**
  String tripRefineCity(String city);

  /// No description provided for @tripRefineThisDay.
  ///
  /// In en, this message translates to:
  /// **'Refine this day'**
  String get tripRefineThisDay;

  /// No description provided for @tripDayNothingPlanned.
  ///
  /// In en, this message translates to:
  /// **'Nothing planned yet'**
  String get tripDayNothingPlanned;

  /// No description provided for @tripPlanThisDay.
  ///
  /// In en, this message translates to:
  /// **'Plan this day'**
  String get tripPlanThisDay;

  /// No description provided for @tripPlanTheseDays.
  ///
  /// In en, this message translates to:
  /// **'Plan these days'**
  String get tripPlanTheseDays;

  /// No description provided for @tripUnplannedDays.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 day unplanned} other{{count} days unplanned}}'**
  String tripUnplannedDays(int count);

  /// No description provided for @tripPlanWithAI.
  ///
  /// In en, this message translates to:
  /// **'Plan with AI'**
  String get tripPlanWithAI;

  /// No description provided for @tripPlanFromScratch.
  ///
  /// In en, this message translates to:
  /// **'Plan your trip'**
  String get tripPlanFromScratch;

  /// No description provided for @tripRefineWithAI.
  ///
  /// In en, this message translates to:
  /// **'Refine with AI'**
  String get tripRefineWithAI;

  /// No description provided for @tripAskAI.
  ///
  /// In en, this message translates to:
  /// **'Ask AI about this trip'**
  String get tripAskAI;

  /// No description provided for @tripShareLinkCopied.
  ///
  /// In en, this message translates to:
  /// **'Share link copied to clipboard'**
  String get tripShareLinkCopied;

  /// No description provided for @tripSharingTurnedOff.
  ///
  /// In en, this message translates to:
  /// **'Sharing turned off — links no longer work (existing co-planners and followers keep access)'**
  String get tripSharingTurnedOff;

  /// No description provided for @tripCoPlanInviteMessage.
  ///
  /// In en, this message translates to:
  /// **'Co-plan with me: {summary}'**
  String tripCoPlanInviteMessage(String summary);

  /// No description provided for @tripInviteCopied.
  ///
  /// In en, this message translates to:
  /// **'Co-planner invite copied — anyone with it can edit'**
  String get tripInviteCopied;

  /// No description provided for @tripCoPlannerRemoved.
  ///
  /// In en, this message translates to:
  /// **'Co-planner removed'**
  String get tripCoPlannerRemoved;

  /// No description provided for @tripInviteSent.
  ///
  /// In en, this message translates to:
  /// **'Invite sent to {email}'**
  String tripInviteSent(String email);

  /// No description provided for @tripShareTrip.
  ///
  /// In en, this message translates to:
  /// **'Share trip'**
  String get tripShareTrip;

  /// No description provided for @tripShareLinkAction.
  ///
  /// In en, this message translates to:
  /// **'Share link…'**
  String get tripShareLinkAction;

  /// No description provided for @tripCopyShareLink.
  ///
  /// In en, this message translates to:
  /// **'Copy share link'**
  String get tripCopyShareLink;

  /// No description provided for @tripShareInviteAction.
  ///
  /// In en, this message translates to:
  /// **'Share co-planner invite…'**
  String get tripShareInviteAction;

  /// No description provided for @tripCopyInviteLink.
  ///
  /// In en, this message translates to:
  /// **'Copy invite link (can edit)'**
  String get tripCopyInviteLink;

  /// No description provided for @tripManageAccess.
  ///
  /// In en, this message translates to:
  /// **'Manage access'**
  String get tripManageAccess;

  /// No description provided for @tripPrintSavePdf.
  ///
  /// In en, this message translates to:
  /// **'Print / Save as PDF'**
  String get tripPrintSavePdf;

  /// No description provided for @tripAddToCalendar.
  ///
  /// In en, this message translates to:
  /// **'Add to calendar'**
  String get tripAddToCalendar;

  /// No description provided for @tripTurnOffSharing.
  ///
  /// In en, this message translates to:
  /// **'Turn off sharing'**
  String get tripTurnOffSharing;

  /// Confirmation before revoking a trip's share links. Revoking cuts off everyone already holding one, and the old links never work again.
  ///
  /// In en, this message translates to:
  /// **'Turn off sharing?'**
  String get tripTurnOffSharingConfirmTitle;

  /// No description provided for @tripTurnOffSharingConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Anyone with a link will lose access to this trip. Links you\'ve already sent stop working.'**
  String get tripTurnOffSharingConfirmBody;

  /// No description provided for @tripTurnOffSharingConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Turn off'**
  String get tripTurnOffSharingConfirmAction;

  /// No description provided for @tripDeleteTrip.
  ///
  /// In en, this message translates to:
  /// **'Delete trip'**
  String get tripDeleteTrip;

  /// No description provided for @tripRemoveFromMyTrips.
  ///
  /// In en, this message translates to:
  /// **'Remove from my trips'**
  String get tripRemoveFromMyTrips;

  /// No description provided for @tripMoreActions.
  ///
  /// In en, this message translates to:
  /// **'More options'**
  String get tripMoreActions;

  /// No description provided for @tripAirportsTitle.
  ///
  /// In en, this message translates to:
  /// **'Trip airports'**
  String get tripAirportsTitle;

  /// No description provided for @tripAirportsHelp.
  ///
  /// In en, this message translates to:
  /// **'Which airports this trip flies out of and comes home into. Your saved home airport doesn\'t change.'**
  String get tripAirportsHelp;

  /// No description provided for @tripAirportsDepartsFrom.
  ///
  /// In en, this message translates to:
  /// **'Departs from'**
  String get tripAirportsDepartsFrom;

  /// No description provided for @tripAirportsReturnsInto.
  ///
  /// In en, this message translates to:
  /// **'Returns into'**
  String get tripAirportsReturnsInto;

  /// No description provided for @tripAirportsSameBothWays.
  ///
  /// In en, this message translates to:
  /// **'Comes home into the same airport'**
  String get tripAirportsSameBothWays;

  /// No description provided for @tripAirportsUseHomeAirport.
  ///
  /// In en, this message translates to:
  /// **'Use my home airport'**
  String get tripAirportsUseHomeAirport;

  /// No description provided for @tripAirportsPickOne.
  ///
  /// In en, this message translates to:
  /// **'Pick an airport from the list.'**
  String get tripAirportsPickOne;

  /// No description provided for @tripAirportsBothNeeded.
  ///
  /// In en, this message translates to:
  /// **'Pick an airport for both ends, or clear them.'**
  String get tripAirportsBothNeeded;

  /// Shown when the trip states no airport of its own, naming what its departure and return legs fall back to.
  ///
  /// In en, this message translates to:
  /// **'Right now these legs use {label}.'**
  String tripAirportsCurrentFallback(String label);

  /// No description provided for @tripAirportsMenuLabel.
  ///
  /// In en, this message translates to:
  /// **'Trip airports…'**
  String get tripAirportsMenuLabel;

  /// No description provided for @tripAirportsChangeDeparture.
  ///
  /// In en, this message translates to:
  /// **'Change departure airport…'**
  String get tripAirportsChangeDeparture;

  /// No description provided for @tripAirportsChangeReturn.
  ///
  /// In en, this message translates to:
  /// **'Change return airport…'**
  String get tripAirportsChangeReturn;

  /// No description provided for @tripAirportsChangeLink.
  ///
  /// In en, this message translates to:
  /// **'Change airport'**
  String get tripAirportsChangeLink;

  /// Confirmation after changing a trip's airports. The zero case is honest rather than an error: a trip with no cities has no derived legs to rename.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Saved. No departure or return leg yet — they\'ll use these airports when they appear.} =1{Saved. 1 leg renamed.} other{Saved. {count} legs renamed.}}'**
  String tripAirportsSaved(int count);

  /// No description provided for @tripAirportsFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save the trip\'s airports: {error}'**
  String tripAirportsFailed(String error);

  /// No description provided for @tripLocalIntel.
  ///
  /// In en, this message translates to:
  /// **'Local intel'**
  String get tripLocalIntel;

  /// No description provided for @tripLocalGuideTitle.
  ///
  /// In en, this message translates to:
  /// **'Local guide: {title}'**
  String tripLocalGuideTitle(String title);

  /// No description provided for @tripGuideBy.
  ///
  /// In en, this message translates to:
  /// **'By {name}'**
  String tripGuideBy(String name);

  /// Header of the per-city events rail on the trip detail page. Counts every event the lookup returned, not the number of cards shown.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 event while you\'re here} other{{count} events while you\'re here}}'**
  String tripEventsWhileHereCount(int count);

  /// Same header when the lookup came back at the server's per-city cap, where the true total is unknown and could be higher.
  ///
  /// In en, this message translates to:
  /// **'{count}+ events while you\'re here'**
  String tripEventsWhileHereCountCapped(int count);

  /// Title of the bottom sheet listing every event found for one city.
  ///
  /// In en, this message translates to:
  /// **'Events in {city}'**
  String tripEventsInCity(String city);

  /// Footnote on the events sheet naming the listings provider, so the list doesn't read as everything happening in the city.
  ///
  /// In en, this message translates to:
  /// **'Listings from Ticketmaster'**
  String get tripEventsSource;

  /// No description provided for @tripFindingEvents.
  ///
  /// In en, this message translates to:
  /// **'Finding events in {city}…'**
  String tripFindingEvents(String city);

  /// No description provided for @tripFindEventsIn.
  ///
  /// In en, this message translates to:
  /// **'Find events in {city}'**
  String tripFindEventsIn(String city);

  /// No description provided for @tripRecommendedBy.
  ///
  /// In en, this message translates to:
  /// **'Recommended by {name}'**
  String tripRecommendedBy(String name);

  /// No description provided for @tripFindFlights.
  ///
  /// In en, this message translates to:
  /// **'Find flights'**
  String get tripFindFlights;

  /// No description provided for @tripFindFlightsShort.
  ///
  /// In en, this message translates to:
  /// **'Flights'**
  String get tripFindFlightsShort;

  /// No description provided for @tripFindFerries.
  ///
  /// In en, this message translates to:
  /// **'Find ferries'**
  String get tripFindFerries;

  /// No description provided for @tripFindFerriesShort.
  ///
  /// In en, this message translates to:
  /// **'Ferries'**
  String get tripFindFerriesShort;

  /// No description provided for @tripAddBooking.
  ///
  /// In en, this message translates to:
  /// **'Add a booking'**
  String get tripAddBooking;

  /// No description provided for @tripEditBooking.
  ///
  /// In en, this message translates to:
  /// **'Edit booking'**
  String get tripEditBooking;

  /// No description provided for @tripFieldType.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get tripFieldType;

  /// No description provided for @tripKindStay.
  ///
  /// In en, this message translates to:
  /// **'Stay'**
  String get tripKindStay;

  /// No description provided for @tripKindTransport.
  ///
  /// In en, this message translates to:
  /// **'Transport'**
  String get tripKindTransport;

  /// No description provided for @tripKindOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get tripKindOther;

  /// No description provided for @tripFieldTitle.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get tripFieldTitle;

  /// No description provided for @tripFieldOrigin.
  ///
  /// In en, this message translates to:
  /// **'Origin (optional)'**
  String get tripFieldOrigin;

  /// No description provided for @tripFieldDestination.
  ///
  /// In en, this message translates to:
  /// **'Destination (optional)'**
  String get tripFieldDestination;

  /// No description provided for @tripFieldDepartDate.
  ///
  /// In en, this message translates to:
  /// **'Depart date (optional)'**
  String get tripFieldDepartDate;

  /// No description provided for @tripFieldCheckIn.
  ///
  /// In en, this message translates to:
  /// **'Check-in (optional)'**
  String get tripFieldCheckIn;

  /// No description provided for @tripFieldCheckOut.
  ///
  /// In en, this message translates to:
  /// **'Check-out (optional)'**
  String get tripFieldCheckOut;

  /// No description provided for @tripFieldLink.
  ///
  /// In en, this message translates to:
  /// **'Link (optional, overrides search)'**
  String get tripFieldLink;

  /// No description provided for @tripTitleRequired.
  ///
  /// In en, this message translates to:
  /// **'Title is required'**
  String get tripTitleRequired;

  /// No description provided for @tripClearDate.
  ///
  /// In en, this message translates to:
  /// **'Clear date'**
  String get tripClearDate;

  /// No description provided for @tripItinerary.
  ///
  /// In en, this message translates to:
  /// **'Itinerary'**
  String get tripItinerary;

  /// No description provided for @tripToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get tripToday;

  /// No description provided for @tripAddPlace.
  ///
  /// In en, this message translates to:
  /// **'Add place'**
  String get tripAddPlace;

  /// Tooltip (and phone overflow-menu label) for the one-tap control that folds every destination group on the trip itinerary. Flips to tripExpandAll once everything is collapsed. 'All' means every destination — say it without naming them, the way a file tree's collapse-all does.
  ///
  /// In en, this message translates to:
  /// **'Collapse all'**
  String get tripCollapseAll;

  /// The other face of tripCollapseAll: re-opens every destination group AND every day section inside them.
  ///
  /// In en, this message translates to:
  /// **'Expand all'**
  String get tripExpandAll;

  /// No description provided for @tripFilterUnbooked.
  ///
  /// In en, this message translates to:
  /// **'Not booked yet'**
  String get tripFilterUnbooked;

  /// No description provided for @tripFilterAllBooked.
  ///
  /// In en, this message translates to:
  /// **'Everything\'s booked'**
  String get tripFilterAllBooked;

  /// No description provided for @tripFilterAllBookedMessage.
  ///
  /// In en, this message translates to:
  /// **'Nothing left to book on this trip — you\'re all set.'**
  String get tripFilterAllBookedMessage;

  /// No description provided for @tripTabBookings.
  ///
  /// In en, this message translates to:
  /// **'Bookings'**
  String get tripTabBookings;

  /// No description provided for @tripBookingsLensEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No bookings yet'**
  String get tripBookingsLensEmptyTitle;

  /// No description provided for @tripBookingsLensEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Flights, stays, and reservations for this trip will show up here.'**
  String get tripBookingsLensEmptyMessage;

  /// No description provided for @tripBookingsLensNoneForDestination.
  ///
  /// In en, this message translates to:
  /// **'No bookings for this destination.'**
  String get tripBookingsLensNoneForDestination;

  /// Shown in the 'Not booked yet' scope when ONE destination is selected and that destination is fully booked. Deliberately not tripFilterAllBooked, which claims the whole trip is done.
  ///
  /// In en, this message translates to:
  /// **'Nothing left to book here.'**
  String get tripBookingsAllBookedForDestination;

  /// The Bookings filter strip's pinned chip: clears the destination filter and shows every booking. Kept short — it sits beside city names in a one-line strip.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get tripBookingsAllDestinations;

  /// No description provided for @tripNoPlacesYet.
  ///
  /// In en, this message translates to:
  /// **'No places yet'**
  String get tripNoPlacesYet;

  /// No description provided for @tripNoPlacesYetMessage.
  ///
  /// In en, this message translates to:
  /// **'Refine with AI or add a place to start your itinerary.'**
  String get tripNoPlacesYetMessage;

  /// No description provided for @tripNoMappedPlaces.
  ///
  /// In en, this message translates to:
  /// **'No mapped places'**
  String get tripNoMappedPlaces;

  /// No description provided for @tripNoPlacesInLeg.
  ///
  /// In en, this message translates to:
  /// **'No places pinned in {city}'**
  String tripNoPlacesInLeg(String city);

  /// No description provided for @tripAddPlaceMapHint.
  ///
  /// In en, this message translates to:
  /// **'Add a place to see it on the map.'**
  String get tripAddPlaceMapHint;

  /// Tooltip/semantics label for the tap-to-expand trip map preview on phones
  ///
  /// In en, this message translates to:
  /// **'Expand map'**
  String get tripExpandMap;

  /// No description provided for @tripDayN.
  ///
  /// In en, this message translates to:
  /// **'Day {n}'**
  String tripDayN(int n);

  /// No description provided for @tripDayTripTo.
  ///
  /// In en, this message translates to:
  /// **'Day trip · {town}'**
  String tripDayTripTo(String town);

  /// No description provided for @tripDayTripFallback.
  ///
  /// In en, this message translates to:
  /// **'Day trip'**
  String get tripDayTripFallback;

  /// No description provided for @tripTonight.
  ///
  /// In en, this message translates to:
  /// **'Tonight: {stays}'**
  String tripTonight(String stays);

  /// No description provided for @tripLegNights.
  ///
  /// In en, this message translates to:
  /// **'· {count, plural, one{1 night} other{{count} nights}}'**
  String tripLegNights(int count);

  /// No description provided for @tripTravelMinutes.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String tripTravelMinutes(int minutes);

  /// No description provided for @tripTravelHours.
  ///
  /// In en, this message translates to:
  /// **'{hours}h'**
  String tripTravelHours(int hours);

  /// No description provided for @tripTravelHoursMinutes.
  ///
  /// In en, this message translates to:
  /// **'{hours}h {minutes}m'**
  String tripTravelHoursMinutes(int hours, int minutes);

  /// No description provided for @tripTravelFromHub.
  ///
  /// In en, this message translates to:
  /// **'{duration} from {hub}'**
  String tripTravelFromHub(String duration, String hub);

  /// No description provided for @tripTravelTotal.
  ///
  /// In en, this message translates to:
  /// **'{duration} travel'**
  String tripTravelTotal(String duration);

  /// No description provided for @tripRainChance.
  ///
  /// In en, this message translates to:
  /// **'{percent}% rain'**
  String tripRainChance(int percent);

  /// No description provided for @tripTypicalForDates.
  ///
  /// In en, this message translates to:
  /// **'typical for these dates'**
  String get tripTypicalForDates;

  /// No description provided for @tripPlaceActions.
  ///
  /// In en, this message translates to:
  /// **'Place actions'**
  String get tripPlaceActions;

  /// No description provided for @tripOpenInGoogleMaps.
  ///
  /// In en, this message translates to:
  /// **'Open in Google Maps'**
  String get tripOpenInGoogleMaps;

  /// No description provided for @tripEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get tripEdit;

  /// No description provided for @tripMoveUp.
  ///
  /// In en, this message translates to:
  /// **'Move up'**
  String get tripMoveUp;

  /// No description provided for @tripMoveDown.
  ///
  /// In en, this message translates to:
  /// **'Move down'**
  String get tripMoveDown;

  /// No description provided for @tripReorderSection.
  ///
  /// In en, this message translates to:
  /// **'Reorder section'**
  String get tripReorderSection;

  /// No description provided for @tripAddToGoogleCalendar.
  ///
  /// In en, this message translates to:
  /// **'Add to Google Calendar'**
  String get tripAddToGoogleCalendar;

  /// No description provided for @tripAddToAppleCalendar.
  ///
  /// In en, this message translates to:
  /// **'Add to Apple Calendar (.ics)'**
  String get tripAddToAppleCalendar;

  /// No description provided for @tripRemovedItem.
  ///
  /// In en, this message translates to:
  /// **'Removed {name}'**
  String tripRemovedItem(String name);

  /// No description provided for @tripMovedToDay.
  ///
  /// In en, this message translates to:
  /// **'Moved to Day {day}'**
  String tripMovedToDay(int day);

  /// No description provided for @tripMarkedAsBooked.
  ///
  /// In en, this message translates to:
  /// **'Marked as booked'**
  String get tripMarkedAsBooked;

  /// No description provided for @tripAddedToPacking.
  ///
  /// In en, this message translates to:
  /// **'Added \"{item}\" to packing'**
  String tripAddedToPacking(String item);

  /// No description provided for @tripAddDates.
  ///
  /// In en, this message translates to:
  /// **'Add dates'**
  String get tripAddDates;

  /// No description provided for @tripCoPlanningWith.
  ///
  /// In en, this message translates to:
  /// **'Co-planning with {name} — your changes save for everyone.'**
  String tripCoPlanningWith(String name);

  /// No description provided for @tripCoPlanningShared.
  ///
  /// In en, this message translates to:
  /// **'Co-planning a shared trip — your changes save for everyone.'**
  String get tripCoPlanningShared;

  /// No description provided for @tripSharedBy.
  ///
  /// In en, this message translates to:
  /// **'Shared by {name} — view only.'**
  String tripSharedBy(String name);

  /// No description provided for @tripSharedViewOnly.
  ///
  /// In en, this message translates to:
  /// **'Shared trip — view only.'**
  String get tripSharedViewOnly;

  /// No description provided for @tripUpdatedBy.
  ///
  /// In en, this message translates to:
  /// **'Updated by {name} · {time}'**
  String tripUpdatedBy(String name, String time);

  /// No description provided for @tripOverview.
  ///
  /// In en, this message translates to:
  /// **'Overview'**
  String get tripOverview;

  /// No description provided for @tripShowMore.
  ///
  /// In en, this message translates to:
  /// **'Show more'**
  String get tripShowMore;

  /// No description provided for @tripShowLess.
  ///
  /// In en, this message translates to:
  /// **'Show less'**
  String get tripShowLess;

  /// No description provided for @tripTimeRecently.
  ///
  /// In en, this message translates to:
  /// **'recently'**
  String get tripTimeRecently;

  /// No description provided for @tripTimeJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get tripTimeJustNow;

  /// No description provided for @tripTimeMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{minutes}m ago'**
  String tripTimeMinutesAgo(int minutes);

  /// No description provided for @tripTimeHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{hours}h ago'**
  String tripTimeHoursAgo(int hours);

  /// No description provided for @tripTimeDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'{days}d ago'**
  String tripTimeDaysAgo(int days);

  /// No description provided for @tripFriendEmail.
  ///
  /// In en, this message translates to:
  /// **'Friend\'s email'**
  String get tripFriendEmail;

  /// No description provided for @tripInvite.
  ///
  /// In en, this message translates to:
  /// **'Invite'**
  String get tripInvite;

  /// No description provided for @tripNoCoPlanners.
  ///
  /// In en, this message translates to:
  /// **'No co-planners yet. Invite a friend by email above, or copy an invite link from the share menu.'**
  String get tripNoCoPlanners;

  /// No description provided for @tripRoleViewer.
  ///
  /// In en, this message translates to:
  /// **'Viewer'**
  String get tripRoleViewer;

  /// No description provided for @tripRoleCanEdit.
  ///
  /// In en, this message translates to:
  /// **'Can edit'**
  String get tripRoleCanEdit;

  /// No description provided for @tripRemoveAccess.
  ///
  /// In en, this message translates to:
  /// **'Remove access'**
  String get tripRemoveAccess;

  /// No description provided for @tripPendingInvites.
  ///
  /// In en, this message translates to:
  /// **'Pending invites'**
  String get tripPendingInvites;

  /// No description provided for @tripInvited.
  ///
  /// In en, this message translates to:
  /// **'Invited — {expires}'**
  String tripInvited(String expires);

  /// No description provided for @tripRevokeInvite.
  ///
  /// In en, this message translates to:
  /// **'Revoke invite'**
  String get tripRevokeInvite;

  /// No description provided for @tripExpiresInDays.
  ///
  /// In en, this message translates to:
  /// **'expires in {days}d'**
  String tripExpiresInDays(int days);

  /// No description provided for @tripExpiresInHours.
  ///
  /// In en, this message translates to:
  /// **'expires in {hours}h'**
  String tripExpiresInHours(int hours);

  /// No description provided for @tripExpiresSoon.
  ///
  /// In en, this message translates to:
  /// **'expires soon'**
  String get tripExpiresSoon;

  /// No description provided for @tripEditPlace.
  ///
  /// In en, this message translates to:
  /// **'Edit place'**
  String get tripEditPlace;

  /// No description provided for @tripFieldName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get tripFieldName;

  /// No description provided for @tripFieldCity.
  ///
  /// In en, this message translates to:
  /// **'City'**
  String get tripFieldCity;

  /// No description provided for @tripFieldDay.
  ///
  /// In en, this message translates to:
  /// **'Day'**
  String get tripFieldDay;

  /// No description provided for @tripCategoryAttraction.
  ///
  /// In en, this message translates to:
  /// **'Attraction'**
  String get tripCategoryAttraction;

  /// No description provided for @tripCategoryRestaurant.
  ///
  /// In en, this message translates to:
  /// **'Restaurant'**
  String get tripCategoryRestaurant;

  /// No description provided for @tripTimeMorning.
  ///
  /// In en, this message translates to:
  /// **'Morning'**
  String get tripTimeMorning;

  /// No description provided for @tripTimeAfternoon.
  ///
  /// In en, this message translates to:
  /// **'Afternoon'**
  String get tripTimeAfternoon;

  /// No description provided for @tripTimeEvening.
  ///
  /// In en, this message translates to:
  /// **'Evening'**
  String get tripTimeEvening;

  /// No description provided for @tripReorderPlaces.
  ///
  /// In en, this message translates to:
  /// **'Reorder places'**
  String get tripReorderPlaces;

  /// No description provided for @tripReorderHint.
  ///
  /// In en, this message translates to:
  /// **'Drag to change the visit order within this section.'**
  String get tripReorderHint;

  /// No description provided for @tripSaveOrder.
  ///
  /// In en, this message translates to:
  /// **'Save order'**
  String get tripSaveOrder;

  /// No description provided for @tripsListTitle.
  ///
  /// In en, this message translates to:
  /// **'My Trips'**
  String get tripsListTitle;

  /// No description provided for @tripsListErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load trips'**
  String get tripsListErrorTitle;

  /// No description provided for @tripsListErrorMessage.
  ///
  /// In en, this message translates to:
  /// **'Check your connection and try again.'**
  String get tripsListErrorMessage;

  /// No description provided for @tripsListEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No trips yet'**
  String get tripsListEmptyTitle;

  /// No description provided for @tripsListEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Chat with the AI agent to create your first trip.'**
  String get tripsListEmptyMessage;

  /// No description provided for @tripsListPlanTrip.
  ///
  /// In en, this message translates to:
  /// **'Plan a trip'**
  String get tripsListPlanTrip;

  /// No description provided for @tripsListSharedWithYou.
  ///
  /// In en, this message translates to:
  /// **'Shared with you'**
  String get tripsListSharedWithYou;

  /// No description provided for @tripsListPastTrips.
  ///
  /// In en, this message translates to:
  /// **'Past trips'**
  String get tripsListPastTrips;

  /// No description provided for @tripsListPastTripsCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 trip} other{{count} trips}}'**
  String tripsListPastTripsCount(int count);

  /// No description provided for @tripsListUpcoming.
  ///
  /// In en, this message translates to:
  /// **'Upcoming'**
  String get tripsListUpcoming;

  /// No description provided for @tripsListNewTrip.
  ///
  /// In en, this message translates to:
  /// **'New trip'**
  String get tripsListNewTrip;

  /// No description provided for @tripsListYourTravels.
  ///
  /// In en, this message translates to:
  /// **'Your travels'**
  String get tripsListYourTravels;

  /// No description provided for @tripsListTravelMap.
  ///
  /// In en, this message translates to:
  /// **'Your travel map'**
  String get tripsListTravelMap;

  /// No description provided for @tripsListStatsTraveled.
  ///
  /// In en, this message translates to:
  /// **'Traveled'**
  String get tripsListStatsTraveled;

  /// No description provided for @tripsListStatsPlanned.
  ///
  /// In en, this message translates to:
  /// **'Planned'**
  String get tripsListStatsPlanned;

  /// No description provided for @tripsListStatTrips.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Trip} other{Trips}}'**
  String tripsListStatTrips(int count);

  /// No description provided for @tripsListStatTravelDays.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Travel day} other{Travel days}}'**
  String tripsListStatTravelDays(int count);

  /// No description provided for @tripsListStatCities.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{City} other{Cities}}'**
  String tripsListStatCities(int count);

  /// No description provided for @tripsListStaysCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 stay} other{{count} stays}}'**
  String tripsListStaysCount(int count);

  /// No description provided for @tripsListPackedCount.
  ///
  /// In en, this message translates to:
  /// **'{checked}/{total} packed'**
  String tripsListPackedCount(int checked, int total);

  /// No description provided for @tripsListBudgetSpentOfTarget.
  ///
  /// In en, this message translates to:
  /// **'{spent} of {target}'**
  String tripsListBudgetSpentOfTarget(String spent, String target);

  /// No description provided for @tripsListBookTransportNudge.
  ///
  /// In en, this message translates to:
  /// **'Book transport — first leg departs {date}'**
  String tripsListBookTransportNudge(String date);

  /// No description provided for @tripDurationDays.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 day} other{{count} days}}'**
  String tripDurationDays(int count);

  /// No description provided for @tripCitiesCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 city} other{{count} cities}}'**
  String tripCitiesCount(int count);

  /// No description provided for @tripsListPlaces.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 place} other{{count} places}}'**
  String tripsListPlaces(int count);

  /// No description provided for @tripsListBookedCount.
  ///
  /// In en, this message translates to:
  /// **'{booked}/{total} booked'**
  String tripsListBookedCount(int booked, int total);

  /// No description provided for @tripsListShared.
  ///
  /// In en, this message translates to:
  /// **'Shared'**
  String get tripsListShared;

  /// No description provided for @upNextEyebrow.
  ///
  /// In en, this message translates to:
  /// **'UP NEXT'**
  String get upNextEyebrow;

  /// No description provided for @upNextStartsIn.
  ///
  /// In en, this message translates to:
  /// **'{days, plural, =0{Starts today} =1{Starts tomorrow} other{Starts in {days} days}}'**
  String upNextStartsIn(int days);

  /// No description provided for @tripsListCreated.
  ///
  /// In en, this message translates to:
  /// **'Created {date}'**
  String tripsListCreated(String date);

  /// No description provided for @tripsListPlannedWith.
  ///
  /// In en, this message translates to:
  /// **'Planned with {name}'**
  String tripsListPlannedWith(String name);

  /// No description provided for @tripsListSharedBy.
  ///
  /// In en, this message translates to:
  /// **'Shared by {name}'**
  String tripsListSharedBy(String name);

  /// No description provided for @tripsListVersionsError.
  ///
  /// In en, this message translates to:
  /// **'Could not load versions'**
  String get tripsListVersionsError;

  /// No description provided for @tripsListVersionLatest.
  ///
  /// In en, this message translates to:
  /// **'latest · {date}'**
  String tripsListVersionLatest(String date);

  /// No description provided for @tripsListVersionNumbered.
  ///
  /// In en, this message translates to:
  /// **'v{version} · {date}'**
  String tripsListVersionNumbered(int version, String date);

  /// No description provided for @settingsConnectedAppsSection.
  ///
  /// In en, this message translates to:
  /// **'Connected apps'**
  String get settingsConnectedAppsSection;

  /// No description provided for @settingsConnectedAppsHelp.
  ///
  /// In en, this message translates to:
  /// **'AI assistants you\'ve allowed to create trips in your account.'**
  String get settingsConnectedAppsHelp;

  /// No description provided for @settingsConnectedAppsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No apps connected.'**
  String get settingsConnectedAppsEmpty;

  /// No description provided for @settingsConnectedAppsError.
  ///
  /// In en, this message translates to:
  /// **'Could not load connected apps'**
  String get settingsConnectedAppsError;

  /// No description provided for @settingsConnectedLastUsed.
  ///
  /// In en, this message translates to:
  /// **'Last used {date}'**
  String settingsConnectedLastUsed(String date);

  /// No description provided for @settingsConnectedNeverUsed.
  ///
  /// In en, this message translates to:
  /// **'Not used yet'**
  String get settingsConnectedNeverUsed;

  /// No description provided for @settingsRevokeAction.
  ///
  /// In en, this message translates to:
  /// **'Revoke'**
  String get settingsRevokeAction;

  /// No description provided for @settingsRevokeConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Revoke {app}?'**
  String settingsRevokeConfirmTitle(String app);

  /// No description provided for @settingsRevokeConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'It will stop being able to create trips in your account right away. You can connect it again later.'**
  String get settingsRevokeConfirmBody;

  /// No description provided for @settingsRevokedToast.
  ///
  /// In en, this message translates to:
  /// **'{app} disconnected'**
  String settingsRevokedToast(String app);

  /// No description provided for @connectAppBarTitle.
  ///
  /// In en, this message translates to:
  /// **'Connect app'**
  String get connectAppBarTitle;

  /// No description provided for @connectTitle.
  ///
  /// In en, this message translates to:
  /// **'Connect {app} to Anemos?'**
  String connectTitle(String app);

  /// No description provided for @connectUnverifiedCaution.
  ///
  /// In en, this message translates to:
  /// **'This name was provided by the app itself and hasn\'t been verified by us. Only continue if you started this from an app you trust.'**
  String get connectUnverifiedCaution;

  /// No description provided for @connectWillBeAbleTo.
  ///
  /// In en, this message translates to:
  /// **'It will be able to:'**
  String get connectWillBeAbleTo;

  /// No description provided for @connectScopeTripsWrite.
  ///
  /// In en, this message translates to:
  /// **'Create trips in your account and see your trip list'**
  String get connectScopeTripsWrite;

  /// No description provided for @connectScopeRecsRead.
  ///
  /// In en, this message translates to:
  /// **'Search Anemos\'s local recommendations'**
  String get connectScopeRecsRead;

  /// No description provided for @connectSignInPrompt.
  ///
  /// In en, this message translates to:
  /// **'Sign in to your Anemos account to continue.'**
  String get connectSignInPrompt;

  /// No description provided for @connectSignInCta.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get connectSignInCta;

  /// No description provided for @connectApprove.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connectApprove;

  /// No description provided for @connectDeny.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get connectDeny;

  /// No description provided for @connectExpiredTitle.
  ///
  /// In en, this message translates to:
  /// **'This request expired'**
  String get connectExpiredTitle;

  /// No description provided for @connectExpiredMessage.
  ///
  /// In en, this message translates to:
  /// **'Start the connection again from your AI assistant.'**
  String get connectExpiredMessage;

  /// No description provided for @importFromAi.
  ///
  /// In en, this message translates to:
  /// **'Import from AI chat'**
  String get importFromAi;

  /// No description provided for @importExplainer.
  ///
  /// In en, this message translates to:
  /// **'Planned a trip in ChatGPT or Claude? Paste the conversation — or its final summary — and we\'ll turn it into a trip you can edit.'**
  String get importExplainer;

  /// No description provided for @importCopyPrompt.
  ///
  /// In en, this message translates to:
  /// **'Copy planning prompt'**
  String get importCopyPrompt;

  /// No description provided for @importPromptCopied.
  ///
  /// In en, this message translates to:
  /// **'Prompt copied — paste it into ChatGPT or Claude to start planning.'**
  String get importPromptCopied;

  /// No description provided for @importPasteButton.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get importPasteButton;

  /// No description provided for @importPasteHint.
  ///
  /// In en, this message translates to:
  /// **'Paste your conversation or trip summary here…'**
  String get importPasteHint;

  /// No description provided for @importButton.
  ///
  /// In en, this message translates to:
  /// **'Import trip'**
  String get importButton;

  /// No description provided for @importProgressReading.
  ///
  /// In en, this message translates to:
  /// **'Reading your conversation…'**
  String get importProgressReading;

  /// No description provided for @importProgressLocating.
  ///
  /// In en, this message translates to:
  /// **'Finding places on the map…'**
  String get importProgressLocating;

  /// No description provided for @importWarningsTitle.
  ///
  /// In en, this message translates to:
  /// **'Some places need attention'**
  String get importWarningsTitle;

  /// No description provided for @importViewTrip.
  ///
  /// In en, this message translates to:
  /// **'View trip'**
  String get importViewTrip;

  /// No description provided for @logTripTitle.
  ///
  /// In en, this message translates to:
  /// **'Log a past trip'**
  String get logTripTitle;

  /// No description provided for @logTripAction.
  ///
  /// In en, this message translates to:
  /// **'Add past trip'**
  String get logTripAction;

  /// No description provided for @logTripExplainer.
  ///
  /// In en, this message translates to:
  /// **'Been somewhere we didn\'t plan? Add it here and it counts in Your travels.'**
  String get logTripExplainer;

  /// No description provided for @logTripDestinationsLabel.
  ///
  /// In en, this message translates to:
  /// **'Where did you go?'**
  String get logTripDestinationsLabel;

  /// No description provided for @logTripDestinationsHint.
  ///
  /// In en, this message translates to:
  /// **'Search a city or country'**
  String get logTripDestinationsHint;

  /// No description provided for @logTripAddByName.
  ///
  /// In en, this message translates to:
  /// **'Add \"{name}\" by name'**
  String logTripAddByName(String name);

  /// No description provided for @logTripNoCoordsNote.
  ///
  /// In en, this message translates to:
  /// **'Destinations without a map location still count as cities, but they won\'t get a dot on your travel map.'**
  String get logTripNoCoordsNote;

  /// No description provided for @logTripDatesLabel.
  ///
  /// In en, this message translates to:
  /// **'When?'**
  String get logTripDatesLabel;

  /// No description provided for @logTripPickDates.
  ///
  /// In en, this message translates to:
  /// **'Pick your travel dates'**
  String get logTripPickDates;

  /// No description provided for @logTripDatesRequired.
  ///
  /// In en, this message translates to:
  /// **'Dates are required — they\'re what counts this trip as travel you\'ve already taken.'**
  String get logTripDatesRequired;

  /// No description provided for @logTripNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name this trip (optional)'**
  String get logTripNameLabel;

  /// No description provided for @logTripSave.
  ///
  /// In en, this message translates to:
  /// **'Save trip'**
  String get logTripSave;

  /// No description provided for @importPlanningPrompt.
  ///
  /// In en, this message translates to:
  /// **'Help me plan a trip. Ask about my destination, dates, interests, pace, and budget, then build a day-by-day itinerary. When we\'re done, finish with a section titled TRIP SUMMARY that lists: the destination(s) and exact travel dates; each day as \"Day N — City\" with Morning / Afternoon / Evening entries, each written as \"Place Name — City\" using real, mappable place names; day trips marked as \"day trip from [city]\"; and how I\'m traveling between cities (flight, car, train, bus, or ferry).'**
  String get importPlanningPrompt;

  /// No description provided for @homeGreetingMorning.
  ///
  /// In en, this message translates to:
  /// **'Good morning'**
  String get homeGreetingMorning;

  /// No description provided for @homeGreetingAfternoon.
  ///
  /// In en, this message translates to:
  /// **'Good afternoon'**
  String get homeGreetingAfternoon;

  /// No description provided for @homeGreetingEvening.
  ///
  /// In en, this message translates to:
  /// **'Good evening'**
  String get homeGreetingEvening;

  /// No description provided for @homeGreetingNamed.
  ///
  /// In en, this message translates to:
  /// **'{greeting}, {name}'**
  String homeGreetingNamed(String greeting, String name);

  /// No description provided for @homeGreetingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Where are we off to next?'**
  String get homeGreetingSubtitle;

  /// No description provided for @homeHeroTitle.
  ///
  /// In en, this message translates to:
  /// **'Plan less. Travel more.'**
  String get homeHeroTitle;

  /// No description provided for @homeHeroSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Describe the trip you\'re dreaming of and I\'ll build the full itinerary — places, days, and routes.'**
  String get homeHeroSubtitle;

  /// No description provided for @homeHeroCta.
  ///
  /// In en, this message translates to:
  /// **'Let\'s go'**
  String get homeHeroCta;

  /// No description provided for @suggestionParis.
  ///
  /// In en, this message translates to:
  /// **'2 days in Paris'**
  String get suggestionParis;

  /// No description provided for @suggestionRome.
  ///
  /// In en, this message translates to:
  /// **'Museums in Rome'**
  String get suggestionRome;

  /// No description provided for @suggestionTokyo.
  ///
  /// In en, this message translates to:
  /// **'Weekend in Tokyo'**
  String get suggestionTokyo;

  /// No description provided for @suggestionGreece.
  ///
  /// In en, this message translates to:
  /// **'Island hopping in Greece'**
  String get suggestionGreece;

  /// No description provided for @suggestionLisbon.
  ///
  /// In en, this message translates to:
  /// **'3 days in Lisbon'**
  String get suggestionLisbon;

  /// No description provided for @suggestionBarcelona.
  ///
  /// In en, this message translates to:
  /// **'Tapas in Barcelona'**
  String get suggestionBarcelona;

  /// No description provided for @suggestionBangkok.
  ///
  /// In en, this message translates to:
  /// **'Street food in Bangkok'**
  String get suggestionBangkok;

  /// No description provided for @suggestionAmalfi.
  ///
  /// In en, this message translates to:
  /// **'Amalfi Coast road trip'**
  String get suggestionAmalfi;

  /// No description provided for @suggestionNewYork.
  ///
  /// In en, this message translates to:
  /// **'A week in New York'**
  String get suggestionNewYork;

  /// No description provided for @suggestionBali.
  ///
  /// In en, this message translates to:
  /// **'Beaches in Bali'**
  String get suggestionBali;

  /// No description provided for @suggestionPatagonia.
  ///
  /// In en, this message translates to:
  /// **'Hiking in Patagonia'**
  String get suggestionPatagonia;

  /// No description provided for @suggestionKenya.
  ///
  /// In en, this message translates to:
  /// **'Safari in Kenya'**
  String get suggestionKenya;

  /// No description provided for @homeLocalGuidesTitle.
  ///
  /// In en, this message translates to:
  /// **'Local guides'**
  String get homeLocalGuidesTitle;

  /// No description provided for @homeGuideByline.
  ///
  /// In en, this message translates to:
  /// **'By {name}'**
  String homeGuideByline(String name);

  /// No description provided for @shellNavHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get shellNavHome;

  /// No description provided for @shellNavPlan.
  ///
  /// In en, this message translates to:
  /// **'Plan'**
  String get shellNavPlan;

  /// No description provided for @shellNavTrips.
  ///
  /// In en, this message translates to:
  /// **'Trips'**
  String get shellNavTrips;

  /// No description provided for @healthMetricsErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load metrics'**
  String get healthMetricsErrorTitle;

  /// No description provided for @healthHealthErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load health'**
  String get healthHealthErrorTitle;

  /// No description provided for @healthProcessSection.
  ///
  /// In en, this message translates to:
  /// **'Process'**
  String get healthProcessSection;

  /// No description provided for @healthRoutesSection.
  ///
  /// In en, this message translates to:
  /// **'Routes'**
  String get healthRoutesSection;

  /// No description provided for @healthProcessUptime.
  ///
  /// In en, this message translates to:
  /// **'Process uptime'**
  String get healthProcessUptime;

  /// No description provided for @healthRequests.
  ///
  /// In en, this message translates to:
  /// **'Requests'**
  String get healthRequests;

  /// No description provided for @healthErrorRate.
  ///
  /// In en, this message translates to:
  /// **'Error rate'**
  String get healthErrorRate;

  /// No description provided for @healthGoroutines.
  ///
  /// In en, this message translates to:
  /// **'Goroutines'**
  String get healthGoroutines;

  /// No description provided for @healthMemory.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get healthMemory;

  /// No description provided for @healthPlacesCalls.
  ///
  /// In en, this message translates to:
  /// **'Places calls'**
  String get healthPlacesCalls;

  /// No description provided for @healthCacheHits.
  ///
  /// In en, this message translates to:
  /// **'{count} cache hits'**
  String healthCacheHits(int count);

  /// No description provided for @healthColRoute.
  ///
  /// In en, this message translates to:
  /// **'Route'**
  String get healthColRoute;

  /// No description provided for @healthColMethod.
  ///
  /// In en, this message translates to:
  /// **'Method'**
  String get healthColMethod;

  /// No description provided for @healthColCount.
  ///
  /// In en, this message translates to:
  /// **'Count'**
  String get healthColCount;

  /// No description provided for @healthColErrorPct.
  ///
  /// In en, this message translates to:
  /// **'Error %'**
  String get healthColErrorPct;

  /// No description provided for @healthDependenciesSection.
  ///
  /// In en, this message translates to:
  /// **'Dependencies'**
  String get healthDependenciesSection;

  /// No description provided for @healthDatabase.
  ///
  /// In en, this message translates to:
  /// **'Database'**
  String get healthDatabase;

  /// No description provided for @healthPing.
  ///
  /// In en, this message translates to:
  /// **'{ms} ms ping'**
  String healthPing(int ms);

  /// No description provided for @healthPillOk.
  ///
  /// In en, this message translates to:
  /// **'ok'**
  String get healthPillOk;

  /// No description provided for @healthPillUnreachable.
  ///
  /// In en, this message translates to:
  /// **'unreachable'**
  String get healthPillUnreachable;

  /// No description provided for @healthPillConfigured.
  ///
  /// In en, this message translates to:
  /// **'configured'**
  String get healthPillConfigured;

  /// No description provided for @healthPillNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'not configured'**
  String get healthPillNotConfigured;

  /// No description provided for @healthPillUnknown.
  ///
  /// In en, this message translates to:
  /// **'unknown'**
  String get healthPillUnknown;

  /// No description provided for @healthPillStale.
  ///
  /// In en, this message translates to:
  /// **'stale'**
  String get healthPillStale;

  /// No description provided for @healthPillFresh.
  ///
  /// In en, this message translates to:
  /// **'fresh'**
  String get healthPillFresh;

  /// No description provided for @healthBackupsSection.
  ///
  /// In en, this message translates to:
  /// **'Backups'**
  String get healthBackupsSection;

  /// No description provided for @healthLastBackup.
  ///
  /// In en, this message translates to:
  /// **'Last backup'**
  String get healthLastBackup;

  /// No description provided for @healthBackupAge.
  ///
  /// In en, this message translates to:
  /// **'{age} ago'**
  String healthBackupAge(String age);

  /// No description provided for @healthNoBackupRecorded.
  ///
  /// In en, this message translates to:
  /// **'no backup recorded'**
  String get healthNoBackupRecorded;

  /// No description provided for @healthBuildSection.
  ///
  /// In en, this message translates to:
  /// **'Build'**
  String get healthBuildSection;

  /// No description provided for @healthRelease.
  ///
  /// In en, this message translates to:
  /// **'release {release}'**
  String healthRelease(String release);

  /// No description provided for @healthDegradedTitle.
  ///
  /// In en, this message translates to:
  /// **'System degraded'**
  String get healthDegradedTitle;

  /// No description provided for @healthRecoveredTitle.
  ///
  /// In en, this message translates to:
  /// **'System recovered'**
  String get healthRecoveredTitle;

  /// No description provided for @notifOpsOpenHealth.
  ///
  /// In en, this message translates to:
  /// **'View system health'**
  String get notifOpsOpenHealth;

  /// No description provided for @healthUptimeSection.
  ///
  /// In en, this message translates to:
  /// **'Uptime'**
  String get healthUptimeSection;

  /// No description provided for @healthUptimeSelfCheckNote.
  ///
  /// In en, this message translates to:
  /// **'Self-check — cannot see edge or gateway outages'**
  String get healthUptimeSelfCheckNote;

  /// No description provided for @healthUptimeComponentApi.
  ///
  /// In en, this message translates to:
  /// **'API'**
  String get healthUptimeComponentApi;

  /// No description provided for @healthUptimeComponentAi.
  ///
  /// In en, this message translates to:
  /// **'AI provider'**
  String get healthUptimeComponentAi;

  /// No description provided for @healthUptimePillDown.
  ///
  /// In en, this message translates to:
  /// **'down'**
  String get healthUptimePillDown;

  /// No description provided for @healthUptimeDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'{days} days ago'**
  String healthUptimeDaysAgo(int days);

  /// No description provided for @healthUptimeToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get healthUptimeToday;

  /// No description provided for @healthUptimeSummary.
  ///
  /// In en, this message translates to:
  /// **'{pct} % uptime'**
  String healthUptimeSummary(String pct);

  /// No description provided for @healthUptimeSummaryPartial.
  ///
  /// In en, this message translates to:
  /// **'{pct} % uptime · {days} days observed'**
  String healthUptimeSummaryPartial(String pct, int days);

  /// No description provided for @healthUptimeNoHistory.
  ///
  /// In en, this message translates to:
  /// **'No history yet'**
  String get healthUptimeNoHistory;

  /// No description provided for @healthUptimeMonitoringSince.
  ///
  /// In en, this message translates to:
  /// **'Monitoring since {date}'**
  String healthUptimeMonitoringSince(String date);

  /// No description provided for @healthUptimeDayNoData.
  ///
  /// In en, this message translates to:
  /// **'{date} · no data'**
  String healthUptimeDayNoData(String date);

  /// No description provided for @healthUptimeNoIncidents.
  ///
  /// In en, this message translates to:
  /// **'no incidents'**
  String get healthUptimeNoIncidents;

  /// No description provided for @healthUptimeDown.
  ///
  /// In en, this message translates to:
  /// **'{duration} down'**
  String healthUptimeDown(String duration);

  /// No description provided for @healthUptimeReasonDbUnreachable.
  ///
  /// In en, this message translates to:
  /// **'database unreachable'**
  String get healthUptimeReasonDbUnreachable;

  /// No description provided for @healthUptimeReasonProcessDown.
  ///
  /// In en, this message translates to:
  /// **'process down'**
  String get healthUptimeReasonProcessDown;

  /// No description provided for @healthUptimeReasonAiFailing.
  ///
  /// In en, this message translates to:
  /// **'AI provider failing'**
  String get healthUptimeReasonAiFailing;

  /// No description provided for @healthUptimeReasonBackupsStale.
  ///
  /// In en, this message translates to:
  /// **'backups stale'**
  String get healthUptimeReasonBackupsStale;

  /// No description provided for @healthUptimeKeyboardHint.
  ///
  /// In en, this message translates to:
  /// **'Use the left and right arrow keys to inspect a day'**
  String get healthUptimeKeyboardHint;

  /// No description provided for @healthUptimeErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load uptime'**
  String get healthUptimeErrorTitle;

  /// No description provided for @reviewSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Trip health'**
  String get reviewSectionTitle;

  /// No description provided for @reviewHeaderAttention.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Mostly ready — 1 to fix} other{Mostly ready — {count} to fix}}'**
  String reviewHeaderAttention(int count);

  /// No description provided for @reviewHeaderSuggestionsOnly.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{In good shape — 1 suggestion} other{In good shape — {count} suggestions}}'**
  String reviewHeaderSuggestionsOnly(int count);

  /// No description provided for @reviewNeedsAttentionHeader.
  ///
  /// In en, this message translates to:
  /// **'Needs attention'**
  String get reviewNeedsAttentionHeader;

  /// No description provided for @reviewSuggestionsHeader.
  ///
  /// In en, this message translates to:
  /// **'Suggestions'**
  String get reviewSuggestionsHeader;

  /// No description provided for @reviewBadgeAttentionSemantics.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 item needs attention} other{{count} items need attention}}'**
  String reviewBadgeAttentionSemantics(int count);

  /// No description provided for @reviewBadgeSuggestionsSemantics.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 suggestion available} other{{count} suggestions available}}'**
  String reviewBadgeSuggestionsSemantics(int count);

  /// No description provided for @reviewEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Looks good'**
  String get reviewEmptyTitle;

  /// No description provided for @reviewEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'No issues found — your trip is in good shape.'**
  String get reviewEmptyMessage;

  /// No description provided for @reviewSeverityCritical.
  ///
  /// In en, this message translates to:
  /// **'Critical'**
  String get reviewSeverityCritical;

  /// No description provided for @reviewSeverityWarning.
  ///
  /// In en, this message translates to:
  /// **'Warning'**
  String get reviewSeverityWarning;

  /// No description provided for @reviewSeverityInfo.
  ///
  /// In en, this message translates to:
  /// **'Info'**
  String get reviewSeverityInfo;

  /// No description provided for @reviewOfflineSnack.
  ///
  /// In en, this message translates to:
  /// **'You\'re offline — reconnect to run more checks.'**
  String get reviewOfflineSnack;

  /// No description provided for @reviewHoursChecked.
  ///
  /// In en, this message translates to:
  /// **'Opening hours checked'**
  String get reviewHoursChecked;

  /// No description provided for @reviewCheckHours.
  ///
  /// In en, this message translates to:
  /// **'Also check opening hours'**
  String get reviewCheckHours;

  /// No description provided for @reviewHoursCheckFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t check opening hours — try again.'**
  String get reviewHoursCheckFailed;

  /// No description provided for @liveTripEyebrow.
  ///
  /// In en, this message translates to:
  /// **'HAPPENING NOW'**
  String get liveTripEyebrow;

  /// No description provided for @liveTripStatusLive.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get liveTripStatusLive;

  /// No description provided for @liveTripDay.
  ///
  /// In en, this message translates to:
  /// **'Day {day}'**
  String liveTripDay(int day);

  /// No description provided for @liveTripDayOfTotal.
  ///
  /// In en, this message translates to:
  /// **'Day {day} of {total}'**
  String liveTripDayOfTotal(int day, int total);

  /// No description provided for @continueChatsTitle.
  ///
  /// In en, this message translates to:
  /// **'Continue where you left off'**
  String get continueChatsTitle;

  /// No description provided for @continueChatsReopenError.
  ///
  /// In en, this message translates to:
  /// **'Could not reopen that conversation.'**
  String get continueChatsReopenError;

  /// No description provided for @continueChatsDismissError.
  ///
  /// In en, this message translates to:
  /// **'Could not dismiss that conversation.'**
  String get continueChatsDismissError;

  /// No description provided for @continueChatsDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get continueChatsDismiss;

  /// No description provided for @mapNoMappedPlaces.
  ///
  /// In en, this message translates to:
  /// **'No mapped places'**
  String get mapNoMappedPlaces;

  /// No description provided for @mapZoomIn.
  ///
  /// In en, this message translates to:
  /// **'Zoom in'**
  String get mapZoomIn;

  /// No description provided for @mapZoomOut.
  ///
  /// In en, this message translates to:
  /// **'Zoom out'**
  String get mapZoomOut;

  /// No description provided for @mapResetMap.
  ///
  /// In en, this message translates to:
  /// **'Reset map'**
  String get mapResetMap;

  /// Qualifier on a map destination chip when a trip visits the same city more than once and the leg dates cannot tell the visits apart (an undated trip, or two runs collapsed onto one day). Renders after the city name, e.g. 'Fira · Visit 2'. Dated trips show the start date instead.
  ///
  /// In en, this message translates to:
  /// **'Visit {n}'**
  String mapLegVisitNumber(int n);

  /// Tooltip on the map's globe button, which clears a destination focus and returns to the whole-trip overview. Deliberately not named mapReset*: mapResetMap sits next to it and means something else — refit the camera over whatever is already shown.
  ///
  /// In en, this message translates to:
  /// **'Show all places'**
  String get mapShowAllPlaces;

  /// Tooltip on the map pin for the airport a trip departs from, when it differs from the one it returns into
  ///
  /// In en, this message translates to:
  /// **'Departure airport ({code})'**
  String mapDepartureAirport(String code);

  /// Tooltip on the map pin for the airport a trip returns into, when it differs from the one it departs from
  ///
  /// In en, this message translates to:
  /// **'Return airport ({code})'**
  String mapReturnAirport(String code);

  /// No description provided for @mapHomeAirport.
  ///
  /// In en, this message translates to:
  /// **'Home airport ({code})'**
  String mapHomeAirport(String code);

  /// Tooltip on the trip map's home-airport toggle button while the overlay (the flight_takeoff pin and its dashed journey legs) is hidden; tapping shows it. Named map*HomeAirport to sit beside mapHomeAirport, the pin tooltip this button shows and hides — deliberately not mapToggle*: the tooltip states the action, not the mechanism.
  ///
  /// In en, this message translates to:
  /// **'Show home airport'**
  String get mapShowHomeAirport;

  /// Tooltip on the same toggle button while the overlay is shown; tapping hides it, tightening the camera on the destinations instead of the leg home.
  ///
  /// In en, this message translates to:
  /// **'Hide home airport'**
  String get mapHideHomeAirport;

  /// No description provided for @accountMenuTooltip.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get accountMenuTooltip;

  /// No description provided for @accountMenuTravelProfile.
  ///
  /// In en, this message translates to:
  /// **'Travel profile'**
  String get accountMenuTravelProfile;

  /// No description provided for @accountMenuNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get accountMenuNotifications;

  /// No description provided for @accountMenuRetakeQuiz.
  ///
  /// In en, this message translates to:
  /// **'Retake travel quiz'**
  String get accountMenuRetakeQuiz;

  /// No description provided for @accountMenuAccountSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get accountMenuAccountSettings;

  /// No description provided for @accountMenuLocalIntelAdmin.
  ///
  /// In en, this message translates to:
  /// **'Local intel admin'**
  String get accountMenuLocalIntelAdmin;

  /// No description provided for @accountMenuMetrics.
  ///
  /// In en, this message translates to:
  /// **'Metrics'**
  String get accountMenuMetrics;

  /// No description provided for @accountMenuSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get accountMenuSignOut;

  /// No description provided for @nextStepEyebrow.
  ///
  /// In en, this message translates to:
  /// **'Next step'**
  String get nextStepEyebrow;

  /// No description provided for @nextStepProgress.
  ///
  /// In en, this message translates to:
  /// **'{n} of {total}'**
  String nextStepProgress(int n, int total);

  /// No description provided for @nextStepViewAll.
  ///
  /// In en, this message translates to:
  /// **'View all'**
  String get nextStepViewAll;

  /// No description provided for @nextStepSetDatesAction.
  ///
  /// In en, this message translates to:
  /// **'Pick dates'**
  String get nextStepSetDatesAction;

  /// No description provided for @nextStepPlanAction.
  ///
  /// In en, this message translates to:
  /// **'Plan in chat'**
  String get nextStepPlanAction;

  /// No description provided for @nextStepLodgingAction.
  ///
  /// In en, this message translates to:
  /// **'Find lodging'**
  String get nextStepLodgingAction;

  /// No description provided for @nextStepTransportAction.
  ///
  /// In en, this message translates to:
  /// **'Find options'**
  String get nextStepTransportAction;

  /// No description provided for @nextStepScheduleAction.
  ///
  /// In en, this message translates to:
  /// **'Fill the gaps'**
  String get nextStepScheduleAction;

  /// No description provided for @nextStepBookAction.
  ///
  /// In en, this message translates to:
  /// **'Review bookings'**
  String get nextStepBookAction;

  /// No description provided for @nextStepPackingAction.
  ///
  /// In en, this message translates to:
  /// **'Open packing list'**
  String get nextStepPackingAction;

  /// No description provided for @nextStepAllSetDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get nextStepAllSetDismiss;

  /// No description provided for @nextStepViewProgress.
  ///
  /// In en, this message translates to:
  /// **'View all steps'**
  String get nextStepViewProgress;

  /// No description provided for @planProgressTitle.
  ///
  /// In en, this message translates to:
  /// **'Plan progress'**
  String get planProgressTitle;

  /// No description provided for @planProgressHint.
  ///
  /// In en, this message translates to:
  /// **'Steps unlock in order — finish this one and the next opens.'**
  String get planProgressHint;

  /// No description provided for @planProgressStateDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get planProgressStateDone;

  /// No description provided for @planProgressStateCurrent.
  ///
  /// In en, this message translates to:
  /// **'Current step'**
  String get planProgressStateCurrent;

  /// No description provided for @planProgressStateLater.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get planProgressStateLater;

  /// No description provided for @notifTitle.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notifTitle;

  /// No description provided for @notifMoreActions.
  ///
  /// In en, this message translates to:
  /// **'More options'**
  String get notifMoreActions;

  /// No description provided for @notifClearAll.
  ///
  /// In en, this message translates to:
  /// **'Clear all'**
  String get notifClearAll;

  /// No description provided for @notifClearAllTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear all notifications?'**
  String get notifClearAllTitle;

  /// No description provided for @notifClearAllBody.
  ///
  /// In en, this message translates to:
  /// **'This removes every notification, including unread ones. This cannot be undone.'**
  String get notifClearAllBody;

  /// No description provided for @notifClearAllFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not clear notifications: {error}'**
  String notifClearAllFailed(String error);

  /// No description provided for @notifLoadErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load notifications'**
  String get notifLoadErrorTitle;

  /// No description provided for @notifEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No notifications yet'**
  String get notifEmptyTitle;

  /// No description provided for @notifEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Trip reminders and co-planning updates will show up here.'**
  String get notifEmptyMessage;

  /// No description provided for @notifUnreadSemantic.
  ///
  /// In en, this message translates to:
  /// **'Unread'**
  String get notifUnreadSemantic;

  /// No description provided for @notifDownFrom.
  ///
  /// In en, this message translates to:
  /// **'{price}, down from {previous}'**
  String notifDownFrom(String price, String previous);

  /// No description provided for @notifBestInWindow.
  ///
  /// In en, this message translates to:
  /// **'(best in window)'**
  String get notifBestInWindow;

  /// No description provided for @notifGenericFallback.
  ///
  /// In en, this message translates to:
  /// **'Notification'**
  String get notifGenericFallback;

  /// No description provided for @notifSomeTrip.
  ///
  /// In en, this message translates to:
  /// **'a trip'**
  String get notifSomeTrip;

  /// No description provided for @notifSomeone.
  ///
  /// In en, this message translates to:
  /// **'Someone'**
  String get notifSomeone;

  /// No description provided for @notifACollaborator.
  ///
  /// In en, this message translates to:
  /// **'A collaborator'**
  String get notifACollaborator;

  /// No description provided for @notifJoinedTrip.
  ///
  /// In en, this message translates to:
  /// **'{who} joined \"{trip}\"'**
  String notifJoinedTrip(String who, String trip);

  /// No description provided for @notifFollowedTrip.
  ///
  /// In en, this message translates to:
  /// **'{who} is now following \"{trip}\"'**
  String notifFollowedTrip(String who, String trip);

  /// No description provided for @notifEditedTrip.
  ///
  /// In en, this message translates to:
  /// **'{who} edited \"{trip}\"'**
  String notifEditedTrip(String who, String trip);

  /// No description provided for @sharedTitle.
  ///
  /// In en, this message translates to:
  /// **'Shared trip'**
  String get sharedTitle;

  /// No description provided for @sharedUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'This link isn\'t available'**
  String get sharedUnavailableTitle;

  /// No description provided for @sharedInviteUnavailableMessage.
  ///
  /// In en, this message translates to:
  /// **'The invite may have expired, been revoked, or already used.'**
  String get sharedInviteUnavailableMessage;

  /// No description provided for @sharedLinkUnavailableMessage.
  ///
  /// In en, this message translates to:
  /// **'The trip may have been unshared, or the link is incorrect.'**
  String get sharedLinkUnavailableMessage;

  /// No description provided for @sharedPlacesGroup.
  ///
  /// In en, this message translates to:
  /// **'Places'**
  String get sharedPlacesGroup;

  /// No description provided for @sharedSaveCopyError.
  ///
  /// In en, this message translates to:
  /// **'Could not save a copy: {error}'**
  String sharedSaveCopyError(String error);

  /// No description provided for @sharedJoinError.
  ///
  /// In en, this message translates to:
  /// **'Could not join trip: {error}'**
  String sharedJoinError(String error);

  /// No description provided for @sharedBy.
  ///
  /// In en, this message translates to:
  /// **'Shared by {name}'**
  String sharedBy(String name);

  /// No description provided for @sharedNoMappedPlaces.
  ///
  /// In en, this message translates to:
  /// **'No mapped places'**
  String get sharedNoMappedPlaces;

  /// No description provided for @sharedNoPlacesIn.
  ///
  /// In en, this message translates to:
  /// **'No places pinned in {city}'**
  String sharedNoPlacesIn(String city);

  /// No description provided for @sharedEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No places yet'**
  String get sharedEmptyTitle;

  /// No description provided for @sharedEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'This trip doesn\'t have an itinerary yet.'**
  String get sharedEmptyMessage;

  /// No description provided for @sharedDayN.
  ///
  /// In en, this message translates to:
  /// **'Day {day}'**
  String sharedDayN(int day);

  /// No description provided for @sharedStays.
  ///
  /// In en, this message translates to:
  /// **'Stays'**
  String get sharedStays;

  /// No description provided for @sharedJoinCoPlanner.
  ///
  /// In en, this message translates to:
  /// **'Join as co-planner'**
  String get sharedJoinCoPlanner;

  /// No description provided for @sharedSaveSeparateCopy.
  ///
  /// In en, this message translates to:
  /// **'Or save a separate copy'**
  String get sharedSaveSeparateCopy;

  /// No description provided for @sharedKeepInTrips.
  ///
  /// In en, this message translates to:
  /// **'Keep in my trips'**
  String get sharedKeepInTrips;

  /// No description provided for @legalAgreementPrefix.
  ///
  /// In en, this message translates to:
  /// **'By signing up you agree to the '**
  String get legalAgreementPrefix;

  /// No description provided for @legalConsentCheckboxPrefix.
  ///
  /// In en, this message translates to:
  /// **'I agree to the '**
  String get legalConsentCheckboxPrefix;

  /// No description provided for @legalTermsOfService.
  ///
  /// In en, this message translates to:
  /// **'Terms of Service'**
  String get legalTermsOfService;

  /// No description provided for @legalAgreementConjunction.
  ///
  /// In en, this message translates to:
  /// **' and '**
  String get legalAgreementConjunction;

  /// No description provided for @legalPrivacyPolicy.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get legalPrivacyPolicy;

  /// No description provided for @offlineJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get offlineJustNow;

  /// No description provided for @offlineMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 minute ago} other{{count} minutes ago}}'**
  String offlineMinutesAgo(int count);

  /// No description provided for @offlineHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 hour ago} other{{count} hours ago}}'**
  String offlineHoursAgo(int count);

  /// No description provided for @offlineDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 day ago} other{{count} days ago}}'**
  String offlineDaysAgo(int count);

  /// No description provided for @offlineBannerMessage.
  ///
  /// In en, this message translates to:
  /// **'Offline — showing saved copy from {when}'**
  String offlineBannerMessage(String when);

  /// No description provided for @chatInputHint.
  ///
  /// In en, this message translates to:
  /// **'Where do you want to go?'**
  String get chatInputHint;

  /// No description provided for @chatInputHintShort.
  ///
  /// In en, this message translates to:
  /// **'Where to?'**
  String get chatInputHintShort;

  /// No description provided for @chatFollowUpHint.
  ///
  /// In en, this message translates to:
  /// **'Ask a follow-up…'**
  String get chatFollowUpHint;

  /// No description provided for @chatFollowUpHintShort.
  ///
  /// In en, this message translates to:
  /// **'Follow-up…'**
  String get chatFollowUpHintShort;

  /// No description provided for @chatSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get chatSend;

  /// No description provided for @chatStopGenerating.
  ///
  /// In en, this message translates to:
  /// **'Stop generating'**
  String get chatStopGenerating;

  /// No description provided for @chatAttachImages.
  ///
  /// In en, this message translates to:
  /// **'Attach images'**
  String get chatAttachImages;

  /// No description provided for @chatStopDictating.
  ///
  /// In en, this message translates to:
  /// **'Stop dictating'**
  String get chatStopDictating;

  /// No description provided for @chatDictate.
  ///
  /// In en, this message translates to:
  /// **'Dictate'**
  String get chatDictate;

  /// No description provided for @chatDropImages.
  ///
  /// In en, this message translates to:
  /// **'Drop images to attach'**
  String get chatDropImages;

  /// No description provided for @chatRemoveImage.
  ///
  /// In en, this message translates to:
  /// **'Remove image'**
  String get chatRemoveImage;

  /// No description provided for @chatImagePlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get chatImagePlaceholder;

  /// No description provided for @chatStillPreparingImage.
  ///
  /// In en, this message translates to:
  /// **'Still preparing an image — one moment.'**
  String get chatStillPreparingImage;

  /// No description provided for @chatAttachLimit.
  ///
  /// In en, this message translates to:
  /// **'You can attach up to {count} images.'**
  String chatAttachLimit(int count);

  /// No description provided for @chatImageUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t read that image — try a JPEG, PNG, GIF, or WebP under 10 MB.'**
  String get chatImageUnreadable;

  /// No description provided for @chatOnlyImages.
  ///
  /// In en, this message translates to:
  /// **'Only image files can be attached.'**
  String get chatOnlyImages;

  /// No description provided for @chatToolSearchPlaces.
  ///
  /// In en, this message translates to:
  /// **'Searching places...'**
  String get chatToolSearchPlaces;

  /// No description provided for @chatToolCreateItinerary.
  ///
  /// In en, this message translates to:
  /// **'Building itinerary...'**
  String get chatToolCreateItinerary;

  /// No description provided for @chatToolUpdateItinerary.
  ///
  /// In en, this message translates to:
  /// **'Updating itinerary...'**
  String get chatToolUpdateItinerary;

  /// No description provided for @chatToolSearchFlights.
  ///
  /// In en, this message translates to:
  /// **'Searching flights...'**
  String get chatToolSearchFlights;

  /// No description provided for @chatToolCheckConnectivity.
  ///
  /// In en, this message translates to:
  /// **'Checking route connectivity...'**
  String get chatToolCheckConnectivity;

  /// No description provided for @chatToolSearchEvents.
  ///
  /// In en, this message translates to:
  /// **'Finding events...'**
  String get chatToolSearchEvents;

  /// No description provided for @chatToolSuggestFerries.
  ///
  /// In en, this message translates to:
  /// **'Finding ferries...'**
  String get chatToolSuggestFerries;

  /// No description provided for @chatToolLocalRecs.
  ///
  /// In en, this message translates to:
  /// **'Finding local picks...'**
  String get chatToolLocalRecs;

  /// No description provided for @chatToolReviewTrip.
  ///
  /// In en, this message translates to:
  /// **'Reviewing your trip...'**
  String get chatToolReviewTrip;

  /// No description provided for @chatToolWeather.
  ///
  /// In en, this message translates to:
  /// **'Checking weather...'**
  String get chatToolWeather;

  /// No description provided for @chatToolSearchNearby.
  ///
  /// In en, this message translates to:
  /// **'Searching nearby...'**
  String get chatToolSearchNearby;

  /// No description provided for @chatToolWorking.
  ///
  /// In en, this message translates to:
  /// **'Working...'**
  String get chatToolWorking;

  /// No description provided for @chatSummarizing.
  ///
  /// In en, this message translates to:
  /// **'Summarizing earlier conversation…'**
  String get chatSummarizing;

  /// No description provided for @chatProfileUpdatedTooltip.
  ///
  /// In en, this message translates to:
  /// **'Travel profile updated'**
  String get chatProfileUpdatedTooltip;

  /// No description provided for @chatProfileUpdated.
  ///
  /// In en, this message translates to:
  /// **'Noted — travel profile updated'**
  String get chatProfileUpdated;

  /// No description provided for @chatTripUpdated.
  ///
  /// In en, this message translates to:
  /// **'Trip updated'**
  String get chatTripUpdated;

  /// No description provided for @chatChipFlightOptions.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{{count} flight option} other{{count} flight options}}'**
  String chatChipFlightOptions(int count);

  /// No description provided for @chatChipLocalPicks.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{{count} local pick} other{{count} local picks}}'**
  String chatChipLocalPicks(int count);

  /// No description provided for @chatStripPlaces.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{{count} place} other{{count} places}}'**
  String chatStripPlaces(int count);

  /// No description provided for @chatStripParking.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{{count} parking option} other{{count} parking options}}'**
  String chatStripParking(int count);

  /// No description provided for @chatToolFindParking.
  ///
  /// In en, this message translates to:
  /// **'Finding parking...'**
  String get chatToolFindParking;

  /// No description provided for @chatCardFreeListed.
  ///
  /// In en, this message translates to:
  /// **'Free (listed)'**
  String get chatCardFreeListed;

  /// No description provided for @chatStripHotels.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{{count} stay} other{{count} stays}}'**
  String chatStripHotels(int count);

  /// Rail-header caveat when hotel results carry no rates (no dates given, allowance spent, or provider down). Must read as an absence of information, never as 'free'.
  ///
  /// In en, this message translates to:
  /// **'no live prices'**
  String get chatStripHotelsNoRates;

  /// No description provided for @chatCardPerNight.
  ///
  /// In en, this message translates to:
  /// **'{price}/night'**
  String chatCardPerNight(String price);

  /// No description provided for @chatToolSearchHotels.
  ///
  /// In en, this message translates to:
  /// **'Finding stays...'**
  String get chatToolSearchHotels;

  /// No description provided for @chatLinksStays.
  ///
  /// In en, this message translates to:
  /// **'Browse stays'**
  String get chatLinksStays;

  /// No description provided for @chatLinksTransport.
  ///
  /// In en, this message translates to:
  /// **'Browse transport'**
  String get chatLinksTransport;

  /// No description provided for @chatChipEvents.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{{count} event} other{{count} events}}'**
  String chatChipEvents(int count);

  /// No description provided for @chatChipFerryOptions.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{{count} ferry option} other{{count} ferry options}}'**
  String chatChipFerryOptions(int count);

  /// No description provided for @chatChipEventSources.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{{count} event source} other{{count} event sources}}'**
  String chatChipEventSources(int count);

  /// No description provided for @chatTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get chatTryAgain;

  /// No description provided for @chatQueued.
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get chatQueued;

  /// No description provided for @chatRemoveQueued.
  ///
  /// In en, this message translates to:
  /// **'Remove queued message'**
  String get chatRemoveQueued;

  /// No description provided for @agentScreenTitle.
  ///
  /// In en, this message translates to:
  /// **'Plan your trip'**
  String get agentScreenTitle;

  /// No description provided for @agentScreenStartOver.
  ///
  /// In en, this message translates to:
  /// **'Start over'**
  String get agentScreenStartOver;

  /// No description provided for @agentScreenEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Tell me about your dream trip'**
  String get agentScreenEmptyTitle;

  /// No description provided for @agentScreenEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'I\'ll search real places and build you a day-by-day itinerary.'**
  String get agentScreenEmptyMessage;

  /// No description provided for @agentScreenItineraryReady.
  ///
  /// In en, this message translates to:
  /// **'Itinerary ready — {count} locations'**
  String agentScreenItineraryReady(int count);

  /// No description provided for @agentScreenViewTrip.
  ///
  /// In en, this message translates to:
  /// **'View trip'**
  String get agentScreenViewTrip;

  /// No description provided for @agentScreenSignInToSave.
  ///
  /// In en, this message translates to:
  /// **'Sign in to save your trips'**
  String get agentScreenSignInToSave;

  /// No description provided for @resultChipViewInTrip.
  ///
  /// In en, this message translates to:
  /// **'View in trip'**
  String get resultChipViewInTrip;

  /// No description provided for @refineTargetDay.
  ///
  /// In en, this message translates to:
  /// **'Day {day}'**
  String refineTargetDay(int day);

  /// No description provided for @refineTargetDayCity.
  ///
  /// In en, this message translates to:
  /// **'Day {day} — {city}'**
  String refineTargetDayCity(int day, String city);

  /// No description provided for @refineTargetWholeTrip.
  ///
  /// In en, this message translates to:
  /// **'Whole trip'**
  String get refineTargetWholeTrip;

  /// No description provided for @refineAssistantTitle.
  ///
  /// In en, this message translates to:
  /// **'Trip assistant'**
  String get refineAssistantTitle;

  /// No description provided for @refineHeader.
  ///
  /// In en, this message translates to:
  /// **'Refining · {target}'**
  String refineHeader(String target);

  /// No description provided for @refineAssistantHint.
  ///
  /// In en, this message translates to:
  /// **'Ask anything about this trip…'**
  String get refineAssistantHint;

  /// No description provided for @refineAssistantHintShort.
  ///
  /// In en, this message translates to:
  /// **'Ask about this trip…'**
  String get refineAssistantHintShort;

  /// No description provided for @refineHint.
  ///
  /// In en, this message translates to:
  /// **'Ask for changes...'**
  String get refineHint;

  /// No description provided for @refineNewChat.
  ///
  /// In en, this message translates to:
  /// **'New chat'**
  String get refineNewChat;

  /// No description provided for @refineClearChat.
  ///
  /// In en, this message translates to:
  /// **'Clear chat'**
  String get refineClearChat;

  /// No description provided for @refineClearChatConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear this conversation?'**
  String get refineClearChatConfirmTitle;

  /// No description provided for @refineClearChatConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'The chat will be deleted. Your trip and its plan aren\'t affected.'**
  String get refineClearChatConfirmBody;

  /// No description provided for @refineResumeLoading.
  ///
  /// In en, this message translates to:
  /// **'Restoring your conversation…'**
  String get refineResumeLoading;

  /// No description provided for @refineResumeGone.
  ///
  /// In en, this message translates to:
  /// **'This conversation has expired.'**
  String get refineResumeGone;

  /// No description provided for @refineResumeGoneDetail.
  ///
  /// In en, this message translates to:
  /// **'It was cleared or removed with its trip. You can start a new one.'**
  String get refineResumeGoneDetail;

  /// No description provided for @refineResumeFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reopen this conversation.'**
  String get refineResumeFailed;

  /// No description provided for @tripContinueChat.
  ///
  /// In en, this message translates to:
  /// **'Continue chat'**
  String get tripContinueChat;

  /// No description provided for @tripContinueChatMeta.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 message} other{{count} messages}} · {age}'**
  String tripContinueChatMeta(int count, String age);

  /// No description provided for @chatDictationPermission.
  ///
  /// In en, this message translates to:
  /// **'Microphone access was blocked. Check your browser settings.'**
  String get chatDictationPermission;

  /// No description provided for @chatDictationUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Voice input isn\'t available in this browser.'**
  String get chatDictationUnsupported;

  /// No description provided for @chatDictationUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Voice input isn\'t available right now.'**
  String get chatDictationUnavailable;

  /// No description provided for @chatDictationFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t transcribe audio. You can type instead.'**
  String get chatDictationFailed;

  /// No description provided for @placeSearchAddTitle.
  ///
  /// In en, this message translates to:
  /// **'Add Location'**
  String get placeSearchAddTitle;

  /// No description provided for @placeSearchEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Location'**
  String get placeSearchEditTitle;

  /// No description provided for @placeSearchManualCoords.
  ///
  /// In en, this message translates to:
  /// **'Use Manual Coordinates'**
  String get placeSearchManualCoords;

  /// No description provided for @placeSearchManualCoordsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enter latitude/longitude manually instead of searching places'**
  String get placeSearchManualCoordsSubtitle;

  /// No description provided for @placeSearchNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Location Name *'**
  String get placeSearchNameLabel;

  /// No description provided for @placeSearchNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Location name is required'**
  String get placeSearchNameRequired;

  /// No description provided for @placeSearchCategoryLabel.
  ///
  /// In en, this message translates to:
  /// **'Category (optional)'**
  String get placeSearchCategoryLabel;

  /// No description provided for @placeSearchCategoryHint.
  ///
  /// In en, this message translates to:
  /// **'e.g., restaurant, museum, coffee_shop'**
  String get placeSearchCategoryHint;

  /// No description provided for @placeSearchVisitDurationLabel.
  ///
  /// In en, this message translates to:
  /// **'Visit Duration (minutes, optional)'**
  String get placeSearchVisitDurationLabel;

  /// No description provided for @placeSearchDurationInvalid.
  ///
  /// In en, this message translates to:
  /// **'Please enter a valid duration in minutes'**
  String get placeSearchDurationInvalid;

  /// No description provided for @placeSearchSearchLabel.
  ///
  /// In en, this message translates to:
  /// **'Search for a place'**
  String get placeSearchSearchLabel;

  /// No description provided for @placeSearchSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Type to search for restaurants, attractions, etc.'**
  String get placeSearchSearchHint;

  /// No description provided for @placeSearchLatitude.
  ///
  /// In en, this message translates to:
  /// **'Latitude'**
  String get placeSearchLatitude;

  /// No description provided for @placeSearchLongitude.
  ///
  /// In en, this message translates to:
  /// **'Longitude'**
  String get placeSearchLongitude;

  /// No description provided for @placeSearchLatitudeRequired.
  ///
  /// In en, this message translates to:
  /// **'Latitude *'**
  String get placeSearchLatitudeRequired;

  /// No description provided for @placeSearchLongitudeRequired.
  ///
  /// In en, this message translates to:
  /// **'Longitude *'**
  String get placeSearchLongitudeRequired;

  /// No description provided for @placeSearchLatitudeRequiredError.
  ///
  /// In en, this message translates to:
  /// **'Latitude is required'**
  String get placeSearchLatitudeRequiredError;

  /// No description provided for @placeSearchLongitudeRequiredError.
  ///
  /// In en, this message translates to:
  /// **'Longitude is required'**
  String get placeSearchLongitudeRequiredError;

  /// No description provided for @placeSearchLatitudeInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter valid latitude (-90 to 90)'**
  String get placeSearchLatitudeInvalid;

  /// No description provided for @placeSearchLongitudeInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter valid longitude (-180 to 180)'**
  String get placeSearchLongitudeInvalid;

  /// No description provided for @placeSearchNoResults.
  ///
  /// In en, this message translates to:
  /// **'No places found. Try a different search term.'**
  String get placeSearchNoResults;

  /// No description provided for @placeSearchError.
  ///
  /// In en, this message translates to:
  /// **'Error: {error}'**
  String placeSearchError(String error);

  /// No description provided for @addToTripAddedTo.
  ///
  /// In en, this message translates to:
  /// **'Added to {title}'**
  String addToTripAddedTo(String title);

  /// No description provided for @addToTripViewTrip.
  ///
  /// In en, this message translates to:
  /// **'View trip'**
  String get addToTripViewTrip;

  /// No description provided for @addToTripTitle.
  ///
  /// In en, this message translates to:
  /// **'Add to trip'**
  String get addToTripTitle;

  /// No description provided for @addToTripDuplicate.
  ///
  /// In en, this message translates to:
  /// **'Already on this trip.'**
  String get addToTripDuplicate;

  /// No description provided for @addToTripAddAnyway.
  ///
  /// In en, this message translates to:
  /// **'Add anyway'**
  String get addToTripAddAnyway;

  /// No description provided for @addToTripLoadTripError.
  ///
  /// In en, this message translates to:
  /// **'Could not load that trip: {error}'**
  String addToTripLoadTripError(String error);

  /// No description provided for @addToTripAddPlaceError.
  ///
  /// In en, this message translates to:
  /// **'Could not add the place: {error}'**
  String addToTripAddPlaceError(String error);

  /// No description provided for @addToTripLoadTripsError.
  ///
  /// In en, this message translates to:
  /// **'Could not load your trips.'**
  String get addToTripLoadTripsError;

  /// No description provided for @addToTripNoTrips.
  ///
  /// In en, this message translates to:
  /// **'No trips yet — plan a trip first, then add places to it.'**
  String get addToTripNoTrips;

  /// No description provided for @addToTripUnscheduled.
  ///
  /// In en, this message translates to:
  /// **'Unscheduled'**
  String get addToTripUnscheduled;

  /// No description provided for @addToTripDay.
  ///
  /// In en, this message translates to:
  /// **'Day {day}'**
  String addToTripDay(int day);

  /// No description provided for @flightSearchTitle.
  ///
  /// In en, this message translates to:
  /// **'Find Flights'**
  String get flightSearchTitle;

  /// No description provided for @flightSearchFrom.
  ///
  /// In en, this message translates to:
  /// **'From'**
  String get flightSearchFrom;

  /// No description provided for @flightSearchTo.
  ///
  /// In en, this message translates to:
  /// **'To'**
  String get flightSearchTo;

  /// No description provided for @flightSearchDepartDate.
  ///
  /// In en, this message translates to:
  /// **'Departure date'**
  String get flightSearchDepartDate;

  /// No description provided for @flightSearchReturnOptional.
  ///
  /// In en, this message translates to:
  /// **'Return (optional)'**
  String get flightSearchReturnOptional;

  /// No description provided for @flightSearchClearReturnTooltip.
  ///
  /// In en, this message translates to:
  /// **'Clear return date'**
  String get flightSearchClearReturnTooltip;

  /// No description provided for @flightSearchCabinEconomy.
  ///
  /// In en, this message translates to:
  /// **'Economy'**
  String get flightSearchCabinEconomy;

  /// No description provided for @flightSearchCabinPremiumEconomy.
  ///
  /// In en, this message translates to:
  /// **'Premium economy'**
  String get flightSearchCabinPremiumEconomy;

  /// No description provided for @flightSearchCabinBusiness.
  ///
  /// In en, this message translates to:
  /// **'Business'**
  String get flightSearchCabinBusiness;

  /// No description provided for @flightSearchCabinFirst.
  ///
  /// In en, this message translates to:
  /// **'First'**
  String get flightSearchCabinFirst;

  /// No description provided for @flightSearchBaggagePersonalItem.
  ///
  /// In en, this message translates to:
  /// **'Personal item'**
  String get flightSearchBaggagePersonalItem;

  /// No description provided for @flightSearchBaggageCarryOn.
  ///
  /// In en, this message translates to:
  /// **'Carry-on'**
  String get flightSearchBaggageCarryOn;

  /// No description provided for @flightSearchBaggageChecked.
  ///
  /// In en, this message translates to:
  /// **'Checked bag'**
  String get flightSearchBaggageChecked;

  /// No description provided for @flightSearchPresetCheapest.
  ///
  /// In en, this message translates to:
  /// **'Cheapest'**
  String get flightSearchPresetCheapest;

  /// No description provided for @flightSearchPresetFastest.
  ///
  /// In en, this message translates to:
  /// **'Fastest'**
  String get flightSearchPresetFastest;

  /// No description provided for @flightSearchPresetBalanced.
  ///
  /// In en, this message translates to:
  /// **'Balanced'**
  String get flightSearchPresetBalanced;

  /// No description provided for @flightSearchSearching.
  ///
  /// In en, this message translates to:
  /// **'Searching…'**
  String get flightSearchSearching;

  /// No description provided for @flightSearchSubmit.
  ///
  /// In en, this message translates to:
  /// **'Search Flights'**
  String get flightSearchSubmit;

  /// No description provided for @flightSearchErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load flights'**
  String get flightSearchErrorTitle;

  /// No description provided for @flightSearchHintInitial.
  ///
  /// In en, this message translates to:
  /// **'Choose an origin, destination, and date to find flights.'**
  String get flightSearchHintInitial;

  /// No description provided for @flightSearchHintEmpty.
  ///
  /// In en, this message translates to:
  /// **'No flights found for this route and date.'**
  String get flightSearchHintEmpty;

  /// No description provided for @flightSearchHintInitialTitle.
  ///
  /// In en, this message translates to:
  /// **'Find your flight'**
  String get flightSearchHintInitialTitle;

  /// No description provided for @flightSearchNoResultsTitle.
  ///
  /// In en, this message translates to:
  /// **'No flights found'**
  String get flightSearchNoResultsTitle;

  /// No description provided for @flightSearchFormTitle.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get flightSearchFormTitle;

  /// No description provided for @flightSearchEditSearch.
  ///
  /// In en, this message translates to:
  /// **'Edit search'**
  String get flightSearchEditSearch;

  /// Passenger-count fragment of the collapsed search summary, e.g. "JFK → CDG · Sep 1 · 2 travelers · Business"
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 traveler} other{{count} travelers}}'**
  String flightSearchSummaryTravelers(int count);

  /// No description provided for @flightSearchCabinLabel.
  ///
  /// In en, this message translates to:
  /// **'Cabin'**
  String get flightSearchCabinLabel;

  /// No description provided for @flightSearchBaggageLabel.
  ///
  /// In en, this message translates to:
  /// **'Baggage'**
  String get flightSearchBaggageLabel;

  /// Shown above results when the provider could price the cabin bag but not the checked bag (baggage_note code checked_not_priced).
  ///
  /// In en, this message translates to:
  /// **'These prices include a carry-on fee but not a checked-bag fee — check that one with the airline.'**
  String get flightSearchCheckedNotPriced;

  /// No description provided for @flightSearchOptimizeLabel.
  ///
  /// In en, this message translates to:
  /// **'Rank results by'**
  String get flightSearchOptimizeLabel;

  /// No description provided for @flightSearchAdults.
  ///
  /// In en, this message translates to:
  /// **'Adults'**
  String get flightSearchAdults;

  /// No description provided for @flightSearchChildren.
  ///
  /// In en, this message translates to:
  /// **'Children'**
  String get flightSearchChildren;

  /// No description provided for @flightSearchAddAdult.
  ///
  /// In en, this message translates to:
  /// **'Add adult'**
  String get flightSearchAddAdult;

  /// No description provided for @flightSearchRemoveAdult.
  ///
  /// In en, this message translates to:
  /// **'Remove adult'**
  String get flightSearchRemoveAdult;

  /// No description provided for @flightSearchAddChild.
  ///
  /// In en, this message translates to:
  /// **'Add child'**
  String get flightSearchAddChild;

  /// No description provided for @flightSearchRemoveChild.
  ///
  /// In en, this message translates to:
  /// **'Remove child'**
  String get flightSearchRemoveChild;

  /// Label on each child-age picker, e.g. "Child 1"
  ///
  /// In en, this message translates to:
  /// **'Child {n}'**
  String flightSearchChildN(int n);

  /// No description provided for @flightSearchResultsCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 flight found} other{{count} flights found}}'**
  String flightSearchResultsCount(int count);

  /// No description provided for @flightCardSavings.
  ///
  /// In en, this message translates to:
  /// **'Saves {amount} vs next option'**
  String flightCardSavings(String amount);

  /// No description provided for @flightCardBagIncluded.
  ///
  /// In en, this message translates to:
  /// **'Bag included'**
  String get flightCardBagIncluded;

  /// No description provided for @flightCardBagPaid.
  ///
  /// In en, this message translates to:
  /// **'incl. bag +{fee}'**
  String flightCardBagPaid(String fee);

  /// Badge under a fare whose provider quoted a bag-inclusive price without itemizing the fee.
  ///
  /// In en, this message translates to:
  /// **'bag fee included'**
  String get flightCardBagInPrice;

  /// No description provided for @flightCardBagUnknown.
  ///
  /// In en, this message translates to:
  /// **'Bag fee unknown'**
  String get flightCardBagUnknown;

  /// No description provided for @flightCardOpenLinkError.
  ///
  /// In en, this message translates to:
  /// **'Could not open link'**
  String get flightCardOpenLinkError;

  /// No description provided for @flightCardBestMatch.
  ///
  /// In en, this message translates to:
  /// **'BEST MATCH'**
  String get flightCardBestMatch;

  /// No description provided for @flightCardFlight.
  ///
  /// In en, this message translates to:
  /// **'Flight'**
  String get flightCardFlight;

  /// No description provided for @flightCardScore.
  ///
  /// In en, this message translates to:
  /// **'score {score}'**
  String flightCardScore(String score);

  /// No description provided for @flightCardBook.
  ///
  /// In en, this message translates to:
  /// **'Book'**
  String get flightCardBook;

  /// No description provided for @flightSheetOutbound.
  ///
  /// In en, this message translates to:
  /// **'Outbound'**
  String get flightSheetOutbound;

  /// No description provided for @flightSheetReturn.
  ///
  /// In en, this message translates to:
  /// **'Return'**
  String get flightSheetReturn;

  /// No description provided for @flightSheetRoundTrip.
  ///
  /// In en, this message translates to:
  /// **'Round trip'**
  String get flightSheetRoundTrip;

  /// No description provided for @flightSheetBookThisFlight.
  ///
  /// In en, this message translates to:
  /// **'Book this flight'**
  String get flightSheetBookThisFlight;

  /// No description provided for @flightSheetBookWith.
  ///
  /// In en, this message translates to:
  /// **'Book with {airline}'**
  String flightSheetBookWith(String airline);

  /// No description provided for @flightSheetBagPersonalItem.
  ///
  /// In en, this message translates to:
  /// **'Personal item'**
  String get flightSheetBagPersonalItem;

  /// No description provided for @flightSheetBagCarryOnCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{carry-on} other{{count} carry-ons}}'**
  String flightSheetBagCarryOnCount(int count);

  /// No description provided for @flightSheetBagCheckedCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{checked bag} other{{count} checked bags}}'**
  String flightSheetBagCheckedCount(int count);

  /// No description provided for @flightSheetIncluded.
  ///
  /// In en, this message translates to:
  /// **'Included: {list}'**
  String flightSheetIncluded(String list);

  /// No description provided for @flightSheetBagFeeNote.
  ///
  /// In en, this message translates to:
  /// **'+{fee} bag fee included in price'**
  String flightSheetBagFeeNote(String fee);

  /// No description provided for @flightSheetBagInPriceNote.
  ///
  /// In en, this message translates to:
  /// **'Bag fee already included in this price'**
  String get flightSheetBagInPriceNote;

  /// No description provided for @flightSheetBagUnknownNote.
  ///
  /// In en, this message translates to:
  /// **'Your bag is not included — check the fee with the airline'**
  String get flightSheetBagUnknownNote;

  /// No description provided for @flightSheetLayover.
  ///
  /// In en, this message translates to:
  /// **'Layover {airport}'**
  String flightSheetLayover(String airport);

  /// No description provided for @flightSheetLayoverWithDuration.
  ///
  /// In en, this message translates to:
  /// **'Layover {airport} · {duration}'**
  String flightSheetLayoverWithDuration(String airport, String duration);

  /// No description provided for @airportFieldHint.
  ///
  /// In en, this message translates to:
  /// **'City or airport'**
  String get airportFieldHint;

  /// No description provided for @airportFieldClearTooltip.
  ///
  /// In en, this message translates to:
  /// **'Clear selection'**
  String get airportFieldClearTooltip;

  /// No description provided for @airportFieldNoMatches.
  ///
  /// In en, this message translates to:
  /// **'No matching airports'**
  String get airportFieldNoMatches;

  /// No description provided for @guidesTitle.
  ///
  /// In en, this message translates to:
  /// **'Local guides'**
  String get guidesTitle;

  /// No description provided for @guidesErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load guides'**
  String get guidesErrorTitle;

  /// No description provided for @guidesErrorMessage.
  ///
  /// In en, this message translates to:
  /// **'Check your connection and try again.'**
  String get guidesErrorMessage;

  /// No description provided for @guidesEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No guides yet'**
  String get guidesEmptyTitle;

  /// No description provided for @guidesEmptyMessage.
  ///
  /// In en, this message translates to:
  /// **'Guides from real locals appear here as they publish.'**
  String get guidesEmptyMessage;

  /// No description provided for @guidesElsewhere.
  ///
  /// In en, this message translates to:
  /// **'Elsewhere'**
  String get guidesElsewhere;

  /// No description provided for @guidesByline.
  ///
  /// In en, this message translates to:
  /// **'by {name}'**
  String guidesByline(String name);

  /// No description provided for @guideDetailTitle.
  ///
  /// In en, this message translates to:
  /// **'Local guide'**
  String get guideDetailTitle;

  /// No description provided for @guideDetailErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not load this guide'**
  String get guideDetailErrorTitle;

  /// No description provided for @guideDetailErrorMessage.
  ///
  /// In en, this message translates to:
  /// **'Check your connection and try again.'**
  String get guideDetailErrorMessage;

  /// No description provided for @guideDetailByline.
  ///
  /// In en, this message translates to:
  /// **'By {name}'**
  String guideDetailByline(String name);

  /// No description provided for @guideDetailPlacesTitle.
  ///
  /// In en, this message translates to:
  /// **'Places in this guide'**
  String get guideDetailPlacesTitle;

  /// No description provided for @guideDetailNoPinsTitle.
  ///
  /// In en, this message translates to:
  /// **'No places pinned yet'**
  String get guideDetailNoPinsTitle;

  /// No description provided for @guideDetailNoPinsMessage.
  ///
  /// In en, this message translates to:
  /// **'This guide is all narrative for now.'**
  String get guideDetailNoPinsMessage;

  /// No description provided for @appMapCredits.
  ///
  /// In en, this message translates to:
  /// **'Map credits'**
  String get appMapCredits;

  /// No description provided for @flightStops.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Nonstop} =1{1 stop} other{{count} stops}}'**
  String flightStops(int count);

  /// No description provided for @flightStopsEachWay.
  ///
  /// In en, this message translates to:
  /// **'{stops} each way'**
  String flightStopsEachWay(String stops);

  /// No description provided for @flightStopsSplit.
  ///
  /// In en, this message translates to:
  /// **'{outbound} / {inbound}'**
  String flightStopsSplit(String outbound, String inbound);

  /// Calendar event title for a stay. MUST stay byte-identical to the Go .ics export's ics.stayTitle — the Google link and the downloaded .ics are the same event.
  ///
  /// In en, this message translates to:
  /// **'Stay: {name}'**
  String calendarStayTitle(String name);

  /// Calendar event title for a transport segment. Mirrors the Go .ics export's ics.segmentTitle.
  ///
  /// In en, this message translates to:
  /// **'{mode}: {route}'**
  String calendarSegmentTitle(String mode, String route);

  /// No description provided for @calendarModeFlight.
  ///
  /// In en, this message translates to:
  /// **'Flight'**
  String get calendarModeFlight;

  /// No description provided for @calendarModeTrain.
  ///
  /// In en, this message translates to:
  /// **'Train'**
  String get calendarModeTrain;

  /// No description provided for @calendarModeBus.
  ///
  /// In en, this message translates to:
  /// **'Bus'**
  String get calendarModeBus;

  /// No description provided for @calendarModeCar.
  ///
  /// In en, this message translates to:
  /// **'Car'**
  String get calendarModeCar;

  /// No description provided for @calendarModeFerry.
  ///
  /// In en, this message translates to:
  /// **'Ferry'**
  String get calendarModeFerry;

  /// No description provided for @calendarModeOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get calendarModeOther;

  /// No description provided for @errorNetwork.
  ///
  /// In en, this message translates to:
  /// **'Check your internet connection and try again.'**
  String get errorNetwork;

  /// No description provided for @errorTooManyRequests.
  ///
  /// In en, this message translates to:
  /// **'You\'re going a little too fast — wait a moment and try again.'**
  String get errorTooManyRequests;

  /// No description provided for @errorSession.
  ///
  /// In en, this message translates to:
  /// **'Your session has expired. Please sign in again.'**
  String get errorSession;

  /// No description provided for @errorServer.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong on our end. Please try again in a moment.'**
  String get errorServer;

  /// No description provided for @errorGeneric.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Please try again.'**
  String get errorGeneric;

  /// No description provided for @nearMeChipLabel.
  ///
  /// In en, this message translates to:
  /// **'What\'s near me?'**
  String get nearMeChipLabel;

  /// No description provided for @nearMeSeedLabel.
  ///
  /// In en, this message translates to:
  /// **'Near my current location'**
  String get nearMeSeedLabel;

  /// No description provided for @nearMeSeedMessage.
  ///
  /// In en, this message translates to:
  /// **'My current location is latitude {lat}, longitude {lng} (accuracy about {accuracy} m). What\'s good to see, do, or eat near me right now?'**
  String nearMeSeedMessage(String lat, String lng, String accuracy);

  /// No description provided for @nearMeManualMessage.
  ///
  /// In en, this message translates to:
  /// **'I\'m in {place}. What\'s good to see, do, or eat nearby right now?'**
  String nearMeManualMessage(String place);

  /// No description provided for @nearMeDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Where are you?'**
  String get nearMeDialogTitle;

  /// No description provided for @nearMeDialogMessage.
  ///
  /// In en, this message translates to:
  /// **'We couldn\'t get your location. Type a city or neighborhood instead, or enable location access and try again.'**
  String get nearMeDialogMessage;

  /// No description provided for @nearMeDialogHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Athens, Plaka'**
  String get nearMeDialogHint;

  /// No description provided for @nearMeDialogCta.
  ///
  /// In en, this message translates to:
  /// **'Ask'**
  String get nearMeDialogCta;

  /// No description provided for @wearSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'What to wear & pack'**
  String get wearSectionTitle;

  /// No description provided for @wearBandFreezing.
  ///
  /// In en, this message translates to:
  /// **'Freezing — thermals and an insulated coat'**
  String get wearBandFreezing;

  /// No description provided for @wearBandCold.
  ///
  /// In en, this message translates to:
  /// **'Cold — warm coat, hat, and gloves'**
  String get wearBandCold;

  /// No description provided for @wearBandCool.
  ///
  /// In en, this message translates to:
  /// **'Cool — a jacket and layers'**
  String get wearBandCool;

  /// No description provided for @wearBandMild.
  ///
  /// In en, this message translates to:
  /// **'Mild — light layers'**
  String get wearBandMild;

  /// No description provided for @wearBandWarm.
  ///
  /// In en, this message translates to:
  /// **'Warm — summer clothes, a light evening layer'**
  String get wearBandWarm;

  /// No description provided for @wearBandHot.
  ///
  /// In en, this message translates to:
  /// **'Hot — light fabrics and sun protection'**
  String get wearBandHot;

  /// No description provided for @wearRainLikely.
  ///
  /// In en, this message translates to:
  /// **'rain likely, pack an umbrella'**
  String get wearRainLikely;

  /// No description provided for @wearBigSwing.
  ///
  /// In en, this message translates to:
  /// **'big day–night range, bring layers'**
  String get wearBigSwing;

  /// No description provided for @wearExtremeHeat.
  ///
  /// In en, this message translates to:
  /// **'very hot days, extra sun protection'**
  String get wearExtremeHeat;

  /// No description provided for @wearFreezingNights.
  ///
  /// In en, this message translates to:
  /// **'freezing nights, warm layers'**
  String get wearFreezingNights;

  /// No description provided for @wearSummaryRain.
  ///
  /// In en, this message translates to:
  /// **'rain likely'**
  String get wearSummaryRain;

  /// No description provided for @wearHistoricalFootnote.
  ///
  /// In en, this message translates to:
  /// **'Beyond the 16-day forecast, ranges show typical weather for these dates.'**
  String get wearHistoricalFootnote;

  /// No description provided for @wearPackTitle.
  ///
  /// In en, this message translates to:
  /// **'Pack for this trip'**
  String get wearPackTitle;

  /// No description provided for @wearByCityTitle.
  ///
  /// In en, this message translates to:
  /// **'City by city'**
  String get wearByCityTitle;

  /// No description provided for @wearEveryStop.
  ///
  /// In en, this message translates to:
  /// **'every stop'**
  String get wearEveryStop;

  /// No description provided for @wearPackThermals.
  ///
  /// In en, this message translates to:
  /// **'Thermals'**
  String get wearPackThermals;

  /// No description provided for @wearPackWarmCoat.
  ///
  /// In en, this message translates to:
  /// **'A warm coat, hat, and gloves'**
  String get wearPackWarmCoat;

  /// No description provided for @wearPackJacket.
  ///
  /// In en, this message translates to:
  /// **'A jacket or warm layer'**
  String get wearPackJacket;

  /// No description provided for @wearPackLightLayer.
  ///
  /// In en, this message translates to:
  /// **'A light layer for evenings'**
  String get wearPackLightLayer;

  /// No description provided for @wearPackSummerClothes.
  ///
  /// In en, this message translates to:
  /// **'Summer clothes'**
  String get wearPackSummerClothes;

  /// No description provided for @wearPackRainGear.
  ///
  /// In en, this message translates to:
  /// **'An umbrella or rain jacket'**
  String get wearPackRainGear;

  /// No description provided for @wearPackSunProtection.
  ///
  /// In en, this message translates to:
  /// **'Sun protection'**
  String get wearPackSunProtection;

  /// Caption on the Konami-code easter egg. Not translated — it is a song title.
  ///
  /// In en, this message translates to:
  /// **'Never gonna give you up'**
  String get rickRollCaption;

  /// Hint under the easter-egg caption telling the user how to close it. Deliberately not 'press esc' — the egg has a touch trigger, and a phone has no Escape key. Escape still works; a tap is the instruction that is true on every device.
  ///
  /// In en, this message translates to:
  /// **'tap anywhere to escape'**
  String get rickRollDismissHint;
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
      <String>['en', 'es'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
