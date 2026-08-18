# Spec: Auth screen split-pane redesign

> **WHAT & WHY only.** Tech decisions live in `plan.md`.

## Context

The sign-in/sign-up screen is a flat centered column on the bare app surface —
no photography, no responsiveness, no continuity with the landing page a
visitor almost always arrives from. Every competitor cluster surveyed on
Mobbin treats auth as a brand moment: the web field is unanimous on a
split-pane layout (a quiet form beside a full-height brand photograph), and
the premium mobile register is photo-first. This redesign gives the auth
screen that atmosphere while leaving the form's behavior — which carries
years of accumulated correctness (SSO gating, autofill auto-submit, handoff
flows) — completely untouched.

## User Stories

- As a **visitor arriving from the landing page**, I want the sign-in screen
  to feel like the same product — photography, the tagline, the brand's calm —
  so the transition doesn't feel like falling out of the app.
- As a **traveler on a phone**, I want the form to still be the first thing I
  can use — the photo may set the scene, but it never buries the fields.
- As a **returning user with a password manager**, I want everything about
  how the form behaves (autofill, submit, SSO buttons) to work exactly as
  before.

## Acceptance Criteria

- [ ] On wide screens (desktop-class), a full-height destination photograph
      fills the left side under the brand scrim, with the tagline set in its
      darkest corner; the sign-in form sits unchanged on the normal app
      surface to the right.
- [ ] On narrow screens tall enough to afford it, a pinned photo band with
      the scrim and tagline sits above the form; the form scrolls beneath it.
- [ ] On short viewports (small phones, keyboard open), the screen is exactly
      today's layout — no photo, nothing displaced.
- [ ] The back control is legible over the photo wherever the photo reaches
      the top edge; the language menu stays visible and legible at every
      width.
- [ ] If the photograph fails to load or is still decoding, a brand-gradient
      surface shows in its place and the tagline stays legible.
- [ ] Light and dark app themes both keep the form on their own surface; only
      the photograph area is committed-dark.
- [ ] The tagline is localized (English and Spanish).
- [ ] All existing auth behavior is unchanged: SSO button gating and order,
      autofill auto-submit, sign-in/sign-up toggle, forgot-password dialogs,
      consent gate, and every entry path into the screen. The existing test
      suite passes unmodified.

## API Surface

None — this is a Flutter-only visual change.

## Data Model

None.

## Out of Scope

- The auth siblings (reset password, verify email, SSO-error screens) keep
  their current treatment; a family-consistency pass is a possible follow-up.
- Any change to form fields, validation, copy other than the new tagline, or
  the onboarding quiz.
