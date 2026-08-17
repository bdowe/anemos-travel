# Spec: Destination Suggestion Cards

> **WHAT & WHY only.** See `plan.md` for the technical approach.

> **Revision — the cards became a carousel.** As first shipped the three
> drawn cards wrapped two-across on a phone, and this spec recorded that a
> horizontal rail was rejected because it "would hide picks behind a scroll
> the empty state gives no reason to try". That reasoning holds for a rail
> that sits still. It stops holding for one that moves itself: an
> auto-advancing carousel shows the traveler the whole pool without asking
> them to go looking for it, and it is *shorter* than the wrapped grid, so the
> message box sits higher rather than lower. The surface now cycles **all
> twelve** destinations, one full-width card at a time, shuffled per visit.
> The criteria below are updated in place; the ones about photos, credits,
> language and tap behaviour are unchanged.

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

- [ ] With an empty conversation, the Plan tab shows one destination photo
  card at a time, captioned with the suggestion it stands for, and moves on to
  the next every few seconds.
- [ ] The carousel cycles the whole pool in a fresh random order each visit,
  and comes back round rather than stopping at the last one.
- [ ] It stops advancing on its own while the Plan tab is hidden, under
  reduced-motion or a screen reader, and for good once the traveler has
  swiped it themselves.
- [ ] Each card shows a photo of ITS own destination — Positano for the Amalfi
  road trip, Tokyo for the Tokyo weekend.
- [ ] Tapping a card sends exactly the text printed on it as the traveler's
  message, and the conversation starts.
- [ ] "What's near me?" and "Import from AI chat" remain available and
  unchanged in behaviour; they are not given photos.
- [ ] The order still re-draws on each fresh chat and each page load, and a
  language switch relabels the same order without reshuffling it.
- [ ] Every card carries a visible photographer + license credit, including
  when the photo fails to load.
- [ ] No shipped photo is under a share-alike or copyleft license, since a
  crop would inherit that obligation.
- [ ] A card whose photo is missing or fails to load still shows its text and
  is still tappable — no blank box, no dead card.
- [ ] On a phone-width window the card fills the width with nothing clipped
  and the message box still reachable — and the block is no taller than the
  wrapped grid it replaced.
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
- **Layout:** headline and subtitle, then the carousel and its page dots, then
  the near-me chip and the import button. The generic chat glyph is dropped:
  the photos are the visual anchor.
- **Card:** destination photo above the suggestion text, which wraps to two
  lines so longer prompts and longer locales stay readable. The photographer
  credit sits over the bottom of the photo.
- **Carousel:** one card per page, filling the available width up to a cap so
  the photo never becomes a banner. It advances every few seconds and loops
  forwards past the last destination. It is swipeable, and a swipe ends the
  auto-advance for that visit — nothing gets pulled out from under a thumb.
  The dots show position and are not tap targets; the card is the button.
- **When it holds still:** a hidden Plan tab (the tab stays mounted, so this
  is explicit), reduced-motion or screen-reader settings, and after a swipe.
  A held-still carousel is still fully usable by hand.
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
