# Spec: Dark Mode

> **WHAT & WHY only.** No tech choices, file names, libraries, or code.

## Context

The app is light-only: anyone planning a trip at night, or whose device is set
to dark, gets a bright white screen. Users increasingly expect apps to respect
the device's appearance preference. This feature gives the app a dark
appearance and a place to choose it — following the device by default, with an
explicit Light or Dark override for people who want the app to differ from
their device. (Two earlier specs — chat-polish and chat-quick-replies — listed
dark mode as a non-goal; this spec supersedes those lines.)

## User Stories

- As a **traveler with my device set to dark**, I want the app to come up dark
  automatically so that it matches every other app I use at night.
- As a **traveler**, I want to force Light or Dark regardless of my device so
  that the app looks the way I prefer.
- As a **returning user**, I want my appearance choice remembered on this
  device so that I don't re-pick it every visit.

## Acceptance Criteria

- [ ] Account settings shows an "Appearance" section with three options:
      Use device setting / Light / Dark. On a device that has never chosen,
      "Use device setting" is selected.
- [ ] Changing the selection restyles the app immediately — no restart, no
      page reload.
- [ ] The choice survives an app restart / browser reload on the same device.
- [ ] With "Use device setting" selected, flipping the OS appearance flips the
      app live.
- [ ] In dark mode every screen is legible: text, inputs, cards, dialogs, and
      menus render with adequate contrast — no light-on-light or
      dark-on-dark.
- [ ] Status colors (success/warning severity, verified, unread) keep their
      meaning with adequate contrast in dark.
- [ ] The trip map, hero banners, and photo overlays look the same in both
      modes (they sit over imagery and are deliberately brightness-constant).
- [ ] The new controls are labeled in both English and Spanish.

## API Surface

None. The choice is device-local; the server renders nothing themed.

## Data Model

- **Appearance choice** — one device-local stored value: follow the device,
  or force light, or force dark. Not tied to an account; not synced across
  devices.

## UI Behavior

- **Screen / surface:** Account settings → new "Appearance" section, directly
  above the Language section (both are device-presentation settings).
- **Happy path:** open Account settings → tap Dark → the whole app restyles
  immediately → reload the page → still dark.
- **States:** no loading/empty/error states — the control is instant and
  local. If device storage is unavailable, the choice still applies for the
  current session.

## Edge Cases & Error States

- A stored value this build doesn't recognize (stale or hand-edited) falls
  back to "Use device setting" — never guesses a brightness.
- Device storage unavailable (e.g. private browsing): the picked appearance
  applies for the session only, silently.
- A user who forces the opposite of their OS may see the first frame or two in
  the wrong brightness while the stored choice loads; the boot splash (a
  brand-teal surface, identical in both modes) covers this window.

## Out of Scope

- Syncing the choice to the account / across devices.
- Matching the browser chrome (`theme-color`) to the *in-app* choice — it
  follows the OS preference only.
- Changing the boot splash per appearance (it is a brand surface, correct in
  both).
- Golden tests.
- Retuning every accent/status color for dark is split into a follow-up
  (`dark-mode-tokens`); this feature ships the mode, the toggle, persistence,
  and a correct base theme.

## Open Questions

None.
