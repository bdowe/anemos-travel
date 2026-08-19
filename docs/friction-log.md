# Friction log

Running log of what broke, what dragged, and what kept coming up — feeds the
build queue. Priority when picking work: **breakage > friction in features
actually used > ideas that recur across ≥2 sessions**. Tag entries `[app]`
(dogfooding the product) or `[dev]` (workflow/tooling). Newest first.

## 2026-08-19 — a push that produced no workflow run at all

- **[dev] Breakage:** wave 3's three merges (#504/#505/#506) landed 5-6 seconds
  apart and GitHub created runs for only the **first two**. Main's tip —
  `5579282`, the #506 merge — had **zero** check-runs. Prod deployed `5c5496b`
  and sat one PR behind with every check green and nothing to notice.
- **[dev] It is not the superseded case, and the recorded test says so.** Main's
  concurrency keeps the newest *pending* run, so a run for the tip would have
  cancelled #505's pending run. Instead #505's survived and ran — meaning
  nothing was superseded, a run was simply never created. The
  `gh run view --json jobs | length == 0` test for "superseded vs broken"
  structurally cannot see this: there is no run to inspect.
- **[dev] Why one missing run silently drops a PR from prod:** `build-push` tags
  images `ghcr.io/...:${{ github.sha }}` and `deploy` defaults `IMAGE_TAG` to
  the same. **A run ships its OWN commit, not main's tip.** So "the newest run
  is green" and "the tip is deployed" are different claims, and only the second
  one matters.
- **[dev] `workflow_dispatch` cannot repair it** — its `image_tag` input wants
  the SHA of a previously green main build, and `build-push` is gated
  `if: github.event_name == 'push'`, so dispatch never builds. No image exists
  for the missing SHA. The remedy is an empty commit to recreate the push event,
  pushed only after any in-flight deploy is green.
- **[dev] `gh run watch --exit-status` misreported twice in one day.** Piped to
  `tail` it returns the pipe's exit code (the `flutter test | tail` trap, again);
  unpiped it returned `1` on a run that concluded `success`, from a transient
  `api.github.com` timeout mid-watch. Read
  `gh run view <id> --json conclusion` instead — an `until status == completed`
  loop plus the conclusion is the only spelling that answered correctly.
- **[dev] Encoded in `/integrate` step 6**, now three explicit sub-steps: assert
  a run exists **for main's tip by SHA** (never by recency) → watch it and read
  the conclusion → confirm prod serves that SHA. The window is one the loop
  actively creates: merging back-to-back is exactly what it encourages.

## 2026-08-18 — /integrate charged every PR the conflict price

- **[dev] Friction:** Brian — *"I think perhaps the /integrate skill has more
  overhead than it needs."* The loop rebased **every** lane branch onto main,
  resolved per conflicted commit, ran local checks, force-pushed, and waited out
  a full CI re-run — ~10–20 min a PR — before merging. The hub table's entire
  purpose is lanes that do not touch the same files, so most of that was being
  paid for a conflict that did not exist. New shape: check
  `git merge-tree --write-tree`, and on exit 0 just `gh pr merge`. Order is now
  the order the PRs were opened, not the tasks.md dependency edges.
- **[dev] The rebase was never what armed the migration guards.** The doc
  claimed *"the rebase rerun is also what makes the duplicate-migration CI guard
  bite"*. Reading `.github/workflows/ci.yml`: the duplicate guard runs on
  `refs/pull/N/merge` — GitHub's ephemeral merge with the current main tip — and
  the out-of-order guard fetches live `origin/main` at run time. Neither needs
  the branch rebased; both need a **fresh run**. What a green badge actually
  certifies is "true as of my last run", which is a different and much smaller
  claim.
- **[dev] So exactly one thing had to survive skipping the rebase.** A competing
  migration merged since the PR's last run produces **no textual conflict**
  (different filenames), so the conflict check waves it through, and the failure
  is `goose` refusing at boot → crash-loop outage, not a red check. `/integrate`
  now runs a local migration-floor check (`git ls-tree origin/main -- migrations/
  | tail -1`) on any PR that adds one. Everything else a stale run can hide —
  cross-lane Go↔Dart drift, codegen drift — is a red check, and is deliberately
  traded to main's own CI: queue stops, fix goes forward on main.
- **[dev] `--ours` and `--theirs` invert between rebase and merge**, and nothing
  warns you. Under `git merge origin/main` on the lane branch, main is
  `--theirs`; under `git rebase origin/main`, main is `--ours`. Both spellings
  mean "take main's generated files unread"; the wrong one silently commits
  main's *stale* codegen into the lane with no conflict marker left behind.
  Verified both directions in a throwaway repo before writing either down.
- **[dev] Nothing in the repo ever required the rebase.** `main` has no branch
  protection at all (`gh api …/branches/main/protection` → 404): no required
  checks, no up-to-date-branch rule, no linear history, and main already carries
  merge bubbles from PRs merged without one. The force-push exception in
  `ship`/`integrate` is gone with it — resolving by merge is a plain push.
- **[dev] Two orderings still beat PR-open order**, both because the repair
  costs more than the rule: a stacked PR waits for its base and is retargeted to
  main first (this is how 00058 got burned), and migration-carrying PRs go in
  ascending number, since a lower number landing after a higher one is refused
  by CI and forces a renumber plus a re-run.

## 2026-08-15 — it planned the whole trip before anyone said yes

- **[app] Friction:** Brian — *"when planning a trip, sometimes it pulls the list
  of activities to do without confirming with me or asking. I feel like I just
  want to get the high level structure of the trip done first, then figure out
  the details of each day in the city later."* Two complaints in one sentence:
  no confirmation, and the wrong altitude.
- **[app] Both were literally in the prompt.** The trigger sentence read *"When
  you have gathered **enough** places for the user's trip, call create_itinerary
  to finalize the plan"* — the decision to write was the model's own, and the
  criterion was its own sense of sufficiency. `create_itinerary`'s description
  said it again: *"call this when you have identified **all** the places."* The
  only pacing line in ~9 KB of doctrine was the closer, *"ask clarifying
  questions **if needed** before **searching**"* — hedged, and about searching,
  not writing. Grep found no "structure", "outline", "high-level" or "draft"
  anywhere in the agent's instructions: **a trip's shape was not a concept the
  planner had.**
- **[app] The app already believed in confirming; the place where trips are born
  never got told.** Every seeded prompt the trip page hands the agent gates on
  the traveler — *"when I confirm a plan, call update_itinerary_section"*
  (`seedPlanItineraryEmpty`), *"propose where everything fits… and when I
  confirm"* (`seedScheduleItems`). Those are client-seeded user messages.
  `basePrompt`, which governs a fresh chat, had no such sentence. Same shape as
  the last-day bug two days earlier: the app held the belief, only the writer
  was missing.
- **[app] "Structure with no activities" turned out not to be representable, and
  that decided the design.** A trip's cities are a projection of its activity
  items — `computeTripLegs` opens `if len(items) == 0 { return nil }` and the
  Dart twin does the same — so a cities-and-dates-only trip renders a blank
  page: no cities, no date chips, no map, Bookings tab hidden, chat FAB hidden.
  A **sparse** itinerary renders perfectly, so the shape ships as a *spine*: one
  place on each city's arrival day and one on the day you move on, middles
  empty. **2N − 1 places for N cities**, and stating it as arithmetic is what
  makes it checkable rather than a habit.
- **[app] The move-on place and the arrival place do different jobs, and only one
  of them is about dates.** A city's last item day IS its departure date, and
  that same date IS the next city's arrival — so a city with nothing on the day
  you leave renders as though you left the day you arrived, and the next city
  swallows its nights. The arrival place is redundant for the dates *except on
  the last city*, which has no move-on day: without it that city has zero items,
  and a city with zero items is not a run at all — it vanishes from the trip.
  Both are pinned, including a characterization test on each side that asserts
  the WRONG output for arrival-anchors-only.
- **[app] The missing move-on place then closes the hotel slot, silently.**
  `bookingSlotClaimed` routes a fully-dated stay to `stayNightsCovered`, which
  is *documented* as **"vacuously true when from >= to"** — so a zero-night leg's
  stay counts as Closed with the checkbox visibly unchecked, and Next Step stops
  asking you to book that city, while `checkLodging` (which walks item days, not
  leg ranges) goes on warning that there is no lodging. Two systems, opposite
  answers about the same city. Nothing rendered a "0 nights" label either, and
  `RenderLeg.ZeroNight` had ridden the payload since the leg-dates work **with no
  consumer anywhere**. It has one now.
- **[app] `end_date` quietly stopped being optional.** `persistTrip` derives a
  missing end from the highest item day. On a dense itinerary that was the real
  last day; on a spine it is the FINAL city's *arrival*, so a 10-day trip saves
  as a 7-day one and a one-city spine saves as a **one-day trip** — and because
  the trip then genuinely ends early, the last-leg anchor has nothing left to
  correct against. Now refused outright, before anything persists.
- **[dev] Refuse the mechanical, report the judgement — and scope each rule to
  the failure it actually prevents.** Three refusals ship (one-sided dates, an
  undated place on a dated trip, a MIX of tagged and untagged places). A city
  whose places sit on one day is deliberately NOT refused: it is usually a
  missing move-on place and sometimes a genuine same-day stop, and no payload
  can tell them apart. The blanket version would have been draft two of the
  last-day rule, which banned museums on a departure day and was rightly
  disobeyed. Likewise the "no tools in pass 1" ban is on **place research**,
  named tool by tool — `check_flight_connectivity` before naming a city the
  traveler didn't ask for is already mandatory two paragraphs later, and an
  unscoped ban would have contradicted it.
- **[dev] Reusing `walkDayCoverage` was load-bearing, not tidy.** The tool result
  now names the days that carry nothing. Built from that function, the
  **journey-home day is structurally incapable of appearing** — it already drops
  the trip's last day ("there is nothing to plan on it") and already ignores city
  fillers. A hand-rolled `1..tripDayCount` loop would list it and the model would
  offer to fill the day you fly home: the bug fixed two days earlier, reopened
  from the other side. Mutation-checked by removing the `cov.Total--` and
  watching "days 7-8" appear.
- **[dev] For the empty-day rows, both obvious windows were wrong.** Visible
  ranges draw the previous city's departure day as unplanned under *two* cities
  and offer the journey home; raw ranges silently miss a day genuinely inside the
  stay the header advertises. The rule that works is **visible, minus the shared
  arrival day and minus the trip's last day** — the two days a visible window
  knowingly borrows. The existing Paris→Rome fixture is what caught both.
- **[dev] An empty day is not a section.** `spliceSection` rejects a selector
  that matches nothing, so `scope='day'` cannot fill a day with no items — which
  is exactly what "Plan this day" asks for. So the placeholder does NOT share the
  day sparkle's action: the sparkle refines a populated day, the placeholder
  fills an empty one with a city-scoped rewrite. The miss error also gained the
  remediation it never had, so a model that tries the wrong scope is told the
  call that works instead of improvising.
- **[dev] A seed that carries an instruction may apply it; a seed that carries
  only a gap must propose first.** Worth writing down because
  `_buildSectionSeed` gets this right for a refine and wrong for an empty trip —
  with zero items it emitted "The full itinerary:" followed by nothing, then
  "keeping unchanged places exactly as listed above", then "Start by asking what
  I want to change". An agent politely asking what to change about nothing.
- **[dev] "Refine with AI" on an itemless trip was a button that refused.** It
  was visible, enabled, and only ever fired the snack *"Add some places before
  refining with AI."* — while the Next Step card had already routed around that
  guard on purpose. The two entry points were never wrong; the callee was, so
  fixing the callee fixed both doors at once. The copy is deleted with its only
  caller.
- **[dev] What the tests can and cannot prove, said out loud in the file.** The
  fake Anthropic *scripts* the model's turns, so no test here shows the model
  withholding `create_itinerary` on turn 1. What is pinned is the server contract
  a shape turn depends on — chips, zero `done` events, zero trips, chat still
  resumable — plus the prompt sentences as text. **Model restraint is a live-run
  item**, exactly as it was for the last-day rule, whose first draft passed
  review and then produced prose contradicting its own tool call.
- **[dev] `auth_autofill_submit_test.dart` is a coin flip on a loaded machine** —
  two of three isolated runs failed here, untouched by this change. The log
  already predicted it: *"a timing test whose failure mode is 'the machine got
  busier' fails for whoever adds the next test file."* This was that file.

## 2026-08-17 — The pill now sums the chips (follow-up to the filter strip)

- **[app] Debt paid the same day it was logged.** The entry below left the
  Bookings tab pill counting booking *todos* while the new destination chips
  count *entries* (one visible checkbox each), so a confirmed record with no
  todo made the chips sum past the pill. Brian: *"reconcile the pill counts
  too."* The pill is now `bookingOverallCount` — literally the **fold of
  `bookingDestinationCounts`** — so the tab's number and the chips' numbers
  are one count split two ways; they cannot drift because there is nothing
  to drift between.
- **[app] The claimed blocker was misread.** The entry below said the pill was
  "load-bearing for `specs/next-step-cta` parity". The spec says the opposite:
  exact parity between the book-everything count and the bookings tab's
  partition is **Out of Scope** ("the trigger is exact; the count is
  motivational"). Re-read the spec section, not the summary of it, before
  declaring a constraint.
- **[app] Viewers stay un-counted, now for a stated reason.** The server
  withholds todos from viewers, so a viewer's entries are only the confirmed
  records — their pill would read "3/3, all booked" while the owner sees the
  real remainder. A partial count states a false total; no number beats a
  partial one. The existing `_bookingTodos.isEmpty` gate keeps that job.

## 2026-08-17 — The Bookings filter cost more screen than the bookings

- **[app] Friction → fixed:** *"Should these big buttons for each city be a
  dropdown instead?"* On an eight-city trip the destination filter was a `Wrap`
  of chips under a separate "Not booked yet" chip — **~5 rows of chrome before
  the first booking row**, and it grew with the trip. It is now one row at every
  width: the scope chip, a pinned **All** chip, and a horizontally scrolling
  strip. Not a dropdown, because a dropdown trades one tap per city switch for
  the same row it saves; the strip keeps the trip's shape visible.
- **[app] The old control had no visible "everything".** Clearing the filter
  meant re-tapping the already-selected chip — an affordance nothing on screen
  advertised. The All chip states the resting state, and a re-tap on a selected
  destination is now a dead gesture rather than a second, hidden way to do the
  same thing. (`MapLegChips` deliberately has no All chip: on a map a chip
  selected at rest would put the strongest treatment on "no filter". Here the
  resting state is the answer to a question the traveler asks.)
- **[app] Each chip carries its own count (`Prague · 1/2`),** so the filter
  doubles as a per-city progress read. Counts come from the same enumeration
  and the same booked-predicate the ROWS use (`bookingSlotEntries` /
  `bookingEntryBooked`, extracted for exactly this reason) — the #455 rule that
  a count answers for the rows beneath it. ~~Open debt: the Bookings tab's own
  pill still counts booking *todos*~~ — reconciled the same day (entry above):
  the pill is now the fold of the chips.
- **[dev] Two layout bugs the new widget tests caught, not the eye.** A 320px
  Spanish row at 1.3× text **overflowed by 94px**, and short of overflowing the
  pinned pair starved the strip to ~180px on a 420px body — less than one
  `Gothenburg · 0/2` chip, so it could never show a whole destination. Fix: cap
  the pinned half at 50% and scale it down inside that (the view-tabs lever).
- **[dev] Swapping a `ShaderMask` in and out re-parents the scroll view.** The
  leading fade (which stops a scrolled-under chip's `· 0/2` tail from reading as
  *All's* count) was applied only when scrolled — and inserting it rebuilt the
  `SingleChildScrollView`, dropping the `ScrollController` position, so the strip
  snapped back to the first chip the instant the fade engaged. The mask now
  stays in the tree and only its gradient changes. Caught by the
  reveal-the-selected-chip test.

## 2026-08-17 — the button named what it creates, not what it destroys

- **[app] Friction → fixed:** *"Maybe rename 'New chat' to 'Clear chat'?"* The
  refine panel header read `✨ Refining Kraków — New chat — ✕`. "New chat" names
  a creation; the button discards the trip's saved conversation, locally and
  server-side. The app already knew — the confirm dialog behind it said "This
  conversation will be cleared." The label was the last part still pretending
  otherwise, one day after #446 gave it that label.
- **[app] One key, five sites, two meanings.** `refineNewChat` also backed the
  expired and failed panels' recovery buttons, where the transcript is *already*
  gone and the button genuinely starts a new one. Renaming the key would have
  put "Clear chat" under the sentence "This conversation has expired." **A
  shared string is only a shared string while the sites share a meaning** — so
  the destructive three (header, Continue-chat ⋮, confirm button) took a new
  `refineClearChat` and the two recovery buttons kept the old one. The test that
  used to just check the expired panel now asserts the split holds.
- **[dev] Blunter copy exposed a dialog that was already lying.** In the expired
  state `hasConversation` is true via the trip's stale `refine_chat` summary, so
  tapping "New chat" raised a confirm — which as "Clear this conversation?"
  would contradict, word for word, the panel the traveler was reading. Fixed at
  the same gate #446 rewrote: `expired` is the one state that answers *no*
  despite the summary, because the server's 404 already settled it.
  Mutation-checked. **Rewording a string is a reason to re-read the condition
  that shows it** — the sharper sentence is what made the wrong state visible.

## 2026-08-17 — The chat opened too short to chat in

- **[app] Friction → fixed:** *"Clicking the chat button on mobile doesn't
  bring the chat window high enough to see."* On a phone the refine sheet
  opened at `initialChildSize: 0.45`. Inside that box the panel's header
  (~55px) and the composer (~140px) are **fixed costs**, so 45% of the body
  bought roughly **200px of transcript** — one quick-reply chip and a clipped
  bubble. The fraction was never the problem on its own; the problem is that a
  fraction was chosen without subtracting what the box already owed.
- **[app] The default was also not a resting place.** `snap: true` with no
  `snapSizes` snaps to `[minChildSize, maxChildSize]` — so `0.45` was a
  starting extent the sheet could never return to. Drag it at all and it left
  and never came back, which is why the thing felt arbitrary rather than
  merely small. It now opens at `1.0` with min `0.4`: **both** resting places
  are reachable, and the one you land in is the useful one.
- **[app] Full-height is the default, not the cage.** The itinerary is still
  behind the sheet and still one drag away, which is what kept this a
  three-number change instead of a new route. The drag strip's margin went
  `8 → 14` in the same pass: it is the **grab area**, not decoration, and at
  full extent a ~20px target pinned to the top edge of the screen is the only
  way back down.
- **[dev] A comment claimed a job the framework was already doing.** The sheet
  padded itself by `MediaQuery.viewInsets.bottom` "so the input clears the
  keyboard". `Scaffold._resizeToAvoidBottomInset` defaults **true** and passes
  `removeBottomInset` when building the body's MediaQuery, so that value is
  **always 0** in a Scaffold body — the composer was cleared by the body
  shrinking, and had been all along. Harmless while the sheet was 45% tall;
  worth checking rather than inheriting once it went full-height. Deleted.
- **[dev] Both new tests were run against the old numbers before being kept.**
  They failed at `0.409` and `0.109` — i.e. `0.45` and `0.15` each minus the
  handle strip, which is also how we know the ratios are measuring the extent
  and not something incidental. A height assertion that passes both ways is
  worth nothing.

## 2026-08-17 — "What to wear & pack" never said what to pack

- **[app] Friction → fixed:** on the 8-city Europe trip the sheet opened as
  **sixteen lines of prose** — one two-line paragraph per city, "Mild — light
  layers", "Warm — summer clothes, a light evening layer", four times over —
  and never answered the question its own title asks. The reader had to hold
  eight phrasings in their head and do the union themselves: *three of these
  say rain, so… umbrella.* The #330 fold was working correctly; the trip
  genuinely has eight distinct weather stories. **Volume was the problem, not
  a bug**, which is why the previous fix (merge same-guidance rows) couldn't
  reach it — there was nothing left to merge.
- **[app] The summary had to be the union, not a second opinion.** The
  tempting version writes a fresh trip-level phrase from the raw flags. That
  gives you two derivations of one thing, and the day the header says
  "umbrella" while no visible row says rain, nobody can tell which is wrong.
  Instead `packEssentials` iterates **`groupWearRegions`** — the exact list
  the rows render — and maps each displayed phrase to the objects it asks for.
  Every suggestion is backed by a visible row and every row contributes at
  least one suggestion, which is what makes collapsing the detail behind
  "City by city" lossless rather than lossy. Same rule that moved
  `effectiveAdvisories` widget→util in #330, one level up.
- **[app] What a row promises decides where it can hide.** The historical
  footnote ("ranges show typical weather for these dates") qualifies the
  **header's** temperature envelope as much as the rows', so putting it inside
  the collapsible would have let the numbers make a forecast claim they can't
  back, one tap away from the correction. It renders outside the disclosure
  and is pinned that way. Corollary the other direction: with one displayed
  group the detail adds only its dates — the envelope is already in the header
  — so there is no disclosure at all rather than a tap that buys nothing.
- **[dev] A "nothing is a no-op" loop is a claim you have to check per case.**
  First draft of the advisory test asserted that every `WearAdvisory` adds an
  essential *over the mild band*. `bigSwing` ("big day–night range, bring
  layers") maps to the same light layer `mild` already yields, so it failed —
  correctly. The honest form pairs each advisory with a band that does **not**
  already imply its object, and the overlap gets its own test saying so: one
  object, one row, the union is idempotent. A green universal loop here would
  have meant the table was wrong, not that the code was right.
- **[dev] A fixture keyed on a derivation restates the derivation.** The
  wear tests' weather fake keys on `'<city>|<startDate>'`, and *startDate* is
  the **visible** leg range — so a new two-city fixture with the obvious dates
  silently resolved one leg to an empty report, folded the trip to a single
  group, and failed two tests for a reason that had nothing to do with them.
  Tests about what the sheet SAYS now use a city-keyed fake; the one test that
  is genuinely about windows keeps the city|date fake and stays the only
  place that spelling appears.

## 2026-08-17 — Trip Health argued with the checklist

- **[app] Friction → fixed:** *"It says I don't have lodging booked for days
  that I do."* Trip Health read **"Mostly ready — 28 to fix"** and led with
  *"No lodging booked for the nights of Mon, Aug 24 – Fri, Aug 28 (5
  nights)"* — while two scrolls up, `Stay in Amsterdam · Aug 24 – Aug 26` and
  `Stay in Prague · Aug 26 – Aug 29` were both **ticked and struck through**.
  The app was contradicting the traveler about the traveler's own trip, on one
  screen, at the same moment.
- **[app] The divergence was designed, written down, and wrong.**
  `specs/next-step-cta/plan.md` said it outright: *"a checked checkbox with no
  accommodation row is the traveler telling us they booked elsewhere. Trip
  Health still reports the gap — that is its job, and **the two surfaces are
  allowed to differ here**."* The Next Step walk honored the tick
  (`walkBookingSlots`); `checkLodging` never read `booking_todos` at all,
  though `exportData` had been carrying them the whole time. This is the same
  shape as the 2026-08-15 entry below — *"Two answers to one question, and the
  rendering one was the lie"* — with the polarity flipped: here the **server**
  was the liar and the screen was right. **When two surfaces answer one
  question, "they're allowed to differ" is a decision with a shelf life** — it
  survives exactly until someone sees both at once. `nightCovered` is now the
  one answer to "does the traveler have a bed this night", and takes the whole
  `exportData` so a caller holding only the accommodations can't ask it.
- **[app] The same hole was one scroll further down, unreported.**
  `checkTransit` ignored booked transport to-dos identically — invisible only
  because transit findings carry no `Day` and sort to the bottom of the list.
  Fixed in the same pass; **directional**, unlike `segmentConnects`, because
  00064 made a derived leg's direction load-bearing and a booked return
  silencing the outbound would be a fresh instance of the bug. Fixing only
  what was pointed at would have re-earned the same complaint next week.
- **[app] The badge counted taste as if it were a gap.** Of the 28, one
  over-stuffed day contributed **four**: "Day 6 has 9 items planned" plus one
  row for each of morning/afternoon/evening. And the slot rule fired at *two*
  — so "Day 1 has 2 things scheduled for the evening" was the app flagging
  dinner and a bar. Now: at most one density finding per day, the slot
  threshold is 3, and every `checkDensity` finding is `info`, so scheduling
  taste lands in the collapsed Suggestions tier and the badge counts only what
  you must actually fill. **A count you can't act on isn't information, it's
  weather** — and it was sitting on the same number as five unbooked nights.
- **[dev] Two causes wore one symptom, and only one was the rule.** "Out of
  date" was also literally true: `tripReviewProvider` is non-`autoDispose` and
  `_load()` never invalidated it, so **adding a stay, editing one, deleting
  one, adding a segment, adding a place, editing or deleting an item, and
  reordering a section** all left the previous answer on screen — leaving and
  returning to the trip didn't help either. Eight callers, eight chances to
  forget; `_load()` owns the invalidation now. The near-miss: the rule fix
  alone would have made the reported screenshot correct and left the next
  mutation stale, which is how a bug comes back wearing a different hat.
- **[dev] A stable-sort test is vacuous under 32 elements.** The client
  re-sorts the attention tier by severity, and `List.sort` is not stable in
  Dart — but below length 32 it falls back to insertion sort, which is. The
  six-finding fixture passed against the *unfixed* implementation; only a
  40-finding one failed. Worth remembering whenever a test's subject is an
  ordering guarantee: **pick the fixture size that reaches the code path, not
  the size that reads nicely.**

## 2026-08-16 — daily food & drink budget

- **[dev] The tests were all green and the section still read badly.** The
  model returns the same `includes` phrase for every city — because it
  describes the *spending tier*, not the city — so printing it under each row
  was pure repetition. Nothing in 43 passing widget tests could see that; one
  screenshot of real output could. Same family as `summarizeHotels` stating
  the bag basis once in its header. **A number's explanation belongs wherever
  it stops varying.** The fix's first cut then compared the *deduped* set size
  to the city count (always false for more than one city) and the new test
  caught it on the first run — worth noting that the test written *for* the
  fix earned its keep immediately.
- **[dev] "No free API" was a design input, not an obstacle.** Two searches
  and one grep settled it: no free global currency-denominated meal-price
  feed exists, and we're on the *legacy* Places API where `price_level` is an
  ordinal 0-4 — which `hotel_search_service.go` had already refused to map
  onto money for the same reason. So the estimate is the model's and says so
  in the subtitle, and `basis: "estimate"` rides the wire so a real provider
  later is a new value rather than a silent change of meaning. Checking what
  the data *can't* do first is what kept this from becoming a paid
  subscription for one number.
- **[dev] The multiplier decision was the whole feature's honesty.** Nights,
  not days: two legs share their transition day, so per-city days bill it
  twice and the section could never reconcile with the trip's own length.
  Verified on a real trip — Lisbon 3 + Porto 4 = the trip's 7 — and the two
  numbers matched the city header chips three inches up the page, which is the
  only reason a traveler would trust either.
- **[dev] Returning nights from the server kept the god screen out of it.**
  Because the endpoint answers with city + nights + rate, `BudgetSection`
  self-fetches and `trip_detail_screen.dart` was never opened — no new props
  through 7,500 lines, and the lane contended with nothing.
- **[dev] Spanish overflowed the header by 95px** ("Sin mirar el precio" sets
  the tier dropdown's width). The planned/paid control had already answered
  this exact question by taking its own line; `Wrap` rather than `Row` so no
  text scale can bring it back.

## 2026-08-16 — the New chat button nobody could find

- **[app] It shipped, and I went looking for it anyway.** #441 put "New chat"
  in the refine panel header as an icon-only button with a tooltip. On a
  touchscreen a tooltip does not exist, `add_comment_outlined` reads as "add a
  comment", and beside the ✕ an unlabeled glyph reads as chrome. It was live in
  prod, working, for a day — and the person who wrote the spec asked for the
  feature to be built. An action whose only name is a tooltip is an
  undocumented action. Now it carries its label.
- **[app] It was also in the wrong place.** The page advertises the saved
  conversation on the Continue-chat card, so that is where you go to be rid of
  it — but the only route was to open the chat and wait out a full transcript
  restore just to throw it away. The card now carries the action itself.
- **[dev] The confirm was reading the wrong copy of the truth.** `_newChat`
  skipped its dialog when the *in-memory* transcript was empty — which is true
  on every card-path tap, because that path deliberately never hydrates. Adding
  the entry point without fixing the gate would have made one tap destroy a
  fifty-message conversation with no dialog at all. "Is there a conversation?"
  has to be answered from wherever one can exist (memory *or* the trip's
  `refine_chat` summary), never from whichever copy this code path happens to
  hold. Mutation-checked: the new test fails with the gate reverted.

## 2026-08-15 — the second half of the composer bug

- **[app] Same defect, second surface.** The Budget row fix (#435) named the
  cause: trip detail's body returns a bare `RefreshIndicator` when the chat
  panel is closed and a `Row`/`Stack` when it's open, so `Widget.canUpdate`
  fails at that slot and the whole subtree is re-inflated. `ChatPanel` lives
  *inside* that subtree — so the half-written question died on the same
  gesture, plus one the budget row never sees: **crossing 900px re-parents
  `Stack` → `Row` and wipes the composer mid-typing, with no gesture at all.**
- **[app] Closing the panel is the common case, not an edge one.** #441 gave
  the panel three ways to close (✕, Escape, back) and made all of them keep the
  transcript. What it did not do — because it never touched `chat_panel.dart` —
  is keep the sentence you were in the middle of writing. So "back doesn't lose
  my chat" shipped while back still lost the thing actually being typed.
- **[app] The attachments ride along, deliberately.** Re-picking four photos is
  worse than retyping a sentence. The cost is honest: their bytes now outlive
  the panel, bounded by the 4-per-message cap, one draft per chat, and the
  clear on send. `_processingCount` is *not* kept — the `await` it counts
  cannot outlive the State, so an image still downscaling when the panel closes
  is genuinely gone, and that's now written down rather than assumed.
- **[dev] The key had to be the conversation's identity, not a second one.**
  The obvious move was a `draftKey` prop each host passes. But `PlanNotifier`
  already carries `tripId` — null on the Agent tab, the trip in the refine
  panel — so a prop would have been a *second* name for one thing, and a host
  that got it wrong would put one chat's words in another's composer with
  nothing to catch it. Deriving it (`chatDraftKeyFor`) also left all **14**
  `chat_panel_*_test.dart` harnesses untouched: they build `PlanNotifier`
  directly, get `tripId == null`, and land in the `agent` bucket for free.
  Explicit does not always mean "add a parameter" — sometimes it means naming
  the identity that already exists.
- **[dev] Three of eight new tests were vacuous until mutation testing said
  so.** With the restore neutered, only 4 of 8 failed. Two more were fine
  (they guard clear-on-send and write-back-on-remove; each fails against *its*
  mutation). But **"two trips do not share one draft" passed with the key
  hardcoded to a constant** — because both panels were mounted, and a mounted
  panel never re-reads the draft, so a shared key was invisible. The test only
  bites if you remount the *other* panel. A test asserting isolation between
  two live widgets proves nothing about a key.

## 2026-08-15 — chat dogfooding (hotels)

- **[app] Friction → fixed: "Chat can't lookup hotel data — doesn't have it in
  its tools, it says."** It didn't. Flights, events, ferries, places, weather
  and local recs were all real-data tools; **stays alone was a link handoff** —
  `suggest_stays` returned two Airbnb/Booking search URLs and nothing else. New
  `search_hotels` returns real properties with real nightly and total rates for
  the traveler's dates (specs/hotel-search).
- **[dev] The app was asking the model for something its tools could not
  produce.** The Next Step CTA seed for "you still need a place to stay" said
  *"Suggest a few good lodging options (call suggest_stays) at a couple of
  price levels, well located for my itinerary."* `suggest_stays` cannot produce
  options, price levels, or locations — so the model either declined or
  invented. **A seed prompt is a promise about the tools; it has to be written
  against what they actually return.** Both lodging seeds now name
  `search_hotels`.
- **[dev] The tier had to become a first-class field, not an inference.** A
  no-prices result looks exactly like a priced one with the numbers left off,
  so `RatesLive` rides on the result SET and `summarizeHotels` states it in
  words plus an explicit "do not estimate a price". Inferring it from "does
  stay 0 have a price" would mislabel a priced set whose top row happened to
  lack one. Same family as the flight-price-semantics bug: **a number in a tool
  result has to arrive with what it means attached** — every rate here is
  labeled per-night AND with the party size it covers.
- **[dev] Two curls before any code, and both changed the design.** The rates
  engine *requires* `check_in_date` (a dateless call is rejected upstream), and
  Google Places returns `price_level: null` on **every** hotel. So the
  two-tier split isn't a preference — dateless questions structurally cannot be
  priced, and the cheap tier structurally cannot answer a money question. A
  third free probe found failed searches cost no quota.
- **[dev] `envInt` would have made the kill switch a lie.** It falls back on
  any non-positive value, so `SERPAPI_HOTEL_SEARCHES_PER_DAY=0` — an operator
  deliberately switching rate lookups off — would have silently meant "use the
  default 8", spending from a shared key they cannot unset because flight
  search needs it. This one knob reads the env itself, and a test pins that 0
  means zero. **A shared helper's fallback rule is part of its contract; check
  it before routing a switch through it.**

## 2026-08-15 — the chat you lose by pressing the wrong button

- **[app] Friction, recurring:** *"when editing a trip via the chat, should keep
  track of the last chat for the trip so you can go back to it. I've
  accidentally clicked the back button and had to restart a chat **several
  times**."* Recurrence rule satisfied on its own.
- **[app] One complaint, three independent causes — and only one of them was
  the back button.**
  1. **Back left the page.** The refine panel is drawn *inside* trip detail
     (`_panelOpen` is widget state, not a route) and the screen had no
     `PopScope`. On narrow it renders as a `DraggableScrollableSheet`, so it
     *looks* modal — back is the obvious gesture for dismissing it, and it threw
     away the whole page instead.
  2. **Five of the six ways back in destroyed the conversation.** Every ✨ entry
     (header chip, app-bar sparkle, per-day, per-city, Next Step) went through
     `beginSectionRefinement`, which called `reset()` first. Only the 💬 FAB
     reopened what was there — and it's hidden while the panel is open, so it
     isn't the button you associate with "the chat". Going back in through the
     button you started with is the one gesture guaranteed to wipe it.
  3. **It was never saved at all.** `persistSession` required
     `boundTripID == nil`, so a trip-bound turn wrote nothing. Even with 1 and 2
     fixed, a refresh or a deploy still lost it.
- **[app] "Nothing to resume" was a claim about the trip, not the conversation.**
  `specs/continue-where-you-left-off` put trip-bound panels out of scope because
  a refine "patches a trip in place — nothing to continue". True of the *trip*.
  The transcript is the thing with continuity, and it was the thing being
  thrown away.
- **[app] The fix: one running conversation per trip, and `UNIQUE (user_id,
  trip_id)` is that sentence.** New table `trip_refine_sessions` (00069) rather
  than a nullable `trip_id` on `plan_chat_sessions`, for a reason worth
  remembering: a refine transcript then has **no chat id anywhere**, so
  `GET /chats/{id}` and `/plan/<id>` *structurally cannot* reach it and can
  never rehydrate it into the unbound Agent tab (where the trip binding would
  silently vanish and the agent would fall back to `create_itinerary`). The
  column version needed `AND trip_id IS NULL` remembered in five places —
  resumable list, get-by-chat-id, the 60-day prune, the weekly-nudge predicate,
  and the upsert's conflict target. **Reusing `trips.chat_id` would have been
  worse than untidy: that key already owns the plan_chat_sessions row of the
  chat that CREATED the trip, so refine turns would have upserted over the
  original planning transcript.**
- **[app] Retention is the trip, not 60 days.** Plan chats are pruned when idle
  two months; a trip planned in August for next March must still have its chat
  in November. `ON DELETE CASCADE` is the entire GC story — no janitor rule.
- **[app] Appending seeds needed the stub, or the fix would have caused the next
  bug.** `_buildSectionSeed` dumps every item with coordinates and tags. Now
  that ✨ appends instead of resetting, a conversation would accumulate
  near-duplicate snapshots and the agent could not tell which is current — the
  same shape as the `update_itinerary_section` scope bugs. So each new seed
  rewrites the earlier ones' listings to a one-line "superseded" stub, **in
  place and never removing a message**, because `compactedCount` is a
  start-anchored index into `messages`. Free for the reader: labeled messages
  render as context chips and their content is never shown.
- **[app] The freshness hole the feature exposed.** A conversation you can
  resume days later is a conversation whose opening description is stale — and
  `update_itinerary_section` takes the COMPLETE list, so rebuilding from memory
  silently reverts anything changed since, including a co-planner's edits. The
  bound prompt now says earlier messages describe the itinerary AS IT WAS and
  requires `get_trip` before any edit. Which surfaced a live bug: `get_trip`
  with no `trip_id` listed `ListLatestTripsByOwner(uid)` — for a **collaborator**
  that is their own other trips and never the trip being refined. In a bound
  session it now returns that trip.
- **[dev] The back fix would have introduced a silent staleness bug.** The
  `trip_updated` → reload listener lived *inside* `TripRefinePanel`. Once back
  can close the panel mid-turn, a patch landing afterwards would never have been
  picked up and the itinerary would have sat there stale after an edit the agent
  really made. Moved to the screen. **A listener's lifetime must be at least as
  long as the thing it listens for.**
- **[dev] A test found a dead end in the error state itself.** The
  expired/failed panel body overflowed the narrow sheet by 48px, so its
  "New chat" button was unreachable — an escape hatch you cannot tap is the
  dead end it exists to escape. Now scrollable.
- **[dev] `pumpAndSettle` never settles behind a live turn.** The closed-panel
  FAB shows a progress indicator while a turn streams, so the mid-stream tests
  have to `pump()` a fixed number of frames. Also: `FilledButton.tonalIcon` is
  not found by `widgetWithText(FilledButton, …)` — the wave-20 subtype trap,
  hit again.

## 2026-08-15 — a flight link for a 1h35 train

- **[app] Friction:** planning Italy, the obvious way from Rome to Florence is
  the train, and the trip page's `Rome → Florence` row said **"Find flights"**
  and opened Google Flights. The chat pushed flights to match.
- **[app] Every rung defaulted to flight, and only the traveler could switch
  it.** The prompt fires `set_travel_mode` only when they *state or imply* a
  mode; unset means `trips.travel_mode` is NULL; the itinerary schema has no
  place to put transport at all; so `_deriveTodos` fell to
  `greek ? 'ferry' : (ground ?? 'flight')`, posted `google_flights`, and the
  server's `pickProviderLink` fallback is `links[0]` — Google Flights again.
  Five independent rungs, one answer.
- **[app] Nobody consulted geography, though the coordinates were right
  there.** Grep across both packages: the only geographic input to any mode
  decision anywhere was a hardcoded Greek name set. Every itinerary item has
  had NOT NULL lat/lng since 00003, and `computeTripLegs` already hands each
  leg a representative coordinate — used, until now, only to find a nearby
  airport.
- **[app] The trip-wide switch was the wrong shape for the question.** "We're
  driving" is a fact about a trip; "how do we get from Rome to Florence" is a
  fact about a leg. `'mixed'` — the value that literally means "the legs
  differ" — resolved to the flight default everywhere, which is the one case
  where per-leg judgement was the whole point.
- **[app] Fix: one resolver, and geography is a real rung of it.**
  `resolveLegMode` (specs/leg-transport-mode, 00068) is now the single answer,
  called by the sync, Trip Health, the model-facing echo and the new tool. It
  answers only when sure — no coordinates, an unknown region, too far, a sea
  crossing all return "no opinion", which lands on exactly the old behaviour.
  So the rule can only move a leg from wrong to right, and any miss is one tap
  from correct.
- **[app] A mode has to be storable to be honest.** A leg's mode was implicit
  in its `provider` string, where `rome2rio` means car OR train OR bus and only
  the trip-wide mode broke the tie — so `promotedSegmentMode` fell back to
  "flight" and Trip Health's fix button said "Add flight" under a row about to
  render as a train. `derived_mode` is now explicit next to `mode`, with the
  difference stated in the schema: `mode` is a **choice somebody made** and is
  preserved forever; `derived_mode` is **what the server worked out** and is
  refreshed like the link it decides.
- **[app] The row said train and still opened the flight search.** A booking
  row's tap target comes from the `_flightLegs` registry the derivation fills,
  not from the row — so relabelling it was not enough; the client has to
  re-derive against the sync response. Found by asking what the row's button
  actually reads, not by watching it render. The test for it fails the moment
  that one line is removed.
- **[app] The planner could not have fixed this, because it could never see
  it.** Nothing in any tool result told the model how the app was rendering a
  leg, so its "take the train" and the page's "Find flights" coexisted
  indefinitely. Every itinerary write now echoes each leg's mode back, and
  `set_leg_transport_mode` is the one-leg reply — the same
  make-the-wrong-guess-falsifiable move the leg-dates arc paid for.
- **[dev] Mutation-checked, five ways.** Island guard, distance threshold,
  geography rung, override handling and the client's registry refresh were each
  reverted in place and confirmed to turn the suite red — the fixture table is
  a claim about the world (real city coordinates), so it had to be shown to
  bite.
- **[dev] A pre-existing failure, baselined not chased.**
  `auth_autofill_submit_test.dart`'s burst-fill case fails on the untouched
  checkout too, and passes on a re-run — flaky, not this branch's.

## 2026-08-15 — the budget row that empties itself while you fetch the price

- **[app] Friction:** logging a flight as an expense means going and getting
  the price. Type "Flight to Amsterdam", go look it up, come back — the row is
  blank. Type it again.
- **[app] Four things unmount that row, and the flow needs at least one of
  them.** The draft lived only in `_BudgetSectionState`'s two controllers plus
  `_addCategory`. `BudgetSection` is a **conditional sliver**
  (`if (_inBudgetView)`), so any header-tab switch destroys it — and "Find
  flights" only renders on the booking rows, so getting there means leaving
  Budget. Worse, the **chat panel** (the other place to ask about flights)
  never pushed a route: the body returns a bare `RefreshIndicator` when closed
  and a `Row`/`Stack` when open, so `Widget.canUpdate` fails and the entire
  body subtree is re-inflated — on open **and** on close, and again at the
  900px docked/undocked boundary. The text was gone before the question was
  asked. The offline banner (which wraps the body in a `Column`) and any loud
  `_load()` do the same.
- **[app] The one that sounded worst was already fine.** Pushing the Find
  Flights screen is a plain `MaterialPageRoute` with `maintainState: true`, and
  top-level tab switches keep every tab mounted (`IndexedStack` +
  `TickerMode`). Both preserve everything. Worth checking before fixing: two of
  the five suspects were innocent.
- **[app] Fix: the draft is not widget state.** `expenseDraftProvider`, a
  non-autoDispose `StateNotifierProvider.family` keyed by trip — the same
  bargain `tripRefineProvider` already makes for the panel conversation, whose
  docstring says out loud that keepAlive "preserves the conversation across
  panel close/reopen". The chat transcript already survived this exact remount
  because someone hit it before; the expense row never got the same treatment.
  The category moved there too and stopped being a second copy: it was a
  *choice*, and silently resetting it to General misfiles the next expense.
- **[dev] `ref` inside `dispose()` is not a risk to weigh, it is a guaranteed
  throw.** `StatefulElement.unmount()` nulls `_widget` *before* calling
  `state.dispose()`, and every riverpod `ref` method gates on
  `context.mounted`. So "write the draft on the way out" is not an option at
  all — write-through on change is the only design. Which surfaced the next
  one:
- **[app] A shipped bug the draft made visible: `_run` invalidated through a
  dead `ref`.** `_run` awaits the POST and *then* calls
  `ref.invalidate(budget/expenses)`. Tab away mid-request — the routine case
  here, not an edge one — and both throw into `catch (_)`. The server had taken
  the expense and no client ever refetched it, so it simply did not appear.
  Fixed by capturing the `ProviderContainer` while still mounted. Pinned by a
  test that fails with `ref.` restored. **Lesson, the same one the draft
  teaches: anything that has to happen after an await cannot be reached
  through the widget that started it.**
- **[dev] A remount test needs one container, not two.** `pumpWidget` a second
  time with a fresh `ProviderScope` builds a new `ProviderContainer` and proves
  nothing — it would pass against the broken code. The section has to be
  toggled behind a conditional *inside* one scope, which is also exactly what
  `if (_inBudgetView)` does in the real screen.
- **[dev] Both non-obvious tests were checked against the un-fixed code
  first.** The "typing never rebuilds the list" test (watch the
  `LinearProgressIndicator`'s identity) and the mid-save one both fail when
  their fix is reverted. A guard test nobody has watched fail is a guard test
  nobody has tested.

## 2026-08-15 — the flight that leaves the day before it lands

- **[app] Friction:** the Amsterdam leg read `Aug 24 – Aug 26 · 2 nights` and the
  flight row under it read **`EWR → Amsterdam / Aug 24`** — but that flight
  departs Newark on the **23rd**. The day Brian actually leaves home appeared
  nowhere in the app, and the date shown was the day he lands, stored in a
  column called `depart_date`.
- **[app] The asymmetry is the bug.** For an inter-city leg (`ranges[i].end`)
  and the return leg (`ranges.last.end`), `depart_date` genuinely *is* a
  departure — you leave a city on its last day. Only the **outbound home leg**
  holds an arrival there, because there is no leg before the first city to
  supply one, so `_deriveTodos` dated it on `ranges.first.start`. The comment
  above it said so out loud and nobody read it as a lie.
- **[app] One wrong date, four wrong places.** It reached the row's text; the
  **"Find flights" link — in-app prefill *and* the server-built `search_url`,
  so the external Google Flights page opened on the wrong day**; the
  "Add details…" prefill, which handed the traveler that wrong day to confirm;
  and the Trips-list nudge *"Book transport — first leg departs Aug 24"*, which
  reads `MIN(booking_todos.depart_date)`. All four are downstream of the one
  posted value, so all four fell to fixing it at the source.
- **[app] The schema has modelled this since migration 00007 — nothing could
  write it.** `trip_segments` carries `depart_date` AND `arrive_date`, the only
  such pair in the schema, and six consumers already read it: the `.ics` export
  spans depart→arrive, the print packet prints both *and* files a
  before-the-trip departure onto its arrival day, `get_trip` tells the model
  "departs X, arrives Y", Trip Health counts both as planned days. But
  `add_transport_segment` had no `arrive_date` parameter and `AddSegmentSheet`
  had no field, so the column was reachable only by raw REST. **Same shape as
  the last-day bug the day before: the app already believed it; only the
  writers were missing.**
- **[app] The `+1` existed four times and reached nothing.** Go's `flightWindow`
  renders `out 21:55→11:30+1` into every offer line the model reads; two Flutter
  widgets draw a red `+1` on flight-search cards; `FlightOffer.arrivalDayOffset`
  is a fifth copy with zero callers. The planner was reading "+1" out loud and
  had nowhere to put it.
- **[app] Fix: the segment is the truth.** The overnight fact belongs to the
  *flight*, not the trip, so it stays on `trip_segments` and the derived row
  defers to its matched confirmed segment — the rule the screen already applies
  to a row's transport mode (*"that row's mode truth is the segment"*). That
  generalizes for free to night trains and overnight ferries, which a
  trip-level departure column would not. Row reads `Aug 23 → Aug 24` when both
  are known, **`Arrives Aug 24` when only the landing day is** — honest with
  today's data instead of asserting a departure it never had. Trip dates,
  nights, day sections and the countdown are deliberately untouched:
  `trips.start_date` is the origin every itinerary `day` counts from.
- **[app] No second matcher, no migration.** `_computeGroupedBookings` already
  claims a confirmed segment per leg, claim-once, and its slots are 1:1 with
  `visibleLegRanges` by construction — so `_deriveTodos` now reads that same
  claim result instead of growing a rival matcher. The posted payload and the
  rendered rows therefore cannot disagree. (00065 stayed free; the
  booking-shortlist lane took it.)
- **[dev] A pre-existing hole the fix would have made visible.**
  `UpdateSegment` COALESCEs each date and the PATCH handler validated only what
  the *request* carried — both present — so `PATCH {"arrive_date":"08-22"}` onto
  a row departing 08-23 was accepted and stored backwards. Harmless while
  nothing rendered it; a nonsense span once the row does. The handler now
  validates the **post-state**, reading the stored row when only one side is
  supplied. Found by writing the test, not by reading the code.
- **[dev] Two `pumpWidget` calls in one test reuse the same `State`.** The
  "Add details… disappears" test looked like a product bug for twenty minutes:
  the second pump never re-ran `_load`, so it was silently inspecting the first
  case's screen. Split into two tests. Also: a widget test that depends on the
  async preferences load resolving before first render is a coin flip — give
  the fixture trip its own `origin_airport` instead.
- **[dev] Mutation-checked, because a passing new test proves nothing.** Both
  new behaviours were reverted in place and confirmed to fail the suite: the
  arrival labelling, and the segment-wins resolver.

## 2026-08-15 — the one affordance was doing someone else's job

- **[app] Friction → fixed (specs/trip-endpoint-airports, wave 2):** "I can't
  change the starting airport manually from the trip detail page. When I try,
  it adds a new item below." The ⋮ on a derived `EWR → Amsterdam` row offered
  exactly one thing — **"Add details…"** — which opens the transport form with
  `From: EWR` prefilled **and editable**. Typing `ALB` over it looks like
  editing the leg; it POSTs a new **segment**. The page then showed
  `EWR → Amsterdam` with `ALB → Amsterdam` nested under it: two claims about
  one flight, and the airport still hadn't moved.
- **[app] The gap was written down as deferred, and came back the same day.**
  Wave 1's spec says outright: *"Out of Scope: any trip-page control for
  editing the endpoints (chat only, this wave)."* It shipped 2026-08-15 and the
  friction landed hours later. **Deferring the only UI for a thing you just
  built means the first person to look for it finds the wrong door** — and the
  wrong door here wasn't inert, it wrote something.
- **[app] A form that offers a field is claiming to own it.** The real defect
  isn't the missing control, it's that one path did two jobs. A derived leg's
  endpoints belong to the trip (its airports) or to the itinerary (its cities);
  the details form's job is carrier/date/link/price. Its From/To are now
  read-only on a derived row with a "Change airport" link, and free-form
  segments — which really do define their own endpoints — stay editable.
- **[dev] The page and the server disagreed about "is this leg covered?", and
  the page was the wrong one.** `_computeGroupedBookings` nested a segment on
  its **destination alone**, which is why `ALB → Amsterdam` tucked itself under
  the EWR leg and read as handled — while `todoClaimed` (trip_review.go), which
  has always required **both** ends, went on counting that flight as an
  unbooked gap in Trip Health. Two answers to one question, and the *rendering*
  one was the lie. The Dart side is now a twin of the Go rule with the same
  fixture table on both sides. Lesson: when a screen answers a question the
  server also answers, the screen's version is the one that gets believed —
  because it is the one people can see.
- **[dev] The paired CHECK had to be restated on the wire.** `columns()` copies
  one airport onto the other when only one is given (that is what makes "we're
  flying out of ALB" set both). Harmless for a chat sentence; wrong for an HTTP
  body, where "change the outbound" would have silently rewritten the leg home.
  The endpoint 400s a one-sided body instead. **A convenience default written
  for one caller becomes a trap for the second one** — the paired invariant is
  in the database, so it belongs on the wire too, not in a caller's memory.
- **[dev] Extract before the second caller, not after.** The tool's write moved
  out to `applyTripEndpoints` before the handler was written, so the handler
  could only ever call it. The parity test
  (`TestPageAndChatWriteTheSameEndpoints`) exists because 00064 was written
  after exactly this class of drift.

## 2026-08-15 — the planner booked the day you fly home

- **[app] Friction → fixed:** an Amsterdam leg reading `Aug 23 – Aug 25 · 2
  nights` had **Rijksmuseum, Anne Frank House and Door 74 on Tue Aug 25** — the
  day you leave — while **Mon Aug 24, the one genuinely free day, was empty.**
  The plan inverted the good day and the travel day. Brian: "generally we
  shouldn't recommend activities on the last day", then the sharper version
  that became the design: **"should ideally depend on the time of the departing
  flight."**
- **[app] The app already believed it. Nobody told the planner.**
  `trip_review.go:293` is literally `cov.Total--  // drop the departure day`,
  under a comment reading *"PLANNABLE days are the span minus its last day,
  which is the day you leave — there is nothing to plan on it"*; the
  return-home transport to-do is already dated on `ranges.last.end`; and
  `update_itinerary_section`'s result has long told the model *"a city's LAST
  item day is its departure day"* — **but only on a refine turn, never at
  create_itinerary**, which is where itineraries are actually born. Trip Health
  and the planner had opposite beliefs about the same day for months.
- **[app] The model could not have obeyed a flight-time rule anyway.**
  `FlightOffer` has carried `DepartTime`/`ArriveTime` from both providers all
  along — and `summarizeOffers`, the ONLY flight text the model ever reads,
  rendered airline/price/stops/duration and **dropped them**. Straight after a
  flight search the planner could not tell a 06:00 departure from a 22:00 one;
  it knew the leg was `4h35m` and nothing about when it left. Fixed there
  first — the rule is worthless without the input.
- **[app] "Don't plan the last day" would have silently rewritten every leg.**
  A leg's rendered end date IS its max item day (`leg_ranges.dart`), and trip
  `end_date` falls out of `maxDay` when the agent omits it
  (`trip_handler.go:432`). So the naive fix turns `Aug 23 – Aug 25 · 2 nights`
  into `Aug 23 – Aug 24 · 1 night` and drags the return-flight to-do back a
  day. The load-bearing half of this change is therefore a **last-leg trip-end
  anchor — the exact mirror of the first-leg trip-start anchor that has always
  sat three lines above it**: the traveler is in the final city until the day
  they go home, and that day now holds nothing. It runs after the arrival chain
  and skips a collapsed leg (stretching a zero-night stop would invent the very
  nights the squeeze says are gone — the existing cascade test caught that on
  the first run).
- **[app] It was a latent bug already.** Any trip whose last city's items
  stopped before `end_date` has been under-rendering its final leg. A one-city
  3-day fixture in the suite was pinned at `Jun 10 – Jun 11 · 1 night` on a
  trip ending Jun 12 — the missing day was in the expectations, not just the
  code.
- **[dev] Deleting a twin beat fixing one, again.** `plan_leg_dates.go` had a
  third implementation of the arrival rule (`visibleLegDisplayRange`) whose
  only consumer was the one sentence promising *"the trip page shows this leg
  as X"* — and no test referenced it. It is gone; that sentence now reads
  `computeTripLegs`. The item-day twins beside it stay on purpose: the
  renumbering math needs "a leg ends on its last item day", which is exactly
  what the page no longer means. Same lesson as `groupRanges` last week —
  anything speaking about the dates on screen derives from the dates on screen.
- **[dev] The first prompt draft got a split decision, and the model was right
  the second time.** Draft one produced *"Aug 25 is the last day — I'll keep it
  light"* and then booked the Stedelijk Museum plus a cocktail bar there, while
  its own prose claimed it had "left the afternoon open". Cause: the
  unknown-time case was buried behind the time-window table, so the model
  averaged the two. Putting **"unless you know when they leave, put NOTHING on
  it"** first fixed it outright — Aug 25 empty, days 1–2 *denser* (4 and 5
  items), and the reply offering to fill it in once it knows the time.
- **[dev] Over-broad rules get ignored, and deserve to be.** Draft two also
  banned museums on the last day outright; told about a 9pm flight, the model
  scheduled the Van Gogh Museum that morning anyway and explained it would
  "leave for the airport around 6pm". It was right — a 10-hour window is a real
  day. The constraint is now proportional: one easy skippable place when the
  window is a sliver, plan normally when the whole day is open. **The live run
  was what found this; no test would have.**

## 2026-08-14 — screen transitions replaying (two correct commits, colliding)

- **[app] Breakage → fixed (#421, stack resets land instantly):** Brian —
  "Sometimes screen transitions are a bit buggy. Old screen scrolls in for a
  half second then scrolls out." Both numbers were literal. We set no
  `pageTransitionsTheme`, so on macOS — what Flutter web reports for Chrome on
  a Mac — a push is `CupertinoPageTransitionsBuilder`: a horizontal slide
  ("scrolls") of exactly **500 ms** ("half a second"). Cause was two commits
  that are each right on their own. `2e537c1` froze hidden tabs' tickers for
  scroll perf; #331 made nav buttons land on the page they name by having
  `selectTab` `popUntil` the **destination** tab before flipping to it. A
  nested `Navigator` is the vsync for its own route transitions and sits
  *inside* that `TickerMode` — so the pop never advanced. The exiting page
  parked fully painted and played its whole 500 ms exit the instant the
  `IndexedStack` revealed the tab. Not a race: deterministic, every time.
  "Sometimes" only meant "when that tab had something on its stack".
  **A stack reset, or a jump that also switches tabs, is bookkeeping — not a
  gesture.** Those now land instantly (`removeRoute`, which is immediate, so
  there is nothing left to freeze); only in-page pushes/pops and a deliberate
  re-tap of the active tab animate. The `TickerMode` comment now carries the
  trap, because that is what the next reader hits first.
- **[dev] `pumpAndSettle` pumps straight past the artifact.** Every existing
  test covering this path was green throughout, because settling runs the
  bogus transition to completion and then asserts on the end state — which was
  always correct. The bug lived entirely in the frames in between. Probe a
  **single `tester.pump()`** when the complaint is about motion. Same shape as
  the "the animation was the bug" entry below: twice now, the defect has been
  something only a mid-flight assertion could see.
- **[dev] A green test that cannot fail is worse than no test.** The follow-up
  double-tap guard came with the obvious test — double-tap a trip card, assert
  one detail screen. It passed. Then it passed with the fix **removed**, which
  is the only reason we know it was worthless: Flutter's own
  `Navigator._cancelActivePointers` absorbs the second pointer when a route
  changes between frames, so the framework was doing the work and the test was
  taking the credit. (`tester.tap` even warns the hit missed — worth reading
  those warnings instead of scrolling past them.) Deleted it and rewrote around
  what the framework explicitly does *not* cover — its own source comment reads
  "This mechanism is far from perfect" (flutter#4770) — a push **after an
  await**, which is a real path here: `connect_app._signIn` saves the pending
  request, awaits, then pushes, and a second call would wipe the token the
  first one just saved. **Habit worth keeping: revert the fix and re-run before
  believing a new test.** Every assertion in #421 was checked that way, and
  each failed with the symptom it claims.
- **[dev] Second trap in the same test: an opaque route hides the duplicate.**
  `Overlay` does not build entries below an opaque one, so two stacked copies
  of a screen look exactly like one — `findsOneWidget` passes either way. Pop
  once and assert the destination is **gone**.
- **[dev] To claim "no animation played", first prove the camera can see one.**
  Browser-verifying the fix meant screenshotting right after a tap and finding
  a clean screen — which proves nothing if the harness is simply slower than
  the transition. Control: shoot an ordinary push and an ordinary back-pop in
  the same session and catch both mid-slide. Only then does the clean frame
  mean anything.
- **[dev] The integrator was working from a stale head SHA, and it would have
  eaten half the PR.** It held a snapshot from before the second commit: saw
  the worktree "dirty", and had the PR head as commit 1 of 2. Rebasing from
  that SHA drops the entire second commit and its tests, and leaves a green PR
  to show for it. Caught by answering with a freshly-read
  `gh pr view --json headRefOid` rather than agreeing from memory. **Between
  sessions, a SHA anyone is quoting from recall is a guess — re-read it.**
  Second time this rule has paid out (see the branch-cleanup entry).

## 2026-08-14 — the map strip's "All" chip (emphasis pointed the wrong way)

- **[app] Friction → fixed (All chip retired, contextual reset):** Brian on the
  map strip — "All should be styled/emphasized differently. Maybe even remove it
  and have it just be the reset button? Reset only appears when there is
  something to reset." The underlying defect was sharper than styling. `All`'s
  value is `null`, and `null` is the resting state, so `isSelected` was true for
  `All` whenever you were **not** filtering: the strongest treatment on the map
  — white ring, w700, darkest fill — sat permanently on *"no filter applied"*,
  while the destinations, the only actionable things in the strip, stayed
  recessive. On top of that `All` was drawn in the exact visual language of a
  city, so it read as a place called "All". **A city is a choice among many; the
  overview is the absence of a choice — they must not share a costume.** The
  chip is gone; at rest nothing is ringed and the ring finally means one thing.
  The way back is a round `MapControlButton` that exists only while a leg is
  focused, in the map's own frosted-circle vocabulary so it can never be
  mistaken for a destination. One widget, three surfaces (inline card,
  full-screen, shared), zero call-site edits. `tripFilterAll` had exactly one
  consumer left and went with it — the comment claiming the trip-detail filter
  menu shared the key was stale since #359.
- **[app] Deliberately NOT a second way out.** Re-tapping the focused chip still
  re-fires the combined gesture (re-expand that city's group, rest its header
  under the pinned chrome on desktop), which is useful on its own. One exit, one
  meaning.
- **[dev] The animation was the bug, and a test caught it.** First cut animated
  the reset slot open with `AnimatedSize` (the sso_buttons pattern). The
  strip-reveal test went red: `_revealSelected` runs post-frame and measures the
  viewport **as it stands**, so with the viewport still mid-resize the
  preselected chip landed 44px — exactly one button — outside the strip. The
  fix was not to coordinate the animations but to delete the animation:
  **reserve the slot's width always.** That also killed a defect nobody had
  filed yet — an appearing slot shoves the whole strip sideways on every chip
  tap. Cost is one button of empty map at rest; bought a strip that never moves.
- **[app] The glyph collision only existed in the browser.** Shipped as
  `Icons.close`, and every test was green — but the full-screen map carries a
  `CloseButton` ✕ in its app bar **directly above** this slot, so focusing a leg
  produced two white ✕s stacked 40px apart, one closing the map and one clearing
  the focus. Worse than the thing being fixed, and invisible to a widget test
  that never renders the two together. Now `Icons.public` — a globe depicts what
  you get back. Not a zoom glyph either: the bottom-right column's "Reset map"
  is `Icons.zoom_in_map` and means something else (refit the camera over
  whatever is already shown). Pinned by a test that asserts the icon is none of
  those three. **Lesson: a control's meaning is set by its neighbours, and its
  neighbours only exist on screen.**
- **[dev] Regenerating l10n from a lane worktree can silently un-format it.**
  The lane's Docker flutter container rewrites
  `.dart_tool/package_config.json` with in-container paths, so host `dart
  format` can't resolve `flutter_lints` and `flutter gen-l10n`'s format step
  crashes **after** writing the files — leaving a ~600-line reformatting diff on
  a hub file. Fix: `flutter pub get` on the host first, then regenerate. Check
  the generated diff is scoped before committing, every time.
- **[app] Second half of the same defect: two chips carrying the identical
  label.** A trip that revisits a city rendered `Fira … Fira` — run keys differ,
  labels don't, so nothing on screen said which stay a tap would focus. Same
  disease as the All chip: a chip that can't be told from its neighbour isn't
  identifying anything. Repeated labels — **and only repeated ones**, so the
  ordinary trip keeps bare city names on a narrow strip — now carry a
  qualifier: the leg's start date, `Fira · Sep 2` / `Fira · Sep 8`, one weight
  down so the row still scans as place names. Built in ONE place
  (`mapLegChipEntries`), replacing the two hand-rolled chip-label loops in the
  detail derivation and the shared view.
  - **The date is the VISIBLE range, never the raw one** (leg_ranges.dart
    doctrine — a chip that names a date promises something about dates on
    screen). It shows Sep 2, not Sep 3, precisely because Athens's header above
    it ends Sep 2 and Fira renders from its arrival. A raw-range chip would
    have disagreed with the header two rows below it — the events-rail bug,
    re-run.
  - It degrades to `Visit 1` / `Visit 2` when dates can't do the job, and that
    is a **whole-strip mode, not a per-chip special case**: an undated trip has
    null ranges for every leg (the allocation is all-or-nothing off
    `trip.startDate`), and a dense itinerary can collapse two runs onto one
    day. A repeated date disambiguates nothing, so it must not be shown as if
    it did; a partially-dated repeat set falls back wholesale rather than
    putting a date beside a number.
  - The qualifier is deliberately NOT baked into the label: `tripNoPlacesInLeg`
    speaks the label in a sentence and must keep saying "No places pinned in
    Fira", not "…in Fira · Sep 2".
  - The shared view keeps its own wording for the unresolved run — it says
    "Places" where trip detail says "Other places" — so the label mapper is
    injectable. Passing the default would have put a chip reading "Other
    places" directly above a header reading "Places".
- **[dev] A new test FILE can turn a wall-clock test red.** Adding
  `map_leg_chip_entries_test.dart` pushed `auth_autofill_submit_test.dart`'s
  "keystroke-simulated burst fill" into failing — deterministically, in the
  full run, green in isolation and green at `--concurrency=1`. Cause: that test
  paid a `tester.runAsync` round trip **per character** (each tears down and
  restores the fake-async zone) to sit "well inside" a 400ms burst window the
  production heuristic measures with a real `DateTime.now()`. More parallel
  load → slower host → 13 characters exceed 400ms → the heuristic correctly
  reads human typing. The delays are now gone (event COUNT was always the
  point, not the gaps). The companion "slow per-char typing does not
  auto-submit" test keeps its real delays on purpose: load only ever pushes
  that one further into passing. **A timing test whose failure mode is "the
  machine got busier" fails for whoever adds the next test file.**

## 2026-08-14 — events on the trip page (overwhelming, and asking the wrong dates)

- **[app] Friction → fixed (specs/events-rail):** a 3-night Berlin leg whose
  whole plan was two rows carried **five full-width event cards** under them —
  ~470px of listings under ~120px of plan, repeated for every city on an
  8-stop trip. Suggestions were rendered with the exact weight of committed
  plan rows, and the header never said how many existed, so five read as "all
  of them" when the client already held up to 30. Now one fixed-height poster
  rail (~196px) reusing the widget the plan chat already uses for these same
  events — `PlacePhotoStrip` + `PlaceCardData.event` — with a counted header
  and a "See all" sheet. Trip detail had been the second, poorer
  implementation of the same card system: it threw away the Ticketmaster
  poster and re-drew the data as text.
- **[app] BREAKAGE underneath it — the section was asking about the wrong
  dates, and the screenshot was the proof.** All five events fell on Fri Sep 4,
  the day he *leaves* Berlin, while the leg header above them read
  "Sep 1 – Sep 4 · 3 nights". Not clustering — the lookup had only asked about
  Sep 4. Reproduced exactly against the live API: the five cards, in order,
  with the same times and venues, come back from
  `start_date=end_date=2026-09-04`; the header's own window returns **14
  events spread 2/3/2/7 across all four days**. (Tell: the same Cirque du
  Soleil run is Sep 3 18:30 in the wide query and Sep 4 16:00 in the narrow
  one — dedupe-by-name keeps the earliest in window.) Cause: the header
  renders `visibleLegRanges` while the events and weather lookups read
  `rawLegRanges` via a label-keyed `groupRanges` map. Berlin's one day-tagged
  item collapsed its RAW range to a single day. **A section that promises
  "while you're here" has to derive from the dates on screen** — anything else
  is two derivations of "when am I in this city" with the user-facing one
  reading the wrong copy, the leg-dates lesson again (docs/zen.md).
- **[app] The same map was silently double-keyed.** `groupRanges` was keyed by
  city LABEL, last-wins, so a revisited city (Fira → Naxos → Fira) rendered two
  identical sections, both on the second visit's window. Everything else on the
  screen keys on the run key. Fixed by **deleting** `groupRanges` rather than
  re-keying it: it was a third parallel window shape with two consumers and
  zero test references, and `visibleRanges` is already index-aligned with the
  groups. Deleting a derivation beats fixing one.
- **[app] A fix that pays twice.** `_legClothingRecs` had the identical
  raw-query/visible-display split — the wear sheet showed dates it had not
  asked about. Moving it too restores query sharing: the sheet and the city
  group now build byte-identical `WeatherQuery`s and the provider family
  dedups, instead of issuing two windows per city.
- **[dev] A day-spread shortlist is not a substitute for the right window.**
  The first diagnosis was "the picks cluster, spread them across the stay", and
  it was wrong about the cause — with a one-day window there is nothing to
  spread. Both shipped (the round-robin matters the moment a real four-day
  window is busy on day one; a plain `take(5)` over the real Berlin data shows
  Sep 1–2 and nothing else), but **the premise got checked with one curl before
  the copy was written**, and that curl is what found the real bug. When a
  symptom implies something implausible about upstream data — "zero events in
  Berlin on three consecutive days" — go look before designing around it.
- **[app] The planner was telling people their events were saved.**
  `summarizeEvents` closed with "the full list is saved with their trip".
  Nothing persists events; no itinerary item can even hold one
  (`allowedItemCategories` is `{attraction, restaurant}`). `summarizeOffers`
  had this exact false claim killed and pinned; `summarizeEvents` was missed.
  Now pinned too.

## 2026-08-14 — the 00058 migration gap (latent prod outage, defused)

- **[dev] BREAKAGE latent in main → fixed before it fired.** The 00058 gap
  was not a stale reservation — it was a **loaded gun**. `db.go` calls
  `goose.Up` with no `WithAllowMissing`, so goose refuses any unapplied
  version below the DB's max (`found N missing migrations before current
  version 60`), and `main.go` escalates that to `log.Fatalf`. Reproduced
  end-to-end against a prod-shaped throwaway Postgres: the API **exits ~25ms
  into boot, never binds :8080**, and under `restart: unless-stopped` with the
  old container already replaced it crash-loops — a full API outage that the
  deploy only reports ~5 minutes later, with no auto-rollback. Merging
  *anything* numbered 00058 would have done this.
- **[dev] The scariest part: every existing check passed.** "Migrations apply
  from zero" runs against an empty database where 58 sorts happily between 57
  and 59 (verified: `OK 00058_…`, exit 0), and the duplicate guard finds no
  collision because filling a gap collides with nothing. A doomed PR would
  have gone green and died on deploy. Fixed by an **out-of-order guard** in the
  same CI job: every migration a branch adds must sort strictly above main's
  highest. Rejected the alternative of enabling `WithAllowMissing` — that
  swaps one loud, zero-damage crash for silent order-dependent schema state
  repo-wide.
- **[dev] Root cause — a stacked PR merged into a base that no longer
  existed.** PR #350 (`budget-v2-autopopulate`) was merged into branch
  `budget-v2` at 17:14Z on 08-13, **47 minutes after `budget-v2` itself merged
  to main** at 16:27Z. GitHub shows #350 as MERGED, but its merge commit
  `c16939c` is not an ancestor of main and the feature is absent from main
  (`git grep source_kind` → nothing). ~1,357 lines of finished work — the
  expense↔booking link, its migration, and 509 lines of Flutter tests — have
  been sitting in `origin/budget-v2` unnoticed for a day. **A MERGED badge is
  not evidence the code is on main**; when a stacked PR's base merges first,
  retarget the child before merging and verify with
  `git merge-base --is-ancestor <merge-commit> origin/main`.
- **[dev] Writing a guard is not the same as having one.** The first draft of
  the CI guard read `git ls-tree … -- src/packages/api/migrations/` from a job
  whose `working-directory` is already `src/packages/api`, so the pathspec
  matched nothing, `main_max` came back empty, and it **passed every case
  including the one it existed to catch**. Caught only by testing it against a
  deliberately-bad tree. A guard now fails closed when it cannot read main,
  and it is exercised across four cases (no-op / gap-fill / correct next /
  equal-to-max) under real `bash` — the local shell is zsh, which does not
  word-split unquoted expansions and quietly hid a loop bug.

## 2026-08-14 — notification-center dogfooding (no way to clear)

- **[app] Friction → fixed (Clear all + 45-day retention,
  specs/clear-notifications):** the notification center was a wall of stale
  "System degraded · backups stale" cards with no way to remove any of them —
  the server had list / mark-all-read / unread-count and **no DELETE query
  anywhere**, so rows lived forever while the hourly janitor pruned sessions,
  stale chats and health samples but never notifications. (The ops stream
  repeats by design: `healthMonitor.lastReasons` is in-memory, so every deploy
  restart re-fires a standing reason, and a reason-set flip never yields a
  recovery — PR #367 made those cards readable and deliberately deferred
  clearing.) Fixed with the missing removal half of the lifecycle: `DELETE
  /api/v1/notifications` (user-scoped, **idempotent 204** — clear-all names no
  resource, so unlike `deleteChatSessionHandler` there is no 404 case) behind
  an app-bar ⋮ + confirm dialog (the trip-delete destructive convention), plus
  a fourth janitor prune. Retention keys on **`read_at`, not `created_at`** —
  "anything you've seen sticks around ~6 more weeks" is a guarantee
  expressible to a user — and `read_at IS NOT NULL` makes "unread never
  expires" structural rather than conventional. Hard delete, **no migration**,
  which also kept the lane clear of the contested 00058 slot (that slot turned
  out to be un-mergeable, not merely reserved — see the 08-14 migration entry
  below; always derive the next number from
  `ls src/packages/api/migrations | tail -1`).
- **[dev] BREAKAGE (self-inflicted, caught before merge): a proxy check
  can confirm the absence of the very thing it was meant to prove.** I
  verified a revert-restore with `grep -c maybeWhen` — which matched the word
  inside the *comment* I had just written above the code, so a silently failed
  `cp` (aliased to `-i`, sitting on a prompt) read as success and the buggy
  line survived into two later test runs. Twice more the same shape: a
  backgrounded `flutter test` exited **0** printing "Test directory not
  found" because the shell cwd had reset to the repo root. Lessons: grep the
  **code line** (`grep -n 'final hasRows' -A1`), never a token that also
  appears in prose; use `/bin/cp -f` in scripted restores; and treat a green
  test run with no `All tests passed` line as a failed run, not a quiet one.
- **[dev] A regression test that passes both ways is not a test.** The first
  version of the menu-visibility test leaned on incidental settle ordering
  (initState's mark-read invalidate racing the first fetch), so a reviewer
  could argue it passed vacuously — and one did. Rewritten to assert the
  precondition (menu visible over real `AsyncData` rows) and *then* drive an
  explicit `ProviderScope.containerOf(...).invalidate(...)` against a
  `failNextList` fake. **Prove a regression test by reverting the fix and
  watching it fail**, not by watching it go green.
- **[dev] An agent-review workflow that reports `<failures>` is reporting
  nothing.** The first review run hit a model spend limit: 6 of 8 agents died,
  every verifier among them, and the workflow returned a clean
  `{confirmed: [], refuted: []}` — an empty verdict that reads exactly like a
  pass. The findings existed; they were dropped when their verifiers errored.
  Same trap as the 2026-08-01 PR #260 entry. **Read `journal.jsonl` before
  believing an empty result**, and resume (`resumeFromRunId`) instead of
  trusting the summary. On resume, two lenses (Go correctness, adversarial
  edge cases) still died on the limit; that coverage was replaced by a manual
  read of the ~50-line Go diff and is recorded here rather than papered over.
- **[app] Known debt, deliberately not fixed here:** a failed clear shows
  `errorGeneric` for HTTP-status failures (401/429/503) because the service
  throws a bare `Exception` and `friendlyError` only classifies
  `ApiException`/`AuthException`/`ClientException`. Reviewed and **refuted as
  a merge blocker**: bare-`Exception` + `friendlyError` is the dominant house
  convention (~82 sites vs 20), the offline case already resolves to
  `errorNetwork`, and surfacing the raw server string would violate the
  deliberately-unlocalized `writeJSONError` doctrine (`i18n.go`). The real fix
  is an app-wide move to `ApiException` with machine-readable codes.

## 2026-08-13 — plan-chat dogfooding (working-indicator arc leftovers, #370)

Open gaps found while fixing "chat doesn't clearly indicate it's loading"
(specs/chat-working-indicator, PR #370) and deliberately left out of that lane:

- **[app] OPEN — composer loses its only in-flight cue while typing:** the
  stop button shows only while the composer is empty
  (`showStop = isStreaming && composerEmpty && !draftAttachments`), so typing
  a queue-ahead follow-up flips it back to Send; if the tail is also scrolled
  away there is then zero on-screen evidence a turn is running. Candidate: a
  small spinner beside the composer (or in the input border) tied to
  isStreaming alone.
- **[app] OPEN — no app-level busy cue when the refine panel is closed
  mid-stream:** closing the trip-detail refine dock (or collapsing the narrow
  sheet to its 0.15 min extent) hides the chat while the turn keeps running —
  the FAB is a static chat icon with no busy state, and nothing else in the
  app watches isStreaming.
- **[app] OPEN — a silently dropped stream is indistinguishable from
  success:** /plan has no end-of-turn event. The `done` event is not one
  despite the name — `create_itinerary` alone emits it
  (`plan_tool_registry.go`, handled as "itinerary ready" in
  `plan_provider.dart`), so a plain conversational turn ends by the socket
  simply closing. A socket that dies without an `error` frame therefore exits
  the client loop normally and commits the partial reply as if finished
  (relevant for 15–45s flight searches behind proxy idle timeouts). Wants a
  `turn_done`-style terminator — a NEW event, since `done` is spoken for —
  plus client stall detection, and pairs with the SDK's silent MaxRetries=2
  re-issues, which can stretch the quiet window further.
- **[app] FIXED (specs/hotel-search) — `stays`/`transport` SSE events were
  dropped by the client:** `suggest_stays` / `suggest_transport` emitted side
  events with no case in the provider switch, so those tools produced a chip
  that vanished with no result artifact at all. Both now land as
  `SourceLinksCard` chips that actually open the links — a `ResultSummaryChip`
  would have been wrong here, because it opens the trip and these links ARE
  the result.

## 2026-08-13 — trip-detail dogfooding (Bookings tab counter → pill)

- **[app] Friction → fixed (counter styling unified):** with the wear/pack
  checked-count now a StatusPill in its sheet header, the Bookings tab's
  inline "Bookings · 0/3" label was the last count not wearing the shared
  pill chrome. The count moved out of the label into a `StatusPill.custom`
  beside it (same surfaceContainerHighest/onSurfaceVariant pair as the
  wear-sheet and checklist headers; `_headerTab` grew a `trailing` slot
  inside the underlined region so the underline spans label + pill). On
  **narrow** the pill is dropped entirely — the tab trio + counter was
  exactly what pushed the FittedBox into visible scale-down at phone
  widths (the narrow-header test's documented tripwire), and the count is
  one tap away inside the view. `tripTabBookingsCounted` deleted from
  both ARBs (dead key).

## 2026-08-13 — trip-detail dogfooding (expanded groups + navigable map)

- **[app] Friction → fixed (decoupled expansion, supersedes the 08-1x
  "accordion city focus" contract):** the single-open accordion didn't
  survive daily use either — landing on a trip showed a wall of collapsed
  headers, and because the open group WAS the map selection, every list
  action moved the camera and vice versa. Third iteration of this contract
  (08-11 partial coupling → accordion full coupling → now full
  DEcoupling), and this one is directional: **expansion is list-only
  state; focus is map-only state; the map's region pins are how the map
  drives the list.** Concretely: all city groups land EXPANDED
  (`_collapsedGroups`, inverted like `_collapsedDays` — empty set = the
  default, so new cities from a refine arrive open and keys staled by a
  lens switch fail safe as expanded); a header tap toggles only its own
  group and never touches the map; `_focusedLegKey` survives as
  notifier-only map state (chips, camera fit, per-leg pin filtering) with
  one slim writer (`_setMapFocus`); chip taps keep the combined gesture
  (focus map + un-collapse + desktop rest-under-chrome scroll) while the
  All chip resets the map ONLY; and destination pins on the All overview
  became navigation — tap scrolls the list to that region's group, with
  deliberately NO focus write (focusing would swap the overview to
  per-item pins and delete the very pin under the pointer). In the
  full-screen map a region-pin tap focuses that city in place (the
  chip-equivalent — there's no list to scroll), and the report-back now
  pre-scrolls the list on phones too, so closing the modal lands on the
  region. The accordion machinery went with the contract: the derived
  `_openGroupKey`, the reveal-only `_unfocusedOpenLegKey` hatch, the
  sole-group seed, and the one-writer assert are all deleted. N groups now
  pin N city headers concurrently — safe because each group's containing
  `MultiSliver` pushes its own header off at the group's end
  (contacts-style handoff; verified against sliver_tools 0.2.12 source):
  the OUTER groups `MultiSliver` must stay non-containing or every header
  would pin to the itinerary's end and stack. The zero-body pinned-header
  rule below (2026-08-0x entry) still governs collapsed rows verbatim.

## 2026-08-13 — trip-detail dogfooding (wear & pack → app-bar icon)

- **[app] Friction → fixed (packing dropdown → app-bar icon + sheet):**
  "What to wear and pack shouldn't be a separate dropdown" — with health in
  the app bar and Budget a header tab, the lone collapsed row at the page
  tail read as leftover chrome. It followed health's exact path: an
  **app-bar luggage icon** (right of health, every breakpoint, still there
  in the Budget view) opening a **bottom-sheet modal**
  (`showWearPackSheet`); the trailing-cluster scaffolding
  (`_sectionCluster`/`_expandedSections`) retired with its last row. The
  old collapsed summary (temp envelope · rain) and checked/total pill
  moved into the sheet header. Deliberately **no badge** on the icon —
  health's severity count sits next door, and two adjacent numbers would
  compete for the glance. Two mechanics diverge from the health sheet:
  weather **regions are a press-time snapshot** (the screen's
  `_legClothingRecs` stays the one producer; the checklist half stays
  live via its provider — a checkbox ticked in the sheet updates the
  header pill in place), and the scrollable pads by `viewInsets.bottom`
  because this sheet hosts a TextField (the add-item row) and
  `showModalBottomSheet` applies no keyboard insets itself.
  `ChecklistSection.isOffline` became a live callback (the
  TripReviewSection trade). Known debt carried over, slightly widened:
  the checklist's offline/error snackbars render behind the sheet barrier
  — for health only success-path snackbars were affected; here errors
  are too. Accepted because the live list is the primary feedback (a
  failed toggle visibly doesn't stick); a sheet-local inline note like the
  hours-check revert is the named follow-up if it bites.

## 2026-08-12 — trip-detail dogfooding (trip health modal)

- **[app] Friction → fixed (health row → app-bar icon + badge, the 08-03
  remedy delivered):** the 08-03 resolution kept Trip health inline for
  glanceability and named the fix if reachability recurred — "surfacing the
  health pill higher"; the 08-04 cluster reorder was the stopgap. This is
  the full remedy: Trip health left the trailing cluster for a fact-check
  **app-bar icon with a severity-colored count badge** — visible from the
  first frame on every breakpoint, which answers the 08-03 "a menu would
  hide glanceable state" objection (count + worst severity are MORE
  glanceable in the app bar than below the whole itinerary). Tapping opens
  a **bottom-sheet modal** (`showTripHealthSheet`) whose body is
  `TripReviewSection` (its body-only `showHeader` knob retired with the
  row); fix flows stack their own sheets above it on the same tab
  navigator, and the list + badge live-update through the one provider
  invalidation; tapping a day-anchored finding pops the sheet, then
  scrolls. The badge needed **solid** color pairs (`AppColors.warningSolid`
  + neutral) — the .20-alpha container amber vanishes on the teal gradient.
  Cluster is now Packing → Budget. Sheet feedback contract (post-review
  hardening): a FAILED fix throws out of `_applyFix` and the sheet closes
  itself so the error snackbar is seen (never a silent no-op); a failed
  hours-check reverts to the cached list with an inline note instead of
  blanking the modal; `isOffline` is a live callback, not a bool frozen at
  open. Known debt: success-path Undo snackbars still render behind the
  open sheet on phones (primary feedback = the finding dropping off the
  list), and there is still zero usage telemetry on any of these surfaces.

## 2026-08-12 — trip-detail dogfooding (add-CTA declutter)

- **[app] Friction → fixed (one add CTA per view):** the itinerary tail
  carried three CTAs — Add stay / Add transport / Add booking — "seems
  like a lot - no need for 3 ctas here." The row was never designed into
  that spot: it's where the retired Bookings section's buttons landed when
  the section died (fad88e3), and meanwhile the new Bookings tab (#335)
  shipped with no add affordance at all. Fixed with a swap that gives each
  tab exactly one add CTA: the Itinerary keeps **Add place**, the Bookings
  view's header slot gets **+ Add booking** — a MenuAnchor fanning out to
  Stay / Transport / Other, wired to the unchanged `_addStay` /
  `_addSegment` / `_addBooking` handlers (icon-only below 800px, same rule
  and reason as Add place). The itinerary tail now shows only residual
  "Other bookings" content. Removing the row entirely was rejected: every
  other creation path is conditional (health fixes need a finding, row
  "Add details…" needs an existing todo, chat is NL-only), so the menu is
  the one unconditional path — now living where a user hunting for
  bookings actually is.

## 2026-08-12 — trip-detail dogfooding (bookings view exit)

- **[dev] Friction → watch (two in-flight lanes touched the hub file
  `trip_detail_screen.dart`):** the parallel-dev rule is "at most one
  in-flight lane may touch `trip_detail_screen.dart`" (docs/parallel-dev.md
  §Parallel Development), but the accordion-focus lane (#339) and the
  retire-trip-status lane (#338) were both open against it at once. It
  integrated cleanly *this time* — #339 merged first, then #338 rebased onto
  it with **zero git conflicts** because the two changed disjoint regions
  (focus state machine vs. the status pill/field). But "no conflict" hid a
  real trap: the rebase silently left two `Trip(status: …)` fixtures that
  #339 *added* after #338 branched — #338's field-removal diff couldn't have
  known about them — and only `flutter analyze` caught it (a clean rebase is
  not a correct one). Lessons: (1) hold the one-lane-per-hub rule at wave
  planning, not just hope the diffs miss each other; (2) when two lanes do
  overlap a hub, the integrator must run the analyzer/tests after the rebase
  even when git reports no conflicts — the dangerous case is the clean-but-
  wrong merge, where one lane's *new* code uses a symbol the other lane
  *removed*. No product impact; recorded so the next wave schedules
  `trip_detail_screen.dart` lanes serially.

- **[app] Friction → fixed (accordion city focus, supersedes the 08-11
  two-way rules):** the 08-11 city-focus feel didn't hold up in use —
  expanding one city didn't close the previously focused one; collapsing a
  non-focused group did nothing to the map while re-expanding it re-fired
  the camera; collapsing the focused group reset to All. All three were the
  documented "multi-expansion, focus = last expanded, non-focused collapse
  inert" design — the incoherence was the contract, not a bug. New
  contract, one sentence: **the open group IS the selection** — expanding a
  header (or tapping its chip) focuses its leg and closes the previous
  group; collapsing the open group, or tapping All, deselects both ways
  (map to overview, list all collapsed); Add place and Today/health
  day-links select the target leg so list and map can never disagree; a map
  pin tap stays reveal-only (camera must not refit under the zoom-to-pin);
  `<2` legs still never focus. Implementation follows docs/zen.md: the
  hand-synced `_expandedCities` set (6 writers, the drift source) is GONE —
  the open group is **derived** from the focused leg at read time via
  `TripDerivation.groupKeyForLeg` (lenses only merge runs, so leg → group
  is a function), with one narrow reveal-only field (`_unfocusedOpenLegKey`)
  for pin-tap/seed/single-leg, and one writer (`_setCityFocus`) asserting
  the two never coexist. Deriving through the group key also fixed two
  latent lens bugs for free: the desktop chip scroll targeted a leg key the
  header registry never held, and the Add-place reveal added leg keys to a
  group-keyed set — both silently inert under a places lens.

- **[app] Friction → fixed (Itinerary | Bookings header tabs):** clicking
  "0 of 21 booked" opened the all-bookings view — "interesting view,
  actually" — but there was no visible way back; the only exit was buried
  in the "Filter places" menu (the code comment even admitted "the filter
  menu is the way back out"). The counter was a one-way invisible door.
  Fixed by making the view switch first-class: the header title is now two
  underline tabs, **Itinerary | Bookings · 0/21** — the booked count rides
  the Bookings tab label (the counter it replaced WAS the old door, so the
  thing you tapped before is the thing you tap now), selection is derived
  from `_itemFilter` every build (never stored), and either view is one
  visible tap from the other, including from the lens's empty state. The
  filter menu slimmed to what its tooltip claims — places only — and "Not
  booked yet" moved inside the Bookings view as a scope FilterChip (same
  'unbooked' state, moved entry point; it renders selected above the
  "Everything's booked" celebration as the explicit why + way back). Header
  row grew 36→44px (real tab touch targets, `_listHeaderHeight` 48→56);
  "Add place" is icon-only below 800px — the tab pair + Today + filter +
  a labeled button can't share a 390px Spanish row. Open debt unchanged
  from 08-06: counter counts todos only; lens usage still has zero
  telemetry (`clientEventTypes` whitelist = a Go change).

## 2026-08-11 — trip-detail dogfooding (map day chips)

- **[app] Friction → fixed (day chips → city focus, specs/map-city-focus):**
  on a 10-destination trip the map's "All / Day 1 … Day 14+" strip said
  nothing — day numbers are meaningless when you think in cities, and the
  city groups below were "just a dropdown". Replaced day chips with
  **destination chips** (All + one chip per `tripLegs` run, same keys as the
  group headers) and made focus **two-way**: expanding a city header focuses
  its leg on the map (per-item pins filtered to the leg + covering stays,
  auto-fit); collapsing the focused header restores the All overview; a chip
  tap focuses + expands, and on desktop rests the header right under the
  pinned map. Day-level map filtering retired everywhere (inline,
  full-screen, shared view); single-leg trips drop the strip (below 2 legs
  the overview mode never engaged anyway). Focus identity is the
  full-itinerary leg key — a places lens can merge adjacent runs, so map
  content resolves by the leg's item POSITIONS, never group keys. Camera
  moves stay instant (no animation dep); animated fly-to noted as polish.

- **[app] Friction → fixed (dead "Show more" toggle):** the header overview's
  "Show more" appeared on wide windows even when the whole summary already fit
  the 2-line clamp — clicking flipped it to "Show less" with zero visual
  change. Root cause: the toggle was gated on `text.length > 140`, a
  character-count proxy for "does the clamp clip", which false-positives on
  wide layouts and false-negatives on short newline-heavy summaries (3 hard
  lines, silent clipping, no toggle). Fix: `_OverviewText` now measures —
  LayoutBuilder width + a TextPainter configured exactly as the rendered
  Text's RenderParagraph (DefaultTextStyle merge, boldText, TextScaler
  object, locale, ellipsis) against one shared `_collapsedMaxLines` constant,
  so the toggle renders iff `didExceedMaxLines`. Lesson: **a proxy signal for
  a layout question re-derives the renderer's decision and will drift from
  it — ask the text engine the same question the renderer asks.**

## 2026-08-06 — trip-detail dogfooding (top-level clutter)

- **[app] Friction → fixed (collapse default + All-bookings lens):** on a
  7-destination trip the itinerary's top level was a wall of repeated
  flight/stay pairs ("EWR → Prague · Find flights" / "Stay in Prague · Open
  in Airbnb" × 7) before any actual content. Fixed two ways, per the 08-03
  doctrine (collapse, don't relocate; the menus rejection defended exactly
  this collapsed-rows shape): (1) destination groups now DEFAULT to
  collapsed — the resting view is one place-plus-dates header line per
  destination; a sole group seeds open, and today-mode still force-expands
  today's group on live trips (day-jump targets now come from a build-time
  `_liveDayKeys` registry, since a never-expanded group has no built day
  headers). (2) A new trip-wide "All bookings" filter lens — booked and
  unbooked, destination filter chips, residuals under an Other chip — entered
  from the filter menu or by tapping the "N of M booked" counter. A lens, not
  a section: it REPLACES the list, so booked-state never renders on two
  surfaces at once (the PR #274 bar), and every row keeps the one
  `_setRowBooked` writer. Open debt, on purpose: the counter still counts
  todos only (residual confirmed records were never "to book"), booking→
  destination attribution is still the fuzzy claim-once `_groupedBookings`
  matcher (the lens filters its OUTPUT — a stored leg association is the
  specs/server-leg-dates lane-1a follow-up), and lens/collapse usage still
  has zero telemetry (`clientEventTypes` whitelist makes that a Go change).

- **[app] BREAKAGE same-day → fixed (collapsed headers squished on
  scroll):** first dogfood of the collapsed default found every header
  squishing to a sliver, then a blank still-scrollable area, as the page
  scrolled. Root cause (verified against sliver_tools source): a collapsed
  group was a `MultiSliver(pushPinnedChildren)` whose ONLY child was its
  `SliverPinnedHeader`; the pinned child reports `paintOrigin = overlap`,
  and with no body sliver contributing `paintOrigin: 0`, the pinned
  chrome's overlap gets subtracted from the group's paint AND layout
  extents while scrollExtent stays full. Fix: pin a header only while its
  section is expanded — collapsed cities AND collapsed days (the same
  zero-body shape, latent since before the collapse default) render as
  plain scrolling rows. Lesson: **a pinned sliver only earns its pin while
  it has content to preside over — a zero-body pinned group is a geometry
  hazard, not a no-op.**

## 2026-08-06 — trip-detail dogfooding (leg dates, round five)

- **[app] BREAKAGE → fixed (specs/set-leg-dates round five):** the agent
  looped three turns claiming updates that never appeared, "apologizing"
  that it hadn't called the tool — but analytics show it called
  `update_itinerary_section` scope=trip SEVEN times, each committing. Its
  day→date mental model was wrong (it read a city's item day as the ARRIVAL;
  it's the departure), so its full-trip rewrites re-wrote ≈ the saved day
  numbers — zero visible change — and clobbered an earlier correct
  set_leg_dates move. Nothing it could read exposed rendered ranges: the
  tool's success result was a fixed 47-char sentence and get_trip showed raw
  day numbers, so the wrong model was unfalsifiable and the least-wrong
  story became "I never called it." Fix: `legsRenderSummary` (render truth
  via `visibleLegDisplayRange`) in BOTH the get_trip output and every
  update_itinerary_section result, plus the day-semantics rule and a
  do-not-resend steer in the result and refine prompt. Dev replay: the
  seven-turn loop's exact ask now resolves in one turn with two
  set_leg_dates calls. Lesson: **a mutating tool whose result carries zero
  derived state lets a wrong mental model survive any number of successful
  calls — every write result must echo the post-state the USER will see.**

## 2026-08-05 — trip-detail dogfooding (leg dates, round four — later still)

- **[app] Minor error → fixed (specs/set-leg-dates v4):** "Medellín should get
  5 nights" worked and the squeeze was narrated + offered for fixing (round
  three machinery), but the interim inverted state rendered "Medellín →
  Quito, Sep 14" directly above "Stay in Quito, Sep 13" — check-in before
  the flight lands. The arrival-adjustment only let the arrival win when it
  was EARLIER than the leg's own start, and inter-city flight rows read the
  previous leg's RAW end, so no local patch could make the chain coherent.
  Fix: one shared visible-ranges derivation (`_visibleGroupRanges` client /
  `visibleLegDisplayRange` server) — a squeezed leg collapses to a
  zero-night stop at its arrival, cascading so downstream flights and
  headers follow; confirmed stays never collapse; the honest no-op quotes
  the zero-night render. Lesson: **when data can be legitimately
  inconsistent mid-conversation, the renderer needs an explicit rule for the
  inconsistent state too — "it can't happen" states that CAN happen
  transiently still get looked at.**

## 2026-08-05 — trip-detail dogfooding (leg dates, round three — late)

- **[app] BREAKAGE → fixed (specs/set-leg-dates v3):** after the Kraków move,
  Prague rendered as a bare "Aug 27" on an Aug 24 trip, and asking to "update
  Prague to Aug 24–27" no-opped with the tool agreeing with the wrong
  rendering ("holding Prague at Aug 27–27") — the agent then suggested a full
  rebuild and manual trip-page edits. The DATA was right all along (in Prague
  Aug 24–27): nothing anchored the FIRST leg's visible start to the trip
  start on either side — a rule that had held only implicitly via the draft
  stay rows migration 00053 deleted. Separately, Kraków's extension landed
  exactly ON Berlin's departure day and consumed all its nights silently
  (gap/overlap narration is mute at n == 0). Fix: first-leg trip-start
  anchor in `_locationGroupRanges` + `anchoredLegDisplayRange` (confirmed
  stay still wins), first-leg start changes steer to set_trip_dates, squeeze
  NOTE + prompt nudge so the agent chains set_leg_dates down the affected
  legs. Lessons: **an invariant that exists only implicitly (via rows that
  can be deleted) must be explicit on both sides of the render mirror**, and
  **boundary narration must cover the == case, not just gap and overlap**.

## 2026-08-05 — trip-detail dogfooding (leg dates, round two)

- **[app] BREAKAGE → fixed (specs/set-leg-dates v2):** the SAME "change LA to
  Sep 24–27" ask failed again after PR #287 — now the tool "succeeded" (or
  honestly no-opped: "already spans Sep 24–27") while the page still showed
  Sep 20–24, plus a "Trip updated" chip on pure no-ops. Root cause: the
  screen derives a leg's visible dates as [previous leg's end → its max item
  day] and rebuilds the stay/flight rows (booking_todos) from item days on
  every load, but the tool moved a different axis — min-day-anchored
  renumbering on a placeholder trip whose single item day encodes the
  DEPARTURE, and a leg-only cascade that left Panama City's end (= LA's
  visible start) untouched. The no-op branch echoed the requested range and
  `trip_updated` fired before the change check. Compounding: PR #287's
  "client re-derives drafts on refetch" premise had been false since PR #274
  removed the drafts sync — frozen auto=true stays also masked trip-health
  lodging gaps. Fix: end-anchored item renumbering, previous-leg end extends
  to meet a later start in the same tx (decision 2026-08-05; overlap still
  narrate-and-ask), zero-change calls commit nothing (no SSE) and report
  actual saved state, `get_trip` now lists stay/transport/todo dates,
  migration 00053 deletes the frozen drafts + `checkLodging` skips auto,
  and the city-header range is arrival-adjusted to match the stay rows.
  Lessons: **a write tool must move the axis the UI renders — verify against
  the derived view, not the storage model**, and **no-op results must
  describe post-state read back from the DB, never echo the request**.

## 2026-08-04 — trip-detail dogfooding (map home legs)

- **[app] Friction re-filed → fixed (shipped-but-unreachable):** "Map doesn't
  show arrows to and from home airport" came back hours after PR #286 shipped
  the home-airport legs — because they render only on the full-screen map,
  whose sole entry points (tap-to-expand + fullscreen button) are phone-only
  (`expandable` is gated on `< 800px`). At the desktop widths the app is
  dogfooded at, the feature was structurally invisible; the item also never
  made it into this log, so nothing flagged the gap. Fix: the inline
  trip-detail card now draws the legs itself (same All/Day 1/last-day gating,
  whole-journey fit) and the wide card gets a fullscreen control beside the
  zoom column, so the big map is finally reachable on desktop. Lesson: **a
  feature scoped to one surface must ship with a reachability check on every
  breakpoint** — "the tap-to-expand map" didn't exist at ≥800px.

## 2026-08-04 — trip-detail dogfooding (cluster order)

- **[app] Friction recurred → fixed (reorder, not relocation):** the 08-03
  "keep Packing & prep / Budget inline" resolution flagged reachability as
  the residual risk, and it recurred the very next day — on a long trip,
  two empty rows ("No items yet" / "Not tracked yet") sat ABOVE an amber
  11-to-review Trip health row. Fixed per that entry's own remedy: the
  trailing cluster now leads with Trip health, so actionable review state
  is met right after the itinerary and the empty rows trail at the true
  page bottom (one-line reorder + an order-contract widget test). Menus
  were re-considered and re-rejected for the same reasons as 08-03:
  glanceable state, the screen deliberately has no overflow menu, the
  share menu's gating (owner-only, hidden offline) can't host
  viewer-visible sections, and there is still zero usage telemetry.

## 2026-08-04 — trip-detail dogfooding (late night)

- **[app] BREAKAGE → fixed (specs/set-leg-dates):** asked the refine chat to
  "change the dates for LA to Sep 24–27" on the Panama City → LA trip; the
  agent kept saying it was doing it, nothing changed. Root cause: no tool
  could move ONE leg — `set_trip_dates` (shipped that same day) is a rigid
  whole-trip shift, and calling it with the trip's unchanged start is a
  delta-0 *success* ("dates already match"), so the anti-fabrication prompt
  line never fired while nothing moved. A per-leg change needs endpoint-
  anchored deltas (Sep 20→24 is +4 on check-in, Sep 24→27 is +3 on
  check-out), item-day renumbering, boundary-segment moves, and a trip-end
  extension. Fix: new `set_leg_dates` tool (leg only + agent narrates the
  gap it opens — cascade decision 2026-08-04), plus the delta-0 result now
  steers the model to it. Lesson for future tools: **a tool that can succeed
  without doing what the traveler asked defeats the honesty guardrail** —
  results must say what did NOT move.

## 2026-08-03 — trip-detail dogfooding

- **[app] Resolved question (no change):** should "Packing & prep" and
  "Budget" live under different menus instead of below the itinerary? **No —
  keep them inline.** The trailing cluster (Packing & prep / Budget / Trip
  health) is three collapsed one-line `CollapsibleSection` rows (~150px
  total) whose value is glanceable state — "No items yet", "Not tracked
  yet", the amber Trip-health review pill — which a menu would hide; the
  screen also has no overflow menu today (the share menu is owner-only and
  hidden offline). Residual friction to watch: on a long trip the cluster
  sits below the entire itinerary and is only met by scrolling past
  everything. If that recurs, the fix is **reachability, not relocation** —
  jump-to chips near the header or surfacing the health pill higher.

## 2026-08-01 — parallel-lanes build session (late night)

- **[dev] BREAKAGE (self-inflicted, fixed same night):** first draft of
  `wt-rm` tore down the **main** dev stack and deleted its
  `development_postgres_data` volume — the test worktree was branched off
  pre-parameterization main, so its compose file ignored `GTT_PROJECT` and
  resolved to project `development`. Local dev DB was recreated empty; the
  other checkout's `development-chrome-1` browser-rig container was also
  removed (recreate if still used). Fix shipped in #259: teardown is
  label-based (`docker compose -p gtt-…`) and refuses non-`gtt-*` projects.
- **[dev] Trap (hit it myself minutes after writing the warning):** bare
  `docker compose -p <lane> up` without `.wt.env` sourced still interpolates
  default ports and tried to bind the main stack's 5432. In a lane, use the
  make targets; for bare commands `set -a; . .wt.env; set +a` first.
- **[dev] Silent default:** the API falls back to `PUBLIC_BASE_URL=
  http://localhost:3000` when unset — on a lane gateway (:3001) that failed
  all 8 MCP/OAuth discovery smoke checks. `wt-new` now retargets the copied
  `.env` (ports + pinned `PUBLIC_BASE_URL`); lane smoke then ran 39/0/3.
- **[dev] tmux env poisoning:** `set -a`-sourcing `.wt.env` in `tmux-dev.sh`
  seeds the tmux *server* environment — every later session (including the
  main checkout's) inherits the lane's `GTT_*` and hijacks its stack. Parse
  values instead of exporting; session targets need exact-match
  (`-t "=$SESSION"`) because tmux prefix-matches names.
- **[dev] Worktree rebase gotcha (encoded in `/integrate`):** a lane branch is
  checked out in its worktree, so `git checkout <branch>` in the main checkout
  refuses — the integrator rebases *inside* the lane's worktree.
- **[dev] Duplicate goose migration numbers** merge cleanly in git and only
  explode at deploy — now guarded in CI (migrations job, runs on the PR merge
  ref) plus reserve-at-planning convention.
- **[dev] Agent-review caveat:** the PR #260 review workflow hit a session
  limit mid-verify (13/17 agents died) and its verdicts were artifacts of the
  failures — when a workflow reports `<failures>`, re-verify findings by hand
  before trusting confirmed/refuted splits.
- **[dev] 1Password signing:** transient "failed to fill whole buffer" on
  commit; immediate retry succeeded (known pattern — never disable signing).
- **[dev] Open follow-ups:** trim `Bash(gh pr *)` from
  `.claude/settings.local.json` (pre-approves `gh pr merge`, defeating the
  lane-agent stall); local dev DB is empty — reseed if anything mattered;
  first real wave should exercise the slimmed `/integrate` end to end (see
  2026-08-18) — expect at least one PR to take the clean path.
