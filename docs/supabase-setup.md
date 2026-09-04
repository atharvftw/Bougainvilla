# Supabase — the only place data lives

The dashboard shows real numbers or none. Everything it displays comes from
here; there is no demo data left in the page.

## Why a database at all

n8n stores nothing durable. Conversation memory is in-RAM and clears on
restart, and the CRM/PMS endpoints are still placeholders. Without a store
there is genuinely nothing for a dashboard to show.

Supabase also closes two gaps that were open by design:

- **Webhook de-duplication.** `messages.provider_message_id` is `UNIQUE`, so
  when Meta retries a delivery the insert conflicts and is ignored instead of
  producing a second reply.
- **Durable conversation history**, independent of n8n restarts.

---

## 1 · Create the project

[supabase.com](https://supabase.com) → **New project**. Free tier is fine.
Pick a region close to your guests (Mumbai / Singapore for India).

## 2 · Run the schema

**SQL Editor → New query** → paste all of
[`supabase/schema.sql`](../supabase/schema.sql) → **Run**.

That creates:

| Object | What it is |
|---|---|
| `leads` | one row per guest per channel, upserted on every message |
| `messages` | every message in and out; `provider_message_id` unique |
| `dashboard_metrics()` | one call returning everything the dashboard needs |
| `record_exchange(...)` | one call recording a whole exchange, atomically |

RLS is enabled with **no policies**, so the anon key can read nothing. n8n
uses the service key, which bypasses RLS, and n8n is the only client — the
dashboard never touches Supabase directly.

## 3 · Credential in n8n

**Credentials → Add credential → Supabase API**

| Field | Value |
|---|---|
| Host | `https://YOUR_PROJECT.supabase.co` (no `/rest/v1`) |
| Secret Key | Project Settings → API Keys → **service_role** |

That credential sets both the `apikey` and `Authorization` headers, which is
what PostgREST needs.

Then open the two nodes below and replace `YOUR_PROJECT` in their URLs, and
select the credential:

- **Save To Supabase** → `…/rest/v1/rpc/record_exchange`
- **Fetch Supabase Metrics** → `…/rest/v1/rpc/dashboard_metrics`

## 4 · Check it

DM the villa from your tester account, then:

```sql
select * from messages order by created_at desc limit 5;
select dashboard_metrics();
```

A row per message means the write path works. The dashboard picks it up
within a minute.

---

## What the dashboard shows

Only what is actually tracked:

| Tile | Source |
|---|---|
| Conversations | distinct people who have messaged |
| Active this week | guests seen in the last 7 days |
| Messages today | in and out, since midnight |
| Waiting on a human | leads the agent flagged `needs_human` |

Plus messages received per day for 14 days, in/out/guest totals, and the ten
most recent conversations.

**Deliberately absent:** revenue, occupancy, ratings, bookings. Bougainvilla
does not track those anywhere yet, so the dashboard does not pretend to. They
become real tiles when a PMS is connected, not before.

## States

| Status pill | Meaning |
|---|---|
| 🟢 Live | Supabase answered |
| 🟡 n8n connected · database not set up | n8n fine, Supabase not reachable or schema missing |
| 🔴 n8n not reachable | check `N8N_DASHBOARD_URL` / `DASHBOARD_API_KEY` and that the workflow is active |

An empty database is **not** an error — it shows zeros and "No conversations
yet", which is the truth on day one.
