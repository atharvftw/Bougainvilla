# Connecting Instagram — click by click

This follows **Instagram API with Instagram Login** (`use_case_enum=INSTAGRAM_BUSINESS`
in the app URL) — the route that does *not* require a Facebook Page.

Everything below produces four values. Where each one goes in n8n is
**[n8n-config.md](n8n-config.md)**.

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

Both apply to the **villa account**, not your personal one:

- [ ] Villa Instagram account switched to **Professional** (Business or Creator)
- [ ] In the Instagram app on that account: **Settings → Messages and story
      replies → Allow access to messages** = **ON**

That second one is the classic silent failure. With it off, every step below
succeeds and no DM ever reaches your webhook, with no error anywhere.

No Facebook Page is required on this route.

---

## Step 1 · Instagram app secret → `META_APP_SECRET`

**Instagram → API setup with Instagram login** → the panel showing **app name,
Instagram app ID and Instagram app secret** → **Show** next to the secret.

→ `META_APP_SECRET` ✅

### ⚠️ Not the one under App settings → Basic

This route has **two** app secrets and they are not interchangeable:

| Secret | Where | Used for |
|---|---|---|
| **Instagram app secret** | Instagram → API setup with Instagram login | ✅ signs webhooks on this route |
| Facebook App Secret | App settings → Basic | the Facebook Login route — not this one |

Both are 32 hex characters, so the wrong one looks entirely plausible and fails
only when a webhook arrives, as `Invalid X-Hub-Signature-256`. If verification
fails with a secret you are sure of, this is why.

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

Panel 2, **Generate access tokens**. Order matters, and *which account* matters
more.

### Which account logs in?

**The villa account.** The token is scoped to whoever logs in, so signing in with
a personal account produces an agent sitting on the wrong inbox — it will never
see a villa DM.

Add **two** accounts as Instagram Testers, for different reasons:

| Account | Why |
|---|---|
| **Villa** (the business) | so **Add account** can connect it — it owns the token |
| **Your personal account** | so it can DM the agent while the app is in development mode |

The second is easy to miss. In development mode the app may only interact with
accounts that hold a role on it. Your personal account is not the business — it
is your **test customer**. Without a role it can DM the villa account and get no
reply, which looks exactly like a broken webhook.

### The sequence

1. **Roles tab → Instagram Testers → Add people** → add **both** handles.
2. **Accept both invites from inside Instagram.** Log into each account at
   instagram.com → Settings → **Apps and websites → Tester invites → Accept**.
   Until accepted, the next step fails with an unhelpful error.
3. Back on API setup → **Add account** → log in as **the villa account**.

You now get, both belonging to the villa account:

- the **access token** → `META_ACCESS_TOKEN` ✅
- the **Instagram account ID** shown next to it → `INSTAGRAM_BUSINESS_ID` ✅

Then test the loop by DMing the villa account **from your personal account**.

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

# returns 200 {"message":"Workflow was started"} - this is CORRECT, see below
curl -X POST -H 'content-type: application/json' -d '{"entry":[]}' \
  https://your-n8n/webhook/bougainvilla-instagram
```

**The third one always returns 200.** The POST webhook acks on receipt and runs
the flow afterwards, because Meta retries and eventually disables a subscription
that does not answer within a couple of seconds. The status code says nothing
about whether the payload was accepted.

Check the **Executions** tab instead. That run must show
`Verify Instagram Signature` failed with `Invalid X-Hub-Signature-256`, and
nothing after it. If the flow got past that node, the signature check is not
working — fix it before pointing Meta at the URL.

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
