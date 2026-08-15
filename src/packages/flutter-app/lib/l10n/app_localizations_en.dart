// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Anemos';

  @override
  String get languageSectionTitle => 'Language';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageSpanish => 'Español';

  @override
  String get languageChangeNote =>
      'Trips and notes you already saved stay in the language they were written in.';

  @override
  String get languageMenuTooltip => 'Change language';

  @override
  String get appearanceLanguageSectionTitle => 'Appearance & language';

  @override
  String get appearanceSectionTitle => 'Appearance';

  @override
  String get appearanceSystem => 'Use device setting';

  @override
  String get appearanceLight => 'Light';

  @override
  String get appearanceDark => 'Dark';

  @override
  String get commonSave => 'Save';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonDelete => 'Delete';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonClose => 'Close';

  @override
  String get commonBack => 'Back';

  @override
  String get commonNext => 'Next';

  @override
  String get commonDone => 'Done';

  @override
  String get commonSeeAll => 'See all';

  @override
  String citiesTwo(String first, String second) {
    return '$first & $second';
  }

  @override
  String citiesMore(String first, String second, int count) {
    return '$first & $second +$count more';
  }

  @override
  String get prefsTitle => 'Travel profile';

  @override
  String get prefsBudget => 'Budget';

  @override
  String get prefsPace => 'Pace';

  @override
  String get prefsInterests => 'Interests';

  @override
  String get prefsAddInterest => 'Add an interest';

  @override
  String get prefsHomeAirport => 'Home airport';

  @override
  String get prefsHomeAirportHelp =>
      'Used as the default origin when planning flights.';

  @override
  String get prefsHomeAirportPickOne =>
      'Pick an airport from the list, or clear the field.';

  @override
  String get prefsProfileNotes => 'Profile notes';

  @override
  String get prefsProfileNotesHelp =>
      'Your AI agent keeps these notes as it learns about you. Edit or clear them anytime.';

  @override
  String get prefsProfileNotesHint =>
      'Nothing noted yet — the agent adds to this as you plan trips.';

  @override
  String get prefsSaved => 'Preferences saved';

  @override
  String get prefsSaveFailed => 'Could not save preferences';

  @override
  String get prefsLoadErrorTitle => 'Could not load your travel profile';

  @override
  String get prefsLoadErrorMessage => 'Check your connection and try again.';

  @override
  String get prefsBudgetLow => 'budget';

  @override
  String get prefsBudgetMid => 'mid';

  @override
  String get prefsBudgetLuxury => 'luxury';

  @override
  String get prefsWorkStyle => 'Work & travel';

  @override
  String get prefsWorkStyleNomad => 'yes — I work as I travel';

  @override
  String get prefsWorkStyleWorkation => 'sometimes';

  @override
  String get prefsWorkStyleLeisure => 'no — trips are time off';

  @override
  String get prefsCompanions => 'Who you travel with';

  @override
  String get prefsFitnessRoutine => 'Working out';

  @override
  String get prefsFitnessRoutineHelp =>
      'Used to pick stays near a gym or a place to run, and to leave you the time.';

  @override
  String get prefsFitnessGym => 'gym access';

  @override
  String get prefsFitnessRunning => 'running routes';

  @override
  String get prefsFitnessBoth => 'both';

  @override
  String get prefsFitnessNone => 'not a factor';

  @override
  String get prefsOutdoorIntensity => 'Outdoor days';

  @override
  String get prefsOutdoorIntensityHelp =>
      'How hard you want hikes and other active outings to be.';

  @override
  String get prefsOutdoorEasy => 'easy — walks and viewpoints';

  @override
  String get prefsOutdoorModerate => 'moderate — half-day hikes';

  @override
  String get prefsOutdoorChallenging => 'challenging — long and steep';

  @override
  String get prefsPaceRelaxed => 'relaxed';

  @override
  String get prefsPaceBalanced => 'balanced';

  @override
  String get prefsPacePacked => 'packed';

  @override
  String get prefsInterestMuseums => 'museums';

  @override
  String get prefsInterestFood => 'food';

  @override
  String get prefsInterestNightlife => 'nightlife';

  @override
  String get prefsInterestNature => 'nature';

  @override
  String get prefsInterestHistory => 'history';

  @override
  String get prefsInterestArt => 'art';

  @override
  String get prefsInterestShopping => 'shopping';

  @override
  String get prefsInterestOutdoors => 'outdoors';

  @override
  String get prefsInterestBeaches => 'beaches';

  @override
  String get prefsInterestArchitecture => 'architecture';

  @override
  String get prefsInterestLiveMusic => 'live music';

  @override
  String get prefsInterestBars => 'bars';

  @override
  String get prefsInterestTheater => 'theater';

  @override
  String get prefsInterestFestivals => 'festivals';

  @override
  String get prefsInterestLocalMarkets => 'local markets';

  @override
  String get prefsInterestStreetFood => 'street food';

  @override
  String get prefsInterestCoffee => 'coffee';

  @override
  String get prefsInterestWine => 'wine';

  @override
  String get prefsInterestCraftBeer => 'craft beer';

  @override
  String get prefsInterestFineDining => 'fine dining';

  @override
  String get prefsInterestHiking => 'hiking';

  @override
  String get prefsInterestWildlife => 'wildlife';

  @override
  String get prefsInterestWaterSports => 'water sports';

  @override
  String get prefsInterestSkiing => 'skiing';

  @override
  String get prefsInterestCycling => 'cycling';

  @override
  String get prefsInterestClimbing => 'climbing';

  @override
  String get prefsInterestNationalParks => 'national parks';

  @override
  String get prefsInterestRoadTrips => 'road trips';

  @override
  String get prefsInterestPhotography => 'photography';

  @override
  String get prefsInterestStreetArt => 'street art';

  @override
  String get prefsInterestWellness => 'wellness';

  @override
  String get prefsInterestSpas => 'spas';

  @override
  String get prefsInterestSportsEvents => 'sports events';

  @override
  String get ssoContinueWithGoogle => 'Continue with Google';

  @override
  String get ssoContinueWithApple => 'Continue with Apple';

  @override
  String get ssoDividerOr => 'or';

  @override
  String get authWelcomeBack => 'Welcome back';

  @override
  String get authCreateAccountTitle => 'Create your account';

  @override
  String get authEmailLabel => 'Email';

  @override
  String get authEmailRequired => 'Email is required';

  @override
  String get authEmailInvalid => 'Enter a valid email';

  @override
  String get authPasswordLabel => 'Password';

  @override
  String get authPasswordRequired => 'Password is required';

  @override
  String get authPasswordTooShort => 'Password must be at least 8 characters';

  @override
  String get authDisplayNameLabel => 'Display name (optional)';

  @override
  String get authSignIn => 'Sign in';

  @override
  String get authCreateAccount => 'Create account';

  @override
  String get authNoAccountPrompt => 'Don\'t have an account? Sign up';

  @override
  String get authHaveAccountPrompt => 'Already have an account? Sign in';

  @override
  String get authForgotPassword => 'Forgot password?';

  @override
  String get authPasswordUpdatedSnack =>
      'Password updated — sign in with your new password';

  @override
  String get authResetDialogTitle => 'Reset your password';

  @override
  String get authResetDialogBody =>
      'We\'ll email you a reset code if this address has an account.';

  @override
  String get authSending => 'Sending…';

  @override
  String get authSendCode => 'Send code';

  @override
  String get authEnterCodeTitle => 'Enter your reset code';

  @override
  String get authEnterCodeBody => 'Check your inbox for the code we just sent.';

  @override
  String get authResetCodeLabel => 'Reset code';

  @override
  String get authNewPasswordLabel => 'New password';

  @override
  String get authCodeRequired => 'Paste the code from the email';

  @override
  String get authSaving => 'Saving…';

  @override
  String get authSetNewPassword => 'Set new password';

  @override
  String get authErrorInvalidCredentials => 'Wrong email or password.';

  @override
  String get authErrorEmailTaken =>
      'That email already has an account — try signing in instead.';

  @override
  String get authErrorBadResetCode =>
      'That code didn\'t match — check it or request a new one.';

  @override
  String get resetAppBarTitle => 'Reset password';

  @override
  String get resetSuccessTitle => 'Password updated';

  @override
  String get resetSuccessBody =>
      'Sign in with your new password. Any other sessions were signed out.';

  @override
  String get resetSignInButton => 'Sign in';

  @override
  String get resetChooseTitle => 'Choose a new password';

  @override
  String get resetNewPasswordLabel => 'New password';

  @override
  String get resetPasswordRequired => 'Password is required';

  @override
  String get resetPasswordTooShort => 'Password must be at least 8 characters';

  @override
  String get resetConfirmLabel => 'Confirm new password';

  @override
  String get resetConfirmRequired => 'Confirm your new password';

  @override
  String get resetPasswordsMismatch => 'Passwords don\'t match';

  @override
  String get resetSetNewPassword => 'Set new password';

  @override
  String get landingSignIn => 'Sign in';

  @override
  String get landingHeroTagline => 'Plan less. Travel more.';

  @override
  String get landingHeroSubtitle =>
      'Your AI travel companion — describe the trip you want and get a full day-by-day itinerary with routes, places, and flights.';

  @override
  String get landingHaveAccount => 'I already have an account';

  @override
  String get landingGetStarted => 'Get started';

  @override
  String get landingFeaturesTitle => 'Everything you need to plan the trip';

  @override
  String get landingFeatureAgentTitle => 'AI Travel Agent';

  @override
  String get landingFeatureAgentDescription =>
      'Describe your dream trip and get a complete itinerary in seconds.';

  @override
  String get landingCopyright => '© 2026 Golden Tempo LLC';

  @override
  String get verifyTitle => 'Verify email';

  @override
  String get verifyChecking => 'Confirming your email…';

  @override
  String get verifySuccessTitle => 'Email verified ✓';

  @override
  String get verifySuccessBody =>
      'You\'re all set — thanks for confirming your address.';

  @override
  String get verifyLinkExpiredTitle => 'Link expired or already used';

  @override
  String get verifyLinkExpiredBody =>
      'Request a new verification email from your account.';

  @override
  String get verifyContinue => 'Continue';

  @override
  String get ssoTitle => 'Signing you in';

  @override
  String get ssoFailedTitle => 'Sign-in didn\'t complete';

  @override
  String get ssoErrorCancelled =>
      'Sign-in was cancelled or failed. Please try again.';

  @override
  String get ssoErrorExpired => 'This sign-in link expired. Please try again.';

  @override
  String get ssoBackToSignIn => 'Back to sign in';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsProfileSection => 'Profile';

  @override
  String get settingsDisplayName => 'Display name';

  @override
  String get settingsSaveName => 'Save name';

  @override
  String get settingsNameUpdated => 'Name updated';

  @override
  String get settingsPasswordSection => 'Password';

  @override
  String get settingsCurrentPassword => 'Current password';

  @override
  String get settingsNewPassword => 'New password (8+ characters)';

  @override
  String get settingsChangePassword => 'Change password';

  @override
  String get settingsPasswordChanged =>
      'Password changed — other devices were signed out';

  @override
  String get settingsSessionsSection => 'Sessions';

  @override
  String get settingsSessionsHelp =>
      'Signs you out on every device, including this one.';

  @override
  String get settingsSignOutEverywhere => 'Sign out everywhere';

  @override
  String get settingsSignOutEverywhereTitle => 'Sign out everywhere?';

  @override
  String get settingsSignOutEverywhereBody =>
      'This signs you out on every device, including this one.';

  @override
  String get settingsEmailPrefsSection => 'Email preferences';

  @override
  String get settingsTripReminders => 'Trip reminders';

  @override
  String get settingsTripRemindersSubtitle =>
      'Nudges about upcoming trips and things left to book.';

  @override
  String get settingsWeeklyIdeas => 'Weekly planning ideas';

  @override
  String get settingsWeeklyIdeasSubtitle =>
      'A weekly email with destination ideas and inspiration.';

  @override
  String get settingsEmailPrefsUpdated => 'Email preferences updated';

  @override
  String get settingsLegalSection => 'Legal';

  @override
  String get settingsPrivacyPolicy => 'Privacy Policy';

  @override
  String get settingsTermsOfService => 'Terms of Service';

  @override
  String get settingsDangerZoneSection => 'Danger zone';

  @override
  String get settingsDeleteAccount => 'Delete account';

  @override
  String get settingsDeleteAccountTitle => 'Delete account?';

  @override
  String get settingsDeleteAccountBody =>
      'This permanently deletes your account, trips and preferences. There is no undo.';

  @override
  String get settingsConfirmPassword => 'Confirm your password';

  @override
  String get settingsDeleteForever => 'Delete forever';

  @override
  String get quizTitle => 'Set up your travel profile';

  @override
  String get quizSkip => 'Skip';

  @override
  String get quizFinish => 'Finish';

  @override
  String get quizStyleTitle => 'What\'s your travel style?';

  @override
  String get quizStyleSubtitle =>
      'Helps the planner match stays and activities to you.';

  @override
  String get quizWorkStyleTitle => 'Do you work while you travel?';

  @override
  String get quizWorkStyleSubtitle =>
      'So the planner can balance wifi-ready stays and work time with exploring.';

  @override
  String get quizInterestsTitle => 'What do you love doing on a trip?';

  @override
  String get quizInterestsSubtitle => 'Pick as many as you like.';

  @override
  String get quizActiveTitle => 'How active are your trips?';

  @override
  String get quizActiveSubtitle =>
      'Both optional — they shape where you stay and how hard the outdoor days get.';

  @override
  String get quizCompanionsTitle => 'Who do you usually travel with?';

  @override
  String get quizCompanionSolo => 'solo';

  @override
  String get quizCompanionPartner => 'partner';

  @override
  String get quizCompanionFriends => 'friends';

  @override
  String get quizCompanionFamily => 'family with kids';

  @override
  String get quizCompanionVaries => 'it varies';

  @override
  String get quizHomeAirportTitle => 'Where do you fly from?';

  @override
  String get quizTripsTitle => 'Any trips you\'re dreaming about?';

  @override
  String get quizTripsSubtitle =>
      'Places, seasons, occasions — the planner will keep them in mind.';

  @override
  String get quizTripsHint =>
      'e.g. Japan for cherry blossom season, a Greek island hop next summer…';

  @override
  String get quizSaveFailed =>
      'Could not save your answers — try again, or skip for now.';

  @override
  String get quizProfileUpdated => 'Travel profile updated';

  @override
  String quizStepOf(int n, int total) {
    return 'Step $n of $total';
  }

  @override
  String get quizLoadErrorTitle => 'Couldn\'t load your travel profile';

  @override
  String get quizLoadErrorBody =>
      'Your saved answers couldn\'t be loaded, so the quiz can\'t start yet. Check your connection and try again.';

  @override
  String get bookingCardEdit => 'Edit';

  @override
  String get bookingCardRemove => 'Remove';

  @override
  String get bookingCardBooked => 'Booked';

  @override
  String bookingCardOpenIn(String provider) {
    return 'Open in $provider';
  }

  @override
  String get bookingCardOpenSearch => 'Open search';

  @override
  String get bookingCardOpenSearchShort => 'Search';

  @override
  String get calendarAddTo => 'Add to calendar';

  @override
  String get calendarGoogle => 'Google Calendar';

  @override
  String get calendarApple => 'Apple Calendar (.ics)';

  @override
  String calendarExportFailed(String error) {
    return 'Could not export the event: $error';
  }

  @override
  String get bookingsAddStay => 'Add stay';

  @override
  String get bookingsAddTransport => 'Add transport';

  @override
  String get bookingsAddBooking => 'Add booking';

  @override
  String get bookingsMenuStay => 'Stay';

  @override
  String get bookingsMenuTransport => 'Transport';

  @override
  String get bookingsMenuOther => 'Other';

  @override
  String get tripOtherBookings => 'Other bookings';

  @override
  String get bookingRowAddDetails => 'Add details…';

  @override
  String get bookingRowOptions => 'Booking options';

  @override
  String get bookingRowModeTooltip => 'Change transport mode';

  @override
  String bookingRowDepartArrive(String depart, String arrive) {
    return '$depart → $arrive';
  }

  @override
  String bookingRowArrivesOn(String date) {
    return 'Arrives $date';
  }

  @override
  String get bookingsOpenListing => 'Open listing';

  @override
  String get bookingsEditStay => 'Edit stay';

  @override
  String get bookingsRemoveStay => 'Remove stay';

  @override
  String get bookingsOpenBooking => 'Open booking';

  @override
  String get bookingsEditTransport => 'Edit transport';

  @override
  String get bookingsRemoveTransport => 'Remove transport';

  @override
  String get bookingsAddAStay => 'Add a stay';

  @override
  String get bookingsStayNameLabel => 'Name *';

  @override
  String get bookingsStayProviderLabel => 'Provider (Airbnb, Booking.com, …)';

  @override
  String get bookingsStayUrlLabel => 'Listing URL';

  @override
  String get bookingsStayAddressLabel => 'Address';

  @override
  String get bookingsCheckInOut => 'Check-in / check-out';

  @override
  String get bookingsPriceNoteLabel => 'Price note (e.g. €120/night)';

  @override
  String get bookingsSegmentFromLabel => 'From *';

  @override
  String get bookingsSegmentToLabel => 'To *';

  @override
  String get bookingsSegmentEndpointsFromTrip => 'Set by the trip.';

  @override
  String get bookingsDepartureDate => 'Departure date';

  @override
  String get bookingsArrivalDate => 'Arrival date (if it lands the next day)';

  @override
  String get bookingsSegmentProviderLabel => 'Provider / carrier';

  @override
  String get bookingsSegmentUrlLabel => 'Booking URL';

  @override
  String get bookingsNotesLabel => 'Notes';

  @override
  String get bookingsModeFlight => 'flight';

  @override
  String get bookingsModeTrain => 'train';

  @override
  String get bookingsModeBus => 'bus';

  @override
  String get bookingsModeCar => 'car';

  @override
  String get bookingsModeFerry => 'ferry';

  @override
  String get bookingsModeOther => 'other';

  @override
  String get budgetTitle => 'Budget';

  @override
  String budgetSummarySpent(String amount) {
    return '$amount spent';
  }

  @override
  String get budgetSummaryNoTarget => 'no target';

  @override
  String get budgetPromptTitle => 'Add to budget?';

  @override
  String get budgetPromptSkip => 'Skip';

  @override
  String budgetPromptAmountLabel(String currency) {
    return 'Amount ($currency)';
  }

  @override
  String budgetPromptAdded(String amount) {
    return '$amount added to Budget';
  }

  @override
  String get budgetPromptLimitReached =>
      'Expense limit reached — remove one in Budget first';

  @override
  String get budgetEmptyTitle => 'No budget yet';

  @override
  String get budgetEmptyMessage =>
      'Set a target above, or add expenses below to track your spending.';

  @override
  String budgetTargetSet(String amount, String currency) {
    return 'Target: $amount ($currency)';
  }

  @override
  String get budgetNoTarget => 'No target set — tracking spend only';

  @override
  String get budgetEditExpenseTitle => 'Edit expense';

  @override
  String get budgetSetTargetTitle => 'Set budget target';

  @override
  String get budgetCategoryLabel => 'Category';

  @override
  String get budgetLabelField => 'Label';

  @override
  String get budgetAmount => 'Amount';

  @override
  String get budgetCurrencyLabel => 'Currency';

  @override
  String get budgetTargetLabel => 'Target';

  @override
  String get budgetTargetHint => 'Leave blank for none';

  @override
  String get budgetTargetHelp =>
      'Leave the target blank to just track spending.';

  @override
  String get budgetExpenseOptions => 'Expense options';

  @override
  String get budgetMenuEdit => 'Edit';

  @override
  String get budgetTotalSpent => 'Total spent';

  @override
  String get budgetRemaining => 'Remaining';

  @override
  String get budgetAddHint => 'Add an expense…';

  @override
  String get budgetAddExpenseTooltip => 'Add expense';

  @override
  String get budgetCategoryFlights => 'Flights';

  @override
  String get budgetCategoryLodging => 'Lodging';

  @override
  String get budgetCategoryFood => 'Food';

  @override
  String get budgetCategoryActivities => 'Activities';

  @override
  String get budgetCategoryTransport => 'Transport';

  @override
  String get budgetCategoryShopping => 'Shopping';

  @override
  String get budgetCategoryGeneral => 'General';

  @override
  String get checklistTitle => 'Packing & prep';

  @override
  String checklistSummary(int checked, int total) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$checked of $total packed',
      zero: 'No items yet',
    );
    return '$_temp0';
  }

  @override
  String get checklistEmptyTitle => 'Nothing packed yet';

  @override
  String get checklistEmptyMessage =>
      'Add items below, or ask the AI assistant to help build your list.';

  @override
  String get checklistEditItemTitle => 'Edit item';

  @override
  String get checklistItemLabel => 'Item';

  @override
  String get checklistItemOptions => 'Item options';

  @override
  String get checklistMenuEdit => 'Edit';

  @override
  String get checklistAddHint => 'Add an item…';

  @override
  String get checklistAddItemTooltip => 'Add item';

  @override
  String get checklistCategoryDocuments => 'Documents';

  @override
  String get checklistCategoryClothing => 'Clothing';

  @override
  String get checklistCategoryElectronics => 'Electronics';

  @override
  String get checklistCategoryHealth => 'Health';

  @override
  String get checklistCategoryGeneral => 'General';

  @override
  String get itemDialogTitle => 'Add place';

  @override
  String get itemDialogSearchLabel => 'Search for a place';

  @override
  String get itemDialogSearchHint => 'e.g. Pastéis de Belém, Lisbon';

  @override
  String get itemDialogPickDifferent => 'Pick a different place';

  @override
  String get itemDialogAddManually => 'Can\'t find it? Add manually';

  @override
  String get itemDialogPlaceNameLabel => 'Place name';

  @override
  String get itemDialogSearchInstead => 'Search places instead';

  @override
  String get itemDialogDayLabel => 'Day';

  @override
  String get itemDialogUnscheduled => 'Unscheduled';

  @override
  String itemDialogDayN(int day) {
    return 'Day $day';
  }

  @override
  String itemDialogNewDay(int day) {
    return 'New day ($day)';
  }

  @override
  String get itemDialogTimeOfDayLabel => 'Time of day';

  @override
  String get itemDialogTimeAny => 'Any';

  @override
  String get itemDialogTimeMorning => 'Morning';

  @override
  String get itemDialogTimeAfternoon => 'Afternoon';

  @override
  String get itemDialogTimeEvening => 'Evening';

  @override
  String get itemDialogCategoryAttraction => 'Attraction';

  @override
  String get itemDialogCategoryRestaurant => 'Restaurant';

  @override
  String get itemDialogAdd => 'Add';

  @override
  String get itemDialogNoResults =>
      'No places found — try a different search, or add the place manually.';

  @override
  String get itemDialogSearchUnavailable =>
      'Search unavailable — add the place manually below.';

  @override
  String get itemDialogErrorEnterName => 'Enter a name for the place.';

  @override
  String get itemDialogErrorPickPlace => 'Pick a place first.';

  @override
  String itemDialogErrorAddFailed(String error) {
    return 'Could not add the place: $error';
  }

  @override
  String get commonOffline => 'You\'re offline — reconnect to make changes.';

  @override
  String get commonGenericError => 'Something went wrong. Try again.';

  @override
  String get tripTitleFallback => 'Trip';

  @override
  String get tripOtherPlaces => 'Other places';

  @override
  String get tripOfflineGuard => 'You\'re offline — reconnect to make changes.';

  @override
  String tripUpdateFailed(String error) {
    return 'Update failed: $error';
  }

  @override
  String tripDeleteFailed(String error) {
    return 'Delete failed: $error';
  }

  @override
  String tripReorderFailed(String error) {
    return 'Could not reorder: $error';
  }

  @override
  String tripLeaveFailed(String error) {
    return 'Could not remove trip: $error';
  }

  @override
  String tripAddStayFailed(String error) {
    return 'Could not add stay: $error';
  }

  @override
  String tripRemoveStayFailed(String error) {
    return 'Could not remove stay: $error';
  }

  @override
  String tripUpdateStayFailed(String error) {
    return 'Could not update stay: $error';
  }

  @override
  String tripAddTransportFailed(String error) {
    return 'Could not add transport: $error';
  }

  @override
  String tripRemoveTransportFailed(String error) {
    return 'Could not remove transport: $error';
  }

  @override
  String tripUpdateTransportFailed(String error) {
    return 'Could not update transport: $error';
  }

  @override
  String tripShareLinkFailed(String error) {
    return 'Could not create share link: $error';
  }

  @override
  String tripPrintExportFailed(String error) {
    return 'Could not open the printable view: $error';
  }

  @override
  String tripCalendarExportFailed(String error) {
    return 'Could not export the calendar: $error';
  }

  @override
  String tripEventExportFailed(String error) {
    return 'Could not export the event: $error';
  }

  @override
  String tripSharingOffFailed(String error) {
    return 'Could not turn off sharing: $error';
  }

  @override
  String tripInviteFailed(String error) {
    return 'Could not create invite: $error';
  }

  @override
  String tripRemoveItemFailed(String name, String error) {
    return 'Could not remove $name: $error';
  }

  @override
  String tripRestoreItemFailed(String name, String error) {
    return 'Could not restore $name: $error';
  }

  @override
  String tripUpdateItemFailed(String name, String error) {
    return 'Could not update $name: $error';
  }

  @override
  String tripMoveItemFailed(String error) {
    return 'Could not move item: $error';
  }

  @override
  String tripUpdateBookingFailed(String error) {
    return 'Could not update booking: $error';
  }

  @override
  String tripUndoFailed(String error) {
    return 'Could not undo: $error';
  }

  @override
  String tripAddPackingFailed(String error) {
    return 'Could not add packing item: $error';
  }

  @override
  String tripLoadBudgetFailed(String error) {
    return 'Could not load budget: $error';
  }

  @override
  String tripUpdateBudgetFailed(String error) {
    return 'Could not update budget: $error';
  }

  @override
  String tripSaveFailed(String error) {
    return 'Save failed: $error';
  }

  @override
  String get tripOpenLinkFailed => 'Could not open link';

  @override
  String get tripFerrySearchFailed => 'Could not open ferry search';

  @override
  String get tripLoadFailed => 'Could not load this trip';

  @override
  String get tripEditTitle => 'Edit title';

  @override
  String get tripDeleteTitle => 'Delete trip?';

  @override
  String get tripDeleteBody => 'This cannot be undone.';

  @override
  String get tripLeaveTitle => 'Remove from my trips?';

  @override
  String get tripLeaveBody =>
      'You\'ll lose access until you\'re invited again. The trip itself is not deleted.';

  @override
  String get tripRemove => 'Remove';

  @override
  String get tripUndo => 'Undo';

  @override
  String get tripAddPlacesBeforeRefine =>
      'Add some places before refining with AI.';

  @override
  String get tripAssistantLabel => 'Trip assistant';

  @override
  String tripRefiningSection(String section) {
    return 'Refining $section';
  }

  @override
  String tripRefineCity(String city) {
    return 'Refine $city';
  }

  @override
  String get tripRefineThisDay => 'Refine this day';

  @override
  String get tripRefineWithAI => 'Refine with AI';

  @override
  String get tripAskAI => 'Ask AI about this trip';

  @override
  String get tripShareLinkCopied => 'Share link copied to clipboard';

  @override
  String get tripSharingTurnedOff =>
      'Sharing turned off — links no longer work (existing co-planners and followers keep access)';

  @override
  String tripCoPlanInviteMessage(String summary) {
    return 'Co-plan with me: $summary';
  }

  @override
  String get tripInviteCopied =>
      'Co-planner invite copied — anyone with it can edit';

  @override
  String get tripCoPlannerRemoved => 'Co-planner removed';

  @override
  String tripInviteSent(String email) {
    return 'Invite sent to $email';
  }

  @override
  String get tripShareTrip => 'Share trip';

  @override
  String get tripShareLinkAction => 'Share link…';

  @override
  String get tripCopyShareLink => 'Copy share link';

  @override
  String get tripShareInviteAction => 'Share co-planner invite…';

  @override
  String get tripCopyInviteLink => 'Copy invite link (can edit)';

  @override
  String get tripManageAccess => 'Manage access';

  @override
  String get tripPrintSavePdf => 'Print / Save as PDF';

  @override
  String get tripAddToCalendar => 'Add to calendar';

  @override
  String get tripTurnOffSharing => 'Turn off sharing';

  @override
  String get tripDeleteTrip => 'Delete trip';

  @override
  String get tripRemoveFromMyTrips => 'Remove from my trips';

  @override
  String get tripMoreActions => 'More options';

  @override
  String get tripAirportsTitle => 'Trip airports';

  @override
  String get tripAirportsHelp =>
      'Which airports this trip flies out of and comes home into. Your saved home airport doesn\'t change.';

  @override
  String get tripAirportsDepartsFrom => 'Departs from';

  @override
  String get tripAirportsReturnsInto => 'Returns into';

  @override
  String get tripAirportsSameBothWays => 'Comes home into the same airport';

  @override
  String get tripAirportsUseHomeAirport => 'Use my home airport';

  @override
  String get tripAirportsPickOne => 'Pick an airport from the list.';

  @override
  String get tripAirportsBothNeeded =>
      'Pick an airport for both ends, or clear them.';

  @override
  String tripAirportsCurrentFallback(String label) {
    return 'Right now these legs use $label.';
  }

  @override
  String get tripAirportsMenuLabel => 'Trip airports…';

  @override
  String get tripAirportsChangeDeparture => 'Change departure airport…';

  @override
  String get tripAirportsChangeReturn => 'Change return airport…';

  @override
  String get tripAirportsChangeLink => 'Change airport';

  @override
  String tripAirportsSaved(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Saved. $count legs renamed.',
      one: 'Saved. 1 leg renamed.',
      zero:
          'Saved. No departure or return leg yet — they\'ll use these airports when they appear.',
    );
    return '$_temp0';
  }

  @override
  String tripAirportsFailed(String error) {
    return 'Couldn\'t save the trip\'s airports: $error';
  }

  @override
  String get tripLocalIntel => 'Local intel';

  @override
  String tripLocalGuideTitle(String title) {
    return 'Local guide: $title';
  }

  @override
  String tripGuideBy(String name) {
    return 'By $name';
  }

  @override
  String tripEventsWhileHereCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count events while you\'re here',
      one: '1 event while you\'re here',
    );
    return '$_temp0';
  }

  @override
  String tripEventsWhileHereCountCapped(int count) {
    return '$count+ events while you\'re here';
  }

  @override
  String tripEventsInCity(String city) {
    return 'Events in $city';
  }

  @override
  String get tripEventsSource => 'Listings from Ticketmaster';

  @override
  String tripFindingEvents(String city) {
    return 'Finding events in $city…';
  }

  @override
  String tripFindEventsIn(String city) {
    return 'Find events in $city';
  }

  @override
  String tripRecommendedBy(String name) {
    return 'Recommended by $name';
  }

  @override
  String get tripFindFlights => 'Find flights';

  @override
  String get tripFindFlightsShort => 'Flights';

  @override
  String get tripFindFerries => 'Find ferries';

  @override
  String get tripFindFerriesShort => 'Ferries';

  @override
  String get tripAddBooking => 'Add a booking';

  @override
  String get tripEditBooking => 'Edit booking';

  @override
  String get tripFieldType => 'Type';

  @override
  String get tripKindStay => 'Stay';

  @override
  String get tripKindTransport => 'Transport';

  @override
  String get tripKindOther => 'Other';

  @override
  String get tripFieldTitle => 'Title';

  @override
  String get tripFieldOrigin => 'Origin (optional)';

  @override
  String get tripFieldDestination => 'Destination (optional)';

  @override
  String get tripFieldDepartDate => 'Depart date (optional)';

  @override
  String get tripFieldCheckIn => 'Check-in (optional)';

  @override
  String get tripFieldCheckOut => 'Check-out (optional)';

  @override
  String get tripFieldLink => 'Link (optional, overrides search)';

  @override
  String get tripTitleRequired => 'Title is required';

  @override
  String get tripClearDate => 'Clear date';

  @override
  String get tripItinerary => 'Itinerary';

  @override
  String get tripToday => 'Today';

  @override
  String get tripAddPlace => 'Add place';

  @override
  String get tripFilterUnbooked => 'Not booked yet';

  @override
  String get tripFilterAllBooked => 'Everything\'s booked';

  @override
  String get tripFilterAllBookedMessage =>
      'Nothing left to book on this trip — you\'re all set.';

  @override
  String get tripTabBookings => 'Bookings';

  @override
  String get tripBookingsLensEmptyTitle => 'No bookings yet';

  @override
  String get tripBookingsLensEmptyMessage =>
      'Flights, stays, and reservations for this trip will show up here.';

  @override
  String get tripBookingsLensNoneForDestination =>
      'No bookings for this destination.';

  @override
  String get tripNoPlacesYet => 'No places yet';

  @override
  String get tripNoPlacesYetMessage =>
      'Refine with AI or add a place to start your itinerary.';

  @override
  String get tripNoMappedPlaces => 'No mapped places';

  @override
  String tripNoPlacesInLeg(String city) {
    return 'No places pinned in $city';
  }

  @override
  String get tripAddPlaceMapHint => 'Add a place to see it on the map.';

  @override
  String get tripExpandMap => 'Expand map';

  @override
  String tripDayN(int n) {
    return 'Day $n';
  }

  @override
  String tripDayTripTo(String town) {
    return 'Day trip · $town';
  }

  @override
  String get tripDayTripFallback => 'Day trip';

  @override
  String tripTonight(String stays) {
    return 'Tonight: $stays';
  }

  @override
  String tripLegNights(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count nights',
      one: '1 night',
    );
    return '· $_temp0';
  }

  @override
  String tripTravelMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String tripTravelHours(int hours) {
    return '${hours}h';
  }

  @override
  String tripTravelHoursMinutes(int hours, int minutes) {
    return '${hours}h ${minutes}m';
  }

  @override
  String tripTravelFromHub(String duration, String hub) {
    return '$duration from $hub';
  }

  @override
  String tripTravelTotal(String duration) {
    return '$duration travel';
  }

  @override
  String tripRainChance(int percent) {
    return '$percent% rain';
  }

  @override
  String get tripTypicalForDates => 'typical for these dates';

  @override
  String get tripPlaceActions => 'Place actions';

  @override
  String get tripOpenInGoogleMaps => 'Open in Google Maps';

  @override
  String get tripEdit => 'Edit';

  @override
  String get tripMoveUp => 'Move up';

  @override
  String get tripMoveDown => 'Move down';

  @override
  String get tripReorderSection => 'Reorder section';

  @override
  String get tripAddToGoogleCalendar => 'Add to Google Calendar';

  @override
  String get tripAddToAppleCalendar => 'Add to Apple Calendar (.ics)';

  @override
  String tripRemovedItem(String name) {
    return 'Removed $name';
  }

  @override
  String tripMovedToDay(int day) {
    return 'Moved to Day $day';
  }

  @override
  String get tripMarkedAsBooked => 'Marked as booked';

  @override
  String tripAddedToPacking(String item) {
    return 'Added \"$item\" to packing';
  }

  @override
  String get tripRename => 'Rename';

  @override
  String get tripAddDates => 'Add dates';

  @override
  String tripCoPlanningWith(String name) {
    return 'Co-planning with $name — your changes save for everyone.';
  }

  @override
  String get tripCoPlanningShared =>
      'Co-planning a shared trip — your changes save for everyone.';

  @override
  String tripSharedBy(String name) {
    return 'Shared by $name — view only.';
  }

  @override
  String get tripSharedViewOnly => 'Shared trip — view only.';

  @override
  String tripUpdatedBy(String name, String time) {
    return 'Updated by $name · $time';
  }

  @override
  String get tripOverview => 'Overview';

  @override
  String get tripShowMore => 'Show more';

  @override
  String get tripShowLess => 'Show less';

  @override
  String get tripTimeRecently => 'recently';

  @override
  String get tripTimeJustNow => 'just now';

  @override
  String tripTimeMinutesAgo(int minutes) {
    return '${minutes}m ago';
  }

  @override
  String tripTimeHoursAgo(int hours) {
    return '${hours}h ago';
  }

  @override
  String tripTimeDaysAgo(int days) {
    return '${days}d ago';
  }

  @override
  String get tripFriendEmail => 'Friend\'s email';

  @override
  String get tripInvite => 'Invite';

  @override
  String get tripNoCoPlanners =>
      'No co-planners yet. Invite a friend by email above, or copy an invite link from the share menu.';

  @override
  String get tripRoleViewer => 'Viewer';

  @override
  String get tripRoleCanEdit => 'Can edit';

  @override
  String get tripRemoveAccess => 'Remove access';

  @override
  String get tripPendingInvites => 'Pending invites';

  @override
  String tripInvited(String expires) {
    return 'Invited — $expires';
  }

  @override
  String get tripRevokeInvite => 'Revoke invite';

  @override
  String tripExpiresInDays(int days) {
    return 'expires in ${days}d';
  }

  @override
  String tripExpiresInHours(int hours) {
    return 'expires in ${hours}h';
  }

  @override
  String get tripExpiresSoon => 'expires soon';

  @override
  String get tripEditPlace => 'Edit place';

  @override
  String get tripFieldName => 'Name';

  @override
  String get tripFieldCity => 'City';

  @override
  String get tripFieldDay => 'Day';

  @override
  String get tripCategoryAttraction => 'Attraction';

  @override
  String get tripCategoryRestaurant => 'Restaurant';

  @override
  String get tripTimeMorning => 'Morning';

  @override
  String get tripTimeAfternoon => 'Afternoon';

  @override
  String get tripTimeEvening => 'Evening';

  @override
  String get tripReorderPlaces => 'Reorder places';

  @override
  String get tripReorderHint =>
      'Drag to change the visit order within this section.';

  @override
  String get tripSaveOrder => 'Save order';

  @override
  String get tripsListTitle => 'My Trips';

  @override
  String get tripsListErrorTitle => 'Could not load trips';

  @override
  String get tripsListErrorMessage => 'Check your connection and try again.';

  @override
  String get tripsListEmptyTitle => 'No trips yet';

  @override
  String get tripsListEmptyMessage =>
      'Chat with the AI agent to create your first trip.';

  @override
  String get tripsListPlanTrip => 'Plan a trip';

  @override
  String get tripsListSharedWithYou => 'Shared with you';

  @override
  String get tripsListPastTrips => 'Past trips';

  @override
  String tripsListPastTripsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count trips',
      one: '1 trip',
    );
    return '$_temp0';
  }

  @override
  String get tripsListUpcoming => 'Upcoming';

  @override
  String get tripsListNewTrip => 'New trip';

  @override
  String get tripsListYourTravels => 'Your travels';

  @override
  String get tripsListTravelMap => 'Your travel map';

  @override
  String get tripsListStatsTraveled => 'Traveled';

  @override
  String get tripsListStatsPlanned => 'Planned';

  @override
  String tripsListStatTrips(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Trips',
      one: 'Trip',
    );
    return '$_temp0';
  }

  @override
  String tripsListStatTravelDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Travel days',
      one: 'Travel day',
    );
    return '$_temp0';
  }

  @override
  String tripsListStatCities(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Cities',
      one: 'City',
    );
    return '$_temp0';
  }

  @override
  String tripsListStaysCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count stays',
      one: '1 stay',
    );
    return '$_temp0';
  }

  @override
  String tripsListPackedCount(int checked, int total) {
    return '$checked/$total packed';
  }

  @override
  String tripsListBudgetSpentOfTarget(String spent, String target) {
    return '$spent of $target';
  }

  @override
  String tripsListBookTransportNudge(String date) {
    return 'Book transport — first leg departs $date';
  }

  @override
  String tripDurationDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days',
      one: '1 day',
    );
    return '$_temp0';
  }

  @override
  String tripCitiesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count cities',
      one: '1 city',
    );
    return '$_temp0';
  }

  @override
  String tripsListPlaces(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count places',
      one: '1 place',
    );
    return '$_temp0';
  }

  @override
  String tripsListBookedCount(int booked, int total) {
    return '$booked/$total booked';
  }

  @override
  String get tripsListShared => 'Shared';

  @override
  String get upNextEyebrow => 'UP NEXT';

  @override
  String upNextStartsIn(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'Starts in $days days',
      one: 'Starts tomorrow',
      zero: 'Starts today',
    );
    return '$_temp0';
  }

  @override
  String tripsListCreated(String date) {
    return 'Created $date';
  }

  @override
  String tripsListPlannedWith(String name) {
    return 'Planned with $name';
  }

  @override
  String tripsListSharedBy(String name) {
    return 'Shared by $name';
  }

  @override
  String get tripsListVersionsError => 'Could not load versions';

  @override
  String tripsListVersionLatest(String date) {
    return 'latest · $date';
  }

  @override
  String tripsListVersionNumbered(int version, String date) {
    return 'v$version · $date';
  }

  @override
  String get settingsConnectedAppsSection => 'Connected apps';

  @override
  String get settingsConnectedAppsHelp =>
      'AI assistants you\'ve allowed to create trips in your account.';

  @override
  String get settingsConnectedAppsEmpty => 'No apps connected.';

  @override
  String get settingsConnectedAppsError => 'Could not load connected apps';

  @override
  String settingsConnectedLastUsed(String date) {
    return 'Last used $date';
  }

  @override
  String get settingsConnectedNeverUsed => 'Not used yet';

  @override
  String get settingsRevokeAction => 'Revoke';

  @override
  String settingsRevokeConfirmTitle(String app) {
    return 'Revoke $app?';
  }

  @override
  String get settingsRevokeConfirmBody =>
      'It will stop being able to create trips in your account right away. You can connect it again later.';

  @override
  String settingsRevokedToast(String app) {
    return '$app disconnected';
  }

  @override
  String get connectAppBarTitle => 'Connect app';

  @override
  String connectTitle(String app) {
    return 'Connect $app to Anemos?';
  }

  @override
  String get connectUnverifiedCaution =>
      'This name was provided by the app itself and hasn\'t been verified by us. Only continue if you started this from an app you trust.';

  @override
  String get connectWillBeAbleTo => 'It will be able to:';

  @override
  String get connectScopeTripsWrite =>
      'Create trips in your account and see your trip list';

  @override
  String get connectScopeRecsRead => 'Search Anemos\'s local recommendations';

  @override
  String get connectSignInPrompt =>
      'Sign in to your Anemos account to continue.';

  @override
  String get connectSignInCta => 'Sign in';

  @override
  String get connectApprove => 'Connect';

  @override
  String get connectDeny => 'Cancel';

  @override
  String get connectExpiredTitle => 'This request expired';

  @override
  String get connectExpiredMessage =>
      'Start the connection again from your AI assistant.';

  @override
  String get importFromAi => 'Import from AI chat';

  @override
  String get importExplainer =>
      'Planned a trip in ChatGPT or Claude? Paste the conversation — or its final summary — and we\'ll turn it into a trip you can edit.';

  @override
  String get importCopyPrompt => 'Copy planning prompt';

  @override
  String get importPromptCopied =>
      'Prompt copied — paste it into ChatGPT or Claude to start planning.';

  @override
  String get importPasteButton => 'Paste';

  @override
  String get importPasteHint => 'Paste your conversation or trip summary here…';

  @override
  String get importButton => 'Import trip';

  @override
  String get importProgressReading => 'Reading your conversation…';

  @override
  String get importProgressLocating => 'Finding places on the map…';

  @override
  String get importWarningsTitle => 'Some places need attention';

  @override
  String get importViewTrip => 'View trip';

  @override
  String get logTripTitle => 'Log a past trip';

  @override
  String get logTripAction => 'Add past trip';

  @override
  String get logTripExplainer =>
      'Been somewhere we didn\'t plan? Add it here and it counts in Your travels.';

  @override
  String get logTripDestinationsLabel => 'Where did you go?';

  @override
  String get logTripDestinationsHint => 'Search a city or country';

  @override
  String logTripAddByName(String name) {
    return 'Add \"$name\" by name';
  }

  @override
  String get logTripNoCoordsNote =>
      'Destinations without a map location still count as cities, but they won\'t get a dot on your travel map.';

  @override
  String get logTripDatesLabel => 'When?';

  @override
  String get logTripPickDates => 'Pick your travel dates';

  @override
  String get logTripDatesRequired =>
      'Dates are required — they\'re what counts this trip as travel you\'ve already taken.';

  @override
  String get logTripNameLabel => 'Name this trip (optional)';

  @override
  String get logTripSave => 'Save trip';

  @override
  String get importPlanningPrompt =>
      'Help me plan a trip. Ask about my destination, dates, interests, pace, and budget, then build a day-by-day itinerary. When we\'re done, finish with a section titled TRIP SUMMARY that lists: the destination(s) and exact travel dates; each day as \"Day N — City\" with Morning / Afternoon / Evening entries, each written as \"Place Name — City\" using real, mappable place names; day trips marked as \"day trip from [city]\"; and how I\'m traveling between cities (flight, car, train, bus, or ferry).';

  @override
  String get homeGreetingMorning => 'Good morning';

  @override
  String get homeGreetingAfternoon => 'Good afternoon';

  @override
  String get homeGreetingEvening => 'Good evening';

  @override
  String homeGreetingNamed(String greeting, String name) {
    return '$greeting, $name';
  }

  @override
  String get homeGreetingSubtitle => 'Where are we off to next?';

  @override
  String get homeHeroTitle => 'Plan less. Travel more.';

  @override
  String get homeHeroSubtitle =>
      'Describe the trip you\'re dreaming of and I\'ll build the full itinerary — places, days, and routes.';

  @override
  String get homeHeroCta => 'Let\'s go';

  @override
  String get suggestionParis => '2 days in Paris';

  @override
  String get suggestionRome => 'Museums in Rome';

  @override
  String get suggestionTokyo => 'Weekend in Tokyo';

  @override
  String get suggestionGreece => 'Island hopping in Greece';

  @override
  String get suggestionLisbon => '3 days in Lisbon';

  @override
  String get suggestionBarcelona => 'Tapas in Barcelona';

  @override
  String get suggestionBangkok => 'Street food in Bangkok';

  @override
  String get suggestionAmalfi => 'Amalfi Coast road trip';

  @override
  String get suggestionNewYork => 'A week in New York';

  @override
  String get suggestionBali => 'Beaches in Bali';

  @override
  String get suggestionPatagonia => 'Hiking in Patagonia';

  @override
  String get suggestionKenya => 'Safari in Kenya';

  @override
  String get homeLocalGuidesTitle => 'Local guides';

  @override
  String homeGuideByline(String name) {
    return 'By $name';
  }

  @override
  String get shellNavHome => 'Home';

  @override
  String get shellNavPlan => 'Plan';

  @override
  String get shellNavTrips => 'Trips';

  @override
  String get healthMetricsErrorTitle => 'Could not load metrics';

  @override
  String get healthHealthErrorTitle => 'Could not load health';

  @override
  String get healthProcessSection => 'Process';

  @override
  String get healthRoutesSection => 'Routes';

  @override
  String get healthProcessUptime => 'Process uptime';

  @override
  String get healthRequests => 'Requests';

  @override
  String get healthErrorRate => 'Error rate';

  @override
  String get healthGoroutines => 'Goroutines';

  @override
  String get healthMemory => 'Memory';

  @override
  String get healthPlacesCalls => 'Places calls';

  @override
  String healthCacheHits(int count) {
    return '$count cache hits';
  }

  @override
  String get healthColRoute => 'Route';

  @override
  String get healthColMethod => 'Method';

  @override
  String get healthColCount => 'Count';

  @override
  String get healthColErrorPct => 'Error %';

  @override
  String get healthDependenciesSection => 'Dependencies';

  @override
  String get healthDatabase => 'Database';

  @override
  String healthPing(int ms) {
    return '$ms ms ping';
  }

  @override
  String get healthPillOk => 'ok';

  @override
  String get healthPillUnreachable => 'unreachable';

  @override
  String get healthPillConfigured => 'configured';

  @override
  String get healthPillNotConfigured => 'not configured';

  @override
  String get healthPillUnknown => 'unknown';

  @override
  String get healthPillStale => 'stale';

  @override
  String get healthPillFresh => 'fresh';

  @override
  String get healthBackupsSection => 'Backups';

  @override
  String get healthLastBackup => 'Last backup';

  @override
  String healthBackupAge(String age) {
    return '$age ago';
  }

  @override
  String get healthNoBackupRecorded => 'no backup recorded';

  @override
  String get healthBuildSection => 'Build';

  @override
  String healthRelease(String release) {
    return 'release $release';
  }

  @override
  String get healthDegradedTitle => 'System degraded';

  @override
  String get healthRecoveredTitle => 'System recovered';

  @override
  String get notifOpsOpenHealth => 'View system health';

  @override
  String get healthUptimeSection => 'Uptime';

  @override
  String get healthUptimeSelfCheckNote =>
      'Self-check — cannot see edge or gateway outages';

  @override
  String get healthUptimeComponentApi => 'API';

  @override
  String get healthUptimeComponentAi => 'AI provider';

  @override
  String get healthUptimePillDown => 'down';

  @override
  String healthUptimeDaysAgo(int days) {
    return '$days days ago';
  }

  @override
  String get healthUptimeToday => 'Today';

  @override
  String healthUptimeSummary(String pct) {
    return '$pct % uptime';
  }

  @override
  String healthUptimeSummaryPartial(String pct, int days) {
    return '$pct % uptime · $days days observed';
  }

  @override
  String get healthUptimeNoHistory => 'No history yet';

  @override
  String healthUptimeMonitoringSince(String date) {
    return 'Monitoring since $date';
  }

  @override
  String healthUptimeDayNoData(String date) {
    return '$date · no data';
  }

  @override
  String get healthUptimeNoIncidents => 'no incidents';

  @override
  String healthUptimeDown(String duration) {
    return '$duration down';
  }

  @override
  String get healthUptimeReasonDbUnreachable => 'database unreachable';

  @override
  String get healthUptimeReasonProcessDown => 'process down';

  @override
  String get healthUptimeReasonAiFailing => 'AI provider failing';

  @override
  String get healthUptimeReasonBackupsStale => 'backups stale';

  @override
  String get healthUptimeKeyboardHint =>
      'Use the left and right arrow keys to inspect a day';

  @override
  String get healthUptimeErrorTitle => 'Could not load uptime';

  @override
  String get reviewSectionTitle => 'Trip health';

  @override
  String reviewHeaderAttention(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Mostly ready — $count to fix',
      one: 'Mostly ready — 1 to fix',
    );
    return '$_temp0';
  }

  @override
  String reviewHeaderSuggestionsOnly(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'In good shape — $count suggestions',
      one: 'In good shape — 1 suggestion',
    );
    return '$_temp0';
  }

  @override
  String get reviewNeedsAttentionHeader => 'Needs attention';

  @override
  String get reviewSuggestionsHeader => 'Suggestions';

  @override
  String reviewBadgeAttentionSemantics(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items need attention',
      one: '1 item needs attention',
    );
    return '$_temp0';
  }

  @override
  String reviewBadgeSuggestionsSemantics(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count suggestions available',
      one: '1 suggestion available',
    );
    return '$_temp0';
  }

  @override
  String get reviewEmptyTitle => 'Looks good';

  @override
  String get reviewEmptyMessage =>
      'No issues found — your trip is in good shape.';

  @override
  String get reviewSeverityCritical => 'Critical';

  @override
  String get reviewSeverityWarning => 'Warning';

  @override
  String get reviewSeverityInfo => 'Info';

  @override
  String get reviewOfflineSnack =>
      'You\'re offline — reconnect to run more checks.';

  @override
  String get reviewHoursChecked => 'Opening hours checked';

  @override
  String get reviewCheckHours => 'Also check opening hours';

  @override
  String get reviewHoursCheckFailed =>
      'Couldn\'t check opening hours — try again.';

  @override
  String get liveTripEyebrow => 'HAPPENING NOW';

  @override
  String get liveTripStatusLive => 'Live';

  @override
  String liveTripDay(int day) {
    return 'Day $day';
  }

  @override
  String liveTripDayOfTotal(int day, int total) {
    return 'Day $day of $total';
  }

  @override
  String get continueChatsTitle => 'Continue where you left off';

  @override
  String get continueChatsReopenError => 'Could not reopen that conversation.';

  @override
  String get continueChatsDismissError =>
      'Could not dismiss that conversation.';

  @override
  String get continueChatsDismiss => 'Dismiss';

  @override
  String get mapNoMappedPlaces => 'No mapped places';

  @override
  String get mapZoomIn => 'Zoom in';

  @override
  String get mapZoomOut => 'Zoom out';

  @override
  String get mapResetMap => 'Reset map';

  @override
  String mapLegVisitNumber(int n) {
    return 'Visit $n';
  }

  @override
  String get mapShowAllPlaces => 'Show all places';

  @override
  String mapDepartureAirport(String code) {
    return 'Departure airport ($code)';
  }

  @override
  String mapReturnAirport(String code) {
    return 'Return airport ($code)';
  }

  @override
  String mapHomeAirport(String code) {
    return 'Home airport ($code)';
  }

  @override
  String get accountMenuTooltip => 'Account';

  @override
  String get accountMenuTravelProfile => 'Travel profile';

  @override
  String get accountMenuNotifications => 'Notifications';

  @override
  String get accountMenuRetakeQuiz => 'Retake travel quiz';

  @override
  String get accountMenuAccountSettings => 'Settings';

  @override
  String get accountMenuLocalIntelAdmin => 'Local intel admin';

  @override
  String get accountMenuMetrics => 'Metrics';

  @override
  String get accountMenuSignOut => 'Sign out';

  @override
  String get nextStepEyebrow => 'Next step';

  @override
  String nextStepProgress(int n, int total) {
    return '$n of $total';
  }

  @override
  String get nextStepViewAll => 'View all';

  @override
  String get nextStepSetDatesAction => 'Pick dates';

  @override
  String get nextStepPlanAction => 'Plan in chat';

  @override
  String get nextStepLodgingAction => 'Find lodging';

  @override
  String get nextStepTransportAction => 'Find options';

  @override
  String get nextStepScheduleAction => 'Fill the gaps';

  @override
  String get nextStepBookAction => 'Review bookings';

  @override
  String get nextStepPackingAction => 'Open packing list';

  @override
  String get nextStepAllSetDismiss => 'Dismiss';

  @override
  String get nextStepViewProgress => 'View all steps';

  @override
  String get planProgressTitle => 'Plan progress';

  @override
  String get planProgressHint =>
      'Steps unlock in order — finish this one and the next opens.';

  @override
  String get planProgressStateDone => 'Done';

  @override
  String get planProgressStateCurrent => 'Current step';

  @override
  String get planProgressStateLater => 'Later';

  @override
  String get notifTitle => 'Notifications';

  @override
  String get notifMoreActions => 'More options';

  @override
  String get notifClearAll => 'Clear all';

  @override
  String get notifClearAllTitle => 'Clear all notifications?';

  @override
  String get notifClearAllBody =>
      'This removes every notification, including unread ones. This cannot be undone.';

  @override
  String notifClearAllFailed(String error) {
    return 'Could not clear notifications: $error';
  }

  @override
  String get notifLoadErrorTitle => 'Could not load notifications';

  @override
  String get notifEmptyTitle => 'No notifications yet';

  @override
  String get notifEmptyMessage =>
      'Trip reminders and co-planning updates will show up here.';

  @override
  String get notifUnreadSemantic => 'Unread';

  @override
  String notifDownFrom(String price, String previous) {
    return '$price, down from $previous';
  }

  @override
  String get notifBestInWindow => '(best in window)';

  @override
  String get notifGenericFallback => 'Notification';

  @override
  String get notifSomeTrip => 'a trip';

  @override
  String get notifSomeone => 'Someone';

  @override
  String get notifACollaborator => 'A collaborator';

  @override
  String notifJoinedTrip(String who, String trip) {
    return '$who joined \"$trip\"';
  }

  @override
  String notifFollowedTrip(String who, String trip) {
    return '$who is now following \"$trip\"';
  }

  @override
  String notifEditedTrip(String who, String trip) {
    return '$who edited \"$trip\"';
  }

  @override
  String get sharedTitle => 'Shared trip';

  @override
  String get sharedUnavailableTitle => 'This link isn\'t available';

  @override
  String get sharedInviteUnavailableMessage =>
      'The invite may have expired, been revoked, or already used.';

  @override
  String get sharedLinkUnavailableMessage =>
      'The trip may have been unshared, or the link is incorrect.';

  @override
  String get sharedPlacesGroup => 'Places';

  @override
  String sharedSaveCopyError(String error) {
    return 'Could not save a copy: $error';
  }

  @override
  String sharedJoinError(String error) {
    return 'Could not join trip: $error';
  }

  @override
  String sharedBy(String name) {
    return 'Shared by $name';
  }

  @override
  String get sharedNoMappedPlaces => 'No mapped places';

  @override
  String sharedNoPlacesIn(String city) {
    return 'No places pinned in $city';
  }

  @override
  String get sharedEmptyTitle => 'No places yet';

  @override
  String get sharedEmptyMessage => 'This trip doesn\'t have an itinerary yet.';

  @override
  String sharedDayN(int day) {
    return 'Day $day';
  }

  @override
  String get sharedStays => 'Stays';

  @override
  String get sharedJoinCoPlanner => 'Join as co-planner';

  @override
  String get sharedSaveSeparateCopy => 'Or save a separate copy';

  @override
  String get sharedKeepInTrips => 'Keep in my trips';

  @override
  String get legalAgreementPrefix => 'By signing up you agree to the ';

  @override
  String get legalConsentCheckboxPrefix => 'I agree to the ';

  @override
  String get legalTermsOfService => 'Terms of Service';

  @override
  String get legalAgreementConjunction => ' and ';

  @override
  String get legalPrivacyPolicy => 'Privacy Policy';

  @override
  String get offlineJustNow => 'just now';

  @override
  String offlineMinutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutes ago',
      one: '1 minute ago',
    );
    return '$_temp0';
  }

  @override
  String offlineHoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hours ago',
      one: '1 hour ago',
    );
    return '$_temp0';
  }

  @override
  String offlineDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days ago',
      one: '1 day ago',
    );
    return '$_temp0';
  }

  @override
  String offlineBannerMessage(String when) {
    return 'Offline — showing saved copy from $when';
  }

  @override
  String get chatInputHint => 'Where do you want to go?';

  @override
  String get chatFollowUpHint => 'Ask a follow-up…';

  @override
  String get chatSend => 'Send';

  @override
  String get chatStopGenerating => 'Stop generating';

  @override
  String get chatAttachImages => 'Attach images';

  @override
  String get chatStopDictating => 'Stop dictating';

  @override
  String get chatDictate => 'Dictate';

  @override
  String get chatDropImages => 'Drop images to attach';

  @override
  String get chatRemoveImage => 'Remove image';

  @override
  String get chatImagePlaceholder => 'Image';

  @override
  String get chatStillPreparingImage =>
      'Still preparing an image — one moment.';

  @override
  String chatAttachLimit(int count) {
    return 'You can attach up to $count images.';
  }

  @override
  String get chatImageUnreadable =>
      'Couldn\'t read that image — try a JPEG, PNG, GIF, or WebP under 10 MB.';

  @override
  String get chatOnlyImages => 'Only image files can be attached.';

  @override
  String get chatToolSearchPlaces => 'Searching places...';

  @override
  String get chatToolCreateItinerary => 'Building itinerary...';

  @override
  String get chatToolUpdateItinerary => 'Updating itinerary...';

  @override
  String get chatToolSearchFlights => 'Searching flights...';

  @override
  String get chatToolCheckConnectivity => 'Checking route connectivity...';

  @override
  String get chatToolSearchEvents => 'Finding events...';

  @override
  String get chatToolSuggestFerries => 'Finding ferries...';

  @override
  String get chatToolLocalRecs => 'Finding local picks...';

  @override
  String get chatToolReviewTrip => 'Reviewing your trip...';

  @override
  String get chatToolWeather => 'Checking weather...';

  @override
  String get chatToolSearchNearby => 'Searching nearby...';

  @override
  String get chatToolWorking => 'Working...';

  @override
  String get chatSummarizing => 'Summarizing earlier conversation…';

  @override
  String get chatProfileUpdatedTooltip => 'Travel profile updated';

  @override
  String get chatProfileUpdated => 'Noted — travel profile updated';

  @override
  String get chatTripUpdated => 'Trip updated';

  @override
  String chatChipFlightOptions(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count flight options',
      one: '$count flight option',
    );
    return '$_temp0';
  }

  @override
  String chatChipLocalPicks(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count local picks',
      one: '$count local pick',
    );
    return '$_temp0';
  }

  @override
  String chatStripPlaces(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count places',
      one: '$count place',
    );
    return '$_temp0';
  }

  @override
  String chatStripParking(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count parking options',
      one: '$count parking option',
    );
    return '$_temp0';
  }

  @override
  String get chatToolFindParking => 'Finding parking...';

  @override
  String get chatCardFreeListed => 'Free (listed)';

  @override
  String chatChipEvents(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count events',
      one: '$count event',
    );
    return '$_temp0';
  }

  @override
  String chatChipFerryOptions(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count ferry options',
      one: '$count ferry option',
    );
    return '$_temp0';
  }

  @override
  String chatChipEventSources(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count event sources',
      one: '$count event source',
    );
    return '$_temp0';
  }

  @override
  String get chatTryAgain => 'Try again';

  @override
  String get chatQueued => 'Queued';

  @override
  String get chatRemoveQueued => 'Remove queued message';

  @override
  String get agentScreenTitle => 'Plan your trip';

  @override
  String get agentScreenStartOver => 'Start over';

  @override
  String get agentScreenEmptyTitle => 'Tell me about your dream trip';

  @override
  String get agentScreenEmptyMessage =>
      'I\'ll search real places and build you a day-by-day itinerary.';

  @override
  String agentScreenItineraryReady(int count) {
    return 'Itinerary ready — $count locations';
  }

  @override
  String get agentScreenViewTrip => 'View trip';

  @override
  String get agentScreenSignInToSave => 'Sign in to save your trips';

  @override
  String get resultChipViewInTrip => 'View in trip';

  @override
  String refineTargetDay(int day) {
    return 'Day $day';
  }

  @override
  String refineTargetDayCity(int day, String city) {
    return 'Day $day — $city';
  }

  @override
  String get refineTargetWholeTrip => 'Whole trip';

  @override
  String get refineAssistantTitle => 'Trip assistant';

  @override
  String refineHeader(String target) {
    return 'Refining · $target';
  }

  @override
  String get refineAssistantHint => 'Ask anything about this trip…';

  @override
  String get refineHint => 'Ask for changes...';

  @override
  String get chatDictationPermission =>
      'Microphone access was blocked. Check your browser settings.';

  @override
  String get chatDictationUnsupported =>
      'Voice input isn\'t available in this browser.';

  @override
  String get chatDictationUnavailable =>
      'Voice input isn\'t available right now.';

  @override
  String get chatDictationFailed =>
      'Couldn\'t transcribe audio. You can type instead.';

  @override
  String get placeSearchAddTitle => 'Add Location';

  @override
  String get placeSearchEditTitle => 'Edit Location';

  @override
  String get placeSearchManualCoords => 'Use Manual Coordinates';

  @override
  String get placeSearchManualCoordsSubtitle =>
      'Enter latitude/longitude manually instead of searching places';

  @override
  String get placeSearchNameLabel => 'Location Name *';

  @override
  String get placeSearchNameRequired => 'Location name is required';

  @override
  String get placeSearchCategoryLabel => 'Category (optional)';

  @override
  String get placeSearchCategoryHint => 'e.g., restaurant, museum, coffee_shop';

  @override
  String get placeSearchVisitDurationLabel =>
      'Visit Duration (minutes, optional)';

  @override
  String get placeSearchDurationInvalid =>
      'Please enter a valid duration in minutes';

  @override
  String get placeSearchSearchLabel => 'Search for a place';

  @override
  String get placeSearchSearchHint =>
      'Type to search for restaurants, attractions, etc.';

  @override
  String get placeSearchLatitude => 'Latitude';

  @override
  String get placeSearchLongitude => 'Longitude';

  @override
  String get placeSearchLatitudeRequired => 'Latitude *';

  @override
  String get placeSearchLongitudeRequired => 'Longitude *';

  @override
  String get placeSearchLatitudeRequiredError => 'Latitude is required';

  @override
  String get placeSearchLongitudeRequiredError => 'Longitude is required';

  @override
  String get placeSearchLatitudeInvalid => 'Enter valid latitude (-90 to 90)';

  @override
  String get placeSearchLongitudeInvalid =>
      'Enter valid longitude (-180 to 180)';

  @override
  String get placeSearchNoResults =>
      'No places found. Try a different search term.';

  @override
  String placeSearchError(String error) {
    return 'Error: $error';
  }

  @override
  String addToTripAddedTo(String title) {
    return 'Added to $title';
  }

  @override
  String get addToTripViewTrip => 'View trip';

  @override
  String get addToTripTitle => 'Add to trip';

  @override
  String get addToTripDuplicate => 'Already on this trip.';

  @override
  String get addToTripAddAnyway => 'Add anyway';

  @override
  String addToTripLoadTripError(String error) {
    return 'Could not load that trip: $error';
  }

  @override
  String addToTripAddPlaceError(String error) {
    return 'Could not add the place: $error';
  }

  @override
  String get addToTripLoadTripsError => 'Could not load your trips.';

  @override
  String get addToTripNoTrips =>
      'No trips yet — plan a trip first, then add places to it.';

  @override
  String get addToTripUnscheduled => 'Unscheduled';

  @override
  String addToTripDay(int day) {
    return 'Day $day';
  }

  @override
  String get flightSearchTitle => 'Find Flights';

  @override
  String get flightSearchFrom => 'From';

  @override
  String get flightSearchTo => 'To';

  @override
  String get flightSearchDepartDate => 'Departure date';

  @override
  String get flightSearchReturnOptional => 'Return (optional)';

  @override
  String get flightSearchClearReturnTooltip => 'Clear return date';

  @override
  String get flightSearchCabinEconomy => 'Economy';

  @override
  String get flightSearchCabinPremiumEconomy => 'Premium economy';

  @override
  String get flightSearchCabinBusiness => 'Business';

  @override
  String get flightSearchCabinFirst => 'First';

  @override
  String get flightSearchBaggagePersonalItem => 'Personal item';

  @override
  String get flightSearchBaggageCarryOn => 'Carry-on';

  @override
  String get flightSearchBaggageChecked => 'Checked bag';

  @override
  String get flightSearchPresetCheapest => 'Cheapest';

  @override
  String get flightSearchPresetFastest => 'Fastest';

  @override
  String get flightSearchPresetBalanced => 'Balanced';

  @override
  String get flightSearchSearching => 'Searching…';

  @override
  String get flightSearchSubmit => 'Search Flights';

  @override
  String get flightSearchErrorTitle => 'Could not load flights';

  @override
  String get flightSearchHintInitial =>
      'Choose an origin, destination, and date to find flights.';

  @override
  String get flightSearchHintEmpty =>
      'No flights found for this route and date.';

  @override
  String get flightSearchHintInitialTitle => 'Find your flight';

  @override
  String get flightSearchNoResultsTitle => 'No flights found';

  @override
  String get flightSearchFormTitle => 'Search';

  @override
  String get flightSearchEditSearch => 'Edit search';

  @override
  String flightSearchSummaryTravelers(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count travelers',
      one: '1 traveler',
    );
    return '$_temp0';
  }

  @override
  String get flightSearchCabinLabel => 'Cabin';

  @override
  String get flightSearchBaggageLabel => 'Baggage';

  @override
  String get flightSearchOptimizeLabel => 'Rank results by';

  @override
  String get flightSearchAdults => 'Adults';

  @override
  String get flightSearchChildren => 'Children';

  @override
  String get flightSearchAddAdult => 'Add adult';

  @override
  String get flightSearchRemoveAdult => 'Remove adult';

  @override
  String get flightSearchAddChild => 'Add child';

  @override
  String get flightSearchRemoveChild => 'Remove child';

  @override
  String flightSearchChildN(int n) {
    return 'Child $n';
  }

  @override
  String flightSearchResultsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count flights found',
      one: '1 flight found',
    );
    return '$_temp0';
  }

  @override
  String flightCardSavings(String amount) {
    return 'Saves $amount vs next option';
  }

  @override
  String get flightCardBagIncluded => 'Bag included';

  @override
  String flightCardBagPaid(String fee) {
    return 'incl. bag +$fee';
  }

  @override
  String get flightCardBagUnknown => 'Bag fee unknown';

  @override
  String get flightCardOpenLinkError => 'Could not open link';

  @override
  String get flightCardBestMatch => 'BEST MATCH';

  @override
  String get flightCardFlight => 'Flight';

  @override
  String flightCardScore(String score) {
    return 'score $score';
  }

  @override
  String get flightCardBook => 'Book';

  @override
  String get flightSheetOutbound => 'Outbound';

  @override
  String get flightSheetReturn => 'Return';

  @override
  String get flightSheetRoundTrip => 'Round trip';

  @override
  String get flightSheetBookThisFlight => 'Book this flight';

  @override
  String flightSheetBookWith(String airline) {
    return 'Book with $airline';
  }

  @override
  String get flightSheetBagPersonalItem => 'Personal item';

  @override
  String flightSheetBagCarryOnCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count carry-ons',
      one: 'carry-on',
    );
    return '$_temp0';
  }

  @override
  String flightSheetBagCheckedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count checked bags',
      one: 'checked bag',
    );
    return '$_temp0';
  }

  @override
  String flightSheetIncluded(String list) {
    return 'Included: $list';
  }

  @override
  String flightSheetBagFeeNote(String fee) {
    return '+$fee bag fee included in price';
  }

  @override
  String get flightSheetBagUnknownNote =>
      'Your bag is not included — check the fee with the airline';

  @override
  String flightSheetLayover(String airport) {
    return 'Layover $airport';
  }

  @override
  String flightSheetLayoverWithDuration(String airport, String duration) {
    return 'Layover $airport · $duration';
  }

  @override
  String get airportFieldHint => 'City or airport';

  @override
  String get airportFieldClearTooltip => 'Clear selection';

  @override
  String get airportFieldNoMatches => 'No matching airports';

  @override
  String get guidesTitle => 'Local guides';

  @override
  String get guidesErrorTitle => 'Could not load guides';

  @override
  String get guidesErrorMessage => 'Check your connection and try again.';

  @override
  String get guidesEmptyTitle => 'No guides yet';

  @override
  String get guidesEmptyMessage =>
      'Guides from real locals appear here as they publish.';

  @override
  String get guidesElsewhere => 'Elsewhere';

  @override
  String guidesByline(String name) {
    return 'by $name';
  }

  @override
  String get guideDetailTitle => 'Local guide';

  @override
  String get guideDetailErrorTitle => 'Could not load this guide';

  @override
  String get guideDetailErrorMessage => 'Check your connection and try again.';

  @override
  String guideDetailByline(String name) {
    return 'By $name';
  }

  @override
  String get guideDetailPlacesTitle => 'Places in this guide';

  @override
  String get guideDetailNoPinsTitle => 'No places pinned yet';

  @override
  String get guideDetailNoPinsMessage => 'This guide is all narrative for now.';

  @override
  String get appMapCredits => 'Map credits';

  @override
  String flightStops(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count stops',
      one: '1 stop',
      zero: 'Nonstop',
    );
    return '$_temp0';
  }

  @override
  String flightStopsEachWay(String stops) {
    return '$stops each way';
  }

  @override
  String flightStopsSplit(String outbound, String inbound) {
    return '$outbound / $inbound';
  }

  @override
  String calendarStayTitle(String name) {
    return 'Stay: $name';
  }

  @override
  String calendarSegmentTitle(String mode, String route) {
    return '$mode: $route';
  }

  @override
  String get calendarModeFlight => 'Flight';

  @override
  String get calendarModeTrain => 'Train';

  @override
  String get calendarModeBus => 'Bus';

  @override
  String get calendarModeCar => 'Car';

  @override
  String get calendarModeFerry => 'Ferry';

  @override
  String get calendarModeOther => 'Other';

  @override
  String get errorNetwork => 'Check your internet connection and try again.';

  @override
  String get errorTooManyRequests =>
      'You\'re going a little too fast — wait a moment and try again.';

  @override
  String get errorSession => 'Your session has expired. Please sign in again.';

  @override
  String get errorServer =>
      'Something went wrong on our end. Please try again in a moment.';

  @override
  String get errorGeneric => 'Something went wrong. Please try again.';

  @override
  String get nearMeChipLabel => 'What\'s near me?';

  @override
  String get nearMeSeedLabel => 'Near my current location';

  @override
  String nearMeSeedMessage(String lat, String lng, String accuracy) {
    return 'My current location is latitude $lat, longitude $lng (accuracy about $accuracy m). What\'s good to see, do, or eat near me right now?';
  }

  @override
  String nearMeManualMessage(String place) {
    return 'I\'m in $place. What\'s good to see, do, or eat nearby right now?';
  }

  @override
  String get nearMeDialogTitle => 'Where are you?';

  @override
  String get nearMeDialogMessage =>
      'We couldn\'t get your location. Type a city or neighborhood instead, or enable location access and try again.';

  @override
  String get nearMeDialogHint => 'e.g. Athens, Plaka';

  @override
  String get nearMeDialogCta => 'Ask';

  @override
  String get wearSectionTitle => 'What to wear & pack';

  @override
  String get wearBandFreezing => 'Freezing — thermals and an insulated coat';

  @override
  String get wearBandCold => 'Cold — warm coat, hat, and gloves';

  @override
  String get wearBandCool => 'Cool — a jacket and layers';

  @override
  String get wearBandMild => 'Mild — light layers';

  @override
  String get wearBandWarm => 'Warm — summer clothes, a light evening layer';

  @override
  String get wearBandHot => 'Hot — light fabrics and sun protection';

  @override
  String get wearRainLikely => 'rain likely, pack an umbrella';

  @override
  String get wearBigSwing => 'big day–night range, bring layers';

  @override
  String get wearExtremeHeat => 'very hot days, extra sun protection';

  @override
  String get wearFreezingNights => 'freezing nights, warm layers';

  @override
  String get wearSummaryRain => 'rain likely';

  @override
  String get wearHistoricalFootnote =>
      'Beyond the 16-day forecast, ranges show typical weather for these dates.';
}
