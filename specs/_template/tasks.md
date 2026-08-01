# Tasks: <Feature Name>

> Dependency-ordered. `[P]` = can run in parallel with its siblings (no shared
> files / no ordering dependency). Work top to bottom; verification is last.

## API (Go)

- [ ] Define request/response types
- [ ] Implement service logic in `<feature>_service.go`
- [ ] Implement handler(s)
- [ ] Register route(s) + startup log line in `main.go`
- [ ] Add any new env var to `.env.sample`

## Models & codegen (Flutter)

- [ ] Hand-write Dart model(s) in `models/`
- [ ] Run `make flutter-build-models` to regenerate `.g.dart`
- [ ] Complete the Contract Parity table in `plan.md` (every row ✓)

## UI (Flutter)

- [ ] [P] Add service wrapper in `services/`
- [ ] [P] Add Riverpod provider in `providers/`
- [ ] Build screen / widget and wire to provider
- [ ] Handle loading / empty / error states

## Verification

- [ ] `make api-fmt && make api-vet` clean
- [ ] `make flutter-analyze` clean
- [ ] `make flutter-test` / `make api-test` pass (as applicable)
- [ ] Manual end-to-end via gateway (`make docker-dev` → `http://localhost:3000`):
      every acceptance criterion in `spec.md` checked off

## Lanes (multi-agent waves only — delete this section for single-agent features)

> One lane = one branch = one worktree = one PR. Rules and the hub-file table:
> `docs/parallel-dev.md`. Reserve migration numbers NOW
> (`ls src/packages/api/migrations | tail -1` → next free).

| Lane | Branch | Tasks | Migration # | Registry tail? | ARB key prefix | trip_detail? | Depends on |
|------|--------|-------|-------------|----------------|----------------|--------------|------------|
| A    | `<feat>-api` | 1–4 | — | no | — | no | — |
| B    | `<feat>-ui`  | 5–8 | — | no | `<featX>` | no | A (contract types) |

**Conflict manifest** — per lane, list every EXISTING file it edits (new files
are free). Constraints to check before fan-out: ≤1 lane touches
`trip_detail_screen.dart`; ≤1 lane appends to `plan_tool_registry.go`; ARB
prefixes unique across the wave; ≤1 migration per lane.

**Merge order** — dependency edges only (e.g. A → B); unordered lanes merge in
any order. Lane agents stop at PR-open (`ship pr`); the integrator merges
(`/integrate`).
