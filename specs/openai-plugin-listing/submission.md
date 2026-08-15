# OpenAI Plugin Directory — submission packet

Everything the portal at
<https://platform.openai.com> asks for, written out so submitting is
transcription rather than authorship.

> **Do not put credentials in this file.** The demo account's password goes into
> the portal directly. `<FILL>` marks values only Brian can supply.

---

## Before you open the portal

| Prerequisite | State |
|---|---|
| Verified individual or business identity on the OpenAI Platform | `<FILL>` — required for any public submission |
| "Apps Management" permission set to **Write** in Platform roles | Org owners have it by default |
| Domain verification for `anemos.travel` | `<FILL>` — follow the portal's mechanism; DNS is on Cloudflare |
| Gate 0 hand-test passed (see `spec.md` open questions) | `<FILL>` |

---

## 1. Listing

| Field | Value |
|---|---|
| Name | Anemos |
| Tagline | Plan trips with recommendations from real locals — and save them. |
| Category | Travel |
| Website | `https://anemos.travel` |
| Documentation / support URL | `https://anemos.travel/connectors` |
| Support contact | `goldentempollc@gmail.com` |
| Privacy policy | `https://anemos.travel/privacy` |
| Terms | `https://anemos.travel/terms` |
| Logo | `https://anemos.travel/app/icons/Icon-512.png` (512×512 PNG) |
| Company | Golden Tempo LLC (New Jersey, USA) |

**Long description**

> Anemos turns a planning conversation into an actual itinerary you can keep.
>
> Ask about a destination and Anemos answers from recommendations left by named
> locals — the places that don't surface in web search — with each local's own
> tip, credited to them. When you've settled on a plan, Anemos saves it to your
> account and hands you a link: a real itinerary with the places on a map, dates,
> and everything you'd otherwise be reconstructing from a chat transcript later.
>
> You connect your own Anemos account, the connector only ever touches that
> account, and you can revoke it in one tap from Settings.

---

## 2. MCP server

| Field | Value |
|---|---|
| Server URL | `https://anemos.travel/mcp` |
| Transport | Streamable HTTP |
| Same URL for every user? | Yes |
| Authentication | OAuth 2.1, public client + PKCE S256, RFC 7591 dynamic client registration |
| Discovery | `/.well-known/oauth-protected-resource[/mcp]`, `/.well-known/oauth-authorization-server` |
| Scopes | `trips:write`, `recs:read` |
| UI components | None — no content security policy needed |

### Tool annotations

Implemented in `src/packages/api/mcp_tools.go` and pinned by
`TestMCPToolsCarryDirectoryAnnotations`.

| Tool | Title | `readOnlyHint` | `destructiveHint` | `openWorldHint` |
|---|---|---|---|---|
| `create_trip` | Save trip to Anemos | `false` | `false` | `false` |
| `search_local_recommendations` | Search local recommendations | `true` | `false` | `false` |
| `list_trips` | List saved trips | `true` | `false` | `false` |

**Why `create_trip` is non-destructive and closed-world:** it only ever adds a
new trip to the traveler's own private account. It cannot edit or delete an
existing trip, and it publishes nothing to the open internet.

---

## 3. Starter prompts

Realistic workflows, each exercising a different tool path. Substitute a city
with published local recommendations for `<DEMO CITY>` (see `spec.md` open
questions).

1. "Plan five days in Lisbon and Porto in early October, then save it to my
   Anemos account."
2. "Where do locals actually eat in `<DEMO CITY>`? Use Anemos's recommendations
   and tell me who recommended each place."
3. "What trips do I have saved in Anemos?"
4. "I'm island-hopping in Greece for a week in June. Build the plan around local
   recommendations, and save it once I'm happy with it."

---

## 4. Test cases

A reviewer runs these against the demo account. Each states what to do and what
should happen.

### Positive

| # | Do this | Expect |
|---|---|---|
| P1 | "What trips do I have saved in Anemos?" | `list_trips` returns the demo account's seeded trip(s), each with a `https://anemos.travel/app/trip/<id>` link that opens the trip. |
| P2 | "Where do locals recommend eating in `<DEMO CITY>`?" | `search_local_recommendations` returns published pins, each credited to a named local with their own tip. |
| P3 | "Save a two-day Lisbon trip to Anemos: Time Out Market, Belém Tower, LX Factory." | `create_trip` succeeds and returns a link; opening it shows the three places on the map. |
| P4 | "Plan three days in Lisbon around local recommendations, then save it." | The assistant calls `search_local_recommendations` before suggesting places, then `create_trip`; the saved trip contains the recommended places. |
| P5 | "Save a Greece trip starting from Newark, travelling by ferry between islands." | `create_trip` accepts `origin` and `travel_mode`; the saved trip shows ferry legs from the stated origin rather than assuming a home airport. |

### Negative

| # | Do this | Expect |
|---|---|---|
| N1 | "Save a Lisbon trip with Time Out Market and Zzqqx Imaginary Cafe." | The trip saves with the real place; the unresolvable one is **named back** ("couldn't locate on a map") rather than silently dropped. Not a crash, not a silent loss. |
| N2 | "What do locals recommend in Ulaanbaatar?" (a city with no published pins) | A clean empty result. The assistant reports there are no Anemos recommendations for that city and does **not** invent any. |
| N3 | In Anemos, open Settings › Connected apps and revoke the connection, then ask ChatGPT "list my Anemos trips." | The call fails with `401` and a `WWW-Authenticate: Bearer resource_metadata=…` challenge; the assistant prompts to reconnect. Proves revocation is immediate. |

### Documented limits (not test cases)

- `create_trip` is capped at **20 per day per connection**; over the cap it
  returns a friendly error result, not a protocol failure.
- `/mcp` is rate-limited **per grant** at 30/min with a burst of 10.
- A single `create_trip` accepts at most **60 locations**.

---

## 5. Demo account

| Field | Value |
|---|---|
| Sign-in | Email + password at `https://anemos.travel` |
| Email | `<FILL>` |
| Password | `<FILL — enter in the portal, never in this repo>` |
| MFA | None — the account must be reachable without MFA, SMS, or email confirmation |
| Seeded with | At least one saved trip, in a city that has published local recommendations |

Setup steps for the reviewer (include verbatim in the portal):

1. Add the connector `https://anemos.travel/mcp`.
2. Sign in with the credentials above when the consent screen appears.
3. Approve the connection. All three tools are then available.

---

## 6. Data handling

| Question | Answer |
|---|---|
| Is the underlying API your own? | Yes — first-party. |
| Personal health data? | No. |
| Sponsored content? | No. Local recommendations are editorial and unpaid. |
| Data sent to OpenAI | Only what a tool call returns: the traveler's saved trips and published local recommendations. |
| Restricted data collected | None — no payment details, credentials, health data, or government IDs. |

---

## 7. Availability and release notes

- **Countries:** `<FILL>` — default to worldwide unless there's a reason not to.
- **Release notes:** "Initial submission. Three tools: save a trip, search
  recommendations from named locals, and list saved trips. OAuth 2.1 with
  dynamic client registration; connections are revocable in-app."

---

## 8. Compliance acknowledgments

All seven are required. Read them in the portal rather than assuming; the ones
worth thinking about before you get there:

- **Directory guidelines** — met via this packet.
- **First-party API usage** — yes, Anemos's own API.
- **Financial transactions** — none. The connector takes no payments.
- **AI media generation** — none.
- **Prompt injection** — tool results are Anemos's own data, not scraped
  third-party content.
- **Conversation data collection** — Anemos does not receive or store the
  assistant conversation; only explicit tool-call arguments reach us.
- **Public documentation** — `https://anemos.travel/connectors`.

---

## 9. After approval

Approval does not publish. Publishing is a separate action in the portal — take
it deliberately, once the support inbox is being watched and the local-content
coverage is where you want a stranger's first impression to be.
