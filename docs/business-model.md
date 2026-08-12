# Business Model

Working strategy doc — the reasoning behind how `<Name>` makes money, not
investor copy. Companion to [`sales-pitch.md`](sales-pitch.md); uses the same
`<Name>` placeholder. Numbers marked *(placeholder)* or *(directional)* are
starting points to be replaced with measured data.

> **Thesis:** a three-layer hybrid, phased for growth. Booking-linked revenue
> is the always-on base that scales with free users. The free tier is generous
> but usage-capped, and keeps the entire core loop free. A paid "power
> traveler" tier — annual or per-trip, never monthly — monetizes heavy users
> without gating the funnel. Right now we optimize for growth and adoption;
> the paid tier ships later, on evidence.

---

## 1. The two revenue streams

`<Name>` has two fundamentally different ways to earn:

1. **Booking-linked revenue** (commissions/markup when a user books). Earns
   from *every* user, free or paid. Scales with top-of-funnel volume and with
   how good the product is at getting trips actually booked.
2. **Direct user monetization** (a paid tier). Earns from the small fraction
   of users who travel heavily enough to pay.

These are complementary, not competing — but only if the funnel stays open.
Every user we'd lose to a paywall is a user whose bookings we'd never see.
**Keeping the product free is a revenue decision, not just a growth one.**

---

## 2. Booking-revenue reality check

The pitch's "affiliate-revenue path" needs precision, because the three
booking handoffs earn very differently:

- **Airbnb — earns $0.** Airbnb shut down its affiliate program in 2021. The
  Airbnb deep links are pure user value; do not count them as revenue.
- **Booking.com — earns today.** A real affiliate program paying roughly
  25–40% of Booking's own commission — call it **~4% of booking value**
  *(directional)*. On a $500 stay, that's ~$20. This is the actual base layer
  right now.
- **Flights (Duffel) — earns only with in-app booking.** Duffel is a
  *merchant* model, not affiliate: revenue is a markup on tickets **sold
  in-app**. Deep links out to airlines earn ~nothing. Consequence: the
  roadmap's "in-app booking" isn't a nice-to-have — **it is the unlock for
  all flight revenue.** (Interim option: metasearch referral programs à la
  Travelpayouts/Skyscanner — thin but nonzero.)

So near-term booking revenue = accommodation attach rate × Booking.com
commission. Flight revenue arrives with Phase 2 (§8).

---

## 3. Why not the obvious two models

**Monthly subscription — no.** Travelers plan 2–4 trips a year. A monthly sub
is churn-by-design: users subscribe in March to plan the summer, cancel in
April, and feel vaguely ripped off. The products that survive in travel
charge on a cadence that matches travel (annual, per-trip), not a cadence
that matches SaaS habit.

**Free trial → paywall — no.** A hard gate after a trial:
- suppresses the booking funnel (§1) — every bounced user is lost commission;
- kills the collaboration viral loop before it exists — shared trips can't
  spread if the recipient hits a paywall;
- contradicts the landing page's "Start planning free →" positioning;
- and is the worst possible fit for a growth-first phase.

The right question isn't "when does the meter start" but "where does the
power-user line sit."

---

## 4. Tiers

The line: **the entire core loop is free** — chat → itinerary → map →
optimized route → booking checklist → booking handoff. Free caps exist to
bound COGS, not to frustrate. Paid gates ride on power usage and roadmap
features.

| | **Free** | **Power Traveler (paid)** |
|---|---|---|
| AI planning sessions | ~20 agent runs / month *(placeholder)* | Unlimited |
| Active trips | 3 *(placeholder)* | Unlimited |
| Itinerary, map, route optimization | ✅ Full | ✅ Full |
| Booking checklist + handoff links | ✅ Full | ✅ Full |
| Traveler preferences / profile | ✅ Full | ✅ Full |
| Collaboration / shared trips | — | ✅ *(roadmap)* |
| Price / fare alerts | — | *(removed 2026-08; resurrectable from git @ 8ca59c5)* |
| Richer in-app accommodation search | — | ✅ *(roadmap)* |
| Offline itineraries | — | ✅ *(roadmap)* |
| Priority / faster model | — | ✅ |

Shipped vs. roadmap follows the honesty rule at the bottom of
`sales-pitch.md`: nothing roadmap-only is claimed as live. At launch of the
paid tier, "unlimited + priority" may be the only shipped gates — which is
another reason the tier ships in Phase 3, after at least one roadmap anchor
feature (most likely collaboration) exists.

---

## 5. Paid cadence and price

- **Primary: annual membership, $30–50/yr** *(placeholder)*. Comparables
  cluster tightly: Wanderlog Pro ~$40/yr, TripIt Pro ~$49/yr. Annual matches
  the "I travel a few times a year" rhythm and prices below a single checked
  bag.
- **Experiment: per-trip unlock, $5–10/trip** *(placeholder)*. Charges at the
  moment of maximum perceived value ("this trip matters"). Worth an A/B once
  the paid tier exists; risk is it trains users to think per-trip and caps
  LTV.
- Note: several VC-funded AI planners (Mindtrip, Layla) are entirely free —
  one more reason the *core loop* must stay free and paid must sell *power*,
  not access.

---

## 6. Unit economics *(directional)*

Per-use cost drivers for one planning session:

| Driver | Rough cost |
|---|---|
| Claude API (Sonnet, tool-use loop) | $0.30–1.50 / session |
| Google Places (search/details calls) | $0.02–0.03 / call |
| Duffel flight search | ~free at this volume |

→ A free user planning one full trip costs on the order of **$1–5**.

**Worked example** *(directional)*: one attached Booking.com reservation on a
$500 stay earns ~$20. At $3 average trip-planning COGS, one booking pays for
~6–7 free planned trips. Break-even attach rate ≈ **15%** of planned trips
producing one $500 booked stay — ambitious but not absurd for a product whose
whole job is getting trips to "booked." **Attach rate is the single number
the growth phase exists to measure.**

COGS levers if the math runs hot:
- the free-tier caps themselves (§4);
- cheaper/faster model on the free tier, premium model as a paid perk;
- cache Google Places results (popular places repeat across users);
- prefer autocomplete over text-search where the UX allows.

---

## 7. Growth-phase sequencing

**Phase 1 — now: free + Booking affiliate.** Minimal friction, no paywall
anywhere. Instrument everything: activation, retention, attach rate, per-user
COGS. The product's job is to prove people come back for trip #2.

**Phase 2 — in-app flight booking (Duffel markup).** The flight-revenue
unlock (§2). Also the roadmap's biggest UX claim ("from plan to booked"
without leaving the app), so it's a product win and a revenue win in one.

**Phase 3 — paid tier.** Trigger conditions, not a date:
- retention proven across ≥2 trips for a meaningful cohort;
- a measured cohort actually hitting the free caps (demand signal);
- at least one roadmap anchor feature (collaboration) shipped to
  gate behind it.

---

## 8. Metrics to watch

- **Activation** — signup → first saved trip.
- **Retention** — users returning for a second trip (the compounding claim).
- **Booking attach rate** — planned trips → booking-link clicks → completed
  bookings. The break-even number (§6).
- **COGS per active user** — Claude + Places spend / MAU.
- **Cap-hit rate** — % of users hitting free limits; the paid-tier demand
  signal and Phase 3 trigger.
- **Free→paid conversion** — later, once the tier exists (expect 1–5%).

---

## 9. Open questions

- Exact free caps — 3 trips / 20 runs are guesses; set from usage data.
- Annual vs. per-trip as the *primary* paid cadence (annual assumed; per-trip
  as experiment).
- Price points within the $30–50/yr and $5–10/trip anchors.
- Timing of Phase 3 — which trigger condition binds first.
- **Collaboration: anchor paid feature or free growth lever?** It's the viral
  loop *and* the most gate-worthy roadmap feature — it can't be both.
  (Possible split: viewing/commenting free, co-editing paid.)

---

*Everything above is strategy, not commitment. The only decisions treated as
settled: hybrid model, growth-first priority, non-monthly paid cadence, and
the core loop staying free.*
