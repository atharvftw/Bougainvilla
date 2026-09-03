# Bougainvilla

Marketing and operations workspace for Bougainvilla Resorts.

## Contents

| Path | What |
|---|---|
| `n8n/` | The CRM automation workflow — import into n8n |
| `dashboard/` | The operations dashboard — deploys to Vercel |
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
3. **[docs/n8n-credentials.md](docs/n8n-credentials.md)** — every secret it needs
4. **[docs/dashboard-contract.md](docs/dashboard-contract.md)** — the JSON the CRM must return
5. **[n8n/README.md](n8n/README.md)** — what each flow does

Copy `.env.example` to `.env` as your checklist. Real values go into the n8n and
Vercel environment settings, never into the repo.

The dashboard runs on demo data until n8n is connected, and says so in the
sidebar — so you can deploy it and wire the backend afterwards.

## Content calendar

September 2026 plan: [docs/september-2026-plan.md](docs/september-2026-plan.md) ·
workbook in `deliverables/`.
