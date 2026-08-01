# Pre-Beta Pitch — Friends & Family Launch

Channel-ready copy for the friends-and-family pre-beta of **Golden Tempo Travel**
(goldentempotravel.com). Four pieces, one shared spine. The investor-facing pitch
lives in [sales-pitch.md](sales-pitch.md); this doc is for the humans we actually know.

> **`[FEEDBACK CHANNEL]`** appears wherever a feedback destination is needed —
> replace it once decided (reply-to-me, dedicated email, form, group chat, etc.).

---

## 1. Core narrative (the shared spine)

Every piece below is a channel-shaped version of the same three beats:

1. **Mission.** I set out to build something I genuinely enjoy using. I travel a
   lot, and I was tired of planning trips across twelve tabs and a chat window
   that forgets everything. If it makes my life easier as a frequent traveler,
   it can make yours easier too. That's the bar: not "would people pay for
   this," but "do I reach for it for my own trips." Everything else follows
   from that.
2. **The build story.** This went from an idea to a real, working application —
   live in production, real flight data, real places, real accounts — built
   solo, with AI doing a lot of the heavy lifting (Claude Code wrote most of
   the code; I steered). Part of this project is figuring out how to streamline
   that zero-to-app process, and I'll be sharing what I learn along the way.
3. **The ask.** Use it. Plan a real trip or a fake one. Find the things you
   don't like — the confusing screen, the button that didn't do what you
   expected, the moment you gave up and opened ChatGPT instead. Then tell me.
   At this stage, your honest feedback is the most valuable thing anyone can
   give me. Compliments are nice; complaints are useful.

---

## 2. Instagram / DM message (warm & personal)

### Full version (~160 words)

> Personal news: I built an app. 🐎✈️
>
> It's called **Golden Tempo Travel** — named after a racehorse I put $100 on
> at the Derby that came back with $700. Felt right for a travel app.
>
> I travel a lot, and I was tired of planning trips across a dozen tabs and a
> ChatGPT window that forgets everything. So I built the thing I wanted: you
> describe the trip, it builds the actual day-by-day itinerary — real places,
> real flights, on a map, saved — and it keeps getting better the more it
> knows how you like to travel.
>
> It's in **pre-beta**, which is a fancy way of saying: it works, it's live,
> and some things will definitely be rough. That's where you come in. Try it,
> plan a trip (real or imaginary), and tell me everything you don't like.
> Honest complaints are genuinely the best gift you can give me right now.
>
> 👉 goldentempotravel.com
>
> `[FEEDBACK CHANNEL]`

### Short DM / text version

> I built a travel app — you describe a trip, it builds the real day-by-day
> itinerary (flights, places, map, all saved). It's early and rough in spots,
> and I need honest eyes on it. Try it and tell me what you hate:
> goldentempotravel.com 🐎 `[FEEDBACK CHANNEL]`

---

## 3. Landing / welcome page copy (startup-pitch energy)

Copy blocks ready to lift into the app later. (Wiring into
`landing_screen.dart` / the ARB files is a separate task — en + es pair
required.)

### Hero

**Plan less. Travel more.**

Describe the trip you want. Get a real, day-by-day itinerary — actual places,
actual flights, on a map, saved and ready to book.

**[Start planning →]**

### The difference

**ChatGPT gives you advice. Golden Tempo gives you a trip.**

A chat window hands you a wall of text and forgets you tomorrow. Golden Tempo
turns the conversation into a living itinerary: every stop is a real place with
real coordinates, every flight is a live fare, and the whole thing is saved,
mapped, and editable — not pasted into your Notes app.

### Feature bullets

- **A travel agent you talk to.** Describe the trip in plain words — it
  searches real places, checks real flights, and assembles the day-by-day plan
  while you watch.
- **Real data, not AI guesses.** Places come from Google, flights from live
  airline inventory, and local picks from actual locals — credited by name.
- **Your trip, in one place.** Map view, price alerts, shareable links, a
  printable travel packet, and calendar export. Even import a trip you already
  planned in ChatGPT or Claude.
- **It learns how you travel.** Budget, pace, interests, home airport — set
  once, and every plan starts from there.

### Pre-beta banner

**You're early — thank you. 🐎**

Golden Tempo is in pre-beta: fully working, live, and still getting its polish.
You'll find rough edges — that's the point of this phase. When something feels
off, confusing, or broken, tell us: `[FEEDBACK CHANNEL]`. Feedback from early
travelers is what shapes what this becomes.

### Closing CTA

**Your next trip is one conversation away.**

**[Plan a trip →]** &nbsp;·&nbsp; Free during pre-beta. English y español.

---

## 4. Talking points (verbal pitch outline)

**The one-liner**
- "It's an AI travel agent that actually builds the trip — you describe it,
  and you get a real day-by-day itinerary with live flights and real places,
  saved and mapped. Plan less, travel more."

**The mission (why it exists)**
- Rule #1 of the project: build something *I* genuinely enjoy using. I'm a
  frequent traveler; I use it to plan my own trips before I build anything new.
- If it beats ChatGPT for my trips, it can beat it for yours. That's the test
  it has to pass every week.

**The differentiation**
- "ChatGPT gives you advice; Golden Tempo gives you a trip."
- Everything is grounded in real data: Google Places for venues, live airline
  inventory for flights, price alerts on fares, recommendations from actual
  locals credited by name — not hallucinated restaurant names.
- The conversation produces an artifact: a saved, editable, shareable itinerary
  with a map, a print packet, and calendar export — not a wall of text.
- You can even paste in a trip you planned in ChatGPT or Claude, and it becomes
  a real itinerary.

**The build story (the learnings thread)**
- Solo founder, zero to a production application: real accounts (Google/Apple
  sign-in), real providers, streaming AI, two languages, running live today.
- Built with AI leverage — Claude Code wrote most of the code while I acted as
  product lead, architect, and QA. The meta-project is streamlining
  idea-to-working-app, and I'm sharing those learnings publicly as I go.
- The name: Golden Tempo was a racehorse. $100 on him at the Derby, $700 back.
  This is the longer-odds bet.

**Status / traction framing**
- Live in production at goldentempotravel.com, on real infrastructure, with
  real flight and places data. LLC formed. Pre-beta = invite-only friends &
  family while the rough edges get sanded.

**The ask**
- Use it for a real trip — or a dream one. Then tell me what you didn't like.
- "Your feedback is the best asset I can get at this stage. I don't need you
  to be nice about it; I need you to be honest."
- Send it to `[FEEDBACK CHANNEL]`.

---

## 5. Claims guardrails (keep the copy honest)

Verified against the shipped app as of 2026-08-01. Safe to claim: AI chat →
day-by-day itineraries; live flight search + price alerts (Duffel); real places
(Google Places); locally-sourced recommendations with named attribution; trip
map; sharing & collaboration; print packet; calendar export; import from
ChatGPT/Claude; traveler preferences; Google/Apple/email sign-in; English +
Spanish.

Do **not** claim (not shipped — roadmap only):

- **In-app booking or payments** — booking is link-out handoffs to providers.
- **In-app accommodation listings/search** — stays are tracked, not searched.
- **Offline mode.**
- Say "live airline inventory" / "real fares," not "cheapest guaranteed."

Also: it's **pre-beta** — always set the "things will be rough" expectation
explicitly; over-promising to friends and family burns the exact goodwill this
phase depends on.
