import 'app_nav.dart';

/// The URL grammar (specs/url-page-persistence). One table shared by both
/// halves of URL persistence — the write half formats locations with the
/// helpers below, the read half parses them with [parseBootTarget] — so the
/// two can never drift apart.
///
/// Token deep links (/share, /invite, /reset, /verify, /sso, /connect) are
/// NOT part of this grammar: generateRoute matches them before parsing, and
/// they boot bare (no shell), exactly as before.

/// Zero-argument screens that are pushed inside the shell and can be
/// reconstructed from their path alone.
enum BootUtility {
  preferences,
  account,
  adminMetrics,
  adminLocal,
  importTrip,
  logTrip,
  guides,
  notifications,
}

/// Where a URL lands after boot: a tab, plus at most one of an inner screen
/// to push (trip detail via [tripId], a utility screen via [utility]) or a
/// plan conversation to resume ([chatId]).
class BootTarget {
  final AppTab tab;
  final String? tripId;
  final String? chatId;
  final BootUtility? utility;

  const BootTarget(this.tab, {this.tripId, this.chatId, this.utility});

  @override
  bool operator ==(Object other) =>
      other is BootTarget &&
      other.tab == tab &&
      other.tripId == tripId &&
      other.chatId == chatId &&
      other.utility == utility;

  @override
  int get hashCode => Object.hash(tab, tripId, chatId, utility);

  @override
  String toString() =>
      'BootTarget(${tab.name}, tripId: $tripId, chatId: $chatId, utility: ${utility?.name})';
}

const kHomeLocation = '/';
const kPlanLocation = '/plan';
const kTripsLocation = '/trips';

String tripDetailLocation(String tripId) => '$kTripsLocation/$tripId';
String planChatLocation(String chatId) => '$kPlanLocation/$chatId';

String utilityLocation(BootUtility utility) => switch (utility) {
      BootUtility.preferences => '/preferences',
      BootUtility.account => '/account',
      BootUtility.adminMetrics => '/admin/metrics',
      BootUtility.adminLocal => '/admin/local',
      BootUtility.importTrip => '/import',
      BootUtility.logTrip => '/log-trip',
      BootUtility.guides => '/guides',
      BootUtility.notifications => '/notifications',
    };

/// The tab a utility screen is restored onto. Import and log-a-past-trip both
/// live in the trips flow; everything else hangs off Home (the account menu is
/// reachable from any tab, so restore needs one deterministic choice).
AppTab utilityTab(BootUtility utility) => switch (utility) {
      BootUtility.importTrip || BootUtility.logTrip => AppTab.trips,
      _ => AppTab.home,
    };

/// Parses a location into a [BootTarget], or null for paths this grammar
/// doesn't know (the caller falls through to the plain AuthGate catch-all,
/// leaving the URL untouched). Trailing slashes are tolerated; query strings
/// and fragments are ignored.
BootTarget? parseBootTarget(Uri uri) {
  final segments =
      uri.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
  if (segments.isEmpty) return const BootTarget(AppTab.home);

  switch (segments[0]) {
    case 'plan':
      if (segments.length == 1) return const BootTarget(AppTab.plan);
      if (segments.length == 2) {
        return BootTarget(AppTab.plan, chatId: segments[1]);
      }
    case 'trips':
      if (segments.length == 1) return const BootTarget(AppTab.trips);
      if (segments.length == 2) {
        return BootTarget(AppTab.trips, tripId: segments[1]);
      }
    // Alias: the MCP connector's create_trip links /trip/<id> (singular).
    // Never written back — the URL self-normalizes to /trips/<id>.
    case 'trip':
      if (segments.length == 2) {
        return BootTarget(AppTab.trips, tripId: segments[1]);
      }
    case 'admin':
      if (segments.length == 2 && segments[1] == 'metrics') {
        return const BootTarget(AppTab.home, utility: BootUtility.adminMetrics);
      }
      if (segments.length == 2 && segments[1] == 'local') {
        return const BootTarget(AppTab.home, utility: BootUtility.adminLocal);
      }
    default:
      if (segments.length == 1) {
        final utility = switch (segments[0]) {
          'preferences' => BootUtility.preferences,
          'account' => BootUtility.account,
          'import' => BootUtility.importTrip,
          'log-trip' => BootUtility.logTrip,
          'guides' => BootUtility.guides,
          'notifications' => BootUtility.notifications,
          _ => null,
        };
        if (utility != null) {
          return BootTarget(utilityTab(utility), utility: utility);
        }
      }
  }
  return null;
}
