# Spec: Destination Suggestion Cards

> **WHAT & WHY only.** See `plan.md` for the technical approach.

## Context

The Plan tab's chat empty state — the first thing a traveler sees when they
open the planner with no conversation — is a grey glyph, a headline, and a row
of five identical grey pills. Three of those pills name real places ("Weekend
in Tokyo", "Amalfi Coast road trip") and sell none of them. It is the flattest
screen in a product whose whole promise is going somewhere. Showing each
suggested destination as a photo turns a list of strings into an invitation,
and does it with the card language the chat already uses for search results,
so the screen reads as part of the app rather than a new idea.

## User Stories

- As a **traveler opening the planner**, I want to see where the suggestions
  would take me, so a prompt reads as a place rather than a line of text.
- As a **traveler**, I want tapping a suggestion to start exactly the trip it
  showed me, with no surprise about what I just asked for.
- As a **Spanish-language traveler**, I want the suggestions in my language,
  with the photos unchanged.
- As a **traveler on a phone**, I want the suggestions to fit on screen
  without burying the message box.
- As a **photographer whose work is used**, I want my credit visible on the
  image, as the license requires.

## Acceptance Criteria

- [ ] With an empty conversation, the Plan tab shows three destination photo
  cards, each captioned with the suggestion it stands for.
- [ ] Each card shows a photo of ITS own destination — Positano for the Amalfi
  road trip, Tokyo for the Tokyo weekend.
- [ ] Tapping a card sends exactly the text printed on it as the traveler's
  message, and the conversation starts.
- [ ] "What's near me?" and "Import from AI chat" remain available and
  unchanged in behaviour; they are not given photos.
- [ ] The suggestions still re-draw on each fresh chat and each page load, and
  a language switch relabels the same three without reshuffling them.
- [ ] Every card carries a visible photographer + license credit, including
  when the photo fails to load.
- [ ] No shipped photo is under a share-alike or copyleft license, since a
  crop would inherit that obligation.
- [ ] A card whose photo is missing or fails to load still shows its text and
  is still tappable — no blank box, no dead card.
- [ ] On a phone-width window the cards fit two across and wrap, with nothing
  clipped and the message box still reachable.
- [ ] The home tab's hero card is unchanged: white text chips over the
  existing hero photo.

## API Surface

None. No new endpoints, no new events, no server change. The photos ship with
the app rather than being fetched, so an empty state costs no request and no
Places billing.

## Data Model

None persisted. The pairing of a suggestion prompt with its destination photo
is static app content, drawn at random per mount exactly as the prompts
already were.

## UI Behavior

- **Surface:** the agent chat's empty state only (the Plan tab, and the trip
  refine panel's chat when empty). The home hero keeps text chips — it already
  sits on a photo, and cards there would be photo-on-photo.
- **Layout:** headline and subtitle, then the three photo cards, then the
  near-me chip and the import button. The generic chat glyph is dropped: the
  photos are the visual anchor.
- **Card:** destination photo above the suggestion text, which wraps to two
  lines so longer prompts and longer locales stay readable. The photographer
  credit sits over the bottom of the photo.
- **Narrow windows:** cards shrink and wrap two-across rather than stacking
  three full-width, which would push the message box off screen.
- **Failure:** a missing image leaves a neutral placeholder with the credit
  and text intact; the card still sends its prompt.

## Out of Scope

- Live or per-city photos from a search provider — these are bundled images.
- Photos anywhere else in the app (trip detail, destination headers).
- Personalising which destinations are suggested.
- Replacing the existing home hero photo (`hero_santorini.jpg`). Its
  provenance is now recorded in `assets/images/LICENSES.md` as far as the repo
  knows it; identifying the exact Unsplash photo is left open there.

## Open Questions

None.
