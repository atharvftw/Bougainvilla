# Bougainvilla CRM — n8n workflow

`bougainvilla-crm.workflow.json` — import via **Workflows → Import from File**.

Setup: [../docs/deploy.md](../docs/deploy.md) ·
Secrets: [../docs/n8n-credentials.md](../docs/n8n-credentials.md)

> **Node-by-node reference:** [`WORKFLOW-CONTEXT.md`](./WORKFLOW-CONTEXT.md)
> — what every one of the 61 nodes does, which flows are live, and which are
> still placeholders.

## Eight independent flows in one workflow

| Trigger | What it does |
|---|---|
| Meta verification (GET) | Answers Meta's ownership handshake on the Instagram callback URL |
| Instagram DMs (POST) | Signature-verified → normalised → slot state machine → reply in the same thread |
| Booking lead webhook | Form lead → live PMS availability → Sarvam sales reply → guest message |
| Voice agent webhook | Transcript → triage → ticket **only if escalation is needed** → callback |
| Follow-up scheduler (2-hourly) | Pulls due leads → one AI message each → sends |
| Pricing scheduler (05:15 daily) | Per-property revenue analysis → human approval queue |
| Review webhook | Sentiment + drafted reply → publish → staff alert if rating ≤ 3 |
| Dashboard webhook (GET) | Key-protected metrics, read from Supabase, for the Vercel dashboard |

### The Instagram booking flow

Eleven nodes, and the model is used in exactly two of them:

```
Instagram webhook → verify signature → normalise
  → Load Guest State        read the saved slots from Supabase
  → Build Extraction Prompt
  → Extract Guest Details   MODEL · what does this one message add?
  → Merge Guest Slots       merge and validate; a regex has the last word
  → Quote And Availability  is it free, and what does it cost?
  → Decide Next Question    the state table — code, not judgement
  → Build Compose Prompt
  → Compose Guest Reply     MODEL · say that sentence warmly, in their language
  → Finalize Reply          reject the model if it invented anything
  → Send Instagram AI Reply
  → Save Conversation Turn  slots, state and both messages
```

The model never decides what to ask. It reads a messy sentence, and it phrases
a sentence we chose. Everything between those two jobs is deterministic, so the
same guest saying the same thing gets the same question every time.

Each of the four network calls is set to continue on error, and every step has
a deterministic fallback: if Sarvam is down the guest is still asked for the
first empty slot, and if the reply is unusable the plain template goes out
instead. A dead dependency must never mean silence.

## Changes from the source workflow

Beyond renaming to Bougainvilla, moving webhook paths from `airbnb-*` to
`bougainvilla-*`, and cutting the workflow down to Instagram (the WhatsApp and
Meta Lead Ads branches are removed, not just disconnected):

**Bugs that would have failed silently**

- Every auth header read as literal text — `Bearer {{$env.KEY}}` and
  `{{$env.SARVAM_API_KEY}}` — because the leading `=` that marks an n8n
  expression was missing, so the `{{...}}` was never evaluated and no API call
  was ever authenticated. Fixed on 17 `Authorization` headers and 5
  `api-subscription-key` headers.
- All six agent tools built their auth header as `={'Bearer '+(...)}` — single
  braces, which n8n does not evaluate. Every tool call would have gone out
  unauthenticated. Fixed to `={{ 'Bearer ' + (...) }}`.
- `Prepare Follow-up Send` and `Prepare Pricing Approval` used
  `$input.first()` while processing many items, so every lead got the *first*
  lead's AI copy and every property got the first property's price. Both now run
  per-item.
- `Respond to Lead`, `Respond Voice Event` and `Respond Review` returned the
  response of the *last HTTP call in the chain* rather than the workflow's own
  result. All three now respond with their intended payload.

**Configuration model**

- Configured entirely through the n8n UI — credentials for outbound auth, three
  marked constants in Code nodes, one node parameter. No `$env`, no `$vars`, no
  server access. See [../docs/n8n-config.md](../docs/n8n-config.md).
- Signature verification implements SHA-256 and HMAC in plain JavaScript. The
  Code sandbox provides neither `require()` nor a `crypto` global, so both the
  usual approaches throw. Digests verified byte-identical to Node's
  `createHmac`; do not replace it with a crypto call.

**Route**

- Targets **Instagram API with Instagram Login**, so the send node calls
  `graph.instagram.com` — not `graph.facebook.com`, which the original used.
  Pointing this route at the Facebook host returns an OAuth error that reads
  like a bad token.

**Security**

- Meta signs every webhook with `X-Hub-Signature-256`. The original verified
  nothing — anyone who found the URL could inject fake bookings and leads. Now
  HMAC-SHA256 over the raw body, constant-time compared, and the request is
  rejected outright if `META_APP_SECRET` is unset.
- The verify-token comparison is constant-time (was `===`).
- Failed verification returns **403**, not a 500 stack trace.
- The Instagram path had no GET verification handler — only the Lead Ads path
  did — so Instagram could never have been registered with Meta at all. Meta
  GET-verifies each callback URL separately.
- `META_ACCESS_TOKEN` moved out of the query string into an `Authorization`
  header, so it stops appearing in access logs.

**Instagram event handling**

- Meta fires a webhook for **every message the business sends**
  (`message.is_echo`). Nothing filtered it, so the agent would have read its
  own reply, answered it, and looped — spending a model call and DMing the
  guest on every pass. Echoes, read/delivery receipts, reactions, deleted
  messages and text-less events are now dropped, ending the branch cleanly.
- One webhook can carry several DMs from different people. The normaliser took
  only `entry[0].messaging[0]`, and the two Code nodes after it ran once for
  all items and returned one result — so extra messages were silently dropped,
  and a `.first()` lookup would have paired a reply with the wrong guest. All
  three now handle every message, paired per item.

**Reply path ordering**

- `Log AI Lead Decision` sat between the agent and the reply and, like every
  n8n node by default, stopped the workflow on error. It points at a
  placeholder CRM until one is connected, so the first real answer the agent
  produced would have died there and the guest would have got nothing. The
  reply is now sent first and logging follows, set to continue on error — a
  CRM that is down costs a log line, never a reply.

**Reply as the villa, and only to the villa's DMs**

- `Send Instagram AI Reply` built its URL from `recipientId` — whichever
  account the DM was addressed to. A tester's personal account subscribed to
  the same app fires this webhook too, so the workflow tried to reply *as* that
  account with the villa's token and Meta refused: *"Object with ID … does not
  exist, cannot be loaded due to missing permissions"*. The URL is now pinned
  to the villa's account.
- `Normalize Instagram Event` drops any event whose `recipient.id` is not the
  villa. Answering a third party's DMs would be wrong even if the token allowed
  it.

**The agent forgot every answer it was given**

- The old flow hung a LangChain agent off `Guest Conversation Memory`, n8n's
  in-RAM window buffer. It held a transcript and nothing structured, so on
  every message the agent re-derived *what do I know about this guest?* from
  raw chat text inside a prompt that also carried its rules, its output schema
  and six tool descriptions. It dropped things, and asked again. Guests were
  answering the same question three times.
- Nothing was being saved between messages. That was the whole bug, and no
  amount of prompt engineering was going to fix it.
- The agent, its memory and its six tools are **gone**. The answers are now
  columns on `leads`, the next question comes out of a state table in
  `Decide Next Question`, and availability and price come from `quote_stay()`
  in one call rather than a tool the model had to remember to use.
- Five of those six tools posted to `example.invalid` anyway. The agent called
  `human_handoff` on the first real DM, the request failed, and the failure
  took the whole execution down — so the guest got nothing at all.

**What the agent may and may not do**

- **May:** state availability, quote the tariff, place a 24-hour hold, take a
  name and phone number.
- **May not:** confirm a booking, take payment, negotiate, or invent a
  discount. A guest who pushes on price is handed to a human, every time.
- A hold is not a booking: it expires, it blocks the dates while it is live,
  and a person confirms it.
- Asking the same slot three times escalates to a human. A loop is a failure,
  not persistence.

**Persistence**

- Every handled message goes to Supabase through one `save_guest_turn` call
  that upserts the guest and records both sides of the exchange atomically.
  `messages.provider_message_id` is `UNIQUE`, so a Meta webhook retry
  conflicts and is ignored rather than producing a second reply — the
  de-duplication gap that was previously open by design.
- The dashboard endpoint reads `dashboard_metrics()`, one call returning
  everything the page needs.

**Behaviour

- The original routed channels through chained IFs, with the `meta_ads` branch
  sitting on the false-output of the Instagram check — so any unrecognised
  channel fell through into the Meta Ads path. With one channel the chain is
  gone entirely.
- Voice calls only open a support ticket when triage actually escalates. Before,
  every call created one.
- `STAFF_ALERT_URL` had two different fallback values in different nodes; unified.

See [../docs/n8n-credentials.md](../docs/n8n-credentials.md) for the gaps that
are still open by design (retry de-duplication, memory persistence, payments).
