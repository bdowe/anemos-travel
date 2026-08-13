# Tasks: Budget v2

## PR A — Budget tab promotion
- [ ] Go: viewer-read fix (`budget_handler.go` GETs → `viewableTrip`) + test
- [ ] Screen: `_inBudgetView`, third tab, gating, place-less pair, force-exit,
      add-CTA guard, body arm, derivation arm, cluster shrink
- [ ] `BudgetSection` upgrade (headline, progress, viewer EmptyState, a11y)
- [ ] `showBudgetTargetDialog` unification; `_refresh` invalidation fix
- [ ] l10n orphan cleanup; regen LAST
- [ ] Tests: fix_actions, filter_lenses, narrow (no-truncation), budget_section,
      today; full suite + Go suite green
- [ ] `ship pr`

## PR B — Autopopulate on mark-booked (stacked on A)
- [ ] Migration 00058 + queries + `make api-sqlc`
- [ ] `budget_handler.go` upsert-by-source, PATCH auto-flip, `expense_added`
- [ ] Go tests: link upsert + validation
- [ ] Flutter: Expense fields, service params/ApiException, categories lift
- [ ] `booked_expense_prompt.dart` (derive + dialog)
- [ ] Wire `_setRowBooked` + health `mark_booked`; unbook cleanup
- [ ] `AddSegmentSheet` price_note (droppable)
- [ ] l10n `budgetPrompt*`; tests (prompt unit/widget, screen integration)
- [ ] Full verification; `ship pr`
