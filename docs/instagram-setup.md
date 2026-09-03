# Connecting Instagram — click by click

Everything below produces four values. Nothing else is needed from Meta.

```
META_APP_SECRET          Step 2
INSTAGRAM_BUSINESS_ID    Step 4
META_ACCESS_TOKEN        Step 5
META_VERIFY_TOKEN        Step 6   (you generate this one yourself)
```

**Ads Manager is not involved.** None of these live there. You need two other
Meta surfaces:

| Surface | URL | What it gives you |
|---|---|---|
| Developers | developers.facebook.com | the app, App Secret, webhooks |
| Business Settings | business.facebook.com/settings | the permanent token |

---

## Step 1 · Prerequisites

These block everything downstream, so clear them first.

- [ ] A Facebook **Page** for Bougainvilla
- [ ] Instagram account switched to **Professional** (Business or Creator)
- [ ] That Instagram account **linked to the Page**
      — Page → Settings → Linked accounts → Instagram
- [ ] In the Instagram mobile app: **Settings → Messages and story replies →
      Allow access to messages** = **ON**

That last one is the classic silent failure. With it off, every step below
succeeds and no DM ever arrives at your webhook, with no error anywhere.

---

## Step 2 · Create the app → `META_APP_SECRET`

developers.facebook.com → **My Apps → Create App**

- Use case: **Other** → Type: **Business**
- Link it to your Business portfolio

Then **Settings → Basic** → next to **App Secret** click **Show**.

→ `META_APP_SECRET` ✅

This is what signs every incoming webhook. The workflow rejects traffic when it
is unset — that is deliberate, not a bug.

---

## Step 3 · Add the Instagram product

Left sidebar → **Add Product** → **Instagram** → **Set up**.

Choose **Instagram API with Facebook Login** (the route that uses your Page).
Connect the Page from Step 1.

---

## Step 4 · Instagram account ID → `INSTAGRAM_BUSINESS_ID`

Usually shown on the Instagram product page. If it isn't, get it once you have
the token from Step 5:

```bash
curl "https://graph.facebook.com/v23.0/me/accounts?fields=instagram_business_account&access_token=TOKEN"
```

The `instagram_business_account.id` in the response is the value.

→ `INSTAGRAM_BUSINESS_ID` ✅

---

## Step 5 · Permanent token → `META_ACCESS_TOKEN`

**The step most people get wrong.** Tokens shown on the product tab expire in
24 hours. Production needs a System User token, which does not expire.

business.facebook.com/settings → **Users → System Users → Add**

- Name: `bougainvilla-n8n`
- Role: **Admin**

**Assign Assets** — assign both:

- your **App** → Full control
- your **Page** → Full control

**Generate new token** → select your app → tick:

```
instagram_basic            pages_manage_metadata
instagram_manage_messages  pages_show_list
business_management
```

→ `META_ACCESS_TOKEN` ✅

**Copy it immediately.** It is displayed exactly once and cannot be retrieved
again — if you lose it you generate a new one.

---

## Step 6 · Verify token → `META_VERIFY_TOKEN`

Nobody issues this. You make it up, and it just has to match on both sides:

```bash
openssl rand -hex 16
```

→ `META_VERIFY_TOKEN` ✅

---

## Step 7 · Webhook

Do this **after** n8n is live on public HTTPS with the workflow **activated** —
Meta calls the URL during setup and the subscription fails if nothing answers.

Instagram → **Configuration → Webhooks → Edit**:

| Field | Value |
|---|---|
| Callback URL | `https://your-n8n/webhook/bougainvilla-instagram` |
| Verify token | from Step 6 |
| Subscribe to fields | **`messages`**, **`messaging_postbacks`** |

Test the handshake yourself before pasting anything into Meta:

```bash
# expect: test123
curl "https://your-n8n/webhook/bougainvilla-instagram?hub.mode=subscribe&hub.verify_token=YOUR_TOKEN&hub.challenge=test123"

# expect: 403
curl -i "https://your-n8n/webhook/bougainvilla-instagram?hub.mode=subscribe&hub.verify_token=wrong&hub.challenge=test123"

# expect: rejected — unsigned
curl -X POST -H 'content-type: application/json' -d '{"entry":[]}' \
  https://your-n8n/webhook/bougainvilla-instagram
```

If the third one succeeds, `META_APP_SECRET` isn't reaching the Code node. Stop
and fix that before pointing Meta at the URL.

---

## Step 8 · App Review

Until you pass review the app is in **development mode**: the agent can only
reply to people added as app testers. Real customers need **Advanced Access** to
`instagram_business_manage_messages`, which requires Business Verification plus
App Review.

Start this early. It runs days to weeks and is the usual reason a finished build
sits unusable.

---

## The 24-hour rule

Outside 24 hours of the guest's last message you cannot send free text on
Instagram. The AI reply node sends free text, so it covers live conversations
and will be rejected for anything colder. The scheduled follow-up branch routes
through `GUEST_MESSAGING_URL` instead — point that at whatever channel you use
for re-engagement.

---

## Phone

Meta is the wrong vendor for this. The workflow's voice branch expects a
telephony provider to POST transcripts to
`https://your-n8n/webhook/bougainvilla-voice-event`.

**Sarvam Voice Agents** is the natural fit — you can rent an Indian number
inside it, the speech and reasoning models are self-hosted, and data stays in
India. Configure its callback to that URL and set `SARVAM_AGENT_CALLBACK_URL` /
`SARVAM_AGENT_API_KEY` in n8n.
