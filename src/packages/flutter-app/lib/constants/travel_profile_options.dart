/// Canonical API values for the chip rows added by specs/active-profile, plus
/// their label mappers. Values are sent to the server and read by the AI agent,
/// so they are NEVER translated — only the labels are (specs/i18n-spanish).
///
/// Shared rather than copied because all three rows appear on BOTH the Travel
/// profile screen and the signup quiz; same reasoning as
/// `interest_bank.dart`. (`_budgets`/`_paces`/`_workStyles` predate this and
/// stay duplicated in the two screens — not worth churning here.)
library;

import '../l10n/l10n.dart';

/// The training a traveler keeps while away. A constraint on where they sleep
/// and how the day opens, not a taste — tastes live in the interest bank.
/// `none` is a real answer: it tells the agent to stop raising the subject.
const fitnessRoutineOptions = ['gym', 'running', 'both', 'none'];

/// How demanding an active outing should be. Orthogonal to pace, which is how
/// MANY things happen in a day rather than how hard they are.
const outdoorIntensityOptions = ['easy', 'moderate', 'challenging'];

/// Who the traveler usually travels with. Collected by the quiz since it
/// shipped, but only stored as a real field from migration 00063 on.
const companionOptions = [
  'solo',
  'partner',
  'friends',
  'family_with_kids',
  'varies',
];

/// The biggest bag the traveler normally flies with. Unlike the rows above,
/// this one also drives a request parameter: it is the default tier every
/// flight search is priced for, so the same list backs the Travel profile, the
/// signup quiz AND the flight search screen's own chips
/// (specs/traveler-baggage). Values match the API's baggage enum exactly.
const baggageOptions = ['personal_item', 'carry_on', 'checked'];

String fitnessRoutineLabel(AppLocalizations l10n, String value) =>
    switch (value) {
      'gym' => l10n.prefsFitnessGym,
      'running' => l10n.prefsFitnessRunning,
      'both' => l10n.prefsFitnessBoth,
      'none' => l10n.prefsFitnessNone,
      _ => value,
    };

String outdoorIntensityLabel(AppLocalizations l10n, String value) =>
    switch (value) {
      'easy' => l10n.prefsOutdoorEasy,
      'moderate' => l10n.prefsOutdoorModerate,
      'challenging' => l10n.prefsOutdoorChallenging,
      _ => value,
    };

/// Reuses the flight-search keys: the profile row and the search chips are the
/// same choice, and a second set of strings for it would be a second wording to
/// keep in sync. The `flightSearch*` key names simply predate the profile field.
String baggageLabel(AppLocalizations l10n, String value) => switch (value) {
      'personal_item' => l10n.flightSearchBaggagePersonalItem,
      'carry_on' => l10n.flightSearchBaggageCarryOn,
      'checked' => l10n.flightSearchBaggageChecked,
      _ => value,
    };

String companionLabel(AppLocalizations l10n, String value) => switch (value) {
      'solo' => l10n.quizCompanionSolo,
      'partner' => l10n.quizCompanionPartner,
      'friends' => l10n.quizCompanionFriends,
      'family_with_kids' => l10n.quizCompanionFamily,
      'varies' => l10n.quizCompanionVaries,
      _ => value,
    };
