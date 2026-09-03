# What the Bougainvilla workflow needs to run

Two kinds of secret, and the difference matters:

- **n8n credential objects** — created in the n8n UI (Credentials → New). The
  workflow needs exactly **one**.
- **Environment variables** — everything else. Set on the n8n instance, read at
  runtime via `$env.X`. Nothing else in the workflow stores a secret.

Nothing here is stored in the repo. `.env.example` is the checklist; the filled
version never gets committed.

---

## 1 · Meta — Instagram DMs

One Meta app, one System User token. developers.facebook.com → your app.

| Variable | Where to get it |
|---|---|
| `META_APP_SECRET` | Settings → Basic → **App Secret** |
| `META_VERIFY_TOKEN` | **You invent this.** Any random string (`openssl rand -hex 16`). Paste the same value into Meta's "Verify token" box |
| `META_ACCESS_TOKEN` | Business Settings → System Users → Generate token. A System User token, never the temporary one from the product tab |
| `INSTAGRAM_BUSINESS_ID` | The Instagram professional account's IGSID |

**Token permissions** (Instagram API with Facebook Login):
`instagram_basic`, `instagram_manage_messages`,
`pages_manage_metadata`, `pages_show_list`, `business_management`.

**Webhook fields to subscribe:** `messages`, `messaging_postbacks`.

Step-by-step walkthrough: **[instagram-setup.md](instagram-setup.md)**.

### Three things that will bite you

- `META_APP_SECRET` is **required**, not optional. Every inbound webhook is
  HMAC-verified before anything is processed. Leave it unset and the workflow
  refuses the request rather than trusting it — the correct behaviour for a URL
  anyone can find.
- **Instagram's 24-hour window.** Outside 24 hours of the guest's last message
  you cannot send free text. The AI reply node sends free text, so it works for
  live conversations but not cold outreach. The scheduled follow-up branch goes
  through `GUEST_MESSAGING_URL` for exactly this reason.
- **"Allow access to messages" must be ON** in the Instagram app
  (Settings → Messages and story replies). Without it the API receives no DMs,
  with no error anywhere.

## 2 · Sarvam AI

| Variable | Where |
|---|---|
| `SARVAM_API_KEY` | dashboard.sarvam.ai → API keys |

Used two different ways:

- **HTTP Request nodes** (sales, voice, follow-up, pricing, reviews) call
  `https://api.sarvam.ai/v1/chat/completions` with an `api-subscription-key`
  header. These work with the key alone.
- **The AI Booking Agent** uses n8n's `lmChatOpenAi` node, which needs the one
  credential object:

  > **Credentials → New → OpenAI** — API key: your Sarvam key,
  > Base URL: `https://api.sarvam.ai/v1`

  Then open **Sarvam AI Chat Model** in the canvas and select it (the imported
  node has a `REPLACE_ME` placeholder, so n8n will prompt you).

  ⚠️ **Verify this one.** That node sends `Authorization: Bearer <key>`, while the
  HTTP nodes send `api-subscription-key`. If Sarvam's OpenAI-compatible endpoint
  rejects Bearer auth, the agent branch won't run — swap the model node for an
  HTTP Request node using the same header as the others. Test it before going
  live; it's the only credential in this list I couldn't verify from here.

---

## 3 · PMS / channel manager

Whatever runs the actual inventory — Hostaway, Guesty, Beds24, or in-house.

`PMS_API_KEY`, `PMS_AVAILABILITY_URL`, `PMS_PROPERTY_SEARCH_URL`,
`PMS_BOOKING_URL`, `PMS_PRICING_DATA_URL`

## 4 · CRM

`CRM_API_KEY`, `CRM_LEAD_URL`, `CRM_FOLLOWUP_URL`, `CRM_METRICS_URL`

`CRM_METRICS_URL` is the one the dashboard reads — see
[dashboard-contract.md](dashboard-contract.md) for the shape it must return.

## 5 · Support and staff alerts

`SUPPORT_API_KEY`, `SUPPORT_TICKET_URL`, `HUMAN_HANDOFF_URL`,
`STAFF_ALERT_API_KEY`, `STAFF_ALERT_URL`

## 6 · Guest messaging (non-Meta)

`MESSAGING_API_KEY`, `GUEST_MESSAGING_URL` — the scheduled follow-up sender.

## 7 · Reviews

`REVIEW_API_KEY`, `REVIEW_REPLY_URL`

## 8 · Revenue approval

`APPROVAL_API_KEY`, `PRICING_APPROVAL_URL` — where a human approves AI price
changes. The workflow **never** writes a price back to the PMS on its own; every
recommendation goes out with `requires_approval: true`.

## 9 · Voice agent callback

`SARVAM_AGENT_CALLBACK_URL`, `SARVAM_AGENT_API_KEY`

## 10 · Dashboard link

`DASHBOARD_API_KEY` — shared secret, **must match** the value in Vercel.
Generate with `openssl rand -hex 32`.

---

## n8n instance settings (not credentials, but required)

```bash
NODE_FUNCTION_ALLOW_BUILTIN=crypto   # signature + token verification needs it
WEBHOOK_URL=https://n8n.yourdomain.com   # must be public HTTPS; Meta will not call http://
N8N_ENCRYPTION_KEY=<random>          # or n8n regenerates it and loses saved credentials
```

Meta will not deliver to `localhost`, a self-signed certificate, or plain HTTP.

---

## Groups you can leave empty for now

The workflow imports and activates with **only** section 1 (Meta), section 2
(Sarvam) and section 10 (dashboard) filled in. Sections 3-9 fall back to
`https://example.invalid/...`, so those calls fail harmlessly instead of sending
anything anywhere. Fill them in as each system gets connected.

---

## Known gaps — deliberate, not oversights

- **No de-duplication.** Meta retries a webhook it thinks failed. Nothing here
  tracks seen `leadgen_id` / message IDs, so a retry can produce a second reply.
  Add a Redis or Postgres node keyed on message ID before high volume.
- **No persistence.** Conversation memory is n8n's in-memory buffer — it clears
  on restart. Swap `memoryBufferWindow` for a Postgres/Redis memory node for
  anything long-running.
- **Payments are out of scope.** The agent is instructed to use only payment
  links returned by tools; no payment gateway is wired up.
