# Configuring the workflow — no server access needed

`n8n.veloit.in` is Community Edition on a container we can't reach:

- **`$env` is out** — setting instance environment variables needs shell access
  and a restart.
- **`$vars` is out** — the Variables feature is paywalled ("Upgrade to unlock").
- **`NODE_FUNCTION_ALLOW_BUILTIN` is out** — same reason as `$env`.

So the workflow is configured entirely through the n8n UI. Nothing here needs
anyone to touch the server.

---

## A · Credentials — for everything outbound

**Credentials → Add credential.** These are encrypted at rest by n8n, so real
secrets belong here rather than in a node.

| Credential | Type | Fields | Used by |
|---|---|---|---|
| `Instagram Graph (Bearer)` | **Bearer Auth** | Token: your `META_ACCESS_TOKEN` | Send Instagram AI Reply |
| `Sarvam AI (api-subscription-key)` | **Header Auth** | Name `api-subscription-key`, Value: your Sarvam key | the 5 Sarvam HTTP nodes |
| `Sarvam AI (OpenAI-compatible)` | **OpenAI** | API key: Sarvam key · Base URL `https://api.sarvam.ai/v1` | Sarvam AI Chat Model |

Create the rest only when you actually connect those systems — until then their
nodes point at `example.invalid` and fail harmlessly:

`CRM API`, `PMS API`, `Support API`, `Guest Messaging`, `Staff Alert`,
`Review API`, `Pricing Approval`, `Sarvam Voice Callback` — all **Bearer Auth**.

The workflow imports with placeholder credential IDs (`CRED_IG`, `CRED_SARVAM`,
…), so n8n shows each node with an unset credential and you pick yours from the
dropdown. That is expected on first import.

---

## B · Three Code nodes — paste one value each

Credentials can't be read from Code nodes, so these three carry their value at
the top of the node, in a marked block. Open the node, paste, save.

| Node | Constant | Value |
|---|---|---|
| **Check Meta Verify Token** | `META_VERIFY_TOKEN` | the string you type into Meta's "Verify token" box |
| **Verify Instagram Signature** | `META_APP_SECRET` | Instagram → API setup with Instagram login → **Instagram app secret** (*not* App settings → Basic) |
| **Authorize Dashboard Request** | `DASHBOARD_API_KEY` | `openssl rand -hex 32`, same value as in Vercel |

```js
// ─── PASTE YOUR APP SECRET HERE ──────────────────────────────────────
//     Meta app → App settings → Basic → App Secret
const META_APP_SECRET = '';
// ─────────────────────────────────────────────────────────────────────
```

Each fails closed if left blank — the node throws rather than processing an
unverified request.

### ⚠️ The tradeoff, stated plainly

These three values live in the **workflow JSON**, not in encrypted credential
storage. That means:

- **Never export this workflow to anywhere public**, and never commit an export
  to this repo. The copy in `n8n/` is the blank template — keep it that way.
- Anyone who can open the workflow in n8n can read them.
- If they leak: rotate the App Secret in the Meta dashboard, and pick a new
  verify token and dashboard key.

There is no way around this on Community Edition without server access. It is
still far better than skipping signature verification.

---

## C · One plain node parameter

**Send Instagram AI Reply** → URL contains `PASTE_INSTAGRAM_BUSINESS_ID`.
Replace it with your Instagram account ID. Not a secret — it's a public account
identifier.

```
https://graph.instagram.com/v23.0/{{ $json.recipientId || 'PASTE_INSTAGRAM_BUSINESS_ID' }}/messages
```

---

## Why the signature check works without server config

Meta signs webhooks with HMAC-SHA256. Two obvious ways to compute it are both
unavailable in n8n's Code sandbox:

- `require('crypto')` — blocked unless `NODE_FUNCTION_ALLOW_BUILTIN=crypto` is
  set on the host.
- `crypto.subtle` (WebCrypto) — the sandbox exposes no `crypto` global at all.
  Trying it fails with `ReferenceError: crypto is not defined`.

So **Verify Instagram Signature** implements SHA-256 and HMAC in plain
JavaScript, using only `Buffer` (which the sandbox does provide) for base64 and
UTF-8 conversion. It depends on nothing that can be switched off.

Verified byte-identical to Node's `createHmac` across message lengths either
side of the 64-byte block boundary (0, 55, 56, 57, 63, 64, 65, 127, 128, 4096)
and key lengths above and below it, then re-tested inside a sandbox with
`crypto` and `require` both undefined: valid signatures pass; tampered bodies,
wrong, truncated and missing signatures are rejected; Unicode and 5 KB payloads
verify correctly.

That is why the node is ~100 lines. Do not "simplify" it back to a crypto
call — it will throw on this instance.

---

## Checklist

- [ ] Import `n8n/bougainvilla-crm.workflow.json` (replaces the old Airbnb one)
- [ ] Create the 3 credentials in section A
- [ ] Open each node with an unset credential and select yours
- [ ] Paste the 3 values in section B
- [ ] Replace `PASTE_INSTAGRAM_BUSINESS_ID` in section C
- [ ] **Activate** the workflow
- [ ] Register the webhook URL in Meta (see [instagram-setup.md](instagram-setup.md) Step 5)
