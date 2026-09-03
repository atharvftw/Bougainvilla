# Deploying Bougainvilla CRM

Two halves, deployed separately: the workflow runs on n8n, the dashboard runs on
Vercel. They meet at one shared secret.

---

## 1 · n8n

n8n must be reachable at a **public HTTPS URL** — Meta will not deliver webhooks
to `localhost`, plain HTTP, or a self-signed certificate. n8n Cloud, Railway,
Render, or your own box behind Caddy/nginx all work.

Set on the instance before importing:

```bash
NODE_FUNCTION_ALLOW_BUILTIN=crypto
WEBHOOK_URL=https://n8n.yourdomain.com
N8N_ENCRYPTION_KEY=<random>
```

Then:

1. **Workflows → Import from File** → `n8n/bougainvilla-crm.workflow.json`
2. Add the env vars from [n8n-credentials.md](n8n-credentials.md)
3. Open **Sarvam AI Chat Model** and attach the OpenAI-compatible credential
   (it imports with a `REPLACE_ME` placeholder)
4. **Activate** the workflow — production webhook URLs only exist while active

### Endpoints this creates

| URL | Method | Purpose |
|---|---|---|
| `/webhook/bougainvilla-instagram` | GET | Meta verification handshake |
| `/webhook/bougainvilla-instagram` | POST | inbound Instagram DMs |
| `/webhook/bougainvilla-booking-lead` | POST | website or landing-page form |
| `/webhook/bougainvilla-voice-event` | POST | Sarvam voice agent |
| `/webhook/bougainvilla-review` | POST | review platform |
| `/webhook/bougainvilla-dashboard` | GET | dashboard metrics (key-protected) |

Register the Instagram product's callback against
`/webhook/bougainvilla-instagram`. Meta sends a GET to that URL to verify
ownership before it will deliver anything.

### Check it before wiring Meta

```bash
# should print your challenge string
curl "https://n8n.yourdomain.com/webhook/bougainvilla-instagram?hub.mode=subscribe&hub.verify_token=YOUR_TOKEN&hub.challenge=test123"

# should return 403
curl -i "https://n8n.yourdomain.com/webhook/bougainvilla-instagram?hub.mode=subscribe&hub.verify_token=wrong&hub.challenge=test123"

# should be rejected — no valid signature
curl -X POST -H 'content-type: application/json' -d '{"entry":[]}' \
  https://n8n.yourdomain.com/webhook/bougainvilla-instagram
```

If the third one succeeds, `META_APP_SECRET` isn't reaching the Code node — stop
and fix that before pointing Meta at it.

---

## 2 · Dashboard on Vercel

The dashboard is static HTML plus one serverless function. No build step.

### Via the Vercel dashboard

1. **Add New → Project**, import this repository
2. **Root Directory: `dashboard`** ← the important one
3. Framework preset: **Other**. Leave build and output commands empty.
4. Environment Variables:

   | Name | Value |
   |---|---|
   | `N8N_DASHBOARD_URL` | `https://n8n.yourdomain.com/webhook/bougainvilla-dashboard` |
   | `DASHBOARD_API_KEY` | same value as in n8n |

5. Deploy.

### Via CLI

```bash
cd dashboard
vercel link
vercel env add N8N_DASHBOARD_URL production
vercel env add DASHBOARD_API_KEY production
vercel --prod
```

Generate the shared key with `openssl rand -hex 32` and set the identical value
in both n8n and Vercel.

### Verify

```bash
curl -s https://<your-deployment>.vercel.app/api/metrics | jq .source
```

- `"crm"` — connected end to end
- `"unavailable"` — check the `error` field: `not_configured` (env vars missing
  on Vercel), `upstream_error` (n8n rejected the key, or the workflow is not
  active), `upstream_unreachable` (wrong URL)

The page itself never breaks on failure — it falls back to demo numbers and the
sidebar says "Demo data — n8n not connected".

### Before it's public

The dashboard has **no login**. Anyone with the URL sees whatever the CRM
returns. Put Vercel Authentication (Project → Settings → Deployment Protection)
in front of it, or keep it on a preview URL, before real guest data flows in.
