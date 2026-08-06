# The Zen of Python — this repo's coding principles

Adopted 2026-08-06 after the leg-dates arc (PRs #284–#295 and the
specs/trip-dates-truth re-architecture it forced). Read this before designing
a data model, a tool contract, or a derivation. When a principle here and a
convenient shortcut disagree, the principle wins — or the divergence gets
written down and justified.

## The Zen of Python (Tim Peters, PEP 20)

```
Beautiful is better than ugly.
Explicit is better than implicit.
Simple is better than complex.
Complex is better than complicated.
Flat is better than nested.
Sparse is better than dense.
Readability counts.
Special cases aren't special enough to break the rules.
Although practicality beats purity.
Errors should never pass silently.
Unless explicitly silenced.
In the face of ambiguity, refuse the temptation to guess.
There should be one-- and preferably only one --obvious way to do it.
Although that way may not be obvious at first unless you're Dutch.
Now is better than never.
Although never is often better than *right* now.
If the implementation is hard to explain, it's a bad idea.
If the implementation is easy to explain, it may be a good idea.
Namespaces are one honking great idea -- let's do more of those!
```

## How this repo has paid for violating it

These aren't hypotheticals — each was a shipped bug class here:

- **Explicit is better than implicit** — the root cause of the leg-dates arc.
  Destination dates were implicit (derived from `trips.start_date + day − 1`,
  with "a city's last item day is its departure" existing only by convention)
  instead of stored as their own dates. Five renderers re-derived them, tools
  edited storage the renderer didn't read, and an AI guessed the convention
  wrong seven "successful" writes in a row. Remediation:
  `specs/trip-dates-truth` (explicit `item_date` storage, one explicit
  derivation, explicit rendered ranges in every write result). Corollary
  learned the hard way: an invariant that only holds *implicitly* — e.g. via
  rows that can be deleted (the first-leg anchor via draft stays) — is not an
  invariant.
- **Errors should never pass silently** — a mutating tool whose success
  result carried zero derived state let a wrong mental model survive
  unlimited "successful" calls; honest no-ops and result echoes fixed it.
- **In the face of ambiguity, refuse the temptation to guess** — day-number
  semantics were ambiguous, so the model guessed (arrival vs departure) and
  the guess was unfalsifiable. Contracts the model consumes must make wrong
  guesses fail loudly.
- **There should be one — and preferably only one — obvious way to do it** —
  the audit found five "what is a leg" grouping rules and ~eight day→date
  computations. One definition, N call sites.

## Applying it here

- New field or derived value? Ask: is the meaning explicit in the schema/type,
  or is it a convention someone must remember? Conventions get promoted to
  storage, types, or enforced boundaries — or documented as debt with a plan.
- New tool/endpoint? Its result must state what changed AND the post-state the
  consumer will observe. "Success" with no derived state is silent error-
  passing.
- Second implementation of anything? Stop. Either consume the first or write
  the parity contract (twin fixtures) that keeps them honest — see
  test/leg_ranges_test.dart ↔ trip_render_legs_test.go.
- Practicality beats purity is allowed — but the divergence gets a comment, a
  decision record (specs/*/plan.md), and a test pinning it.
