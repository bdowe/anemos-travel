# Spec: Collaborative Trip Editing (async v1)

## Context

Trip sharing v1 (specs/trip-sharing) shipped read-only links with a `role`
column explicitly reserved for editing. This feature grows it into async
co-editing — the product's viral-loop next step. An owner mints an editor
link; a signed-in recipient joins as a collaborator; collaborators edit the
trip through the normal endpoints. No live sync: changes appear on reload /
pull-to-refresh. AI refinement stays owner-only, keeping the chat_id version
lineage single-writer.

## Design

- **Membership is explicit state, tokens are only the capability to join.**
  Redeeming an editor token creates a `trip_collaborators` row (migration
  00027, lineage-scoped like trip_shares, partial-unique on active rows).
  Revoking links stops new joins but does NOT evict existing collaborators;
  eviction is explicit per-person.
- **One authorization seam.** `ownedTrip` → `editableTrip(w, r) (store.Trip,
  bool)` backed by `GetEditableTripByID` (owner OR active editor on the row's
  lineage; non-members get the same 404). Returning the trip row lets call
  sites use the OWNER's id for follow-up reads — fixing two latent traps
  (post-insert trip reload keyed to caller; patchTripHandler's implicit
  owner check).
- **Owner-only unchanged:** delete trip, share create/revoke, collaborator
  management, refine + the /plan SSE trip bind.
- **Conflicts: documented last-write-wins.** Reorder still 409s on stale item
  sets; item PATCH is field-level COALESCE so disjoint edits merge; clients
  reload after every mutation.

## Acceptance Criteria

- [x] `POST /trips/{id}/share` accepts optional `{"role":"editor"}`; absent
      body still mints a viewer link (backward compatible); idempotent per
      (lineage, role); viewer and editor tokens coexist.
- [x] `GET /shared/{token}` carries `role` so the client can offer join.
- [x] `POST /shared/{token}/join` (auth, strict rate tier): editor tokens
      create membership (idempotent; owner self-join is a no-op success);
      viewer tokens 403; revoked/unknown tokens 404.
- [x] Editors can create/edit/delete itinerary items, stays, segments,
      booking todos, and PATCH trip title/dates (originally also status,
      retired by specs/retire-trip-status). All mutations return
      the same shapes as for owners.
- [x] Editors cannot delete the trip, mint/revoke links, manage
      collaborators, or refine — uniform 404s.
- [x] `GET /trips/{id}` works for owner and editors; response carries
      `access` ("owner"|"editor") and `owner_name` (editor only).
- [x] `GET /trips/shared-with-me` lists the latest version per collaborated
      lineage with owner attribution and cities.
- [x] `GET/DELETE /trips/{id}/collaborators[/{userId}]` (owner-only); removal
      immediately revokes the editor's read+write (404) and empties their
      shared-with-me list; second removal 404s.
- [x] Link revocation blocks new joins while existing collaborators keep
      access.
- [x] Analytics: editor_share_created, collaborator_joined,
      collaborator_removed.

## Contract Parity

| JSON key | Go type | Dart type | Nullable |
|---|---|---|---|
| `role` (share create req/resp, shared resp) | `string` | `String` | req optional |
| `trip_id`, `access` (join resp) | `string` | `String` | no |
| `access` (TripResponse) | `string` | `String?` (missing ⇒ owner) | yes |
| `owner_name` (TripResponse) | `*string` | `String?` | yes |
| collaborator: `user_id`, `display_name`, `email`, `joined_at` | strings/time | `String`/`DateTime` | no |

## Out of Scope

- Live sync / presence / websockets (async v1: reload & pull-to-refresh).
- Editor-run AI refinement (owner-only per product decision).
- Viewer-role membership (viewer links stay unauthenticated read-only).
- Notifications when a collaborator edits.
