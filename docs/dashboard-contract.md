# Dashboard data contract

How a number gets from the CRM onto the dashboard:

```
browser  ──GET /api/metrics──▶  Vercel function  ──x-api-key──▶  n8n
                                                                  │
                                                    CRM_METRICS_URL
```

The browser never holds a key and never learns the n8n hostname.

## What `CRM_METRICS_URL` must return

Every field is optional. Anything missing or non-numeric is dropped by
**Shape Dashboard Metrics** and the dashboard keeps its built-in demo value for
that tile — so a partial response degrades one number, not the page.

```json
{
  "total_bookings": 312,
  "active_leads": 57,
  "revenue_mtd": 2140000,
  "avg_rating": 4.91,
  "channels":  { "instagram": 58, "direct": 27, "voice": 15 },
  "revenue_series": {
    "labels": ["May","Jun","Jul","Aug","Sep"],
    "values": [920000, 1140000, 1380000, 1520000, 2140000]
  },
  "recent_bookings": [
    { "guest_name": "Priya Sharma", "property": "Villa 2",
      "dates": "Sep 15-19", "status": "Confirmed" }
  ]
}
```

Notes:

- `revenue_mtd` and `revenue_series.values` are **rupees**. The dashboard divides
  by 100,000 to display lakhs — don't pre-convert.
- `channels` keys are `instagram` (DMs), `direct` (website booking form) and
  `voice` (phone). Values are percentages and should total ~100.
- `status` maps to a colour: `confirmed`/`booked` green, `pending`/`support`
  amber, `awaiting_payment`/`enquiry` blue, `cancelled` red. Anything else
  renders blue.
- A top-level `data` wrapper is unwrapped automatically, so `{"data": {...}}`
  works too.
- Guest names are HTML-escaped before rendering.

## Live vs demo

The sidebar pill and the "Recent Bookings" badge report which one you're seeing:

| `source` | Sidebar | Badge | Means |
|---|---|---|---|
| `crm` | 🟢 "Live — n8n connected" | Live | working end to end |
| `no_crm` | 🟡 "n8n connected · CRM not linked" | Demo | n8n answered; `CRM_METRICS_URL` isn't wired up |
| anything else | 🔴 "Demo data — n8n not reachable" | Demo | the proxy couldn't reach n8n at all |

The middle state matters: without it, a missing CRM looks identical to a broken
n8n connection, and you debug the wrong half of the system.

Failures never blank the page. `/api/metrics` returns HTTP 200 with
`source: "unavailable"` and a reason (`not_configured`, `upstream_error`,
`upstream_timeout`, `upstream_unreachable`) — visible in the browser console.

The page polls every 60 seconds.
