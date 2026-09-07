# Bougainvilla n8n workflow — what every node does

61 nodes, 8 independent flows in one workflow. They share nothing except the
workflow file: each has its own trigger and runs on its own.

**Only 3 of the 8 flows are real.** The other 5 still point at
`example.invalid` — placeholders inherited from the source workflow that were
never wired to anything. See [Flows that do not work yet](#flows-that-do-not-work-yet).

| # | Flow | Trigger | Status |
|---|---|---|---|
| 1 | Meta verification | `GET /bougainvilla-instagram` | **live** |
| 2 | Instagram DMs | `POST /bougainvilla-instagram` | **live** — the main one |
| 3 | Dashboard metrics | `GET /bougainvilla-dashboard` | **live** |
| 4 | Booking lead form | `POST /bougainvilla-booking-lead` | placeholder |
| 5 | Voice agent | `POST /bougainvilla-voice-event` | placeholder |
| 6 | Follow-up scheduler | every 2 hours | placeholder — **fails on every run** |
| 7 | Pricing scheduler | daily 05:15 | placeholder — **fails on every run** |
| 8 | Review handling | `POST /bougainvilla-review` | placeholder |

---

## 1 · Meta verification — 5 nodes

Meta calls this once when you save the callback URL, to prove you own it.
Same path as the DM webhook, different HTTP method.

| Node | What it does |
|---|---|
| **Meta Webhook Verify** | Catches Meta's `GET`, which carries `hub.mode`, `hub.verify_token` and `hub.challenge`. |
| **Check Meta Verify Token** | Compares the token Meta sent against the one stored in this node's code. The token is a constant here because n8n Community has no variables. |
| **Verify Token Valid** | An IF. True → challenge, false → reject. |
| **Return Challenge (200)** | Echoes `hub.challenge` back as plain text. Meta accepts the URL only if the body is exactly this. |
| **Reject Verification (403)** | Wrong token. Refuses instead of echoing, so nobody else can claim your webhook. |

---

## 2 · Instagram DMs — 14 nodes

**This is the booking agent.** A guest DMs the villa; this replies.

The model is used in exactly **two** of these nodes, and it never decides what
to ask. Everything between is fixed logic.

### The guard nodes

| Node | What it does |
|---|---|
| **Instagram Booking Webhook** | `POST` from Meta. Set to `rawBody` — the exact bytes are needed to check the signature; a parsed body would not match. Acks immediately, then processes. |
| **Verify Instagram Signature** | Recomputes `X-Hub-Signature-256` (HMAC-SHA256 of the raw body with your **Instagram app secret**) and drops anything that does not match. Without this, anyone who learns the URL can make the villa send messages. Pure JavaScript SHA-256, because n8n's Code sandbox has no `crypto`. |
| **Normalize Instagram Event** | Meta sends a nested batch. This flattens it to one item per message and **throws most of them away**: echoes of our own replies (else it talks to itself forever), read receipts, delivery receipts, reactions, deleted messages, empty text, and — importantly — anything whose `recipient.id` is not the villa account. |

### The state machine

| Node | What it does |
|---|---|
| **Load Guest State** | Supabase `get_guest_state`. Returns what we already know about this guest: dates, nights, guests, name, phone, which state the conversation is in, and the last 8 messages. **This is what replaced the old chat memory that kept forgetting.** |
| **Build Extraction Prompt** | Writes a prompt asking one narrow question: *what does this single message add?* It is given today's date so "next Friday" resolves correctly. |
| **Extract Guest Details** 🤖 | **Model call 1.** Sarvam reads the guest's sentence and returns JSON only: dates, nights, guests, name, phone, and flags for agreed / declined / price objection / wants a human / which language. |
| **Merge Guest Slots** | Merges the new answers into the old. **A blank never overwrites a saved answer**, so a message saying nothing cannot wipe the date. Everything is validated here — a date must be real and in the future, a phone must be 10–13 digits — because the model is not trusted further than a regex will carry it. |
| **Quote And Availability** | Supabase `quote_stay`. Is it free, what does it cost, what does the weekend rate include, and what is the nearest free Mon–Thu if they came asking about a weekend. One call, both answers. |
| **Decide Next Question** | **The brain.** Picks the state and writes the exact sentence to send. See the table below. No model involved. |
| **Build Compose Prompt** | Wraps that sentence in an instruction: say this, warmly, in the guest's language, add nothing. |
| **Compose Guest Reply** 🤖 | **Model call 2.** Sarvam rephrases. That is all it does. |
| **Finalize Reply** | Checks the model's version. **Any number of 1,000 or more that we did not give it, and the reply is thrown away** and the plain sentence sent instead. Same for an empty reply, an essay, or one that dropped the price. This is what stops a friendly model inventing a discount. |
| **Send Instagram AI Reply** | Posts to `graph.instagram.com`. The URL is **pinned to the villa account id** — it used to be built from whoever received the DM, which made it try to reply as a tester's personal account and fail. |
| **Save Conversation Turn** | Supabase `save_guest_turn`. Writes the slots, the state, and both messages. Meta retries are ignored because the message id is unique. |

### What Decide Next Question chooses

Checked top to bottom. First match wins.

| State | When | What it says |
|---|---|---|
| `HUMAN` | complaint, refund, emergency, or asked the same thing 3× | hands off to a person |
| `HELD` | a live hold, nothing changed | acknowledges, does not re-announce |
| `NEW` | no dates yet | "Which dates were you looking at?" |
| `DATES` | dates but no headcount | "How many guests will you be?" |
| `UNAVAILABLE` | those dates are taken | offers the next free date |
| `PRICE_OBJECTION` | "too expensive" | **holds the weekend price, offers the nearest Mon–Thu instead** |
| `QUOTED` | free and priced | the price, what the weekend includes, "shall I hold it?" |
| `NEEDS_NAME` | said yes | "What name should I put it under?" |
| `NEEDS_PHONE` | has a name | "A number our caretaker can reach you on?" |
| `HOLD_PLACED` | everything | "Held for 24 hours. Our team will call to confirm." |

Because the state comes from the saved answers, a guest who opens with
*"villa for 8 on the 14th, 2 nights"* jumps straight to the price.

**Never:** confirms a booking, takes payment, negotiates, invents a discount.
A hold is not a booking — it expires, it blocks the dates while live, and a
person confirms it.

### If something breaks

All four network calls are set to **continue on error**, and every step has a
plain fallback. Sarvam down → the guest is still asked for the first missing
answer. Supabase down → still answered, just without memory for that turn.
**A dead dependency must never mean silence.**

---

## 3 · Dashboard metrics — 5 nodes

| Node | What it does |
|---|---|
| **Dashboard Metrics Webhook** | `GET`, called by the Vercel function — never by the browser. |
| **Authorize Dashboard Request** | Checks `x-api-key`. Wrong or missing → stops here. |
| **Fetch Supabase Metrics** | One call to `dashboard_metrics()`, which does all the counting in SQL. |
| **Shape Dashboard Metrics** | Adds `source` and `generated_at`, passes the rest through. On failure returns `source: "no_db"` so the page can say *database not set up* instead of showing zeros. |
| **Respond Dashboard Metrics** | Returns the JSON. Always 200, so the page renders in every case. |

The browser never holds a key and never learns the n8n address. n8n is the
only thing that talks to Supabase.

---

## Flows that do not work yet

These five came from the original source workflow. Every one of them calls
`example.invalid`, which does not exist. **They will fail if triggered.**

| Flow | Nodes | Needs |
|---|---|---|
| **Booking lead form** | 8 | a real PMS and a messaging API |
| **Voice agent** | 9 | Sarvam voice + a support desk |
| **Follow-up scheduler** | 6 | a CRM to list due leads |
| **Pricing scheduler** | 6 | PMS metrics + an approvals inbox |
| **Review handling** | 8 | a review platform API |

Each follows the same shape: normalise the input → build a prompt → ask Sarvam
→ act on the answer → reply.

### ⚠ Two of them run on a timer

**Follow-up Scheduler** fires every 2 hours and **Pricing Scheduler** at 05:15
daily. Both call `example.invalid`, so both **fail every single time** and fill
the execution log with red. That is very likely most of the failures you have
been seeing.

Nothing breaks if you disable those two trigger nodes — no live flow touches
them. Right-click the trigger → Deactivate.

---

## Credentials

Three, shared across all flows.

| Name in n8n | Type | Used by |
|---|---|---|
| `Supabase (Bougainvilla)` | Supabase API | all 4 Supabase calls |
| `Sarvam AI (api-subscription-key)` | Header Auth | all Sarvam calls |
| `Instagram Graph (Bearer)` | Bearer Auth | Send Instagram AI Reply |

Two secrets are **not** credentials, because n8n Community has no variables —
they are constants inside Code nodes:

- the Meta verify token, in **Check Meta Verify Token**
- the Instagram app secret, in **Verify Instagram Signature** — this is the
  secret from *Instagram → API setup with Instagram login*, **not** the app
  secret on App Settings → Basic. They are different values and the wrong one
  fails every signature.

---

## Where the logic actually lives

Most of the thinking is in Supabase, not n8n. That is deliberate: SQL is
testable and n8n Code nodes are not.

| Function | What it decides |
|---|---|
| `get_guest_state` | what we already know about this guest |
| `save_guest_turn` | writes it back; blanks never overwrite |
| `quote_stay` | free or not, the price, the weekend inclusions, the midweek alternative |
| `tariff_nightly` | the price of each night and why |
| `next_midweek_opening` | the nearest all-weekday gap |
| `dashboard_metrics` | every number on the dashboard |
| `pricing_config` | **one row** holding rates, the discount ladder, costs, the target |

To change pricing you edit that one row. Nothing is redeployed.
