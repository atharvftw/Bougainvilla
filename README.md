# Bougainvilla

Marketing and operations workspace for Bougainvilla Resorts.

## Contents

| Path | What |
|---|---|
| `n8n/` | The CRM automation workflow — import into n8n |
| `dashboard/` | The operations dashboard — deploys to Vercel |
| `supabase/` | Database schema — the only place data lives |
| `docs/` | Setup, credentials, data contract, content plan |
| `deliverables/` | Finished client-facing files |
| `scripts/` | Generators for anything in `deliverables/` |

## CRM automation

An n8n workflow that answers Instagram DMs with an AI booking agent, checks live
PMS availability before quoting anything, handles website booking enquiries,
triages voice calls, sends scheduled follow-ups, proposes nightly price changes
for human approval, and drafts review replies. A Vercel-hosted dashboard reads
its numbers back out.

Start here:

1. **[docs/deploy.md](docs/deploy.md)** — get both halves running
2. **[docs/instagram-setup.md](docs/instagram-setup.md)** — click-by-click Meta setup
3. **[docs/n8n-config.md](docs/n8n-config.md)** — where each value goes in n8n (no server access needed)
4. **[docs/supabase-setup.md](docs/supabase-setup.md)** — the database the dashboard reads
5. **[docs/n8n-credentials.md](docs/n8n-credentials.md)** — every secret it needs
6. **[docs/dashboard-contract.md](docs/dashboard-contract.md)** — the JSON the CRM must return
7. **[n8n/README.md](n8n/README.md)** — what each flow does

Copy `.env.example` to `.env` as your checklist, then `node scripts/check-creds.mjs`
to validate the values before wiring anything up. Real values go into the n8n UI
and the Vercel project, never into the repo.

The dashboard shows real numbers or none — there is no demo data in it. An
empty database renders zeros and "No conversations yet", and the status pill
distinguishes "database not set up" from "n8n not reachable".

## Content calendar

September 2026 plan: [docs/september-2026-plan.md](docs/september-2026-plan.md) ·
workbook in `deliverables/`.
