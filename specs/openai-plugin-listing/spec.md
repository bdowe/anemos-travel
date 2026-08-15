# Spec: ChatGPT Plugin Directory listing

## Context

Anemos has run an MCP connector at `https://anemos.travel/mcp` since
2026-08-01 (specs/mcp-connector), but the only way to reach it is ChatGPT's
Developer Mode or Claude's custom-connector dialog — both of which require
pasting a URL into a settings page. That caps adoption at people who already
know the connector exists.

OpenAI's Plugin Directory (the app directory merged into it on 2026-07-09,
shared by ChatGPT and Codex) removes that step entirely, and unlike Anthropic's
Connectors Directory it is submittable without a paid plan upgrade — it needs a
verified developer identity and domain verification. Approval and publication
are separate steps, so submitting early costs nothing but buys queue position.

The outcome: Anemos is listed, and a ChatGPT user can add it without ever seeing
a URL.

## User Stories

- As a **ChatGPT user**, I want to find Anemos in the directory and connect it in
  one flow, so that I never have to enable Developer Mode or paste a server URL.
- As a **traveler mid-conversation**, I want my assistant to consult Anemos's
  local recommendations before it suggests places, so that I get the pins I
  can't find by searching the web.
- As a **cautious user**, I want to see exactly what a connected assistant can
  read and write before I approve it, and revoke it in one tap afterwards.

## Acceptance Criteria

- [ ] Every tool advertises a title and all three hints
      (`readOnlyHint`, `openWorldHint`, `destructiveHint`), with the write tool's
      hints explicitly present on the wire rather than omitted.
- [ ] `initialize` returns a non-empty version, description, website, icon, and
      instructions.
- [ ] `https://anemos.travel/connectors` serves connector documentation and a
      support contact, and `/connect/<request-token>` still routes to the
      in-app OAuth consent screen.
- [ ] The privacy policy describes what a connected assistant can read and
      write, where that data goes, and how to revoke.
- [ ] A reviewer can run five positive and three negative test cases end to end
      using a demo account, with no MFA and no private-network access.
- [ ] Submission is accepted; publication remains a separate, deliberate step.

## Out of Scope

- The Anthropic Connectors Directory submission (blocked on a Team/Enterprise
  org decision — every prerequisite above is shared with it and is done here).
- The in-app "Connect" card and connection detection.
- Notifications, trip provenance, and binding an assistant-created trip to a
  resumable Anemos chat session.
- `openid`/`email` scopes and a UserInfo endpoint — OpenAI wants those only for
  workspace domain restrictions, not for a consumer listing.
- MCP Apps / Apps SDK interactive UI components.

## Open Questions

- [NEEDS CLARIFICATION] Do write tools execute on the submitter's consumer
  ChatGPT plan? OpenAI's developer-mode guide lists Pro/Plus/Business/
  Enterprise/Edu with write actions merely requiring confirmation; several
  secondary sources claim write is restricted to Business/Enterprise/Edu.
  Resolve by hand before submitting — it changes what the listing promises.
- [NEEDS CLARIFICATION] Which cities have enough published local
  recommendations to demo? `GET /api/v1/admin/local/coverage` answers this;
  the starter prompts and test cases below must name a city that returns pins.
