# Connecting Instagram — click by click

This follows **Instagram API with Instagram Login** (`use_case_enum=INSTAGRAM_BUSINESS`
in the app URL) — the route that does *not* require a Facebook Page.

Everything below produces four values:

```
META_APP_SECRET          Step 1
META_ACCESS_TOKEN        Step 3
INSTAGRAM_BUSINESS_ID    Step 3
META_VERIFY_TOKEN        Step 4   (you generate this one yourself)
```

> **If `developers.facebook.com` bounces you to `business.facebook.com`:** you are
> logged in with a Meta Business Account, not a personal Facebook profile. Only a
> personal profile can create apps. Add your personal profile as an Admin of the
> business portfolio (business.facebook.com → Settings → People → Add), then log
> in to the developer site as that profile.

---

## Step 0 · Prerequisites

- [ ] Instagram account switched to **Professional** (Business or Creator)
- [ ] In the Instagram mobile app: **Settings → Messages and story replies →
      Allow access to messages** = **ON**

That second one is the classic silent failure. With it off, every step below
succeeds and no DM ever reaches your webhook, with no error anywhere.

No Facebook Page is required on this route.

---

## Step 1 · App Secret → `META_APP_SECRET`

In your app: **App settings → Basic** → next to **App Secret** click **Show**.

→ `META_APP_SECRET` ✅

This signs every incoming webhook. The workflow rejects traffic when it is
unset — deliberate, not a bug.

---

## Step 2 · Permissions

On **Instagram → API setup with Instagram login**, panel 1 asks for:

```
instagram_business_basic
instagram_business_manage_comments
instagram_business_manage_messages
```

The workflow only needs `instagram_business_basic` and
`instagram_business_manage_messages`. Leaving comments in is harmless.

---

## Step 3 · Token + account ID → `META_ACCESS_TOKEN`, `INSTAGRAM_BUSINESS_ID`

Panel 2, **Generate access tokens**. Two things in order, and the order matters:

1. **Roles tab → Instagram Testers → Add people** → add your Instagram account.
2. **Accept the invite from inside Instagram**: instagram.com → Settings →
   **Apps and websites → Tester invites → Accept**. Until you accept, the next
   step fails with an unhelpful error.
3. Back on API setup → **Add account** → log in with the Instagram account.

You now get:

- the **access token** → `META_ACCESS_TOKEN` ✅
- the **Instagram account ID** shown next to it → `INSTAGRAM_BUSINESS_ID` ✅

### ⚠️ This token expires in 60 days

Unlike a System User token, an Instagram User access token is long-lived but
**not permanent**. Refresh it before day 60 (the token must be at least 24 hours
old to be refreshable, and once expired it cannot be refreshed — you start over):

```bash
curl "https://graph.instagram.com/refresh_access_token\
?grant_type=ig_refresh_token&access_token=$META_ACCESS_TOKEN"
```

Put the returned token back into `META_ACCESS_TOKEN` in n8n. **Set a calendar
reminder for day 50.** An expired token fails silently — the agent simply stops
replying.

---

## Step 4 · Verify token → `META_VERIFY_TOKEN`

Nobody issues this. You invent it, and it only has to match on both sides:

```bash
openssl rand -hex 16
```

→ `META_VERIFY_TOKEN` ✅

---

## Step 5 · Webhook (panel 3)

**This panel is blocked until two things are true**, which is why it looks
unfillable right now:

1. **n8n is deployed at a public HTTPS URL with the workflow activated.** Meta
   calls the URL during setup; if nothing answers, the save fails.
2. **The app is in published state** — panel 3 says so explicitly. A development
   app receives no webhooks.

Then fill in:

| Field | Value |
|---|---|
| Callback URL | `https://your-n8n/webhook/bougainvilla-instagram` |
| Verify token | from Step 4 |
| Subscribe to fields | **`messages`** |

Test the handshake yourself *before* pasting anything into Meta:

```bash
# expect: test123
curl "https://your-n8n/webhook/bougainvilla-instagram?hub.mode=subscribe&hub.verify_token=YOUR_TOKEN&hub.challenge=test123"

# expect: 403
curl -i "https://your-n8n/webhook/bougainvilla-instagram?hub.mode=subscribe&hub.verify_token=wrong&hub.challenge=test123"

# expect: rejected — unsigned
curl -X POST -H 'content-type: application/json' -d '{"entry":[]}' \
  https://your-n8n/webhook/bougainvilla-instagram
```

If the third succeeds, `META_APP_SECRET` isn't reaching the Code node. Fix that
before pointing Meta at the URL.

---

## Step 6 · App Review

In development mode the agent only replies to accounts with the **Instagram
Tester** role. Real customers need Advanced Access to
`instagram_business_manage_messages`, which requires Business Verification plus
App Review.

Start this early — it runs days to weeks and is the usual reason a finished
build sits unusable.

---

## Two API facts this route changes

- **Host is `graph.instagram.com`**, not `graph.facebook.com`. The workflow's
  send node uses the Instagram host; pointing it at the Facebook host returns an
  OAuth error that reads like a bad token.
- **You can only message people who messaged you first**, and only within
  **24 hours** of their last message. The AI reply node sends free text, so it
  covers live conversations and nothing colder. The scheduled follow-up branch
  routes through `GUEST_MESSAGING_URL` for exactly this reason.

---

## Phone

Meta is the wrong vendor here. The workflow's voice branch expects a telephony
provider to POST transcripts to
`https://your-n8n/webhook/bougainvilla-voice-event`.

**Sarvam Voice Agents** is the natural fit — rent an Indian number inside it,
models are self-hosted, data stays in India. Set `SARVAM_AGENT_CALLBACK_URL` and
`SARVAM_AGENT_API_KEY` in n8n.
