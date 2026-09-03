# Bougainvilla CRM — n8n workflow

`bougainvilla-crm.workflow.json` — import via **Workflows → Import from File**.

Setup: [../docs/deploy.md](../docs/deploy.md) ·
Secrets: [../docs/n8n-credentials.md](../docs/n8n-credentials.md)

## Seven independent flows in one workflow

| Trigger | What it does |
|---|---|
| Meta verification (GET ×3) | Answers Meta's ownership handshake on all three callback paths |
| WhatsApp / Instagram / Lead Ads (POST) | Signature-verified → normalised → AI agent → reply on the same channel |
| Booking lead webhook | Form lead → live PMS availability → Sarvam sales reply → guest message |
| Voice agent webhook | Transcript → triage → ticket **only if escalation is needed** → callback |
| Follow-up scheduler (2-hourly) | Pulls due leads → one AI message each → sends |
| Pricing scheduler (05:15 daily) | Per-property revenue analysis → human approval queue |
| Review webhook | Sentiment + drafted reply → publish → staff alert if rating ≤ 3 |
| Dashboard webhook (GET) | Key-protected metrics for the Vercel dashboard |

The three messaging channels converge on one **Bougainvilla AI Booking Agent**
with shared memory and six tools (availability, property search, create booking,
CRM lead, support ticket, human handoff), then fan back out by channel.

## Changes from the source workflow

Beyond renaming to Bougainvilla and moving webhook paths from `airbnb-*` to
`bougainvilla-*`:

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

**Security**

- Meta signs every webhook with `X-Hub-Signature-256`. The original verified
  nothing — anyone who found the URL could inject fake bookings and leads. Now
  HMAC-SHA256 over the raw body, constant-time compared, and the request is
  rejected outright if `META_APP_SECRET` is unset.
- The verify-token comparison is constant-time (was `===`).
- Failed verification returns **403**, not a 500 stack trace.
- Meta verifies each callback URL separately, so the WhatsApp and Instagram
  paths now have GET handlers too — previously only the Lead Ads path did, and
  the other two could never have been registered.
- `META_ACCESS_TOKEN` moved out of the query string into an `Authorization`
  header, so it stops appearing in access logs.

**Behaviour**

- Channel routing is one Switch node instead of chained IFs — the original's
  `meta_ads` branch sat on the false-output of the Instagram check, so any
  unrecognised channel fell through into the Meta Ads path.
- Voice calls only open a support ticket when triage actually escalates. Before,
  every call created one.
- `STAFF_ALERT_URL` had two different fallback values in different nodes; unified.

See [../docs/n8n-credentials.md](../docs/n8n-credentials.md) for the gaps that
are still open by design (retry de-duplication, memory persistence, payments).
