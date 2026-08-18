/// Shared layout constants for the landing page (specs/landing-redesign).
///
/// The landing page is the one marketing surface, so it gets its own content
/// tier above `PageContainer`'s 700/760/900 app tiers: wide enough for a
/// three-column feature grid, still narrow enough to read as one column of
/// content on a 1440px display.
library;

/// Max content width for landing sections (feature grid, how-it-works).
const double kLandingContentWidth = 1080;

/// Vertical rhythm between landing sections.
const double kLandingSectionGap = 64;
