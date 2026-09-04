# Dashboard data contract

```
browser ──GET /api/metrics──▶ Vercel function ──x-api-key──▶ n8n ──▶ Supabase
```

The browser never holds a key and never learns the n8n hostname. n8n is the
only thing that talks to Supabase.

## The payload

`dashboard_metrics()` returns exactly this; `Shape Dashboard Metrics` adds
`source` and `generated_at` and passes it through unchanged.

```json
{
  "source": "supabase",
  "generated_at": "2026-09-04T07:30:00.000Z",
  "stats": {
    "conversations": 2, "active_leads": 2, "messages_today": 3,
    "needs_human": 1, "messages_in": 3, "messages_out": 2, "total_leads": 2
  },
  "channels": { "instagram": 2 },
  "message_series": {
    "labels": ["22 Aug", "23 Aug"],
    "values": [0, 1]
  },
  "recent_leads": [
    { "sender_id": "1024…", "display_name": "Aarti", "lead_stage": "qualified",
      "booking_status": "enquiry", "needs_human": true,
      "last_message": "do you have a villa free in October?",
      "last_seen_at": "2026-09-04T07:29:00+00:00" }
  ]
}
```

Notes:

- `message_series` is ordered by date, not by label — sorting the formatted
  label would put "01 Sep" before "22 Aug" and scramble the chart.
- `display_name` is often null; Instagram does not send a name with a DM. The
  page falls back to `Guest ####` from the last four digits of the sender id.
- Guest text is HTML-escaped before rendering.

## `source` values

| Value | Sidebar | Meaning |
|---|---|---|
| `supabase` | 🟢 Live | working end to end |
| `no_db` | 🟡 n8n connected · database not set up | n8n answered; Supabase did not |
| anything else | 🔴 n8n not reachable | the proxy could not reach n8n |

`/api/metrics` always returns HTTP 200 so the page renders in every case.

The page polls every 60 seconds.
