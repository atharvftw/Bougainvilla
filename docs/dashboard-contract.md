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
  ],
  "bookings": {
    "total": 6, "upcoming": 6, "nights_this_month": 10, "days_in_month": 30,
    "next_free": "2026-09-04", "list": [ { "guest": "…", "from": "…", "to": "…", "status": "booked" } ]
  },
  "occupancy": {
    "weekend_available": 12, "weekend_sold": 8, "weekend_fill_pct": 67,
    "weekday_available": 18, "weekday_sold": 2, "weekday_fill_pct": 11,
    "empty_weekday_nights_14d": [
      { "date": "2026-09-07", "dow": "Mon", "price": 17000 }
    ]
  },
  "economics": {
    "revenue_this_month": 296000, "revenue_basis": "list_tariff",
    "nights_sold": 10, "avg_rate": 29600,
    "fixed_monthly": null, "variable_per_night": 3000,
    "profit": null, "break_even_nights": null, "nights_to_break_even": null
  },
  "tariff": { "weekend": 30000, "weekday_list": 28000, "weekday_floor": 17000,
              "base_pax": 10, "ladder": [ { "min_days": 22, "price": 28000 } ] }
}
```

Notes:

- `message_series` is ordered by date, not by label — sorting the formatted
  label would put "01 Sep" before "22 Aug" and scramble the chart.
- `display_name` is often null; Instagram does not send a name with a DM. The
  page falls back to `Guest ####` from the last four digits of the sender id.
- Guest text is HTML-escaped before rendering.
- `occupancy.weekday_fill_pct` is the number to manage. Weekends run 67–92%
  full and weekdays 11–18%, so the weekday bucket is where the unearned
  revenue sits.
- `empty_weekday_nights_14d` is a work queue, not a statistic: each entry is a
  night with nobody in it and the price the ladder currently asks for it.
- `revenue_basis` is `list_tariff` while the ledger carries no prices, and
  `quoted` once stays booked through the agent have a `quoted_total`.
- `economics.profit`, `break_even_nights` and `nights_to_break_even` are
  **null until `pricing_config.fixed_monthly` is filled in**. The page shows a
  dash and says what is missing rather than inventing a number.

## `source` values

| Value | Sidebar | Meaning |
|---|---|---|
| `supabase` | 🟢 Live | working end to end |
| `no_db` | 🟡 n8n connected · database not set up | n8n answered; Supabase did not |
| anything else | 🔴 n8n not reachable | the proxy could not reach n8n |

`/api/metrics` always returns HTTP 200 so the page renders in every case.

The page polls every 60 seconds.
